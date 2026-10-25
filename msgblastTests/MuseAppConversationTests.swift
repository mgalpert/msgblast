import XCTest
@testable import msgblastCore

final class MuseAppConversationTests: XCTestCase {
    func testAssistantLiteralYouLabelCannotBecomeAnOutgoingMessage() throws {
        let reply = MuseAXNode(role: "AXGroup", children: [
            .init(role: "AXGroup", children: [.init(role: "AXStaticText", value: "You:"), .init(role: "AXPopUpButton", label: "React")])
        ])
        XCTAssertEqual(try MuseTranscript.messages(in: .init(role: "AXGroup", label: "Chat messages", children: [reply])),
                       [.init(role: .assistant, text: "You:")])
        let streaming = MuseAXNode(role: "AXGroup", children: [.init(role: "AXGroup", children: [.init(role: "AXStaticText", value: "You:")])])
        XCTAssertEqual(try MuseTranscript.messages(in: .init(role: "AXGroup", label: "Chat messages", children: [streaming])), [])
    }
    func testEmptyCompoundComposerCannotBeConfusedWithLiteralMessageDraft() throws {
        let placeholder = "Message" + String(repeating: "\n", count: 6)
        XCTAssertEqual(try MuseComposerText.read(markerText: { "Message" + String(repeating: "\n", count: 5) }) { range in
            range.length == 7 ? "Message" : range.length == 8 ? placeholder : nil
        }, "")
        let literal = "Message" as NSString
        XCTAssertEqual(try MuseComposerText.read(markerText: { "" }) { range in
            range.length <= literal.length ? literal.substring(with: range) : ""
        }, "Message")
        XCTAssertThrowsError(try MuseComposerText.read(markerText: { placeholder }) { _ in "Message" })
        XCTAssertThrowsError(try MuseComposerText.read(markerText: { nil }) { _ in "" })
    }

    func testBindingsSurviveRestartAndCannotTransferOrReplaceChatIdentity() throws {
        let a = UUID(), b = UUID(), thread = UUID()
        var state = WebWorkspaceState()
        try state.recordMuseAppBinding(.init(comparisonID: a, threadID: nil, title: "New"))
        try state.recordMuseAppBinding(.init(comparisonID: a, threadID: thread, title: "Generated"))
        try state.recordMuseAppBinding(.init(comparisonID: a, threadID: thread, title: "Renamed"))
        XCTAssertThrowsError(try state.recordMuseAppBinding(.init(comparisonID: a, threadID: UUID(), title: "Other")))
        XCTAssertThrowsError(try state.recordMuseAppBinding(.init(comparisonID: a, threadID: nil, title: "Lost")))
        XCTAssertThrowsError(try state.recordMuseAppBinding(.init(comparisonID: b, threadID: thread, title: "Duplicate title")))
        let reopened = try JSONDecoder().decode(WebWorkspaceState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(try reopened.museAppBinding(for: a)?.threadID, thread)
        XCTAssertEqual(try reopened.museAppBinding(for: a)?.title, "Renamed")
        XCTAssertTrue(reopened.localSessionIDs.isEmpty)
        state.museAppConversations[b.uuidString] = .init(comparisonID: a, threadID: UUID(), title: "Wrong owner")
        XCTAssertThrowsError(try state.museAppBinding(for: a))
    }
    func testTextRangeReaderPreservesFullUnicodeDraftAndWhitespace() throws {
        for text in ["", "Message", "first line\n\n😀 café שלום 日本語\n", String(repeating: "long draft ", count: 500)] {
            let input = text as NSString
            let result = try MuseTextRange.read { range in
                range.location + range.length <= input.length ? input.substring(with: range) : ""
            }
            XCTAssertEqual(result, text)
            let characters = Array(text)
            XCTAssertEqual(try MuseTextRange.read { range in
                range.length <= characters.count ? String(characters.prefix(range.length)) : ""
            }, text, "Muse's visible-character ranges must retain full Unicode text")
        }
    }

    func testTextRangeReaderRefusesUnreadableChangingAndOversizedDrafts() {
        XCTAssertThrowsError(try MuseTextRange.read { _ in nil })
        XCTAssertThrowsError(try MuseTextRange.read(maximumUTF16: 8) { range in
            range.length <= 9 ? String(repeating: "x", count: range.length) : ""
        })
        var completeReads = 0
        XCTAssertThrowsError(try MuseTextRange.read { range in
            if range.length == 3 { completeReads += 1; return completeReads > 1 ? "new" : "old" }
            return range.length <= 3 ? String("old".prefix(range.length)) : ""
        })
    }

    func testSideChatIdentityRejectsMainNewAndForeignURLs() throws {
        let id = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        XCTAssertEqual(MuseSideChatBinding.threadID(in: URL(string: "https://muse.ai/thread/\(id.uuidString)")!), id)
        for url in ["https://muse.ai/", "https://muse.ai/thread/new", "https://other.example/thread/\(id)", "https://muse.ai/thread/\(id)?other=1", "http://muse.ai/thread/\(id)"] {
            XCTAssertNil(MuseSideChatBinding.threadID(in: URL(string: url)!))
        }
        let owner = UUID()
        let binding = MuseSideChatBinding(comparisonID: owner, threadID: id, title: "Generated title")
        let reopened = try JSONDecoder().decode(MuseSideChatBinding.self, from: JSONEncoder().encode(binding))
        XCTAssertEqual(reopened.comparisonID, owner)
        XCTAssertEqual(reopened.threadID, id)
    }

    func testReceiptUsesNewOutgoingOccurrenceAndSpeakerNotTitleOrEchoedText() throws {
        let baseline: [MuseAppMessage] = [.init(role: .user, text: "Echo"), .init(role: .assistant, text: "Old reply")]
        let receipt = MuseAppReceipt(baseline: baseline, prompt: "Echo")
        XCTAssertNil(try receipt.reply(in: baseline))
        XCTAssertEqual(try receipt.reply(in: baseline + [.init(role: .user, text: "Echo"), .init(role: .assistant, text: "Echo")]), "Echo")
        XCTAssertThrowsError(try receipt.reply(in: [.init(role: .user, text: "Changed history")]))
        XCTAssertThrowsError(try receipt.reply(in: baseline + [.init(role: .user, text: "Someone else's prompt"), .init(role: .assistant, text: "Wrong reply")]))
        XCTAssertThrowsError(try receipt.reply(in: baseline + [.init(role: .user, text: "Echo"), .init(role: .assistant, text: "Partial"), .init(role: .user, text: "Another request")]))
    }

    func testMultilineUnicodeAXMessagesProduceTheExactSubmissionAndReply() throws {
        let prompt = "[msgblast request 11111111-2222-4333-8444-555555555555]\n\nFirst line\n\n😀 café 日本語"
        let root = MuseAXNode(role: "AXGroup", label: "Chat messages", children: [
            .init(role: "AXGroup", children: [.init(role: "AXStaticText", value: "2:45 PM")]),
            .init(role: "AXGroup", children: [.init(role: "AXStaticText", value: "You:"),
                .init(role: "AXGroup", children: [.init(role: "AXStaticText", value: prompt)])]),
            .init(role: "AXGroup", children: [.init(role: "AXGroup", children: [
                .init(role: "AXStaticText", value: "First paragraph\nSecond line"),
                .init(role: "AXStaticText", value: "😀 日本語"), .init(role: "AXPopUpButton", label: "React")])])
        ])
        let messages = try MuseTranscript.messages(in: root)
        XCTAssertEqual(messages.first, .init(role: .user, text: prompt))
        XCTAssertEqual(try MuseAppReceipt(baseline: [], prompt: prompt).reply(in: messages), "First paragraph\nSecond line\n\n😀 日本語")
    }

    func testTranscriptSeparatesMessageGroupsFromTimestampsAndActionLabels() throws {
        let root = MuseAXNode(role: "AXGroup", label: "Chat messages", children: [
            .init(role: "AXGroup", children: [.init(role: "AXStaticText", value: "1:41 PM")]),
            .init(role: "AXGroup", children: [.init(role: "AXStaticText", value: "You:"), .init(role: "AXGroup", children: [.init(role: "AXStaticText", value: "Question")])]),
            .init(role: "AXGroup", children: [.init(role: "AXPopUpButton", label: "More options"), .init(role: "AXButton", label: "Copy response"), .init(role: "AXButton", label: "Reply")]),
            .init(role: "AXGroup", children: [.init(role: "AXGroup", children: [.init(role: "AXStaticText", value: "1:41 PM"), .init(role: "AXPopUpButton", label: "React"), .init(role: "AXButton", label: "Reply"), .init(role: "AXButton", label: "Copy response")])])
        ])
        XCTAssertEqual(try MuseTranscript.messages(in: root), [.init(role: .user, text: "Question"), .init(role: .assistant, text: "1:41 PM")])
    }
}
