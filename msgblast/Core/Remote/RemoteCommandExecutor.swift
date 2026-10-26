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
    public static func applied(conversationID: UUID? = nil, statuses: [String: RemoteAttemptStatus] = [:], message: String? = nil) -> Self {
        Self(applied: true, code: nil, message: message, conversationID: conversationID, agentStatuses: statuses)
    }
    public static func rejected(_ code: RemoteRejectionCode, _ message: String, conversationID: UUID? = nil) -> Self {
        Self(applied: false, code: code, message: message, conversationID: conversationID, agentStatuses: [:])
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
    func endConversation(_ id: UUID) -> RemoteHostResult
    func acknowledgeIncomplete(agentID: String, attemptID: String?) -> RemoteHostResult
    func cancelNative(agentID: String) -> RemoteHostResult
    func setKeepAwake(_ enabled: Bool) -> RemoteHostResult
    func stageAttachment(_ data: Data, filename: String) throws -> String
    func hasStagedAttachment(_ id: String) -> Bool
    func requestReport(_ id: UUID) async -> RemoteHostResult
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
        if var stored = ledger[id] { stored.replayed = true; reply(stored); return }
        if inProgress.contains(id) { reply(RemoteCommandResult(clientCommandID: id, outcome: .accepted, message: "Already running on the Mac.", replayed: true)); return }
        if command.action.isSend {
            if let rejection = checkSend(command) { finish(rejection, reply); return }
            inProgress.insert(id)
            if sending { reply(RemoteCommandResult(clientCommandID: id, outcome: .accepted, message: "Waiting for the previous request on the Mac.")) }
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
            if let rejection = self.checkSend(command, atHead: true) { result = rejection }
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
        guard let host else { return reject(command, .failed, "Remote control stopped on the Mac.") }
        guard !host.isLocked else { return reject(command, .macLocked, "Your Mac is locked. Unlock it to send.") }
        guard let plan = plan(command) else { return reject(command, .invalidCommand, "Not a send.") }
        if atHead && host.isBusy { return reject(command, .macBusy, "The Mac is sending something else. Nothing was sent; try again when it finishes.") }
        let text = plan.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !plan.attachmentIDs.isEmpty else { return reject(command, .invalidCommand, "Write a message first.") }
        guard plan.kind != .newConversation || !plan.agentIDs.isEmpty else { return reject(command, .invalidCommand, "Choose at least one agent.") }
        guard Set(plan.agentIDs).count == plan.agentIDs.count else { return reject(command, .invalidCommand, "An agent is listed twice.") }
        var members: [String]?
        if let id = plan.conversationID {
            switch host.conversation(id) {
            case nil: return reject(command, .unknownConversation, "That conversation is no longer on the Mac.")
            case .ended?: return reject(command, .conversationEnded, "That conversation has ended.")
            case .active(let list)?: members = list
            }
        }
        if plan.kind == .sharedFollowUp, let members, let outsider = plan.agentIDs.first(where: { !members.contains($0) }) {
            return reject(command, .invalidCommand, "\(outsider) is not in this conversation. Add agents from the Mac.")
        }
        // "Everyone" means every member that takes shared messages (Hark does not), as on the Mac.
        let targets = plan.agentIDs.isEmpty ? (members ?? []).filter { host.availability(for: $0)?.capabilities.sharedSend != false } : plan.agentIDs
        var messagesTargets = 0
        for agentID in targets {
            guard let availability = host.availability(for: agentID) else { return reject(command, .unknownAgent, "An agent is no longer available on the Mac.") }
            if availability.form == .messages {
                messagesTargets += 1
                guard host.messagesSendsAllowed else {
                    return reject(command, .messagesSendsOff, "iMessage sends from your phone are off. Turn them on in msgblast Settings → Remote on your Mac.")
                }
            }
            if plan.kind == .privateMessage, !availability.capabilities.privateSend { return reject(command, .agentUnavailable, "\(availability.displayName) cannot take private messages.") }
            if plan.kind != .privateMessage, !availability.capabilities.sharedSend { return reject(command, .agentUnavailable, "\(availability.displayName) cannot take shared messages.") }
            guard availability.readiness.acceptsSend else {
                let why = availability.reasons.map(\.userText).first ?? "\(availability.displayName) is not ready."
                return reject(command, .agentUnavailable, why)
            }
        }
        if !plan.attachmentIDs.isEmpty {
            guard messagesTargets == targets.count else { return reject(command, .attachmentRejected, "Files can only be sent to Messages agents.") }
            guard plan.attachmentIDs.allSatisfy(host.hasStagedAttachment) else { return reject(command, .attachmentRejected, "An attachment is no longer staged on the Mac. Upload it again.") }
        }
        return nil
    }

    private func runSend(_ command: RemoteCommand) async -> RemoteCommandResult {
        guard let host, let plan = plan(command) else { return reject(command, .failed, "Remote control stopped on the Mac.") }
        let result = await host.performSend(plan)
        return outcome(command, result)
    }

    private func outcome(_ command: RemoteCommand, _ result: RemoteHostResult, attachmentID: String? = nil) -> RemoteCommandResult {
        RemoteCommandResult(clientCommandID: command.clientCommandID, outcome: result.applied ? .applied : .rejected, code: result.code, message: result.message,
                            conversationID: result.conversationID, attachmentID: attachmentID, agentStatuses: result.agentStatuses)
    }

    private func apply(_ command: RemoteCommand) async -> RemoteCommandResult {
        guard let host else { return reject(command, .failed, "Remote control stopped on the Mac.") }
        guard !host.isLocked else { return reject(command, .macLocked, "Your Mac is locked. Unlock it first.") }
        switch command.action {
        case .endConversation(let id):
            switch host.conversation(id) {
            case nil: return reject(command, .unknownConversation, "That conversation is no longer on the Mac.")
            case .ended?: return outcome(command, .applied(conversationID: id, message: "Already ended."))
            case .active?: return outcome(command, host.endConversation(id))
            }
        case .acknowledgeIncomplete(let agent, let attempt): return outcome(command, host.acknowledgeIncomplete(agentID: agent, attemptID: attempt))
        case .cancelNative(let agent): return outcome(command, host.cancelNative(agentID: agent))
        case .setKeepAwake(let enabled): return outcome(command, host.setKeepAwake(enabled))
        case .requestReport(let id):
            guard case .active? = host.conversation(id) else { return reject(command, .unknownConversation, "That conversation is not available for a report.") }
            return outcome(command, await host.requestReport(id))
        case .uploadAttachmentChunk(let uploadID, let filename, let index, let count, let data):
            return receive(command, uploadID: uploadID, filename: filename, index: index, count: count, data: data)
        case .attachStaged(let uploadID, let digest):
            guard let upload = uploads[uploadID], upload.chunks.count == upload.count else { return reject(command, .attachmentRejected, "The upload is incomplete.") }
            let data = (0..<upload.count).reduce(into: Data()) { $0.append(upload.chunks[$1]!) }
            uploads[uploadID] = nil
            guard Data(SHA256.hash(data: data)) == digest else { return reject(command, .attachmentRejected, "The upload was corrupted. Upload it again.") }
            do { return outcome(command, .applied(), attachmentID: try host.stageAttachment(data, filename: upload.filename)) }
            catch { return reject(command, .attachmentRejected, error.localizedDescription) }
        case .createConversation, .sendShared, .sendPrivate: return reject(command, .invalidCommand, "Sends are queued separately.")
        case .unknown(let kind): return reject(command, .unsupported, "This Mac does not support \(kind) yet. Update msgblast on the Mac.")
        }
    }

    static func cleanFilename(_ name: String) -> String? {
        let last = (name as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !last.isEmpty, last != ".", last != "..", !last.hasPrefix("."), last.utf8.count <= 255,
              !last.contains("/"), !last.contains(":"), last.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return last
    }

    private func receive(_ command: RemoteCommand, uploadID: UUID, filename: String, index: Int, count: Int, data: Data) -> RemoteCommandResult {
        guard let name = Self.cleanFilename(filename) else { return reject(command, .attachmentRejected, "That file name cannot be used.") }
        guard count > 0, count <= Self.maximumUploadChunks, index >= 0, index < count, !data.isEmpty, data.count <= RemoteProtocol.maximumAttachmentChunkBytes else {
            uploads[uploadID] = nil
            return reject(command, .attachmentRejected, "The upload chunk is not valid.")
        }
        var upload = uploads[uploadID] ?? Upload(filename: name, count: count)
        guard upload.filename == name, upload.count == count else { uploads[uploadID] = nil; return reject(command, .attachmentRejected, "The upload changed while it was being sent.") }
        upload.bytes += data.count - (upload.chunks[index]?.count ?? 0)
        guard upload.bytes <= RemoteProtocol.maximumAttachmentBytes else { uploads[uploadID] = nil; return reject(command, .attachmentRejected, "Files are limited to 25 MB.") }
        upload.chunks[index] = data
        uploads[uploadID] = upload
        return outcome(command, .applied())
    }

    /// Drops partial uploads when the client disconnects.
    public func discardUploads() { uploads = [:] }
}
