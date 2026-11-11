import Foundation

/// A phone request. The Mac records `clientCommandID`; a replayed id returns the
/// original result and never repeats the action. The phone never retries a send.
public struct RemoteCommand: Codable, Hashable, Sendable {
    public var clientCommandID: UUID
    public var action: RemoteAction
    public init(clientCommandID: UUID = UUID(), action: RemoteAction) { self.clientCommandID = clientCommandID; self.action = action }
}

public enum RemoteAction: Codable, Hashable, Sendable {
    /// New conversation sent to several agents (Mac: "Send & compare" from New Blast).
    case createConversation(text: String, agentIDs: [String], attachmentIDs: [String])
    /// Shared follow-up in an existing conversation, to the listed members (or all when empty).
    case sendShared(conversationID: UUID, text: String, agentIDs: [String], attachmentIDs: [String])
    /// One agent only. A nil conversation starts a new one-agent conversation.
    case sendPrivate(conversationID: UUID?, agentID: String, text: String, attachmentIDs: [String])
    case endConversation(conversationID: UUID)
    /// "Stop waiting" / acknowledge an unresolved native request. Never resends.
    case acknowledgeIncomplete(agentID: String, attemptID: String?)
    /// Cancels the local wait for a native request; the other app is not stopped.
    case cancelNative(agentID: String)
    /// The phone's keep-awake request. The Mac's Settings toggle can still refuse it.
    case setKeepAwake(enabled: Bool)
    /// Chunked upload into a staging buffer. `index` is zero-based.
    case uploadAttachmentChunk(uploadID: UUID, filename: String, index: Int, count: Int, data: Data)
    /// Completes an upload; the result's `attachmentID` is used in send actions.
    case attachStaged(uploadID: UUID, sha256: Data)
    /// Starts a comparison report on the Mac with the configured local agent.
    case requestReport(conversationID: UUID)
    /// Sent when the phone opens a composer or changes recipients: runs the Mac's existing
    /// prepare paths (which may navigate website pages, never launch apps or send) and
    /// answers when the agents are ready, or with each agent's reason.
    case prepareConversation(conversationID: UUID?, agentIDs: [String])
    /// Asks for the result of an earlier command without running anything. After a Mac
    /// restart an unknown id is answered with `unknownCommand`: show it as unconfirmed.
    case queryCommand(clientCommandID: UUID)
    /// Read-only: the artwork an agent's `avatarRef` (`sha256:<hex>`) names. The result's
    /// `avatar` carries the bytes. A Mac without it answers `unsupported`: show initials.
    case fetchAvatar(ref: String)
    /// Names a conversation (Messages' "Change Name"). The Mac trims it and refuses an empty
    /// name or one over 80 characters. Older Macs answer `unsupported`.
    case renameConversation(conversationID: UUID, title: String)
    /// Read-only: one attachment of a turn, on demand. Images come back as JPEG scaled to
    /// fit `maxBytes` (320 px thumbnails up to 256 KB, else 1600 px); other files whole when
    /// they fit `maxBytes` and `RemoteProtocol.maximumAttachmentFetchBytes`. Older Macs answer
    /// `unsupported`.
    case fetchAttachment(turnID: String, index: Int, maxBytes: Int)
    case unknown(kind: String)

    public var kind: String {
        switch self {
        case .createConversation: "createConversation"
        case .sendShared: "sendShared"
        case .sendPrivate: "sendPrivate"
        case .endConversation: "endConversation"
        case .acknowledgeIncomplete: "acknowledgeIncomplete"
        case .cancelNative: "cancelNative"
        case .setKeepAwake: "setKeepAwake"
        case .uploadAttachmentChunk: "uploadAttachmentChunk"
        case .attachStaged: "attachStaged"
        case .requestReport: "requestReport"
        case .prepareConversation: "prepareConversation"
        case .queryCommand: "queryCommand"
        case .fetchAvatar: "fetchAvatar"
        case .renameConversation: "renameConversation"
        case .fetchAttachment: "fetchAttachment"
        case .unknown(let kind): kind
        }
    }
    /// Actions that run one at a time with sends (they may navigate pages on the Mac).
    public var isSerial: Bool {
        if case .prepareConversation = self { return true }
        return isSend
    }
    /// Actions that can deliver text to an agent.
    public var isSend: Bool {
        switch self { case .createConversation, .sendShared, .sendPrivate: true; default: false }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, text, agentIDs, attachmentIDs, conversationID, agentID, attemptID, enabled, uploadID, filename, index, count, data, sha256, clientCommandID, ref, title, turnID, maxBytes
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        func ids(_ key: CodingKeys) throws -> [String] { try c.decodeIfPresent([String].self, forKey: key) ?? [] }
        switch kind {
        case "createConversation":
            self = .createConversation(text: try c.decode(String.self, forKey: .text), agentIDs: try ids(.agentIDs), attachmentIDs: try ids(.attachmentIDs))
        case "sendShared":
            self = .sendShared(conversationID: try c.decode(UUID.self, forKey: .conversationID), text: try c.decode(String.self, forKey: .text), agentIDs: try ids(.agentIDs), attachmentIDs: try ids(.attachmentIDs))
        case "sendPrivate":
            self = .sendPrivate(conversationID: try c.decodeIfPresent(UUID.self, forKey: .conversationID), agentID: try c.decode(String.self, forKey: .agentID), text: try c.decode(String.self, forKey: .text), attachmentIDs: try ids(.attachmentIDs))
        case "endConversation": self = .endConversation(conversationID: try c.decode(UUID.self, forKey: .conversationID))
        case "acknowledgeIncomplete": self = .acknowledgeIncomplete(agentID: try c.decode(String.self, forKey: .agentID), attemptID: try c.decodeIfPresent(String.self, forKey: .attemptID))
        case "cancelNative": self = .cancelNative(agentID: try c.decode(String.self, forKey: .agentID))
        case "setKeepAwake": self = .setKeepAwake(enabled: try c.decode(Bool.self, forKey: .enabled))
        case "uploadAttachmentChunk":
            self = .uploadAttachmentChunk(uploadID: try c.decode(UUID.self, forKey: .uploadID), filename: try c.decode(String.self, forKey: .filename), index: try c.decode(Int.self, forKey: .index), count: try c.decode(Int.self, forKey: .count), data: try c.decode(Data.self, forKey: .data))
        case "attachStaged": self = .attachStaged(uploadID: try c.decode(UUID.self, forKey: .uploadID), sha256: try c.decode(Data.self, forKey: .sha256))
        case "requestReport": self = .requestReport(conversationID: try c.decode(UUID.self, forKey: .conversationID))
        case "prepareConversation": self = .prepareConversation(conversationID: try c.decodeIfPresent(UUID.self, forKey: .conversationID), agentIDs: try ids(.agentIDs))
        case "queryCommand": self = .queryCommand(clientCommandID: try c.decode(UUID.self, forKey: .clientCommandID))
        case "fetchAvatar": self = .fetchAvatar(ref: try c.decode(String.self, forKey: .ref))
        case "fetchAttachment":
            self = .fetchAttachment(turnID: try c.decode(String.self, forKey: .turnID), index: try c.decode(Int.self, forKey: .index), maxBytes: try c.decode(Int.self, forKey: .maxBytes))
        case "renameConversation": self = .renameConversation(conversationID: try c.decode(UUID.self, forKey: .conversationID), title: try c.decode(String.self, forKey: .title))
        default: self = .unknown(kind: kind)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case .createConversation(let text, let agentIDs, let attachmentIDs):
            try c.encode(text, forKey: .text); try c.encode(agentIDs, forKey: .agentIDs); try c.encode(attachmentIDs, forKey: .attachmentIDs)
        case .sendShared(let conversationID, let text, let agentIDs, let attachmentIDs):
            try c.encode(conversationID, forKey: .conversationID); try c.encode(text, forKey: .text)
            try c.encode(agentIDs, forKey: .agentIDs); try c.encode(attachmentIDs, forKey: .attachmentIDs)
        case .sendPrivate(let conversationID, let agentID, let text, let attachmentIDs):
            try c.encodeIfPresent(conversationID, forKey: .conversationID); try c.encode(agentID, forKey: .agentID)
            try c.encode(text, forKey: .text); try c.encode(attachmentIDs, forKey: .attachmentIDs)
        case .endConversation(let id): try c.encode(id, forKey: .conversationID)
        case .acknowledgeIncomplete(let agentID, let attemptID): try c.encode(agentID, forKey: .agentID); try c.encodeIfPresent(attemptID, forKey: .attemptID)
        case .cancelNative(let agentID): try c.encode(agentID, forKey: .agentID)
        case .setKeepAwake(let enabled): try c.encode(enabled, forKey: .enabled)
        case .uploadAttachmentChunk(let uploadID, let filename, let index, let count, let data):
            try c.encode(uploadID, forKey: .uploadID); try c.encode(filename, forKey: .filename)
            try c.encode(index, forKey: .index); try c.encode(count, forKey: .count); try c.encode(data, forKey: .data)
        case .attachStaged(let uploadID, let sha256): try c.encode(uploadID, forKey: .uploadID); try c.encode(sha256, forKey: .sha256)
        case .requestReport(let id): try c.encode(id, forKey: .conversationID)
        case .prepareConversation(let id, let agents): try c.encodeIfPresent(id, forKey: .conversationID); try c.encode(agents, forKey: .agentIDs)
        case .queryCommand(let id): try c.encode(id, forKey: .clientCommandID)
        case .fetchAvatar(let ref): try c.encode(ref, forKey: .ref)
        case .renameConversation(let id, let title): try c.encode(id, forKey: .conversationID); try c.encode(title, forKey: .title)
        case .fetchAttachment(let turnID, let index, let maxBytes):
            try c.encode(turnID, forKey: .turnID); try c.encode(index, forKey: .index); try c.encode(maxBytes, forKey: .maxBytes)
        case .unknown: break
        }
    }
}

public struct RemoteRejectionCode: RemoteOpenValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let macLocked: Self = "macLocked"
    public static let macBusy: Self = "macBusy"
    public static let agentUnavailable: Self = "agentUnavailable"
    public static let unknownAgent: Self = "unknownAgent"
    public static let unknownConversation: Self = "unknownConversation"
    public static let conversationEnded: Self = "conversationEnded"
    public static let messagesSendsOff: Self = "messagesSendsOff"
    public static let historyNotLoaded: Self = "historyNotLoaded"
    public static let invalidCommand: Self = "invalidCommand"
    public static let unsupported: Self = "unsupported"
    public static let attachmentRejected: Self = "attachmentRejected"
    public static let keepAwakeDisabled: Self = "keepAwakeDisabled"
    public static let failed: Self = "failed"
    /// The Mac navigated an agent's chat for this send and, as on the Mac, needs a new explicit send.
    /// Kept for compatibility; current Macs wait for readiness instead (see `notReady`).
    public static let preparedNotSent: Self = "preparedNotSent"
    /// Agents did not become ready within the wait. Nothing was submitted.
    public static let notReady: Self = "notReady"
    /// The Mac has no record of this command id (for example after it restarted). Unconfirmed.
    public static let unknownCommand: Self = "unknownCommand"
    /// `fetchAvatar` named artwork this Mac does not have (any more).
    public static let unknownAvatar: Self = "unknownAvatar"
    /// `fetchAttachment` named a file the Mac does not have, or one too large to send.
    public static let attachmentUnavailable: Self = "attachmentUnavailable"
}

public struct RemoteCommandResult: Codable, Hashable, Sendable {
    public enum Outcome: String, Codable, Hashable, Sendable {
        /// Queued or running; a later result with the same id reports the outcome.
        case accepted
        /// Nothing was sent or changed.
        case rejected
        /// The Mac ran the action. For sends this is submission evidence, not delivery;
        /// per-agent attempt status arrives as ordinary events.
        case applied
    }
    public var clientCommandID: UUID
    public var outcome: Outcome
    public var code: RemoteRejectionCode?
    public var message: String?
    public var conversationID: UUID?
    public var attachmentID: String?
    /// Agent id → attempt status reported by the send path, when known.
    public var agentStatuses: [String: RemoteAttemptStatus]
    /// Agent id → why it is not ready (for `prepareConversation` and `notReady`).
    public var agentReasons: [String: String]
    /// True when the Mac returned the stored result for a replayed `clientCommandID`.
    public var replayed: Bool
    /// `fetchAvatar` only: the image bytes (PNG or JPEG, at most `RemoteProtocol.maximumAvatarBytes`).
    public var avatar: Data?
    /// `fetchAttachment` only: the file's bytes and its type (a MIME type such as `image/jpeg`).
    public var attachment: Data?
    public var attachmentType: String?
    public init(clientCommandID: UUID, outcome: Outcome, code: RemoteRejectionCode? = nil, message: String? = nil, conversationID: UUID? = nil, attachmentID: String? = nil, agentStatuses: [String: RemoteAttemptStatus] = [:], agentReasons: [String: String] = [:], replayed: Bool = false, avatar: Data? = nil, attachment: Data? = nil, attachmentType: String? = nil) {
        self.clientCommandID = clientCommandID; self.outcome = outcome; self.code = code; self.message = message
        self.conversationID = conversationID; self.attachmentID = attachmentID; self.agentStatuses = agentStatuses; self.agentReasons = agentReasons; self.replayed = replayed
        self.avatar = avatar; self.attachment = attachment; self.attachmentType = attachmentType
    }
    private enum CodingKeys: String, CodingKey { case clientCommandID, outcome, code, message, conversationID, attachmentID, agentStatuses, agentReasons, replayed, avatar, attachment, attachmentType }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clientCommandID = try c.decode(UUID.self, forKey: .clientCommandID)
        outcome = try c.decode(Outcome.self, forKey: .outcome)
        code = try c.decodeIfPresent(RemoteRejectionCode.self, forKey: .code)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        conversationID = try c.decodeIfPresent(UUID.self, forKey: .conversationID)
        attachmentID = try c.decodeIfPresent(String.self, forKey: .attachmentID)
        agentStatuses = try c.decodeIfPresent([String: RemoteAttemptStatus].self, forKey: .agentStatuses) ?? [:]
        agentReasons = try c.decodeIfPresent([String: String].self, forKey: .agentReasons) ?? [:]
        replayed = try c.decodeIfPresent(Bool.self, forKey: .replayed) ?? false
        avatar = try c.decodeIfPresent(Data.self, forKey: .avatar)
        attachment = try c.decodeIfPresent(Data.self, forKey: .attachment)
        attachmentType = try c.decodeIfPresent(String.self, forKey: .attachmentType)
    }
    public static func rejected(_ id: UUID, _ code: RemoteRejectionCode, _ message: String) -> Self {
        Self(clientCommandID: id, outcome: .rejected, code: code, message: message)
    }
}
