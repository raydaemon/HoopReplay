import XCTest
@testable import HoopReplay

@MainActor
final class GameModelTests: XCTestCase {
    private func makeStore() -> AppStore { AppStore(inMemory: true) }

    private func makeGame(_ store: AppStore) -> Game {
        let home = store.addTeam("Home \(UUID().uuidString.prefix(6))")
        let away = store.addTeam("Away \(UUID().uuidString.prefix(6))")
        let id = store.addGame(title: "Home vs Away", home: home, away: away, scheduledAt: nowMs(), videoQuality: "UHD", periodCount: 4, periodDurationMs: 480_000)
        return store.game(id)!
    }

    func testGameStartsReadyWithZeroScore() {
        let store = makeStore()
        let game = makeGame(store)
        XCTAssertEqual(game.status, "READY")
        XCTAssertEqual(game.homeScore, 0)
        XCTAssertEqual(game.awayScore, 0)
        XCTAssertEqual(game.clockRemainingMs, 480_000)
    }

    func testAddPlayerReusesJerseyNumber() {
        let store = makeStore()
        let team = store.addTeam("Roster")
        let first = store.addPlayer(team, name: "alex", number: "7")
        let second = store.addPlayer(team, name: "Someone Else", number: "7")
        XCTAssertEqual(first, second)
        XCTAssertEqual(store.player(first)?.name, "Alex")
    }

    func testRosterOrderNumberedFirstThenFirstName() {
        let players = [
            Player(id: "1", teamId: "t", name: "Zoe Park", number: ""),
            Player(id: "2", teamId: "t", name: "Mia Lopez", number: "23"),
            Player(id: "3", teamId: "t", name: "Ava Chen", number: ""),
            Player(id: "4", teamId: "t", name: "Ivy Nash", number: "4"),
        ]
        XCTAssertEqual(rosterOrder(players).map(\.id), ["4", "2", "3", "1"])
    }

    func testScoringEventUpdatesScoreAndUndoRevertsIt() {
        let store = makeStore()
        let game = makeGame(store)
        store.addEvent(gameId: game.id, teamId: game.awayId, playerId: nil, type: "PTS_2", value: 2, period: 1, clock: 400_000, segment: 0, segmentMs: 0, videoMs: 0)
        store.recalculateScore(game.id)
        XCTAssertEqual(store.game(game.id)?.awayScore, 2)
        let undone = store.undo(game.id)
        XCTAssertEqual(undone?.type, "PTS_2")
        store.recalculateScore(game.id)
        XCTAssertEqual(store.game(game.id)?.awayScore, 0)
        XCTAssertEqual(store.events(game.id).count, 1, "undo keeps the row and marks it reverted")
        XCTAssertTrue(store.activeEvents(game.id).isEmpty)
    }

    func testDeletionsLeaveTombstones() {
        let store = makeStore()
        let team = store.addTeam("Ghosts")
        XCTAssertTrue(store.deleteTeam(team))
        let tombstones = store.pendingDeletions().filter { ($0["entity"] as? String) == "teams" && ($0["row_id"] as? String) == team }
        XCTAssertEqual(tombstones.count, 1)
    }

    func testMinutesComeOnlyFromLineupEvents() {
        let store = makeStore()
        let game = makeGame(store)
        let starter = store.addPlayer(game.homeId, name: "Starter", number: "1")
        let scorer = store.addPlayer(game.homeId, name: "Scorer", number: "2")
        store.addEvent(gameId: game.id, teamId: game.homeId, playerId: starter, type: "STARTER", value: 1, period: 1, clock: 480_000, segment: 0, segmentMs: 0, videoMs: 0)
        store.addEvent(gameId: game.id, teamId: game.homeId, playerId: scorer, type: "PTS_2", value: 2, period: 1, clock: 300_000, segment: 0, segmentMs: 0, videoMs: 0)
        store.recalculatePlayerGameStats(game)
        let stats = store.playerGameStats(game.id)
        XCTAssertEqual(stats[starter]?.0, 480_000)
        XCTAssertEqual(stats[scorer]?.0, 0, "a stat never implies the player was on the floor")
        XCTAssertEqual(stats[starter]?.1, 2)
    }

    func testGameExportsProduceJSONAndPDF() throws {
        let store = makeStore()
        let game = makeGame(store)
        let json = try store.exportGameJsonFile(game)
        let text = try String(contentsOf: json, encoding: .utf8)
        XCTAssertTrue(text.contains("hoopreplay.game"))
        XCTAssertTrue(text.contains("UHD"))
        let pdf = try store.exportStatsPdf(game)
        XCTAssertEqual(try Data(contentsOf: pdf).prefix(4), Data("%PDF".utf8))
        let plays = try store.exportPlaysPdf(game)
        XCTAssertEqual(try Data(contentsOf: plays).prefix(4), Data("%PDF".utf8))
    }

    func testImportRoundTripCreatesNewGame() throws {
        let store = makeStore()
        let game = makeGame(store)
        store.addPlayer(game.homeId, name: "Ava Chen", number: "4")
        let snapshot = store.exportGameJson(game)
        let before = store.games().count
        let summary = try store.importGameJson(snapshot)
        XCTAssertEqual(store.games().count, before + 1)
        XCTAssertEqual(summary.createdTeams, 0, "teams are matched by name")
    }

    func testNewRowIdsAreTimeOrderedUUIDv7() {
        let ids = (0..<50).map { _ in newRowId() }
        XCTAssertEqual(ids, ids.sorted())
        for id in ids {
            XCTAssertNotNil(id.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression), id)
        }
    }

    func testIntegerStoreUpgradesToLegacyPlaceholders() throws {
        let old = #"{"teams":[{"id":5,"name":"A","createdAt":1}],"players":[{"id":6,"teamId":5,"name":"P","number":"1"}],"games":[],"events":[],"segments":[],"deletions":[{"entity":"teams","localId":9,"deletedAt":1,"deviceId":"d"}],"stats":[]}"#
        let upgraded = try JSONSerialization.jsonObject(with: AppStore.upgradedSnapshotData(Data(old.utf8))) as! [String: Any]
        let player = (upgraded["players"] as! [[String: Any]])[0]
        XCTAssertEqual(player["id"] as? String, "legacy:6")
        XCTAssertEqual(player["teamId"] as? String, "legacy:5")
        XCTAssertEqual((upgraded["deletions"] as! [[String: Any]])[0]["rowId"] as? String, "legacy:9")
    }

    func testLegacyAdoptionMapsTombstonesAndReferences() {
        let store = makeStore()
        store.mergeSyncSnapshot(["teams": [["id": "legacy:1", "name": "Home", "user_id": "me"], ["id": "legacy:2", "name": "Gone", "user_id": "me"]],
                                 "players": [["id": "legacy:3", "team_id": "legacy:1", "name": "P", "number": "4", "user_id": "me"]]], ownUserId: "me")
        XCTAssertTrue(store.hasLegacyIds)
        let mapped = "0190c0de-0000-7000-8000-000000000001"
        store.adoptLegacyIds(mapped: ["teams": [1: mapped]], tombstoned: ["teams": [2]])
        XCTAssertFalse(store.hasLegacyIds)
        XCTAssertEqual(store.teams().map(\.id), [mapped])
        XCTAssertEqual(store.players(mapped).count, 1, "the player follows its team to the mapped id")
    }

    func testSharedRowsStayReadOnlyAndAreNeverPushed() {
        let store = makeStore()
        let own = store.addTeam("Mine")
        store.mergeSyncSnapshot(["teams": [["id": own, "name": "Hijacked", "user_id": "other"], ["id": "t-shared", "name": "Theirs", "user_id": "other"]]], ownUserId: "me")
        XCTAssertEqual(store.team(own)?.name, "Mine", "a shared row never replaces an own row")
        XCTAssertEqual(store.team("t-shared")?.ownerId, "other")
        let pushed = (store.exportSyncSnapshot()["teams"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        XCTAssertEqual(pushed, [own])
        store.mergeSyncSnapshot([:], ownUserId: "me")
        XCTAssertNil(store.team("t-shared"), "shared rows the latest pull no longer returns are removed")
    }

    func testSegmentUriOutsideRecordingsIsNeverOpened() {
        XCTAssertNil(recordingHandle(RecordingSegment(id: "s", gameId: "g", sequence: 1, uri: "/etc/hosts", durationMs: 1, createdAt: 0)))
        XCTAssertNil(recordingHandle(RecordingSegment(id: "s", gameId: "g", sequence: 1, uri: "file:///etc/hosts", durationMs: 1, createdAt: 0)))
        XCTAssertNil(recordingHandle(RecordingSegment(id: "s", gameId: "g", sequence: 1, uri: "ABC/L0/001", durationMs: 1, createdAt: 0, ownerId: "other")))
        XCTAssertEqual(recordingHandle(RecordingSegment(id: "s", gameId: "g", sequence: 1, uri: "ABC/L0/001", durationMs: 1, createdAt: 0)), .photosAsset("ABC/L0/001"))
    }
}
