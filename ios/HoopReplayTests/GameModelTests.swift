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
            Player(id: 1, teamId: 1, name: "Zoe Park", number: ""),
            Player(id: 2, teamId: 1, name: "Mia Lopez", number: "23"),
            Player(id: 3, teamId: 1, name: "Ava Chen", number: ""),
            Player(id: 4, teamId: 1, name: "Ivy Nash", number: "4"),
        ]
        XCTAssertEqual(rosterOrder(players).map(\.id), [4, 2, 3, 1])
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
        let tombstones = store.pendingDeletions().filter { ($0["entity"] as? String) == "teams" && ($0["local_id"] as? Int64) == team }
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
}
