import XCTest
@testable import msgblastCore

final class PerformanceTests: XCTestCase {
    func testRequestGroupFixtureAlignsRepeatedSharedActionsAfterPrivateTurns() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent("docs/performance/sample-upload-request-groups-v1.json")
        let bytes = try Data(contentsOf: fixture)
        let chunk = try JSONDecoder().decode(PerformanceUploadChunk.self, from: bytes)
        XCTAssertEqual(try PerformanceCanonical.bytes(chunk), bytes)
        let digest = try String(contentsOf: fixture.deletingPathExtension().appendingPathExtension("sha256"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(PerformanceCanonical.hash(bytes), digest)
        let turns = chunk.events.filter { $0.kind == .turnStarted }
        let initial = turns.filter { $0.requestGroupID == "synthetic-group-comparison" }
        let repeated = turns.filter { $0.requestGroupID == "synthetic-shared-follow-up" }
        XCTAssertEqual(initial.count, 4)
        XCTAssertEqual(repeated.count, 4)
        XCTAssertEqual(Set(repeated.compactMap(\.agent?.id)), ["web-a", "cli-b", "messages-c", "bot-d"])
        XCTAssertEqual(Set(repeated.compactMap(\.turnPosition)), [1, 2])
        XCTAssertEqual(Set(repeated.compactMap(\.text)), Set(initial.compactMap(\.text)))
        let subset = turns.filter { $0.requestGroupID == "synthetic-targeted-follow-up" }
        XCTAssertEqual(subset.count, 2)
        XCTAssertTrue(subset.allSatisfy { $0.targetAgentIDs == ["messages-c", "web-a"] })
        XCTAssertFalse(subset.contains { $0.agent?.id == "bot-d" })
        let unaligned = turns.first { $0.text == "Manual unaligned request" }!
        XCTAssertNil(unaligned.requestGroupID)
        XCTAssertNil(unaligned.targetAgentIDs)
    }

    func testAgentNavigationGapDoesNotInvalidateAnotherAgentButGlobalGapDoes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try PerformanceRecorder(directory: root, fixture: true); recorder.enabled = true
        let alpha = PerformanceAgent(id: "alpha", name: "Alpha", connection: .website)
        let beta = PerformanceAgent(id: "beta", name: "Beta", connection: .website)
        func stamp(_ ms: Int64) -> PerformanceStamp { .init(clockID: "clock", monotonicMS: ms, wallMS: 1000 + ms) }
        let a = try recorder.beginTurn(comparisonID: "c", agent: alpha, text: "A", scope: .shared, at: stamp(0))
        _ = try recorder.record(.dispatched, comparisonID: "c", agent: alpha, turnID: a, at: stamp(10))
        let b = try recorder.beginTurn(comparisonID: "c", agent: beta, text: "B", scope: .shared, at: stamp(15))
        _ = try recorder.record(.dispatched, comparisonID: "c", agent: beta, turnID: b, at: stamp(20))
        _ = try recorder.record(.gap, comparisonID: "c", agent: alpha, reason: "navigation", at: stamp(40))
        try recorder.reply(comparisonID: "c", agent: beta, messageID: "beta", text: "Continuous Beta", turnID: b, at: stamp(80))
        try recorder.reply(comparisonID: "c", agent: alpha, messageID: "alpha", text: "After Alpha navigation", turnID: a, at: stamp(90))
        XCTAssertEqual(PerformanceMetrics.firstReplyMS(events: recorder.events, turnID: b), 60)
        XCTAssertNil(PerformanceMetrics.firstReplyMS(events: recorder.events, turnID: a))
        let nextA = try recorder.beginTurn(comparisonID: "c", agent: alpha, text: "A2", scope: .shared, at: stamp(100))
        _ = try recorder.record(.dispatched, comparisonID: "c", agent: alpha, turnID: nextA, at: stamp(110))
        let nextB = try recorder.beginTurn(comparisonID: "c", agent: beta, text: "B2", scope: .shared, at: stamp(115))
        _ = try recorder.record(.dispatched, comparisonID: "c", agent: beta, turnID: nextB, at: stamp(120))
        _ = try recorder.record(.gap, comparisonID: "c", reason: "sleep", at: stamp(130))
        try recorder.reply(comparisonID: "c", agent: alpha, messageID: "alpha2", text: "After sleep", turnID: nextA, at: stamp(190))
        try recorder.reply(comparisonID: "c", agent: beta, messageID: "beta2", text: "After sleep", turnID: nextB, at: stamp(200))
        XCTAssertNil(PerformanceMetrics.firstReplyMS(events: recorder.events, turnID: nextA))
        XCTAssertNil(PerformanceMetrics.firstReplyMS(events: recorder.events, turnID: nextB))
    }

    func testTimingPartitionsMissingCompletionAndGapBoundaries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try PerformanceRecorder(directory: root, fixture: true); recorder.enabled = true
        let cli = PerformanceAgent(id: "cli", name: "Same name", connection: .cli, provider: "codexCLI")
        func stamp(_ ms: Int64) -> PerformanceStamp { .init(clockID: "clock", monotonicMS: ms, wallMS: 1000 + ms) }
        let initial = try recorder.beginTurn(comparisonID: "c", agent: cli, text: "Initial", scope: .shared, at: stamp(0))
        _ = try recorder.record(.dispatched, comparisonID: "c", agent: cli, turnID: initial, at: stamp(10))
        try recorder.reply(comparisonID: "c", agent: cli, messageID: "first", text: "Final output", turnID: initial, at: stamp(110))
        _ = try recorder.record(.completed, comparisonID: "c", agent: cli, turnID: initial, at: stamp(130))
        let follow = try recorder.beginTurn(comparisonID: "c", agent: cli, text: "Follow-up", scope: .private, at: stamp(200))
        _ = try recorder.record(.dispatched, comparisonID: "c", agent: cli, turnID: follow, at: stamp(210))
        try recorder.reply(comparisonID: "c", agent: cli, messageID: "follow", text: "Follow-up output", turnID: follow, at: stamp(410))
        _ = try recorder.record(.completed, comparisonID: "c", agent: cli, turnID: follow, at: stamp(430))
        let messages = PerformanceAgent(id: "messages", name: "Same name", connection: .messages)
        let messageTurn = try recorder.beginTurn(comparisonID: "c", agent: messages, text: "Messages", scope: .shared, at: stamp(500))
        _ = try recorder.record(.dispatched, comparisonID: "c", agent: messages, turnID: messageTurn, at: stamp(510))
        try recorder.reply(comparisonID: "c", agent: messages, messageID: "m", text: "Observed message", turnID: messageTurn, at: stamp(550))
        let stats = PersonalUsageStats(events: recorder.events)
        let usage = stats.agents.first { $0.id == "cli" }!
        XCTAssertEqual(usage.medianInitialReplyMS, 100)
        XCTAssertEqual(usage.medianFollowUpReplyMS, 200)
        XCTAssertEqual(usage.initialTimingSamples, 1)
        XCTAssertEqual(usage.followUpTimingSamples, 1)
        XCTAssertEqual(usage.completionSamples, 2)
        XCTAssertEqual(usage.replied, 2)
        XCTAssertEqual(stats.agents.first { $0.id == "messages" }?.completionSamples, 0)
        XCTAssertEqual(PersonalUsageStats.rate(usage.replied, of: usage.turns), "2/2 (100%)")
        let gapTurn = try recorder.beginTurn(comparisonID: "c", agent: cli, text: "Gap", scope: .shared, at: stamp(600))
        _ = try recorder.record(.dispatched, comparisonID: "c", agent: cli, turnID: gapTurn, at: stamp(610))
        _ = try recorder.record(.gap, comparisonID: "c", reason: "sleep", at: stamp(620))
        try recorder.reply(comparisonID: "c", agent: cli, messageID: "gap", text: "After gap", turnID: gapTurn, at: stamp(710))
        XCTAssertNil(PerformanceMetrics.firstReplyMS(events: recorder.events, turnID: gapTurn))
        try recorder.stop(reason: "disabled")
        XCTAssertTrue(recorder.activeComparisonIDs.isEmpty)
        XCTAssertTrue(try PerformanceRecorder(directory: root, fixture: true).activeComparisonIDs.isEmpty)
        let file = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("Performance/events.jsonl").path)
        let directory = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("Performance").path)
        XCTAssertEqual((file[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((directory[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testNativeProducedProviderFixturePreservesUnknownModelsAndDistinctReplies() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent("docs/performance/sample-upload-providers-v1.json")
        let bytes = try Data(contentsOf: fixture)
        let chunk = try JSONDecoder().decode(PerformanceUploadChunk.self, from: bytes)
        XCTAssertEqual(try PerformanceCanonical.bytes(chunk), bytes)
        let digest = try String(contentsOf: fixture.deletingPathExtension().appendingPathExtension("sha256"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(PerformanceCanonical.hash(bytes), digest)
        let agents = chunk.events.filter { $0.kind == .turnStarted }.compactMap(\.agent)
        XCTAssertEqual(Set(agents.compactMap(\.provider)), ["chatgpt", "claude"])
        XCTAssertEqual(Set(agents.map(\.id)).count, 3)
        XCTAssertTrue(agents.allSatisfy { $0.model == nil })
        XCTAssertEqual(chunk.events.filter { $0.kind == .replyObserved }.count, 6)
        XCTAssertEqual(Set(chunk.events.filter { $0.kind == .replyObserved }.compactMap(\.messageID)).count, 6)
        XCTAssertTrue(chunk.events.contains { $0.kind == .observationState })
    }

    func testRangeOutcomesUseOnlySelectedTurnsAndNormalClosureIsNotPartial() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try PerformanceRecorder(directory: root, fixture: true); recorder.enabled = true
        let agent = PerformanceAgent(id: "cli", name: "CLI", connection: .cli)
        let old = try recorder.beginTurn(comparisonID: "c", agent: agent, text: "Old", scope: .shared, at: .init(clockID: "clock", monotonicMS: 100, wallMS: 1000))
        _ = try recorder.record(.completed, comparisonID: "c", agent: agent, turnID: old, at: .init(clockID: "clock", monotonicMS: 200, wallMS: 2500))
        let selected = try recorder.beginTurn(comparisonID: "c", agent: agent, text: "Selected", scope: .private, at: .init(clockID: "clock", monotonicMS: 300, wallMS: 2600))
        _ = try recorder.record(.completed, comparisonID: "c", agent: agent, turnID: selected, at: .init(clockID: "clock", monotonicMS: 400, wallMS: 2700))
        let stats = PersonalUsageStats(events: recorder.events, since: Date(timeIntervalSince1970: 2), until: Date(timeIntervalSince1970: 3))
        XCTAssertEqual(stats.turnCount, 1)
        XCTAssertEqual(stats.agents.first?.completed, 1, "An outcome from a turn outside the range cannot enter the selected denominator")
        try recorder.stop(reason: "disabled")
        XCTAssertEqual(PersonalUsageStats(events: recorder.events).partialCount, 0, "Closing a bounded idle recording is not a gap")
    }

    func testStaleWriterCannotDamageAnotherCommittedAppend() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let one = try PerformanceRecorder(directory: root, fixture: true); one.enabled = true
        let agent = PerformanceAgent(id: "a", name: "Agent", connection: .cli)
        _ = try one.beginTurn(comparisonID: "c", agent: agent, text: "First", scope: .shared)
        let two = try PerformanceRecorder(directory: root, fixture: true); two.enabled = true
        _ = try two.beginTurn(comparisonID: "c", agent: agent, text: "Second", scope: .private)
        let url = root.appendingPathComponent("Performance/events.jsonl")
        let committed = try Data(contentsOf: url)
        XCTAssertThrowsError(try one.record(.gap, comparisonID: "c", reason: "stale-writer"))
        XCTAssertEqual(try Data(contentsOf: url), committed)
        XCTAssertEqual(try PerformanceRecorder(directory: root, fixture: true).events.count, two.events.count)
    }

    func testOldStateDefaultsOffWithoutChangingDraft() throws {
        var state = AppState(); state.draft = "Keep this draft"
        let decoded = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state))
        XCTAssertFalse(decoded.performanceTrackingEnabled)
        XCTAssertEqual(decoded.draft, state.draft)
    }

    func testDiskJournalFeedbackRevisionsAndCorruptionPreservation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try PerformanceRecorder(directory: root, fixture: true)
        recorder.enabled = true
        let comparison = UUID().uuidString
        let agent = PerformanceAgent(id: "agent-a", name: "Same name", connection: .cli)
        let turn = try recorder.beginTurn(comparisonID: comparison, agent: agent, text: "Synthetic", scope: .shared, at: .init(clockID: "clock", monotonicMS: 100, wallMS: 1000))
        _ = try recorder.record(.dispatched, comparisonID: comparison, agent: agent, turnID: turn, at: .init(clockID: "clock", monotonicMS: 100, wallMS: 1000))
        try recorder.reply(comparisonID: comparison, agent: agent, messageID: "reply", text: "Answer", turnID: turn, at: .init(clockID: "clock", monotonicMS: 350, wallMS: -2000))
        try recorder.reply(comparisonID: comparison, agent: agent, messageID: "reply", text: "Answer revised", turnID: turn, at: .init(clockID: "clock", monotonicMS: 400, wallMS: -1000))
        try recorder.setFeedback(comparisonID: comparison, agentID: agent.id, messageID: "reply", selection: .favorite)
        try recorder.setFeedback(comparisonID: comparison, agentID: agent.id, messageID: "reply", selection: .negative)
        let restored = try PerformanceRecorder(directory: root, fixture: true)
        XCTAssertEqual(restored.replies.count, 1)
        XCTAssertEqual(restored.replies.first?.feedback, .negative)
        XCTAssertEqual(restored.replies.first?.text, "Answer revised")
        XCTAssertEqual(PerformanceMetrics.firstReplyMS(events: restored.events, turnID: turn), 250)
        let journal = root.appendingPathComponent("Performance/events.jsonl")
        var bytes = try Data(contentsOf: journal); bytes.append(Data("broken".utf8))
        try bytes.write(to: journal)
        XCTAssertThrowsError(try PerformanceRecorder(directory: root, fixture: true))
        XCTAssertEqual(try Data(contentsOf: journal), bytes)
    }

    func testPortableFixtureCanonicalHashAndInterleavedChains() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/performance/sample-upload-v1.json")
        let bytes = try Data(contentsOf: fixture)
        let chunk = try JSONDecoder().decode(PerformanceUploadChunk.self, from: bytes)
        XCTAssertEqual(try PerformanceCanonical.bytes(chunk), bytes)
        let digest = try String(contentsOf: fixture.deletingPathExtension().appendingPathExtension("sha256"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(PerformanceCanonical.hash(bytes), digest)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try PerformanceRecorder(directory: root, fixture: true); recorder.enabled = true
        let agent = PerformanceAgent(id: "a", name: "Agent", connection: .cli)
        _ = try recorder.beginTurn(comparisonID: "one", agent: agent, text: "One", scope: .shared)
        _ = try recorder.beginTurn(comparisonID: "two", agent: agent, text: "Two", scope: .shared)
        _ = try recorder.beginTurn(comparisonID: "one", agent: agent, text: "Follow-up", scope: .private)
        let first = recorder.events.filter { $0.comparisonID == "one" }
        XCTAssertEqual(first.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(first[2].previousHash, PerformanceCanonical.hash(try PerformanceCanonical.bytes(first[1])))
        XCTAssertEqual(try PerformanceRecorder(directory: root, fixture: true).events.count, 5)
    }

    func testOffRecordsNothingAndDisableClosesSegment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try PerformanceRecorder(directory: root, fixture: true)
        let agent = PerformanceAgent(id: "a", name: "Agent", connection: .messages)
        XCTAssertNil(try recorder.beginTurn(comparisonID: "c", agent: agent, text: "Not recorded", scope: .shared))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Performance").path))
        recorder.enabled = true
        _ = try recorder.beginTurn(comparisonID: "c", agent: agent, text: "Recorded", scope: .shared)
        try recorder.stop(reason: "disabled")
        recorder.enabled = false
        XCTAssertEqual(recorder.events.last?.kind, .segmentEnded)
        let before = recorder.events.count
        try recorder.reply(comparisonID: "c", agent: agent, messageID: "late", text: "Late", turnID: nil)
        XCTAssertEqual(recorder.events.count, before)
    }

    func testMissingClocksAndDistinctAgentUsage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try PerformanceRecorder(directory: root, fixture: true); recorder.enabled = true
        let a = PerformanceAgent(id: "a", name: "Same", connection: .website)
        let b = PerformanceAgent(id: "b", name: "Same", connection: .website)
        let turn = try recorder.beginTurn(comparisonID: "c", agent: a, text: "Question", scope: .shared, at: .init(clockID: "old", monotonicMS: 50, wallMS: 1000))
        _ = try recorder.record(.dispatched, comparisonID: "c", agent: a, turnID: turn, at: .init(clockID: "old", monotonicMS: 50, wallMS: 1000))
        try recorder.reply(comparisonID: "c", agent: a, messageID: "reply", text: "Answer", turnID: turn, at: .init(clockID: "new", monotonicMS: 100, wallMS: 2000))
        _ = try recorder.beginTurn(comparisonID: "c", agent: b, text: "Question", scope: .shared)
        XCTAssertNil(PerformanceMetrics.firstReplyMS(events: recorder.events, turnID: turn))
        let stats = PersonalUsageStats(events: recorder.events)
        XCTAssertEqual(stats.agents.count, 2)
        XCTAssertEqual(stats.turnCount, 2)
        XCTAssertEqual(stats.comparisonCount, 1)
    }
}
