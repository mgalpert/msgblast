import XCTest
@testable import msgblastCore

final class GPTLiveContextTests: XCTestCase {
    func testEncodedBudgetHandlesUnicodeAndEscaping() throws {
        for unit in ["🙂", "日本語", "\u{0001}", "\"/\\\n"] {
            let context = GPTLiveConversationContext(comparisonID: "selected", question: String(repeating: unit, count: 4000), recipients: [
                .init(id: "a", name: "A", messages: [.init(role: "assistant", text: String(repeating: unit, count: 24000) + "latest")])
            ])
            XCTAssertTrue(context.historyTruncated)
            XCTAssertTrue(context.recipients[0].messages[0].text.hasSuffix("latest"))
            XCTAssertLessThan(try context.json().utf8.count, 56000)
        }
    }
    func testContextRetainsAllRecipientsAndLatestHistoryWithinBudget() throws {
        let context = GPTLiveConversationContext(comparisonID: "selected", question: "Question", recipients: [
            .init(id: "a", name: "A", messages: [.init(role: "user", text: String(repeating: "x", count: 14000)), .init(role: "assistant", text: "latest")]),
            .init(id: "b", name: "B", messages: [.init(role: "assistant", text: "B answer")])
        ])
        XCTAssertTrue(context.historyTruncated)
        XCTAssertEqual(context.recipients.count, 2)
        XCTAssertEqual(context.recipients[0].messages.last?.text, "latest")
        XCTAssertEqual(context.recipients[1].messages.last?.text, "B answer")
        XCTAssertLessThanOrEqual(context.recipients[0].messages.reduce(0) { $0 + $1.text.count }, 12000)
        XCTAssertFalse(context.attachmentContentsIncluded)
        XCTAssertTrue(try context.json().contains("selected"))
    }
    func testDraftRejectsUnknownDuplicateEmptyAndOversizedInput() throws {
        for ids in [["stranger"], ["a", "a"], []] {
            XCTAssertThrowsError(try GPTLiveDraft.validated(comparisonID: nil, recipientIDs: ids, text: "Hi", allowedRecipientIDs: ["a"]))
        }
        for text in ["  ", String(repeating: "x", count: 8001)] {
            XCTAssertThrowsError(try GPTLiveDraft.validated(comparisonID: nil, recipientIDs: ["a"], text: text, allowedRecipientIDs: ["a"]))
        }
    }
    func testDraftPinsMultipleRecipientsAndProtectsHumanEdits() throws {
        let id = UUID()
        var draft = try GPTLiveDraft.validated(comparisonID: id, recipientIDs: ["a", "b"], text: "Hello 👋\nSecond line", allowedRecipientIDs: ["a", "b"])
        XCTAssertEqual(draft.comparisonID, id)
        XCTAssertEqual(draft.recipientIDs, ["a", "b"])
        XCTAssertEqual(draft.text, "Hello 👋\nSecond line")
        try draft.edit("Revised", expectedRevision: 0)
        XCTAssertEqual(draft.revision, 1)
        XCTAssertThrowsError(try draft.edit("Stale", expectedRevision: 0))
        XCTAssertEqual(draft.text, "Revised")
        XCTAssertNil(try GPTLiveDraft.validated(comparisonID: nil, recipientIDs: ["a"], text: "New", allowedRecipientIDs: ["a"]).comparisonID)
    }
}
