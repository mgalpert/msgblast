import XCTest

final class AgentGridWorkflowTests: XCTestCase {
    @MainActor
    func testDotsSetupUsesOneConnectActionForInstallationAndReadiness() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        app.activate()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Edit agents"].waitForExistence(timeout: 10))
        app.buttons["Edit agents"].click()
        let search = app.textFields["Search available agents"]
        app.scrollViews["Agent grid scroll area"].scroll(byDeltaX: 0, deltaY: -1000)
        search.click(); search.typeText("Dots")
        XCTAssertTrue(app.buttons["Add Dots"].waitForExistence(timeout: 5))
        app.buttons["Add Dots"].click()
        XCTAssertTrue(app.buttons["Done setting up Dots"].waitForExistence(timeout: 5))
        let enable = app.switches["Enable Dots"]
        if String(describing: enable.value ?? "") != "1" { enable.click() }
        let connect = app.buttons["Connect Dots"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Check connection"].exists)
        XCTAssertFalse(app.buttons["Check installation"].exists)
        connect.click()
        XCTAssertTrue(app.staticTexts["Ready for your first prompt"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Check installation"].exists)
        capture(app, name: "Dots single Connect action — simulated installation and readiness")
        app.buttons["Done setting up Dots"].click()
        app.buttons["Done editing agents"].click()
        XCTAssertTrue(app.staticTexts["No comparisons"].exists, "Connecting must not send a message")
    }

    @MainActor
    func testEditGridHidesAddsReordersAndKeepsDraft() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        app.activate()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Edit agents"].waitForExistence(timeout: 10))
        let editor = app.textViews["Shared prompt"]
        editor.click(); editor.typeKey("a", modifierFlags: .command)
        editor.typeText("Keep this draft while I organize agents")
        app.buttons["Edit agents"].click()
        XCTAssertTrue(app.staticTexts["Your agents"].waitForExistence(timeout: 5))
        app.buttons["Hide Muse"].click()
        XCTAssertFalse(app.buttons["Hide Muse"].exists)
        let search = app.textFields["Search available agents"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        app.scrollViews["Agent grid scroll area"].scroll(byDeltaX: 0, deltaY: -1000)
        search.click(); search.typeText("Grok Bot")
        XCTAssertTrue(app.buttons["Add Grok Bot"].waitForExistence(timeout: 5))
        capture(app, name: "More agents with per-avatar plus — isolated fixture")
        app.buttons["Add Grok Bot"].click()
        XCTAssertTrue(app.buttons["Done setting up Grok Bot"].waitForExistence(timeout: 5))
        capture(app, name: "New Grok Bot opens onboarding overlay — isolated fixture")
        app.buttons["Done setting up Grok Bot"].click()
        XCTAssertTrue(app.buttons["Hide Grok Bot"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Add Grok Bot"].exists)
        let added = app.descendants(matching: .any).matching(identifier: "Agent Grok Bot").firstMatch
        XCTAssertTrue(added.isHittable, "The added first tile must be visible above the input field")
        XCTAssertLessThan(added.frame.maxY, editor.frame.minY)
        let first = app.descendants(matching: .any).matching(identifier: "Agent ChatGPT").firstMatch
        let second = app.descendants(matching: .any).matching(identifier: "Agent Claude").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch
        let origin = window.coordinate(withNormalizedOffset: .zero)
        let source = origin.withOffset(CGVector(dx: first.frame.midX - window.frame.minX, dy: first.frame.midY - window.frame.minY))
        let destination = origin.withOffset(CGVector(dx: second.frame.midX - window.frame.minX, dy: second.frame.midY - window.frame.minY))
        source.press(forDuration: 0.1, thenDragTo: destination, withVelocity: .slow, thenHoldForDuration: 0.1)
        let moved = NSPredicate { _, _ in
            let lhs = app.descendants(matching: .any).matching(identifier: "Agent Claude").firstMatch.frame
            let rhs = app.descendants(matching: .any).matching(identifier: "Agent ChatGPT").firstMatch.frame
            return lhs.minY < rhs.minY - 5 || (abs(lhs.minY - rhs.minY) < 5 && lhs.minX < rhs.minX)
        }
        expectation(for: moved, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        capture(app, name: "Personalized reordered grid — isolated fixture")
        app.buttons["Done editing agents"].click()
        XCTAssertTrue(app.buttons["Grok Bot"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Muse"].exists)
        XCTAssertEqual(app.textViews["Shared prompt"].value as? String, "Keep this draft while I organize agents")
        XCTAssertNotEqual(app.buttons["Grok Bot"].value as? String, "Selected", "Adding a tile must not select a send recipient")
        app.buttons["Edit agents"].click()
        app.scrollViews["Agent grid scroll area"].scroll(byDeltaX: 0, deltaY: -1000)
        search.click(); search.typeText("Muse")
        XCTAssertTrue(app.buttons["Add Muse"].waitForExistence(timeout: 5))
        app.buttons["Add Muse"].click()
        app.buttons["Done editing agents"].click()
        XCTAssertEqual(app.buttons["Muse"].value as? String, "Not selected", "A hidden agent must stay deselected when restored")
    }

    @MainActor
    func testLocalAgentsAreAvailableWithoutEnablingAccounts() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        app.activate()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Edit agents"].waitForExistence(timeout: 10))
        app.buttons["Edit agents"].click()
        let search = app.textFields["Search available agents"]
        for name in ["Claude Code", "OpenClaw", "Hermes"] {
            app.scrollViews["Agent grid scroll area"].scroll(byDeltaX: 0, deltaY: -1000)
            search.click(); search.typeKey("a", modifierFlags: .command); search.typeText(name)
            XCTAssertTrue(app.buttons["Add \(name)"].waitForExistence(timeout: 5))
            app.buttons["Add \(name)"].click()
            XCTAssertTrue(app.buttons["Done setting up \(name)"].waitForExistence(timeout: 5))
            app.buttons["Done setting up \(name)"].click()
            XCTAssertTrue(app.buttons["Hide \(name)"].waitForExistence(timeout: 5))
        }
        app.buttons["Done editing agents"].click()
        XCTAssertEqual(app.buttons["Claude Code"].value as? String, "Set up")
        XCTAssertEqual(app.buttons["OpenClaw"].value as? String, "Local setup")
        XCTAssertEqual(app.buttons["Hermes"].value as? String, "Local setup")
        capture(app, name: "Local agent tiles reuse setup capabilities — isolated fixture")
    }

    @MainActor
    func testDuplicateWebAgentCreatesIndependentRecipientAndCanBeRenamed() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch(); app.activate()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["ChatGPT"].waitForExistence(timeout: 10))
        app.buttons["ChatGPT"].rightClick()
        XCTAssertTrue(app.menuItems["Duplicate agent…"].waitForExistence(timeout: 5))
        app.menuItems["Duplicate agent…"].click()
        let name = app.textFields["Agent name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click(); name.typeKey("a", modifierFlags: .command); name.typeText("ChatGPT deep")
        XCTAssertTrue(app.checkBoxes["Use another account"].exists)
        capture(app, name: "Duplicate agent with shared sign-in — isolated fixture")
        app.buttons["Save agent"].click()
        XCTAssertTrue(app.buttons["ChatGPT deep"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["ChatGPT deep"].value as? String, "Not selected")
        app.buttons["ChatGPT deep"].click()
        XCTAssertEqual(app.buttons["ChatGPT deep"].value as? String, "Selected")
        app.buttons["ChatGPT deep"].rightClick()
        app.menuItems["Rename…"].click()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click(); name.typeKey("a", modifierFlags: .command); name.typeText("ChatGPT research")
        app.buttons["Save agent"].click()
        XCTAssertTrue(app.buttons["ChatGPT research"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["ChatGPT"].exists)
        XCTAssertFalse(app.buttons["ChatGPT deep"].exists)
        capture(app, name: "Two independently selectable ChatGPT agents — isolated fixture")
    }

    @MainActor
    func testMessagesAccessOffHidesContactsAndUsesPermissionToggle() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo", "--permission-guide-preview"]
        app.launch()
        defer { app.terminate() }
        let access = app.switches["enable-messages-history-permission"]
        XCTAssertTrue(access.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Open Settings"].exists)
        XCTAssertFalse(app.buttons["Cedar"].exists, "Saved Messages contacts stay hidden until history is available")
        XCTAssertTrue(app.buttons["Add ChatGPT"].exists, "Native apps remain available while Messages access is off")
        capture(app, name: "Messages access toggle with unavailable contacts hidden — isolated fixture")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let evidence = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        evidence.name = name
        evidence.lifetime = .keepAlways
        add(evidence)
    }
}
