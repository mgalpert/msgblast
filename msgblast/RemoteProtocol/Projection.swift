import Foundation

/// The Mac's visible agent grid, in order. Hidden agents keep their histories.
public struct RemoteGrid: Codable, Hashable, Sendable {
    public var visibleAgentIDs: [String]
    public init(visibleAgentIDs: [String]) { self.visibleAgentIDs = visibleAgentIDs }
}

public struct RemoteConversation: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var prompt: String
    public var created: Date
    public var endedAt: Date?
    /// Messages members as `messages:<uuid>` plus website/app/CLI/bot agents as `WebAgentID.id`.
    public var agentIDs: [String]
    /// False until every website history is loaded on the Mac (`canArchiveComparison`).
    public var canEnd: Bool
    public var unresolvedAttemptCount: Int
    public var lastActivity: Date
    public var report: RemoteReport?
    /// Unresolved app, CLI and bot requests in this conversation. The agent stays `ready`
    /// elsewhere; inside this conversation the phone disables it and offers acknowledge.
    public var incompleteAttempts: [RemoteIncompleteAttempt]
    public init(id: UUID, title: String, prompt: String, created: Date, endedAt: Date?, agentIDs: [String], canEnd: Bool, unresolvedAttemptCount: Int, lastActivity: Date,
                report: RemoteReport? = nil, incompleteAttempts: [RemoteIncompleteAttempt] = []) {
        self.id = id; self.title = title; self.prompt = prompt; self.created = created; self.endedAt = endedAt
        self.agentIDs = agentIDs; self.canEnd = canEnd; self.unresolvedAttemptCount = unresolvedAttemptCount; self.lastActivity = lastActivity
        self.report = report; self.incompleteAttempts = incompleteAttempts
    }
    private enum CodingKeys: String, CodingKey { case id, title, prompt, created, endedAt, agentIDs, canEnd, unresolvedAttemptCount, lastActivity, report, incompleteAttempts }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); title = try c.decode(String.self, forKey: .title); prompt = try c.decode(String.self, forKey: .prompt)
        created = try c.decode(Date.self, forKey: .created); endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        agentIDs = try c.decode([String].self, forKey: .agentIDs); canEnd = try c.decode(Bool.self, forKey: .canEnd)
        unresolvedAttemptCount = try c.decode(Int.self, forKey: .unresolvedAttemptCount); lastActivity = try c.decode(Date.self, forKey: .lastActivity)
        report = try c.decodeIfPresent(RemoteReport.self, forKey: .report)
        // Added in phase 1 review; older Macs omit it.
        incompleteAttempts = try c.decodeIfPresent([RemoteIncompleteAttempt].self, forKey: .incompleteAttempts) ?? []
    }
}

public struct RemoteIncompleteAttempt: Codable, Hashable, Sendable {
    public var agentID: String
    public var attemptID: String
    public var reasonCode: AvailabilityReasonCode
    public init(agentID: String, attemptID: String, reasonCode: AvailabilityReasonCode) { self.agentID = agentID; self.attemptID = attemptID; self.reasonCode = reasonCode }
}

/// A comparison report produced on the Mac by the configured local agent.
public struct RemoteReport: Codable, Hashable, Sendable {
    public var provider: String?
    public var overview: String?
    public var comparison: String?
    public var uncertainties: [String]
    public var running: Bool
    public var error: String?
    public init(provider: String?, overview: String?, comparison: String?, uncertainties: [String], running: Bool, error: String?) {
        self.provider = provider; self.overview = overview; self.comparison = comparison
        self.uncertainties = uncertainties; self.running = running; self.error = error
    }
}

public enum RemoteTurnRole: String, Codable, Hashable, Sendable {
    case user, assistant, system
}

public enum RemoteTurnOrigin: String, Codable, Hashable, Sendable {
    /// The conversation's first shared prompt.
    case sharedPrompt
    /// A Messages follow-up (shared or private).
    case followUp
    /// A message read from an agent's own transcript (website page, CLI, bot, Mac app).
    case agentTranscript
    /// A Messages reply read from the read-only history.
    case messagesHistory
}

public struct RemoteAttachmentRef: Codable, Hashable, Sendable {
    public var id: String
    public var filename: String
    public var mimeType: String?
    public var byteCount: Int64?
    public init(id: String, filename: String, mimeType: String?, byteCount: Int64?) {
        self.id = id; self.filename = filename; self.mimeType = mimeType; self.byteCount = byteCount
    }
}

public struct RemoteTurn: Codable, Hashable, Sendable, Identifiable {
    /// Stable projection id. Website turns use agent + conversation + ordinal, so a
    /// re-rendered or still-streaming reply updates in place rather than duplicating.
    public var id: String
    public var conversationID: UUID
    /// Nil for the shared prompt and shared follow-ups.
    public var agentID: String?
    public var role: RemoteTurnRole
    public var origin: RemoteTurnOrigin
    public var text: String
    public var created: Date?
    public var ordinal: Int
    public var attachments: [RemoteAttachmentRef]
    /// SHA-256 prefix of the text; lets a client skip unchanged bodies.
    public var contentHash: String
    public init(id: String, conversationID: UUID, agentID: String?, role: RemoteTurnRole, origin: RemoteTurnOrigin, text: String, created: Date?, ordinal: Int, attachments: [RemoteAttachmentRef] = [], contentHash: String) {
        self.id = id; self.conversationID = conversationID; self.agentID = agentID; self.role = role; self.origin = origin
        self.text = text; self.created = created; self.ordinal = ordinal; self.attachments = attachments; self.contentHash = contentHash
    }
}

/// Website, app, CLI and bot attempts (`WebSendStatus`) and Messages submissions (`Submission`) share one vocabulary.
public enum RemoteAttemptStatus: String, Codable, Hashable, Sendable {
    case preparing, attempting, waiting, observed, notSent, uncertain, dismissed
    case ready, sending, submitted, failed
    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .uncertain
    }
    /// Never resend automatically while true.
    public var isUnresolved: Bool { [.attempting, .waiting, .uncertain, .sending].contains(self) }
}

public struct RemoteAttempt: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var conversationID: UUID
    public var agentID: String
    public var text: String
    public var status: RemoteAttemptStatus
    public var detail: String?
    public var created: Date?
    public init(id: String, conversationID: UUID, agentID: String, text: String, status: RemoteAttemptStatus, detail: String?, created: Date?) {
        self.id = id; self.conversationID = conversationID; self.agentID = agentID; self.text = text
        self.status = status; self.detail = detail; self.created = created
    }
}

/// A full, normalized view. The Mac derives it from live state; nothing here is persisted.
public struct RemoteSnapshot: Codable, Hashable, Sendable {
    public var seq: UInt64
    public var macStatus: MacStatus
    public var grid: RemoteGrid
    public var agents: [AgentAvailability]
    public var conversations: [RemoteConversation]
    public var turns: [RemoteTurn]
    public var attempts: [RemoteAttempt]
    /// Large snapshots are split by turns; parts share `seq` and arrive in order.
    public var partIndex: Int
    public var partCount: Int
    public init(seq: UInt64, macStatus: MacStatus, grid: RemoteGrid, agents: [AgentAvailability], conversations: [RemoteConversation], turns: [RemoteTurn], attempts: [RemoteAttempt], partIndex: Int = 0, partCount: Int = 1) {
        self.seq = seq; self.macStatus = macStatus; self.grid = grid; self.agents = agents; self.conversations = conversations
        self.turns = turns; self.attempts = attempts; self.partIndex = partIndex; self.partCount = partCount
    }
    /// Splits turns so each encoded part stays under `limit` bytes when possible.
    public func parts(maximumTurnsPerPart: Int = 400) -> [RemoteSnapshot] {
        guard turns.count > maximumTurnsPerPart else { return [self] }
        let chunks = stride(from: 0, to: turns.count, by: maximumTurnsPerPart).map { Array(turns[$0..<min($0 + maximumTurnsPerPart, turns.count)]) }
        return chunks.enumerated().map { index, chunk in
            var part = self
            part.turns = chunk
            part.partIndex = index
            part.partCount = chunks.count
            if index > 0 { part.agents = []; part.conversations = []; part.attempts = [] }
            return part
        }
    }
}
