import XCTest
import AppKit
@testable import msgblastCore

final class MessagesSendScriptTests: XCTestCase {
    private let handle = "urn:biz:00000000-0000-0000-0000-000000000123"
    private var business: Chat {
        Chat(id: "iMessage;-;" + handle, handle: handle, lastActivity: 0, displayName: "Poke", businessConversation: true)
    }
    func testBusinessAliasTargetsExactlyOneExistingChatWithoutAContactAddress() throws {
        let source = try MessagesSendScript.text("fixture", to: business)
        XCTAssertTrue(source.contains("set targetChat to chat id \"any;-;" + handle + "\""))
        XCTAssertTrue(source.contains("if (id of targetChat as text) is not \"any;-;" + handle + "\""))
        XCTAssertTrue(source.contains("if (handle of item 1 of participants of targetChat as text) is not \"" + handle + "\""))
        XCTAssertTrue(source.contains("if (count of participants of targetChat) is not 1"))
        XCTAssertTrue(source.contains("if service type of account of targetChat is not iMessage"))
        XCTAssertEqual(source.components(separatedBy: "send \"fixture\" to targetChat").count - 1, 1)
        XCTAssertFalse(source.contains("make new"))
        XCTAssertFalse(source.contains("+1555"))
    }
    func testEmojiReachTheScriptUnchanged() throws {
        let chat = Chat(id: "any;-;person@example.com", handle: "person@example.com", lastActivity: 0)
        for text in ["👩‍👩‍👧‍👦", "👍🏽 thanks", "🇵🇹🇮🇹", "❤️❤️❤️", "Café ☕️ e cappuccino", "🫶🏾✨"] {
            let source = try MessagesSendScript.text(text, to: chat)
            XCTAssertTrue(source.contains("send \"\(text)\" to targetChat"), "No normalization or escaping of \(text)")
        }
    }
    func testOrdinaryIMessageUsesItsSavedGUIDAndSameParticipantChecks() throws {
        let chat = Chat(id: "any;-;person@example.com", handle: "person@example.com", lastActivity: 0)
        let source = try MessagesSendScript.text("ordinary", to: chat)
        XCTAssertTrue(source.contains("chat id \"any;-;person@example.com\""))
        XCTAssertTrue(source.contains("is not \"person@example.com\""))
        XCTAssertFalse(source.contains("urn:biz:"))
    }
    func testPreflightHasAllDestinationChecksAndNoSubmissionCommand() throws {
        let preflight = try MessagesSendScript.preflight(to: business)
        XCTAssertTrue(preflight.contains("return \"READY\""))
        XCTAssertFalse(preflight.contains("send "))
        XCTAssertFalse(preflight.contains("set submissionAttempted to true"))
        let missing = Chat(id: "any;-;urn:biz:00000000-0000-0000-0000-000000000999", handle: "urn:biz:00000000-0000-0000-0000-000000000999", lastActivity: 0, businessConversation: true)
        XCTAssertTrue(try MessagesSendScript.preflight(to: missing).contains("NOT_SUBMITTED:"))
    }
    func testUnsupportedBusinessIdentityGroupsAndSMSNeverGenerateASend() {
        var group = business; group.participantCount = 2
        var sms = business; sms.service = "SMS"
        var unknown = business; unknown.businessConversation = nil
        var wrong = business; wrong.id = "any;+;different-group"
        var invalid = business; invalid.handle = "urn:biz:not-a-uuid"
        for chat in [group, sms, unknown, wrong, invalid] {
            XCTAssertThrowsError(try MessagesSendScript.text("never send", to: chat))
            XCTAssertThrowsError(try MessagesSendScript.attachment(path: "/tmp/fixture.png", to: chat))
        }
    }
    @MainActor
    func testTextAttachmentAndReadOnlyScriptsCompileWithEscapedContentWithoutExecuting() throws {
        let sources = [
            try MessagesSendScript.preflight(to: business),
            try MessagesSendScript.text("quotes \" and \\ slashes\nnext line\rreturn", to: business),
            try MessagesSendScript.attachment(path: "/tmp/fixture \"quote\" \\backslash.png", to: business)
        ]
        for source in sources {
            var error: NSDictionary?
            let script = try XCTUnwrap(NSAppleScript(source: source))
            XCTAssertTrue(script.compileAndReturnError(&error), "Compile-only check failed: \(error?.description ?? "unknown")")
        }
    }
    func testErrorsBeforeSubmissionAreDistinguishedFromUncertainSendFailures() throws {
        let source = try MessagesSendScript.text("fixture", to: business)
        let attempted = try XCTUnwrap(source.range(of: "set submissionAttempted to true"))
        let send = try XCTUnwrap(source.range(of: "send \"fixture\" to targetChat"))
        let check = try XCTUnwrap(source.range(of: "The destination participant changed."))
        XCTAssertLessThan(check.lowerBound, attempted.lowerBound)
        XCTAssertLessThan(attempted.lowerBound, send.lowerBound)
        XCTAssertTrue(source.contains("if submissionAttempted then return \"UNCERTAIN:\""))
        XCTAssertTrue(source.contains("return \"NOT_SUBMITTED:\""))
    }
}
