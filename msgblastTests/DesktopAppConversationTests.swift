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
