import XCTest

final class OnboardingWorkflowTests: XCTestCase {
    @MainActor
    func testExactMessagesContactsUseOneConfirmationAndUncheckedAgentsAreSkipped() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo", "--onboarding-preview"]
        app.launch()
        defer { app.terminate() }
        for name in ["Fo", "Instinct", "Szn"] { app.buttons["Choose \(name)"].click() }
        app.buttons["Continue setup"].click()
        for name in ["Fo", "Instinct", "Szn"] {
            let row = app.buttons["Select \(name)"]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            XCTAssertEqual(row.value as? String, "Selected")
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "Contact for \(name)").firstMatch.exists)
        }
        XCTAssertFalse(app.textFields["Find onboarding contact"].exists)
        XCTAssertFalse(app.buttons["New Blast"].exists)
        XCTAssertFalse(app.buttons["Use contact"].exists)
        XCTAssertFalse(app.buttons["Search instead"].exists)
        XCTAssertFalse(app.buttons["Skip Szn"].exists)
        XCTAssertEqual(app.descendants(matching: .scrollBar).count, 0)
        app.buttons["Select Szn"].click()
        app.buttons["Connect selected"].click()
        XCTAssertTrue(app.buttons["Start chatting"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["New Blast"].exists)
        app.buttons["Start chatting"].click()
        XCTAssertTrue(app.buttons["New Blast"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Fo"].exists)
        XCTAssertTrue(app.buttons["Instinct"].exists)
        XCTAssertFalse(app.buttons["Szn"].exists)
        XCTAssertTrue(app.buttons["Finish setup"].exists)
    }

    @MainActor
    func testUncheckedMessagesRowsCannotFinishWithoutAConnectedAgent() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo", "--onboarding-preview"]
        app.launch()
        defer { app.terminate() }
        app.buttons["Choose Fo"].click()
        app.buttons["Continue setup"].click()
        let row = app.buttons["Select Fo"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        XCTAssertFalse(app.buttons["Connect selected"].isEnabled)
        XCTAssertFalse(app.buttons["New Blast"].exists)
        row.click()
        app.buttons["Connect selected"].click()
        XCTAssertTrue(app.buttons["Start chatting"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testUncheckingPreviouslyConfirmedRowsClearsTheirConnections() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo", "--onboarding-preview"]
        app.launch()
        defer { app.terminate() }
        for name in ["Fo", "Szn"] { app.buttons["Choose \(name)"].click() }
        app.buttons["Continue setup"].click()
        let contact = app.descendants(matching: .any).matching(identifier: "Contact for Szn").firstMatch
        XCTAssertTrue(contact.waitForExistence(timeout: 5))
        contact.click()
        app.menuItems["Search Contacts…"].click()
        let query = app.textFields["Find onboarding contact"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        query.click()
        query.typeKey("a", modifierFlags: .command)
        query.typeText("new-szn@example.test")
        let choice = app.buttons["Choose new-szn@example.test contact"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.click()
        app.buttons["Connect selected"].click()
        XCTAssertTrue(app.images["Fo connected"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Start chatting"].exists)
        for name in ["Fo", "Szn"] { app.buttons["Select \(name)"].click() }
        app.buttons["Continue"].click()
        XCTAssertTrue(app.staticTexts["Which agents do you use?"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["New Blast"].exists)
    }

    @MainActor
    func testDisablingTheOnlyConnectedAgentBeforeAcknowledgementKeepsOnboardingOpen() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo", "--onboarding-preview"]
        app.launch()
        defer { app.terminate() }
        app.buttons["Choose Claude Code"].click()
        app.buttons["Continue setup"].click()
        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 10))
        app.buttons["Continue"].click()
        XCTAssertTrue(app.buttons["Start chatting"].waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        let enabled = app.switches["Enable Claude Code"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 5))
        XCTAssertTrue(["1", "on"].contains(String(describing: enabled.value ?? "")))
        enabled.click()
        XCTAssertTrue(["0", "off"].contains(String(describing: enabled.value ?? "")))
        let settings = app.windows.containing(.switch, identifier: "Enable Claude Code").firstMatch
        settings.buttons[XCUIIdentifierCloseWindow].click()
        app.buttons["Start chatting"].click()
        XCTAssertTrue(app.staticTexts["Which agents do you use?"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["New Blast"].exists)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "disabled-agent-keeps-onboarding-open"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testRuntimeDetectionUpdatesWithoutLeavingTheScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo", "--onboarding-preview"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Choose OpenClaw"].waitForExistence(timeout: 5))
        app.buttons["Choose OpenClaw"].click()
        app.buttons["Continue setup"].click()
        XCTAssertTrue(app.staticTexts["Installed on this Mac"].waitForExistence(timeout: 5))
        app.buttons["Done with setup"].click()
        XCTAssertTrue(app.staticTexts["Which agents do you use?"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["New Blast"].exists)
    }

    @MainActor
    func testDeselectingAConnectedMessagesAgentRemovesItFromRecipients() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo", "--onboarding-preview"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Choose Fo"].waitForExistence(timeout: 5))
        app.buttons["Choose Fo"].click()
        app.buttons["Choose Szn"].click()
        app.buttons["Continue setup"].click()
        XCTAssertTrue(app.buttons["Connect selected"].waitForExistence(timeout: 5))
        app.buttons["Connect selected"].click()
        XCTAssertTrue(app.buttons["Start chatting"].waitForExistence(timeout: 5))
        app.buttons["Back"].click()
        app.buttons["Choose Fo"].click()
        app.buttons["Choose ChatGPT"].click()
        app.buttons["Continue setup"].click()
        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 10))
        app.buttons["Continue"].click()
        XCTAssertTrue(app.buttons["Start chatting"].waitForExistence(timeout: 5))
        app.buttons["Start chatting"].click()
        XCTAssertTrue(app.buttons["New Blast"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["Fo"].value as? String, "Not selected")
    }

    @MainActor
    func testMultipleAgentsConnectOrSkipBeforeTheWorkspaceOpens() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo", "--onboarding-preview"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Which agents do you use?"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Set up later"].exists)
        XCTAssertFalse(app.buttons["Not sure? Help me choose"].exists)
        XCTAssertTrue(app.buttons["Choose OpenClaw"].exists)
        XCTAssertTrue(app.buttons["Choose Hermes"].exists)
        let other = app.buttons["Choose I use another agent in Messages"]
        XCTAssertTrue(other.isHittable)
        XCTAssertEqual(other.frame.height, app.buttons["Choose ChatGPT"].frame.height, accuracy: 1)
        XCTAssertEqual(other.frame.width, app.buttons["Choose ChatGPT"].frame.width, accuracy: 1)
        XCTAssertEqual(app.descendants(matching: .scrollBar).count, 0)
        for name in ["ChatGPT", "Claude Code", "Fo", "Instinct", "Szn"] {
            app.buttons["Choose \(name)"].click()
        }
        app.buttons["Continue setup"].click()
        XCTAssertTrue(app.staticTexts["Let’s connect ChatGPT"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["New Blast"].exists)
        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 10))
        app.buttons["Continue"].click()
        XCTAssertTrue(app.staticTexts["Let’s connect Claude Code"].waitForExistence(timeout: 10))
        app.buttons["Skip for now"].click()
        XCTAssertTrue(app.staticTexts["Choose who to connect"].waitForExistence(timeout: 10))
        for name in ["Fo", "Instinct", "Szn"] {
            XCTAssertTrue(app.buttons["Select \(name)"].waitForExistence(timeout: 5))
            app.buttons["Select \(name)"].click()
        }
        XCTAssertFalse(app.buttons["New Blast"].exists)
        app.buttons["Continue"].click()
        XCTAssertTrue(app.buttons["Start chatting"].waitForExistence(timeout: 5))
        app.buttons["Start chatting"].click()
        XCTAssertTrue(app.buttons["New Blast"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Finish setup"].exists)
        XCTAssertFalse(app.staticTexts["Connect Contacts"].exists)
    }

    @MainActor
    func testGrokBotShowsTheExactPromptInsideOnboarding() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo", "--onboarding-preview"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Choose Grok Bot"].waitForExistence(timeout: 5))
        app.buttons["Choose Grok Bot"].click()
        app.buttons["Continue setup"].click()
        XCTAssertTrue(app.staticTexts["Let’s connect Grok Bot"].waitForExistence(timeout: 10))
        let prompt = app.staticTexts["Grok Bot setup prompt"]
        XCTAssertTrue(prompt.exists)
        let displayedPrompt = (prompt.value as? String) ?? prompt.label
        XCTAssertTrue(displayedPrompt.contains("Create an enabled webhook-triggered routine named “msgblast”"))
        XCTAssertTrue(displayedPrompt.contains("Never log callback credentials."))
        XCTAssertTrue(app.buttons["Copy prompt"].exists)
        XCTAssertFalse(app.buttons["New Blast"].exists)
        app.buttons["Skip for now"].click()
        XCTAssertTrue(app.staticTexts["Which agents do you use?"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["New Blast"].exists, "Skipping every agent must not unlock the workspace")
    }

    @MainActor
    func testSearchingForAContactOnlyUpdatesTheProposalUntilConfirmation() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo", "--onboarding-preview"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Choose Fo"].waitForExistence(timeout: 5))
        app.buttons["Choose Fo"].click()
        app.buttons["Choose Szn"].click()
        app.buttons["Continue setup"].click()
        XCTAssertTrue(app.staticTexts["Choose who to connect"].waitForExistence(timeout: 10))
        let contact = app.descendants(matching: .any).matching(identifier: "Contact for Fo").firstMatch
        XCTAssertTrue(contact.waitForExistence(timeout: 5))
        contact.click()
        app.menuItems["Search Contacts…"].click()
        XCTAssertTrue(app.buttons["Choose Fo contact"].waitForExistence(timeout: 10))
        app.buttons["Choose Fo contact"].click()
        XCTAssertFalse(app.buttons["Start chatting"].exists)
        XCTAssertTrue(app.buttons["Select Szn"].exists)
        XCTAssertFalse(app.buttons["New Blast"].exists)
        app.buttons["Select Szn"].click()
        app.buttons["Connect selected"].click()
        XCTAssertTrue(app.buttons["Start chatting"].waitForExistence(timeout: 5))
        app.buttons["Start chatting"].click()
        XCTAssertTrue(app.buttons["New Blast"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Fo"].exists)
        XCTAssertFalse(app.buttons["Send & compare"].exists, "An empty draft cannot be submitted")
    }

    @MainActor
    func testFeedbackTipAppearsBeforeFinishingAndTheMenuOpensFeedback() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo", "--onboarding-preview"]
        app.launch()
        defer { app.terminate() }
        app.buttons["Choose ChatGPT"].click()
        app.buttons["Continue setup"].click()
        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 10))
        app.buttons["Continue"].click()
        XCTAssertTrue(app.staticTexts["Share feedback anytime"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["Help menu with Share Feedback highlighted"].exists)
        XCTAssertFalse(app.buttons["New Blast"].exists)
        XCTAssertFalse(app.buttons["Skip for now"].exists)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "feedback-tip-before-workspace"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.menuBars.menuBarItems["Help"].click()
        app.menuBars.menuBarItems["Help"].menuItems["Share Feedback…"].click()
        let feedback = app.windows["Send Feedback"]
        XCTAssertTrue(feedback.waitForExistence(timeout: 5))
        feedback.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(app.staticTexts["Share feedback anytime"].exists)
        app.buttons["Start chatting"].click()
        XCTAssertTrue(app.buttons["New Blast"].waitForExistence(timeout: 5))
    }
}
