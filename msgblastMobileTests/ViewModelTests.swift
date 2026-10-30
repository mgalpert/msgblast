import CryptoKit
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
        XCTAssertFalse(first.preview.hasPrefix(presenter.shortName(first.agentIDs[0]) + ":"), "A direct row shows the reply without repeating the agent")
        XCTAssertNotEqual(first.preview, first.title, "Preview shows the last reply, not the prompt")

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

    func testDisabledReasonsLaunchNotesAndNewConversationList() throws {
        var state = try RecordedFixtures.reduce(["snapshot"])
        let presenter = ProjectionPresenter(state: state)
        let messages = try XCTUnwrap(state.orderedAgents.first { $0.form == .messages })
        XCTAssertNil(presenter.disabledReason(agentIDs: [messages.agentID], conversation: nil))
        XCTAssertEqual(presenter.disabledLine(agentIDs: ["geminiApp"], conversation: nil), StatusLine("Gemini isn't in this version", detail: "Gemini is not offered in this version of msgblast."))
        XCTAssertEqual(presenter.disabledReason(agentIDs: [], conversation: nil), "Choose who to send to")

        var app = try XCTUnwrap(state.agents["chatgptApp"])
        app.readiness = .readyWillLaunch
        state.agents["chatgptApp"] = app
        XCTAssertEqual(ProjectionPresenter(state: state).launchNotes(agentIDs: ["chatgptApp"]), ["Opens ChatGPT on your Mac"])
        XCTAssertEqual(ProjectionPresenter.agentStatus(app), "Opens on your Mac", "The row already names the agent")

        let conversation = UUID()
        state.conversations[conversation] = RemoteConversation(id: conversation, title: "T", prompt: "P", created: Date(), endedAt: nil, agentIDs: ["chatgptApp"], canEnd: true,
            unresolvedAttemptCount: 1, lastActivity: Date(), incompleteAttempts: [RemoteIncompleteAttempt(agentID: "chatgptApp", attemptID: "wa:1", reasonCode: .incompleteRequestBlocking)])
        XCTAssertEqual(ProjectionPresenter(state: state).disabledReason(agentIDs: ["chatgptApp"], conversation: conversation), "Finish the ChatGPT request first", "Blocked inside that conversation")
        XCTAssertNil(ProjectionPresenter(state: state).disabledReason(agentIDs: ["chatgptApp"], conversation: nil), "Ready elsewhere")
        state.macLocked = true
        XCTAssertEqual(ProjectionPresenter(state: state).disabledReason(agentIDs: [messages.agentID], conversation: nil), "Mac locked")

        let list = presenter.newConversationAgents
        XCTAssertFalse(list.agents.isEmpty)
        XCTAssertTrue(list.agents.allSatisfy { $0.form != .messages }); XCTAssertTrue(list.messages.allSatisfy { $0.form == .messages })
        XCTAssertFalse(list.messages.isEmpty, "Messages contacts have their own section")
        let gridOrder = state.grid.filter { id in list.agents.contains { $0.agentID == id } }
        XCTAssertEqual(Array(list.agents.map(\.agentID).prefix(gridOrder.count)), gridOrder, "The Mac's grid order")
        XCTAssertEqual(Set(list.agents.map(\.agentID)).count, list.agents.count, "Each form is its own row; histories stay separate")
        XCTAssertEqual(ProjectionPresenter.formLabel(.webhookBot), "Bot")
        XCTAssertEqual(ChipState(.uncertain), .unconfirmed)
        XCTAssertEqual(ChipState(.observed), .replied)
    }
    func testARefusedPrepareKeepsSendEnabledAndRetriesOnceTheAgentIsReady() throws {
        var state = try RecordedFixtures.reduce(["snapshot"])
        var app = try XCTUnwrap(state.agents["chatgptApp"])
        app.readiness = .ready
        state.agents["chatgptApp"] = app
        let name = app.displayName
        let refused = ["chatgptApp": "Check msgblast permissions on your Mac"]
        let ready = ProjectionPresenter(state: state)

        // Only the refused prepare is in the way: its reason shows, Send stays enabled.
        let failed = try XCTUnwrap(ready.composeBlock(canSend: true, connectionText: "Connected", agentIDs: ["chatgptApp"], conversation: nil, prepareReasons: refused))
        XCTAssertEqual(failed, .prepareFailed("\(name): Check msgblast permissions on your Mac"))
        XCTAssertEqual(ready.composeBlock(canSend: true, connectionText: "", agentIDs: ["chatgptApp"], conversation: nil, prepareReasons: ["chatgptApp": "\(name) is still loading"]),
                       .prepareFailed("\(name) is still loading"), "A line that names the agent is not prefixed again")
        XCTAssertTrue(failed.allowsSend)
        XCTAssertNil(ready.composeBlock(canSend: true, connectionText: "Connected", agentIDs: ["chatgptApp"], conversation: nil, prepareReasons: [:]))
        XCTAssertEqual(ready.composeBlock(canSend: true, connectionText: "", agentIDs: ["chatgptApp"], conversation: nil, prepareReasons: ["": "Not ready"]), .prepareFailed("Not ready"))

        // Disconnection and the projection's own reasons still disable Send.
        let offline = try XCTUnwrap(ready.composeBlock(canSend: false, connectionText: MacConnectionState.reconnecting(attempt: 1, retryAt: Date()).statusText, agentIDs: ["chatgptApp"], conversation: nil, prepareReasons: refused))
        XCTAssertEqual(offline, .blocked("Reconnecting…")); XCTAssertFalse(offline.allowsSend)
        var busyState = state
        app.readiness = .busy(detail: "Sending")
        busyState.agents["chatgptApp"] = app
        let busy = ProjectionPresenter(state: busyState)
        XCTAssertFalse(try XCTUnwrap(busy.composeBlock(canSend: true, connectionText: "", agentIDs: ["chatgptApp"], conversation: nil, prepareReasons: refused)).allowsSend)

        // The prepare runs again by itself only when the refused agents can accept a send.
        XCTAssertFalse(busy.shouldRetryPrepare(prepareReasons: refused, agentIDs: ["chatgptApp"]))
        XCTAssertTrue(ready.shouldRetryPrepare(prepareReasons: refused, agentIDs: ["chatgptApp"]))
        XCTAssertFalse(ready.shouldRetryPrepare(prepareReasons: [:], agentIDs: ["chatgptApp"]), "Nothing to retry")
        XCTAssertNotEqual(busy.readiness(agentIDs: ["chatgptApp"]), ready.readiness(agentIDs: ["chatgptApp"]), "The view notices the change")
    }

    func testBlockedLinesKeepTheMacsLongerReasonAsDetail() throws {
        var state = try RecordedFixtures.reduce(["snapshot"])
        var app = try XCTUnwrap(state.agents["chatgptApp"])
        let usage = "An earlier request to ChatGPT did not complete. Review it before sending again; usage may have been consumed."
        app.readiness = .blocked
        app.reasons = [AvailabilityReason(code: .incompleteRequestBlocking, userText: "Finish the ChatGPT request first", fixOn: .phone, attemptID: "A1", detail: usage)]
        state.agents["chatgptApp"] = app
        let block = try XCTUnwrap(ProjectionPresenter(state: state).composeBlock(canSend: true, connectionText: "", agentIDs: ["chatgptApp"], conversation: nil, prepareReasons: [:]))
        XCTAssertEqual(block, .blocked("Finish the ChatGPT request first", detail: usage))
        XCTAssertFalse(block.allowsSend)
        XCTAssertEqual(ProjectionPresenter.agentStatus(app), "Finish the ChatGPT request first")
    }

    func testIncompleteSummaryRecipientsAndTimestamps() throws {
        var state = ProjectionState()
        let conversation = UUID(), started = Date(timeIntervalSince1970: 1_800_000_000)
        state.agents["museApp"] = AgentAvailability(agentID: "museApp", product: .muse, form: .macApp, displayName: "Muse", visibleInGrid: true, selectedForSharedSend: true,
            capabilities: AgentCapabilities(sharedSend: true, privateSend: true, attachments: false, namedCopies: false, endConversation: true, sharesOneConversation: false),
            readiness: .blocked, reasons: [AvailabilityReason(code: .incompleteRequestBlocking, userText: "Finish the Muse request first", fixOn: .phone, detail: "Usage may have been consumed.")],
            observedAt: started, source: .live)
        state.attempts["wa:1"] = RemoteAttempt(id: "wa:1", conversationID: conversation, agentID: "museApp", text: "Hi", status: .attempting, detail: "Outgoing message observed in the app. Waiting for its reply.", created: started)
        let incomplete = RemoteIncompleteAttempt(agentID: "museApp", attemptID: "wa:1", reasonCode: .incompleteRequestBlocking)
        let running = ProjectionPresenter(state: state).incompleteSummary(incomplete)
        XCTAssertTrue(running.running); XCTAssertEqual(running.title, "Waiting for Muse…"); XCTAssertEqual(running.started, started)
        XCTAssertEqual(running.details, ["Outgoing message observed in the app. Waiting for its reply.", "Usage may have been consumed."], "Every Mac reason stays reachable")
        state.attempts["wa:1"]?.status = .uncertain
        let review = ProjectionPresenter(state: state).incompleteSummary(incomplete)
        XCTAssertFalse(review.running); XCTAssertEqual(review.title, "Muse didn't reply")

        let presenter = ProjectionPresenter(state: state)
        XCTAssertEqual(presenter.recipientSummary(["museApp", "claude"], members: ["claude", "museApp"]), "To everyone")
        XCTAssertEqual(presenter.recipientSummary(["museApp"], members: ["claude", "museApp"]), "Only Muse")
        XCTAssertEqual(presenter.recipientSummary(["a", "b"], members: ["a", "b", "c"]), "To 2 agents")
        let chip = StatusChip(agentID: "museApp", agentName: "Muse", state: .sending, reason: nil)
        XCTAssertEqual(chip.label(showsName: false), "Sending"); XCTAssertEqual(chip.label(showsName: true), "Muse\u{00A0}·\u{00A0}Sending", "The separator never starts a line")

        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US")
        let now = Date(timeIntervalSince1970: 1_800_000_000)  // Friday 15 January 2027, 08:00 UTC
        XCTAssertEqual(ProjectionPresenter.inboxTimestamp(now.addingTimeInterval(-3600), now: now, calendar: calendar, locale: locale).replacingOccurrences(of: "\u{202F}", with: " "), "7:00 AM")
        XCTAssertEqual(ProjectionPresenter.inboxTimestamp(now.addingTimeInterval(-86_400), now: now, calendar: calendar, locale: locale), "Yesterday")
        XCTAssertEqual(ProjectionPresenter.inboxTimestamp(now.addingTimeInterval(-3 * 86_400), now: now, calendar: calendar, locale: locale), "Tuesday")
        XCTAssertEqual(ProjectionPresenter.inboxTimestamp(now.addingTimeInterval(-30 * 86_400), now: now, calendar: calendar, locale: locale), "12/16/26")
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

    func testAvatarsAreFetchedOnceCachedAndClearedByForget() async throws {
        let mac = FakeMac()
        let image = Data("png-bytes".utf8)
        let ref = "sha256:" + SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
        let lying = "sha256:" + String(repeating: "0", count: 64)
        mac.avatars = [ref: image, lying: Data("other".utf8)]
        func agent(_ id: String, _ avatarRef: String?) -> AgentAvailability {
            AgentAvailability(agentID: id, product: .claude, form: .website, displayName: id, avatarRef: avatarRef, visibleInGrid: true, selectedForSharedSend: true,
                              capabilities: AgentCapabilities(sharedSend: true, privateSend: true, attachments: false, namedCopies: false, endConversation: true, sharesOneConversation: false),
                              readiness: .ready, reasons: [], observedAt: Date(), source: .live)
        }
        mac.snapshot.agents = [agent("claude", ref), agent("copy", ref), agent("liar", lying), agent("old", "provider:grok"), agent("none", nil)]
        let database = try LocalDatabase(url: nil)
        let app = MobileApp(database: database, keys: MemoryDeviceKeyStore(), defaults: UserDefaults(suiteName: "msgblast-mobile-tests-\(UUID().uuidString)")!,
                            makeTransport: { [mac] in mac.transport(for: $0, spki: $1) })
        _ = try await app.pairAndWaitForInbox(offer: mac.offer(), deviceName: "Phone")
        for _ in 0..<200 where app.store.avatar(ref) == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(app.store.avatar(ref), image)
        XCTAssertNil(app.store.avatar(lying), "Bytes that do not match their reference are dropped")
        let fetches = mac.commands.compactMap { if case .fetchAvatar(let ref) = $0.action { ref } else { nil } }
        XCTAssertEqual(fetches.sorted(), [ref, lying].sorted(), "One request per content reference; other strings are never fetched")
        XCTAssertTrue(app.store.commands.isEmpty, "Artwork requests stay out of the command ledger")

        app.requestAvatars()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(mac.commands.filter { if case .fetchAvatar = $0.action { true } else { false } }.count, 2, "No retry storm")
        XCTAssertEqual(MobileStore(database: database).avatar(ref), image, "Cached across launches")
        app.forgetMac()
        XCTAssertTrue(app.store.avatars.isEmpty)
        XCTAssertNil(MobileStore(database: database).avatar(ref), "Forget This Mac clears the cache")
    }

    func testAnOlderMacLeavesInitials() async throws {
        let mac = FakeMac()
        mac.avatars = nil
        mac.snapshot.agents = [AgentAvailability(agentID: "claude", product: .claude, form: .website, displayName: "Claude", avatarRef: "sha256:" + String(repeating: "a", count: 64),
            visibleInGrid: true, selectedForSharedSend: true, capabilities: AgentCapabilities(sharedSend: true, privateSend: true, attachments: false, namedCopies: false, endConversation: true, sharesOneConversation: false),
            readiness: .ready, reasons: [], observedAt: Date(), source: .live)]
        let app = MobileApp(database: try LocalDatabase(url: nil), keys: MemoryDeviceKeyStore(), defaults: UserDefaults(suiteName: "msgblast-mobile-tests-\(UUID().uuidString)")!,
                            makeTransport: { [mac] in mac.transport(for: $0, spki: $1) })
        _ = try await app.pairAndWaitForInbox(offer: mac.offer(), deviceName: "Phone")
        for _ in 0..<100 where !mac.commands.contains(where: { if case .fetchAvatar = $0.action { true } else { false } }) { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(30))
        app.requestAvatars()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(app.store.avatars.isEmpty)
        XCTAssertEqual(mac.commands.filter { if case .fetchAvatar = $0.action { true } else { false } }.count, 1, "An unsupported answer is not repeated")
        XCTAssertEqual(app.connection.state, .connected, "No artwork is not an error")
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
