import Foundation
import Combine
import Photos
import Security

// Data layer mirroring the Android HoopDb: the same tables (team, player, game, event,
// player_game_stat, segment, deletion) and the same deletion tombstones, so sync and exports are
// interchangeable. Every row is keyed by a client-generated UUIDv7 string; a store written by an
// older build keeps its integer ids as `legacy:<n>` placeholders until the first signed-in sync
// maps them onto the server's ids (HoopSync.adoptLegacyIds).
//
// `ownerId` is nil for this account's own rows and the owner's user id for rows of a game someone
// shared with this account; those are read-only copies that are never pushed.

typealias RowID = String

private let idLock = NSLock()
private var lastIdMs: Int64 = 0

/// A new lowercase UUIDv7: 48-bit Unix ms prefix, so string order is creation order on this device.
func newRowId() -> RowID {
    idLock.lock()
    let ms = max(nowMs(), lastIdMs + 1)
    lastIdMs = ms
    idLock.unlock()
    var bytes = [UInt8](repeating: 0, count: 16)
    if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255, using: &generator) }
    }
    for index in 0..<6 { bytes[index] = UInt8(truncatingIfNeeded: ms >> (8 * (5 - index))) }
    bytes[6] = (bytes[6] & 0x0f) | 0x70
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    let hex = bytes.map { String(format: "%02x", $0) }.joined()
    let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in
        String(hex[hex.index(hex.startIndex, offsetBy: range.lowerBound)..<hex.index(hex.startIndex, offsetBy: range.upperBound)])
    }
    return parts.joined(separator: "-")
}

let legacyIdPrefix = "legacy:"
func isLegacyId(_ id: RowID) -> Bool { id.hasPrefix(legacyIdPrefix) }

struct Team: Identifiable, Codable, Hashable {
    var id: RowID
    var name: String
    var createdAt: Int64 = 0
    var ownerId: String? = nil
    var syncSpace: String? = nil
}

struct Player: Identifiable, Codable, Hashable {
    var id: RowID
    var teamId: RowID
    var name: String
    var number: String
    var ownerId: String? = nil
    var syncSpace: String? = nil

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
    var id: RowID
    var title: String
    var homeId: RowID
    var awayId: RowID
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
    var ownerId: String? = nil
    var syncSpace: String? = nil
    // Joined from the team table when the game is read, never stored.
    var homeName = ""
    var awayName = ""

    /// A game someone else shared with this account: a read-only copy.
    var isShared: Bool { ownerId != nil }

    enum CodingKeys: String, CodingKey { case id, title, homeId, awayId, homeScore, awayScore, status, scheduledAt, videoQuality, periodCount, periodDurationMs, currentPeriod, clockRemainingMs, createdAt, ownerId, syncSpace }
}

struct StatEvent: Identifiable, Codable, Hashable {
    var id: RowID
    var gameId: RowID
    var teamId: RowID
    var playerId: RowID?
    var type: String
    var value: Int
    var period: Int
    var gameClockMs: Int64
    var segment: Int
    var segmentTimeMs: Int64
    var finalVideoTimeMs: Int64
    var reverted: Bool
    var createdAt: Int64 = 0
    var ownerId: String? = nil
    var syncSpace: String? = nil
}

struct RecordingSegment: Identifiable, Codable, Hashable {
    var id: RowID
    var gameId: RowID
    var sequence: Int
    var uri: String
    var durationMs: Int64
    var createdAt: Int64
    var ownerId: String? = nil
    var syncSpace: String? = nil
}

struct Deletion: Codable, Hashable {
    var entity: String
    var rowId: RowID
    var deletedAt: Int64
    var deviceId: String
}

struct PlayerGameStat: Codable, Hashable {
    var gameId: RowID
    var playerId: RowID
    var minutesMs: Int64
    var plusMinus: Int
}

struct GameImport {
    var gameId: RowID
    var events: Int
    var createdTeams: Int
    var createdPlayers: Int
}

let gameExportKind = "hoopreplay.game"
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
            if let data = try? Data(contentsOf: fileURL), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: Self.upgradedSnapshotData(data)) {
                teamRows = snapshot.teams; playerRows = snapshot.players; gameRows = snapshot.games; eventRows = snapshot.events
                segmentRows = snapshot.segments; deletionRows = snapshot.deletions; statRows = snapshot.stats
            } else if let data = try? Data(contentsOf: legacyFileURL) {
                migrateLegacy(data)
            }
        }
        loading = false
    }

    /**
     Stores written before UUID row ids hold integer ids and references. Each becomes the placeholder
     `legacy:<n>`, which keeps every relationship and stays unique on this device until the first
     signed-in sync swaps it for the server's id. The old tombstone key `localId` becomes `rowId`.
     */
    static func upgradedSnapshotData(_ data: Data) -> Data {
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data }
        let idKeys = ["id", "teamId", "homeId", "awayId", "gameId", "playerId", "rowId"]
        var changed = false
        for (table, value) in root {
            guard let rows = value as? [[String: Any]] else { continue }
            root[table] = rows.map { original -> [String: Any] in
                var row = original
                if let local = row.removeValue(forKey: "localId") { row["rowId"] = local; changed = true }
                for key in idKeys {
                    if let number = row[key] as? NSNumber { row[key] = legacyIdPrefix + String(number.int64Value); changed = true }
                }
                return row
            }
        }
        return changed ? (try? JSONSerialization.data(withJSONObject: root)) ?? data : data
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

    /// Forgets every synced row and tombstone (sign-out, or another account signing in on this phone).
    /// Recordings stay in Photos / the Recordings folder; they belong to the phone's user.
    func clearLocalRows() {
        teamRows.removeAll(); playerRows.removeAll(); gameRows.removeAll(); eventRows.removeAll()
        segmentRows.removeAll(); deletionRows.removeAll(); statRows.removeAll(); save()
    }

    /// Clears all locally cached account data after the server confirms deletion.
    @MainActor func clearAllAccountData() async {
        let assetIds = segmentRows.filter { $0.ownerId == nil }.compactMap { uri -> String? in
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
        clearLocalRows()
        let fm = FileManager.default
        try? fm.removeItem(at: documents.appendingPathComponent("Recordings", isDirectory: true))
    }

    // MARK: - Deletions

    /**
     A deletion has to be recorded, never inferred from a row's absence: sync used to push only the
     rows this device still had, so nothing ever told the other devices that a game was gone.
     Ids are never reused, so a tombstone always wins over a row with the same id.
     */
    private func deviceId() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: "device_id") { return existing }
        let created = "ios-" + UUID().uuidString.lowercased()
        defaults.set(created, forKey: "device_id")
        return created
    }
    private func recordDeletions(_ entity: String, _ ids: [RowID]) {
        guard !ids.isEmpty else { return }
        let deletedAt = nowMs()
        let device = deviceId()
        for id in ids where !deletionRows.contains(where: { $0.entity == entity && $0.rowId == id }) {
            deletionRows.append(Deletion(entity: entity, rowId: id, deletedAt: deletedAt, deviceId: device))
        }
    }

    // MARK: - Teams

    @discardableResult
    func addTeam(_ name: String) -> RowID {
        let id = newRowId()
        teamRows.append(Team(id: id, name: name.capitalizeInitial(), createdAt: nowMs()))
        save()
        return id
    }
    /// Creation order; legacy placeholders and UUIDv7s both follow createdAt.
    func teams() -> [Team] { teamRows.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) } }
    /// Teams this account owns: the only ones a new game, an import or a roster edit may use.
    func ownTeams() -> [Team] { teams().filter { $0.ownerId == nil } }
    func team(_ id: RowID) -> Team? { teamRows.first { $0.id == id } }
    func deleteTeam(_ id: RowID) -> Bool {
        guard team(id)?.ownerId == nil else { return false }
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

    func findPlayer(_ team: RowID, name: String, number: String) -> Player? {
        let cleanName = name.capitalizeInitial().trimmed
        let cleanNumber = number.trimmed
        let roster = players(team)
        if !cleanNumber.isEmpty { return roster.first { $0.number.trimmed == cleanNumber } }
        return roster.first { $0.number.isBlank && !cleanName.isEmpty && $0.name.caseInsensitiveCompare(cleanName) == .orderedSame }
    }
    /// Reuses the existing player when the jersey number (or the name, for unnumbered players) already exists on the team.
    @discardableResult
    func addPlayer(_ team: RowID, name: String, number: String) -> RowID {
        if let existing = findPlayer(team, name: name, number: number) { return existing.id }
        let id = newRowId()
        playerRows.append(Player(id: id, teamId: team, name: name.capitalizeInitial(), number: number))
        save()
        return id
    }
    func players(_ team: RowID) -> [Player] {
        playerRows.filter { $0.teamId == team }.sorted { (Int($0.number.trimmed) ?? 0, $0.id) < (Int($1.number.trimmed) ?? 0, $1.id) }
    }
    func player(_ id: RowID) -> Player? { playerRows.first { $0.id == id } }
    /// Renames a player / changes their jersey number in place, so recorded stats stay attached.
    func updatePlayer(_ id: RowID, name: String, number: String) {
        guard let index = playerRows.firstIndex(where: { $0.id == id && $0.ownerId == nil }) else { return }
        playerRows[index].name = name.trimmed.capitalizeInitial()
        playerRows[index].number = number.trimmed
        save()
    }
    func playerHasEvents(_ id: RowID) -> Bool { eventRows.contains { $0.playerId == id } }
    @discardableResult
    func deletePlayer(_ id: RowID) -> Bool {
        guard player(id)?.ownerId == nil else { return false }
        recordDeletions("players", [id])
        for index in eventRows.indices where eventRows[index].playerId == id { eventRows[index].playerId = nil }
        let before = playerRows.count
        playerRows.removeAll { $0.id == id }
        save()
        return playerRows.count < before
    }

    // MARK: - Games

    @discardableResult
    func addGame(title: String, home: RowID, away: RowID, scheduledAt: Int64, videoQuality: String, periodCount: Int, periodDurationMs: Int64) -> RowID {
        let id = newRowId()
        gameRows.append(Game(id: id, title: title, homeId: home, awayId: away, status: "READY", scheduledAt: scheduledAt, videoQuality: videoQuality, periodCount: periodCount, periodDurationMs: periodDurationMs, currentPeriod: 1, clockRemainingMs: periodDurationMs, createdAt: nowMs()))
        save()
        return id
    }
    func updateGame(_ id: RowID, title: String, home: RowID, away: RowID, scheduledAt: Int64, videoQuality: String, periodCount: Int, periodDurationMs: Int64) {
        guard let index = gameRows.firstIndex(where: { $0.id == id && $0.ownerId == nil }) else { return }
        let oldDuration = gameRows[index].periodDurationMs
        let wasAtPeriodStart = gameRows[index].currentPeriod == 1 && gameRows[index].clockRemainingMs == oldDuration
        gameRows[index].title = title; gameRows[index].homeId = home; gameRows[index].awayId = away
        gameRows[index].scheduledAt = scheduledAt; gameRows[index].videoQuality = videoQuality
        gameRows[index].periodCount = periodCount; gameRows[index].periodDurationMs = periodDurationMs
        if wasAtPeriodStart { gameRows[index].clockRemainingMs = periodDurationMs }
        save()
    }
    /// Games with both teams resolved (the SQL join), newest first. Never ordered by id: legacy
    /// games kept random ids.
    func games() -> [Game] {
        gameRows.compactMap { row -> Game? in
            guard let home = team(row.homeId), let away = team(row.awayId) else { return nil }
            var game = row; game.homeName = home.name; game.awayName = away.name
            return game
        }.sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
    }
    func game(_ id: RowID) -> Game? { games().first { $0.id == id } }
    @discardableResult
    func deleteGame(_ id: RowID) -> Bool {
        let own = gameRows.first { $0.id == id }?.ownerId == nil
        if own {
            recordDeletions("events", eventRows.filter { $0.gameId == id }.map(\.id))
            recordDeletions("segments", segmentRows.filter { $0.gameId == id }.map(\.id))
            recordDeletions("games", [id])
        }
        eventRows.removeAll { $0.gameId == id }
        segmentRows.removeAll { $0.gameId == id }
        statRows.removeAll { $0.gameId == id }
        let before = gameRows.count
        gameRows.removeAll { $0.id == id }
        save()
        return gameRows.count < before
    }
    private func updateGame(_ id: RowID, _ change: (inout Game) -> Void) {
        guard let index = gameRows.firstIndex(where: { $0.id == id }) else { return }
        change(&gameRows[index])
        save()
    }
    func status(_ id: RowID, _ value: String) { updateGame(id) { $0.status = value } }
    /// Restores the exported scoreboard and clock on a freshly imported game.
    func updateImportedGame(_ id: RowID, homeScore: Int, awayScore: Int, status: String, currentPeriod: Int, clockRemainingMs: Int64) {
        updateGame(id) { $0.homeScore = homeScore; $0.awayScore = awayScore; $0.status = status; $0.currentPeriod = currentPeriod; $0.clockRemainingMs = clockRemainingMs }
    }
    func videoQuality(_ id: RowID, _ value: String) { updateGame(id) { $0.videoQuality = value } }
    func saveProgress(_ id: RowID, period: Int, clockRemainingMs: Int64) { updateGame(id) { $0.currentPeriod = period; $0.clockRemainingMs = clockRemainingMs } }
    func score(_ game: Game, homeDelta: Int, awayDelta: Int) {
        updateGame(game.id) { $0.homeScore = max(0, $0.homeScore + homeDelta); $0.awayScore = max(0, $0.awayScore + awayDelta) }
    }
    /// Keeps the persisted scoreboard in sync with the same active scoring events used by stats.
    func recalculateScore(_ gameId: RowID) {
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
    func addEvent(gameId: RowID, teamId: RowID, playerId: RowID?, type: String, value: Int, period: Int, clock: Int64, segment: Int, segmentMs: Int64, videoMs: Int64) -> RowID {
        startSegment(gameId, sequence: segment)
        let id = newRowId()
        eventRows.append(StatEvent(id: id, gameId: gameId, teamId: teamId, playerId: playerId, type: type, value: value, period: period, gameClockMs: clock, segment: segment, segmentTimeMs: segmentMs, finalVideoTimeMs: videoMs, reverted: false, createdAt: nowMs()))
        save()
        return id
    }
    func undo(_ gameId: RowID) -> StatEvent? {
        guard let last = events(gameId).last(where: { !$0.reverted }), let index = eventRows.firstIndex(where: { $0.id == last.id }) else { return nil }
        eventRows[index].reverted = true
        save()
        return eventRows[index]
    }
    func revertEvent(_ id: RowID) {
        guard let index = eventRows.firstIndex(where: { $0.id == id }) else { return }
        eventRows[index].reverted = true
        save()
    }
    func updateEvent(_ id: RowID, playerId: RowID?, type: String, value: Int, period: Int? = nil, gameClockMs: Int64? = nil) {
        guard let index = eventRows.firstIndex(where: { $0.id == id }) else { return }
        eventRows[index].playerId = playerId
        eventRows[index].type = type
        eventRows[index].value = value
        if let period { eventRows[index].period = period }
        if let gameClockMs { eventRows[index].gameClockMs = gameClockMs }
        save()
    }
    /// Recording order: createdAt, then the time-ordered id for plays stamped in the same millisecond.
    func events(_ gameId: RowID) -> [StatEvent] { eventRows.filter { $0.gameId == gameId }.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) } }
    func activeEvents(_ gameId: RowID) -> [StatEvent] { events(gameId).filter { !$0.reverted } }

    // MARK: - Minutes and plus/minus

    func playerGameStats(_ gameId: RowID) -> [RowID: (Int64, Int)] {
        var result: [RowID: (Int64, Int)] = [:]
        for row in statRows where row.gameId == gameId { result[row.playerId] = (row.minutesMs, row.plusMinus) }
        return result
    }
    func recalculatePlayerGameStats(_ game: Game) {
        let es = activeEvents(game.id).sorted { ($0.period, -$0.gameClockMs, $0.createdAt, $0.id) < ($1.period, -$1.gameClockMs, $1.createdAt, $1.id) }
        // Only recorded STARTER events open a period for a player: a stat never implies that the
        // player was on the floor, so minutes come solely from STARTER / SUB_IN / SUB_OUT history.
        func starters(_ teamId: RowID, _ period: Int) -> Set<RowID> {
            var seen: [RowID] = []
            for e in es where e.teamId == teamId && e.period == period && e.type == "STARTER" {
                if let p = e.playerId, !seen.contains(p) { seen.append(p) }
            }
            return Set(seen.prefix(5))
        }
        var minutes: [RowID: Int64] = [:]
        var plusMinus: [RowID: Int] = [:]
        let periods = Array(Set(es.map(\.period))).sorted()
        for teamId in [game.homeId, game.awayId] {
            for period in periods {
                var onCourt = starters(teamId, period)
                var entered: [RowID: Int64] = [:]
                for p in onCourt { entered[p] = game.periodDurationMs }
                for e in es where e.period == period {
                    if e.teamId == teamId && e.type == "SUB_IN", let p = e.playerId {
                        let pairedClock = es.filter { $0.type == "SUB_OUT" && $0.teamId == e.teamId && $0.period == e.period && $0.gameClockMs >= e.gameClockMs && $0.gameClockMs - e.gameClockMs <= 5_000 }
                            .min { ($0.gameClockMs, abs($0.createdAt - e.createdAt)) < ($1.gameClockMs, abs($1.createdAt - e.createdAt)) }?.gameClockMs ?? e.gameClockMs
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
    func startSegment(_ gameId: RowID, sequence: Int) -> RowID {
        if let existing = segmentRows.first(where: { $0.gameId == gameId && $0.sequence == sequence }) { return existing.id }
        let id = newRowId()
        segmentRows.append(RecordingSegment(id: id, gameId: gameId, sequence: sequence, uri: "", durationMs: 0, createdAt: nowMs()))
        save()
        return id
    }
    func finalizeSegment(_ id: RowID, uri: String, durationMs: Int64) {
        guard let index = segmentRows.firstIndex(where: { $0.id == id && $0.ownerId == nil }) else { return }
        segmentRows[index].uri = uri; segmentRows[index].durationMs = durationMs
        save()
    }
    /// Segments whose recording never finalized (a crash mid-recording leaves the uri empty).
    func orphanSegments(_ gameId: RowID) -> [(RowID, Int)] { segmentRows.filter { $0.gameId == gameId && $0.ownerId == nil && $0.uri.isEmpty }.map { ($0.id, $0.sequence) } }

    // MARK: - Sync snapshots (the same JSON rows the Android app exchanges with the server)

    /// True while any row, reference or tombstone still carries a pre-UUID `legacy:` placeholder.
    var hasLegacyIds: Bool {
        teamRows.contains { isLegacyId($0.id) }
            || playerRows.contains { isLegacyId($0.id) || isLegacyId($0.teamId) }
            || gameRows.contains { isLegacyId($0.id) || isLegacyId($0.homeId) || isLegacyId($0.awayId) }
            || eventRows.contains { isLegacyId($0.id) || isLegacyId($0.gameId) || isLegacyId($0.teamId) || $0.playerId.map(isLegacyId) == true }
            || segmentRows.contains { isLegacyId($0.id) || isLegacyId($0.gameId) }
            || deletionRows.contains { isLegacyId($0.rowId) }
    }

    /**
     The rows this account may push: its own rows whose parents are its own too. Shared games (and
     their teams, players, plays and recordings) are read-only copies and never leave the phone.
     */
    func exportSyncSnapshot() -> [String: Any] {
        let teams = teamRows.filter { $0.ownerId == nil }.sorted { $0.id < $1.id }
        let teamIds = Set(teams.map(\.id))
        let players = playerRows.filter { $0.ownerId == nil && teamIds.contains($0.teamId) }.sorted { $0.id < $1.id }
        let playerIds = Set(players.map(\.id))
        let games = gameRows.filter { $0.ownerId == nil && teamIds.contains($0.homeId) && teamIds.contains($0.awayId) }.sorted { $0.id < $1.id }
        let gameIds = Set(games.map(\.id))
        return [
            "schemaVersion": 3,
            "updatedAt": nowMs(),
            "teams": teams.map { ["id": $0.id, "name": $0.name, "created_at": $0.createdAt] as [String: Any] },
            "players": players.map { ["id": $0.id, "team_id": $0.teamId, "name": $0.name, "number": $0.number] as [String: Any] },
            "games": games.map { ["id": $0.id, "title": $0.title, "home_id": $0.homeId, "away_id": $0.awayId, "home_score": $0.homeScore, "away_score": $0.awayScore, "status": $0.status, "scheduled_at": $0.scheduledAt, "video_quality": $0.videoQuality, "period_count": $0.periodCount, "period_duration_ms": $0.periodDurationMs, "current_period": $0.currentPeriod, "clock_remaining_ms": $0.clockRemainingMs, "created_at": $0.createdAt] as [String: Any] },
            "events": eventRows.filter { $0.ownerId == nil && gameIds.contains($0.gameId) }.sorted { $0.id < $1.id }.map { event -> [String: Any] in
                let player: Any = event.playerId.flatMap { playerIds.contains($0) ? $0 : nil } ?? NSNull()
                return ["id": event.id, "game_id": event.gameId, "team_id": event.teamId, "player_id": player, "type": event.type, "value": event.value, "period": event.period, "game_clock_ms": event.gameClockMs, "segment": event.segment, "segment_time_ms": event.segmentTimeMs, "final_video_time_ms": event.finalVideoTimeMs, "reverted": event.reverted ? 1 : 0, "created_at": event.createdAt]
            },
            "segments": segmentRows.filter { $0.ownerId == nil && gameIds.contains($0.gameId) }.sorted { $0.id < $1.id }.map { ["id": $0.id, "game_id": $0.gameId, "sequence": $0.sequence, "uri": $0.uri, "duration_ms": $0.durationMs, "created_at": $0.createdAt] as [String: Any] },
            "deletions": pendingDeletions(),
        ]
    }

    /// Tombstones this device still has to push, newest last. Unmapped legacy ones cannot be named on the server.
    func pendingDeletions() -> [[String: Any]] {
        deletionRows.filter { !isLegacyId($0.rowId) }.sorted { $0.deletedAt < $1.deletedAt }.map { ["entity": $0.entity, "row_id": $0.rowId, "deleted_at": $0.deletedAt, "device_id": $0.deviceId] }
    }

    /**
     Merges a full pull. Every row keeps its owner: `user_id == ownUserId` rows are this account's
     (ownerId nil), anything else is a read-only copy of a shared game. The pull is the complete
     set of shared rows, so shared rows it no longer returns are dropped. A shared row never
     replaces one of this account's rows, and a tombstone always wins.
     */
    func mergeSyncSnapshot(_ snapshot: [String: Any], ownUserId: String) {
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
        func id(_ row: [String: Any], _ key: String) -> RowID { str(row, key).lowercased() }
        func owner(_ row: [String: Any]) -> String? { let user = str(row, "user_id"); return user.isEmpty || user == ownUserId ? nil : user }
        func space(_ row: [String: Any]) -> String? { let value = str(row, "sync_space"); return value.isEmpty ? nil : value }
        func upsert<Row: Identifiable>(_ list: inout [Row], _ row: Row, ownerOf: (Row) -> String?) where Row.ID == RowID {
            if let index = list.firstIndex(where: { $0.id == row.id }) {
                if ownerOf(list[index]) == nil && ownerOf(row) != nil { return }
                list[index] = row
            } else { list.append(row) }
        }
        teamRows.removeAll { $0.ownerId != nil }; playerRows.removeAll { $0.ownerId != nil }; gameRows.removeAll { $0.ownerId != nil }
        eventRows.removeAll { $0.ownerId != nil }; segmentRows.removeAll { $0.ownerId != nil }
        for row in rows("teams") {
            upsert(&teamRows, Team(id: id(row, "id"), name: str(row, "name"), createdAt: int(row, "created_at"), ownerId: owner(row), syncSpace: space(row)), ownerOf: \.ownerId)
        }
        for row in rows("players") {
            upsert(&playerRows, Player(id: id(row, "id"), teamId: id(row, "team_id"), name: str(row, "name"), number: str(row, "number"), ownerId: owner(row), syncSpace: space(row)), ownerOf: \.ownerId)
        }
        for row in rows("games") {
            let game = Game(id: id(row, "id"), title: str(row, "title"), homeId: id(row, "home_id"), awayId: id(row, "away_id"), homeScore: Int(int(row, "home_score")), awayScore: Int(int(row, "away_score")), status: str(row, "status"), scheduledAt: int(row, "scheduled_at"), videoQuality: str(row, "video_quality"), periodCount: Int(int(row, "period_count")), periodDurationMs: int(row, "period_duration_ms"), currentPeriod: Int(int(row, "current_period")), clockRemainingMs: int(row, "clock_remaining_ms"), createdAt: int(row, "created_at"), ownerId: owner(row), syncSpace: space(row))
            upsert(&gameRows, game, ownerOf: \.ownerId)
        }
        for row in rows("segments") {
            upsert(&segmentRows, RecordingSegment(id: id(row, "id"), gameId: id(row, "game_id"), sequence: Int(int(row, "sequence")), uri: str(row, "uri"), durationMs: int(row, "duration_ms"), createdAt: int(row, "created_at"), ownerId: owner(row), syncSpace: space(row)), ownerOf: \.ownerId)
        }
        for row in rows("events") {
            let playerId: RowID? = (row["player_id"] == nil || row["player_id"] is NSNull) ? nil : id(row, "player_id")
            let event = StatEvent(id: id(row, "id"), gameId: id(row, "game_id"), teamId: id(row, "team_id"), playerId: playerId, type: str(row, "type"), value: Int(int(row, "value")), period: Int(int(row, "period")), gameClockMs: int(row, "game_clock_ms"), segment: Int(int(row, "segment")), segmentTimeMs: int(row, "segment_time_ms"), finalVideoTimeMs: int(row, "final_video_time_ms"), reverted: int(row, "reverted") != 0, createdAt: int(row, "created_at"), ownerId: owner(row), syncSpace: space(row))
            upsert(&eventRows, event, ownerOf: \.ownerId)
        }
        for row in rows("deletions") {
            let deletion = Deletion(entity: str(row, "entity"), rowId: id(row, "row_id"), deletedAt: int(row, "deleted_at"), deviceId: str(row, "device_id"))
            if !deletionRows.contains(where: { $0.entity == deletion.entity && $0.rowId == deletion.rowId }) { deletionRows.append(deletion) }
        }
        applyDeletions()
        let gameIds = Set(gameRows.map(\.id))
        statRows.removeAll { !gameIds.contains($0.gameId) }
        save()
    }

    /// Replays every tombstone this device knows about, so a game deleted elsewhere disappears here too.
    private func applyDeletions() {
        for entity in ["teams", "players", "games", "events", "segments"] {
            let ids = Set(deletionRows.filter { $0.entity == entity }.map(\.rowId))
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

    /**
     One-time upgrade of `legacy:<n>` placeholders (contract rule 6b). `mapped[table][n]` is the
     server id of this account's row that used to be local id n, `tombstoned[table]` the legacy ids
     the server has a tombstone for. Mapped ids (and every reference to them) take the server id,
     tombstoned rows are removed, and anything left over gets a fresh UUIDv7. Legacy tombstones are
     mapped the same way or dropped. Runs in one go before anything is pushed.
     */
    func adoptLegacyIds(mapped: [String: [Int64: RowID]], tombstoned: [String: Set<Int64>]) {
        func number(_ id: RowID) -> Int64? { isLegacyId(id) ? Int64(id.dropFirst(legacyIdPrefix.count)) : nil }
        var renamed: [String: [RowID: RowID]] = [:]
        var removed: [String: Set<RowID>] = [:]
        func plan(_ table: String, _ ids: [RowID]) {
            for id in ids where isLegacyId(id) && renamed[table]?[id] == nil && removed[table]?.contains(id) != true {
                let n = number(id)
                if let n, tombstoned[table]?.contains(n) == true { removed[table, default: []].insert(id) }
                else { renamed[table, default: [:]][id] = n.flatMap { mapped[table]?[$0] } ?? newRowId() }
            }
        }
        plan("teams", teamRows.map(\.id)); plan("players", playerRows.map(\.id)); plan("games", gameRows.map(\.id))
        plan("events", eventRows.map(\.id)); plan("segments", segmentRows.map(\.id))
        /// A reference to a row this phone no longer has keeps the server's id when there is one.
        func ref(_ table: String, _ id: RowID) -> RowID {
            guard isLegacyId(id) else { return id }
            return renamed[table]?[id] ?? number(id).flatMap { mapped[table]?[$0] } ?? id
        }
        teamRows.removeAll { removed["teams"]?.contains($0.id) == true }
        playerRows.removeAll { removed["players"]?.contains($0.id) == true || removed["teams"]?.contains($0.teamId) == true }
        gameRows.removeAll { removed["games"]?.contains($0.id) == true }
        eventRows.removeAll { removed["events"]?.contains($0.id) == true || removed["games"]?.contains($0.gameId) == true }
        segmentRows.removeAll { removed["segments"]?.contains($0.id) == true || removed["games"]?.contains($0.gameId) == true }
        statRows.removeAll { removed["games"]?.contains($0.gameId) == true }
        for i in teamRows.indices { teamRows[i].id = ref("teams", teamRows[i].id) }
        for i in playerRows.indices { playerRows[i].id = ref("players", playerRows[i].id); playerRows[i].teamId = ref("teams", playerRows[i].teamId) }
        for i in gameRows.indices {
            gameRows[i].id = ref("games", gameRows[i].id)
            gameRows[i].homeId = ref("teams", gameRows[i].homeId); gameRows[i].awayId = ref("teams", gameRows[i].awayId)
        }
        for i in eventRows.indices {
            eventRows[i].id = ref("events", eventRows[i].id); eventRows[i].gameId = ref("games", eventRows[i].gameId)
            eventRows[i].teamId = ref("teams", eventRows[i].teamId)
            if let player = eventRows[i].playerId {
                let mappedPlayer = ref("players", player)
                eventRows[i].playerId = isLegacyId(mappedPlayer) || removed["players"]?.contains(player) == true ? nil : mappedPlayer
            }
        }
        for i in segmentRows.indices { segmentRows[i].id = ref("segments", segmentRows[i].id); segmentRows[i].gameId = ref("games", segmentRows[i].gameId) }
        for i in statRows.indices { statRows[i].gameId = ref("games", statRows[i].gameId); statRows[i].playerId = ref("players", statRows[i].playerId) }
        deletionRows = deletionRows.compactMap { deletion in
            guard isLegacyId(deletion.rowId) else { return deletion }
            guard let n = number(deletion.rowId), let id = mapped[deletion.entity]?[n] else { return nil }
            var upgraded = deletion; upgraded.rowId = id
            return upgraded
        }
        // References whose parent is gone everywhere stay dangling; push skips them and the UI hides them.
        save()
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

    /// The first iOS store kept UUIDs; they are mapped with the same function the old sync used, so
    /// rows already uploaded from this device are matched to their cloud rows by the legacy id upgrade.
    private func migrateLegacy(_ data: Data) {
        guard let snapshot = try? JSONDecoder().decode(LegacySnapshot.self, from: data) else { return }
        func cloudID(_ uuid: UUID) -> RowID {
            let parts = uuid.uuidString.split(separator: "-")
            if parts.count == 5, parts[1] == "0000", parts[2] == "0000", parts[3] == "0000",
               let high = Int64(parts[0], radix: 16), let low = Int64(parts[4], radix: 16) { return legacyIdPrefix + String((high << 48) | low) }
            var hash: UInt64 = 14_695_981_039_346_656_037
            uuid.uuidString.utf8.forEach { hash = (hash ^ UInt64($0)) &* 1_099_511_628_211 }
            return legacyIdPrefix + String(Int64(hash & 0x001F_FFFF_FFFF_FFFF))
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

/// The app's own folder for recordings that could not go to Photos.
var recordingsDirectory: URL {
    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Recordings", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/**
 What a segment's recording may be opened from on this phone. A segment uri is synced data, so it
 is only trusted on this account's own rows, and a file path only by its name inside the app's
 Recordings folder (never an arbitrary path); anything else must be a Photos asset id.
 */
enum RecordingHandle: Equatable { case file(URL), photosAsset(String) }

func recordingHandle(_ segment: RecordingSegment) -> RecordingHandle? {
    let uri = segment.uri.trimmed
    guard segment.ownerId == nil, !uri.isEmpty else { return nil }
    if uri.hasPrefix("/") {
        let name = URL(fileURLWithPath: uri).lastPathComponent
        guard !name.isEmpty, name != "..", name != "." else { return nil }
        let file = recordingsDirectory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: file.path) ? .file(file) : nil
    }
    // Photos local identifiers look like "<UUID>/L0/001"; no scheme, no leading slash.
    guard !uri.contains("://"), !uri.contains("..") else { return nil }
    return .photosAsset(uri)
}

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
