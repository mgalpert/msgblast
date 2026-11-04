import XCTest
import msgblastRemoteProtocol
@testable import msgblastMobileKit

/// A fixed instant, so no test depends on when it runs (Friday 15 January 2027, 08:00 UTC).
private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

/// Fixtures were recorded from the Demo Mac through scripts/record_mobile_fixtures.sh
/// (simulated Messages and replies, simulated lock; the Mac name is neutralized).
enum RecordedFixtures {
    static func events(_ name: String) throws -> [RemoteClientDriver.Event] {
        let bundle = Bundle(for: FixtureAnchor.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures") ?? bundle.url(forResource: name, withExtension: "jsonl"),
                                "Missing fixture \(name).jsonl")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { try RemoteProtocol.decoder().decode(RemoteClientDriver.Event.self, from: Data($0.utf8)) }
    }
    static func reduce(_ names: [String], from start: ProjectionState = ProjectionState()) throws -> ProjectionState {
        try names.flatMap(events).reduce(start, ProjectionReducer.reduce)
    }
}
final class FixtureAnchor {}

final class ReducerTests: XCTestCase {
    func testSnapshotFixtureBuildsTheProjection() throws {
        let state = try RecordedFixtures.reduce(["snapshot"])
        XCTAssertEqual(state.macStatus?.macName, "Demo Mac")
        XCTAssertEqual(state.macStatus?.variant, .demo)
        XCTAssertNotNil(state.seq)
        XCTAssertEqual(state.agents.count, 23)
        XCTAssertEqual(state.orderedAgents.count, state.agentOrder.count, "Agent order is kept from the snapshot")
        XCTAssertTrue(state.orderedAgents.contains { $0.form == .messages && $0.readiness == .ready })
        XCTAssertTrue(state.orderedAgents.contains { $0.agentID == "geminiApp" && $0.reasons.first?.code == .notOfferedInBuild })
        XCTAssertFalse(state.grid.isEmpty)
    }

    func testSendEventsAddTheConversationAndTheSimulatedReply() throws {
        let state = try RecordedFixtures.reduce(["send"])
        let conversation = try XCTUnwrap(state.sortedConversations.first)
        XCTAssertEqual(conversation.prompt, "Fixture question from the phone")
        let turns = state.turns(in: conversation.id)
        XCTAssertTrue(turns.contains { $0.origin == .sharedPrompt && $0.role == .user })
        XCTAssertTrue(turns.contains { $0.role == .assistant && $0.origin == .messagesHistory }, "The simulated Messages reply arrived as an event")
        XCTAssertEqual(state.attempts(in: conversation.id).first?.status, .submitted)

        // Replaying events already applied changes nothing (resume overlap).
        let again = try RecordedFixtures.events("send").filter { if case .events = $0 { true } else { false } }.reduce(state, ProjectionReducer.reduce)
        XCTAssertEqual(again, state)
    }

    func testResumeAppliesOnlyTheMissedEvents() throws {
        let before = try RecordedFixtures.reduce(["send"])
        let after = try RecordedFixtures.reduce(["resume"], from: before)
        XCTAssertGreaterThan(after.seq ?? 0, before.seq ?? 0)
        XCTAssertEqual(after.conversations.count, 2, "The second question made in another session arrived on resume")
        XCTAssertEqual(after.agents, before.agents, "A resume without a snapshot keeps the cached agents")
    }

    func testLockedThenUnlocked() throws {
        let base = try RecordedFixtures.reduce(["send"])
        let events = try RecordedFixtures.events("locked")
        var state = base
        var sawLocked = false
        for event in events {
            state = ProjectionReducer.reduce(state, event)
            if state.macLocked { sawLocked = true }
        }
        XCTAssertTrue(sawLocked, "The macLocked notice marks the Mac disconnected")
        XCTAssertFalse(state.macLocked, "Data after unlock clears it")
        XCTAssertEqual(state.macStatus?.locked, false)
        XCTAssertEqual(state.conversations, base.conversations, "Locking hides nothing already cached")
    }

    func testReplacedPhoneLosesItsPairing() throws {
        let state = try RecordedFixtures.reduce(["send", "replaced"])
        XCTAssertNotNil(state.pairingLost)
        XCTAssertFalse(state.conversations.isEmpty, "Cached history stays readable until the user forgets the Mac")
    }

    func testMultiPartSnapshotsMatchOneSnapshotAndUnknownChangesAskForASnapshot() throws {
        let snapshot = try XCTUnwrap(RecordedFixtures.events("send").lazy.compactMap { if case .snapshot(let s) = $0 { s } else { nil } }.first)
        var big = snapshot
        let conversation = UUID()
        big.turns = (0..<9).map { RemoteTurn(id: "t\($0)", conversationID: conversation, agentID: nil, role: .user, origin: .followUp, text: "\($0)", created: nil, ordinal: $0, contentHash: "h") }
        let whole = ProjectionReducer.reduce(ProjectionState(), .snapshot(big))
        let parts = big.parts(maximumTurnsPerPart: 4)
        XCTAssertEqual(parts.count, 3)
        var state = ProjectionState()
        for (index, part) in parts.enumerated() {
            state = ProjectionReducer.reduce(state, .snapshot(part))
            if index < parts.count - 1 { XCTAssertTrue(state.agents.isEmpty, "Nothing is shown until the last part") }
        }
        XCTAssertEqual(state, whole)
        let unknown = ProjectionReducer.reduce(state, .events([RemoteEvent(seq: (state.seq ?? 0) + 1, change: .unknown(kind: "hologram"))], latestSeq: (state.seq ?? 0) + 1))
        XCTAssertTrue(unknown.needsSnapshot)
    }

    func testCommandLedger() throws {
        var records: [UUID: CommandRecord] = [:]
        let send = RemoteCommand(action: .sendPrivate(conversationID: nil, agentID: "codexCLI", text: "Hi", attachmentIDs: []))
        records[send.clientCommandID] = CommandLedger.record(send, at: fixedNow)
        CommandLedger.apply(RemoteCommandResult(clientCommandID: send.clientCommandID, outcome: .accepted), to: &records)
        XCTAssertEqual(records[send.clientCommandID]?.status, .accepted)
        CommandLedger.connectionLost(&records)
        XCTAssertEqual(records[send.clientCommandID]?.status, .unconfirmed, "No result before the connection ended")
        XCTAssertEqual(CommandLedger.unresolved(records), [send.clientCommandID])
        CommandLedger.apply(.rejected(send.clientCommandID, .unknownCommand, "Restarted"), to: &records)
        XCTAssertEqual(records[send.clientCommandID]?.status, .unconfirmed, "unknownCommand after a Mac restart stays unconfirmed")
        CommandLedger.apply(RemoteCommandResult(clientCommandID: send.clientCommandID, outcome: .applied, replayed: true), to: &records)
        XCTAssertEqual(records[send.clientCommandID]?.status, .applied)
        XCTAssertTrue(CommandLedger.unresolved(records).isEmpty)
        let results = try RecordedFixtures.events("send").compactMap { if case .commandResult(let r) = $0 { r } else { nil } }
        XCTAssertEqual(results.first?.outcome, .applied)
    }

    @MainActor func testStorePersistsDraftsCommandsAndProjection() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-store-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MobileStore(database: try LocalDatabase(url: url))
        for event in try RecordedFixtures.events("send") { store.handle(event) }
        let key = MobileStore.draftKey(conversation: nil, agentID: nil)
        store.setDraft("Unsent on this phone", for: key)
        let pending = RemoteCommand(action: .setKeepAwake(enabled: true))
        store.recordSent(pending)
        store.saveNow()
        let reopened = MobileStore(database: try LocalDatabase(url: url))
        XCTAssertEqual(reopened.projection, store.projection)
        XCTAssertEqual(reopened.draft(key), "Unsent on this phone")
        XCTAssertEqual(reopened.commands[pending.clientCommandID]?.status, .unconfirmed, "A command without a result before quitting is unconfirmed")
        reopened.forgetMac()
        XCTAssertTrue(reopened.projection.conversations.isEmpty)
        XCTAssertEqual(MobileStore(database: try LocalDatabase(url: url)).draft(key), "")
    }
}
