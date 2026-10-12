import XCTest

final class WebServiceWorkflowTests: XCTestCase {
    @MainActor
    private func switchIsOn(_ toggle: XCUIElement, file: StaticString = #filePath, line: UInt = #line) -> Bool? {
        let raw = toggle.value
        if let number = raw as? NSNumber, [0.0, 1.0].contains(number.doubleValue) { return number.boolValue }
        if let text = raw as? String, text == "0" || text == "1" { return text == "1" }
        XCTFail("Expected a Boolean switch value, got \(String(describing: raw))", file: file, line: line)
        return nil
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in scroll: XCUIElement, window: XCUIElement, horizontal: Bool = false) -> Bool {
        guard scroll.waitForExistence(timeout: 5), element.waitForExistence(timeout: 5) else {
            XCTFail("The intended control and its scrolling container must exist")
            return false
        }
        for step in 0...12 {
            let frame = element.frame
            let viewport = scroll.frame
            if frame.width > 0, frame.height > 0, viewport.contains(frame), element.isHittable { return true }
            guard step < 12 else { break }
            if horizontal {
                // A wheel event over the container can land inside a WKWebView.
                // Move the real outer scrollbar instead of an embedded scroller.
                let bars = scroll.children(matching: .scrollBar)
                guard bars.count == 1 else { XCTFail("Expected the outer horizontal scrollbar"); return false }
                let bar = bars.element
                let barFrame = bar.frame
                let windowFrame = window.frame
                let toRight = frame.midX > viewport.midX
                let sourcePoint = CGPoint(x: barFrame.minX + barFrame.width * (toRight ? 0.25 : 0.75), y: barFrame.midY)
                let destinationPoint = CGPoint(x: barFrame.minX + barFrame.width * (toRight ? 0.95 : 0.05), y: barFrame.midY)
                guard barFrame.width.isFinite, barFrame.height.isFinite, barFrame.width > 0, barFrame.height > 0,
                      viewport.contains(sourcePoint), viewport.contains(destinationPoint),
                      windowFrame.contains(sourcePoint), windowFrame.contains(destinationPoint) else {
                    XCTFail("The outer scrollbar drag must stay inside the visible viewport and window")
                    return false
                }
                let origin = window.coordinate(withNormalizedOffset: .zero)
                let source = origin.withOffset(CGVector(dx: sourcePoint.x - windowFrame.minX, dy: sourcePoint.y - windowFrame.minY))
                let destination = origin.withOffset(CGVector(dx: destinationPoint.x - windowFrame.minX, dy: destinationPoint.y - windowFrame.minY))
                // Element hover tries AX autoscrolling for this scrollbar.
                // Target its visible thumb by bounded mouse coordinate instead.
                source.hover()
                source.click(forDuration: 0.1, thenDragTo: destination, withVelocity: .slow, thenHoldForDuration: 0.1)
                let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in abs(element.frame.minX - frame.minX) > 1 }, object: element)
                guard XCTWaiter.wait(for: [moved], timeout: 5) == .completed else { XCTFail("The outer scrollbar must move the chat column"); return false }
            } else {
                scroll.scroll(byDeltaX: 0, deltaY: frame.midY < viewport.midY ? 500 : -500)
            }
        }
        XCTFail("The control must be reachable inside its scrolling container: \(element)")
        return false
    }

    @MainActor
    private func setGridRecipient(_ name: String, selected: Bool, in app: XCUIApplication) -> Bool {
        let button = app.buttons[name]
        guard button.waitForExistence(timeout: 5) else { XCTFail("Missing fixture recipient \(name)"); return false }
        let expected = selected ? "Selected" : "Not selected"
        if button.value as? String == expected { return true }
        guard reveal(button, in: app.scrollViews["Agent grid scroll area"], window: app.windows.firstMatch) else { return false }
        button.click()
        let reached = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: button)
        guard XCTWaiter.wait(for: [reached], timeout: 5) == .completed else {
            XCTFail("\(name) must become \(expected), got \(String(describing: button.value))")
            return false
        }
        return true
    }

    @MainActor
    private func selectWebFixtureRecipients(_ app: XCUIApplication) -> Bool {
        for name in ["Muse", "ChatGPT", "Claude", "Grok"] {
            guard setGridRecipient(name, selected: true, in: app) else { return false }
        }
        return true
    }
    @MainActor
    func testSevenChatsResizeWindowAndRemainReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        guard selectWebFixtureRecipients(app) else { app.terminate(); return }
        app.activate()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Maple"].waitForExistence(timeout: 5))
        for name in ["Maple", "Echo", "Flint"] {
            guard setGridRecipient(name, selected: false, in: app) else { return }
        }
        app.buttons["Send & compare"].click()
        let cedar = app.textViews["Private reply to Cedar"]
        XCTAssertTrue(cedar.waitForExistence(timeout: 15))
        XCTAssertEqual(app.webViews.count, 4)
        let wideWidth = app.windows.firstMatch.frame.width
        let columns = app.scrollViews["Comparison chat columns"]
        for name in ["Muse", "ChatGPT", "Claude", "Grok"] {
            let reload = app.buttons["Reload \(name)"]
            XCTAssertTrue(reload.waitForExistence(timeout: 5))
            guard reveal(reload, in: columns, window: app.windows.firstMatch, horizontal: true) else { return }
            reload.click()
            XCTAssertTrue(reload.isHittable, "The \(name) column must remain reachable")
        }
        for name in ["Cedar", "Lumen", "Orbit"] {
            let editor = app.textViews["Private reply to \(name)"]
            XCTAssertTrue(editor.exists)
            guard reveal(editor, in: columns, window: app.windows.firstMatch, horizontal: true) else { return }
            editor.click()
            XCTAssertTrue(editor.isHittable, "The \(name) column must remain reachable")
            editor.typeText("Reachable \(name) fixture draft")
            XCTAssertEqual(editor.value as? String, "Reachable \(name) fixture draft")
        }
        for name in ["Muse", "ChatGPT", "Claude", "Grok"] { app.buttons["Recipient \(name)"].click() }
        let threeChats = NSPredicate { _, _ in app.webViews.count == 0 }
        expectation(for: threeChats, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        let narrowed = NSPredicate { _, _ in app.windows.firstMatch.frame.width <= min(wideWidth, 1500) }
        expectation(for: narrowed, evaluatedWith: app.windows.firstMatch)
        waitForExpectations(timeout: 5)
        for name in ["Muse", "ChatGPT", "Claude", "Grok"] { app.buttons["Recipient \(name)"].click() }
        let sevenChats = NSPredicate { _, _ in app.webViews.count == 4 }
        expectation(for: sevenChats, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        let expanded = NSPredicate { _, _ in app.windows.firstMatch.frame.width >= wideWidth - 1 }
        expectation(for: expanded, evaluatedWith: app.windows.firstMatch)
        waitForExpectations(timeout: 5)
        for name in ["Cedar", "Lumen", "Orbit"] {
            XCTAssertEqual(app.textViews["Private reply to \(name)"].value as? String, "Reachable \(name) fixture draft")
        }
        capture(app, name: "Seven reachable chats — isolated fixture")
    }

    @MainActor
    func testAddAgentToExistingBlastInjectsSharedHistoryOnly() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        guard selectWebFixtureRecipients(app) else { app.terminate(); return }
        defer { app.terminate() }
        let excluded = ["Cedar", "Lumen", "Orbit", "Maple", "Echo", "Flint", "Claude", "Grok"]
        for name in excluded {
            guard setGridRecipient(name, selected: false, in: app) else { return }
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
        let context = reply(app, containing: "Grok fixture reply: Original joining fixture ask")
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
        guard selectWebFixtureRecipients(app) else { app.terminate(); return }
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
            if switchIsOn(toggle) == false { toggle.click() }
            XCTAssertEqual(switchIsOn(toggle), true)
        }
        settings.buttons[XCUIIdentifierCloseWindow].click()
        let excluded = ["Cedar", "Lumen", "Orbit", "Maple", "Echo", "Flint", "Muse", "ChatGPT", "Claude", "Grok", "Claude Code"]
        for name in excluded {
            guard setGridRecipient(name, selected: false, in: app) else { return }
        }
        let codex = app.buttons["Codex CLI"]
        XCTAssertEqual(codex.value as? String, "Not selected", "Enabling a CLI must not select a recipient")
        guard setGridRecipient("Codex CLI", selected: true, in: app) else { return }
        codex.rightClick()
        let openChat = app.menuItems["Open chat"]
        XCTAssertTrue(openChat.isEnabled, "The sole selected CLI must be available for a private chat")
        openChat.click()
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
        let contexts = app.staticTexts.matching(NSPredicate(format: "(label CONTAINS %@ AND label CONTAINS %@) OR (value CONTAINS %@ AND value CONTAINS %@)", "Claude Code fixture reply: Original CLI privacy ask", "Shared CLI follow-up", "Claude Code fixture reply: Original CLI privacy ask", "Shared CLI follow-up"))
        XCTAssertTrue(contexts.firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "(label CONTAINS %@ AND label CONTAINS %@) OR (value CONTAINS %@ AND value CONTAINS %@)", "Original CLI privacy ask", "Private CLI detail", "Original CLI privacy ask", "Private CLI detail")).count, 0)
        XCTAssertEqual(app.textViews.matching(NSPredicate(format: "value == %@", "Private CLI detail")).count, 0)
        XCTAssertEqual(app.textViews.matching(NSPredicate(format: "value CONTAINS %@ AND value CONTAINS %@", "Original CLI privacy ask", "Private CLI detail")).count, 0, "A Messages joining payload must not embed private CLI history")
        XCTAssertEqual(shared.value as? String, "Retained unsent shared draft")
        capture(app, name: "Web CLI and Messages joins exclude private CLI detail — isolated fixture")
    }

    @MainActor
    func testWebDefaultsAndOptionalCLIConversationsStaySeparate() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        guard selectWebFixtureRecipients(app) else { app.terminate(); return }
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
            XCTAssertEqual(switchIsOn(toggle), false)
            toggle.click()
            XCTAssertEqual(switchIsOn(toggle), true)
        }
        capture(app, name: "Optional CLI toggles in Settings — simulated accounts")
        settings.buttons[XCUIIdentifierCloseWindow].click()
        for name in ["Cedar", "Lumen", "Orbit", "Maple", "Echo", "Flint", "Muse", "Grok"] {
            guard setGridRecipient(name, selected: false, in: app) else { return }
        }
        for name in ["Codex CLI", "Claude Code"] {
            XCTAssertEqual(app.buttons[name].value as? String, "Not selected", "Enabling an account is separate from choosing a recipient")
            guard setGridRecipient(name, selected: true, in: app) else { return }
        }
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
        let comparison = app.outlines.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Web and CLI comparison fixture")).firstMatch
        XCTAssertTrue(comparison.waitForExistence(timeout: 5))
        comparison.click()
        let selectedComparison = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Selected"), object: comparison)
        guard XCTWaiter.wait(for: [selectedComparison], timeout: 5) == .completed else { return XCTFail("The saved comparison button must activate its workspace") }
        XCTAssertTrue(app.buttons["Recipient Codex CLI"].waitForExistence(timeout: 5))
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
        let reopenedComparison = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Selected"), object: comparison)
        guard XCTWaiter.wait(for: [reopenedComparison], timeout: 5) == .completed else { return XCTFail("The saved comparison must reopen with its disabled CLI history") }
        XCTAssertTrue(app.buttons["Recipient Codex CLI"].waitForExistence(timeout: 5))
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
        guard selectWebFixtureRecipients(app) else { app.terminate(); return }
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
        guard selectWebFixtureRecipients(app) else { app.terminate(); return }
        app.activate()
        defer { app.terminate() }
        for name in ["Cedar", "Lumen", "Orbit", "Maple", "Echo", "Flint", "ChatGPT", "Claude", "Grok"] { app.buttons[name].click() }
        app.buttons["Muse"].rightClick()
        app.menuItems["Open chat"].click()
        let signOut = app.buttons["Sign out of fixture"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 10))
        signOut.click()
        XCTAssertTrue(app.buttons["Sign in to fixture"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["New Blast"].exists, "No comparison has been saved yet")
        let agents = app.outlines.cells.containing(NSPredicate(format: "label == %@", "Agents")).firstMatch
        XCTAssertTrue(agents.waitForExistence(timeout: 5))
        agents.click()
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
        guard selectWebFixtureRecipients(app) else { app.terminate(); return }
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
        guard selectWebFixtureRecipients(app) else { app.terminate(); return }
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
