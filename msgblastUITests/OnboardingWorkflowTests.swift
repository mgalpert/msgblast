import XCTest

final class OnboardingWorkflowTests: XCTestCase {
    @MainActor
    private func launch(contactsDenied: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo", "--onboarding-preview"]
        if contactsDenied { app.launchArguments.append("--contacts-access-preview") }
        app.launch()
        XCTAssertTrue(app.staticTexts["Allow access"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    private func choose(_ connector: String, in app: XCUIApplication) {
        let next = app.buttons["continue-permissions"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: next)
        waitForExpectations(timeout: 5)
        next.click()
        XCTAssertTrue(app.staticTexts["Choose your agents"].waitForExistence(timeout: 5))
        if connector == "Messages" { selectChoice("Fo", in: app) }
    }

    @MainActor
    private func revealChoice(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: 10000)
        let choice = app.buttons["Choose \(name)"]
        for _ in 0..<16 where !choice.isHittable {
            app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -240)
        }
        XCTAssertTrue(choice.isHittable)
        return choice
    }

    @MainActor
    private func selectChoice(_ name: String, in app: XCUIApplication) {
        revealChoice(name, in: app).click()
    }

    @MainActor
    func testUnifiedPermissionsPrecedeAllAgentGroupsAndSelectionIsRequired() {
        let app = launch()
        defer { app.terminate() }
        for identifier in ["messages-history", "messages-contacts", "messages-automation", "cua-host", "cua-driver", "cua-capture"] {
            XCTAssertTrue(app.staticTexts["permission-status-\(identifier)"].exists)
        }
        XCTAssertFalse(app.buttons["Choose ChatGPT App"].exists)
        choose("Apps", in: app)
        XCTAssertFalse(app.buttons["Continue setup"].isEnabled)
        for name in ["Fo", "ChatGPT App", "ChatGPT", "Codex CLI", "Claude Code", "OpenClaw", "Hermes"] {
            XCTAssertTrue(revealChoice(name, in: app).exists)
        }
        selectChoice("ChatGPT App", in: app)
        XCTAssertTrue(app.buttons["Continue setup"].isEnabled)
        app.buttons["Back"].click()
        XCTAssertTrue(app.staticTexts["Allow access"].waitForExistence(timeout: 5))
        choose("Apps", in: app)
        XCTAssertEqual(app.buttons["Choose ChatGPT App"].value as? String, "Installed on this Mac. Selected")
    }

    @MainActor
    func testPartialPermissionsCannotContinueUntilOneWholeSectionIsReady() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo", "--onboarding-preview", "--onboarding-permissions-preview", "--contacts-access-preview"]
        app.launch()
        defer { app.terminate() }
        let next = app.buttons["continue-permissions"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        let host = app.buttons["enable-cua-host-permission"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: host)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(next.isEnabled)
        for _ in 0..<8 where !host.isHittable { app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -160) }
        host.click()
        XCTAssertEqual(app.staticTexts["permission-status-cua-host"].value as? String, "Allowed")
        XCTAssertFalse(next.isEnabled, "One Accessibility grant does not complete App access")
        let driver = app.buttons["enable-cua-driver-permission"]
        for _ in 0..<8 where !driver.isHittable { app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -160) }
        driver.click()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: next)
        waitForExpectations(timeout: 5)
        XCTAssertNotEqual(app.staticTexts["permission-status-messages-contacts"].value as? String, "Allowed")
        next.click()
        XCTAssertTrue(app.staticTexts["Choose your agents"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Choose Fo"].isEnabled)
        XCTAssertTrue(revealChoice("ChatGPT App", in: app).isEnabled)
    }

    @MainActor
    func testGeminiSetupOffersChatTaskModelsAndThinkingInsideMsgblast() {
        let app = launch()
        defer { app.terminate() }
        choose("Apps", in: app)
        selectChoice("Gemini", in: app)
        app.buttons["Continue setup"].click()
        XCTAssertTrue(app.staticTexts["Connect your agents"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["permission-status-cua-host"].exists)
        let check = app.buttons["Connect Gemini"]
        for _ in 0..<8 where !check.isHittable { app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -200) }
        check.click()
        let models = app.popUpButtons["gemini-model-picker"]
        XCTAssertTrue(models.waitForExistence(timeout: 5))
        for _ in 0..<8 where !models.isHittable { app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -200) }
        models.click()
        app.menuItems["4 Argon · Complex tasks"].click()
        let thinking = app.popUpButtons["gemini-thinking-picker"]
        XCTAssertTrue(thinking.waitForExistence(timeout: 5))
        thinking.click()
        app.menuItems["High, Extra thorough"].click()
        XCTAssertEqual(thinking.value as? String, "High, Extra thorough")
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Gemini Chat model and thinking — simulated native options"
        screenshot.lifetime = .keepAlways; add(screenshot)
        let mode = app.segmentedControls["gemini-mode-picker"]
        mode.buttons["Task"].click()
        expectation(for: NSPredicate(format: "value == %@", "3.8 Flash · All-around help"), evaluatedWith: models)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(thinking.exists)
        XCTAssertTrue(app.buttons["Continue"].isEnabled)
        XCTAssertEqual(app.webViews.count, 0)
        let task = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        task.name = "Gemini Task mode — simulated native options"
        task.lifetime = .keepAlways; add(task)
    }

    @MainActor
    func testWabiOnboardingConfirmsDedicatedChatBeforeFirstPrompt() {
        let app = launch()
        defer { app.terminate() }
        choose("Apps", in: app)
        let wabi = app.buttons["Choose Wabi"]
        XCTAssertTrue(wabi.waitForExistence(timeout: 5))
        selectChoice("Wabi", in: app)
        expectation(for: NSPredicate(format: "value == %@", "Installed on this Mac. Selected"), evaluatedWith: wabi)
        waitForExpectations(timeout: 5)
        let next = app.buttons["Continue setup"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: next)
        waitForExpectations(timeout: 5)
        next.click()
        XCTAssertTrue(app.staticTexts["Connect your agents"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["permission-status-cua-host"].exists)
        XCTAssertFalse(app.buttons["Continue"].isEnabled)
        XCTAssertFalse(app.staticTexts["Ready for your first prompt"].exists)
        let check = app.buttons["Connect Wabi"]
        for _ in 0..<6 where !check.isHittable { app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -200) }
        XCTAssertTrue(check.isHittable)
        check.click()
        XCTAssertTrue(app.staticTexts["Ready for your first prompt"].waitForExistence(timeout: 5))
        let confirmation = "Your first prompt in a new comparison starts a dedicated AI chat in Wabi. Follow-ups stay in that chat. This check didn’t send a message."
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value == %@", confirmation)).firstMatch.exists)
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["Continue"])
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.webViews.count, 0)
    }

    @MainActor
    func testGrokBotIsChosenInsideMsgblastAndConnectsWithoutAnExtraCheck() {
        let app = launch()
        defer { app.terminate() }
        choose("Apps", in: app)
        selectChoice("Grok Bot App", in: app)
        app.buttons["Continue setup"].click()
        let picker = app.popUpButtons["grok-bot-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        for _ in 0..<6 where !picker.isHittable { app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -200) }
        XCTAssertFalse(app.buttons["Continue"].isEnabled)
        XCTAssertTrue(app.buttons["Connect Grok Bot App"].exists)
        picker.click()
        app.menuItems["Research Bot"].click()
        XCTAssertTrue(app.staticTexts["Ready for your first prompt"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Research Bot")).firstMatch.exists)
        XCTAssertTrue(app.buttons["Continue"].isEnabled)
        XCTAssertEqual(app.webViews.count, 0)
    }

    @MainActor
    func testMuseChecksConnectionAfterGlobalPermissionsWithoutBrowserImport() {
        let app = launch()
        defer { app.terminate() }
        choose("Apps", in: app)
        for name in ["Muse App", "Grok Bot App", "Wabi"] {
            let installedApp = app.buttons["Choose \(name)"]
            XCTAssertTrue(installedApp.waitForExistence(timeout: 5))
            XCTAssertTrue(installedApp.isEnabled)
            XCTAssertEqual(installedApp.value as? String, "Installed on this Mac. Not selected")
        }
        let muse = app.buttons["Choose Muse App"]
        selectChoice("Muse App", in: app)
        expectation(for: NSPredicate(format: "value == %@", "Installed on this Mac. Selected"), evaluatedWith: muse)
        waitForExpectations(timeout: 5)
        let continueSetup = app.buttons["Continue setup"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: continueSetup)
        waitForExpectations(timeout: 5)
        continueSetup.click()
        XCTAssertTrue(app.staticTexts["Connect your agents"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["permission-status-cua-host"].exists)
        XCTAssertEqual(app.webViews.count, 0, "A desktop app must not open a website sign-in flow")
        XCTAssertFalse(app.buttons["Continue"].isEnabled)
        XCTAssertFalse(app.staticTexts["Ready for your first prompt"].exists)
        let connect = app.buttons["Connect Muse App"]
        for _ in 0..<6 where !connect.isHittable { app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -200) }
        XCTAssertTrue(connect.isHittable)
        connect.click()
        XCTAssertTrue(app.staticTexts["Ready for your first prompt"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Your first prompt in a new comparison starts a new side chat in Muse. This check didn’t send a message."].exists)
        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["Continue"])
        waitForExpectations(timeout: 5)
        app.buttons["Back"].click()
        app.buttons["Continue setup"].click()
        XCTAssertTrue(app.staticTexts["Connect your agents"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Continue"].isEnabled, "A saved binding still requires an explicit live check")
        XCTAssertFalse(app.staticTexts["Ready for your first prompt"].exists, "A cached check must not show a new confirmation")
        let reconnect = app.buttons["Connect Muse App"]
        for _ in 0..<6 where !reconnect.isHittable { app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -200) }
        reconnect.click()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["Continue"])
        waitForExpectations(timeout: 5)
        app.buttons["Continue"].click()
        XCTAssertTrue(app.staticTexts["Help shape msgblast"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testNativeConnectionsShareOneChecklistAndContinueRequiresEveryRowResolved() {
        let app = launch()
        defer { app.terminate() }
        choose("Apps", in: app)
        for name in ["ChatGPT App", "Dots App", "Claude App"] { selectChoice(name, in: app) }
        app.buttons["Continue setup"].click()
        XCTAssertTrue(app.staticTexts["Connect your agents"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Continue"].isEnabled)
        XCTAssertFalse(app.switches["Enable ChatGPT App"].exists)
        app.buttons["Connect ChatGPT App"].click()
        XCTAssertTrue(app.staticTexts["Ready for your first prompt"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Continue"].isEnabled, "One ready app must not bypass unresolved selected apps")
        app.buttons["Skip Dots App"].click()
        XCTAssertFalse(app.buttons["Continue"].isEnabled)
        app.buttons["Connect Claude App"].click()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["Continue"])
        waitForExpectations(timeout: 5)
        app.buttons["Continue"].click()
        XCTAssertTrue(app.staticTexts["Help shape msgblast"].waitForExistence(timeout: 5), "Native apps complete in one batch")
    }

    @MainActor
    func testIncompleteMessagingSectionLocksItsAgentsWhileAppsCanContinue() {
        let app = launch(contactsDenied: true)
        defer { app.terminate() }
        choose("Apps", in: app)
        XCTAssertFalse(app.buttons["Choose Fo"].isEnabled)
        XCTAssertTrue(app.buttons["Choose ChatGPT App"].isEnabled)
        app.buttons["Back"].click()
        let contacts = app.buttons["enable-messages-contacts-permission"]
        XCTAssertTrue(contacts.waitForExistence(timeout: 5))
        contacts.click()
        app.buttons["check-onboarding-permissions"].click()
        choose("Apps", in: app)
        XCTAssertTrue(app.buttons["Choose Fo"].isEnabled)
        XCTAssertFalse(app.buttons["Continue setup"].isEnabled)
    }

    @MainActor
    func testDiscoveredMessagesCanBeDeselectedAndContactsSearched() {
        let app = launch()
        defer { app.terminate() }
        choose("Messages", in: app)
        app.buttons["Continue setup"].click()
        XCTAssertTrue(app.buttons["Deselect Fo"].waitForExistence(timeout: 5))
        app.buttons["Deselect Fo"].click()
        XCTAssertTrue(app.buttons["Select Fo"].waitForExistence(timeout: 5))
        app.buttons["Select Fo"].click()
        app.buttons["Search for more agents in Messages"].click()
        XCTAssertTrue(app.textFields["Find onboarding contact"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].click()
        app.buttons["Add other agents"].click()
        XCTAssertTrue(app.staticTexts["Choose your agents"].waitForExistence(timeout: 5))
        app.buttons["Back"].click()
        XCTAssertTrue(app.staticTexts["Allow access"].waitForExistence(timeout: 5))
        choose("Apps", in: app)
        app.buttons["Continue setup"].click()
        XCTAssertTrue(app.buttons["Start chatting"].waitForExistence(timeout: 5), "Permission review must retain completed agent setup")
    }

    @MainActor
    func testMessagesContinueGoesToContributionWithoutRepeatedSelection() {
        let app = launch()
        defer { app.terminate() }
        choose("Messages", in: app)
        app.buttons["Continue setup"].click()
        XCTAssertTrue(app.buttons["Deselect Fo"].waitForExistence(timeout: 5))
        app.buttons["Continue setup"].click()
        XCTAssertTrue(app.staticTexts["Help shape msgblast"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Choose who to connect"].exists)
        XCTAssertTrue(app.buttons["Start chatting"].exists)
    }

    @MainActor
    func testFinishedSetupShowsChosenAgentsWithoutSelectingRecipients() {
        let app = launch()
        defer { app.terminate() }
        choose("Messages", in: app)
        selectChoice("Instinct", in: app)
        app.buttons["Continue setup"].click()
        XCTAssertTrue(app.buttons["Deselect Fo"].waitForExistence(timeout: 5))
        app.buttons["Deselect Fo"].click()
        app.buttons["Continue setup"].click()
        XCTAssertTrue(app.buttons["Start chatting"].waitForExistence(timeout: 5))
        app.buttons["Back"].click()
        XCTAssertTrue(app.staticTexts["Choose your agents"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["Choose Fo"].value as? String, "Not selected")
        app.buttons["Continue setup"].click()
        app.buttons["Start chatting"].click()
        XCTAssertTrue(app.buttons["Edit agents"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Fo"].exists)
        XCTAssertEqual(app.buttons["Instinct"].value as? String, "Not selected")
        XCTAssertFalse(app.buttons["Add Messages agents"].exists)
        XCTAssertFalse(app.buttons["New Blast"].exists)
        app.buttons["Edit agents"].click()
        XCTAssertFalse(app.buttons["Restore setup agents"].exists)
        app.buttons["Done editing agents"].click()
        app.buttons["Instinct"].click()
        XCTAssertEqual(app.buttons["Instinct"].value as? String, "Selected")
        app.textViews["Shared prompt"].click()
        app.textViews["Shared prompt"].typeText("Local fixture recipient check")
        app.buttons["Send & compare"].click()
        XCTAssertTrue(app.textViews["Private reply to Instinct"].waitForExistence(timeout: 10))
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.buttons["New Blast"].waitForExistence(timeout: 10))
        app.buttons["New Blast"].click()
        XCTAssertTrue(app.buttons["Edit agents"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["New Blast"].exists, "A saved conversation makes New Blast available")
        XCTAssertFalse(app.buttons["Connect agents"].exists)
    }

    @MainActor
    func testPokeBusinessFixtureMatchesButRequiresExplicitRecipientSelection() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo", "--onboarding-preview", "--business-messages-preview"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Allow access"].waitForExistence(timeout: 5))
        choose("Apps", in: app)
        selectChoice("Poke", in: app)
        app.buttons["Continue setup"].click()
        XCTAssertTrue(app.buttons["Deselect Poke 🌴"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["Deselect Poke 🌴"].value as? String, "Connected · Business conversation")
        XCTAssertFalse(app.buttons["Choose conversation"].exists)
        app.buttons["Continue setup"].click()
        XCTAssertTrue(app.buttons["Start chatting"].waitForExistence(timeout: 5))
        app.buttons["Start chatting"].click()
        XCTAssertTrue(app.buttons["Poke 🌴"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["Poke 🌴"].value as? String, "Not selected")
        app.buttons["Poke 🌴"].click()
        XCTAssertEqual(app.buttons["Poke 🌴"].value as? String, "Selected")
    }

    @MainActor
    func testAppsKeepBrowserImportAndManualConnection() {
        let app = launch()
        defer { app.terminate() }
        choose("Apps", in: app)
        selectChoice("ChatGPT", in: app)
        app.buttons["Continue setup"].click()
        XCTAssertTrue(app.staticTexts["Use your existing logins"].waitForExistence(timeout: 5))
        app.buttons["Skip for now"].click()
        XCTAssertTrue(app.staticTexts["Let’s connect ChatGPT"].waitForExistence(timeout: 5))
        app.buttons["Back"].click()
        XCTAssertTrue(app.staticTexts["Choose your agents"].waitForExistence(timeout: 5))
    }
}
