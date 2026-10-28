import XCTest
import msgblastRemoteProtocol
@testable import msgblastMobileKit

final class PresenterTests: XCTestCase {
    func testInboxChipsAndThreadsFromRecordedEvents() throws {
        let state = try RecordedFixtures.reduce(["send", "resume"])
        let presenter = ProjectionPresenter(state: state)
        let rows = presenter.inbox
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.title, "Second fixture question", "Newest activity first")
        XCTAssertTrue(rows.allSatisfy(\.isDirect), "One-agent conversations are direct rows")
        let first = try XCTUnwrap(rows.first { $0.title == "Fixture question from the phone" })
        XCTAssertTrue(first.preview.contains(":"), "Preview shows the last reply with its agent")

        let prompt = try XCTUnwrap(presenter.turns(in: first.id, agentID: nil).first { $0.origin == .sharedPrompt })
        let chips = presenter.chips(for: prompt)
        XCTAssertEqual(chips.count, 1)
        XCTAssertEqual(chips.first?.state, .replied, "A submitted Messages send with a later reply reads Replied")
        let agent = try XCTUnwrap(first.agentIDs.first)
        XCTAssertEqual(presenter.chips(for: prompt, agentID: agent).map(\.agentID), [agent], "A one-agent filter shows only that agent's chip")
        XCTAssertTrue(presenter.chips(for: prompt, agentID: "someone-else").isEmpty)
        XCTAssertTrue(presenter.turns(in: first.id, agentID: agent).contains { $0.role == .assistant })
    }

    func testSharedPromptChipsFollowTheAgentFilter() {
        var state = ProjectionState()
        let conversation = UUID()
        let prompt = RemoteTurn(id: "p", conversationID: conversation, agentID: nil, role: .user, origin: .sharedPrompt, text: "Hi", created: Date(), ordinal: 0, contentHash: "h")
        state.turns[prompt.id] = prompt
        for (agent, status) in [("claude", RemoteAttemptStatus.observed), ("codexCLI", .uncertain)] {
            state.attempts[agent] = RemoteAttempt(id: agent, conversationID: conversation, agentID: agent, text: "Hi", status: status, detail: nil, created: Date())
        }
        let presenter = ProjectionPresenter(state: state)
        XCTAssertEqual(presenter.chips(for: prompt).map(\.agentID), ["claude", "codexCLI"], "All shows every agent")
        XCTAssertEqual(presenter.chips(for: prompt, agentID: "codexCLI").map(\.state), [.unconfirmed], "One agent's view shows only its chip")
    }

    func testDisabledReasonsLaunchNotesAndProductGroups() throws {
        var state = try RecordedFixtures.reduce(["snapshot"])
        let presenter = ProjectionPresenter(state: state)
        let messages = try XCTUnwrap(state.orderedAgents.first { $0.form == .messages })
        XCTAssertNil(presenter.disabledReason(agentIDs: [messages.agentID], conversation: nil))
        XCTAssertEqual(presenter.disabledReason(agentIDs: ["geminiApp"], conversation: nil), "Gemini is not offered in this version of msgblast.")
        XCTAssertEqual(presenter.disabledReason(agentIDs: [], conversation: nil), "Choose who to send to.")

        var app = try XCTUnwrap(state.agents["chatgptApp"])
        app.readiness = .readyWillLaunch
        state.agents["chatgptApp"] = app
        XCTAssertEqual(ProjectionPresenter(state: state).launchNotes(agentIDs: ["chatgptApp"]), ["Will open ChatGPT on your Mac"])

        let conversation = UUID()
        state.conversations[conversation] = RemoteConversation(id: conversation, title: "T", prompt: "P", created: Date(), endedAt: nil, agentIDs: ["chatgptApp"], canEnd: true,
            unresolvedAttemptCount: 1, lastActivity: Date(), incompleteAttempts: [RemoteIncompleteAttempt(agentID: "chatgptApp", attemptID: "wa:1", reasonCode: .incompleteRequestBlocking)])
        XCTAssertNotNil(ProjectionPresenter(state: state).disabledReason(agentIDs: ["chatgptApp"], conversation: conversation), "Blocked inside that conversation")
        XCTAssertNil(ProjectionPresenter(state: state).disabledReason(agentIDs: ["chatgptApp"], conversation: nil), "Ready elsewhere")
        state.macLocked = true
        XCTAssertEqual(ProjectionPresenter(state: state).disabledReason(agentIDs: [messages.agentID], conversation: nil), "Your Mac is locked.")

        let groups = presenter.productGroups
        XCTAssertEqual(Set(groups.map(\.product)).count, groups.count, "One group per product")
        XCTAssertTrue(groups.allSatisfy { group in group.agents.allSatisfy { $0.product == group.product } }, "Forms are grouped, histories stay separate")
        XCTAssertEqual(ProjectionPresenter.formLabel(.webhookBot), "Bot")
        XCTAssertEqual(ChipState(.uncertain), .unconfirmed)
        XCTAssertEqual(ChipState(.observed), .replied)
    }
}

@MainActor
final class MobileAppTests: XCTestCase {
    func testPairSendAndUnconfirmedWhenTheConnectionDrops() async throws {
        let mac = FakeMac()
        let defaults = UserDefaults(suiteName: "msgblast-mobile-tests-\(UUID().uuidString)")!
        let app = MobileApp(database: try LocalDatabase(url: nil), keys: MemoryDeviceKeyStore(), defaults: defaults,
                            makeTransport: { [mac] in mac.transport(for: $0, spki: $1) })
        app.connection.timing.backoff = [.seconds(30)]
        XCTAssertThrowsError(try app.send(.setKeepAwake(enabled: true)), "Never queued while disconnected")
        let paired = try await app.pair(link: mac.offer().url.absoluteString, deviceName: "Phone")
        XCTAssertEqual(paired.macName, "Fake Mac")
        for _ in 0..<100 where app.store.projection.seq == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(app.store.projection.seq, 10)

        let result = try await app.perform(.sendPrivate(conversationID: nil, agentID: "codexCLI", text: "Hi", attachmentIDs: []))
        XCTAssertEqual(result.outcome, .applied)
        XCTAssertEqual(app.store.commands[result.clientCommandID]?.status, .applied)

        mac.answerCommands = false
        let pending = try app.send(.sendPrivate(conversationID: nil, agentID: "codexCLI", text: "Lost", attachmentIDs: []))
        for _ in 0..<100 where !mac.commands.contains(where: { $0.clientCommandID == pending.clientCommandID }) { try await Task.sleep(for: .milliseconds(5)) }
        mac.sessions.last!.transport.drop()
        for _ in 0..<100 where app.store.commands[pending.clientCommandID]?.status != .unconfirmed { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(app.store.commands[pending.clientCommandID]?.status, .unconfirmed)
        XCTAssertEqual(mac.commands.filter { $0.clientCommandID == pending.clientCommandID }.count, 1, "Not resent")
        app.forgetMac()
        XCTAssertEqual(app.connection.state, .unpaired)
    }

    func testRepairingReturnsOnlyOnceTheNewInboxIsReady() async throws {
        let mac = FakeMac()
        let app = MobileApp(database: try LocalDatabase(url: nil), keys: MemoryDeviceKeyStore(),
                            defaults: UserDefaults(suiteName: "msgblast-mobile-tests-\(UUID().uuidString)")!,
                            makeTransport: { [mac] in mac.transport(for: $0, spki: $1) })
        _ = try await app.pairAndWaitForInbox(offer: mac.offer(), deviceName: "Phone")
        XCTAssertTrue(app.inboxReady)

        // Pairing again replaces the cache; the call waits for the new Mac's snapshot.
        mac.snapshotDelay = .milliseconds(200)
        let started = ContinuousClock.now
        _ = try await app.pairAndWaitForInbox(offer: mac.offer(), deviceName: "Phone")
        XCTAssertTrue(app.inboxReady, "Returns onto a filled inbox")
        XCTAssertEqual(app.store.projection.seq, 10)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(200))

        // A failed attempt throws and keeps the existing pairing, so a sheet can stay open.
        let before = app.connection.pairedMac
        var wrong = mac.offer(); wrong.code = "wrong"
        do { _ = try await app.pairAndWaitForInbox(offer: wrong, deviceName: "Phone"); XCTFail("A wrong code must not pair") } catch {}
        XCTAssertEqual(app.connection.pairedMac, before)
    }
}
