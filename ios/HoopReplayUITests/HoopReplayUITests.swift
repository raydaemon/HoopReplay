import XCTest

final class HoopReplayUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-ui-testing"]
        app.launch()
        addUIInterruptionMonitor(withDescription: "System alerts") { alert in
            for label in ["Allow", "允许", "好", "OK", "继续", "Continue", "Allow While Using App"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        XCTAssertTrue(app.staticTexts["HoopReplay"].waitForExistence(timeout: 10))
        let deviceScreenshot = XCTAttachment(screenshot: app.screenshot())
        deviceScreenshot.name = "iPhone 13 Pro Max current screen"
        deviceScreenshot.lifetime = .keepAlways
        add(deviceScreenshot)
    }

    func testHomeNavigationAndCoreEntryPoints() throws {
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Welcome back'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Cloud sync"].exists)
        tapTab("games")
        XCTAssertTrue(app.staticTexts["Games"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Create Game"].exists)
        tapTab("teams")
        XCTAssertTrue(app.buttons["add-team-button"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Teams & Players"].exists)
        tapTab("settings")
        XCTAssertTrue(app.staticTexts["Storage"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Interface language"].exists)
        XCTAssertTrue(app.buttons["Choose JSON file"].exists)
        tapTab("home")
    }

    func testCreateTeamsAndPlayersFlow() throws {
        tapTab("teams")
        createTeam("Falcons")
        createTeam("Rockets")
        XCTAssertTrue(app.staticTexts["Falcons"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Rockets"].exists)
        app.staticTexts["Falcons"].tap()
        addPlayer(first: "Alex", last: "Chen", number: "7")
        XCTAssertTrue(app.staticTexts["Alex Chen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Jersey 7"].exists)
        // Player detail keeps Delete/Edit and the edit dialog asks for first and last name separately.
        app.staticTexts["Alex Chen"].tap()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 5))
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.staticTexts["Edit player"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        app.buttons["BackButton"].tap()
        XCTAssertTrue(app.buttons["Add player"].waitForExistence(timeout: 5))
    }

    func testCreateGameFlow() throws {
        tapTab("teams")
        createTeam("Falcons")
        createTeam("Rockets")
        createGame()
        XCTAssertTrue(app.staticTexts["Falcons vs Rockets"].waitForExistence(timeout: 8))
        app.staticTexts["Falcons vs Rockets"].tap()
        XCTAssertTrue(app.staticTexts["Game Details"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Statistics"].exists)
        XCTAssertTrue(app.buttons["Play-by-Play"].exists)
        XCTAssertTrue(app.buttons["End game"].exists)
        XCTAssertTrue(app.buttons["Export"].exists)
        let detailScreenshot = XCTAttachment(screenshot: app.screenshot())
        detailScreenshot.name = "Game details"
        detailScreenshot.lifetime = .keepAlways
        add(detailScreenshot)
    }

    func testScoreModeAndUndoFlow() throws {
        tapTab("teams")
        createTeam("Falcons")
        createTeam("Rockets")
        createGame()
        app.staticTexts["Falcons vs Rockets"].tap()
        XCTAssertTrue(app.buttons["Score"].waitForExistence(timeout: 5))
        app.buttons["Score"].tap()
        XCTAssertTrue(app.buttons["Score Mode"].waitForExistence(timeout: 8))
        sleep(1)
        // Score mode records +2 without a player dialog.
        app.buttons["Score Mode"].tap()
        XCTAssertTrue(app.buttons["Stat Mode"].waitForExistence(timeout: 5))
        let awayTwo = app.buttons["score-2-Rockets"]
        XCTAssertTrue(awayTwo.waitForExistence(timeout: 5))
        awayTwo.tap()
        let awayScore = app.staticTexts["score-value-Rockets"]
        XCTAssertTrue(awayScore.waitForExistence(timeout: 5))
        XCTAssertEqual(awayScore.label, "2")
        app.buttons["Undo"].tap()
        XCTAssertEqual(awayScore.label, "0")
        // Period/Time opens the wheel editor with Cancel/Save on top.
        app.buttons["Period/Time"].tap()
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        // Exit is position two while idle; Start turns it into Stop.
        XCTAssertTrue(app.buttons["recorder_pos2"].label == "Exit")
        app.buttons["recorder_pos1"].tap()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 5))
        app.buttons["Stop"].tap()
        XCTAssertTrue(app.buttons["Exit"].waitForExistence(timeout: 5))
        app.buttons["Exit"].tap()
        XCTAssertTrue(app.staticTexts["Game Details"].waitForExistence(timeout: 8))
    }

    func testStatModeFreeThrowAndFoulDialogs() throws {
        tapTab("teams")
        createTeam("Falcons")
        app.staticTexts["Falcons"].tap()
        addPlayer(first: "Alex", last: "Chen", number: "7")
        app.buttons["BackButton"].tap()
        createTeam("Rockets")
        app.staticTexts["Rockets"].tap()
        addPlayer(first: "Ben", last: "Diaz", number: "9")
        app.buttons["BackButton"].tap()
        createGame()
        app.staticTexts["Falcons vs Rockets"].tap()
        XCTAssertTrue(app.buttons["Score"].waitForExistence(timeout: 5))
        app.buttons["Score"].tap()
        XCTAssertTrue(app.buttons["Free Throw"].firstMatch.waitForExistence(timeout: 8))
        sleep(1)
        // Free Throw: Select shooter offers Assign later and Choose number.
        app.buttons["Free Throw"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Select shooter"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Assign later"].exists)
        XCTAssertTrue(app.buttons["Choose number"].exists)
        app.buttons["Cancel"].tap()
        // Foul: two steps, the second one lists the opposing team.
        app.buttons["Foul"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Who committed the foul?"].waitForExistence(timeout: 5))
        app.buttons["Assign later"].tap()
        XCTAssertTrue(app.staticTexts["Who was fouled?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Previous"].exists)
        app.buttons["Cancel"].tap()
        // Sub is one toggle list with Save.
        app.buttons["Sub"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Substitution"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Exit"].exists)
        app.buttons["Exit"].tap()
        XCTAssertTrue(app.staticTexts["Game Details"].waitForExistence(timeout: 8))
    }

    // Utility, not a regression test: parks the app on the live score screen for ten
    // minutes so a person can inspect the layout on the device. Run it alone with
    // -only-testing; it is skipped in normal suite runs via the HOLD_SCREEN env toggle.
    func testHoldScoreModeForManualReview() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HOLD_SCREEN"] == "1", "manual utility; set HOLD_SCREEN=1 to run")
        // Reuse the data already on the device instead of rebuilding fixtures each run.
        app.terminate()
        app.launchArguments.removeAll { $0 == "-ui-testing" }
        app.launch()
        tapTab("games")
        let existingGame = app.staticTexts.matching(NSPredicate(format: "label CONTAINS ' vs '")).firstMatch
        if existingGame.waitForExistence(timeout: 5) {
            existingGame.tap()
        } else {
            tapTab("teams")
            createTeam("Falcons")
            createTeam("Rockets")
            createGame()
            app.staticTexts["Falcons vs Rockets"].tap()
        }
        XCTAssertTrue(app.buttons["Score"].waitForExistence(timeout: 5))
        app.buttons["Score"].tap()
        XCTAssertTrue(app.buttons["Free Throw"].firstMatch.waitForExistence(timeout: 8))
        sleep(600)
    }

    // Utility, not a regression test: parks the app on the bottom of Settings for ten
    // minutes so a person can check the About card and the installed version.
    func testHoldSettingsVersionForManualReview() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HOLD_SCREEN"] == "1", "manual utility; set HOLD_SCREEN=1 to run")
        app.terminate()
        app.launchArguments.removeAll { $0 == "-ui-testing" }
        app.launch()
        tapTab("settings")
        let version = app.staticTexts["Version"].firstMatch
        for _ in 0..<6 where !version.isHittable { app.swipeUp() }
        XCTAssertTrue(version.waitForExistence(timeout: 5))
        sleep(600)
    }

    // Utility, not a regression test: parks the app on the sign-in dialog (with the
    // Sign in with Apple button) for ten minutes so a person can inspect it on the device.
    func testHoldSignInDialogForManualReview() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HOLD_SCREEN"] == "1", "manual utility; set HOLD_SCREEN=1 to run")
        app.terminate()
        app.launchArguments.removeAll { $0 == "-ui-testing" }
        app.launch()
        let signIn = app.buttons["Sign in"].firstMatch
        if !signIn.waitForExistence(timeout: 5) {
            // Signed in: sign out through the account menu first, like a user would.
            app.buttons["account-button"].firstMatch.tap()
            let signOut = app.buttons["Sign out"].firstMatch
            XCTAssertTrue(signOut.waitForExistence(timeout: 5))
            signOut.tap()
        }
        XCTAssertTrue(signIn.waitForExistence(timeout: 5))
        signIn.tap()
        XCTAssertTrue(app.buttons["Sign in with Apple"].firstMatch.waitForExistence(timeout: 8))
        sleep(600)
    }

    // Utility, not a regression test: opens the sign-in dialog and taps Continue with Google,
    // then holds for ten minutes so a person can inspect the browser sign-in sheet on the device.
    func testHoldGoogleSignInForManualReview() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HOLD_SCREEN"] == "1", "manual utility; set HOLD_SCREEN=1 to run")
        app.terminate()
        app.launchArguments.removeAll { $0 == "-ui-testing" }
        app.launch()
        let signIn = app.buttons["Sign in"].firstMatch
        if !signIn.waitForExistence(timeout: 5) {
            app.buttons["account-button"].firstMatch.tap()
            let signOut = app.buttons["Sign out"].firstMatch
            XCTAssertTrue(signOut.waitForExistence(timeout: 5))
            signOut.tap()
        }
        XCTAssertTrue(signIn.waitForExistence(timeout: 5))
        signIn.tap()
        let google = app.buttons["Continue with Google"].firstMatch
        XCTAssertTrue(google.waitForExistence(timeout: 8))
        sleep(2)
        google.tap()
        sleep(600)
    }

    // End-to-end Google sign-in through our own web API (no Supabase provider): taps Continue
    // with Google, picks GOOGLE_E2E_ACCOUNT in the web-auth sheet (the device's Safari must already
    // be signed in to that Google account) and expects the home screen to show the signed-in state.
    // Needs the network and a real account, so it only runs with GOOGLE_E2E=1.
    func testGoogleSignInEndToEnd() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GOOGLE_E2E"] == "1", "needs a real Google account; set GOOGLE_E2E=1 to run")
        let account = ProcessInfo.processInfo.environment["GOOGLE_E2E_ACCOUNT"] ?? "myconnectedai@gmail.com"
        app.terminate()
        app.launchArguments.removeAll { $0 == "-ui-testing" }
        app.launch()
        let signIn = app.buttons["Sign in"].firstMatch
        if !signIn.waitForExistence(timeout: 5) {
            app.buttons["account-button"].firstMatch.tap()
            let signOut = app.buttons["Sign out"].firstMatch
            XCTAssertTrue(signOut.waitForExistence(timeout: 5))
            signOut.tap()
        }
        XCTAssertTrue(signIn.waitForExistence(timeout: 5))
        signIn.tap()
        // The button's label is its two texts joined ("G, Continue with Google"), so match loosely.
        let google = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Continue with Google'")).firstMatch
        XCTAssertTrue(google.waitForExistence(timeout: 8))
        google.tap()
        // The "wants to use google.com to sign in" alert belongs to SpringBoard.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let consentHosts: [XCUIApplication] = [app, springboard]
        let consentDeadline = Date().addingTimeInterval(20)
        while Date() < consentDeadline {
            let buttons = consentHosts.flatMap { [$0.alerts.buttons["Continue"].firstMatch, $0.buttons["Continue"].firstMatch] }
            if let consent = buttons.first(where: { $0.exists }) { consent.tap(); break }
            sleep(1)
        }
        // Google's account chooser renders inside the web-auth sheet; the account row carries the email.
        let byEmail = NSPredicate(format: "label CONTAINS[c] %@", account)
        let hosts: [XCUIApplication] = [app, springboard, XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")]
        let candidates = hosts.flatMap { [$0.links.matching(byEmail).firstMatch, $0.staticTexts.matching(byEmail).firstMatch, $0.buttons.matching(byEmail).firstMatch] }
        let deadline = Date().addingTimeInterval(40)
        var tapped = false
        while Date() < deadline && !tapped {
            if let row = candidates.first(where: { $0.exists }) { row.tap(); tapped = true } else { sleep(1) }
        }
        let sheet = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); sheet.name = "google sign-in sheet"; sheet.lifetime = .keepAlways; add(sheet)
        XCTAssertTrue(tapped, "Google account \(account) was not offered in the sign-in sheet")
        XCTAssertTrue(app.buttons["account-button"].firstMatch.waitForExistence(timeout: 60), "not signed in after Google sign-in")
        XCTAssertTrue(app.staticTexts["Signed in"].firstMatch.waitForExistence(timeout: 30))
        let home = XCTAttachment(screenshot: app.screenshot()); home.name = "signed in with Google"; home.lifetime = .keepAlways; add(home)
    }

    // Utility, not a regression test: walks the App Review account-deletion flow at a human
    // pace so the screen can be recorded on a physical device: create a fresh account, wait
    // while its confirmation email is opened (production requires a confirmed email), sign in,
    // open Settings, and delete the account. It runs against the isolated `-ui-testing` store,
    // so the deletion never touches the device's real games or videos. Pass the throwaway
    // account as REVIEW_EMAIL / REVIEW_PASSWORD (TEST_RUNNER_ prefix through xcodebuild).
    func testRecordAccountDeletionFlow() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["RECORD_DELETE"] == "1", "manual utility; set RECORD_DELETE=1 to run")
        let reviewEmail = try XCTUnwrap(env["REVIEW_EMAIL"], "set REVIEW_EMAIL")
        let reviewPassword = try XCTUnwrap(env["REVIEW_PASSWORD"], "set REVIEW_PASSWORD")
        let confirmWait = UInt32(env["CONFIRM_WAIT"] ?? "") ?? 150

        let settingsTab = app.buttons["tab-settings"].firstMatch
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 8))
        settingsTab.tap()
        app.swipeUp()
        let signOut = app.buttons["Sign out"].firstMatch
        if signOut.waitForExistence(timeout: 3) { signOut.tap(); sleep(1) }
        let signIn = app.buttons["Sign in"].firstMatch
        XCTAssertTrue(signIn.waitForExistence(timeout: 5))
        sleep(2)
        signIn.tap()

        // SIGN_IN_ONLY=1 signs in to an already confirmed account instead of creating one.
        let signInOnly = env["SIGN_IN_ONLY"] == "1"
        if !signInOnly {
            let create = app.buttons["New here? Create account"].firstMatch
            XCTAssertTrue(create.waitForExistence(timeout: 8))
            sleep(1)
            create.tap()
        }
        // The field may be prefilled with the last remembered email; clear it first.
        let email = app.textFields.firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        email.tap()
        let existing = (email.value as? String) ?? ""
        if !existing.isEmpty, existing != email.placeholderValue {
            email.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        email.typeText(reviewEmail)
        if !signInOnly {
            enterPasswordAndTap("Create account", title: "Create sync account", password: reviewPassword)
            // Production sends a confirmation email; the dialog switches back to sign-in.
            let checkEmail = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Check your email'")).firstMatch
            XCTAssertTrue(checkEmail.waitForExistence(timeout: 20), "sign-up did not ask for email confirmation")
            sleep(confirmWait)
        }
        enterPasswordAndTap("Sign in & sync", title: "Sign in to sync", password: reviewPassword)

        // Account actions sit at the bottom of Settings.
        let deleteButton = app.buttons.matching(NSPredicate(format: "label == 'Delete Account'")).firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 30), "sign-in did not complete")
        sleep(2)
        for _ in 0..<4 where !deleteButton.isHittable { app.swipeUp(); sleep(1) }
        sleep(2)
        deleteButton.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'This permanently deletes'")).firstMatch.waitForExistence(timeout: 5))
        sleep(3)
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Delete Account'"))
        confirm.element(boundBy: confirm.count - 1).tap()

        XCTAssertTrue(app.staticTexts["Account deleted"].firstMatch.waitForExistence(timeout: 20))
        sleep(2)
        for _ in 0..<3 where !app.buttons["Sign in"].firstMatch.isHittable { app.swipeDown(); sleep(1) }
        XCTAssertTrue(app.buttons["Sign in"].firstMatch.exists)
        sleep(5)
    }

    /// Types the password into the auth dialog, dismisses the keyboard by tapping the dialog
    /// title, then taps the dialog's primary button once it is enabled.
    private func enterPasswordAndTap(_ buttonLabel: String, title: String, password: String) {
        let field = app.secureTextFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(password)
        sleep(1)
        app.staticTexts[title].firstMatch.tap()
        sleep(1)
        let button = app.buttons.matching(NSPredicate(format: "label == %@ AND enabled == true", buttonLabel)).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func createTeam(_ name: String) {
        let addTeam = app.buttons["add-team-button"].firstMatch
        XCTAssertTrue(addTeam.waitForExistence(timeout: 8))
        addTeam.tap()
        let field = app.textFields["team-name-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(name)
        app.buttons["team-save-button"].tap()
    }

    private func addPlayer(first: String, last: String, number: String) {
        app.buttons["add-player-button"].tap()
        let firstField = app.textFields["player-first-name-field"]
        XCTAssertTrue(firstField.waitForExistence(timeout: 5))
        firstField.tap(); firstField.typeText(first)
        app.textFields["player-last-name-field"].tap(); app.textFields["player-last-name-field"].typeText(last)
        app.textFields["player-number-field"].tap(); app.textFields["player-number-field"].typeText(number)
        app.buttons["player-save-button"].tap()
    }

    private func createGame() {
        tapTab("games")
        app.buttons["Create Game"].firstMatch.tap()
        XCTAssertTrue(app.buttons["game-create-button"].waitForExistence(timeout: 5))
        // The form preselects the first two teams; pick them explicitly anyway. The picker button
        // itself carries the selected team's name, so the menu item is matched by identifier.
        app.buttons["home-team-picker"].tap()
        menuItem("Falcons").tap()
        app.buttons["away-team-picker"].tap()
        menuItem("Rockets").tap()
        app.buttons["game-create-button"].tap()
    }

    private func menuItem(_ label: String) -> XCUIElement {
        let item = app.buttons.matching(NSPredicate(format: "label == %@ AND NOT (identifier CONTAINS 'picker')", label)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        return item
    }

    private func tapTab(_ key: String) {
        let tab = app.buttons["tab-\(key)"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 12))
        tab.tap()
    }
}
