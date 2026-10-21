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
        if connector == "Messages" {
            expectation(for: NSPredicate(format: "value == %@", "Selected"), evaluatedWith: app.buttons["Choose Fo"])
            waitForExpectations(timeout: 5)
        }
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
    func testSettingsOffersWebAlternativesDisabledForNewUsers() {
        let app = launch()
        defer { app.terminate() }
        app.typeKey(",", modifierFlags: .command)
        let chatgpt = app.switches["enable-web-chatgpt"]
        XCTAssertTrue(chatgpt.waitForExistence(timeout: 5))
        for provider in ["muse", "chatgpt", "claude", "dots", "grok"] {
            let toggle = app.switches["enable-web-\(provider)"]
            XCTAssertTrue(toggle.exists)
            let value = toggle.value
            let enabled = (value as? NSNumber)?.boolValue ?? (value as? String).flatMap {
                ["1", "on"].contains($0) ? true : ["0", "off"].contains($0) ? false : nil
            }
            XCTAssertEqual(enabled, false, "New installations must opt into web agents")
        }
    }

    @MainActor
    func testNativeChoicesReplaceWebAlternativesInOnboarding() {
        let app = launch()
        defer { app.terminate() }
        choose("Apps", in: app)
        for name in ["Muse", "ChatGPT", "Claude", "Dots", "Grok"] {
            XCTAssertFalse(app.buttons["Choose \(name)"].exists)
        }
        for name in ["Muse App", "ChatGPT App", "Claude App", "Dots App", "Grok Bot App", "Wabi", "Gemini"] {
            XCTAssertTrue(app.buttons["Choose \(name)"].exists)
        }
    }

    @MainActor
    func testUnifiedPermissionsPrecedeAllAgentGroupsAndSelectionIsRequired() {
        let app = launch(contactsDenied: true)
        defer { app.terminate() }
        XCTAssertFalse(app.buttons["check-onboarding-permissions"].exists)
        XCTAssertEqual(app.scrollViews.count, 0, "Permission setup fits without scrolling")
        XCTAssertFalse(app.staticTexts["System Settings · Privacy & Security"].exists)
        XCTAssertTrue(app.switches["enable-cua-driver-permission"].exists)
        XCTAssertFalse(app.buttons["Manage"].exists)
        XCTAssertFalse(app.staticTexts["Messaging agents"].exists)
        XCTAssertFalse(app.staticTexts["App agents"].exists)
        for identifier in ["messages-history", "messages-contacts", "messages-automation", "cua-host", "cua-driver", "cua-capture"] {
            XCTAssertTrue(app.switches["enable-\(identifier)-permission"].exists)
        }
        XCTAssertFalse(app.buttons["Choose ChatGPT App"].exists)
        choose("Apps", in: app)
        XCTAssertFalse(app.buttons["Continue setup"].isEnabled)
        XCTAssertTrue(app.buttons["Choose Fo"].exists)
        XCTAssertFalse(app.buttons["Choose Fo"].isEnabled)
        for name in ["ChatGPT App", "Codex CLI", "Claude Code", "OpenClaw", "Hermes"] {
            XCTAssertTrue(revealChoice(name, in: app).exists)
        }
        for name in ["Muse", "ChatGPT", "Claude", "Dots", "Grok"] {
            XCTAssertFalse(app.buttons["Choose \(name)"].exists, "Web alternatives are enabled in Settings")
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
        let host = app.switches["enable-cua-host-permission"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: host)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(next.isEnabled)
        XCTAssertTrue(host.isHittable)
        host.click()
        XCTAssertEqual((app.switches["enable-cua-host-permission"].value as? NSNumber)?.boolValue, true)
        XCTAssertFalse(next.isEnabled, "One Accessibility grant does not complete App access")
        let driver = app.switches["enable-cua-driver-permission"]
        XCTAssertTrue(driver.isHittable)
        driver.click()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: next)
        waitForExpectations(timeout: 5)
        XCTAssertEqual((app.switches["enable-messages-contacts-permission"].value as? NSNumber)?.boolValue, false)
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
        app.buttons["Start chatting"].click()
        XCTAssertTrue(app.buttons["ChatGPT App"].waitForExistence(timeout: 5))
        app.buttons["ChatGPT App"].click()
        app.buttons["Claude App"].click()
        let prompt = app.textViews["Shared prompt"]
        prompt.click(); prompt.typeText("Clean native conversation fixture")
        app.buttons["Send & compare"].click()
        XCTAssertTrue(app.textViews["Message ChatGPT App"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["desktop-app-installation"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["desktop-connection-confirmation"].exists)
        XCTAssertFalse(app.switches["Enable ChatGPT App"].exists)
        XCTAssertFalse(app.buttons["Check installation"].exists)
        app.buttons["ChatGPT App options"].click()
        XCTAssertTrue(app.staticTexts["desktop-app-installation"].waitForExistence(timeout: 5))
        app.buttons["Done"].click()
        XCTAssertFalse(app.staticTexts["desktop-app-installation"].exists)
    }

    @MainActor
    func testIncompleteMessagingSectionLocksItsAgentsWhileAppsCanContinue() {
        let app = launch(contactsDenied: true)
        defer { app.terminate() }
        choose("Apps", in: app)
        XCTAssertFalse(app.buttons["Choose Fo"].isEnabled)
        XCTAssertTrue(app.buttons["Choose ChatGPT App"].isEnabled)
        app.buttons["Back"].click()
        let contacts = app.switches["enable-messages-contacts-permission"]
        XCTAssertTrue(contacts.waitForExistence(timeout: 5))
        contacts.click()
        choose("Apps", in: app)
        XCTAssertTrue(app.buttons["Choose Fo"].isEnabled)
        XCTAssertEqual(app.buttons["Choose Fo"].value as? String, "Selected")
        XCTAssertTrue(app.buttons["Continue setup"].isEnabled, "Granting Messaging access adds existing agents automatically")
    }

    @MainActor
    func testMessagesAreAddedWithoutDiscoveryOrConversationPicker() {
        let app = launch()
        defer { app.terminate() }
        choose("Messages", in: app)
        XCTAssertEqual(app.buttons["Choose Fo"].value as? String, "Selected")
        XCTAssertEqual(app.buttons["Choose Instinct"].value as? String, "Selected")
        XCTAssertFalse(app.staticTexts["Agents we found"].exists)
        XCTAssertFalse(app.buttons["Search for more agents in Messages"].exists)
        XCTAssertFalse(app.textFields["Find onboarding contact"].exists)
        app.buttons["Continue setup"].click()
        XCTAssertTrue(app.staticTexts["Help shape msgblast"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Start chatting"].exists)
    }

    @MainActor
    func testFinishedSetupShowsChosenAgentsWithoutSelectingRecipients() {
        let app = launch()
        defer { app.terminate() }
        choose("Messages", in: app)
        selectChoice("Fo", in: app)
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
        XCTAssertEqual(app.buttons["Choose Poke"].value as? String, "Selected")
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
        selectChoice("Hark", in: app)
        app.buttons["Continue setup"].click()
        XCTAssertTrue(app.staticTexts["Use your existing logins"].waitForExistence(timeout: 5))
        app.buttons["Skip for now"].click()
        XCTAssertTrue(app.staticTexts["Let’s connect Hark"].waitForExistence(timeout: 5))
        app.buttons["Back"].click()
        XCTAssertTrue(app.staticTexts["Choose your agents"].waitForExistence(timeout: 5))
    }
}
