import XCTest
@testable import msgblastCore

final class DesktopAppConversationTests: XCTestCase {
    func testDesktopAgentsRemainSeparateFromExistingAccounts() {
        XCTAssertTrue(WebProvider.museApp.usesNativeConversation)
        XCTAssertTrue(WebProvider.grokBotApp.usesNativeConversation)
        XCTAssertTrue(WebProvider.wabi.usesNativeConversation)
        XCTAssertFalse(WebProvider.muse.usesNativeConversation)
        XCTAssertNil(WebProvider.grokbot.desktopApp)
        XCTAssertNotEqual(WebProvider.museApp.storageFilename, WebProvider.muse.storageFilename)
        XCTAssertNotEqual(WebProvider.grokBotApp.storageFilename, WebProvider.grokbot.storageFilename)
    }

    func testReplyAttributionExcludesSidebarAndComposerText() throws {
        let snapshot = try decode([
            element("AXLink", "Wabi Old sidebar preview"),
            element("AXStaticText", "Old sidebar preview"),
            element("AXStaticText", "Background test"),
            element("AXPopUpButton", "Add reaction"),
            element("AXStaticText", "12:12 PM"),
            element("AXStaticText", "Read"),
            element("AXStaticText", "WABI-OK"),
            element("AXPopUpButton", "Add reaction"),
            element("AXStaticText", "12:12 PM"),
            element("AXTextArea", "Message", value: "Say something…"),
            element("AXHeading", "Wabi")
        ])
        XCTAssertEqual(try snapshot.reply(after: "Background test", app: .wabi), "WABI-OK")
        XCTAssertEqual(try snapshot.conversation(app: .wabi), "Wabi")
        XCTAssertEqual(try snapshot.composer(app: .wabi).draft, "")
    }

    func testGrokReplyUsesSpeakerAndRejectsAnotherOutgoingMessage() throws {
        let snapshot = try decode([
            element("AXHeading", "Test Bot"),
            element("AXStaticText", "You"), element("AXStaticText", "Background test"),
            element("AXStaticText", "12:12 PM"), element("AXStaticText", "Test Bot"),
            element("AXStaticText", "GROK-OK"), element("AXStaticText", "12:12 PM"),
            element("AXTextArea", "Prompt", value: "Message Test Bot")
        ])
        XCTAssertEqual(try snapshot.reply(after: "Background test", app: .grokBot), "GROK-OK")
        let interrupted = try decode([
            element("AXHeading", "Test Bot"), element("AXStaticText", "Background test"),
            element("AXStaticText", "You"), element("AXStaticText", "Unrelated user message"),
            element("AXTextArea", "Prompt", value: "Message Test Bot")
        ])
        XCTAssertThrowsError(try interrupted.reply(after: "Background test", app: .grokBot))
    }

    func testGrokConversationHeaderIgnoresHeadingsInsideReplies() throws {
        var header = element("AXHeading", "Test Bot")
        header["element_index"] = 2
        var details = element("AXButton", "View conversation details")
        details["parent_index"] = 2
        let snapshot = try decode([header, details,
                                   element("AXHeading", "A heading in the bot's answer"),
                                   element("AXTextArea", "Prompt", value: "")])
        XCTAssertEqual(try snapshot.conversation(app: .grokBot), "Test Bot")
    }

    func testGrokEmptyParagraphRequiresNativeEmptyEditorEvidence() {
        XCTAssertEqual(GrokBotNativeReader.draftValue("\n", emptyEditor: true), "")
        XCTAssertEqual(GrokBotNativeReader.draftValue("\n", emptyEditor: false), "\n")
        for text in ["Message Test Bot", "Type your answer, or talk about something else", "Keep this draft", "\n\n"] {
            XCTAssertEqual(GrokBotNativeReader.draftValue(text, emptyEditor: true), text)
        }
    }

    func testGrokBotListSeparatesExistingBotsFromActionsAndUnreadLabels() throws {
        let elements: [[String: Any]] = [
            ["role": "AXButton", "label": "Main, Main Bot, Unread activity", "element_index": 1, "element_token": "s00000001:main"],
            ["role": "AXImage", "label": "Main Bot", "parent_index": 1],
            ["role": "AXList", "element_index": 3],
            ["role": "AXButton", "label": "Research, Unread activity", "element_index": 4, "parent_index": 3, "element_token": "s00000001:research"],
            ["role": "AXButton", "label": "New Bot", "element_index": 5, "element_token": "s00000001:new"],
            ["role": "AXSplitter", "label": "Resize sidebar"]
        ]
        let snapshot = try JSONDecoder().decode(DesktopAppSnapshot.self, from: JSONSerialization.data(withJSONObject: ["elements": elements]))
        XCTAssertEqual(try snapshot.grokBots().map(\.name), ["Main", "Research"])
    }

    func testSidebarPromptPreviewCannotBeUsedAsOutgoingMessage() throws {
        let snapshot = try decode([
            element("AXStaticText", "Background test"),
            element("AXSplitter", "Resize sidebar"),
            element("AXStaticText", "Old response"),
            element("AXTextArea", "Message", value: "Say something…"),
            element("AXHeading", "Wabi")
        ])
        XCTAssertNil(try snapshot.reply(after: "Background test", app: .wabi))
    }

    func testEchoedPromptIsReturnedAsReply() throws {
        let wabi = try decode([
            element("AXStaticText", "Echo this"), element("AXPopUpButton", "Add reaction"),
            element("AXStaticText", "Echo this"), element("AXPopUpButton", "Add reaction"),
            element("AXTextArea", "Message", value: "Say something…"), element("AXHeading", "Wabi")
        ])
        XCTAssertEqual(try wabi.reply(after: "Echo this", app: .wabi), "Echo this")
        let grok = try decode([
            element("AXHeading", "Test Bot"), element("AXStaticText", "You"),
            element("AXStaticText", "Echo this"), element("AXStaticText", "Test Bot"),
            element("AXStaticText", "Echo this"), element("AXTextArea", "Prompt", value: "Message Test Bot")
        ])
        XCTAssertEqual(try grok.reply(after: "Echo this", app: .grokBot), "Echo this")
    }

    func testShortRepliesThatResembleMetadataRemainMessageText() throws {
        for reply in ["Read", "Delivered", "Today", "12:12 PM", "Test Bot", "Wabi"] {
            let grok = try decode([
                element("AXHeading", "Test Bot"), element("AXStaticText", "You"),
                element("AXStaticText", "Question"), element("AXStaticText", "12:12 PM"),
                element("AXStaticText", "Test Bot"), element("AXStaticText", reply),
                element("AXStaticText", "12:12 PM"), element("AXTextArea", "Prompt", value: "Message Test Bot")
            ])
            XCTAssertEqual(try grok.reply(after: "Question", app: .grokBot), reply)
            let wabi = try decode([
                element("AXStaticText", "Question"), element("AXPopUpButton", "Add reaction"),
                element("AXButton", "Reply"), element("AXStaticText", "12:12 PM"),
                element("AXStaticText", "Read"), element("AXStaticText", reply),
                element("AXPopUpButton", "Add reaction"), element("AXButton", "Reply"),
                element("AXStaticText", "12:12 PM"), element("AXTextArea", "Message", value: "Say something…"),
                element("AXHeading", "Wabi")
            ])
            XCTAssertEqual(try wabi.reply(after: "Question", app: .wabi), reply)
        }
    }

    func testDraftAndHumanConversationAreNotAcceptedAsWabiAI() throws {
        let snapshot = try decode([
            element("AXTextArea", "Message", value: "Keep my draft"),
            element("AXHeading", "Someone else")
        ])
        XCTAssertEqual(try snapshot.composer(app: .wabi).draft, "Keep my draft")
        XCTAssertThrowsError(try snapshot.conversation(app: .wabi))
    }

    func testTruncatedSnapshotsCannotAuthorizeSendOrReply() throws {
        let data = try JSONSerialization.data(withJSONObject: ["elements_complete": false, "total_element_count": 200, "returned_element_count": 2,
            "elements": [element("AXTextArea", "Prompt"), element("AXHeading", "Test Bot")]])
        let snapshot = try JSONDecoder().decode(DesktopAppSnapshot.self, from: data)
        XCTAssertThrowsError(try snapshot.conversation(app: .grokBot))
    }

    func testWabiThreadOwnershipIsImmutableUniqueAndCompatibleWithOlderState() throws {
        let first = UUID(), second = UUID()
        let url = URL(string: "wabi://app/threads/aaaaaaaaaaaaaaaaaaaaaaaa")!
        var state = try JSONDecoder().decode(WebWorkspaceState.self, from: Data("{\"sessionID\":\"\(UUID())\"}".utf8))
        XCTAssertNil(try state.wabiConversation(for: first))
        try state.recordWabiConversation(url, for: first)
        XCTAssertThrowsError(try state.recordWabiConversation(url, for: second))
        XCTAssertThrowsError(try state.recordWabiConversation(URL(string: "wabi://app/threads/bbbbbbbbbbbbbbbbbbbbbbbb")!, for: first))
        for invalid in ["https://app/threads/aaaaaaaaaaaaaaaaaaaaaaaa", "wabi://app/threads/aaaaaaaaaaaaaaaaaaaaaaaa?x=1", "wabi://app/threads/new", "wabi://other/threads/aaaaaaaaaaaaaaaaaaaaaaaa", "wabi://app/threads/aaaaaaaaaaaaaaaaaaaaaaaa/"] {
            XCTAssertThrowsError(try state.recordWabiConversation(URL(string: invalid)!, for: second))
        }
        let reopened = try JSONDecoder().decode(WebWorkspaceState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(try reopened.wabiConversation(for: first), url)
        XCTAssertNil(try reopened.wabiConversation(for: second))
    }

    func testWabiReceiptRejectsChangedHistoryAndForeignOutgoingMessages() throws {
        let old: [WabiAppMessage] = [.init(role: .user, text: "Earlier question"), .init(role: .assistant, text: "Earlier answer")]
        let prompt = WabiAppMessage(role: .user, text: "New question")
        let answer = WabiAppMessage(role: .assistant, text: "New answer")
        let foreign = WabiAppMessage(role: .user, text: "Another outgoing question")
        let receipt = WabiAppReceipt(baseline: old, prompt: prompt.text)
        XCTAssertNil(try receipt.reply(in: old.reversed()))
        XCTAssertNil(try receipt.reply(in: [prompt] + old.reversed()))
        XCTAssertEqual(try receipt.reply(in: [answer, prompt] + old.reversed()), "New answer")
        XCTAssertThrowsError(try receipt.reply(in: [old[1], prompt, answer]))
        XCTAssertThrowsError(try receipt.reply(in: old + [foreign, answer]))
        XCTAssertThrowsError(try receipt.reply(in: old + [prompt, foreign]))
        XCTAssertThrowsError(try receipt.reply(in: old + [prompt, foreign, answer]))
    }

    func testWabiNativeMessageFramesProveSendersAndKeepLiteralMetadataText() throws {
        func frame(_ sender: String, _ text: String) -> WabiAXNode {
            .init(role: "AXGroup", classes: ["x1n2onr6", "x193iq5w", "x67m8t7", "xc90arz", "xza2g2e", sender], children: [
                .init(role: "AXStaticText", value: text), .init(role: "AXPopUpButton", label: "Add reaction"), .init(role: "AXStaticText", value: "5:13 PM")])
        }
        let root = WabiAXNode(role: "AXWebArea", children: [frame("xpvyfi4", "Read"), frame("xqcrz7y", "5:13 PM")])
        XCTAssertEqual(try WabiNativeMessages.read(root), [.init(role: .user, text: "Read"), .init(role: .assistant, text: "5:13 PM")])
        XCTAssertThrowsError(try WabiNativeMessages.read(frame("unknown", "A message")))
        XCTAssertThrowsError(try WabiNativeMessages.read(.init(role: "AXWebArea", children: [.init(role: "AXPopUpButton", label: "Add reaction")])))
    }

    @MainActor
    func testLegacyWabiTranscriptIsPreservedWithoutAdoptingAnExistingChat() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wabi-legacy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = WebAgentSession(provider: .wabi, storageURL: directory.appendingPathComponent("state.json"), fixture: true)
        defer { session.beginShutdown() }
        session.setEnabled(true)
        await session.connectDesktopConversation()
        let comparison = UUID()
        session.updateState { $0.localConversations[comparison.uuidString] = [WebPageMessage(role: "assistant", text: "Earlier shared chat")] }
        let attempt = await session.send("Continue", comparisonID: comparison)
        XCTAssertEqual(attempt?.status, .notSent)
        XCTAssertNil(session.state.conversationURLs[comparison.uuidString])
        XCTAssertEqual(session.state.localConversations[comparison.uuidString]?.map(\.text), ["Earlier shared chat"])
        XCTAssertTrue(attempt?.detail?.contains("without a tracked dedicated chat") == true)
    }

    @MainActor
    func testNativeDesktopConversationSavesHistoryAndKeepsCLISessionsEmpty() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = WebAgentSession(provider: .wabi, storageURL: directory.appendingPathComponent("wabi.json"), fixture: true)
        session.setEnabled(true)
        await session.connectDesktopConversation()
        let comparison = UUID()
        let attempt = await session.send("Fixture prompt", comparisonID: comparison)
        XCTAssertEqual(attempt?.status, .observed)
        XCTAssertEqual(session.snapshot.messages.map(\.role), ["user", "assistant"])
        XCTAssertEqual(session.snapshot.messages.first?.text, "Fixture prompt")
        XCTAssertTrue(session.state.localSessionIDs.isEmpty, "Desktop bindings are not CLI session IDs")
        let firstThread = try XCTUnwrap(session.state.conversationURLs[comparison.uuidString])
        let followup = await session.send("Follow up", comparisonID: comparison)
        XCTAssertEqual(followup?.status, .observed)
        XCTAssertEqual(session.state.conversationURLs[comparison.uuidString], firstThread)
        let other = UUID()
        let separate = await session.send("Separate comparison", comparisonID: other)
        XCTAssertEqual(separate?.status, .observed)
        XCTAssertNotEqual(session.state.conversationURLs[other.uuidString], firstThread)
        let reopened = WebAgentSession(provider: .wabi, storageURL: directory.appendingPathComponent("wabi.json"), fixture: true)
        XCTAssertEqual(reopened.state.desktopConversation?.name, "Wabi")
        XCTAssertEqual(reopened.state.conversationURLs, session.state.conversationURLs)
        XCTAssertEqual(reopened.state.localConversations[comparison.uuidString]?.last?.text, "Wabi fixture reply: Follow up")
        session.beginShutdown(); reopened.beginShutdown()
    }

    @MainActor
    func testUncertainDesktopSendBlocksAnotherComparison() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = WebAgentSession(provider: .wabi, storageURL: directory.appendingPathComponent("wabi.json"), fixture: true)
        session.setEnabled(true)
        await session.connectDesktopConversation()
        var earlier = WebSendAttempt(text: "Earlier prompt", status: .uncertain)
        earlier.comparisonID = UUID()
        session.updateState { $0.attempts = [earlier] }
        let attempt = await session.send("Different prompt", comparisonID: UUID())
        XCTAssertNil(attempt, "An unresolved request owns the shared app conversation across comparisons")
        XCTAssertEqual(session.state.attempts.count, 1)
        session.beginShutdown()
    }

    @MainActor
    func testInterruptedDesktopRequestRetainsOwnerAndDraftAcrossRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-owner-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("wabi.json")
        let owner = UUID(), other = UUID()
        let original = WebAgentSession(provider: .wabi, storageURL: file, fixture: true)
        original.setEnabled(true)
        await original.connectDesktopConversation()
        original.updateState { $0.comparisonID = owner }
        original.updateState {
            $0.draft = "Uncertain outgoing draft"
            var interrupted = WebSendAttempt(text: "Uncertain outgoing draft", status: .attempting)
            interrupted.comparisonID = owner
            $0.attempts = [interrupted]
            $0.localConversations[owner.uuidString] = [WebPageMessage(role: "assistant", text: "Earlier answer")]
        }
        original.beginShutdown()
        let reopened = WebAgentSession(provider: .wabi, storageURL: file, fixture: true)
        defer { reopened.beginShutdown() }
        XCTAssertEqual(reopened.state.attempts.first?.status, .uncertain)
        XCTAssertEqual(reopened.state.attempts.first?.comparisonID, owner)
        XCTAssertEqual(reopened.state.draft, "Uncertain outgoing draft")
        XCTAssertEqual(reopened.state.desktopConversation?.name, "Wabi")
        reopened.updateState { $0.comparisonID = other }
        reopened.updateState { $0.draft = "Other comparison draft" }
        reopened.acknowledgeIncompleteRequest()
        let blocked = await reopened.send("New prompt", comparisonID: other)
        XCTAssertNil(blocked, "Another comparison cannot acknowledge the original request")
        XCTAssertEqual(reopened.state.attempts.count, 1)
        XCTAssertNil(reopened.state.localConversations[other.uuidString])
        reopened.updateState { $0.comparisonID = owner }
        XCTAssertEqual(reopened.state.draft, "Uncertain outgoing draft")
        reopened.acknowledgeIncompleteRequest()
        XCTAssertEqual(reopened.state.attempts.first?.status, .dismissed)
        reopened.updateState { $0.comparisonID = other }
        XCTAssertEqual(reopened.state.draft, "Other comparison draft")
        reopened.updateState { $0.draft = "New prompt" }
        let allowed = await reopened.send("New prompt", comparisonID: other)
        XCTAssertEqual(allowed?.status, .observed)
        XCTAssertEqual(reopened.state.localConversations[owner.uuidString]?.map(\.text), ["Earlier answer"])
        XCTAssertEqual(reopened.state.localConversations[other.uuidString]?.first?.text, "New prompt")
        XCTAssertTrue(reopened.state.localSessionIDs.isEmpty)
    }

    private func element(_ role: String, _ label: String, value: String? = nil) -> [String: Any] {
        var result: [String: Any] = ["role": role, "label": label, "element_token": "s00000001:\(UUID().uuidString)", "in_web_content": true]
        if role == "AXHeading" { result["value"] = "2" }
        if let value { result["value"] = value }
        return result
    }
    private func decode(_ elements: [[String: Any]]) throws -> DesktopAppSnapshot {
        try JSONDecoder().decode(DesktopAppSnapshot.self, from: JSONSerialization.data(withJSONObject: ["elements": [element("AXSplitter", "Resize sidebar")] + elements, "elements_complete": true]))
    }
}

/// Runs the real adapter/process boundary. The executable below only consumes a
/// local JSON plan; it cannot discover or contact the installed Cua service.
@MainActor
final class DesktopAppDriverTests: XCTestCase {
    private let prompt = "Fixture prompt"
    private let binding = DesktopConversationBinding(name: "Fixture Bot")

    func testBotDiscoveryIsReadOnlyAndSelectionOpensOnlyTheChosenBot() async throws {
        let initial = grok(name: "Other Bot", bots: ["Other Bot", "Fixture Bot"])
        let discovery = try driver([apps(), windows(), snapshot(initial)])
        defer { discovery.remove() }
        let names = try await adapter(discovery).availableGrokBots()
        XCTAssertEqual(names, ["Fixture Bot", "Other Bot"])
        assertNoInput(try await finishedCalls(discovery))
        let fixture = try driver([apps(), windows(), snapshot(initial),
                                  step("click", [:], arguments: ["element_token": "s00000001:bot1"]),
                                  snapshot(grok())])
        defer { fixture.remove() }
        let selected = try await adapter(fixture).connectGrokBot(named: "Fixture Bot")
        XCTAssertEqual(selected.name, "Fixture Bot")
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1)
        XCTAssertFalse(calls.contains { $0.tool == "type_text" })
        assertBackgroundTargets(calls)
    }

    func testSavedBotIsOpenedBeforeTypingAndDuplicateOrDraftedTargetsStop() async throws {
        let initial = grok(name: "Other Bot", bots: ["Other Bot", "Fixture Bot"])
        let fixture = try driver([apps(), windows(), snapshot(initial),
                                  step("click", [:], arguments: ["element_token": "s00000001:bot1"]),
                                  snapshot(grok(token: "s00000002")),
                                  step("type_text", [:], arguments: ["element_token": "s00000002:composer"]),
                                  snapshot(grok(draft: prompt, token: "s00000003")),
                                  step("click", [:], arguments: ["element_token": "s00000003:send"]),
                                  snapshot(grok(reply: "Chosen bot answer", token: "s00000004"), repeating: true)])
        defer { fixture.remove() }
        let answer = try await adapter(fixture).reply(prompt, app: .grokBot, binding: binding)
        XCTAssertEqual(answer, "Chosen bot answer")
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 2)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        for state in [grok(bots: ["Fixture Bot", "Fixture Bot"]), grok(draft: "Message Fixture Bot")] {
            let denied = try driver([apps(), windows(), snapshot(state)])
            defer { denied.remove() }
            _ = await failure { try await self.adapter(denied).reply(self.prompt, app: .grokBot, binding: self.binding) }
            assertNoInput(try await finishedCalls(denied))
        }
        let drafted = try driver([apps(), windows(), snapshot(initial), step("click", [:]), snapshot(grok(draft: "Keep this draft"))])
        defer { drafted.remove() }
        _ = await failure { try await self.adapter(drafted).reply(self.prompt, app: .grokBot, binding: self.binding) }
        let draftedCalls = try await finishedCalls(drafted)
        XCTAssertEqual(draftedCalls.filter { $0.tool == "click" }.count, 1, "Only bot navigation is allowed")
        XCTAssertFalse(draftedCalls.contains { $0.tool == "type_text" })
    }

    func testNativeBotOrDraftDisagreementAndReadFailurePreventAllInput() async throws {
        let observations: [[String: String]?] = [
            ["name": "Other Bot", "draft": ""],
            ["name": "Fixture Bot", "draft": "Keep this native draft"],
            nil
        ]
        for native in observations {
            var state = grok()
            state["_grok_native"] = native
            let fixture = try driver([apps(), windows(), snapshot(state)])
            defer { fixture.remove() }
            _ = await failure { try await self.adapter(fixture).reply(self.prompt, app: .grokBot, binding: self.binding) }
            assertNoInput(try await finishedCalls(fixture))
        }
    }

    func testNativeDisagreementAfterTypingNeverClicksSend() async throws {
        let observations: [[String: String]?] = [
            ["name": "Other Bot", "draft": prompt],
            ["name": "Fixture Bot", "draft": "Changed after typing"],
            nil
        ]
        for native in observations {
            var prepared = grok(draft: prompt, token: "s00000002")
            prepared["_grok_native"] = native
            var typed = step("type_text", [:])
            if native == nil { typed["remove_grok_native"] = true }
            let fixture = try driver([apps(), windows(), snapshot(grok()), typed, snapshot(prepared)])
            defer { fixture.remove() }
            _ = await failure { try await self.adapter(fixture).reply(self.prompt, app: .grokBot, binding: self.binding) }
            let calls = try await finishedCalls(fixture)
            XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
            XCTAssertFalse(calls.contains { $0.tool == "click" })
            assertBackgroundTargets(calls)
        }
    }

    func testChoosingABotSavesAndRestoresTheExplicitChoiceWithoutASend() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-bot-choice-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("state.json")
        let session = WebAgentSession(provider: .grokBotApp, storageURL: file, fixture: true)
        session.setEnabled(true)
        await session.refreshGrokBots()
        XCTAssertNil(session.state.desktopConversation)
        XCTAssertFalse(session.desktopReady)
        await session.connectDesktopConversation(botName: "Research Bot")
        XCTAssertTrue(session.desktopReady)
        XCTAssertEqual(session.state.desktopConversation?.name, "Research Bot")
        XCTAssertTrue(session.state.attempts.isEmpty)
        session.beginShutdown()
        let reopened = WebAgentSession(provider: .grokBotApp, storageURL: file, fixture: true)
        defer { reopened.beginShutdown() }
        await reopened.refreshGrokBots()
        XCTAssertEqual(reopened.state.desktopConversation?.name, "Research Bot")
        XCTAssertTrue(reopened.desktopReady)
        XCTAssertTrue(reopened.state.attempts.isEmpty)
        var pending = WebSendAttempt(text: "Earlier request", status: .uncertain)
        pending.comparisonID = UUID()
        reopened.updateState { $0.attempts = [pending] }
        await reopened.connectDesktopConversation(botName: "Writing Bot")
        XCTAssertEqual(reopened.state.desktopConversation?.name, "Research Bot")
        XCTAssertEqual(reopened.state.attempts.first?.status, .uncertain)
        XCTAssertFalse(reopened.desktopReady)
    }

    func testSavedBotAvailabilityChecksDoNotNavigateFromTheCurrentBot() async throws {
        let other = grok(name: "Other Bot", bots: ["Fixture Bot", "Other Bot"])
        let read = [apps(), windows(), snapshot(other)]
        let fixture = try driver(read + read + read)
        defer { fixture.remove() }
        let session = WebAgentSession(provider: .grokBotApp, storageURL: fixture.directory.appendingPathComponent("state.json"), fixture: false,
                                      museApp: .shared, desktopApps: .demo, desktopDriver: adapter(fixture))
        defer { session.beginShutdown() }
        session.setEnabled(true)
        session.updateState { $0.desktopConversation = binding }
        await session.refreshGrokBots()
        XCTAssertEqual(session.grokBotNames, ["Fixture Bot", "Other Bot"])
        XCTAssertEqual(session.state.desktopConversation, binding)
        XCTAssertTrue(session.isReadyForOnboarding, session.desktopStatus)
        await session.refresh()
        XCTAssertTrue(session.snapshot.ready, session.desktopStatus)
        XCTAssertTrue(session.state.attempts.isEmpty)
        assertNoInput(try await finishedCalls(fixture, cleanupCount: 3))
    }

    func testGrokDiscoveryAndSelectionWaitForReadinessRefresh() async throws {
        for choosing in [false, true] {
            let initial = grok(bots: ["Fixture Bot", "Other Bot"])
            var waiting = windows(); waiting["wait_for_release"] = true
            let afterRefresh = choosing
                ? [apps(), windows(), snapshot(initial), step("click", [:]), snapshot(grok(name: "Other Bot", bots: ["Fixture Bot", "Other Bot"]))]
                : [apps(), windows(), snapshot(initial), apps(), windows(), snapshot(initial)]
            let fixture = try driver([apps(), waiting, snapshot(initial)] + afterRefresh)
            defer { fixture.remove() }
            let session = WebAgentSession(provider: .grokBotApp, storageURL: fixture.directory.appendingPathComponent("state.json"), fixture: false,
                                          museApp: .shared, desktopApps: .demo, desktopDriver: adapter(fixture))
            defer { session.beginShutdown() }
            session.setEnabled(true)
            session.updateState { $0.desktopConversation = binding }
            session.connect(automaticallyRefresh: false)
            let readiness = Task { await session.refresh() }
            try await waitForCall("list_windows", in: fixture)
            let setup = Task {
                if choosing { await session.connectDesktopConversation(botName: "Other Bot") }
                else { await session.refreshGrokBots() }
            }
            try await Task.sleep(for: .milliseconds(50))
            try Data().write(to: fixture.directory.appendingPathComponent("release"))
            await readiness.value
            await setup.value
            XCTAssertEqual(session.state.desktopConversation?.name, choosing ? "Other Bot" : "Fixture Bot")
            if !choosing { XCTAssertEqual(session.grokBotNames, ["Fixture Bot", "Other Bot"]) }
            XCTAssertTrue(session.desktopReady, session.desktopStatus)
            XCTAssertTrue(session.state.attempts.isEmpty)
            let calls = try await finishedCalls(fixture, cleanupCount: choosing ? 2 : 3)
            XCTAssertFalse(calls.contains { $0.tool == "type_text" })
            if !choosing { assertNoInput(calls) }
        }
    }

    func testSendingWhileBotSelectionIsInProgressCannotUseTheOldBinding() async throws {
        var switching = step("click", [:]); switching["wait_for_release"] = true
        let fixture = try driver([apps(), windows(), snapshot(grok()),
                                  apps(), windows(), snapshot(grok(bots: ["Fixture Bot", "Other Bot"])), switching])
        defer { fixture.remove() }
        let session = WebAgentSession(provider: .grokBotApp, storageURL: fixture.directory.appendingPathComponent("state.json"), fixture: false,
                                      museApp: .shared, desktopApps: .demo, desktopDriver: adapter(fixture))
        defer { session.beginShutdown() }
        session.setEnabled(true)
        await session.connectDesktopConversation(botName: "Fixture Bot")
        XCTAssertTrue(session.snapshot.ready)
        let changing = Task { await session.connectDesktopConversation(botName: "Other Bot") }
        try await waitForCall("click", in: fixture)
        XCTAssertTrue(session.loading)
        let sent = await session.send(prompt, comparisonID: UUID())
        XCTAssertNil(sent)
        XCTAssertTrue(session.state.attempts.isEmpty)
        changing.cancel()
        await changing.value
        XCTAssertEqual(session.state.desktopConversation?.name, "Fixture Bot")
        let calls = try await finishedCalls(fixture, cleanupCount: 2)
        XCTAssertFalse(calls.contains { $0.tool == "type_text" })
    }

    func testUnverifiedTypingUsesFreshDraftEvidenceAndSubmitsOnlyOnce() async throws {
        for diagnostic: [String: Any] in [
            ["effect": "unverifiable", "escalation": ["reason": "delivery_failed", "target": "foreground"]],
            ["effect": "partial", "code": "type_text_incomplete", "delivered_chars": 0]
        ] {
            let fixture = try driver([
                apps(), windows(), snapshot(grok()),
                step("type_text", diagnostic, arguments: ["element_token": "s00000001:composer", "text": prompt]),
                snapshot(grok(draft: prompt, token: "s00000002")),
                step("click", ["effect": "unverifiable"], arguments: ["element_token": "s00000002:send"]),
                snapshot(grok(reply: "Observed answer", token: "s00000003"), repeating: true)
            ])
            defer { fixture.remove() }
            let answer = try await adapter(fixture).reply(prompt, app: .grokBot, binding: binding)
            XCTAssertEqual(answer, "Observed answer")
            let calls = try await finishedCalls(fixture)
            XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1, "A false-negative type result must not replay the prompt")
            XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1)
            assertBackgroundTargets(calls)
        }
    }

    func testWabiUsesSavedThreadIdentityAndFreshSendControl() async throws {
        var initial = windows(); initial["native"] = wabiNative()
        var typed = step("type_text", ["effect": "unverifiable"], arguments: ["element_token": "s00000001:composer"])
        typed["native"] = wabiNative(draft: prompt)
        var sent = step("click", [:], arguments: ["element_token": "s00000002:send"])
        sent["native"] = wabiNative(messages: [.init(role: .user, text: prompt), .init(role: .assistant, text: "Wabi fixture answer")])
        var renamed = wabi(reply: "Wabi fixture answer", token: "s00000003")
        var body = renamed["elements"] as! [[String: Any]]; body[0]["label"] = "Renamed by Wabi"; renamed["elements"] = body
        let fixture = try driver([apps(.wabi), initial, snapshot(wabi()), typed,
                                  snapshot(wabi(draft: prompt, token: "s00000002")), sent, snapshot(renamed, repeating: true)])
        defer { fixture.remove() }
        let answer = try await wabiAdapter(fixture).reply(prompt, in: wabiURL)
        XCTAssertEqual(answer, "Wabi fixture answer")
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        assertBackgroundTargets(calls)

        var wrong = windows(); wrong["native"] = wabiNative(url: otherWabiURL)
        let denied = try driver([apps(.wabi), wrong, snapshot(wabi())])
        defer { denied.remove() }
        let error = await failure { try await self.wabiAdapter(denied).reply(self.prompt, in: self.wabiURL) }
        XCTAssertTrue(error.contains("selected chat changed"), error)
        assertNoInput(try await finishedCalls(denied))
    }

    func testWabiReplyUsesNewMessagesInEitherOrderAndAcceptsAnEcho() async throws {
        let welcome = "What can I do for you?"
        for (messages, expected) in [(["New answer", prompt, welcome], "New answer"),
                                     ([welcome, prompt, prompt], prompt),
                                     (["Read", prompt, welcome], "Read"),
                                     (["Today", prompt, welcome], "Today"),
                                     (["5:13 PM", prompt, welcome], "5:13 PM")] {
            let before: [WabiAppMessage] = [.init(role: .assistant, text: welcome)]
            let outgoing = WabiAppMessage(role: .user, text: prompt)
            let incoming = WabiAppMessage(role: .assistant, text: expected)
            let observed = messages.first == welcome ? before + [outgoing, incoming] : [incoming, outgoing] + before
            var initial = windows(); initial["native"] = wabiNative(messages: before)
            var typed = step("type_text", [:]); typed["native"] = wabiNative(draft: prompt, messages: before)
            var sent = step("click", [:]); sent["native"] = wabiNative(messages: observed)
            let fixture = try driver([apps(.wabi), initial, snapshot(wabiMessages([welcome])), typed,
                                      snapshot(wabiMessages([welcome], draft: prompt)), sent,
                                      snapshot(wabiMessages(messages), repeating: true)])
            defer { fixture.remove() }
            let answer = try await wabiAdapter(fixture).reply(prompt, in: wabiURL)
            XCTAssertEqual(answer, expected)
            let calls = try await finishedCalls(fixture)
            XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1)
            XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        }
    }

    private func wabiMessages(_ messages: [String], draft: String = "") -> [String: Any] {
        var state = wabi(draft: draft)
        var body = state["elements"] as! [[String: Any]]
        let content = messages.flatMap { [element("AXStaticText", $0), element("AXPopUpButton", "Add reaction"), element("AXStaticText", "5:13 PM")] }
        body.insert(contentsOf: content, at: 3)
        state["elements"] = body; state["returned_element_count"] = body.count; state["total_element_count"] = body.count
        return state
    }

    func testWabiCreatesAIThreadThroughChooserAndResumesExactSidebarURL() async throws {
        let fixture = try driver(wabiCreationSteps())
        defer { fixture.remove() }
        let created = try await wabiAdapter(fixture).prepare(savedURL: nil)
        XCTAssertEqual(created, otherWabiURL)
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 2)
        XCTAssertFalse(calls.contains { $0.tool == "type_text" })
        assertBackgroundTargets(calls)

        var resume = windows(); resume["native"] = wabiNative(links: [["url": otherWabiURL.absoluteString, "label": "Same title"]])
        var select = step("click", [:], arguments: ["element_token": "s00000004:saved"]); select["native"] = wabiNative(url: otherWabiURL)
        let saved = try driver([apps(.wabi), resume, snapshot(wabiWith([element("AXLink", "Same title", token: "s00000004:saved")])), select, snapshot(wabi())])
        defer { saved.remove() }
        let resumed = try await wabiAdapter(saved).prepare(savedURL: otherWabiURL)
        XCTAssertEqual(resumed, otherWabiURL)
        let resumeCalls = try await finishedCalls(saved)
        XCTAssertEqual(resumeCalls.filter { $0.tool == "click" }.count, 1)
    }

    func testWabiMissingAmbiguousSavedChatAndDraftNeverCreateReplacement() async throws {
        for mode in ["missing", "ambiguous", "draft"] {
            let links = mode == "missing" ? [] : [["url": otherWabiURL.absoluteString, "label": "Same title"]]
            var initial = windows(); initial["native"] = wabiNative(draft: mode == "draft" ? "Keep this" : "", links: links)
            let rows = mode == "ambiguous" ? [element("AXLink", "Same title"), element("AXLink", "Same title")] : []
            let fixture = try driver([apps(.wabi), initial, snapshot(wabiWith(rows, draft: mode == "draft" ? "Keep this" : ""))])
            defer { fixture.remove() }
            let error = await failure { try await self.wabiAdapter(fixture).prepare(savedURL: self.otherWabiURL).absoluteString }
            XCTAssertFalse(error.isEmpty)
            assertNoInput(try await finishedCalls(fixture))
        }
    }

    func testWabiChangedThreadOrHistoryAfterTypingPreservesDraftWithoutSend() async throws {
        for changedHistory in [false, true] {
            var initial = windows(); initial["native"] = wabiNative()
            var typed = step("type_text", [:])
            typed["native"] = wabiNative(url: changedHistory ? wabiURL : otherWabiURL, draft: prompt,
                                         messages: changedHistory ? [.init(role: .user, text: "Another outgoing question")] : [])
            let fixture = try driver([apps(.wabi), initial, snapshot(wabi()), typed, snapshot(wabi(draft: prompt))])
            defer { fixture.remove() }
            let error = await failure { try await self.wabiAdapter(fixture).reply(self.prompt, in: self.wabiURL) }
            XCTAssertTrue(error.contains("Send was not pressed"), error)
            let calls = try await finishedCalls(fixture)
            XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
            XCTAssertFalse(calls.contains { $0.tool == "click" })
        }
    }

    func testWabiConnectionCheckIsReadOnlyAndGenericSendIsUnavailable() async throws {
        var initial = windows(); initial["native"] = wabiNative()
        let fixture = try driver([apps(.wabi), initial, snapshot(wabiWith([element("AXButton", "New chat")]))])
        defer { fixture.remove() }
        try await wabiAdapter(fixture).checkAvailable()
        assertNoInput(try await finishedCalls(fixture))
        let generic = try driver([])
        defer { generic.remove() }
        let error = await failure { try await self.adapter(generic).reply(self.prompt, app: .wabi, binding: .init(name: "Wabi")) }
        XCTAssertTrue(error.contains("dedicated chat"), error)
        XCTAssertTrue(try generic.calls().isEmpty)
    }

    func testWabiSavesCreatedDestinationBeforeTypingAndKeepsItAfterCancellation() async throws {
        var ready = windows(); ready["native"] = wabiNative(url: otherWabiURL)
        var blocked = step("type_text", [:]); blocked["wait_for_release"] = true
        let fixture = try driver(wabiCreationSteps() + [apps(.wabi), ready, snapshot(wabi()), blocked])
        defer { fixture.remove() }
        let file = fixture.directory.appendingPathComponent("state.json")
        let owner = UUID()
        let session = WebAgentSession(provider: .wabi, storageURL: file, fixture: false, museApp: .shared, desktopApps: .demo, wabiApp: wabiAdapter(fixture), desktopDriver: try readinessDriver(fixture, app: .wabi))
        session.setEnabled(true)
        session.updateState { $0.desktopConversation = .init(name: "Wabi") }
        let sending = Task { await session.send(prompt, comparisonID: owner) }
        try await waitForCall("type_text", in: fixture)
        let saved = try JSONDecoder().decode(WebWorkspaceState.self, from: Data(contentsOf: file))
        XCTAssertEqual(saved.conversationURLs[owner.uuidString], otherWabiURL)
        XCTAssertEqual(saved.attempts.first?.conversationURL, otherWabiURL)
        XCTAssertEqual(saved.attempts.first?.status, .attempting)
        session.cancelNativeRequest()
        let attempt = await sending.value
        XCTAssertEqual(attempt?.status, .uncertain)
        session.beginShutdown()
        let reopened = WebAgentSession(provider: .wabi, storageURL: file, fixture: true)
        defer { reopened.beginShutdown() }
        XCTAssertEqual(reopened.state.conversationURLs[owner.uuidString], otherWabiURL)
        XCTAssertEqual(reopened.state.attempts.first?.conversationURL, otherWabiURL)
        let retry = await reopened.send("Another prompt", comparisonID: owner)
        XCTAssertNil(retry)
        let calls = try await finishedCalls(fixture, cleanupCount: 2)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 2, "Only the two New chat navigation controls were pressed")
        XCTAssertFalse(calls.contains { $0.arguments["element_token"] as? String == "s00000001:send" })
    }

    private func wabiCreationSteps() -> [[String: Any]] {
        var initial = windows(); initial["native"] = wabiNative()
        let navigation = [element("AXButton", "New chat", token: "s00000001:new")]
        var open = step("click", [:], arguments: ["element_token": "s00000001:new"])
        open["native"] = wabiNative(draft: nil)
        let chooser = [element("AXHeading", "New chat"), element("AXHeading", "Contacts on Wabi"),
                       element("AXTextField", "Name, username, or phone number"), element("AXButton", "New chat", token: "s00000002:new"),
                       element("AXButton", "Eugenia Kuyda @eugenia")]
        var create = step("click", [:], arguments: ["element_token": "s00000002:new"])
        create["native"] = wabiNative(url: otherWabiURL, messages: [.init(role: .assistant, text: "What can I do for you?")])
        var blank = wabi(); var elements = blank["elements"] as! [[String: Any]]
        elements[0]["label"] = "New chat"; elements.insert(contentsOf: [element("AXStaticText", "What can I do for you?"), element("AXPopUpButton", "Add reaction"), element("AXStaticText", "5:13 PM")], at: 3)
        blank["elements"] = elements; blank["returned_element_count"] = elements.count; blank["total_element_count"] = elements.count
        return [apps(.wabi), initial, snapshot(wabiWith(navigation)), open, snapshot(["elements": chooser]), create, snapshot(blank)]
    }

    private var wabiURL: URL { URL(string: "wabi://app/threads/aaaaaaaaaaaaaaaaaaaaaaaa")! }
    private var otherWabiURL: URL { URL(string: "wabi://app/threads/bbbbbbbbbbbbbbbbbbbbbbbb")! }
    private func wabiNative(url: URL? = nil, draft: String? = "", links: [[String: String]] = [], messages: [WabiAppMessage] = []) -> [String: Any] {
        var result: [String: Any] = ["url": (url ?? wabiURL).absoluteString, "links": links, "messages": messages.map { ["role": $0.role.rawValue, "text": $0.text] }]
        if let draft { result["draft"] = draft }
        return result
    }
    private func wabiWith(_ additions: [[String: Any]], draft: String = "") -> [String: Any] {
        var state = wabi(draft: draft)
        let body = additions + (state["elements"] as! [[String: Any]])
        state["elements"] = body; state["returned_element_count"] = body.count; state["total_element_count"] = body.count
        return state
    }
    private func wabiAdapter(_ fixture: DriverFixture) -> WabiAppConversation {
        let file = fixture.directory.appendingPathComponent("native.json")
        return WabiAppConversation(executable: fixture.executable, timing: .init(pollInterval: .milliseconds(5), stableDuration: .milliseconds(60), replyTimeout: .seconds(2), callTimeout: 3)) { target in
            guard target.pid == 4242, target.window == 101 else { throw CocoaError(.fileReadUnknown) }
            return try JSONDecoder().decode(WabiAppObservation.self, from: Data(contentsOf: file))
        }
    }

    func testAmbiguousMainWindowsPreventAllInput() async throws {
        let fixture = try driver([apps(), step("list_windows", ["windows": [
            ["window_id": 101, "title": "First chat", "bounds": ["width": 800, "height": 600]],
            ["window_id": 102, "title": "Second chat", "bounds": ["width": 800, "height": 600]]
        ]])])
        defer { fixture.remove() }
        let error = await failure { try await self.adapter(fixture).reply(self.prompt, app: .grokBot, binding: self.binding) }
        XCTAssertTrue(error.contains("one main Grok Bot window"), error)
        assertNoInput(try await finishedCalls(fixture))
    }

    func testPartialOrChangedDraftNeverClicksSendOrRetriesTyping() async throws {
        for draft in ["Fixture", "Fixture prompt plus someone else's edit", ""] {
            let fixture = try driver([
                apps(), windows(), snapshot(grok()),
                step("type_text", ["effect": "partial", "delivered_chars": 7]),
                snapshot(grok(draft: draft, token: "s00000002"))
            ])
            defer { fixture.remove() }
            let error = await failure { try await self.adapter(fixture).reply(self.prompt, app: .grokBot, binding: self.binding) }
            XCTAssertTrue(error.contains("prepared draft"), error)
            let calls = try await finishedCalls(fixture)
            XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
            XCTAssertFalse(calls.contains { $0.tool == "click" })
            assertBackgroundTargets(calls)
        }
    }

    func testExternalDraftAndMissingBotPreventAllInput() async throws {
        for (state, reason) in [(grok(draft: "Keep this external draft"), "unsent draft"),
                                (grok(name: "Other Bot"), "missing")] {
            let fixture = try driver([apps(), windows(), snapshot(state)])
            defer { fixture.remove() }
            let error = await failure { try await self.adapter(fixture).reply(self.prompt, app: .grokBot, binding: self.binding) }
            XCTAssertTrue(error.contains(reason), error)
            assertNoInput(try await finishedCalls(fixture))
        }
    }

    func testConversationSwitchAfterTypingPreservesDraftAndNeverSubmits() async throws {
        let fixture = try driver([
            apps(), windows(), snapshot(grok()), step("type_text", ["effect": "unverifiable"]),
            snapshot(grok(draft: prompt, name: "Other Bot", token: "s00000002"))
        ])
        defer { fixture.remove() }
        let error = await failure { try await self.adapter(fixture).reply(self.prompt, app: .grokBot, binding: self.binding) }
        XCTAssertTrue(error.contains("conversation changed"), error)
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        XCTAssertFalse(calls.contains { $0.tool == "click" })
    }

    func testChangedConversationWhileWaitingCannotReturnItsReply() async throws {
        let fixture = try driver(sendSteps() + [snapshot(grok(reply: "Wrong conversation's answer", name: "Other Bot", token: "s00000003"))])
        defer { fixture.remove() }
        let error = await failure { try await self.adapter(fixture).reply(self.prompt, app: .grokBot, binding: self.binding) }
        XCTAssertTrue(error.contains("conversation changed"), error)
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1)
    }

    func testDegradedAndTruncatedSnapshotsPreventAllInput() async throws {
        let invalid: [[String: Any]] = [
            ["elements": [], "degraded": true, "degraded_reason": "ax_window_unresolved"],
            ["elements": grok()["elements"]!, "total_element_count": 200, "returned_element_count": 3]
        ]
        for state in invalid {
            let fixture = try driver([apps(), windows(), snapshot(state)])
            defer { fixture.remove() }
            let error = await failure { try await self.adapter(fixture).reply(self.prompt, app: .grokBot, binding: self.binding) }
            XCTAssertTrue(error.contains("snapshot is incomplete"), error)
            assertNoInput(try await finishedCalls(fixture))
        }
    }

    func testMissingDisabledOrAmbiguousSendControlCannotSubmit() async throws {
        let base = grok(draft: prompt, token: "s00000002")
        let elements = try XCTUnwrap(base["elements"] as? [[String: Any]])
        let button = try XCTUnwrap(elements.last)
        var disabled = button; disabled["enabled"] = false
        let variants = [Array(elements.dropLast()), Array(elements.dropLast()) + [disabled], elements + [button]]
        for variant in variants {
            let fixture = try driver([apps(), windows(), snapshot(grok()), step("type_text", [:]), snapshot(["elements": variant, "_grok_native": ["name": "Fixture Bot", "draft": prompt]])])
            defer { fixture.remove() }
            let error = await failure { try await self.adapter(fixture).reply(self.prompt, app: .grokBot, binding: self.binding) }
            XCTAssertTrue(error.contains("Send control"), error)
            let calls = try await finishedCalls(fixture)
            XCTAssertFalse(calls.contains { $0.tool == "click" })
        }
    }

    func testDriverRefusalNeverFallsBackToForegroundOrResends() async throws {
        for refusal: [String: Any] in [
            ["status": "refused", "refusal": ["code": "background_unavailable"]],
            ["isError": true, "message": "Permission denied"]
        ] {
            let fixture = try driver([apps(), windows(), snapshot(grok()), step("type_text", refusal)])
            defer { fixture.remove() }
            let error = await failure { try await self.adapter(fixture).reply(self.prompt, app: .grokBot, binding: self.binding) }
            XCTAssertTrue(error.contains("refused type_text"), error)
            let calls = try await finishedCalls(fixture)
            XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
            XCTAssertFalse(calls.contains { $0.tool == "click" })
            assertBackgroundTargets(calls)
        }
    }

    func testRepeatedPromptCannotReturnOldAnswer() async throws {
        let old = grok(reply: "Old answer")
        let prepared = grok(draft: prompt, reply: "Old answer", token: "s00000002")
        let new = grok(reply: "New answer", token: "s00000004", previousReply: "Old answer")
        let fixture = try driver([
            apps(), windows(), snapshot(old), step("type_text", [:]), snapshot(prepared), step("click", [:]),
            snapshot(grok(reply: "Old answer", token: "s00000003")), snapshot(new, repeating: true)
        ])
        defer { fixture.remove() }
        let answer = try await adapter(fixture).reply(prompt, app: .grokBot, binding: binding)
        XCTAssertEqual(answer, "New answer")
        _ = try await finishedCalls(fixture)
    }

    func testGenerationAndUnclearedComposerCannotFinishTheReply() async throws {
        let fixture = try driver(sendSteps() + [
            snapshot(grok(draft: prompt, reply: "Still a draft", token: "s00000003")),
            snapshot(grok(reply: "Partial answer", token: "s00000004", generating: true)),
            snapshot(grok(reply: "Final answer", token: "s00000005"), repeating: true)
        ])
        defer { fixture.remove() }
        let answer = try await adapter(fixture).reply(prompt, app: .grokBot, binding: binding)
        XCTAssertEqual(answer, "Final answer")
        let calls = try await finishedCalls(fixture)
        XCTAssertGreaterThanOrEqual(calls.filter { $0.tool == "get_window_state" }.count, 6)
    }

    func testTimeoutAfterSubmissionDoesNotClickSendAgain() async throws {
        let fixture = try driver(sendSteps() + [snapshot(grok(token: "s00000003"), repeating: true)])
        defer { fixture.remove() }
        let error = await failure { try await self.adapter(fixture, replyTimeout: .milliseconds(180)).reply(self.prompt, app: .grokBot, binding: self.binding) }
        XCTAssertTrue(error.contains("No stable reply"), error)
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1)
        assertBackgroundTargets(calls)
    }

    func testCancellationStopsDriverProcessAndReleasesAppForAnotherRequest() async throws {
        var blocked = step("type_text", ["effect": "unverifiable"])
        blocked["wait_for_release"] = true
        let fixture = try driver([apps(), windows(), snapshot(grok()), blocked])
        defer { fixture.remove() }
        let conversation = adapter(fixture)
        let sending = Task { try await conversation.reply(prompt, app: .grokBot, binding: binding) }
        try await waitForCall("type_text", in: fixture)
        let collision = await failure { try await conversation.reply("Another request", app: .grokBot, binding: self.binding) }
        XCTAssertTrue(collision.contains("already handling"), collision)
        sending.cancel()
        do { _ = try await sending.value; XCTFail("Canceled driver request must not complete") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        let calls = try await finishedCalls(fixture)
        let call = try XCTUnwrap(calls.first { $0.tool == "type_text" })
        XCTAssertEqual(kill(Int32(call.pid), 0), -1, "The fake driver process must not survive cancellation")
        XCTAssertFalse(calls.contains { $0.tool == "click" })
        try fixture.replacePlan([apps(), windows(), snapshot(grok())])
        let inspected = try await conversation.connectGrokBot(named: binding.name)
        XCTAssertEqual(inspected, binding)
        _ = try await finishedCalls(fixture, cleanupCount: 2)
    }

    func testDriverTimeoutStopsProcessBeforeAnySend() async throws {
        var blocked = step("type_text", [:]); blocked["wait_for_release"] = true
        let fixture = try driver([apps(), windows(), snapshot(grok()), blocked])
        defer { fixture.remove() }
        let conversation = adapter(fixture, callTimeout: 1)
        do { _ = try await conversation.reply(prompt, app: .grokBot, binding: binding); XCTFail("Expected the driver call to time out") }
        catch {
            guard case PersonalAgentError.timedOut = error else { return XCTFail("Expected timeout, got \(error)") }
        }
        let calls = try await finishedCalls(fixture)
        let call = try XCTUnwrap(calls.first { $0.tool == "type_text" })
        XCTAssertEqual(kill(Int32(call.pid), 0), -1)
        XCTAssertFalse(calls.contains { $0.tool == "click" })
    }

    func testMuseMainChatAndUntrackedSideChatCannotAuthorizeAutomaticSend() async throws {
        for title in ["Main chat", "Side chat A", "Side chat B"] {
            // Even if Muse exposes a standard editable field in a later app
            // version, a generic "Muse" heading cannot identify a side chat.
            let state: [String: Any] = ["elements": [
                element("AXButton", "Muse"), element("AXStaticText", title),
                element("AXTextArea", "Message", value: ""), element("AXButton", "Send")
            ]]
            let fixture = try driver([apps(.muse), windows(), snapshot(state)])
            defer { fixture.remove() }
            let error = await failure { try await self.adapter(fixture).reply(self.prompt, app: .muse, binding: .init(name: "Muse")) }
            XCTAssertTrue(error.contains("side-chat"), "An untracked \(title) must remain gated: \(error)")
            assertNoInput(try await finishedCalls(fixture))
        }
    }

    func testMuseCompoundComposerAndOffSpaceSnapshotRemainReadOnly() async throws {
        for state: [String: Any] in [
            ["elements": [element("AXButton", "Back to main chat"), element("AXStaticText", "New side chat"),
                          element("AXButton", "Message Attach file Dictate a message Send"), element("AXButton", "Muse")]],
            ["elements": [], "degraded": true, "degraded_reason": "ax_window_unresolved"]
        ] {
            let fixture = try driver([apps(.muse), windows(), snapshot(state)])
            defer { fixture.remove() }
            _ = await failure { try await self.adapter(fixture).reply(self.prompt, app: .muse, binding: .init(name: "Muse")) }
            assertNoInput(try await finishedCalls(fixture))
        }
    }

    func testMuseOnboardingCheckReadsComposerWithoutInputAndKeepsAnActionableFailure() async throws {
        for draft in ["", "Unsent Muse draft"] {
            var window = windows()
            window["native"] = try object(museObservation(draft: draft))
            let fixture = try driver([apps(.muse), window])
            defer { fixture.remove() }
            let session = WebAgentSession(provider: .museApp, storageURL: fixture.directory.appendingPathComponent("state.json"),
                                          fixture: false, museApp: museAdapter(fixture), desktopApps: .demo, desktopDriver: try readinessDriver(fixture, app: .muse))
            session.setEnabled(true)
            await session.connectDesktopConversation()
            XCTAssertEqual(session.desktopReady, draft.isEmpty)
            XCTAssertEqual(session.desktopConnectionConfirmation != nil, draft.isEmpty)
            if !draft.isEmpty {
                let failure = session.desktopStatus
                XCTAssertTrue(failure.contains("draft"))
                session.refreshDesktopInstallation()
                XCTAssertEqual(session.desktopStatus, failure, "Reactivation must preserve the reason a check failed")
            }
            XCTAssertTrue(session.state.attempts.isEmpty)
            XCTAssertTrue(session.state.museAppConversations.isEmpty)
            let calls = try fixture.calls()
            XCTAssertEqual(calls.map(\.tool), ["list_apps", "list_windows"])
            assertNoInput(calls)
            session.beginShutdown()
        }
    }

    func testMuseCheckCannotClaimReadyAfterRemovalDisableOrShutdownDuringTheRead() async throws {
        @MainActor final class InstalledApp {
            var installation = DesktopAppInstallation(url: URL(fileURLWithPath: "/Fixture/Muse.app"), processID: 4242)
        }
        for change in ["removal", "disable", "shutdown"] {
            var window = windows()
            window["native"] = try object(museObservation())
            window["wait_for_release"] = true
            let fixture = try driver([apps(.muse), window])
            defer { fixture.remove() }
            let installed = InstalledApp()
            let client = DesktopAppInstallationClient(inspect: { _ in installed.installation }, open: { _ in XCTFail("A check must not launch the app") })
            let session = WebAgentSession(provider: .museApp, storageURL: fixture.directory.appendingPathComponent("state.json"),
                                          fixture: false, museApp: museAdapter(fixture), desktopApps: client, desktopDriver: try readinessDriver(fixture, app: .muse))
            session.setEnabled(true)
            let check = Task { await session.connectDesktopConversation() }
            try await waitForCall("list_windows", in: fixture)
            if change == "removal" { installed.installation = .init(url: nil, processID: nil) }
            else if change == "disable" { session.setEnabled(false) }
            else { session.beginShutdown() }
            try Data().write(to: fixture.directory.appendingPathComponent("release"))
            await check.value
            XCTAssertFalse(session.desktopReady)
            XCTAssertFalse(session.snapshot.ready)
            XCTAssertNil(session.desktopConnectionConfirmation)
            XCTAssertNil(session.state.desktopConversation)
            XCTAssertTrue(session.state.attempts.isEmpty)
            assertNoInput(try fixture.calls())
            session.beginShutdown()
        }
    }

    func testMuseCreatesSideChatVerifiesDraftAndPersistsUUIDBeforeReply() async throws {
        let owner = UUID(), thread = UUID()
        let fixture = try driver(try museCreationSteps(owner: owner, thread: thread, answer: nil))
        defer { fixture.remove() }
        let stateURL = fixture.directory.appendingPathComponent("state.json")
        var saved = WebWorkspaceState()
        saved.enabled = true; saved.desktopConversation = .init(name: "Muse"); saved.comparisonID = owner; saved.draft = prompt
        try JSONEncoder().encode(saved).write(to: stateURL)
        let session = WebAgentSession(provider: .museApp, storageURL: stateURL, fixture: false, museApp: museAdapter(fixture, transientWindowFailure: true), desktopApps: .demo, desktopDriver: try readinessDriver(fixture, app: .muse))
        let sending = Task { await session.send(prompt, comparisonID: owner) }
        try await waitForCall("press_key", in: fixture)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while session.state.museAppConversations[owner.uuidString]?.threadID == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let waiting = try JSONDecoder().decode(WebWorkspaceState.self, from: Data(contentsOf: stateURL))
        XCTAssertEqual(waiting.museAppConversations[owner.uuidString]?.threadID, thread)
        XCTAssertEqual(waiting.attempts.first?.conversationURL, waiting.museAppConversations[owner.uuidString]?.url)
        XCTAssertTrue(session.isSending, "Identity must be durable while the response is still pending")
        let requestID = try XCTUnwrap(waiting.attempts.first?.id)
        let wire = "[msgblast request \(requestID.uuidString.lowercased())]\n\n" + prompt
        try setNative(museObservation(thread: thread, messages: [.init(role: .user, text: wire), .init(role: .assistant, text: "Muse answer")], title: "Renamed by Muse"), in: fixture)
        let sent = await sending.value
        let attempt = try XCTUnwrap(sent)
        XCTAssertEqual(attempt.status, .observed)
        XCTAssertEqual(attempt.conversationURL, waiting.museAppConversations[owner.uuidString]?.url)
        XCTAssertEqual(session.state.localConversations[owner.uuidString]?.map(\.text), [prompt, "Muse answer"])
        XCTAssertEqual(session.state.museAppConversations[owner.uuidString]?.title, "Renamed by Muse")
        XCTAssertTrue(session.state.localSessionIDs.isEmpty)
        let calls = try await finishedCalls(fixture, cleanupCount: 2)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.compactMap { $0.arguments["text"] as? String }, ["[msgblast request \(requestID.uuidString.lowercased())]", prompt])
        XCTAssertEqual(calls.filter { $0.tool == "press_key" && $0.arguments["modifiers"] == nil }.count, 1)
        XCTAssertTrue(calls.filter { $0.tool == "type_text" }.allSatisfy { $0.arguments["element_token"] == nil && $0.arguments["x"] == nil })
        assertMuseBackground(calls)
        session.beginShutdown()
    }

    func testMuseResumeUsesUUIDWhenTitlesDuplicateAndNeverCreatesReplacement() async throws {
        let owner = UUID(), intended = UUID(), other = UUID()
        var first = windows(); first["native"] = try object(museObservation(thread: other))
        let navigation: [String: Any] = ["elements": [
            element("AXHeading", "Side chats"), element("AXButton", "New side chat", token: "s00000001:new"),
            element("AXButton", "Same generated title", token: "s00000001:wrong"),
            element("AXButton", "Same generated title", token: "s00000001:right"), element("AXSplitter", "Resize panel")
        ]]
        let fixture = try driver([
            apps(.muse), first, snapshot(navigation),
            capturedNavigation(navigation), try museStep("click", observation: museObservation(thread: other)),
            snapshot(navigation), capturedNavigation(navigation), try museStep("click", observation: museObservation(thread: intended, title: "Changed title"))
        ])
        defer { fixture.remove() }
        let result = try await museAdapter(fixture).prepare(comparisonID: owner, binding: .init(comparisonID: owner, threadID: intended, title: "Same generated title"))
        XCTAssertEqual(result.threadID, intended)
        XCTAssertEqual(result.title, "Changed title")
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.compactMap { $0.arguments["y"] as? Int }, [105, 165])
        XCTAssertTrue(calls.filter { $0.tool == "click" }.allSatisfy { $0.arguments["element_token"] == nil })
        assertMuseBackground(calls)
    }

    func testMusePartialDraftFocusLossAndChatSwitchPreventReturnWithoutReplay() async throws {
        let owner = UUID(), thread = UUID()
        for fault in ["partial", "focus", "chat"] {
            var initial = windows(); initial["native"] = try object(museObservation(thread: thread))
            var typed = museObservation(thread: fault == "chat" ? UUID() : thread, draft: fault == "partial" ? "Partial" : prompt)
            typed.composerFocused = fault != "focus"
            let fixture = try driver([apps(.muse), initial, try museStep("type_text", observation: typed)])
            defer { fixture.remove() }
            _ = await failure { try await self.museAdapter(fixture).reply(self.prompt, binding: .init(comparisonID: owner, threadID: thread, title: "Title")) { _ in XCTFail("Must not record an unsubmitted draft") } }
            let calls = try await finishedCalls(fixture)
            XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
            XCTAssertFalse(calls.contains { $0.tool == "press_key" })
            assertMuseBackground(calls)
        }
    }

    func testMuseRejectsExternalDraftAndUntrackedNewChatAfterRestart() async throws {
        for draft in ["", "External unsent draft"] {
            var initial = windows(); initial["native"] = try object(museObservation(draft: draft))
            let fixture = try driver([apps(.muse), initial])
            defer { fixture.remove() }
            _ = await failure { try await self.museAdapter(fixture).reply(self.prompt, binding: .init(comparisonID: UUID(), threadID: nil, title: "New side chat")) { _ in XCTFail("No submission") } }
            assertNoInput(try await finishedCalls(fixture))
        }
    }

    func testMuseTimeoutRetainsUUIDAndBlocksOtherComparisonsAcrossRestart() async throws {
        let owner = UUID(), thread = UUID(), other = UUID()
        let fixture = try driver(try museCreationSteps(owner: owner, thread: thread, answer: nil))
        defer { fixture.remove() }
        let stateURL = fixture.directory.appendingPathComponent("state.json")
        var saved = WebWorkspaceState()
        saved.enabled = true; saved.desktopConversation = .init(name: "Muse"); saved.comparisonID = owner; saved.draft = prompt
        try JSONEncoder().encode(saved).write(to: stateURL)
        let session = WebAgentSession(provider: .museApp, storageURL: stateURL, fixture: false, museApp: museAdapter(fixture, timeout: .milliseconds(150)), desktopApps: .demo, desktopDriver: try readinessDriver(fixture, app: .muse))
        let result = await session.send(prompt, comparisonID: owner)
        XCTAssertEqual(result?.status, .uncertain)
        XCTAssertEqual(session.state.museAppConversations[owner.uuidString]?.threadID, thread)
        session.beginShutdown()
        let reopened = WebAgentSession(provider: .museApp, storageURL: stateURL, fixture: false, museApp: museAdapter(fixture), desktopApps: .demo, desktopDriver: try readinessDriver(fixture, app: .muse))
        reopened.updateState { $0.comparisonID = other }
        let blocked = await reopened.send("Other comparison", comparisonID: other)
        XCTAssertNil(blocked)
        reopened.acknowledgeIncompleteRequest()
        XCTAssertTrue(reopened.hasUnresolvedSend(prompt))
        reopened.updateState { $0.comparisonID = owner }
        reopened.acknowledgeIncompleteRequest()
        XCTAssertFalse(reopened.hasUnresolvedSend(prompt))
        XCTAssertEqual(reopened.state.draft, prompt)
        XCTAssertEqual(reopened.state.museAppConversations[owner.uuidString]?.threadID, thread)
        let calls = try await finishedCalls(fixture, cleanupCount: 2)
        XCTAssertEqual(calls.filter { $0.tool == "press_key" && $0.arguments["modifiers"] == nil }.count, 1)
        assertMuseBackground(calls)
        reopened.beginShutdown()
    }

    func testMuseURLBeforeOutgoingSurvivesTimeoutAcknowledgementAndVerifiedRecovery() async throws {
        let owner = UUID(), thread = UUID()
        var plan = try museCreationSteps(owner: owner, thread: thread, answer: nil)
        plan[plan.count - 1]["native"] = try object(museObservation(thread: thread))
        let fixture = try driver(plan)
        defer { fixture.remove() }
        let file = fixture.directory.appendingPathComponent("state.json")
        var saved = WebWorkspaceState()
        saved.enabled = true; saved.desktopConversation = .init(name: "Muse"); saved.comparisonID = owner
        try JSONEncoder().encode(saved).write(to: file)
        let session = WebAgentSession(provider: .museApp, storageURL: file, fixture: false, museApp: museAdapter(fixture, timeout: .milliseconds(150)), desktopApps: .demo, desktopDriver: try readinessDriver(fixture, app: .muse))
        let sent = await session.send(prompt, comparisonID: owner)
        let result = try XCTUnwrap(sent)
        XCTAssertEqual(result.status, .uncertain)
        let candidate = URL(string: "https://muse.ai/thread/\(thread.uuidString)")!
        XCTAssertEqual(result.recoveryConversationURL, candidate)
        XCTAssertNil(result.conversationURL)
        XCTAssertNil(session.state.museAppConversations[owner.uuidString]?.threadID)
        session.beginShutdown()
        let reopened = WebAgentSession(provider: .museApp, storageURL: file, fixture: false, museApp: museAdapter(fixture), desktopApps: .demo, desktopDriver: try readinessDriver(fixture, app: .muse))
        reopened.acknowledgeIncompleteRequest()
        reopened.connect(automaticallyRefresh: false)
        try fixture.replacePlan([apps(.muse), windows()])
        await reopened.refresh()
        XCTAssertFalse(reopened.snapshot.ready, "An address alone cannot establish ownership")
        XCTAssertNil(reopened.state.museAppConversations[owner.uuidString]?.threadID)
        let wire = "[msgblast request \(result.id.uuidString.lowercased())]\n\n" + prompt
        try setNative(museObservation(thread: thread, messages: [.init(role: .user, text: wire), .init(role: .assistant, text: "Late answer")]), in: fixture)
        try fixture.replacePlan([apps(.muse), windows()])
        await reopened.refresh()
        XCTAssertTrue(reopened.snapshot.ready)
        let disk = try JSONDecoder().decode(WebWorkspaceState.self, from: Data(contentsOf: file))
        XCTAssertEqual(disk.museAppConversations[owner.uuidString]?.threadID, thread)
        XCTAssertEqual(disk.attempts.first?.conversationURL, URL(string: "https://muse.ai/thread/\(thread.uuidString.lowercased())"))
        XCTAssertNil(disk.attempts.first?.recoveryConversationURL)
        XCTAssertEqual(disk.attempts.first?.status, .dismissed, "Recovery must not invent a completed reply")
        let calls = try await finishedCalls(fixture, cleanupCount: 4)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1, "Recovery cannot create a replacement")
        XCTAssertEqual(calls.filter { $0.tool == "press_key" && $0.arguments["modifiers"] == nil }.count, 1, "Recovery cannot resend")
        assertMuseBackground(calls)
        reopened.beginShutdown()
    }

    func testMuseOldChatWithSamePromptCannotClaimFirstSubmissionOrRecoverWithoutReference() async throws {
        let owner = UUID(), foreign = UUID()
        var plan = try museCreationSteps(owner: owner, thread: foreign, answer: nil)
        plan[plan.count - 1]["native"] = try object(museObservation(thread: foreign, messages: [
            .init(role: .user, text: prompt), .init(role: .assistant, text: "Old answer")]))
        let fixture = try driver(plan)
        defer { fixture.remove() }
        let file = fixture.directory.appendingPathComponent("state.json")
        var saved = WebWorkspaceState()
        saved.enabled = true; saved.desktopConversation = .init(name: "Muse"); saved.comparisonID = owner
        try JSONEncoder().encode(saved).write(to: file)
        let session = WebAgentSession(provider: .museApp, storageURL: file, fixture: false, museApp: museAdapter(fixture), desktopApps: .demo, desktopDriver: try readinessDriver(fixture, app: .muse))
        let sent = await session.send(prompt, comparisonID: owner)
        let result = try XCTUnwrap(sent)
        XCTAssertEqual(result.status, .uncertain)
        XCTAssertNotNil(result.recoveryConversationURL, "Keep the observed locator even when attribution fails")
        XCTAssertNil(result.conversationURL)
        XCTAssertNil(session.state.museAppConversations[owner.uuidString]?.threadID)
        XCTAssertTrue(session.state.localConversations.isEmpty)
        session.acknowledgeIncompleteRequest()
        try fixture.replacePlan([apps(.muse), windows()])
        await session.refresh()
        XCTAssertFalse(session.snapshot.ready)
        XCTAssertNil(session.state.museAppConversations[owner.uuidString]?.threadID)
        let calls = try await finishedCalls(fixture, cleanupCount: 3)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1)
        XCTAssertEqual(calls.filter { $0.tool == "press_key" && $0.arguments["modifiers"] == nil }.count, 1)
        assertMuseBackground(calls)
        session.beginShutdown()
    }

    func testMuseCancellationStopsInputAndReleasesActorWithoutSendingReturn() async throws {
        let owner = UUID(), thread = UUID()
        var initial = windows(); initial["native"] = try object(museObservation(thread: thread))
        var blocked = try museStep("type_text", observation: museObservation(thread: thread, draft: prompt))
        blocked["wait_for_release"] = true
        let fixture = try driver([apps(.muse), initial, blocked])
        defer { fixture.remove() }
        let adapter = museAdapter(fixture)
        let sending = Task { try await adapter.reply(prompt, binding: .init(comparisonID: owner, threadID: thread, title: "Saved")) { _ in XCTFail("No submission") } }
        try await waitForCall("type_text", in: fixture)
        let collision = await failure { try await adapter.prepare(comparisonID: owner, binding: nil) }
        XCTAssertTrue(collision.contains("already handling"))
        sending.cancel()
        do { _ = try await sending.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        let calls = try await finishedCalls(fixture)
        XCTAssertFalse(calls.contains { $0.tool == "press_key" })
        let call = try XCTUnwrap(calls.first { $0.tool == "type_text" })
        XCTAssertEqual(kill(Int32(call.pid), 0), -1)
        try setNative(museObservation(thread: thread), in: fixture)
        try fixture.replacePlan([apps(.muse), windows()])
        let reopened = try await adapter.prepare(comparisonID: owner, binding: .init(comparisonID: owner, threadID: thread, title: "Saved"))
        XCTAssertEqual(reopened.threadID, thread)
        _ = try await finishedCalls(fixture, cleanupCount: 2)
    }

    func testMuseMissingSavedChatCannotCreateReplacement() async throws {
        let owner = UUID(), other = UUID()
        var initial = windows(); initial["native"] = try object(museObservation(thread: other))
        let list = snapshot(["elements": [element("AXButton", "New side chat", token: "s00000001:new"), element("AXButton", "Another chat", token: "s00000001:other"), element("AXSplitter", "Resize panel")]])
        let capture = capturedNavigation(list["result"] as! [String: Any])
        let click = try museStep("click", observation: museObservation(thread: other))
        let fixture = try driver([apps(.muse), initial, list, capture, click, list, capture, list, capture, click, list, capture])
        defer { fixture.remove() }
        let message = await failure { try await self.museAdapter(fixture).prepare(comparisonID: owner, binding: .init(comparisonID: owner, threadID: UUID(), title: "Missing")) }
        XCTAssertTrue(message.contains("not found"), message)
        let calls = try await finishedCalls(fixture)
        XCTAssertFalse(calls.contains { $0.tool == "type_text" || $0.tool == "press_key" || $0.arguments["element_token"] as? String == "s00000001:new" })
        assertMuseBackground(calls)
    }

    func testMuseChangedChatWhileWaitingCannotReturnForeignAnswer() async throws {
        let owner = UUID(), thread = UUID()
        var initial = windows(); initial["native"] = try object(museObservation(thread: thread))
        let fixture = try driver([apps(.muse), initial,
            try museStep("type_text", observation: museObservation(thread: thread, draft: prompt)),
            try museStep("press_key", observation: museObservation(thread: UUID(), messages: [.init(role: .user, text: prompt), .init(role: .assistant, text: "Foreign reply")]))])
        defer { fixture.remove() }
        let error = await failure { try await self.museAdapter(fixture).reply(self.prompt, binding: .init(comparisonID: owner, threadID: thread, title: "Saved")) { _ in XCTFail("Foreign UUID cannot replace a saved binding") } }
        XCTAssertTrue(error.contains("switched side chats"), error)
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "press_key" }.count, 1)
    }

    func testMuseMultilineDraftUsesShiftReturnAndSubmitsOnlyAfterExactFinalReadback() async throws {
        let owner = UUID(), thread = UUID()
        let multiline = "First line 😀\n\nReply only: MULTILINE"
        var initial = windows(); initial["native"] = try object(museObservation(thread: thread))
        let fixture = try driver([
            apps(.muse), initial,
            try museStep("type_text", observation: museObservation(thread: thread, draft: "First line 😀")),
            try museStep("press_key", observation: museObservation(thread: thread, draft: "First line 😀\n\n")),
            try museStep("press_key", observation: museObservation(thread: thread, draft: "First line 😀\n\n\n")),
            try museStep("type_text", observation: museObservation(thread: thread, draft: multiline)),
            try museStep("press_key", observation: museObservation(thread: thread, messages: [.init(role: .user, text: multiline), .init(role: .assistant, text: "MULTILINE")]))
        ])
        defer { fixture.remove() }
        let answer = try await museAdapter(fixture).reply(multiline, binding: .init(comparisonID: owner, threadID: thread, title: "Saved")) { _ in }
        XCTAssertEqual(answer, "MULTILINE")
        let calls = try await finishedCalls(fixture)
        let keys = calls.filter { $0.tool == "press_key" }
        XCTAssertEqual(keys.count, 3)
        XCTAssertEqual(keys[0].arguments["modifiers"] as? [String], ["shift"])
        XCTAssertEqual(keys[1].arguments["modifiers"] as? [String], ["shift"])
        XCTAssertNil(keys[2].arguments["modifiers"])
        XCTAssertTrue(calls.filter { $0.tool == "type_text" }.allSatisfy { !($0.arguments["text"] as? String ?? "").contains("\n") })
        assertMuseBackground(calls)
    }

    func testMuseFixtureComparisonsKeepIndependentSideChatsAndResumeSavedID() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-muse-demo-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("state.json"), a = UUID(), b = UUID()
        let session = WebAgentSession(provider: .museApp, storageURL: file, fixture: true)
        session.setEnabled(true)
        await session.connectDesktopConversation()
        let first = await session.send("First comparison", comparisonID: a)
        let second = await session.send("Second comparison", comparisonID: b)
        let aid = try XCTUnwrap(session.state.museAppConversations[a.uuidString]?.threadID)
        let bid = try XCTUnwrap(session.state.museAppConversations[b.uuidString]?.threadID)
        XCTAssertNotEqual(aid, bid)
        XCTAssertNotEqual(first?.conversationURL, second?.conversationURL)
        session.beginShutdown()
        let reopened = WebAgentSession(provider: .museApp, storageURL: file, fixture: true)
        let ready = await reopened.openComparison(a)
        XCTAssertTrue(ready)
        let resumed = await reopened.send("Continue first", comparisonID: a)
        XCTAssertEqual(resumed?.conversationURL, first?.conversationURL)
        XCTAssertEqual(reopened.state.museAppConversations[a.uuidString]?.threadID, aid)
        XCTAssertEqual(reopened.state.localConversations[a.uuidString]?.count, 4)
        XCTAssertEqual(reopened.state.localConversations[b.uuidString]?.count, 2)
        XCTAssertTrue(reopened.state.localSessionIDs.isEmpty)
        XCTAssertFalse(WebProvider.museApp.sharesOneConversation)
        reopened.beginShutdown()
    }

    func testMuseRejectsCarriageReturnBeforeAnyDriverInputCanSubmitEarly() async throws {
        let fixture = try driver([])
        defer { fixture.remove() }
        let error = await failure { try await self.museAdapter(fixture).reply("First\rSecond", binding: .init(comparisonID: UUID(), threadID: UUID(), title: "Saved")) { _ in XCTFail("No submission") } }
        XCTAssertTrue(error.contains("control characters"), error)
        XCTAssertTrue(try fixture.calls().isEmpty)
    }

    func testMusePreservesEmojiJoinersAndCombiningMarksInPreparedText() async throws {
        let owner = UUID(), thread = UUID(), text = "Emoji 👩‍💻 and e\u{301}"
        var initial = windows(); initial["native"] = try object(museObservation(thread: thread))
        var typing = try museStep("type_text", observation: museObservation(thread: thread, draft: text))
        typing["arguments"] = ["text": text]
        let fixture = try driver([apps(.muse), initial, typing,
            try museStep("press_key", observation: museObservation(thread: thread, messages: [.init(role: .user, text: text), .init(role: .assistant, text: "Unicode preserved")]))])
        defer { fixture.remove() }
        let answer = try await museAdapter(fixture).reply(text, binding: .init(comparisonID: owner, threadID: thread, title: "Saved")) { _ in }
        XCTAssertEqual(answer, "Unicode preserved")
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        XCTAssertEqual(calls.filter { $0.tool == "press_key" }.count, 1)
        assertMuseBackground(calls)
    }

    func testMuseResumeFocusesCompoundComposerByFreshGeometryWithoutAXPress() async throws {
        let owner = UUID(), thread = UUID()
        var initial = windows(), unfocused = museObservation(thread: thread)
        unfocused.composerFocused = false
        initial["native"] = try object(unfocused)
        var composer = element("AXButton", "Message Attach file Dictate a message Send", token: "s00000001:composer")
        composer["frame"] = ["x": 300, "y": 600, "w": 600, "h": 50]
        let fixture = try driver([apps(.muse), initial, capturedNavigation(["elements": [composer]]),
                                  try museStep("click", observation: museObservation(thread: thread))])
        defer { fixture.remove() }
        let binding = try await museAdapter(fixture).prepare(comparisonID: owner, binding: .init(comparisonID: owner, threadID: thread, title: "Saved"))
        XCTAssertEqual(binding.threadID, thread)
        let calls = try await finishedCalls(fixture)
        let click = try XCTUnwrap(calls.first { $0.tool == "click" })
        XCTAssertEqual(click.arguments["x"] as? Int, 600)
        XCTAssertEqual(click.arguments["y"] as? Int, 788)
        XCTAssertNil(click.arguments["element_token"], "AXPress on this composer opens its file picker")
        let path = try XCTUnwrap(calls.first { $0.tool == "get_window_state" }?.arguments["screenshot_out_file"] as? String)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "Private captures must be removed after use")
        assertMuseBackground(calls)
    }

    func testMuseInvalidMissingOrMismatchedCaptureCannotClickSavedChat() async throws {
        let thread = UUID(), owner = UUID()
        let list: [String: Any] = ["elements": [element("AXButton", "New side chat"), element("AXButton", "Saved"), element("AXSplitter", "Resize panel")]]
        for fault in ["invalid", "missing", "wrong_window", "wrong_dimensions", "wrong_path", "outside", "window_moved", "overflow"] {
            let other = UUID()
            var initial = windows(); initial["native"] = try object(museObservation(thread: other))
            var capture = capturedNavigation(list)
            var result = capture["result"] as! [String: Any]
            if fault == "invalid" { result["screenshot_frame_valid"] = false }
            if fault == "wrong_window" { result["window_id"] = 999 }
            if fault == "wrong_dimensions" { result["screenshot_width"] = 1500 }
            if fault == "outside" {
                var elements = result["elements"] as! [[String: Any]]
                elements[1]["frame"] = ["x": 0, "y": 0, "w": 20, "h": 20]
                result["elements"] = elements
            }
            if fault == "overflow" {
                result["window_bounds"] = ["x": 1e308, "y": 0.0, "width": 1e308, "height": 600.0]
                var elements = result["elements"] as! [[String: Any]]
                elements[1]["frame"] = ["x": 1e308, "y": 10.0, "w": 1e308, "h": 40.0]
                result["elements"] = elements
            }
            capture["result"] = result
            if fault == "missing" { capture["capture"] = "missing" }
            if fault == "wrong_path" { capture["capture"] = "wrong_path" }
            if fault == "window_moved" {
                var moved = museObservation(thread: other); moved.windowBounds = .init(x: 300, y: 100, width: 800, height: 600)
                capture["native"] = try object(moved)
            }
            let fixture = try driver([apps(.muse), initial, snapshot(list), capture])
            defer { fixture.remove() }
            let error = await failure { try await self.museAdapter(fixture).prepare(comparisonID: owner, binding: .init(comparisonID: owner, threadID: thread, title: "Saved")) }
            XCTAssertTrue(error.contains("geometry"), "\(fault): \(error)")
            let calls = try await finishedCalls(fixture)
            XCTAssertFalse(calls.contains { ["click", "type_text", "press_key"].contains($0.tool) })
            let path = try XCTUnwrap(calls.last { $0.tool == "get_window_state" }?.arguments["screenshot_out_file"] as? String)
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
    }

    private func capturedNavigation(_ state: [String: Any]) -> [String: Any] {
        var result = state
        var index = 0
        result["elements"] = (state["elements"] as! [[String: Any]]).map { element in
            var element = element
            if element["role"] as? String == "AXButton", element["label"] as? String != "New side chat", element["frame"] == nil {
                element["frame"] = ["x": 240, "y": 150 + index * 40, "w": 200, "h": 40]
                index += 1
            }
            return element
        }
        result["pid"] = 4242; result["window_id"] = 101
        result["window_bounds"] = ["x": 200, "y": 100, "width": 800, "height": 600]
        result["screenshot_frame_valid"] = true
        result["screenshot_width"] = 1200; result["screenshot_height"] = 900
        result["screenshot_scale"] = 2 // The returned PNG was resized; do not multiply by this.
        var step = snapshot(result)
        step["capture"] = "valid"
        return step
    }

    private func museObservation(thread: UUID? = nil, draft: String = "", messages: [MuseAppMessage] = [], title: String = "Muse side chat") -> MuseAppObservation {
        .init(url: thread.map { URL(string: "https://muse.ai/thread/\($0.uuidString)")! } ?? MuseSideChatBinding.newURL,
              draft: draft, composerFocused: true, messages: messages, windowBounds: .init(x: 200, y: 100, width: 800, height: 600), title: title)
    }
    private func object(_ observation: MuseAppObservation) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(observation)) as! [String: Any]
    }
    private func setNative(_ observation: MuseAppObservation, in fixture: DriverFixture) throws {
        try JSONEncoder().encode(observation).write(to: fixture.directory.appendingPathComponent("native.json"), options: .atomic)
    }
    private func museStep(_ tool: String, observation: MuseAppObservation, token: String? = nil) throws -> [String: Any] {
        var result = step(tool, ["effect": "unverifiable", "delivered_chars": 0], arguments: token.map { ["element_token": $0] } ?? [:])
        result["native"] = try object(observation)
        return result
    }
    private func museCreationSteps(owner: UUID, thread: UUID, answer: String?) throws -> [[String: Any]] {
        var initial = windows()
        var main = museObservation(); main.url = URL(string: "https://muse.ai/")!; main.composerFocused = false
        initial["native"] = try object(main)
        let reference = "[msgblast request <attempt-id>]"
        let wire = reference + "\n\n" + prompt
        var messages = [MuseAppMessage(role: .user, text: wire)]
        if let answer { messages.append(.init(role: .assistant, text: answer)) }
        func input(_ tool: String, draft: String, arguments: [String: Any]) throws -> [String: Any] {
            var step = try museStep(tool, observation: museObservation(draft: draft))
            step["arguments"] = arguments
            return step
        }
        return [apps(.muse), initial,
                snapshot(["elements": [element("AXButton", "New side chat", token: "s00000001:new")]]),
                try museStep("click", observation: museObservation(), token: "s00000001:new"),
                apps(.muse), windows(),
                try input("type_text", draft: reference, arguments: ["text": reference]),
                try input("press_key", draft: reference + "\n\n", arguments: ["key": "return", "modifiers": ["shift"]]),
                try input("press_key", draft: reference + "\n\n\n", arguments: ["key": "return", "modifiers": ["shift"]]),
                try input("type_text", draft: wire, arguments: ["text": prompt]),
                try museStep("press_key", observation: museObservation(thread: thread, messages: messages))]
    }
    private final class MuseReadFault: @unchecked Sendable {
        private let lock = NSLock()
        private var failed = false
        func shouldFail() -> Bool { lock.withLock { if failed { return false }; failed = true; return true } }
    }
    private func museAdapter(_ fixture: DriverFixture, timeout: Duration = .seconds(3), transientWindowFailure: Bool = false) -> MuseAppConversation {
        let fault = MuseReadFault()
        let url = fixture.directory.appendingPathComponent("native.json")
        return MuseAppConversation(executable: fixture.executable, timing: .init(pollInterval: .milliseconds(5), stableDuration: .milliseconds(60), replyTimeout: timeout, callTimeout: 3)) { target in
            guard target.pid == 4242, target.window == 101 else { throw CocoaError(.fileReadUnknown) }
            let observation = try JSONDecoder().decode(MuseAppObservation.self, from: Data(contentsOf: url))
            if transientWindowFailure, observation.url == MuseSideChatBinding.newURL, fault.shouldFail() {
                throw DesktopAppError.unavailable("Muse's exact window is temporarily unavailable")
            }
            return observation
        }
    }
    private func assertMuseBackground(_ calls: [DriverCall], file: StaticString = #filePath, line: UInt = #line) {
        for call in calls where ["click", "type_text", "press_key"].contains(call.tool) {
            XCTAssertEqual(call.arguments["delivery_mode"] as? String, "background", file: file, line: line)
            XCTAssertEqual(call.arguments["pid"] as? Int, 4242, file: file, line: line)
            XCTAssertEqual(call.arguments["window_id"] as? Int, 101, file: file, line: line)
        }
    }

    private func adapter(_ fixture: DriverFixture, replyTimeout: Duration = .seconds(3), callTimeout: TimeInterval = 3) -> DesktopAppConversation {
        let file = fixture.directory.appendingPathComponent("grok-native.json")
        return DesktopAppConversation(executable: fixture.executable, timing: .init(pollInterval: .milliseconds(5), stableDuration: .milliseconds(60), replyTimeout: replyTimeout, callTimeout: callTimeout)) { target in
            guard target.pid == 4242, target.window == 101 else { throw CocoaError(.fileReadUnknown) }
            return try JSONDecoder().decode(GrokBotNativeState.self, from: Data(contentsOf: file))
        }
    }
    private func sendSteps() -> [[String: Any]] {
        [apps(), windows(), snapshot(grok()), step("type_text", [:]), snapshot(grok(draft: prompt, token: "s00000002")), step("click", [:])]
    }
    private func step(_ tool: String, _ result: [String: Any], arguments: [String: String] = [:]) -> [String: Any] {
        ["tool": tool, "result": result, "arguments": arguments]
    }
    private func apps(_ app: DesktopAppProvider = .grokBot) -> [String: Any] {
        step("list_apps", ["apps": [["bundle_id": app.bundleID, "pid": 4242, "running": true]]])
    }
    private func windows() -> [String: Any] {
        step("list_windows", ["windows": [["window_id": 101, "title": "Fixture app", "bounds": ["width": 800, "height": 600]]]])
    }
    private func snapshot(_ result: [String: Any], repeating: Bool = false) -> [String: Any] {
        var step = step("get_window_state", result)
        step["repeat"] = repeating
        if let native = result["_grok_native"] { step["grok_native"] = native }
        return step
    }
    private func element(_ role: String, _ label: String, value: String? = nil, token: String = "s00000001:item") -> [String: Any] {
        var result: [String: Any] = ["role": role, "label": label, "element_token": token, "enabled": true]
        if let value { result["value"] = value }
        return result
    }
    private func wabi(draft: String = "", reply: String? = nil, token: String = "s00000001") -> [String: Any] {
        var body = [element("AXHeading", "Wabi", value: "2"), element("AXStaticText", "Sidebar preview"), element("AXSplitter", "Resize sidebar")]
        if let reply {
            body += [element("AXStaticText", prompt), element("AXPopUpButton", "Add reaction"),
                     element("AXStaticText", "1:41 PM"), element("AXStaticText", "Read"),
                     element("AXStaticText", reply), element("AXPopUpButton", "Add reaction")]
        }
        body += [element("AXTextArea", "Message", value: draft, token: "\(token):composer"), element("AXButton", "Send", token: "\(token):send")]
        return ["elements": body, "returned_element_count": body.count, "total_element_count": body.count]
    }
    private func grok(draft: String = "", reply: String? = nil, name: String = "Fixture Bot", token: String = "s00000001", previousReply: String? = nil, generating: Bool = false, bots: [String]? = nil) -> [String: Any] {
        var list = element("AXList", ""); list["element_index"] = 1
        var body = [list]
        for (index, bot) in (bots ?? [name]).enumerated() {
            var item = element("AXButton", bot, token: "\(token):bot\(index)")
            item["element_index"] = index + 2; item["parent_index"] = 1
            body.append(item)
        }
        var heading = element("AXHeading", name, value: "2"); heading["element_index"] = 100
        var details = element("AXButton", "View conversation details"); details["parent_index"] = 100
        body += [element("AXSplitter", "Resize sidebar"), heading, details]
        if let previousReply {
            body += [element("AXStaticText", "You"), element("AXStaticText", prompt), element("AXStaticText", name), element("AXStaticText", previousReply)]
        }
        if let reply {
            body += [element("AXStaticText", "You"), element("AXStaticText", prompt), element("AXStaticText", name), element("AXStaticText", reply)]
        }
        body += [element("AXTextArea", "Prompt", value: draft, token: "\(token):composer"),
                 element("AXButton", "Send message", token: "\(token):send")]
        if generating { body.append(element("AXButton", "Stop generating")) }
        return ["elements": body, "returned_element_count": body.count, "total_element_count": body.count,
                "_grok_native": ["name": name, "draft": draft]]
    }
    private func failure<T>(_ operation: () async throws -> T) async -> String {
        do { _ = try await operation(); XCTFail("Expected the adapter to refuse this workflow"); return "" }
        catch { return error.localizedDescription }
    }
    private func assertNoInput(_ calls: [DriverCall], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(calls.allSatisfy { ["list_apps", "list_windows", "get_window_state", "end_session"].contains($0.tool) }, "Unexpected driver mutation: \(calls.map(\.tool))", file: file, line: line)
    }
    private func assertBackgroundTargets(_ calls: [DriverCall], file: StaticString = #filePath, line: UInt = #line) {
        for call in calls where ["type_text", "click", "press_key"].contains(call.tool) {
            XCTAssertEqual(call.arguments["pid"] as? Int, 4242, file: file, line: line)
            XCTAssertEqual(call.arguments["window_id"] as? Int, 101, file: file, line: line)
            XCTAssertEqual(call.arguments["delivery_mode"] as? String, "background", file: file, line: line)
        }
        XCTAssertEqual(Set(calls.compactMap { $0.arguments["session"] as? String }).count, 1, file: file, line: line)
    }
    private func waitForCall(_ tool: String, in fixture: DriverFixture) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if try fixture.calls().contains(where: { $0.tool == tool }) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Fake driver did not reach \(tool)")
        throw CocoaError(.fileReadUnknown)
    }
    private func finishedCalls(_ fixture: DriverFixture, cleanupCount: Int = 1) async throws -> [DriverCall] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            let calls = try fixture.calls()
            if calls.filter({ $0.tool == "end_session" }).count >= cleanupCount { return calls }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Driver lifecycle session was not cleaned up")
        return try fixture.calls()
    }
    private struct DriverCall {
        let tool: String
        let arguments: [String: Any]
        let pid: Int
    }
    private struct DriverFixture: Sendable {
        let directory: URL
        var executable: URL { directory.appendingPathComponent("cua-driver") }
        func remove() { try? FileManager.default.removeItem(at: directory) }
        func replacePlan(_ steps: [[String: Any]]) throws {
            try JSONSerialization.data(withJSONObject: steps).write(to: directory.appendingPathComponent("plan.json"), options: .atomic)
            try Data("0".utf8).write(to: directory.appendingPathComponent("index"), options: .atomic)
        }
        func calls() throws -> [DriverCall] {
            let url = directory.appendingPathComponent("calls.jsonl")
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
                let value = try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
                return DriverCall(tool: value["tool"] as! String, arguments: value["arguments"] as! [String: Any], pid: value["pid"] as! Int)
            }
        }
    }
    private func readinessDriver(_ fixture: DriverFixture, app: DesktopAppProvider) throws -> DesktopAppConversation {
        // Session window readiness is separate from the adapter's ordered action plan.
        let executable = fixture.directory.appendingPathComponent("readiness-driver")
        try Data("""
        #!/usr/bin/env python3
        import json,sys,time
        assert len(sys.argv)==4 and sys.argv[1]=='call'
        tool=sys.argv[2];args=json.loads(sys.argv[3])
        if tool=='list_apps':
            assert args=={}
            print(json.dumps({'apps':[{'bundle_id':'\(app.bundleID)','pid':42,'running':True}]}))
        elif tool=='list_windows':
            assert args=={'pid':42}
            print(json.dumps({'windows':[{'window_id':101,'title':'Fixture app','is_on_screen':True,'bounds':{'width':800,'height':600}}]}))
        else: raise AssertionError('Unexpected readiness action: '+tool)
        sys.stdout.flush();time.sleep(.02)
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return DesktopAppConversation(executable: executable)
    }
    private func driver(_ steps: [[String: Any]]) throws -> DriverFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-driver-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let fixture = DriverFixture(directory: directory)
        try fixture.replacePlan(steps)
        try Data(Self.driverScript.utf8).write(to: fixture.executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.executable.path)
        return fixture
    }
    private static let driverScript = #"""
    #!/usr/bin/env python3
    import fcntl, json, os, pathlib, struct, sys, time, zlib
    root = pathlib.Path(__file__).parent
    if len(sys.argv) != 4 or sys.argv[1] != "call":
        raise SystemExit(90)
    tool, arguments = sys.argv[2], json.loads(sys.argv[3])
    with (root / "lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with (root / "calls.jsonl").open("a") as log:
            log.write(json.dumps({"tool": tool, "arguments": arguments, "pid": os.getpid()}) + "\n")
        if tool == "end_session":
            print(json.dumps({"active": False}))
            raise SystemExit(0)
        index = int((root / "index").read_text())
        plan = json.loads((root / "plan.json").read_text())
        expected = plan[index] if index < len(plan) else {}
        if "<attempt-id>" in json.dumps(expected):
            # The real session durably creates the request ID before driver input.
            request_id = json.loads((root / "state.json").read_text())["attempts"][0]["id"].lower()
            expected = json.loads(json.dumps(expected).replace("<attempt-id>", request_id))
        if expected.get("tool") != tool or any(arguments.get(k) != v for k, v in expected.get("arguments", {}).items()):
            print(json.dumps({"isError": True, "message": "Unexpected fake-driver call"}))
            raise SystemExit(91)
        if "native" in expected:
            (root / "native.json").write_text(json.dumps(expected["native"]))
        if "grok_native" in expected:
            (root / "grok-native.json").write_text(json.dumps(expected["grok_native"]))
        if expected.get("remove_grok_native"):
            (root / "grok-native.json").unlink(missing_ok=True)
        if not expected.get("repeat"):
            (root / "index").write_text(str(index + 1))
    if expected.get("wait_for_release"):
        deadline = time.monotonic() + 30
        while not (root / "release").exists() and time.monotonic() < deadline:
            time.sleep(0.01)
    result = expected["result"]
    if "capture" in expected:
        capture_path = pathlib.Path(arguments["screenshot_out_file"])
        result["screenshot_file_path"] = str(capture_path.resolve() if expected["capture"] != "wrong_path" else capture_path.parent / "other.png")
        if expected["capture"] != "missing":
            width, height = 1200, 900
            def chunk(kind, data):
                body = kind + data
                return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xffffffff)
            pixels = (b"\x00" + b"\xff\xff\xff" * width) * height
            png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b"")
            capture_path.write_bytes(png)
    print(json.dumps(result))
    """#
}
