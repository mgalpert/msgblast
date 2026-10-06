import XCTest

final class WebServiceWorkflowTests: XCTestCase {
    @MainActor
    func testNativeChatGPTAndClaudeReopenTheSameComparisonWithoutWebViews() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        defer { app.terminate() }
        for name in ["Cedar", "Lumen", "Orbit", "Maple", "Echo", "Flint"] { app.buttons[name].click() }
        app.buttons["Muse"].click(); app.buttons["Grok"].click()
        let editor = app.textViews["Shared prompt"]
        editor.click(); editor.typeKey("a", modifierFlags: .command); editor.typeText("Native conversation fixture")
        app.buttons["Send & compare"].click()
        let reply = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "ChatGPT fixture reply: Native conversation fixture", "ChatGPT fixture reply: Native conversation fixture")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        XCTAssertEqual(app.webViews.count, 0)
        capture(app, name: "Native ChatGPT and Claude panes — simulated replies")
        app.buttons["New Blast"].click()
        let comparison = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Native conversation fixture", "Native conversation fixture")).firstMatch
        XCTAssertTrue(comparison.waitForExistence(timeout: 5))
        comparison.click()
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        editor.click(); editor.typeText("Continue the same conversation")
        app.buttons["Send & compare"].click()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "ChatGPT fixture reply: Continue the same conversation", "ChatGPT fixture reply: Continue the same conversation")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(reply.exists)
        XCTAssertEqual(app.webViews.count, 0)
    }

    @MainActor
    func testSignedOutAgentOpensSetupAndKeepsPromptUntilUserSubmitsAgain() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        defer { app.terminate() }
        for name in ["Cedar", "Lumen", "Orbit", "Maple", "Echo", "Flint", "ChatGPT", "Claude", "Grok"] { app.buttons[name].click() }
        app.buttons["Muse"].rightClick()
        app.menuItems["Open chat"].click()
        let signOut = app.buttons["Sign out of fixture"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 10))
        signOut.click()
        XCTAssertTrue(app.buttons["Sign in to fixture"].waitForExistence(timeout: 10))
        app.buttons["New Blast"].click()
        let editor = app.textViews["Shared prompt"]
        editor.click(); editor.typeKey("a", modifierFlags: .command); editor.typeText("Keep this comparison request")
        let send = app.buttons["Send & compare"]
        XCTAssertTrue(send.isEnabled, "A signed-out agent must lead to setup, not a disabled send button")
        send.click()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Connect your accounts")).firstMatch.waitForExistence(timeout: 10))
        app.buttons["Start signing in"].click()
        XCTAssertEqual(editor.value as? String, "Keep this comparison request")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "Fixture reply: Keep this comparison request")).firstMatch.exists)
        app.buttons["Sign in to fixture"].click()
        XCTAssertTrue(app.buttons["Sign out of fixture"].waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, "Keep this comparison request")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "Fixture reply: Keep this comparison request")).firstMatch.exists, "Signing in must not submit automatically")
        send.click()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "Fixture reply: Keep this comparison request")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Appeared in Muse"].exists)
    }

    @MainActor
    func testFailedMessagesRecipientCanRetryWithoutResendingToMuse() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        defer { app.terminate() }
        for name in ["Lumen", "Orbit", "Maple", "Echo", "Flint"] { app.buttons[name].click() }
        app.checkBoxes["Simulate one failure"].click()
        app.buttons["Muse"].click()
        XCTAssertTrue(app.buttons["Open Muse"].waitForExistence(timeout: 10))
        let editor = app.textViews["Shared prompt"]
        editor.click(); editor.typeKey("a", modifierFlags: .command); editor.typeText("Mixed failure fixture")
        app.buttons["Send & compare"].click()
        XCTAssertTrue(app.staticTexts["Appeared in Muse"].waitForExistence(timeout: 10))
        let retry = app.buttons["Retry only failed recipients"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        retry.click()
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value == %@", "Mixed failure fixture")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(retry.exists)
        let museReplies = app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "Fixture reply: Mixed failure fixture"))
        XCTAssertEqual(museReplies.count, 1)
    }

    @MainActor
    func testEmbeddedMuseAndMessagesReceiveOneSharedPrompt() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Muse"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["Muse"].value as? String, "Not selected")
        XCTAssertFalse(app.staticTexts["Web services"].exists)
        XCTAssertFalse(app.staticTexts["Grok Bot · unavailable"].exists)
        for name in ["Lumen", "Orbit", "Maple", "Echo", "Flint"] { app.buttons[name].click() }
        app.buttons["Muse"].click()
        XCTAssertEqual(app.buttons["Muse"].value as? String, "Selected")
        capture(app, name: "Muse selected beside Messages agents — local fixture")
        XCTAssertTrue(app.buttons["Open Muse"].waitForExistence(timeout: 10))
        app.buttons["Open Muse"].click()
        XCTAssertTrue(app.staticTexts["Chat ready"].waitForExistence(timeout: 10))
        capture(app, name: "Muse connected — local fixture")
        XCTAssertEqual(app.buttons["Recipient Cedar"].value as? String, "Selected")
        let editor = app.textViews["Shared prompt"]
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("Compare a morning walk with an afternoon walk.")
        capture(app, name: "Shared prompt ready — synthetic content")
        app.buttons["Send & compare"].click()
        XCTAssertTrue(app.staticTexts["Appeared in Muse"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "Fixture reply: Compare a morning walk")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Cedar (Demo)"].firstMatch.waitForExistence(timeout: 10))
        capture(app, name: "Embedded Muse and Messages replies — synthetic content")
        editor.click(); editor.typeText("Keep this shared draft")
        app.buttons["New Blast"].click()
        XCTAssertEqual(app.buttons["Muse"].value as? String, "Selected")
        XCTAssertEqual(app.buttons["Cedar"].value as? String, "Selected")
        XCTAssertEqual(app.textViews["Shared prompt"].value as? String, "Keep this shared draft")
        app.buttons["Open Muse"].click()
        XCTAssertTrue(app.staticTexts["Appeared in Muse"].exists)
        XCTAssertFalse(app.buttons["Connect Muse"].exists)
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
