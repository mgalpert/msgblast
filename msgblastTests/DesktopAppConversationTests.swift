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
        let reopened = WebAgentSession(provider: .wabi, storageURL: directory.appendingPathComponent("wabi.json"), fixture: true)
        XCTAssertEqual(reopened.state.desktopConversation?.name, "Wabi")
        XCTAssertEqual(reopened.state.localConversations[comparison.uuidString], session.snapshot.messages)
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

    func testWabiUsesOnlyItsAIConversationAndFreshSendControl() async throws {
        let fixture = try driver([
            apps(.wabi), windows(), snapshot(wabi()),
            step("type_text", ["effect": "unverifiable"], arguments: ["element_token": "s00000001:composer"]),
            snapshot(wabi(draft: prompt, token: "s00000002")),
            step("click", [:], arguments: ["element_token": "s00000002:send"]),
            snapshot(wabi(reply: "Wabi fixture answer", token: "s00000003"), repeating: true)
        ])
        defer { fixture.remove() }
        let answer = try await adapter(fixture).reply(prompt, app: .wabi, binding: .init(name: "Wabi"))
        XCTAssertEqual(answer, "Wabi fixture answer")
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1)
        assertBackgroundTargets(calls)
        var human = wabi()
        var elements = try XCTUnwrap(human["elements"] as? [[String: Any]])
        elements[0]["label"] = "A human contact"
        human["elements"] = elements
        let denied = try driver([apps(.wabi), windows(), snapshot(human)])
        defer { denied.remove() }
        let error = await failure { try await self.adapter(denied).reply(self.prompt, app: .wabi, binding: .init(name: "Wabi")) }
        XCTAssertTrue(error.contains("Human conversations are not supported"), error)
        assertNoInput(try await finishedCalls(denied))
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

    func testExternalDraftAndWrongConversationPreventAllInput() async throws {
        for (state, reason) in [(grok(draft: "Keep this external draft"), "unsent draft"),
                                (grok(name: "Other Bot"), "conversation changed")] {
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
            let fixture = try driver([apps(), windows(), snapshot(grok()), step("type_text", [:]), snapshot(["elements": variant])])
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
        let inspected = try await conversation.inspect(.grokBot)
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
            _ = await failure { try await self.adapter(fixture).inspect(.muse) }
            assertNoInput(try await finishedCalls(fixture))
        }
    }

    private func adapter(_ fixture: DriverFixture, replyTimeout: Duration = .seconds(3), callTimeout: TimeInterval = 3) -> DesktopAppConversation {
        DesktopAppConversation(executable: fixture.executable, timing: .init(pollInterval: .milliseconds(5), stableDuration: .milliseconds(60), replyTimeout: replyTimeout, callTimeout: callTimeout))
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
        var result = step("get_window_state", result); result["repeat"] = repeating; return result
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
    private func grok(draft: String = "", reply: String? = nil, name: String = "Fixture Bot", token: String = "s00000001", previousReply: String? = nil, generating: Bool = false) -> [String: Any] {
        var body = [element("AXHeading", name, value: "2"), element("AXSplitter", "Resize sidebar")]
        if let previousReply {
            body += [element("AXStaticText", "You"), element("AXStaticText", prompt), element("AXStaticText", name), element("AXStaticText", previousReply)]
        }
        if let reply {
            body += [element("AXStaticText", "You"), element("AXStaticText", prompt), element("AXStaticText", name), element("AXStaticText", reply)]
        }
        body += [element("AXTextArea", "Prompt", value: draft, token: "\(token):composer"),
                 element("AXButton", "Send message", token: "\(token):send")]
        if generating { body.append(element("AXButton", "Stop generating")) }
        return ["elements": body, "returned_element_count": body.count, "total_element_count": body.count]
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
    import fcntl, json, os, pathlib, sys, time
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
        if expected.get("tool") != tool or any(arguments.get(k) != v for k, v in expected.get("arguments", {}).items()):
            print(json.dumps({"isError": True, "message": "Unexpected fake-driver call"}))
            raise SystemExit(91)
        if not expected.get("repeat"):
            (root / "index").write_text(str(index + 1))
    if expected.get("wait_for_release"):
        deadline = time.monotonic() + 30
        while not (root / "release").exists() and time.monotonic() < deadline:
            time.sleep(0.01)
    print(json.dumps(expected["result"]))
    """#
}
