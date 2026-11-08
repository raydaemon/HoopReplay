import Foundation
import Combine
import Photos

// Data layer mirroring the Android HoopDb: the same tables (team, player, game, event,
// player_game_stat, segment, deletion), the same integer ids derived from the clock plus a
// per-device salt, and the same deletion tombstones, so sync and exports are interchangeable.

struct Team: Identifiable, Codable, Hashable {
    var id: Int64
    var name: String
    var createdAt: Int64 = 0
}

struct Player: Identifiable, Codable, Hashable {
    var id: Int64
    var teamId: Int64
    var name: String
    var number: String

    /// "#12 Haoxuan Tan"; a player without a jersey number shows only the name, never "#--".
    var label: String {
        let number = self.number.trimmed
        let name = self.name.trimmed
        return number.isEmpty ? name : "#\(number) \(name)".trimmed
    }
}

func playerSelectionLabel(_ player: Player, among players: [Player]) -> String {
    let name = player.name.trimmed
    guard !name.isEmpty else { return player.number.trimmed.isEmpty ? "—" : "#\(player.number.trimmed)" }
    let first = firstNameOf(name), last = lastNameOf(name)
    let sameFirst = players.filter { firstNameOf($0.name).localizedCaseInsensitiveCompare(first) == .orderedSame }
    guard sameFirst.count > 1 else { return player.number.trimmed.isEmpty ? first : "#\(player.number.trimmed) \(first)" }
    guard !last.isEmpty else { return player.label }
    let initial = String(last.prefix(1)).uppercased()
    let sameInitial = sameFirst.filter { lastNameOf($0.name).prefix(1).uppercased() == initial }.count
    let display = sameInitial > 1 ? name : "\(first) \(initial)."
    return player.number.trimmed.isEmpty ? display : "#\(player.number.trimmed) \(display)"
}

struct Game: Identifiable, Codable, Hashable {
    var id: Int64
    var title: String
    var homeId: Int64
    var awayId: Int64
    var homeScore = 0
    var awayScore = 0
    var status = "READY"
    var scheduledAt: Int64
    var videoQuality = "HIGHEST"
    var periodCount = 4
    var periodDurationMs: Int64 = 480_000
    var currentPeriod = 1
    var clockRemainingMs: Int64 = 480_000
    var createdAt: Int64 = 0
    // Joined from the team table when the game is read, never stored.
    var homeName = ""
    var awayName = ""

    enum CodingKeys: String, CodingKey { case id, title, homeId, awayId, homeScore, awayScore, status, scheduledAt, videoQuality, periodCount, periodDurationMs, currentPeriod, clockRemainingMs, createdAt }
}

struct StatEvent: Identifiable, Codable, Hashable {
    var id: Int64
    var gameId: Int64
    var teamId: Int64
    var playerId: Int64?
    var type: String
    var value: Int
    var period: Int
    var gameClockMs: Int64
    var segment: Int
    var segmentTimeMs: Int64
    var finalVideoTimeMs: Int64
    var reverted: Bool
    var createdAt: Int64 = 0
}

struct RecordingSegment: Identifiable, Codable, Hashable {
    var id: Int64
    var gameId: Int64
    var sequence: Int
    var uri: String
    var durationMs: Int64
    var createdAt: Int64
}

struct Deletion: Codable, Hashable {
    var entity: String
    var localId: Int64
    var deletedAt: Int64
    var deviceId: String
}

struct PlayerGameStat: Codable, Hashable {
    var gameId: Int64
    var playerId: Int64
    var minutesMs: Int64
    var plusMinus: Int
}

struct GameImport {
    var gameId: Int64
    var events: Int
    var createdTeams: Int
    var createdPlayers: Int
}

let gameExportKind = "hoopreplay.game"
private let idSaltRange: Int64 = 1000
private let deletableEntities: [(entity: String, table: String)] = [("teams", "team"), ("players", "player"), ("games", "game"), ("events", "event"), ("segments", "segment")]

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var isBlank: Bool { trimmed.isEmpty }
    func capitalizeInitial() -> String {
        guard let index = firstIndex(where: { $0.isLetter }) else { return self }
        var result = self
        result.replaceSubrange(index...index, with: String(self[index]).uppercased())
        return result
    }
    /// "COMPLETED" -> "Completed": enum values are never shown in all capitals.
    var titleCased: String {
        split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
    }
}

func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var teamRows: [Team] = []
    @Published private(set) var playerRows: [Player] = []
    @Published private(set) var gameRows: [Game] = []
    @Published private(set) var eventRows: [StatEvent] = []
    @Published private(set) var segmentRows: [RecordingSegment] = []
    @Published private(set) var deletionRows: [Deletion] = []
    @Published private(set) var statRows: [PlayerGameStat] = []
    /// Short transient message, the iOS stand-in for an Android Toast.
    @Published var toast: String?
    private var toastTask: Task<Void, Never>?

    private var loading = true
    private var lastIdTick: Int64 = 0

    private struct Snapshot: Codable {
        var teams: [Team]; var players: [Player]; var games: [Game]; var events: [StatEvent]
        var segments: [RecordingSegment]; var deletions: [Deletion]; var stats: [PlayerGameStat]
    }

    // UI-test launches must never touch the real store: they start empty AND write to
    // their own file, so running the test suite cannot wipe the data on the device.
    static var isUITesting: Bool { ProcessInfo.processInfo.arguments.contains("-ui-testing") }
    private var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private var fileURL: URL { documents.appendingPathComponent(Self.isUITesting ? "hoopreplay-v2-ui-testing.json" : "hoopreplay-v2.json") }
    private var legacyFileURL: URL { documents.appendingPathComponent("hoopreplay.json") }

    /// A throwaway store for unit tests: nothing is read from or written to disk.
    private let inMemory: Bool
    init(inMemory: Bool = false) {
        self.inMemory = inMemory
        if !Self.isUITesting && !inMemory {
            if let data = try? Data(contentsOf: fileURL), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
                teamRows = snapshot.teams; playerRows = snapshot.players; gameRows = snapshot.games; eventRows = snapshot.events
                segmentRows = snapshot.segments; deletionRows = snapshot.deletions; statRows = snapshot.stats
            } else if let data = try? Data(contentsOf: legacyFileURL) {
                migrateLegacy(data)
            }
        }
        loading = false
    }

    private func save() {
        guard !loading, !inMemory else { return }
        let snapshot = Snapshot(teams: teamRows, players: playerRows, games: gameRows, events: eventRows, segments: segmentRows, deletions: deletionRows, stats: statRows)
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: fileURL, options: .atomic) }
    }

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { try? await Task.sleep(nanoseconds: 2_500_000_000); if !Task.isCancelled { toast = nil } }
    }

    /// Clears all locally cached account data after the server confirms deletion.
    @MainActor func clearAllAccountData() async {
        let assetIds = segmentRows.compactMap { uri -> String? in
            let value = uri.uri
            return value.hasPrefix("ph://") ? String(value.dropFirst(5)) : (value.contains("/") ? nil : value)
        }
        if !assetIds.isEmpty {
            let authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            if authorization == .authorized || authorization == .limited {
                let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIds, options: nil)
                try? await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets(assets)
                }
            }
        }
        teamRows.removeAll(); playerRows.removeAll(); gameRows.removeAll(); eventRows.removeAll()
        segmentRows.removeAll(); deletionRows.removeAll(); statRows.removeAll(); save()
        let fm = FileManager.default
        try? fm.removeItem(at: documents.appendingPathComponent("Recordings", isDirectory: true))
    }

    // MARK: - Ids and deletions

    /**
     A deletion has to be recorded, never inferred from a row's absence: sync used to push only the
     rows this device still had, so nothing ever told the other devices that a game was gone.
     */
    private func deviceId() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: "device_id") { return existing }
        let created = "ios-" + UUID().uuidString.lowercased()
        defaults.set(created, forKey: "device_id")
        return created
    }
    private func recordDeletions(_ entity: String, _ ids: [Int64]) {
        guard !ids.isEmpty else { return }
        let deletedAt = nowMs()
        let device = deviceId()
        for id in ids {
            deletionRows.removeAll { $0.entity == entity && $0.localId == id }
            deletionRows.append(Deletion(entity: entity, localId: id, deletedAt: deletedAt, deviceId: device))
        }
    }
    /// A reused id must drop the tombstone it inherited.
    private func clearDeletion(_ entity: String, _ id: Int64) { deletionRows.removeAll { $0.entity == entity && $0.localId == id } }

    /**
     Allocates the id for a new row. Deriving the id from the clock and a per-device salt keeps
     each device in its own lane while ids stay sortable by creation order.
     */
    private func nextLocalId(_ highestInTable: Int64, entity: String) -> Int64 {
        let highestDeleted = deletionRows.filter { $0.entity == entity }.map(\.localId).max() ?? 0
        let highest = max(highestInTable, highestDeleted)
        let tick = max(nowMs(), highest / idSaltRange + 1, lastIdTick + 1)
        lastIdTick = tick
        return tick * idSaltRange + deviceSalt()
    }
    private func deviceSalt() -> Int64 {
        var hash: Int64 = 0
        for scalar in deviceId().unicodeScalars { hash = (hash * 31 + Int64(scalar.value)) % idSaltRange }
        return hash
    }

    // MARK: - Teams

    @discardableResult
    func addTeam(_ name: String) -> Int64 {
        let id = nextLocalId(teamRows.map(\.id).max() ?? 0, entity: "teams")
        teamRows.append(Team(id: id, name: name.capitalizeInitial(), createdAt: nowMs()))
        clearDeletion("teams", id)
        save()
        return id
    }
    func teams() -> [Team] { teamRows.sorted { $0.id < $1.id } }
    func team(_ id: Int64) -> Team? { teamRows.first { $0.id == id } }
    func deleteTeam(_ id: Int64) -> Bool {
        if gameRows.contains(where: { $0.homeId == id || $0.awayId == id }) { return false }
        recordDeletions("players", playerRows.filter { $0.teamId == id }.map(\.id))
        recordDeletions("teams", [id])
        playerRows.removeAll { $0.teamId == id }
        let before = teamRows.count
        teamRows.removeAll { $0.id == id }
        save()
        return teamRows.count < before
    }

    // MARK: - Players

    func findPlayer(_ team: Int64, name: String, number: String) -> Player? {
        let cleanName = name.capitalizeInitial().trimmed
        let cleanNumber = number.trimmed
        let roster = players(team)
        if !cleanNumber.isEmpty { return roster.first { $0.number.trimmed == cleanNumber } }
        return roster.first { $0.number.isBlank && !cleanName.isEmpty && $0.name.caseInsensitiveCompare(cleanName) == .orderedSame }
    }
    /// Reuses the existing player when the jersey number (or the name, for unnumbered players) already exists on the team.
    @discardableResult
    func addPlayer(_ team: Int64, name: String, number: String) -> Int64 {
        if let existing = findPlayer(team, name: name, number: number) { return existing.id }
        let id = nextLocalId(playerRows.map(\.id).max() ?? 0, entity: "players")
        playerRows.append(Player(id: id, teamId: team, name: name.capitalizeInitial(), number: number))
        clearDeletion("players", id)
        save()
        return id
    }
    func players(_ team: Int64) -> [Player] {
        playerRows.filter { $0.teamId == team }.sorted { (Int($0.number.trimmed) ?? 0, $0.id) < (Int($1.number.trimmed) ?? 0, $1.id) }
    }
    func player(_ id: Int64) -> Player? { playerRows.first { $0.id == id } }
    /// Renames a player / changes their jersey number in place, so recorded stats stay attached.
    func updatePlayer(_ id: Int64, name: String, number: String) {
        guard let index = playerRows.firstIndex(where: { $0.id == id }) else { return }
        playerRows[index].name = name.trimmed.capitalizeInitial()
        playerRows[index].number = number.trimmed
        save()
    }
    func playerHasEvents(_ id: Int64) -> Bool { eventRows.contains { $0.playerId == id } }
    @discardableResult
    func deletePlayer(_ id: Int64) -> Bool {
        recordDeletions("players", [id])
        for index in eventRows.indices where eventRows[index].playerId == id { eventRows[index].playerId = nil }
        let before = playerRows.count
        playerRows.removeAll { $0.id == id }
        save()
        return playerRows.count < before
    }

    // MARK: - Games

    @discardableResult
    func addGame(title: String, home: Int64, away: Int64, scheduledAt: Int64, videoQuality: String, periodCount: Int, periodDurationMs: Int64) -> Int64 {
        let id = nextLocalId(gameRows.map(\.id).max() ?? 0, entity: "games")
        gameRows.append(Game(id: id, title: title, homeId: home, awayId: away, status: "READY", scheduledAt: scheduledAt, videoQuality: videoQuality, periodCount: periodCount, periodDurationMs: periodDurationMs, currentPeriod: 1, clockRemainingMs: periodDurationMs, createdAt: nowMs()))
        clearDeletion("games", id)
        save()
        return id
    }
    func updateGame(_ id: Int64, title: String, home: Int64, away: Int64, scheduledAt: Int64, videoQuality: String, periodCount: Int, periodDurationMs: Int64) {
        guard let index = gameRows.firstIndex(where: { $0.id == id }) else { return }
        let oldDuration = gameRows[index].periodDurationMs
        let wasAtPeriodStart = gameRows[index].currentPeriod == 1 && gameRows[index].clockRemainingMs == oldDuration
        gameRows[index].title = title; gameRows[index].homeId = home; gameRows[index].awayId = away
        gameRows[index].scheduledAt = scheduledAt; gameRows[index].videoQuality = videoQuality
        gameRows[index].periodCount = periodCount; gameRows[index].periodDurationMs = periodDurationMs
        if wasAtPeriodStart { gameRows[index].clockRemainingMs = periodDurationMs }
        save()
    }
    /// Games with both teams resolved (the SQL join), newest first.
    func games() -> [Game] {
        gameRows.compactMap { row -> Game? in
            guard let home = team(row.homeId), let away = team(row.awayId) else { return nil }
            var game = row; game.homeName = home.name; game.awayName = away.name
            return game
        }.sorted { $0.id > $1.id }
    }
    func game(_ id: Int64) -> Game? { games().first { $0.id == id } }
    @discardableResult
    func deleteGame(_ id: Int64) -> Bool {
        recordDeletions("events", eventRows.filter { $0.gameId == id }.map(\.id))
        recordDeletions("segments", segmentRows.filter { $0.gameId == id }.map(\.id))
        recordDeletions("games", [id])
        eventRows.removeAll { $0.gameId == id }
        segmentRows.removeAll { $0.gameId == id }
        statRows.removeAll { $0.gameId == id }
        let before = gameRows.count
        gameRows.removeAll { $0.id == id }
        save()
        return gameRows.count < before
    }
    private func updateGame(_ id: Int64, _ change: (inout Game) -> Void) {
        guard let index = gameRows.firstIndex(where: { $0.id == id }) else { return }
        change(&gameRows[index])
        save()
    }
    func status(_ id: Int64, _ value: String) { updateGame(id) { $0.status = value } }
    /// Restores the exported scoreboard and clock on a freshly imported game.
    func updateImportedGame(_ id: Int64, homeScore: Int, awayScore: Int, status: String, currentPeriod: Int, clockRemainingMs: Int64) {
        updateGame(id) { $0.homeScore = homeScore; $0.awayScore = awayScore; $0.status = status; $0.currentPeriod = currentPeriod; $0.clockRemainingMs = clockRemainingMs }
    }
    func videoQuality(_ id: Int64, _ value: String) { updateGame(id) { $0.videoQuality = value } }
    func saveProgress(_ id: Int64, period: Int, clockRemainingMs: Int64) { updateGame(id) { $0.currentPeriod = period; $0.clockRemainingMs = clockRemainingMs } }
    func score(_ game: Game, homeDelta: Int, awayDelta: Int) {
        updateGame(game.id) { $0.homeScore = max(0, $0.homeScore + homeDelta); $0.awayScore = max(0, $0.awayScore + awayDelta) }
    }
    /// Keeps the persisted scoreboard in sync with the same active scoring events used by stats.
    func recalculateScore(_ gameId: Int64) {
        guard let index = gameRows.firstIndex(where: { $0.id == gameId }) else { return }
        let game = gameRows[index]
        let scoring = eventRows.filter { $0.gameId == gameId && !$0.reverted && isScoringType($0.type) }
        let home = scoring.filter { $0.teamId == game.homeId }.reduce(0) { $0 + $1.value }
        let away = scoring.filter { $0.teamId == game.awayId }.reduce(0) { $0 + $1.value }
        if game.homeScore != home || game.awayScore != away {
            gameRows[index].homeScore = home; gameRows[index].awayScore = away
            save()
        }
    }

    // MARK: - Events

    @discardableResult
    func addEvent(gameId: Int64, teamId: Int64, playerId: Int64?, type: String, value: Int, period: Int, clock: Int64, segment: Int, segmentMs: Int64, videoMs: Int64) -> Int64 {
        startSegment(gameId, sequence: segment)
        let id = nextLocalId(eventRows.map(\.id).max() ?? 0, entity: "events")
        eventRows.append(StatEvent(id: id, gameId: gameId, teamId: teamId, playerId: playerId, type: type, value: value, period: period, gameClockMs: clock, segment: segment, segmentTimeMs: segmentMs, finalVideoTimeMs: videoMs, reverted: false, createdAt: nowMs()))
        clearDeletion("events", id)
        save()
        return id
    }
    func undo(_ gameId: Int64) -> StatEvent? {
        guard let index = eventRows.lastIndex(where: { $0.gameId == gameId && !$0.reverted }) else { return nil }
        eventRows[index].reverted = true
        save()
        return eventRows[index]
    }
    func revertEvent(_ id: Int64) {
        guard let index = eventRows.firstIndex(where: { $0.id == id }) else { return }
        eventRows[index].reverted = true
        save()
    }
    func updateEvent(_ id: Int64, playerId: Int64?, type: String, value: Int, period: Int? = nil, gameClockMs: Int64? = nil) {
        guard let index = eventRows.firstIndex(where: { $0.id == id }) else { return }
        eventRows[index].playerId = playerId
        eventRows[index].type = type
        eventRows[index].value = value
        if let period { eventRows[index].period = period }
        if let gameClockMs { eventRows[index].gameClockMs = gameClockMs }
        save()
    }
    func events(_ gameId: Int64) -> [StatEvent] { eventRows.filter { $0.gameId == gameId }.sorted { $0.id < $1.id } }
    func activeEvents(_ gameId: Int64) -> [StatEvent] { events(gameId).filter { !$0.reverted } }

    // MARK: - Minutes and plus/minus

    func playerGameStats(_ gameId: Int64) -> [Int64: (Int64, Int)] {
        var result: [Int64: (Int64, Int)] = [:]
        for row in statRows where row.gameId == gameId { result[row.playerId] = (row.minutesMs, row.plusMinus) }
        return result
    }
    func recalculatePlayerGameStats(_ game: Game) {
        let es = activeEvents(game.id).sorted { ($0.period, -$0.gameClockMs, $0.id) < ($1.period, -$1.gameClockMs, $1.id) }
        // Only recorded STARTER events open a period for a player: a stat never implies that the
        // player was on the floor, so minutes come solely from STARTER / SUB_IN / SUB_OUT history.
        func starters(_ teamId: Int64, _ period: Int) -> Set<Int64> {
            var seen: [Int64] = []
            for e in es where e.teamId == teamId && e.period == period && e.type == "STARTER" {
                if let p = e.playerId, !seen.contains(p) { seen.append(p) }
            }
            return Set(seen.prefix(5))
        }
        var minutes: [Int64: Int64] = [:]
        var plusMinus: [Int64: Int] = [:]
        let periods = Array(Set(es.map(\.period))).sorted()
        for teamId in [game.homeId, game.awayId] {
            for period in periods {
                var onCourt = starters(teamId, period)
                var entered: [Int64: Int64] = [:]
                for p in onCourt { entered[p] = game.periodDurationMs }
                for e in es where e.period == period {
                    if e.teamId == teamId && e.type == "SUB_IN", let p = e.playerId {
                        let pairedClock = es.filter { $0.type == "SUB_OUT" && $0.teamId == e.teamId && $0.period == e.period && $0.gameClockMs >= e.gameClockMs && $0.gameClockMs - e.gameClockMs <= 5_000 }
                            .min { ($0.gameClockMs, abs($0.id - e.id)) < ($1.gameClockMs, abs($1.id - e.id)) }?.gameClockMs ?? e.gameClockMs
                        onCourt.insert(p)
                        if entered[p] == nil { entered[p] = pairedClock }
                    } else if e.teamId == teamId && e.type == "SUB_OUT", let p = e.playerId {
                        if let start = entered.removeValue(forKey: p) { minutes[p, default: 0] += max(0, start - e.gameClockMs) }
                        onCourt.remove(p)
                    } else if isScoringType(e.type) {
                        // Manual +1/-1 adjustments count like Android does, so +/- matches the scoreboard.
                        for p in onCourt { plusMinus[p, default: 0] += e.teamId == teamId ? e.value : -e.value }
                    }
                }
                for (p, start) in entered { minutes[p, default: 0] += max(0, start) }
            }
        }
        let fresh = (players(game.homeId) + players(game.awayId)).map { PlayerGameStat(gameId: game.id, playerId: $0.id, minutesMs: minutes[$0.id] ?? 0, plusMinus: plusMinus[$0.id] ?? 0) }
        let current = statRows.filter { $0.gameId == game.id }
        if Set(current) != Set(fresh) {
            statRows.removeAll { $0.gameId == game.id }
            statRows.append(contentsOf: fresh)
            save()
        }
    }

    // MARK: - Recording segments

    @discardableResult
    func startSegment(_ gameId: Int64, sequence: Int) -> Int64 {
        if let existing = segmentRows.first(where: { $0.gameId == gameId && $0.sequence == sequence }) { return existing.id }
        let id = nextLocalId(segmentRows.map(\.id).max() ?? 0, entity: "segments")
        segmentRows.append(RecordingSegment(id: id, gameId: gameId, sequence: sequence, uri: "", durationMs: 0, createdAt: nowMs()))
        clearDeletion("segments", id)
        save()
        return id
    }
    func finalizeSegment(_ id: Int64, uri: String, durationMs: Int64) {
        guard let index = segmentRows.firstIndex(where: { $0.id == id }) else { return }
        segmentRows[index].uri = uri; segmentRows[index].durationMs = durationMs
        save()
    }
    /// Segments whose recording never finalized (a crash mid-recording leaves the uri empty).
    func orphanSegments(_ gameId: Int64) -> [(Int64, Int)] { segmentRows.filter { $0.gameId == gameId && $0.uri.isEmpty }.map { ($0.id, $0.sequence) } }

    // MARK: - Sync snapshots (the same JSON rows the Android app exchanges with the server)

    func exportSyncSnapshot() -> [String: Any] {
        [
            "schemaVersion": 1,
            "updatedAt": nowMs(),
            "teams": teams().map { ["id": $0.id, "name": $0.name, "created_at": $0.createdAt] as [String: Any] },
            "players": playerRows.sorted { $0.id < $1.id }.map { ["id": $0.id, "team_id": $0.teamId, "name": $0.name, "number": $0.number] as [String: Any] },
            "games": gameRows.sorted { $0.id < $1.id }.map { ["id": $0.id, "title": $0.title, "home_id": $0.homeId, "away_id": $0.awayId, "home_score": $0.homeScore, "away_score": $0.awayScore, "status": $0.status, "scheduled_at": $0.scheduledAt, "video_quality": $0.videoQuality, "period_count": $0.periodCount, "period_duration_ms": $0.periodDurationMs, "current_period": $0.currentPeriod, "clock_remaining_ms": $0.clockRemainingMs, "created_at": $0.createdAt] as [String: Any] },
            "events": eventRows.sorted { $0.id < $1.id }.map { ["id": $0.id, "game_id": $0.gameId, "team_id": $0.teamId, "player_id": $0.playerId as Any? ?? NSNull(), "type": $0.type, "value": $0.value, "period": $0.period, "game_clock_ms": $0.gameClockMs, "segment": $0.segment, "segment_time_ms": $0.segmentTimeMs, "final_video_time_ms": $0.finalVideoTimeMs, "reverted": $0.reverted ? 1 : 0, "created_at": $0.createdAt] as [String: Any] },
            "segments": segmentRows.sorted { $0.id < $1.id }.map { ["id": $0.id, "game_id": $0.gameId, "sequence": $0.sequence, "uri": $0.uri, "duration_ms": $0.durationMs, "created_at": $0.createdAt] as [String: Any] },
            "deletions": pendingDeletions(),
        ]
    }

    /// Tombstones this device still has to push, newest last.
    func pendingDeletions() -> [[String: Any]] {
        deletionRows.sorted { $0.deletedAt < $1.deletedAt }.map { ["entity": $0.entity, "local_id": $0.localId, "deleted_at": $0.deletedAt, "device_id": $0.deviceId] }
    }

    func mergeSyncSnapshot(_ snapshot: [String: Any]) {
        func rows(_ key: String) -> [[String: Any]] { snapshot[key] as? [[String: Any]] ?? [] }
        func int(_ row: [String: Any], _ key: String) -> Int64 {
            if let value = row[key] as? Int64 { return value }
            if let value = row[key] as? Int { return Int64(value) }
            if let value = row[key] as? Double { return Int64(value) }
            if let value = row[key] as? String, let parsed = Int64(value) { return parsed }
            if let value = row[key] as? Bool { return value ? 1 : 0 }
            return 0
        }
        func str(_ row: [String: Any], _ key: String) -> String { (row[key] as? String) ?? (row[key].map { $0 is NSNull ? "" : "\($0)" } ?? "") }
        for row in rows("teams") {
            let team = Team(id: int(row, "id"), name: str(row, "name"), createdAt: int(row, "created_at"))
            if let index = teamRows.firstIndex(where: { $0.id == team.id }) { teamRows[index] = team } else { teamRows.append(team) }
        }
        for row in rows("players") {
            let player = Player(id: int(row, "id"), teamId: int(row, "team_id"), name: str(row, "name"), number: str(row, "number"))
            if let index = playerRows.firstIndex(where: { $0.id == player.id }) { playerRows[index] = player } else { playerRows.append(player) }
        }
        for row in rows("games") {
            let game = Game(id: int(row, "id"), title: str(row, "title"), homeId: int(row, "home_id"), awayId: int(row, "away_id"), homeScore: Int(int(row, "home_score")), awayScore: Int(int(row, "away_score")), status: str(row, "status"), scheduledAt: int(row, "scheduled_at"), videoQuality: str(row, "video_quality"), periodCount: Int(int(row, "period_count")), periodDurationMs: int(row, "period_duration_ms"), currentPeriod: Int(int(row, "current_period")), clockRemainingMs: int(row, "clock_remaining_ms"), createdAt: int(row, "created_at"))
            if let index = gameRows.firstIndex(where: { $0.id == game.id }) { gameRows[index] = game } else { gameRows.append(game) }
        }
        for row in rows("segments") {
            let segment = RecordingSegment(id: int(row, "id"), gameId: int(row, "game_id"), sequence: Int(int(row, "sequence")), uri: str(row, "uri"), durationMs: int(row, "duration_ms"), createdAt: int(row, "created_at"))
            if let index = segmentRows.firstIndex(where: { $0.id == segment.id }) { segmentRows[index] = segment } else { segmentRows.append(segment) }
        }
        for row in rows("events") {
            let playerId: Int64? = (row["player_id"] == nil || row["player_id"] is NSNull) ? nil : int(row, "player_id")
            let event = StatEvent(id: int(row, "id"), gameId: int(row, "game_id"), teamId: int(row, "team_id"), playerId: playerId, type: str(row, "type"), value: Int(int(row, "value")), period: Int(int(row, "period")), gameClockMs: int(row, "game_clock_ms"), segment: Int(int(row, "segment")), segmentTimeMs: int(row, "segment_time_ms"), finalVideoTimeMs: int(row, "final_video_time_ms"), reverted: int(row, "reverted") != 0, createdAt: int(row, "created_at"))
            if let index = eventRows.firstIndex(where: { $0.id == event.id }) { eventRows[index] = event } else { eventRows.append(event) }
        }
        for row in rows("deletions") {
            let deletion = Deletion(entity: str(row, "entity"), localId: int(row, "local_id"), deletedAt: int(row, "deleted_at"), deviceId: str(row, "device_id"))
            deletionRows.removeAll { $0.entity == deletion.entity && $0.localId == deletion.localId }
            deletionRows.append(deletion)
        }
        applyDeletions()
        save()
    }

    /// Replays every tombstone this device knows about, so a game deleted elsewhere disappears here too.
    private func applyDeletions() {
        for (entity, _) in deletableEntities {
            let ids = Set(deletionRows.filter { $0.entity == entity }.map(\.localId))
            guard !ids.isEmpty else { continue }
            switch entity {
            case "teams": teamRows.removeAll { ids.contains($0.id) }
            case "players": playerRows.removeAll { ids.contains($0.id) }
            case "games": gameRows.removeAll { ids.contains($0.id) }
            case "events": eventRows.removeAll { ids.contains($0.id) }
            case "segments": segmentRows.removeAll { ids.contains($0.id) }
            default: break
            }
        }
    }

    // MARK: - Legacy store migration

    private struct LegacyTeam: Decodable { var id: UUID; var name: String; var players: [LegacyPlayer] }
    private struct LegacyPlayer: Decodable { var id: UUID; var name: String; var number: String }
    private struct LegacyGame: Decodable {
        var id: UUID?; var home: LegacyTeam; var away: LegacyTeam; var scheduledAt: Date; var periodCount: Int; var periodMinutes: Int
        var homeScore: Int?; var awayScore: Int?; var status: String?; var videoQuality: String?; var currentPeriod: Int?; var currentClockSeconds: Int?
    }
    private struct LegacyEvent: Decodable { var id: UUID; var gameID: UUID; var teamID: UUID; var playerID: UUID?; var type: String; var value: Int; var period: Int; var clockSeconds: Int; var createdAt: Date? }
    private struct LegacySnapshot: Decodable { var teams: [LegacyTeam]; var games: [LegacyGame]; var events: [LegacyEvent] }

    /// The previous iOS store kept UUIDs; they are mapped with the same function the old sync used, so
    /// rows already uploaded from this device keep their cloud ids.
    private func migrateLegacy(_ data: Data) {
        guard let snapshot = try? JSONDecoder().decode(LegacySnapshot.self, from: data) else { return }
        func cloudID(_ uuid: UUID) -> Int64 {
            let parts = uuid.uuidString.split(separator: "-")
            if parts.count == 5, parts[1] == "0000", parts[2] == "0000", parts[3] == "0000",
               let high = Int64(parts[0], radix: 16), let low = Int64(parts[4], radix: 16) { return (high << 48) | low }
            var hash: UInt64 = 14_695_981_039_346_656_037
            uuid.uuidString.utf8.forEach { hash = (hash ^ UInt64($0)) &* 1_099_511_628_211 }
            return Int64(hash & 0x001F_FFFF_FFFF_FFFF)
        }
        let now = nowMs()
        var teams: [Team] = []
        var players: [Player] = []
        func absorb(_ team: LegacyTeam) {
            let id = cloudID(team.id)
            if !teams.contains(where: { $0.id == id }) { teams.append(Team(id: id, name: team.name, createdAt: now)) }
            for player in team.players where !players.contains(where: { $0.id == cloudID(player.id) }) {
                players.append(Player(id: cloudID(player.id), teamId: id, name: player.name, number: player.number))
            }
        }
        snapshot.teams.forEach(absorb)
        snapshot.games.forEach { absorb($0.home); absorb($0.away) }
        teamRows = teams; playerRows = players
        gameRows = snapshot.games.map { game in
            let quality = game.videoQuality == "DEVICE_MAX" ? "HIGHEST" : (game.videoQuality ?? "HIGHEST")
            let durationMs = Int64(game.periodMinutes) * 60_000
            let clock = (game.currentClockSeconds ?? 0) > 0 ? Int64(game.currentClockSeconds ?? 0) * 1000 : durationMs
            return Game(id: cloudID(game.id ?? UUID()), title: "\(game.home.name) vs \(game.away.name)", homeId: cloudID(game.home.id), awayId: cloudID(game.away.id), homeScore: game.homeScore ?? 0, awayScore: game.awayScore ?? 0, status: game.status == "IN_PROGRESS" ? "PAUSED" : (game.status ?? "READY"), scheduledAt: Int64(game.scheduledAt.timeIntervalSince1970 * 1000), videoQuality: quality, periodCount: game.periodCount, periodDurationMs: durationMs, currentPeriod: game.currentPeriod ?? 1, clockRemainingMs: clock, createdAt: now)
        }
        eventRows = snapshot.events.map { event in
            StatEvent(id: cloudID(event.id), gameId: cloudID(event.gameID), teamId: cloudID(event.teamID), playerId: event.playerID.map(cloudID), type: event.type, value: event.value, period: event.period, gameClockMs: Int64(event.clockSeconds) * 1000, segment: 0, segmentTimeMs: 0, finalVideoTimeMs: 0, reverted: false, createdAt: Int64((event.createdAt ?? Date()).timeIntervalSince1970 * 1000))
        }
        loading = false
        save()
        loading = true
    }
}

// MARK: - Shared helpers used by every screen

/// Types that move the scoreboard: made shots, free throws, and manual +1/-1 adjustments.
func isScoringType(_ type: String) -> Bool { type.hasPrefix("PTS_") || type == "FT_MADE" || type == "ADJ" }
func eventPoints(_ type: String, _ value: Int) -> Int { isScoringType(type) ? value : 0 }

func formatClock(_ ms: Int64) -> String { String(format: "%02d:%02d", ms / 60000, (ms / 1000) % 60) }

func formatGameDateTime(_ timestamp: Int64) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d, yyyy  h:mm a"
    return formatter.string(from: Date(timeIntervalSince1970: Double(timestamp) / 1000))
}

/// Numbered players first by jersey number, then players without a number by first name.
enum PlayerSort: String, CaseIterable {
    case first, last, number
    var label: String { switch self { case .first: "First name"; case .last: "Last name"; case .number: "Jersey number" } }
}

private var playerSortPreference: PlayerSort {
    get { PlayerSort(rawValue: UserDefaults.standard.string(forKey: "player_sort") ?? "number") ?? .number }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: "player_sort") }
}
func savedPlayerSort() -> PlayerSort { playerSortPreference }
func savePlayerSort(_ sort: PlayerSort) { playerSortPreference = sort }

func rosterOrder(_ players: [Player]) -> [Player] {
    players.sorted { a, b in
        if playerSortPreference == .first {
            return firstNameOf(a.name).localizedCaseInsensitiveCompare(firstNameOf(b.name)) == .orderedAscending || (firstNameOf(a.name).localizedCaseInsensitiveCompare(firstNameOf(b.name)) == .orderedSame && a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending)
        }
        if playerSortPreference == .last {
            let lastA = lastNameOf(a.name), lastB = lastNameOf(b.name)
            return lastA.localizedCaseInsensitiveCompare(lastB) == .orderedAscending || (lastA.localizedCaseInsensitiveCompare(lastB) == .orderedSame && firstNameOf(a.name).localizedCaseInsensitiveCompare(firstNameOf(b.name)) == .orderedAscending)
        }
        let aBlank = a.number.isBlank, bBlank = b.number.isBlank
        if aBlank != bBlank { return !aBlank }
        let aNumber = Int(a.number.trimmed) ?? Int.max, bNumber = Int(b.number.trimmed) ?? Int.max
        if aNumber != bNumber { return aNumber < bNumber }
        let aFirst = firstNameOf(a.name).lowercased(), bFirst = firstNameOf(b.name).lowercased()
        if aFirst != bFirst { return aFirst < bFirst }
        return a.name.lowercased() < b.name.lowercased()
    }
}

func firstNameOf(_ name: String) -> String { String(name.trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).first ?? "").trimmed }
func lastNameOf(_ name: String) -> String {
    let parts = name.trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
    return parts.count > 1 ? String(parts[1]).trimmed : ""
}
func fullName(_ first: String, _ last: String) -> String { [first.trimmed, last.trimmed].filter { !$0.isEmpty }.joined(separator: " ") }

/// "Period 3" within the scheduled count, "OT 1" for overtime periods beyond it.
func periodLabel(_ period: Int, _ periodCount: Int) -> String { period > periodCount ? "OT \(period - periodCount)" : "Period \(period)" }
/// Compact form for the timeline and PDF: "Q3", or "OT1" past the scheduled periods.
func periodShortLabel(_ period: Int, _ periodCount: Int) -> String { period > periodCount ? "OT\(period - periodCount)" : "Q\(period)" }

func eventLabel(_ event: StatEvent) -> String {
    switch event.type {
    case "STARTER": return "Starter"
    case "PTS_1", "FT_MADE": return "Free throw made"
    case "PTS_2": return "2-point field goal made"
    case "PTS_3": return "3-point field goal made"
    case "MISS_2": return "2-point field goal missed"
    case "MISS_3": return "3-point field goal missed"
    case "FT_MISS": return "Free throw missed"
    case "FOULED", "FOUL_DRAWN": return "Foul drawn"
    case "REB": return "Rebound"
    case "AST": return "Assist"
    case "STL": return "Steal"
    case "BLK": return "Block"
    case "TOV": return "Turnover"
    case "FOUL": return "Foul"
    case "SUB_OUT": return "Substitution out"
    case "SUB_IN": return "Substitution in"
    case "ADJ": return "Score adjustment"
    case "VIDEO": return "Recording saved (\(formatClock(Int64(event.value) * 1000)))"
    default: return event.type.replacingOccurrences(of: "_", with: " ").lowercased().capitalizeInitial()
    }
}

/// Short labels for the timeline, where the line must also fit the player's number and name.
func eventShortLabel(_ event: StatEvent) -> String {
    switch event.type {
    case "STARTER": return "Starter"
    case "PTS_1", "FT_MADE": return "FT made"
    case "PTS_2": return "2PT made"
    case "PTS_3": return "3PT made"
    case "MISS_2": return "2PT missed"
    case "MISS_3": return "3PT missed"
    case "FT_MISS": return "FT missed"
    case "FOULED", "FOUL_DRAWN": return "Foul drawn"
    case "REB": return "REB"
    case "AST": return "AST"
    case "STL": return "STL"
    case "BLK": return "BLK"
    case "TOV": return "TO"
    case "FOUL": return "Foul"
    case "SUB_OUT": return "Sub out"
    case "SUB_IN": return "Sub in"
    case "ADJ": return "Adjust"
    case "VIDEO": return "Video \(formatClock(Int64(event.value) * 1000))"
    default: return eventLabel(event)
    }
}

func shootingPercent(_ made: Int, _ attempts: Int) -> String { attempts == 0 ? "—" : String(format: "%.1f%%", Double(made) * 100 / Double(attempts)) }

/// Free throws come from their own event types rather than the field-goal ones.
func freeThrows(_ events: [StatEvent]) -> (Int, Int, String) {
    let made = events.filter { $0.type == "FT_MADE" }.count
    let attempts = made + events.filter { $0.type == "FT_MISS" }.count
    return (made, attempts, shootingPercent(made, attempts))
}
/// Two- and three-pointers are counted separately: made are PTS_n, misses are MISS_n.
func fieldGoals(_ events: [StatEvent], _ points: Int) -> (Int, Int, String) {
    let made = events.filter { $0.type == "PTS_\(points)" }.count
    let attempts = made + events.filter { $0.type == "MISS_\(points)" }.count
    return (made, attempts, shootingPercent(made, attempts))
}
