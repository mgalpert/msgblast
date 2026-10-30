import CryptoKit
import XCTest
@testable import msgblastCore
import msgblastRemoteProtocol

@MainActor
final class FakeRemoteHost: RemoteCommandHost {
    var isLocked = false
    var messagesSendsAllowed = false
    var isBusy = false
    var agents: [String: AgentAvailability] = [:]
    var conversations: [UUID: RemoteConversationState] = [:]
    var sends: [RemoteSendPlan] = []
    var running = 0, maximumConcurrent = 0
    var sendDelay: Duration = .zero
    var staged: [String: (Data, String)] = [:]
    var keepAwake: [Bool] = []
    var ended: [UUID] = []
    var acknowledged: [(String, String?)] = []
    func availability(for agentID: String) -> AgentAvailability? { agents[agentID] }
    func conversation(_ id: UUID) -> RemoteConversationState? { conversations[id] }
    func performSend(_ plan: RemoteSendPlan) async -> RemoteHostResult {
        running += 1; maximumConcurrent = max(maximumConcurrent, running)
        defer { running -= 1 }
        sends.append(plan)
        if sendDelay > .zero { try? await Task.sleep(for: sendDelay) }
        let id = plan.conversationID ?? UUID()
        return .applied(conversationID: id, statuses: Dictionary(uniqueKeysWithValues: plan.agentIDs.map { ($0, .observed) }))
    }
    func endConversation(_ id: UUID) -> RemoteHostResult { ended.append(id); return .applied(conversationID: id) }
    func acknowledgeIncomplete(agentID: String, attemptID: String?) -> RemoteHostResult { acknowledged.append((agentID, attemptID)); return .applied() }
    func cancelNative(agentID: String) -> RemoteHostResult { .applied() }
    /// When set, keep-awake requests drive a real controller as `AppRemoteHost` does.
    var keepAwakeController: RemoteKeepAwake?
    func setKeepAwake(_ enabled: Bool) -> RemoteHostResult {
        keepAwake.append(enabled)
        guard let keepAwakeController else { return .applied() }
        return keepAwakeController.setClientRequested(enabled) ? .applied() : .rejected(.keepAwakeDisabled, "Keep awake is off on your Mac")
    }
    func stageAttachment(_ data: Data, filename: String) throws -> String { let id = UUID().uuidString; staged[id] = (data, filename); return id }
    func hasStagedAttachment(_ id: String) -> Bool { staged[id] != nil }
    func requestReport(_ id: UUID) async -> RemoteHostResult { .applied(conversationID: id) }
    var prepared: [[String]] = []
    /// The reason the Mac's session reports for an agent that is not ready.
    var notReadyReason = "Sign in"
    var avatars: [String: Data] = [:]
    var avatarReads = 0
    func avatar(_ ref: String) -> Data? { avatarReads += 1; return avatars[ref] }
    func prepareConversation(_ id: UUID?, agentIDs: [String]) async -> RemoteHostResult {
        prepared.append(agentIDs)
        let waiting = agentIDs.filter { agents[$0]?.readiness.acceptsSend == false }
        return waiting.isEmpty ? .applied(conversationID: id) : .rejected(.notReady, "Not ready", reasons: Dictionary(uniqueKeysWithValues: waiting.map { ($0, notReadyReason) }))
    }

    static func agent(_ id: String, form: AgentForm = .website, readiness: AgentReadiness = .ready, privateSend: Bool = true) -> AgentAvailability {
        AgentAvailability(agentID: id, product: form == .messages ? .messages : .claude, form: form, displayName: id, visibleInGrid: true, selectedForSharedSend: false,
            capabilities: AgentCapabilities(sharedSend: true, privateSend: privateSend, attachments: form == .messages, namedCopies: false, endConversation: true, sharesOneConversation: false),
            readiness: readiness, reasons: readiness.acceptsSend ? [] : [AvailabilityReason(code: .signedOut, userText: "Sign in to \(id) on your Mac", fixOn: .mac)],
            observedAt: Date(), source: .live)
    }
}

@MainActor
final class RemoteCommandExecutorTests: XCTestCase {
    private func host() -> FakeRemoteHost {
        let host = FakeRemoteHost()
        for id in ["claude", "chatgptApp", "claudeApp"] { host.agents[id] = FakeRemoteHost.agent(id, form: id.hasSuffix("App") ? .macApp : .website) }
        host.agents["messages:A"] = FakeRemoteHost.agent("messages:A", form: .messages)
        return host
    }

    func testReplayedCommandIDsNeverRepeatASend() async {
        let host = host()
        let executor = RemoteCommandExecutor(host: host)
        let command = RemoteCommand(action: .createConversation(text: "Compare", agentIDs: ["claude"], attachmentIDs: []))
        let first = await executor.execute(command)
        XCTAssertEqual(first.outcome, .applied); XCTAssertFalse(first.replayed)
        let replay = await executor.execute(command)
        XCTAssertEqual(replay.outcome, .applied); XCTAssertTrue(replay.replayed)
        XCTAssertEqual(replay.conversationID, first.conversationID)
        XCTAssertEqual(host.sends.count, 1, "A replay returns the stored result")

        // A replay while the first copy is still running reports progress, not a second send.
        host.sendDelay = .milliseconds(80)
        let slow = RemoteCommand(action: .createConversation(text: "Slow", agentIDs: ["claude"], attachmentIDs: []))
        var replies: [RemoteCommandResult] = []
        executor.submit(slow) { replies.append($0) }
        try? await Task.sleep(for: .milliseconds(10))
        executor.submit(slow) { replies.append($0) }
        for _ in 0..<50 where replies.count < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(replies.map(\.outcome), [.accepted, .applied])
        XCTAssertTrue(replies[0].replayed)
        XCTAssertEqual(host.sends.count, 2)
    }

    func testSendsRunOneAtATimeAndRecheckAtTheHead() async {
        let host = host()
        host.sendDelay = .milliseconds(40)
        let executor = RemoteCommandExecutor(host: host)
        var results: [UUID: [RemoteCommandResult.Outcome]] = [:]
        let commands = ["chatgptApp", "claudeApp", "claude"].map { RemoteCommand(action: .createConversation(text: "To \($0)", agentIDs: [$0], attachmentIDs: [])) }
        for command in commands { executor.submit(command) { results[command.clientCommandID, default: []].append($0.outcome) } }
        XCTAssertEqual(results[commands[1].clientCommandID], [.accepted], "A queued desktop send is accepted, not refused")
        for _ in 0..<100 where host.sends.count < 3 || executor.isSending { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(host.maximumConcurrent, 1, "Mac app requests stay serial across commands")
        XCTAssertEqual(host.sends.map(\.agentIDs), [["chatgptApp"], ["claudeApp"], ["claude"]])
        XCTAssertEqual(results[commands[2].clientCommandID], [.accepted, .applied])

        // The Mac started its own send while a remote one waited: the queued one is refused, not retried later.
        host.sends = []
        let first = RemoteCommand(action: .createConversation(text: "One", agentIDs: ["claude"], attachmentIDs: []))
        let second = RemoteCommand(action: .createConversation(text: "Two", agentIDs: ["claude"], attachmentIDs: []))
        var secondResult: RemoteCommandResult?
        executor.submit(first) { _ in host.isBusy = true }
        executor.submit(second) { if $0.outcome != .accepted { secondResult = $0 } }
        for _ in 0..<100 where secondResult == nil { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(secondResult?.code, .macBusy)
        XCTAssertEqual(host.sends.count, 1)
    }

    func testGuardsRejectBeforeAnythingIsSent() async {
        let host = host()
        let executor = RemoteCommandExecutor(host: host)
        func run(_ action: RemoteAction) async -> RemoteCommandResult { await executor.execute(RemoteCommand(action: action)) }

        host.isLocked = true
        do { let result = await run(.createConversation(text: "Hi", agentIDs: ["claude"], attachmentIDs: [])); XCTAssertEqual(result.code, .macLocked) }
        do { let result = await run(.setKeepAwake(enabled: true)); XCTAssertEqual(result.outcome, .applied, "Keep-awake is the one command a locked Mac accepts") }
        host.isLocked = false

        do { let result = await run(.createConversation(text: "Hi", agentIDs: ["messages:A"], attachmentIDs: [])); XCTAssertEqual(result.code, .messagesSendsOff, "iMessage sends from the phone are off by default") }
        host.messagesSendsAllowed = true
        do { let result = await run(.createConversation(text: "Hi", agentIDs: ["messages:A"], attachmentIDs: [])); XCTAssertEqual(result.outcome, .applied) }

        host.agents["claude"] = FakeRemoteHost.agent("claude", readiness: .blocked)
        let blocked = await run(.createConversation(text: "Hi", agentIDs: ["claude"], attachmentIDs: []))
        XCTAssertEqual(blocked.code, .agentUnavailable); XCTAssertEqual(blocked.message, "Sign in to claude on your Mac")
        do { let result = await run(.createConversation(text: "Hi", agentIDs: ["nobody"], attachmentIDs: [])); XCTAssertEqual(result.code, .unknownAgent) }
        do { let result = await run(.createConversation(text: "   ", agentIDs: ["chatgptApp"], attachmentIDs: [])); XCTAssertEqual(result.code, .invalidCommand) }
        do { let result = await run(.createConversation(text: "Hi", agentIDs: [], attachmentIDs: [])); XCTAssertEqual(result.code, .invalidCommand) }
        do { let result = await run(.createConversation(text: "Hi", agentIDs: ["chatgptApp", "chatgptApp"], attachmentIDs: [])); XCTAssertEqual(result.code, .invalidCommand) }
        host.agents["chatgptApp"] = FakeRemoteHost.agent("chatgptApp", form: .macApp, readiness: .readyWillLaunch)
        do { let result = await run(.createConversation(text: "Hi", agentIDs: ["chatgptApp"], attachmentIDs: [])); XCTAssertEqual(result.outcome, .applied, "readyWillLaunch accepts sends") }

        let gone = UUID(), ended = UUID(), active = UUID()
        host.conversations = [ended: .ended, active: .active(members: ["chatgptApp", "messages:A"])]
        do { let result = await run(.sendShared(conversationID: gone, text: "More", agentIDs: [], attachmentIDs: [])); XCTAssertEqual(result.code, .unknownConversation) }
        do { let result = await run(.sendShared(conversationID: ended, text: "More", agentIDs: [], attachmentIDs: [])); XCTAssertEqual(result.code, .conversationEnded) }
        do { let result = await run(.sendShared(conversationID: active, text: "More", agentIDs: ["claudeApp"], attachmentIDs: [])); XCTAssertEqual(result.code, .invalidCommand, "Shared sends go to members only") }
        do { let result = await run(.sendShared(conversationID: active, text: "More", agentIDs: [], attachmentIDs: [])); XCTAssertEqual(result.outcome, .applied) }
        XCTAssertEqual(host.sends.last?.conversationID, active)
        host.agents["hark"] = FakeRemoteHost.agent("hark", readiness: .unavailable)
        host.agents["hark"]!.capabilities.sharedSend = false
        host.conversations[active] = .active(members: ["chatgptApp", "messages:A", "hark"])
        do { let result = await run(.sendShared(conversationID: active, text: "Everyone", agentIDs: [], attachmentIDs: [])); XCTAssertEqual(result.outcome, .applied, "Members without shared sends are skipped, not a refusal") }
        do { let result = await run(.teleport()); XCTAssertEqual(result.code, .unsupported) }
        do { let result = await run(.sendPrivate(conversationID: active, agentID: "chatgptApp", text: "Only you", attachmentIDs: [])); XCTAssertEqual(result.outcome, .applied) }
        host.agents["os3"] = FakeRemoteHost.agent("os3", privateSend: false)
        do { let result = await run(.sendPrivate(conversationID: nil, agentID: "os3", text: "Only you", attachmentIDs: [])); XCTAssertEqual(result.code, .agentUnavailable) }
    }

    func testUploadsStageOnlyVerifiedFilesForMessagesAgents() async {
        let host = host()
        host.messagesSendsAllowed = true
        let executor = RemoteCommandExecutor(host: host)
        func run(_ action: RemoteAction) async -> RemoteCommandResult { await executor.execute(RemoteCommand(action: action)) }
        let upload = UUID(), bytes = Data(repeating: 7, count: 300_000)
        let parts = [bytes.prefix(200_000), bytes.suffix(100_000)].map { Data($0) }
        do { let result = await run(.uploadAttachmentChunk(uploadID: upload, filename: "photo.png", index: 1, count: 2, data: parts[1])); XCTAssertEqual(result.outcome, .applied) }
        do { let result = await run(.attachStaged(uploadID: upload, sha256: Data(SHA256.hash(data: bytes)))); XCTAssertEqual(result.code, .attachmentRejected, "Incomplete uploads are refused") }
        let retry = UUID()
        for (index, part) in parts.enumerated() { _ = await run(.uploadAttachmentChunk(uploadID: retry, filename: "photo.png", index: index, count: 2, data: part)) }
        let staged = await run(.attachStaged(uploadID: retry, sha256: Data(SHA256.hash(data: bytes))))
        let attachment = try? XCTUnwrap(staged.attachmentID)
        XCTAssertEqual(host.staged[attachment ?? ""]?.0, bytes); XCTAssertEqual(host.staged[attachment ?? ""]?.1, "photo.png")

        let corrupt = UUID()
        _ = await run(.uploadAttachmentChunk(uploadID: corrupt, filename: "a.txt", index: 0, count: 1, data: Data("abc".utf8)))
        do { let result = await run(.attachStaged(uploadID: corrupt, sha256: Data(repeating: 0, count: 32))); XCTAssertEqual(result.code, .attachmentRejected) }
        do { let result = await run(.uploadAttachmentChunk(uploadID: UUID(), filename: "../../etc/passwd", index: 0, count: 1, data: Data([1]))); XCTAssertEqual(result.outcome, .applied, "Paths reduce to a file name") }
        do { let result = await run(.uploadAttachmentChunk(uploadID: UUID(), filename: ".hidden", index: 0, count: 1, data: Data([1]))); XCTAssertEqual(result.code, .attachmentRejected) }
        do { let result = await run(.uploadAttachmentChunk(uploadID: UUID(), filename: "a", index: 0, count: 500, data: Data([1]))); XCTAssertEqual(result.code, .attachmentRejected) }
        do { let result = await run(.uploadAttachmentChunk(uploadID: UUID(), filename: "a", index: 0, count: 1, data: Data(count: RemoteProtocol.maximumAttachmentChunkBytes + 1))); XCTAssertEqual(result.code, .attachmentRejected) }

        do { let result = await run(.createConversation(text: "See file", agentIDs: ["claude"], attachmentIDs: [attachment ?? ""])); XCTAssertEqual(result.code, .attachmentRejected, "Website agents never take files") }
        do { let result = await run(.createConversation(text: "See file", agentIDs: ["messages:A"], attachmentIDs: ["missing"])); XCTAssertEqual(result.code, .attachmentRejected) }
        do { let result = await run(.createConversation(text: "", agentIDs: ["messages:A"], attachmentIDs: [attachment ?? ""])); XCTAssertEqual(result.outcome, .applied, "An attachment alone is a message") }
        XCTAssertEqual(host.sends.last?.attachmentIDs, [attachment ?? ""])
    }

    func testPreparationRunsSeriallyAndQueriesNeverRun() async {
        let host = host()
        host.sendDelay = .milliseconds(40)
        let executor = RemoteCommandExecutor(host: host)
        let send = RemoteCommand(action: .createConversation(text: "One", agentIDs: ["claude"], attachmentIDs: []))
        var order: [String] = []
        executor.submit(send) { if $0.outcome != .accepted { order.append("send") } }
        let prepare = RemoteCommand(action: .prepareConversation(conversationID: nil, agentIDs: ["claude", "chatgptApp"]))
        executor.submit(prepare) { if $0.outcome != .accepted { order.append("prepare") } }
        for _ in 0..<100 where order.count < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(order, ["send", "prepare"], "Preparation waits behind a running send")
        XCTAssertEqual(host.prepared, [["claude", "chatgptApp"]])
        host.agents["claude"] = FakeRemoteHost.agent("claude", readiness: .blocked)
        let blocked = await executor.execute(RemoteCommand(action: .prepareConversation(conversationID: nil, agentIDs: ["claude"])))
        XCTAssertEqual(blocked.code, .notReady); XCTAssertEqual(blocked.agentReasons, ["claude": "Sign in"])
        do { let result = await executor.execute(RemoteCommand(action: .prepareConversation(conversationID: nil, agentIDs: ["nobody"]))); XCTAssertEqual(result.code, .unknownAgent) }

        // Queries report stored, running, or unknown commands and never run anything.
        let stored = await executor.execute(RemoteCommand(action: .queryCommand(clientCommandID: send.clientCommandID)))
        XCTAssertEqual(stored.clientCommandID, send.clientCommandID); XCTAssertEqual(stored.outcome, .applied); XCTAssertTrue(stored.replayed)
        let unknown = UUID()
        let missing = await executor.execute(RemoteCommand(action: .queryCommand(clientCommandID: unknown)))
        XCTAssertEqual(missing.clientCommandID, unknown); XCTAssertEqual(missing.code, .unknownCommand)
        XCTAssertEqual(host.sends.count, 1)
    }

    func testASignedOutWebsiteAgentsReasonNamesTheMacNotThePane() async {
        let host = host()
        var os3 = FakeRemoteHost.agent("os3", readiness: .blocked)
        os3.displayName = "rabbit OS3"
        host.agents["os3"] = os3
        // The exact text the Mac's web session gives when the comparison chat cannot open.
        host.notReadyReason = "rabbit OS3’s comparison chat could not open. Open it in this pane and sign in if needed. Nothing was sent."
        let executor = RemoteCommandExecutor(host: host)
        let result = await executor.execute(RemoteCommand(action: .prepareConversation(conversationID: nil, agentIDs: ["os3"])))
        let reason = try? XCTUnwrap(result.agentReasons["os3"])
        XCTAssertEqual(reason, "Open rabbit OS3 on your Mac and sign in", "The phone gets one short line")
        XCTAssertFalse(reason?.lowercased().contains("pane") ?? true)
        XCTAssertEqual(RemotePhoneText.split(host.notReadyReason, agentName: "rabbit OS3").detail,
                       "rabbit OS3’s comparison chat could not open. Open rabbit OS3 on your Mac and sign in if needed.",
                       "The full reason stays available as the detail, without the clause the chip already shows")

        // Other Mac reasons that point at the Mac's screen also name the Mac.
        for (mac, phone) in [
            ("Open this agent to sign in here.", "Open rabbit OS3 on your Mac and sign in."),
            ("rabbit OS3 already has a draft. Send or clear it in the page first.", "rabbit OS3 already has a draft. Send or clear it on your Mac first."),
            ("rabbit OS3’s page layout is not recognized yet. Reload the page and try again.", "rabbit OS3’s page layout is not recognized yet. Reload rabbit OS3 on your Mac and try again."),
            ("The page did not accept text. Use its composer directly.", "The page did not accept text. Use rabbit OS3 directly on your Mac."),
            ("Open the intended conversation in Claude, then connect it here.", "Open the intended conversation in Claude, then connect it on your Mac."),
            ("Finish the open dialog in rabbit OS3 first.", "Finish the open dialog in rabbit OS3 on your Mac first."),
        ] {
            XCTAssertEqual(RemotePhoneText.phrase(mac, agentName: "rabbit OS3"), phone)
        }
        XCTAssertEqual(RemotePhoneText.phrase("Sign in to rabbit OS3 on your Mac", agentName: "rabbit OS3"), "Sign in to rabbit OS3 on your Mac",
                       "Reasons already written for the phone are unchanged")
        XCTAssertEqual(RemotePhoneText.phrase("Sign in to rabbit OS3 in msgblast on your Mac.", agentName: "rabbit OS3"), "Sign in to rabbit OS3 on your Mac.",
                       "The app is implied: \"on your Mac\" is enough")
    }

    func testDesktopDriverMessagesGetShortFormsWithTheFullTextAsDetail() {
        let cases: [(String, String?, String)] = [
            ("App control could not complete this request. Review msgblast permissions; nothing will be retried automatically.", "Muse", "Check msgblast permissions on your Mac"),
            ("The app is still updating its controls. No input was sent.", "Muse", "Muse is still loading"),
            ("Keep one main Muse window open and dismiss any dialogs before connecting.", nil, "Open one Muse window on your Mac"),
            ("Outgoing message observed in the app. Waiting for its reply.", nil, "Sent, waiting for a reply"),
            ("Finish the open dialog in Claude first.", "Claude", "Close Claude’s dialog on your Mac"),
        ]
        for (mac, name, short) in cases {
            let line = RemotePhoneText.split(mac, agentName: name)
            XCTAssertEqual(line.text, short)
            XCTAssertLessThanOrEqual(line.text.count, 40)
            XCTAssertEqual(line.detail, RemotePhoneText.phrase(mac, agentName: name), "The Mac's full reason is kept")
        }
        XCTAssertEqual(RemotePhoneText.phrase("App control could not complete this request. Review msgblast permissions; nothing will be retried automatically."),
                       "App control could not complete this request. Review msgblast permissions.")
        let plain = RemotePhoneText.split("Sign in to Claude on your Mac")
        XCTAssertEqual(plain.text, "Sign in to Claude on your Mac"); XCTAssertNil(plain.detail, "Short text has no separate detail")
    }

    func testFetchAvatarReturnsTheBytesAndRejectsUnknownRefs() async {
        let host = host()
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        host.avatars["sha256:abc"] = bytes
        host.isLocked = true
        let executor = RemoteCommandExecutor(host: host)
        let command = RemoteCommand(action: .fetchAvatar(ref: "sha256:abc"))
        let first = await executor.execute(command)
        XCTAssertEqual(first.outcome, .applied, "Read-only artwork is served even while locked"); XCTAssertEqual(first.avatar, bytes)
        let again = await executor.execute(command)
        XCTAssertEqual(again.avatar, bytes, "Repeating the same command gives the same bytes")
        XCTAssertFalse(again.replayed, "Artwork is not kept in the ledger")
        let unknown = await executor.execute(RemoteCommand(action: .fetchAvatar(ref: "sha256:missing")))
        XCTAssertEqual(unknown.outcome, .rejected); XCTAssertEqual(unknown.code, .unknownAvatar); XCTAssertNil(unknown.avatar)
        XCTAssertEqual(unknown.message, "No artwork for that agent")
        let foreign = await executor.execute(RemoteCommand(action: .fetchAvatar(ref: "provider:claude")))
        XCTAssertEqual(foreign.code, .unknownAvatar, "Only content references are served")
        host.avatars["sha256:big"] = Data(count: RemoteProtocol.maximumAvatarBytes + 1)
        let big = await executor.execute(RemoteCommand(action: .fetchAvatar(ref: "sha256:big")))
        XCTAssertEqual(big.code, .unknownAvatar, "Oversized artwork is never sent")
    }

    func testNonSendCommandsReachTheHost() async {
        let host = host()
        let executor = RemoteCommandExecutor(host: host)
        let active = UUID(), ended = UUID()
        host.conversations = [active: .active(members: []), ended: .ended]
        do { let result = await executor.execute(RemoteCommand(action: .endConversation(conversationID: active))); XCTAssertEqual(result.outcome, .applied) }
        do { let result = await executor.execute(RemoteCommand(action: .endConversation(conversationID: ended))); XCTAssertEqual(result.message, "Already ended") }
        XCTAssertEqual(host.ended, [active])
        _ = await executor.execute(RemoteCommand(action: .acknowledgeIncomplete(agentID: "chatgptApp", attemptID: "X")))
        XCTAssertEqual(host.acknowledged.first?.1, "X")
        _ = await executor.execute(RemoteCommand(action: .setKeepAwake(enabled: true)))
        XCTAssertEqual(host.keepAwake, [true])
        do { let result = await executor.execute(RemoteCommand(action: .requestReport(conversationID: ended))); XCTAssertEqual(result.code, .unknownConversation) }
    }
}

private extension RemoteAction {
    static func teleport() -> RemoteAction { .unknown(kind: "teleport") }
}
