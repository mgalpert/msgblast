import XCTest

final class WebServiceWorkflowTests: XCTestCase {
    @MainActor
    func testSevenChatsResizeWindowAndRemainReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        app.activate()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Maple"].waitForExistence(timeout: 5))
        for name in ["Maple", "Echo", "Flint"] { app.buttons[name].click() }
        app.buttons["Send & compare"].click()
        XCTAssertTrue(app.staticTexts["Chats (7)"].waitForExistence(timeout: 15))
        let wideWidth = app.windows.firstMatch.frame.width
        for name in ["Muse", "ChatGPT", "Claude", "Grok", "Cedar", "Lumen", "Orbit"] {
            let tab = app.buttons["Show \(name) chat"]
            XCTAssertTrue(tab.exists)
            tab.click()
        }
        for name in ["Muse", "ChatGPT", "Claude", "Grok"] { app.buttons["Recipient \(name)"].click() }
        XCTAssertTrue(app.staticTexts["Chats (3)"].waitForExistence(timeout: 5))
        let narrowed = NSPredicate { _, _ in app.windows.firstMatch.frame.width <= min(wideWidth, 1500) }
        expectation(for: narrowed, evaluatedWith: app.windows.firstMatch)
        waitForExpectations(timeout: 5)
        for name in ["Muse", "ChatGPT", "Claude", "Grok"] { app.buttons["Recipient \(name)"].click() }
        XCTAssertTrue(app.staticTexts["Chats (7)"].waitForExistence(timeout: 5))
        let expanded = NSPredicate { _, _ in app.windows.firstMatch.frame.width >= wideWidth - 1 }
        expectation(for: expanded, evaluatedWith: app.windows.firstMatch)
        waitForExpectations(timeout: 5)
        capture(app, name: "Seven reachable chats — isolated fixture")
    }

    @MainActor
    func testAddAgentToExistingBlastInjectsSharedHistoryOnly() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        defer { app.terminate() }
        let excluded = ["Cedar", "Lumen", "Orbit", "Maple", "Echo", "Flint", "Claude", "Grok"]
        for name in excluded {
            let button = app.buttons[name]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            if button.value as? String == "Selected" { button.click() }
        }
        // Confirm setup after launch tasks settle before exercising recipient joins.
        for name in excluded {
            let button = app.buttons[name]
            if button.value as? String == "Selected" { button.click() }
            XCTAssertEqual(button.value as? String, "Not selected")
        }
        let editor = app.textViews["Shared prompt"]
        func broadcast(_ text: String) {
            editor.click()
            editor.typeKey("a", modifierFlags: .command)
            editor.typeText(text)
            XCTAssertTrue(app.buttons["Send & compare"].isEnabled)
            app.buttons["Send & compare"].click()
            let reply = app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "Fixture reply: " + text)).firstMatch
            XCTAssertTrue(reply.waitForExistence(timeout: 15))
        }
        broadcast("Original joining fixture ask")
        broadcast("Shared joining fixture follow-up")
        app.buttons["Recipient ChatGPT"].click()
        broadcast("Private joining fixture detail")
        capture(app, name: "Before adding Grok — isolated simulated chats")
        app.buttons["Recipient Grok"].click()
        let context = app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@ AND value CONTAINS %@", "Original ask:", "Follow-up 1:")).firstMatch
        XCTAssertTrue(context.waitForExistence(timeout: 15))
        XCTAssertTrue((context.value as? String ?? context.label).contains("Shared joining fixture follow-up"))
        XCTAssertFalse((context.value as? String ?? context.label).contains("Private joining fixture detail"))
        XCTAssertEqual(app.buttons["Recipient Grok"].value as? String, "Selected")
        capture(app, name: "Grok joined existing blast with shared context — isolated simulated chats")
        app.buttons["Recipient Cedar"].click()
        let cedar = app.buttons["Recipient Cedar"]
        let deadline = Date().addingTimeInterval(15)
        while cedar.value as? String != "Selected", Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertEqual(cedar.value as? String, "Selected")
        XCTAssertTrue(app.staticTexts["Shared joining fixture follow-up"].waitForExistence(timeout: 15))
        capture(app, name: "Messages agent joined existing blast — isolated simulated chats")
    }

    @MainActor
    func testFreshPrivateCLIConversationSharesOnlyExplicitBroadcastsWhenAgentsJoin() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Muse"].waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        for (index, name) in ["Codex CLI", "Claude Code"].enumerated() {
            XCTAssertTrue(settings.staticTexts["Enable \(name)"].waitForExistence(timeout: 5))
            // macOS exposes these two switch controls without the adjacent label.
            let toggle = settings.switches.element(boundBy: index)
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            toggle.click()
            if String(describing: toggle.value ?? "") == "0" { toggle.click() }
            XCTAssertEqual(String(describing: toggle.value ?? ""), "1")
        }
        settings.buttons[XCUIIdentifierCloseWindow].click()
        let excluded = ["Cedar", "Lumen", "Orbit", "Maple", "Echo", "Flint", "Muse", "ChatGPT", "Claude", "Grok", "Claude Code"]
        for _ in 0..<2 {
            for name in excluded where app.buttons[name].value as? String == "Selected" { app.buttons[name].click() }
        }
        for name in excluded { XCTAssertEqual(app.buttons[name].value as? String, "Not selected") }
        app.buttons["Codex CLI"].rightClick()
        app.menuItems["Open chat"].click()
        let direct = app.textViews["Message Codex CLI"]
        XCTAssertTrue(direct.waitForExistence(timeout: 10))
        func sendDirect(_ text: String) {
            direct.click(); direct.typeText(text)
            XCTAssertEqual(direct.value as? String, text)
            direct.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(reply(app, containing: "Codex CLI fixture reply: " + text).waitForExistence(timeout: 15))
        }
        sendDirect("Original CLI privacy ask")
        sendDirect("Private CLI detail")
        let shared = app.textViews["Shared prompt"]
        shared.click(); shared.typeKey("a", modifierFlags: .command); shared.typeText("Shared CLI follow-up")
        app.buttons["Send & compare"].click()
        XCTAssertTrue(reply(app, containing: "Codex CLI fixture reply: Shared CLI follow-up").waitForExistence(timeout: 15))
        capture(app, name: "Private sole CLI conversation before joins — isolated fixture")
        shared.click(); shared.typeText("Retained unsent shared draft")
        for name in ["Grok", "Claude Code", "Cedar"] {
            app.buttons["Recipient \(name)"].click()
            let deadline = Date().addingTimeInterval(15)
            while !app.buttons["Send & compare"].isEnabled, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
            XCTAssertEqual(app.buttons["Recipient \(name)"].value as? String, "Selected")
        }
        XCTAssertTrue(reply(app, containing: "Claude Code fixture reply: You are joining an existing conversation").waitForExistence(timeout: 15))
        let contexts = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@ AND value CONTAINS %@", "Original ask:", "Shared CLI follow-up"))
        XCTAssertTrue(contexts.firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@ AND value CONTAINS %@", "Original ask:", "Private CLI detail")).count, 0)
        XCTAssertEqual(app.textViews.matching(NSPredicate(format: "value == %@", "Private CLI detail")).count, 0)
        XCTAssertEqual(shared.value as? String, "Retained unsent shared draft")
        capture(app, name: "Web CLI and Messages joins exclude private CLI detail — isolated fixture")
    }

    @MainActor
    func testWebDefaultsAndOptionalCLIConversationsStaySeparate() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        defer { app.terminate() }
        for name in ["Muse", "ChatGPT", "Claude", "Grok"] {
            XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 5))
            XCTAssertEqual(app.buttons[name].value as? String, "Selected")
        }
        XCTAssertTrue(app.buttons["Codex CLI"].exists)
        XCTAssertEqual(app.buttons["Codex CLI"].value as? String, "Set up")
        XCTAssertFalse(app.buttons["Claude Code"].exists)
        XCTAssertFalse(app.staticTexts["Your local accounts (simulated)"].exists)
        capture(app, name: "Featured grid with optional CLI setup — isolated fixture")
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        for name in ["Codex CLI", "Claude Code"] {
            let toggle = settings.switches["Enable \(name)"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            XCTAssertEqual(toggle.value as? String, "0")
            toggle.click()
        }
        capture(app, name: "Optional CLI toggles in Settings — simulated accounts")
        settings.buttons[XCUIIdentifierCloseWindow].click()
        for name in ["Cedar", "Lumen", "Orbit", "Maple", "Echo", "Flint", "Muse", "Grok"] { app.buttons[name].click() }
        XCTAssertEqual(app.buttons["Codex CLI"].value as? String, "Selected")
        XCTAssertEqual(app.buttons["Claude Code"].value as? String, "Selected")
        let editor = app.textViews["Shared prompt"]
        editor.click(); editor.typeKey("a", modifierFlags: .command); editor.typeText("Web and CLI comparison fixture")
        app.buttons["Send & compare"].click()
        for name in ["ChatGPT", "Claude", "Codex CLI", "Claude Code"] {
            XCTAssertTrue(reply(app, containing: "\(name) fixture reply: Web and CLI comparison fixture").waitForExistence(timeout: 15))
        }
        XCTAssertEqual(app.webViews.count, 2, "Website chats coexist with two separate native CLI panes")
        XCTAssertFalse(app.buttons["Switch account"].exists)
        capture(app, name: "Website and CLI replies in the same blast — synthetic replies")
        app.buttons["New Blast"].click()
        let comparison = app.outlines.cells.containing(NSPredicate(format: "label CONTAINS %@", "Web and CLI comparison fixture")).firstMatch
        XCTAssertTrue(comparison.waitForExistence(timeout: 5))
        comparison.click()
        XCTAssertTrue(reply(app, containing: "Codex CLI fixture reply: Web and CLI comparison fixture").waitForExistence(timeout: 10))
        editor.click(); editor.typeText("Continue each saved conversation")
        app.buttons["Send & compare"].click()
        for name in ["ChatGPT", "Claude", "Codex CLI", "Claude Code"] {
            XCTAssertTrue(reply(app, containing: "\(name) fixture reply: Continue each saved conversation").waitForExistence(timeout: 15))
        }
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.switches["Enable Codex CLI"].click()
        settings.buttons[XCUIIdentifierCloseWindow].click()
        app.buttons["New Blast"].click()
        XCTAssertTrue(app.buttons["Codex CLI"].exists)
        XCTAssertEqual(app.buttons["Codex CLI"].value as? String, "Set up")
        comparison.click()
        XCTAssertTrue(reply(app, containing: "Codex CLI fixture reply: Web and CLI comparison fixture").waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Recipient Codex CLI"].isEnabled)
    }

    @MainActor
    private func reply(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
    }

    @MainActor
    func testSignedInWebsitesSkipConnectionIntro() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        app.activate()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Cedar"].waitForExistence(timeout: 5))
        for name in ["Cedar", "Lumen", "Orbit", "Maple", "Echo", "Flint"] { app.buttons[name].click() }
        let editor = app.textViews["Shared prompt"]
        editor.click(); editor.typeKey("a", modifierFlags: .command); editor.typeText("Already signed in fixture")
        app.buttons["Send & compare"].click()
        for name in ["ChatGPT", "Claude", "Grok"] {
            XCTAssertTrue(reply(app, containing: "\(name) fixture reply: Already signed in fixture").waitForExistence(timeout: 15))
        }
        XCTAssertTrue(reply(app, containing: "Fixture reply: Already signed in fixture").exists)
        XCTAssertFalse(app.staticTexts["Connect your accounts"].exists)
        capture(app, name: "Signed-in websites submit without a login reminder — isolated fixture")
    }

    @MainActor
    func testSignedOutAgentOpensSetupAndKeepsPromptUntilUserSubmitsAgain() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        app.activate()
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
        XCTAssertTrue(app.staticTexts["Website sign-in status"].waitForExistence(timeout: 5))
        app.activate(); send.click()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Connect your accounts", "Connect your accounts")).firstMatch.waitForExistence(timeout: 10))
        capture(app, name: "Only signed-out Muse requires login; prompt preserved — isolated fixture")
        app.activate(); app.buttons["Start signing in"].click()
        XCTAssertEqual(editor.value as? String, "Keep this comparison request")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Fixture reply: Keep this comparison request", "Fixture reply: Keep this comparison request")).firstMatch.exists)
        app.activate(); app.buttons["Sign in to fixture"].click()
        XCTAssertTrue(app.buttons["Sign out of fixture"].waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, "Keep this comparison request")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Fixture reply: Keep this comparison request", "Fixture reply: Keep this comparison request")).firstMatch.exists, "Signing in must not submit automatically")
        app.activate(); send.click()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Fixture reply: Keep this comparison request", "Fixture reply: Keep this comparison request")).firstMatch.waitForExistence(timeout: 10))
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
        for name in ["ChatGPT", "Claude", "Grok"] { app.buttons[name].click() }
        let editor = app.textViews["Shared prompt"]
        editor.click(); editor.typeKey("a", modifierFlags: .command); editor.typeText("Mixed failure fixture")
        app.buttons["Send & compare"].click()
        XCTAssertTrue(reply(app, containing: "Fixture reply:").waitForExistence(timeout: 10))
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
        XCTAssertEqual(app.buttons["Muse"].value as? String, "Selected")
        XCTAssertFalse(app.staticTexts["Web services"].exists)
        XCTAssertFalse(app.staticTexts["Grok Bot · unavailable"].exists)
        for name in ["Lumen", "Orbit", "Maple", "Echo", "Flint"] { app.buttons[name].click() }
        for name in ["ChatGPT", "Claude", "Grok"] { app.buttons[name].click() }
        XCTAssertEqual(app.buttons["Muse"].value as? String, "Selected")
        capture(app, name: "Muse selected beside Messages agents — local fixture")
        app.buttons["Muse"].rightClick()
        app.menuItems["Open chat"].click()
        XCTAssertTrue(app.buttons["Sign out of fixture"].waitForExistence(timeout: 10))
        capture(app, name: "Muse connected — local fixture")
        XCTAssertEqual(app.buttons["Recipient Cedar"].value as? String, "Selected")
        let editor = app.textViews["Shared prompt"]
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("Compare a morning walk with an afternoon walk.")
        capture(app, name: "Shared prompt ready — synthetic content")
        app.buttons["Send & compare"].click()
        XCTAssertTrue(reply(app, containing: "Fixture reply:").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "Fixture reply: Compare a morning walk")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Cedar (Demo)"].firstMatch.waitForExistence(timeout: 10))
        capture(app, name: "Embedded Muse and Messages replies — synthetic content")
        editor.click(); editor.typeText("Keep this shared draft")
        let privateReply = app.textViews["Private reply to Cedar"]
        XCTAssertTrue(privateReply.exists)
        privateReply.click(); privateReply.typeText("Cedar direct reply from its pane")
        privateReply.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value == %@", "Cedar direct reply from its pane")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(privateReply.value as? String, "")
        XCTAssertEqual(editor.value as? String, "Keep this shared draft")
        XCTAssertFalse(reply(app, containing: "Fixture reply: Cedar direct reply from its pane").exists, "Private Messages replies must not be sent to Muse")
        capture(app, name: "Direct Messages pane reply — simulated Messages, shared draft retained")
        app.buttons["New Blast"].click()
        XCTAssertEqual(app.buttons["Muse"].value as? String, "Selected")
        XCTAssertEqual(app.buttons["Cedar"].value as? String, "Selected")
        XCTAssertEqual(app.textViews["Shared prompt"].value as? String, "Keep this shared draft")
        app.buttons["Muse"].rightClick()
        app.menuItems["Open chat"].click()
        XCTAssertFalse(app.staticTexts["Appeared in Muse"].exists)
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
