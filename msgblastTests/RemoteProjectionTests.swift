import Combine
import XCTest
@testable import msgblastCore
import msgblastRemoteProtocol

@MainActor
final class RemoteProjectionTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private func status(locked: Bool = false) -> MacStatus {
        MacStatus(macName: "Studio", variant: .demo, locked: locked, awake: true, databaseAvailable: true, databaseStatus: "ok", messagesBusy: false, broadcastBusy: false,
                  sendingAgentIDs: [], keepAwakeEnabled: true, keepAwakeHeld: false, messagesSendsAllowed: false, observedAt: Date())
    }
    private func fixture() -> (RemoteProjectionInput, Comparison, Member) {
        let member = Member(agentID: UUID(), name: "Cedar", chat: Chat(id: "demo-0", handle: "cedar@example.com", lastActivity: 0))
        var comparison = Comparison(prompt: "Compare approaches", members: [member])
        comparison.created = date
        comparison.members[0].submission = .submitted
        comparison.setWebAgents([.claude, .codexCLI])
        var followUp = FollowUp(text: "Only Cedar", memberIDs: [member.id]); followUp.created = date.addingTimeInterval(5); followUp.states[member.id.uuidString] = .uncertain
        comparison.followUps = [followUp]
        var input = RemoteProjectionInput(macStatus: status(), gridAgentIDs: ["claude"], agents: [], comparisons: [comparison])
        input.messagesTranscripts = [comparison.id: [member.id: [
            Message(id: 1, guid: "out-1", chatID: "demo-0", text: "Compare approaches", outgoing: true, date: date),
            Message(id: 2, guid: "in-2", chatID: "demo-0", text: "Start small.", outgoing: false, date: date.addingTimeInterval(9))]]]
        var attempt = WebSendAttempt(text: "Compare approaches", status: .waiting); attempt.comparisonID = comparison.id
        input.webHistories = [comparison.id: [.claude: [WebPageMessage(id: "node-1", role: "user", text: "Compare approaches"), WebPageMessage(id: "node-2", role: "assistant", text: "Draft")],
                                              .codexCLI: [WebPageMessage(id: "uuid-a", role: "assistant", text: "Native")]]]
        input.webAttempts = [comparison.id: [.claude: [attempt]]]
        input.canEnd = [comparison.id: false]
        return (input, comparison, member)
    }

    func testBuilderProjectsConversationsTurnsAndAttemptsWithStableIDs() throws {
        let (input, comparison, member) = fixture()
        let state = RemoteProjectionBuilder.state(from: input)
        let conversation = try XCTUnwrap(state.conversations.first)
        XCTAssertEqual(conversation.agentIDs, ["messages:\(member.id.uuidString)", "claude", "codexCLI"])
        XCTAssertFalse(conversation.canEnd, "End stays unavailable until website history is loaded on the Mac")
        XCTAssertEqual(conversation.unresolvedAttemptCount, 2, "The waiting web attempt and the uncertain follow-up")
        XCTAssertEqual(conversation.lastActivity, date.addingTimeInterval(9))
        let ids = state.turns.map(\.id)
        XCTAssertEqual(ids.first, "p:\(comparison.id.uuidString)")
        XCTAssertTrue(ids.contains("m:in-2")); XCTAssertFalse(ids.contains("m:out-1"), "Outgoing Messages rows are the user's own prompts")
        XCTAssertTrue(ids.contains("w:claude:\(comparison.id.uuidString):1"), "Website turns are keyed by position, not synthetic DOM ids")
        XCTAssertTrue(ids.contains("w:codexCLI:\(comparison.id.uuidString):uuid-a"), "Native transcripts keep their stable ids")
        let followUp = try XCTUnwrap(state.turns.first { $0.origin == .followUp })
        XCTAssertEqual(followUp.agentID, "messages:\(member.id.uuidString)", "A one-member follow-up is private")
        XCTAssertEqual(Set(state.attempts.map(\.status)), [.submitted, .uncertain, .waiting])
    }

    func testIncompleteNativeRequestsAreListedPerConversation() throws {
        var (input, comparison, _) = fixture()
        var stuck = WebSendAttempt(text: "Compare approaches", status: .uncertain); stuck.comparisonID = comparison.id
        var done = WebSendAttempt(text: "Earlier", status: .observed); done.comparisonID = comparison.id
        input.webAttempts[comparison.id]?[.codexCLI] = [stuck, done]
        let conversation = try XCTUnwrap(RemoteProjectionBuilder.state(from: input).conversations.first)
        XCTAssertEqual(conversation.incompleteAttempts, [RemoteIncompleteAttempt(agentID: "codexCLI", attemptID: "wa:\(stuck.id.uuidString)", reasonCode: .incompleteRequestBlocking)],
                       "The waiting website attempt is not a block; only the native request is")
        let decoded = try RemoteProtocol.decoder().decode(RemoteConversation.self, from: RemoteProtocol.encoder().encode(conversation))
        XCTAssertEqual(decoded, conversation)
        var legacy = try JSONSerialization.jsonObject(with: RemoteProtocol.encoder().encode(conversation)) as! [String: Any]
        legacy["incompleteAttempts"] = nil
        XCTAssertEqual(try RemoteProtocol.decoder().decode(RemoteConversation.self, from: JSONSerialization.data(withJSONObject: legacy)).incompleteAttempts, [])
    }

    func testJournalDiffsUpdatesInPlaceAndResumes() throws {
        var (input, comparison, _) = fixture()
        let journal = RemoteChangeJournal(capacity: 50, startingSeq: 1000)
        let initial = journal.apply(RemoteProjectionBuilder.state(from: input))
        XCTAssertEqual(initial.first?.seq, 1001)
        XCTAssertEqual(initial.map(\.seq), Array(1001...UInt64(1000 + initial.count)), "seq is contiguous and monotonic")
        XCTAssertTrue(journal.apply(RemoteProjectionBuilder.state(from: input)).isEmpty, "An unchanged projection emits nothing")
        let cursor = journal.seq

        // A streaming website reply re-renders at the same position: one update, same id.
        input.webHistories[comparison.id]?[.claude]?[1] = WebPageMessage(id: "node-9", role: "assistant", text: "Draft, then more")
        let streaming = journal.apply(RemoteProjectionBuilder.state(from: input))
        XCTAssertEqual(streaming.count, 1)
        guard case .turnUpsert(let turn) = streaming[0].change else { return XCTFail("Expected a turn update") }
        XCTAssertEqual(turn.id, "w:claude:\(comparison.id.uuidString):1")
        XCTAssertEqual(turn.text, "Draft, then more")

        // Status timestamps alone do not emit; content does.
        input.macStatus = status()
        XCTAssertTrue(journal.apply(RemoteProjectionBuilder.state(from: input)).isEmpty)
        input.macStatus = status(locked: true)
        XCTAssertEqual(journal.apply(RemoteProjectionBuilder.state(from: input)).map(\.change.kind), ["macStatus"])

        XCTAssertEqual(journal.events(since: cursor)?.map(\.change.kind), ["turnUpsert", "macStatus"])
        XCTAssertEqual(journal.events(since: journal.seq)?.count, 0)
        XCTAssertNil(journal.events(since: journal.seq + 1), "A cursor from the future needs a snapshot")

        input.comparisons = []
        let removed = journal.apply(RemoteProjectionBuilder.state(from: input))
        XCTAssertTrue(removed.contains { if case .conversationRemove(let id) = $0.change { return id == comparison.id }; return false })
        XCTAssertEqual(removed.filter { $0.change.kind == "turnRemove" }.count, 6)
        XCTAssertTrue(journal.snapshot()?.conversations.isEmpty == true)
    }

    func testOldCursorsGetASnapshotAndSeqSurvivesRestarts() {
        let (input, _, _) = fixture()
        let journal = RemoteChangeJournal(capacity: 3, startingSeq: 0)
        let events = journal.apply(RemoteProjectionBuilder.state(from: input))
        XCTAssertGreaterThan(events.count, 3)
        XCTAssertNil(journal.events(since: 0), "The bounded history no longer reaches the cursor")
        XCTAssertEqual(journal.events(since: journal.seq - 3)?.count, 3)
        XCTAssertEqual(journal.snapshot()?.seq, journal.seq)

        let earlier = RemoteChangeJournal()
        let later = RemoteChangeJournal(startingSeq: UInt64(Date().addingTimeInterval(1).timeIntervalSince1970 * 1000) * 1024)
        XCTAssertGreaterThan(later.seq, earlier.seq + 1000, "A relaunched Mac never reuses an old cursor")
        XCTAssertNil(later.events(since: earlier.seq))
    }

    func testProjectionDebouncesObjectWillChange() async throws {
        let subject = PassthroughSubject<Void, Never>()
        var builds = 0
        var (input, _, _) = fixture()
        let projection = RemoteProjection(debounce: .milliseconds(30), triggers: [subject.eraseToAnyPublisher()]) {
            builds += 1
            return RemoteProjectionBuilder.state(from: input)
        }
        var received: [[RemoteEvent]] = []
        projection.onEvents = { received.append($0) }
        projection.start()
        XCTAssertEqual(builds, 1, "Starting builds the first projection")
        input.gridAgentIDs = ["claude", "codexCLI"]
        for _ in 0..<10 { subject.send() }
        for _ in 0..<50 where builds < 2 { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(builds, 2, "A burst of changes rebuilds once")
        XCTAssertEqual(received.last?.map(\.change.kind), ["grid"])
        projection.stop()
        subject.send()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(builds, 2, "Stopped projections do not observe")
    }

    func testGatherReadsLiveSessionsWithoutConnecting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-projection-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let web = WebAgents(directory: directory, fixture: true)
        defer { web.beginShutdown() }
        var comparison = Comparison(prompt: "Hello", members: [])
        comparison.setWebAgents([.claude])
        var input = RemoteProjectionInput(macStatus: status(), gridAgentIDs: [], agents: [], comparisons: [comparison])
        input.gatherWebState(from: web.sessions)
        XCTAssertEqual(input.webHistories[comparison.id]?[.claude], [])
        XCTAssertEqual(input.canEnd[comparison.id], true, "Nothing submitted yet, so nothing must load before ending")
        XCTAssertFalse(web.session(for: .claude)!.connected)
        var ended = comparison; ended.endedAt = date; ended.endedWebHistory = ["claude": [WebPageMessage(id: "x", role: "assistant", text: "Kept")]]
        input.comparisons = [ended]
        input.gatherWebState(from: web.sessions)
        XCTAssertEqual(input.webHistories[comparison.id]?[.claude]?.first?.text, "Kept", "Ended conversations project their retained history")
        XCTAssertEqual(input.canEnd[comparison.id], false)
    }
}
