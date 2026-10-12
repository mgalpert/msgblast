import Foundation
import XCTest
@testable import msgblastCore

final class ComparisonPublicationTests: XCTestCase {
    private func fixture() throws -> PerformanceUploadChunk {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(PerformanceUploadChunk.self, from: Data(contentsOf: root.appendingPathComponent("docs/performance/sample-upload-request-groups-v1.json")))
    }
    private let agent = PerformanceAgent(id: "contact@example.com", name: "Alice", connection: .website)
    private func event(_ kind: PerformanceEventKind, _ sequence: Int, turn: String? = "t", scope: PerformanceScope? = .shared, message: String? = nil, text: String? = nil, group: String? = "action", targets: [String]? = nil) -> PerformanceEvent {
        .init(sequence: sequence, comparisonID: "c", segmentID: "s", kind: kind,
              stamp: .init(clockID: "clock", monotonicMS: Int64(sequence * 100), wallMS: 1700000000000 + Int64(sequence * 100)), fixture: true,
              agent: agent, turnID: turn, turnPosition: kind == .turnStarted ? 0 : nil,
              requestGroupID: kind == .turnStarted ? group : nil, targetAgentIDs: kind == .turnStarted ? targets : nil,
              scope: scope, messageID: message, text: text)
    }
    func testManualRedactionOnlyMasksLiteralCapturedText() throws {
        let source = [event(.turnStarted, 1, text: "Keep secret\n  indentation."), event(.replyObserved, 2, message: "reply", text: "Literal .* secret\n\nUnchanged answer.")]
        let originalBytes = try PerformanceCanonical.bytes(source)
        var publication = try ComparisonPublicationBuilder.build(events: source, comparisonID: "c")
        publication.redactLiteral("secret")
        XCTAssertEqual(publication.turns[0].prompt, "Keep [redacted]\n  indentation.")
        XCTAssertEqual(publication.turns[0].replies[0].messages[0].text, "Literal .* [redacted]\n\nUnchanged answer.")
        publication.redactLiteral(".*")
        XCTAssertEqual(publication.turns[0].replies[0].messages[0].text, "Literal [redacted] [redacted]\n\nUnchanged answer.")
        let masked = try publication.previewBytes(); publication.redactLiteral("")
        XCTAssertEqual(try publication.previewBytes(), masked)
        XCTAssertEqual(try PerformanceCanonical.bytes(source), originalBytes)
    }
    func testNativeRequestFixturePreservesActionsDespitePrivateInterleaveAndRepeatedText() throws {
        let chunk = try fixture(), originals = try PerformanceCanonical.bytes(chunk.events)
        let p = try ComparisonPublicationBuilder.build(events: chunk.events, comparisonID: chunk.sessionID)
        XCTAssertEqual(p.turns.count, 2)
        // Independently canonicalized with Python json + hashlib from the native fixture.
        XCTAssertEqual(try p.previewHash(), "90e0ab4c01810bdc08bf4fd5ec3d6ffaad70667a503ee35b21ac2d804ed01f7e")
        XCTAssertEqual(p.turns.map(\.kind), ["initial", "followUp"])
        XCTAssertEqual(p.turns.map { $0.replies.count }, [4, 4])
        XCTAssertEqual(p.turns[0].prompt, p.turns[1].prompt)
        XCTAssertEqual(p.participants.map(\.label), ["Agent 1", "Agent 2", "Agent 3", "Agent 4"])
        XCTAssertTrue(p.omissions.contains { $0.contains("3 private") })
        XCTAssertTrue(p.omissions.contains { $0.contains("1 unknown") })
        XCTAssertFalse(String(decoding: try p.previewBytes(), as: UTF8.self).contains("web-a"))
        XCTAssertEqual(try PerformanceCanonical.bytes(chunk.events), originals)
        var options = ComparisonPublicationOptions(); options.includePrivate = true; options.includeUnknownScope = true
        let all = try ComparisonPublicationBuilder.build(events: chunk.events, comparisonID: chunk.sessionID, options: options)
        XCTAssertEqual(all.turns.count, 5)
        XCTAssertEqual(all.turns[1].scope, .private)
        XCTAssertEqual(all.turns[1].targetedAgentIDs?.count, 1)
        XCTAssertEqual(all.turns.last?.scope, .unknown)
        XCTAssertEqual(all.turns.last?.kind, "unknown")
        XCTAssertEqual(all.includesUnknown, true)
    }
    func testDistinctRepliesLatestStreamingFeedbackAndOptionalRevisions() throws {
        var events = [event(.turnStarted, 1, text: "Explain"), event(.dispatched, 2),
            event(.replyObserved, 3, message: "dom-secret-1", text: "Acknowledged"),
            event(.replyObserved, 4, message: "dom-secret-2", text: "part"),
            event(.feedback, 5, turn: nil, message: "dom-secret-2"),
            event(.replyObserved, 6, message: "dom-secret-2", text: "<script>alert(1)</script>\n    answer"),
            event(.replyObserved, 7, message: "dom-secret-3", text: "Extra"),
            event(.feedback, 8, turn: nil, message: "dom-secret-2")]
        events[4].selection = .favorite; events[7].selection = .negative
        let original = events
        let p = try ComparisonPublicationBuilder.build(events: events, comparisonID: "c")
        let messages = p.turns[0].replies[0].messages
        XCTAssertEqual(messages.map(\.text), ["Acknowledged", "<script>alert(1)</script>\n    answer", "Extra"])
        XCTAssertEqual(messages[1].feedback, .negative)
        XCTAssertEqual(messages[0].timingLabel, "Dispatch to observed reply: 0.1 s")
        XCTAssertEqual(messages[1].timingLabel, "Previous reply to observed reply: 0.1 s")
        XCTAssertNil(messages[1].revisions)
        XCTAssertTrue(p.omissions.contains { $0.contains("1 earlier streaming") })
        var options = ComparisonPublicationOptions(); options.includesStreamingRevisions = true
        var withRevisions = try ComparisonPublicationBuilder.build(events: events, comparisonID: "c", options: options)
        XCTAssertEqual(withRevisions.turns[0].replies[0].messages[1].revisions?.map(\.text), ["part"])
        withRevisions.redactText { $0.replacingOccurrences(of: "part", with: "manual") }
        XCTAssertEqual(withRevisions.turns[0].replies[0].messages[1].revisions?.first?.text, "manual")
        XCTAssertEqual(events, original)
    }
    func testAnonymousRedactionPreservesIndentationAndDoesNotMutateOriginal() throws {
        let raw = "Alice contact@example.com @alice /Users/alice/private.txt 2026-10-12\n    return 1"
        let events = [event(.turnStarted, 1, text: raw), event(.replyObserved, 2, message: "private-dom-id", text: raw)]
        let p = try ComparisonPublicationBuilder.build(events: events, comparisonID: "c")
        XCTAssertEqual(p.turns[0].prompt, "[redacted] [redacted] [redacted] [redacted] [redacted]\n    return 1")
        XCTAssertEqual(events[0].text, raw)
        let json = String(decoding: try p.previewBytes(), as: UTF8.self)
        XCTAssertFalse(json.contains("private-dom-id")); XCTAssertFalse(json.contains("1700000000000"))
    }
    func testDeclaredMissingTargetsRemainUnobservedAndLegacyMembershipUndeclared() throws {
        let other = PerformanceAgent(id: "duplicate-name", name: "Alice", connection: .cli)
        var metadata = event(.observationState, 1, turn: nil); metadata.agent = other
        let start = event(.turnStarted, 2, text: "Ask", targets: [agent.id, other.id])
        let p = try ComparisonPublicationBuilder.build(events: [metadata, start], comparisonID: "c")
        XCTAssertEqual(p.participants.count, 2)
        XCTAssertEqual(p.turns[0].targetedAgentIDs?.count, 2)
        XCTAssertEqual(p.turns[0].replies.map(\.outcome), ["unobserved", "unobserved"])
        let legacy = try ComparisonPublicationBuilder.build(events: [metadata, event(.turnStarted, 2, text: "Ask", group: nil)], comparisonID: "c")
        XCTAssertNil(legacy.turns[0].targetedAgentIDs)
        XCTAssertEqual(legacy.turns[0].kind, "unknown")
        XCTAssertNotNil(legacy.turns[0].alignmentLabel)
        XCTAssertEqual(legacy.turns[0].replies.count, 1)
    }
    func testConflictingScopeDuplicateStartAndUnassignedReplyCannotLeak() throws {
        var conflicting = event(.turnStarted, 2, scope: .private, text: "secret"); conflicting.agent?.id = "second"
        let malformed = [event(.turnStarted, 1, text: "shared"), conflicting, event(.replyObserved, 3, turn: nil, message: "x", text: "private-secret")]
        let p = try ComparisonPublicationBuilder.build(events: malformed, comparisonID: "c")
        XCTAssertTrue(p.turns.isEmpty)
        XCTAssertTrue(p.omissions.contains { $0.contains("conflicting-scope") })
        XCTAssertFalse(String(decoding: try p.previewBytes(), as: UTF8.self).contains("private-secret"))
        let duplicate = try ComparisonPublicationBuilder.build(events: [event(.turnStarted, 1, text: "x"), event(.turnStarted, 2, text: "x")], comparisonID: "c")
        XCTAssertTrue(duplicate.turns.isEmpty)
        XCTAssertTrue(duplicate.omissions.contains { $0.contains("malformed association") })
    }
    func testFeedbackWithReusedMessageIdentityDoesNotCrossTurns() throws {
        var second = event(.turnStarted, 4, turn: "second", text: "Next", group: "next"); second.turnPosition = 1
        var feedback = event(.feedback, 6, turn: nil, message: "reused"); feedback.selection = .favorite
        let p = try ComparisonPublicationBuilder.build(events: [event(.turnStarted, 1, text: "First"), event(.replyObserved, 2, message: "reused", text: "One"), second, event(.replyObserved, 5, turn: "second", message: "reused", text: "Two"), feedback], comparisonID: "c")
        XCTAssertEqual(p.turns.map { $0.replies[0].messages[0].feedback }, [.unmarked, .unmarked])
        XCTAssertTrue(p.omissions.contains { $0.contains("1 feedback selections with ambiguous") })
    }
    func testGapAndClockChangeProduceUnavailableRatherThanZeroTiming() throws {
        var gap = event(.gap, 3, turn: nil); gap.agent = nil
        let p = try ComparisonPublicationBuilder.build(events: [event(.turnStarted, 1, text: "x"), event(.dispatched, 2), gap, event(.replyObserved, 4, message: "m", text: "reply")], comparisonID: "c")
        XCTAssertTrue(p.turns[0].replies[0].messages[0].timingLabel.contains("unavailable"))
        var reply = event(.replyObserved, 3, message: "m", text: "reply"); reply.stamp.clockID = "restart"
        let restarted = try ComparisonPublicationBuilder.build(events: [event(.turnStarted, 1, text: "x"), event(.dispatched, 2), reply], comparisonID: "c")
        XCTAssertTrue(restarted.turns[0].replies[0].messages[0].timingLabel.contains("unavailable"))
    }
    func testCanonicalHashMatchesIndependentKnownSHAAndEditsChangeExactBytes() throws {
        // SHA-256 public known vector, independent of projection implementation.
        XCTAssertEqual(PerformanceCanonical.hash(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        var p = try ComparisonPublicationBuilder.build(events: [event(.turnStarted, 1, text: "x")], comparisonID: "c")
        let bytes = try p.previewBytes(), hash = try p.previewHash()
        XCTAssertEqual(hash, PerformanceCanonical.hash(bytes))
        p.turns[0].prompt = "owner edited"
        XCTAssertNotEqual(try p.previewBytes(), bytes); XCTAssertNotEqual(try p.previewHash(), hash)
    }
    func testActualRecorderProducesEditableProjectionWithoutChangingJournal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("publication-recorder-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = try PerformanceRecorder(directory: directory, fixture: true); recorder.enabled = true
        let turn = try recorder.beginTurn(comparisonID: "c", agent: agent, text: "Owner request", scope: .shared, requestGroup: .init(id: "actual-action", targetAgentIDs: [agent.id]))
        _ = try recorder.record(.dispatched, comparisonID: "c", agent: agent, turnID: turn)
        try recorder.reply(comparisonID: "c", agent: agent, messageID: "receipt-1", text: "Acknowledgment", turnID: turn)
        try recorder.reply(comparisonID: "c", agent: agent, messageID: "receipt-2", text: "Partial", turnID: turn)
        try recorder.setFeedback(comparisonID: "c", agentID: agent.id, messageID: "receipt-2", selection: .favorite)
        try recorder.reply(comparisonID: "c", agent: agent, messageID: "receipt-2", text: "Final answer", turnID: turn)
        _ = try recorder.record(.outcome, comparisonID: "c", agent: agent, turnID: turn, reason: "timeout")
        let original = try PerformanceCanonical.bytes(recorder.events)
        var p = try ComparisonPublicationBuilder.build(events: recorder.events, comparisonID: "c")
        XCTAssertEqual(p.turns[0].replies[0].messages.map(\.text), ["Acknowledgment", "Final answer"])
        XCTAssertEqual(p.turns[0].replies[0].messages[1].feedback, .favorite)
        XCTAssertEqual(p.turns[0].replies[0].outcome, "timeout")
        p.redactText { $0.replacingOccurrences(of: "Final answer", with: "Owner edit") }
        XCTAssertEqual(try PerformanceCanonical.bytes(recorder.events), original)
    }
    func testEarlierHistoryUnavailableAndArtifactAllowlist() throws {
        var options = ComparisonPublicationOptions(); options.includeEarlierHistory = true
        XCTAssertThrowsError(try ComparisonPublicationBuilder.build(events: [], comparisonID: "c", options: options))
        XCTAssertThrowsError(try ComparisonPublication.Artifact(id: "a", name: "inert.svg", type: "image/svg+xml", bytes: Data("<svg/>".utf8)))
        XCTAssertThrowsError(try ComparisonPublication.Artifact(id: "a", name: "fake.png", type: "image/png", bytes: Data("<html/>".utf8)))
        let text = try ComparisonPublication.Artifact(id: "a", name: "Selected text", type: "text/plain", bytes: Data("<script/>".utf8))
        XCTAssertEqual(Data(base64Encoded: text.base64), Data("<script/>".utf8))
    }
}
