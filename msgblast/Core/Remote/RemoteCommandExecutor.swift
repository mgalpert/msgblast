import CryptoKit
import Foundation
import msgblastRemoteProtocol

/// What a remote send asks the Mac to do, after the executor's checks.
public struct RemoteSendPlan: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case newConversation, sharedFollowUp, privateMessage }
    public var kind: Kind
    public var conversationID: UUID?
    public var text: String
    public var agentIDs: [String]
    public var attachmentIDs: [String]
}

public struct RemoteHostResult: Sendable, Equatable {
    public var applied: Bool
    public var code: RemoteRejectionCode?
    public var message: String?
    public var conversationID: UUID?
    public var agentStatuses: [String: RemoteAttemptStatus]
    public var agentReasons: [String: String] = [:]
    public static func applied(conversationID: UUID? = nil, statuses: [String: RemoteAttemptStatus] = [:], message: String? = nil) -> Self {
        Self(applied: true, code: nil, message: message, conversationID: conversationID, agentStatuses: statuses)
    }
    public static func rejected(_ code: RemoteRejectionCode, _ message: String, conversationID: UUID? = nil, reasons: [String: String] = [:]) -> Self {
        Self(applied: false, code: code, message: message, conversationID: conversationID, agentStatuses: [:], agentReasons: reasons)
    }
}

/// Rewrites Mac reasons that point at the Mac's own screen ("this pane", "here", "the page")
/// so they make sense on the phone, and gives long desktop-driver messages a short form.
/// Every reason and message the phone sees passes through it. The phone never parses
/// sentences: a short form travels as the line to show, the full reason as its detail.
public enum RemotePhoneText {
    public static func phrase(_ text: String, agentName: String? = nil) -> String {
        let name = agentName.flatMap { $0.isEmpty ? nil : $0 } ?? "it"
        var text = text
        let exact: [(String, String)] = [
            ("Open it in this pane and sign in if needed.", "Open \(name) on your Mac and sign in if needed."),
            ("Open this agent to sign in here.", "Open \(name) on your Mac and sign in."),
            ("then connect it here.", "then connect it on your Mac."),
            ("Reload the page and try again.", "Reload \(name) on your Mac and try again."),
            ("Use its composer directly.", "Use \(name) directly on your Mac."),
            ("composer directly.", "composer directly on your Mac."),
            ("continue in the page", "continue on your Mac"),
            ("in the page first.", "on your Mac first."),
        ]
        for (mac, phone) in exact { text = text.replacingOccurrences(of: mac, with: phone) }
        if text.hasPrefix("Finish the open dialog in "), !text.contains("on your Mac"), text.hasSuffix(" first.") {
            text = String(text.dropLast(" first.".count)) + " on your Mac first."
        }
        // Anything left that still names the Mac's screen, or names the app the phone already implies.
        for mac in ["in this pane", "in this window", "in the page", "in msgblast on your Mac"] { text = text.replacingOccurrences(of: mac, with: "on your Mac") }
        // The phone shows what was not sent through state; these clauses only repeat it.
        for clause in [" Nothing was sent.", " Nothing was submitted.", " No input was sent."] where text.hasSuffix(clause) && text.count > clause.count {
            text = String(text.dropLast(clause.count))
        }
        text = text.replacingOccurrences(of: "; nothing will be retried automatically.", with: ".")
        return text
    }

    /// A glanceable form (about 40 characters, no trailing period) of a long Mac message
    /// the phone shows inline, or nil when the message has none. The caller keeps
    /// `phrase(text)` as the detail.
    public static func short(_ text: String, agentName: String? = nil) -> String? {
        let named = agentName.flatMap { $0.isEmpty ? nil : $0 }
        if text.contains("App control could not complete this request") { return "Check msgblast permissions on your Mac" }
        if text.contains("still updating its controls") || text.contains("controls are still updating") { return "\(named ?? "The app") is still loading" }
        if let app = between(text, "Keep one main ", " window open") { return "Open one \(app.isEmpty ? named ?? "app" : app) window on your Mac" }
        if text.hasPrefix("Outgoing message observed in the app") { return "Sent, waiting for a reply" }
        if text.contains("comparison chat could not open") { return "Open \(named ?? "it") on your Mac and sign in" }
        if let app = between(text, "Finish the open dialog in ", " on your Mac first.") ?? between(text, "Finish the open dialog in ", " first.") {
            return "Close \(app)’s dialog on your Mac"
        }
        if text.hasPrefix("Wait for"), text.hasSuffix("current reply.") { return "\(named ?? "It") is still replying" }
        if text.contains("already has a draft") { return "Clear the draft in \(named ?? "it") on your Mac" }
        if text.contains("page layout is not recognized") { return "Reload \(named ?? "it") on your Mac" }
        return nil
    }

    /// The text between a prefix and the first following marker; "" when they touch.
    private static func between(_ text: String, _ prefix: String, _ marker: String) -> String? {
        if text.hasPrefix(prefix.trimmingCharacters(in: .whitespaces) + marker) { return "" }
        guard text.hasPrefix(prefix), let range = text.range(of: marker, range: text.index(text.startIndex, offsetBy: prefix.count)..<text.endIndex) else { return nil }
        return String(text[text.index(text.startIndex, offsetBy: prefix.count)..<range.lowerBound])
    }

    /// The line to show and, when it was shortened, the full reason as its detail.
    public static func split(_ text: String, agentName: String? = nil) -> (text: String, detail: String?) {
        let full = phrase(text, agentName: agentName)
        guard let short = short(text, agentName: agentName), short != full else { return (full, nil) }
        return (short, full)
    }
}

public enum RemoteConversationState: Sendable, Equatable { case active(members: [String]), ended }

/// The Mac side the executor drives. The app implements it over AppModel and the
/// same send paths the Mac UI uses; tests implement it with fakes.
@MainActor
public protocol RemoteCommandHost: AnyObject {
    var isLocked: Bool { get }
    var messagesSendsAllowed: Bool { get }
    /// The Mac itself is sending (Messages busy, a shared send, or any session sending).
    var isBusy: Bool { get }
    func availability(for agentID: String) -> AgentAvailability?
    func conversation(_ id: UUID) -> RemoteConversationState?
    func performSend(_ plan: RemoteSendPlan) async -> RemoteHostResult
    /// Runs the existing prepare paths for these agents and waits for readiness. Never sends or launches apps.
    func prepareConversation(_ id: UUID?, agentIDs: [String]) async -> RemoteHostResult
    func endConversation(_ id: UUID) -> RemoteHostResult
    func acknowledgeIncomplete(agentID: String, attemptID: String?) -> RemoteHostResult
    func cancelNative(agentID: String) -> RemoteHostResult
    func setKeepAwake(_ enabled: Bool) -> RemoteHostResult
    func stageAttachment(_ data: Data, filename: String) throws -> String
    func hasStagedAttachment(_ id: String) -> Bool
    func requestReport(_ id: UUID) async -> RemoteHostResult
    /// The normalized artwork an agent's `avatarRef` names, or nil when the Mac has none.
    func avatar(_ ref: String) -> Data?
}

public extension RemoteCommandHost {
    func avatar(_ ref: String) -> Data? { nil }
}

/// Applies phone commands. Idempotent by `clientCommandID`: a replay returns the
/// stored (or in-progress) result and never repeats the action. Sends run one at a
/// time, so Mac app requests stay serial across commands; nothing is ever retried.
@MainActor
public final class RemoteCommandExecutor {
    public static let ledgerCapacity = 1000
    public static let maximumUploadChunks = 128
    private weak var host: (any RemoteCommandHost)?
    private var ledger: [UUID: RemoteCommandResult] = [:]
    private var ledgerOrder: [UUID] = []
    private var inProgress: Set<UUID> = []
    private var sendQueue: [(RemoteCommand, (RemoteCommandResult) -> Void)] = []
    private var sending = false
    private var uploads: [UUID: Upload] = [:]
    private struct Upload { var filename: String; var count: Int; var chunks: [Int: Data] = [:]; var bytes = 0 }

    public init(host: any RemoteCommandHost) { self.host = host }

    public var queuedSendCount: Int { sendQueue.count }
    public var isSending: Bool { sending }

    /// Calls `reply` once with the final result, or first with `accepted` when a send
    /// waits behind another and then again with its final result.
    public func submit(_ command: RemoteCommand, reply: @escaping (RemoteCommandResult) -> Void) {
        let id = command.clientCommandID
        if case .queryCommand(let target) = command.action { reply(status(of: target)); return }
        // Read-only and repeatable: answered at once, even while locked, and kept out of the
        // ledger so artwork bytes are not held for replay.
        if case .fetchAvatar(let ref) = command.action { reply(avatar(command, ref: ref)); return }
        if var stored = ledger[id] { stored.replayed = true; reply(stored); return }
        if inProgress.contains(id) { reply(RemoteCommandResult(clientCommandID: id, outcome: .accepted, message: "Already running on your Mac", replayed: true)); return }
        if command.action.isSerial {
            if let rejection = command.action.isSend ? checkSend(command) : checkPrepare(command) { finish(rejection, reply); return }
            inProgress.insert(id)
            if sending { reply(RemoteCommandResult(clientCommandID: id, outcome: .accepted, message: "Waiting for the previous request")) }
            sendQueue.append((command, reply))
            drain()
            return
        }
        inProgress.insert(id)
        Task { @MainActor in self.finish(await self.apply(command), reply) }
    }

    /// Convenience for tests and the in-memory transport: the final result only.
    public func execute(_ command: RemoteCommand) async -> RemoteCommandResult {
        await withCheckedContinuation { continuation in
            var resumed = false
            submit(command) { result in
                guard result.outcome != .accepted || result.replayed, !resumed else { return }
                resumed = true
                continuation.resume(returning: result)
            }
        }
    }

    private func finish(_ result: RemoteCommandResult, _ reply: (RemoteCommandResult) -> Void) {
        let id = result.clientCommandID
        inProgress.remove(id)
        ledger[id] = result
        ledgerOrder.append(id)
        if ledgerOrder.count > Self.ledgerCapacity { ledger[ledgerOrder.removeFirst()] = nil }
        reply(result)
    }

    private func drain() {
        guard !sending, !sendQueue.isEmpty else { return }
        sending = true
        let (command, reply) = sendQueue.removeFirst()
        Task { @MainActor in
            // Re-check at the head of the queue: the Mac may have locked or started its own send.
            let result: RemoteCommandResult
            if let rejection = command.action.isSend ? self.checkSend(command, atHead: true) : self.checkPrepare(command, atHead: true) { result = rejection }
            else { result = await self.runSend(command) }
            self.finish(result, reply)
            self.sending = false
            self.drain()
        }
    }

    private func reject(_ command: RemoteCommand, _ code: RemoteRejectionCode, _ message: String) -> RemoteCommandResult {
        .rejected(command.clientCommandID, code, message)
    }

    private func plan(_ command: RemoteCommand) -> RemoteSendPlan? {
        switch command.action {
        case .createConversation(let text, let agents, let files): RemoteSendPlan(kind: .newConversation, conversationID: nil, text: text, agentIDs: agents, attachmentIDs: files)
        case .sendShared(let id, let text, let agents, let files): RemoteSendPlan(kind: .sharedFollowUp, conversationID: id, text: text, agentIDs: agents, attachmentIDs: files)
        case .sendPrivate(let id, let agent, let text, let files): RemoteSendPlan(kind: .privateMessage, conversationID: id, text: text, agentIDs: [agent], attachmentIDs: files)
        default: nil
        }
    }

    private func checkSend(_ command: RemoteCommand, atHead: Bool = false) -> RemoteCommandResult? {
        guard let host else { return reject(command, .failed, "Remote control stopped on your Mac") }
        guard !host.isLocked else { return reject(command, .macLocked, "Your Mac is locked") }
        guard let plan = plan(command) else { return reject(command, .invalidCommand, "Not a send.") }
        if atHead && host.isBusy { return reject(command, .macBusy, "Your Mac is busy. Try again soon") }
        let text = plan.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !plan.attachmentIDs.isEmpty else { return reject(command, .invalidCommand, "Write a message first") }
        guard plan.kind != .newConversation || !plan.agentIDs.isEmpty else { return reject(command, .invalidCommand, "Choose at least one agent") }
        guard Set(plan.agentIDs).count == plan.agentIDs.count else { return reject(command, .invalidCommand, "An agent is listed twice") }
        var members: [String]?
        if let id = plan.conversationID {
            switch host.conversation(id) {
            case nil: return reject(command, .unknownConversation, "This conversation is gone from your Mac")
            case .ended?: return reject(command, .conversationEnded, "This conversation has ended")
            case .active(let list)?: members = list
            }
        }
        if plan.kind == .sharedFollowUp, let members, let outsider = plan.agentIDs.first(where: { !members.contains($0) }) {
            return reject(command, .invalidCommand, "\(outsider) isn't in this conversation")
        }
        // "Everyone" means every member that takes shared messages (Hark does not), as on the Mac.
        let targets = plan.agentIDs.isEmpty ? (members ?? []).filter { host.availability(for: $0)?.capabilities.sharedSend != false } : plan.agentIDs
        var messagesTargets = 0
        for agentID in targets {
            guard let availability = host.availability(for: agentID) else { return reject(command, .unknownAgent, "An agent is gone from your Mac") }
            if availability.form == .messages {
                messagesTargets += 1
                guard host.messagesSendsAllowed else {
                    return reject(command, .messagesSendsOff, "Turn on iMessage sends on your Mac")
                }
            }
            if plan.kind == .privateMessage, !availability.capabilities.privateSend { return reject(command, .agentUnavailable, "\(availability.displayName) can't take private messages") }
            if plan.kind != .privateMessage, !availability.capabilities.sharedSend { return reject(command, .agentUnavailable, "\(availability.displayName) can't take shared messages") }
            guard availability.readiness.acceptsSend else {
                let why = availability.reasons.map(\.userText).first ?? "\(availability.displayName) isn't ready"
                return reject(command, .agentUnavailable, why)
            }
        }
        if !plan.attachmentIDs.isEmpty {
            guard messagesTargets == targets.count else { return reject(command, .attachmentRejected, "Files go only to Messages agents") }
            guard plan.attachmentIDs.allSatisfy(host.hasStagedAttachment) else { return reject(command, .attachmentRejected, "Attachment expired. Add it again") }
        }
        return nil
    }

    private func avatar(_ command: RemoteCommand, ref: String) -> RemoteCommandResult {
        guard ref.hasPrefix("sha256:"), let data = host?.avatar(ref), data.count <= RemoteProtocol.maximumAvatarBytes else {
            return reject(command, .unknownAvatar, "No artwork for that agent")
        }
        return RemoteCommandResult(clientCommandID: command.clientCommandID, outcome: .applied, avatar: data)
    }

    /// A stored, running, or unknown command. Read-only: never runs anything.
    public func status(of id: UUID) -> RemoteCommandResult {
        if var stored = ledger[id] { stored.replayed = true; return stored }
        if inProgress.contains(id) { return RemoteCommandResult(clientCommandID: id, outcome: .accepted, message: "Still running on your Mac", replayed: true) }
        return .rejected(id, .unknownCommand, "Your Mac lost this request. Check the conversation")
    }

    private func checkPrepare(_ command: RemoteCommand, atHead: Bool = false) -> RemoteCommandResult? {
        guard let host else { return reject(command, .failed, "Remote control stopped on your Mac") }
        guard !host.isLocked else { return reject(command, .macLocked, "Your Mac is locked") }
        guard case .prepareConversation(let id, let agents) = command.action else { return reject(command, .invalidCommand, "Not a preparation.") }
        if atHead && host.isBusy { return reject(command, .macBusy, "Your Mac is busy. Try again soon") }
        if let id {
            switch host.conversation(id) {
            case nil: return reject(command, .unknownConversation, "This conversation is gone from your Mac")
            case .ended?: return reject(command, .conversationEnded, "This conversation has ended")
            case .active?: break
            }
        }
        guard agents.allSatisfy({ host.availability(for: $0) != nil }) else { return reject(command, .unknownAgent, "An agent is gone from your Mac") }
        return nil
    }

    private func runSend(_ command: RemoteCommand) async -> RemoteCommandResult {
        if case .prepareConversation(let id, let agents) = command.action {
            guard let host else { return reject(command, .failed, "Remote control stopped on your Mac") }
            return outcome(command, await host.prepareConversation(id, agentIDs: agents))
        }
        guard let host, let plan = plan(command) else { return reject(command, .failed, "Remote control stopped on your Mac") }
        let result = await host.performSend(plan)
        return outcome(command, result)
    }

    private func outcome(_ command: RemoteCommand, _ result: RemoteHostResult, attachmentID: String? = nil) -> RemoteCommandResult {
        // The result has one line per reason; long desktop-driver messages are shortened.
        // The agent's availability keeps the full reason as its detail.
        let reasons = Dictionary(uniqueKeysWithValues: result.agentReasons.map { id, reason in
            (id, RemotePhoneText.split(reason, agentName: host?.availability(for: id)?.displayName).text)
        })
        return RemoteCommandResult(clientCommandID: command.clientCommandID, outcome: result.applied ? .applied : .rejected, code: result.code,
                                   message: result.message.map { RemotePhoneText.split($0).text }, conversationID: result.conversationID,
                                   attachmentID: attachmentID, agentStatuses: result.agentStatuses, agentReasons: reasons)
    }

    private func apply(_ command: RemoteCommand) async -> RemoteCommandResult {
        guard let host else { return reject(command, .failed, "Remote control stopped on your Mac") }
        // Keep-awake matters most while the Mac is locked, and the phone sends it only once
        // per connection, so it is never refused for the lock.
        if case .setKeepAwake(let enabled) = command.action { return outcome(command, host.setKeepAwake(enabled)) }
        guard !host.isLocked else { return reject(command, .macLocked, "Your Mac is locked") }
        switch command.action {
        case .endConversation(let id):
            switch host.conversation(id) {
            case nil: return reject(command, .unknownConversation, "This conversation is gone from your Mac")
            case .ended?: return outcome(command, .applied(conversationID: id, message: "Already ended"))
            case .active?: return outcome(command, host.endConversation(id))
            }
        case .acknowledgeIncomplete(let agent, let attempt): return outcome(command, host.acknowledgeIncomplete(agentID: agent, attemptID: attempt))
        case .cancelNative(let agent): return outcome(command, host.cancelNative(agentID: agent))
        case .setKeepAwake(let enabled): return outcome(command, host.setKeepAwake(enabled))
        case .requestReport(let id):
            guard case .active? = host.conversation(id) else { return reject(command, .unknownConversation, "Reports need an active conversation") }
            return outcome(command, await host.requestReport(id))
        case .uploadAttachmentChunk(let uploadID, let filename, let index, let count, let data):
            return receive(command, uploadID: uploadID, filename: filename, index: index, count: count, data: data)
        case .attachStaged(let uploadID, let digest):
            guard let upload = uploads[uploadID], upload.chunks.count == upload.count else { return reject(command, .attachmentRejected, "Upload incomplete. Add it again") }
            let data = (0..<upload.count).reduce(into: Data()) { $0.append(upload.chunks[$1]!) }
            uploads[uploadID] = nil
            guard Data(SHA256.hash(data: data)) == digest else { return reject(command, .attachmentRejected, "Upload failed. Add it again") }
            do { return outcome(command, .applied(), attachmentID: try host.stageAttachment(data, filename: upload.filename)) }
            catch { return reject(command, .attachmentRejected, error.localizedDescription) }
        case .createConversation, .sendShared, .sendPrivate, .prepareConversation, .queryCommand, .fetchAvatar: return reject(command, .invalidCommand, "Handled separately.")
        case .unknown(let kind): return reject(command, .unsupported, "Update msgblast on your Mac")
        }
    }

    static func cleanFilename(_ name: String) -> String? {
        let last = (name as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !last.isEmpty, last != ".", last != "..", !last.hasPrefix("."), last.utf8.count <= 255,
              !last.contains("/"), !last.contains(":"), last.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return last
    }

    private func receive(_ command: RemoteCommand, uploadID: UUID, filename: String, index: Int, count: Int, data: Data) -> RemoteCommandResult {
        guard let name = Self.cleanFilename(filename) else { return reject(command, .attachmentRejected, "That file name can't be used") }
        guard count > 0, count <= Self.maximumUploadChunks, index >= 0, index < count, !data.isEmpty, data.count <= RemoteProtocol.maximumAttachmentChunkBytes else {
            uploads[uploadID] = nil
            return reject(command, .attachmentRejected, "Upload failed. Add it again")
        }
        var upload = uploads[uploadID] ?? Upload(filename: name, count: count)
        guard upload.filename == name, upload.count == count else { uploads[uploadID] = nil; return reject(command, .attachmentRejected, "Upload failed. Add it again") }
        upload.bytes += data.count - (upload.chunks[index]?.count ?? 0)
        guard upload.bytes <= RemoteProtocol.maximumAttachmentBytes else { uploads[uploadID] = nil; return reject(command, .attachmentRejected, "Files are limited to 25 MB") }
        upload.chunks[index] = data
        uploads[uploadID] = upload
        return outcome(command, .applied())
    }

    /// Drops partial uploads when the client disconnects.
    public func discardUploads() { uploads = [:] }
}
