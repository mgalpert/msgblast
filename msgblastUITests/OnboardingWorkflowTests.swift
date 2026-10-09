import XCTest

final class OnboardingWorkflowTests: XCTestCase {
    @MainActor
    func testExactMessagesContactsAreSuggestedWithoutOpeningSearch() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo", "--onboarding-preview"]
        app.launch()
        defer { app.terminate() }
        for name in ["Fo", "Instinct", "Szn"] { app.buttons["Choose \(name)"].click() }
        app.buttons["Continue setup"].click()
        for name in ["Fo", "Instinct", "Szn"] {
            XCTAssertTrue(app.buttons["Use suggested \(name) contact"].waitForExistence(timeout: 5))
        }
        XCTAssertFalse(app.textFields["Find onboarding contact"].exists)
        XCTAssertFalse(app.buttons["New Blast"].exists)
        app.buttons["Use suggested Fo contact"].click()
        XCTAssertTrue(app.staticTexts["Fo connected"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Use suggested Instinct contact"].exists)
        XCTAssertTrue(app.buttons["Use suggested Szn contact"].exists)
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
        app.buttons["Choose contact for Fo"].click()
        XCTAssertTrue(app.buttons["Use Fo"].waitForExistence(timeout: 5))
        app.buttons["Use Fo"].click()
        XCTAssertTrue(app.staticTexts["Fo connected"].waitForExistence(timeout: 5))
        app.buttons["Back"].click()
        app.buttons["Choose Fo"].click()
        app.buttons["Choose ChatGPT"].click()
        app.buttons["Continue setup"].click()
        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 10))
        app.buttons["Continue"].click()
        app.buttons["Skip Szn"].click()
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
        XCTAssertTrue(app.staticTexts["Connect your Messages agents"].waitForExistence(timeout: 10))
        for name in ["Fo", "Instinct", "Szn"] {
            XCTAssertTrue(app.buttons["Choose contact for \(name)"].exists)
        }
        XCTAssertFalse(app.buttons["New Blast"].exists)
        app.buttons["Skip for now"].click()
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
    func testSelectingAContactCompletesOnlyThatMessagesAgent() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo", "--onboarding-preview"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Choose Fo"].waitForExistence(timeout: 5))
        app.buttons["Choose Fo"].click()
        app.buttons["Choose Szn"].click()
        app.buttons["Continue setup"].click()
        XCTAssertTrue(app.staticTexts["Connect your Messages agents"].waitForExistence(timeout: 10))
        app.buttons["Choose contact for Fo"].click()
        XCTAssertTrue(app.buttons["Use Fo"].waitForExistence(timeout: 10))
        app.buttons["Use Fo"].click()
        XCTAssertTrue(app.staticTexts["Fo connected"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Choose contact for Szn"].exists)
        XCTAssertFalse(app.buttons["New Blast"].exists)
        app.buttons["Skip Szn"].click()
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
