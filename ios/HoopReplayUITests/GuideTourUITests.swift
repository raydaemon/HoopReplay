import XCTest

/// Walks every screen and every button of the app on a real device, attaching a named
/// screenshot per screen for docs/user_guide_ios.md. Run with the runner env toggle:
///   TEST_RUNNER_GUIDE_TOUR=1 xcodebuild test ... -only-testing:HoopReplayUITests/GuideTourUITests
/// The tour runs as a dedicated UI-test target and reuses the data already on the device (the Falcons vs Rockets demo game) and only
/// creates the demo teams and game when the device has none. Everything it records is undone.
final class GuideTourUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["HoopReplay"].waitForExistence(timeout: 12))
    }

    // MARK: - Helpers

    /// The live screens are locked to landscape-right by the app while the device itself may still
    /// report portrait, so the caller says which way the capture must be rotated on export.
    private func shot(_ name: String, landscape: Bool = false) {
        sleep(1)
        // Redraw the capture so its orientation metadata is baked into the pixels; the raw screen
        // capture of a landscape-locked screen otherwise comes back rotated at random.
        let raw = XCUIScreen.main.screenshot().image
        let normalized = UIGraphicsImageRenderer(size: raw.size).image { _ in raw.draw(in: CGRect(origin: .zero, size: raw.size)) }
        let attachment = XCTAttachment(image: normalized)
        attachment.name = landscape ? name + "@LR" : name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tapTab(_ key: String) {
        let tab = app.buttons["tab-\(key)"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 8))
        tab.tap()
    }

    private func button(_ label: String, index: Int = 0) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).element(boundBy: index)
    }

    private func containing(_ text: String, index: Int = 0) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).element(boundBy: index)
    }

    private func tap(_ element: XCUIElement, timeout: TimeInterval = 6) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "missing \(element)")
        element.tap()
    }

    private func cancelDialog() { tap(button("Cancel")) }

    private func menuItem(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ AND NOT (identifier CONTAINS 'picker')", label)).firstMatch
    }

    /// First player button inside an open live dialog.
    private func dialogPlayer(_ index: Int = 0) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'dialog-player-'")).element(boundBy: index)
    }
    private func pickPlayer(_ index: Int = 0) { tap(dialogPlayer(index)) }

    private func lineupPlayers() -> XCUIElementQuery { app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'lineup-player-'")) }

    /// Camera, microphone, and Photos permission prompts are springboard alerts; approve them.
    private func settleSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 3) else { break }
            for label in ["Allow While Using App", "Allow Full Access", "Add Photos Only", "OK", "Allow", "允许", "好", "继续"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); break }
            }
        }
    }

    // MARK: - Fixtures

    private var demoGame: XCUIElement { app.staticTexts["Falcons vs Rockets"].firstMatch }

    private func ensureDemoData() {
        tapTab("games")
        if demoGame.waitForExistence(timeout: 4) { return }
        tapTab("teams")
        createTeam("Falcons", players: [("4", "Ava Chen"), ("7", "Mia Lopez"), ("9", "Zoe Park"), ("11", "Ivy Nash"), ("15", "Ruby Diaz"), ("23", "Nora Kim")])
        createTeam("Rockets", players: [("3", "Leo Ward"), ("8", "Kai Reyes"), ("10", "Omar Diaz"), ("12", "Eli Brooks"), ("21", "Tariq Bell"), ("33", "Noah Grant")])
        createGame()
        XCTAssertTrue(demoGame.waitForExistence(timeout: 8))
    }

    private func createTeam(_ name: String, players: [(String, String)]) {
        tap(app.buttons["add-team-button"].firstMatch)
        let field = app.textFields["team-name-field"]
        tap(field); field.typeText(name)
        tap(app.buttons["team-save-button"])
        tap(app.staticTexts[name].firstMatch)
        for (number, playerName) in players {
            tap(app.buttons["add-player-button"].firstMatch)
            let first = app.textFields["player-first-name-field"]
            let parts = playerName.split(separator: " ", maxSplits: 1).map(String.init)
            tap(first); first.typeText(parts[0])
            if parts.count > 1 { tap(app.textFields["player-last-name-field"]); app.textFields["player-last-name-field"].typeText(parts[1]) }
            tap(app.textFields["player-number-field"]); app.textFields["player-number-field"].typeText(number)
            tap(app.buttons["player-save-button"])
        }
        tap(app.buttons["BackButton"])
    }

    private func createGame() {
        tapTab("games")
        tap(app.buttons["Create Game"].firstMatch)
        tap(app.buttons["home-team-picker"])
        tap(menuItem("Falcons"))
        tap(app.buttons["away-team-picker"])
        tap(menuItem("Rockets"))
        tap(app.buttons["game-create-button"])
    }

    private func openGameDetails() {
        ensureDemoData()
        tapTab("games")
        tap(demoGame)
        XCTAssertTrue(app.staticTexts["Game Details"].waitForExistence(timeout: 8))
    }

    /// The app locks the live screens to landscape; the device orientation is set to match so every
    /// screen capture there comes out with the same rotation.
    private func openLiveScore() {
        openGameDetails()
        tap(app.buttons["Score"].firstMatch)
        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(containing("Lineup").waitForExistence(timeout: 10))
        sleep(1)
    }

    private func exitLive() {
        sleep(1)
        tap(button("Exit"))
        XCTAssertTrue(app.staticTexts["Game Details"].waitForExistence(timeout: 8))
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: - Tour A: home, account, games list

    func testTourA_HomeAndGames() throws {
        ensureDemoData()
        tapTab("home")
        shot("01-home")
        if app.buttons["account-button"].exists {
            tap(app.buttons["account-button"])
            shot("54-account-menu")
            tap(button("Sync status"))
            XCTAssertTrue(app.staticTexts["Storage"].waitForExistence(timeout: 5))
            tapTab("home")
        }
        tapTab("games")
        shot("57-games-list")
        let search = app.textFields.firstMatch
        tap(search); search.typeText("Falc")
        shot("58-games-search")
        search.doubleTap(); app.keys["delete"].tap()
        tapTab("home")
    }

    // MARK: - Tour B: teams, roster, player detail

    func testTourB_TeamsAndPlayers() throws {
        ensureDemoData()
        tapTab("teams")
        XCTAssertTrue(app.buttons["add-team-button"].waitForExistence(timeout: 8))
        shot("02-teams")
        tap(app.buttons["add-team-button"])
        XCTAssertTrue(app.textFields["team-name-field"].waitForExistence(timeout: 5))
        shot("55-add-team")
        cancelDialog()
        tap(app.staticTexts["Falcons"].firstMatch)
        XCTAssertTrue(app.buttons["add-player-button"].waitForExistence(timeout: 8))
        shot("03-team-roster")
        tap(app.buttons["add-player-button"])
        XCTAssertTrue(app.textFields["player-first-name-field"].waitForExistence(timeout: 5))
        shot("59-add-player")
        cancelDialog()
        tap(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Jersey'")).firstMatch)
        XCTAssertTrue(button("Edit").waitForExistence(timeout: 5))
        shot("60-player-detail")
        tap(button("Edit"))
        XCTAssertTrue(app.staticTexts["Edit player"].waitForExistence(timeout: 5))
        shot("61-edit-player")
        cancelDialog()
        tap(button("Delete"))
        XCTAssertTrue(app.staticTexts["Delete player?"].waitForExistence(timeout: 5))
        shot("62-delete-player")
        cancelDialog()
        tap(app.buttons["BackButton"])
        tap(button("Delete team"))
        XCTAssertTrue(app.staticTexts["Delete team?"].waitForExistence(timeout: 5))
        shot("63-delete-team")
        cancelDialog()
        tap(app.buttons["BackButton"])
        XCTAssertTrue(app.staticTexts["Teams & Players"].waitForExistence(timeout: 5))
    }

    // MARK: - Tour C: settings

    func testTourC_Settings() throws {
        tapTab("settings")
        XCTAssertTrue(app.staticTexts["Storage"].waitForExistence(timeout: 5))
        shot("53-settings")
        tap(button("Español"))
        XCTAssertTrue(app.staticTexts["Configuración"].waitForExistence(timeout: 5))
        shot("64-settings-spanish")
        tap(button("English"))
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 5))
        app.swipeUp()
        XCTAssertTrue(app.buttons["Choose JSON file"].waitForExistence(timeout: 5))
        shot("52-import")
        tap(app.buttons["Choose JSON file"])
        sleep(2)
        shot("65-import-file-picker")
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.waitForExistence(timeout: 4) { cancel.tap() } else { app.swipeDown() }
        tapTab("home")
    }

    // MARK: - Tour D: create game form and delete game

    func testTourD_CreateAndDeleteGame() throws {
        ensureDemoData()
        tapTab("games")
        tap(app.buttons["Create Game"].firstMatch)
        XCTAssertTrue(app.buttons["game-create-button"].waitForExistence(timeout: 5))
        shot("04-create-game")
        tap(containing(",", index: 0)) // the Date button shows "Sep 6, 2026"
        XCTAssertTrue(app.staticTexts["Select date"].waitForExistence(timeout: 5))
        shot("66-pick-date")
        tap(button("OK"))
        tap(app.buttons.matching(NSPredicate(format: "label CONTAINS ':'")).firstMatch) // the Time button shows "12:00 AM"
        XCTAssertTrue(app.staticTexts["Select time"].waitForExistence(timeout: 5))
        shot("67-pick-time")
        tap(button("OK"))
        tap(app.buttons["home-team-picker"])
        shot("68-home-team-menu")
        tap(menuItem("Falcons"))
        tap(app.buttons["away-team-picker"])
        tap(menuItem("Rockets"))
        tap(button("+", index: 0)); tap(button("−", index: 0))
        tap(button("+", index: 1)); tap(button("−", index: 1))
        tap(app.buttons["video-quality-picker"])
        shot("05-resolution-menu")
        tap(menuItem("Device maximum"))
        tap(app.buttons["game-create-button"])
        XCTAssertTrue(demoGame.waitForExistence(timeout: 8))
        tap(demoGame) // the newest game is listed first
        XCTAssertTrue(app.staticTexts["Game Details"].waitForExistence(timeout: 8))
        tap(button("Delete"))
        XCTAssertTrue(app.staticTexts["Delete game?"].waitForExistence(timeout: 5))
        shot("69-delete-game")
        tap(button("Delete", index: 1))
        XCTAssertTrue(app.buttons["tab-home"].waitForExistence(timeout: 8))
    }

    // MARK: - Tour E: game details

    func testTourE_GameDetails() throws {
        openGameDetails()
        shot("06-game-details")
        tap(containing("(A)"))
        shot("70-details-away-stats")
        tap(button("Select columns"))
        XCTAssertTrue(app.staticTexts["Select columns"].waitForExistence(timeout: 5))
        shot("71-select-columns")
        tap(button("MIN")); tap(button("FGM")); tap(button("FGA"))
        tap(button("Apply"))
        shot("72-fewer-columns")
        tap(button("Select columns")); tap(button("MIN")); tap(button("FGM")); tap(button("FGA")); tap(button("Apply"))
        tap(button("PTS"))
        shot("73-sorted-by-points")
        tap(containing("PTS")); tap(containing("PTS"))
        tap(button("Full screen"))
        XCUIDevice.shared.orientation = .landscapeRight
        sleep(2)
        shot("74-stats-full-screen", landscape: true)
        tap(button("X"))
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        tap(button("Play-by-Play"))
        shot("50-details-play-by-play")
        let play = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'play-event-'")).firstMatch
        if play.waitForExistence(timeout: 3) {
            play.tap()
            XCTAssertTrue(app.staticTexts["Edit play"].waitForExistence(timeout: 5))
            shot("75-details-edit-play")
            cancelDialog()
        }
        tap(button("Export"))
        XCTAssertTrue(button("Statistics (PDF)").waitForExistence(timeout: 5))
        shot("51-export-menu")
        tap(button("Game data (JSON)"))
        sleep(3)
        shot("76-share-sheet")
        let close = app.buttons["Close"].firstMatch
        if close.waitForExistence(timeout: 3) { close.tap() } else { app.swipeDown() }
        tap(button("End game"))
        XCTAssertTrue(app.staticTexts["End game?"].waitForExistence(timeout: 5))
        shot("77-end-game")
        cancelDialog()
        tap(button("Falcons"))
        XCTAssertTrue(app.buttons["add-player-button"].waitForExistence(timeout: 5))
        tap(app.buttons["BackButton"])
        XCTAssertTrue(app.staticTexts["Game Details"].waitForExistence(timeout: 5))
        tap(app.buttons["BackButton"])
    }

    // MARK: - Tour F: lineup and scoring flows

    func testTourF_LiveLineupAndScoringFlows() throws {
        openLiveScore()
        shot("07-score-mode", landscape: true)

        // Home lineup: right-hand side is the home team, second Lineup button.
        tap(containing("Lineup", index: 1))
        XCTAssertTrue(button("Confirm").waitForExistence(timeout: 5))
        shot("08-lineup-empty", landscape: true)
        let homePlayers = lineupPlayers()
        for index in 0..<min(5, homePlayers.count) where homePlayers.element(boundBy: index).label.contains("Substitute") { homePlayers.element(boundBy: index).tap() }
        shot("09-lineup-selected", landscape: true)
        tap(button("Confirm"))
        tap(containing("Lineup", index: 0))
        let awayPlayers = lineupPlayers()
        for index in 0..<min(5, awayPlayers.count) where awayPlayers.element(boundBy: index).label.contains("Substitute") { awayPlayers.element(boundBy: index).tap() }
        tap(button("Confirm"))
        shot("10-lineups-set", landscape: true)

        tap(button("Start"))
        sleep(1)

        tap(button("+1", index: 1))
        shot("78-plus-one-adjust", landscape: true)
        tap(button("-1", index: 1))
        tap(button("Undo")); tap(button("Undo"))

        tap(button("+2", index: 1))
        XCTAssertTrue(app.staticTexts["Who scored?"].waitForExistence(timeout: 5))
        shot("11-plus2-shooter", landscape: true)
        pickPlayer()
        XCTAssertTrue(app.staticTexts["Who made the assist?"].waitForExistence(timeout: 5))
        shot("12-plus2-assist", landscape: true)
        pickPlayer()
        sleep(1)
        shot("79-after-two-with-assist", landscape: true)
        tap(button("Undo")); tap(button("Undo"))

        tap(button("+3", index: 1))
        XCTAssertTrue(app.staticTexts["Who scored?"].waitForExistence(timeout: 5))
        shot("13-plus3-shooter", landscape: true)
        tap(button("Assign later"))
        XCTAssertTrue(app.staticTexts["Who made the assist?"].waitForExistence(timeout: 5))
        shot("14-plus3-assist", landscape: true)
        tap(button("Previous"))
        XCTAssertTrue(app.staticTexts["Who scored?"].waitForExistence(timeout: 5))
        pickPlayer()
        tap(button("No assist"))
        sleep(1)
        tap(button("Undo"))

        tap(button("Pause"))
        tap(button("Stop"))
        exitLive()
    }

    // MARK: - Tour G: missed shots and rebounds

    func testTourG_LiveMissAndRebound() throws {
        openLiveScore()
        tap(button("Miss 2", index: 1))
        XCTAssertTrue(app.staticTexts["Who took this shot?"].waitForExistence(timeout: 5))
        shot("15-miss2-shooter", landscape: true)
        pickPlayer()
        XCTAssertTrue(containing("Offensive rebound").waitForExistence(timeout: 5))
        shot("16-miss2-rebound", landscape: true)
        tap(containing("Defensive rebound"))
        shot("17-rebound-other-team", landscape: true)
        tap(button("Choose number"))
        XCTAssertTrue(app.buttons["number-99"].waitForExistence(timeout: 5))
        shot("80-rebound-number-pad", landscape: true)
        cancelDialog()
        tap(button("No rebound"))
        tap(button("Undo"))

        tap(button("Miss 3", index: 1))
        shot("18-miss3-shooter", landscape: true)
        tap(button("Choose number"))
        XCTAssertTrue(app.buttons["number-99"].waitForExistence(timeout: 5))
        shot("81-choose-number-pad", landscape: true)
        cancelDialog()
        XCTAssertTrue(app.staticTexts["Who took this shot?"].waitForExistence(timeout: 5))
        pickPlayer()
        XCTAssertTrue(containing("Offensive rebound").waitForExistence(timeout: 5))
        shot("19-miss3-rebound", landscape: true)
        pickPlayer()
        sleep(1)
        tap(button("Undo")); tap(button("Undo"))
        exitLive()
    }

    // MARK: - Tour H: free throws

    func testTourH_FreeThrows() throws {
        openLiveScore()
        tap(button("Free Throw", index: 1))
        XCTAssertTrue(app.staticTexts["Select shooter"].waitForExistence(timeout: 5))
        shot("20-free-throw-shooter", landscape: true)
        pickPlayer()
        XCTAssertTrue(button("2 FTs").waitForExistence(timeout: 5))
        shot("21-free-throw-format", landscape: true)
        tap(button("Made +1", index: 0))
        shot("22-free-throw-attempts", landscape: true)
        tap(button("Miss", index: 1)) // a missed last free throw opens the rebound picker
        XCTAssertTrue(containing("Offensive rebound").waitForExistence(timeout: 5))
        shot("23-free-throw-rebound", landscape: true)
        tap(button("No rebound"))
        sleep(1)
        tap(button("Undo")); tap(button("Undo"))

        tap(button("Free Throw", index: 1))
        tap(button("Assign later"))
        XCTAssertTrue(button("1+1").waitForExistence(timeout: 5))
        tap(button("1+1"))
        shot("24-free-throw-one-and-one", landscape: true)
        tap(button("Made +1", index: 0))
        shot("25-one-and-one-bonus", landscape: true)
        tap(button("Previous"))
        XCTAssertTrue(app.staticTexts["Select shooter"].waitForExistence(timeout: 5))
        pickPlayer()
        tap(button("3 FTs"))
        shot("82-three-free-throws", landscape: true)
        cancelDialog()
        exitLive()
    }

    // MARK: - Tour I: standalone stats, fouls, substitution

    func testTourI_StatsFoulSub() throws {
        openLiveScore()
        let stats: [(String, String)] = [
            ("Rebound", "26-stat-rebound"), ("Assist", "27-stat-assist"),
            ("Steal", "28-stat-steal"), ("Block", "29-stat-block"), ("Turnover", "30-stat-turnover"),
        ]
        for (label, file) in stats {
            tap(button(label, index: 1))
            XCTAssertTrue(app.staticTexts["Who recorded this stat?"].waitForExistence(timeout: 5))
            shot(file)
            cancelDialog()
        }
        tap(button("Steal", index: 1)); pickPlayer(); sleep(1); tap(button("Undo"))

        tap(button("Foul", index: 1))
        XCTAssertTrue(app.staticTexts["Who committed the foul?"].waitForExistence(timeout: 5))
        shot("31-stat-foul", landscape: true)
        pickPlayer()
        XCTAssertTrue(app.staticTexts["Who was fouled?"].waitForExistence(timeout: 5))
        shot("32-foul-drawn", landscape: true)
        pickPlayer()
        sleep(1)
        shot("83-after-foul", landscape: true)
        tap(button("Undo")); tap(button("Undo"))

        tap(button("Sub", index: 1))
        XCTAssertTrue(app.staticTexts["Substitution"].waitForExistence(timeout: 5))
        shot("33-substitution", landscape: true)
        let bench = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'lineup-player-' AND label CONTAINS 'Bench'")).firstMatch
        let onCourt = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'lineup-player-' AND label CONTAINS 'On court'")).firstMatch
        if onCourt.exists && bench.exists {
            onCourt.tap(); bench.tap()
            shot("34-substitution-changed", landscape: true)
            tap(button("Save"))
            sleep(1)
            tap(button("Undo")); tap(button("Undo"))
        } else { cancelDialog() }
        exitLive()
    }

    // MARK: - Tour J: panels and controls

    func testTourJ_PanelsAndControls() throws {
        openLiveScore()

        tap(button("Players", index: 1))
        XCTAssertTrue(button("Names").waitForExistence(timeout: 5))
        shot("35-add-player-live", landscape: true)
        tap(app.buttons["number-98"])
        shot("84-number-added", landscape: true)
        tap(button("Names"))
        shot("36-players-names-tab", landscape: true)
        tap(app.buttons["roster-new-first"])
        XCTAssertTrue(button("Space").waitForExistence(timeout: 5))
        shot("85-in-app-keyboard", landscape: true)
        // Two Done buttons are on screen: the panel's (index 0) and the keyboard's (index 1).
        tap(button("Q")); tap(app.buttons["keyboard-done"])
        tap(app.buttons["roster-number-98"])
        XCTAssertTrue(app.staticTexts["Player number"].waitForExistence(timeout: 5))
        shot("86-number-keypad", landscape: true)
        tap(app.buttons["number-cancel"])
        tap(button("Cancel")) // rolls every roster change back

        tap(button("Period/Time"))
        XCTAssertTrue(button("Save").waitForExistence(timeout: 5))
        shot("37-adjust-clock", landscape: true)
        // Wheeling to another period resets the clock to the full period; Cancel keeps the demo game in period 1.
        app.pickerWheels.element(boundBy: 0).adjust(toPickerWheelValue: "Period 2")
        shot("46-next-period", landscape: true)
        cancelDialog()

        tap(button("Stats"))
        XCTAssertTrue(button("Select columns").waitForExistence(timeout: 5))
        shot("38-live-stats", landscape: true)
        tap(containing("(A)"))
        shot("39-live-stats-away", landscape: true)
        tap(button("Full screen"))
        shot("87-live-stats-full-screen", landscape: true)
        tap(button("X", index: 0))
        tap(button("X", index: 0))

        tap(button("Plays"))
        XCTAssertTrue(button("×").waitForExistence(timeout: 5))
        shot("40-plays", landscape: true)
        tap(button("Scoring"))
        shot("41-plays-filter-scoring", landscape: true)
        tap(button("Fouls")); tap(button("Away")); tap(button("Home")); tap(button("All"))
        let plays = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'dialog-play-event-'"))
        if let play = plays.allElementsBoundByIndex.first(where: { $0.isHittable }) {
            play.tap()
            XCTAssertTrue(app.staticTexts["Edit play"].waitForExistence(timeout: 5))
            shot("42-edit-play", landscape: true)
            tap(button("Delete"))
            XCTAssertTrue(app.staticTexts["Delete play?"].waitForExistence(timeout: 5))
            shot("88-delete-play", landscape: true)
            cancelDialog()
            cancelDialog()
        }
        tap(button("×"))

        tap(button("Score Mode"))
        shot("45-score-mode-toggle", landscape: true)
        tap(button("+2", index: 1)); sleep(1); tap(button("Undo"))
        tap(button("Stat Mode"))

        tap(containing("Quality:"))
        shot("43-quality-menu", landscape: true)
        tap(menuItem("720p · Smaller file"))
        tap(containing("Quality:"))
        tap(menuItem("Device maximum"))

        tap(button("Start"))
        sleep(2)
        tap(containing("(A)", index: 0))
        XCTAssertTrue(app.staticTexts["Recording in progress"].waitForExistence(timeout: 5))
        shot("89-stop-first", landscape: true)
        tap(button("OK"))
        tap(button("Pause"))
        shot("47-clock-paused", landscape: true)
        tap(button("Resume"))
        sleep(1)
        tap(button("Stop"))
        shot("48-after-stop", landscape: true)
        tap(containing("(H)", index: 0))
        XCTAssertTrue(app.buttons["add-player-button"].waitForExistence(timeout: 5))
        shot("90-team-from-live")
        tap(app.buttons["BackButton"])
        XCTAssertTrue(button("Exit").waitForExistence(timeout: 8))
        exitLive()
        shot("49-game-details-after")
        tap(app.buttons["BackButton"])
    }

    // MARK: - Tour K: recording mode

    func testTourK_RecordMode() throws {
        openGameDetails()
        tap(app.buttons["Record"].firstMatch)
        XCUIDevice.shared.orientation = .landscapeRight
        settleSystemAlerts()
        XCTAssertTrue(containing("Lineup").waitForExistence(timeout: 10))
        sleep(3)
        shot("56-record-mode", landscape: true)
        tap(button("Start"))
        XCTAssertTrue(button("Pause").waitForExistence(timeout: 10))
        sleep(4)
        shot("91-recording", landscape: true)
        tap(button("Pause"))
        sleep(2)
        tap(button("Resume"))
        sleep(3)
        tap(button("Stop"))
        settleSystemAlerts()
        XCTAssertTrue(button("Exit").waitForExistence(timeout: 20))
        shot("92-recording-saved", landscape: true)
        tap(button("Plays"))
        sleep(1)
        shot("93-plays-with-video", landscape: true)
        tap(button("×"))
        exitLive()
        tap(app.buttons["BackButton"])
    }

    // MARK: - Cleanup of test fixtures written into the device store by earlier unit-test runs

    func testTourZ_CleanupUnitTestFixtures() throws {
        tapTab("games")
        for _ in 0..<12 {
            let junk = app.staticTexts["Home vs Away"].firstMatch
            guard junk.waitForExistence(timeout: 3) else { break }
            junk.tap()
            XCTAssertTrue(app.staticTexts["Game Details"].waitForExistence(timeout: 8))
            tap(button("Delete"))
            tap(button("Delete", index: 1))
            XCTAssertTrue(app.buttons["tab-home"].waitForExistence(timeout: 8))
            tapTab("games")
        }
        tapTab("teams")
        for _ in 0..<24 {
            let junk = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Home ' OR label BEGINSWITH 'Away ' OR label == 'Roster' OR label BEGINSWITH 'Export ' OR label BEGINSWITH 'RosterTest'")).firstMatch
            guard junk.waitForExistence(timeout: 3) else { break }
            junk.tap()
            tap(button("Delete team"))
            tap(button("Delete"))
            XCTAssertTrue(app.staticTexts["Teams & Players"].waitForExistence(timeout: 8))
        }
        // Number-only players left behind by an interrupted roster-panel tour.
        tap(app.staticTexts["Falcons"].firstMatch)
        for number in ["98", "99"] {
            let row = app.staticTexts["Jersey \(number)"].firstMatch
            guard row.waitForExistence(timeout: 2) else { continue }
            row.tap()
            tap(button("Delete"))
            tap(button("Delete", index: 1))
            XCTAssertTrue(app.buttons["add-player-button"].waitForExistence(timeout: 8))
        }
        tap(app.buttons["BackButton"])
        // Period-2 starters written by earlier tour runs that advanced the period.
        openGameDetails()
        tap(button("Play-by-Play"))
        let collapse = containing("Collapse")
        if collapse.waitForExistence(timeout: 3) { collapse.tap() }
        for _ in 0..<40 {
            guard let play = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'play-event-'")).allElementsBoundByIndex.first(where: { $0.isHittable }) else { break }
            play.tap()
            XCTAssertTrue(app.staticTexts["Edit play"].waitForExistence(timeout: 5))
            if app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Q2'")).firstMatch.exists {
                tap(button("Delete")); tap(button("Delete", index: 1))
            } else { cancelDialog(); break }
        }
        tap(app.buttons["BackButton"])
    }
}
