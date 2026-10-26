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
        case .unknown(let kind): kind
        }
    }
    /// Actions that can deliver text to an agent.
    public var isSend: Bool {
        switch self { case .createConversation, .sendShared, .sendPrivate: true; default: false }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, text, agentIDs, attachmentIDs, conversationID, agentID, attemptID, enabled, uploadID, filename, index, count, data, sha256
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
    public static let preparedNotSent: Self = "preparedNotSent"
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
    /// True when the Mac returned the stored result for a replayed `clientCommandID`.
    public var replayed: Bool
    public init(clientCommandID: UUID, outcome: Outcome, code: RemoteRejectionCode? = nil, message: String? = nil, conversationID: UUID? = nil, attachmentID: String? = nil, agentStatuses: [String: RemoteAttemptStatus] = [:], replayed: Bool = false) {
        self.clientCommandID = clientCommandID; self.outcome = outcome; self.code = code; self.message = message
        self.conversationID = conversationID; self.attachmentID = attachmentID; self.agentStatuses = agentStatuses; self.replayed = replayed
    }
    public static func rejected(_ id: UUID, _ code: RemoteRejectionCode, _ message: String) -> Self {
        Self(clientCommandID: id, outcome: .rejected, code: code, message: message)
    }
}
