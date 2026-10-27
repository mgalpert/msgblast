import Foundation
import msgblastRemoteProtocol

/// How a status chip under one of your messages reads, per agent.
public enum ChipState: String, Equatable, Sendable {
    case sending = "Sending on Mac"
    case sent = "Sent"
    case replied = "Replied"
    case notSent = "Not sent"
    case unconfirmed = "Unconfirmed"

    public init(_ status: RemoteAttemptStatus) {
        switch status {
        case .preparing, .attempting, .sending, .ready: self = .sending
        case .waiting, .submitted: self = .sent
        case .observed: self = .replied
        case .notSent, .failed, .dismissed: self = .notSent
        case .uncertain: self = .unconfirmed
        }
    }
}

public struct StatusChip: Equatable, Identifiable, Sendable {
    public var id: String { agentID }
    public var agentID: String
    public var agentName: String
    public var state: ChipState
    public var reason: String?
}

public struct InboxRow: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var agentNames: [String]
    public var agentIDs: [String]
    public var preview: String
    public var lastActivity: Date
    public var unconfirmed: Int
    public var ended: Bool
    public var isDirect: Bool { agentIDs.count == 1 }
}

/// Readable views of the projection for the screens. Histories of different forms of one
/// product are never merged: each agent id is its own thread.
public struct ProjectionPresenter: Sendable {
    public let state: ProjectionState
    public let commands: [UUID: CommandRecord]
    public init(state: ProjectionState, commands: [UUID: CommandRecord] = [:]) { self.state = state; self.commands = commands }

    public func name(_ agentID: String) -> String { state.agents[agentID]?.formLabel ?? agentID }
    public func shortName(_ agentID: String) -> String { state.agents[agentID]?.displayName ?? agentID }

    public var inbox: [InboxRow] {
        state.sortedConversations.map { conversation in
            let reply = state.turns(in: conversation.id).last { $0.role == .assistant }
            let unconfirmedCommands = commands.values.filter { $0.conversationID == conversation.id && $0.status == .unconfirmed }.count
            return InboxRow(id: conversation.id, title: conversation.title, agentNames: conversation.agentIDs.map(shortName), agentIDs: conversation.agentIDs,
                            preview: reply.map { "\(shortName($0.agentID ?? "")): \($0.text)" } ?? conversation.prompt, lastActivity: conversation.lastActivity,
                            unconfirmed: conversation.unresolvedAttemptCount + unconfirmedCommands, ended: conversation.endedAt != nil)
        }
    }

    /// `agentID == nil` is the All view: your messages and every agent's replies.
    public func turns(in conversation: UUID, agentID: String?) -> [RemoteTurn] {
        let all = state.turns(in: conversation)
        guard let agentID else {
            // In All, an agent's own copy of your shared prompt is not repeated.
            return all.filter { !($0.origin == .agentTranscript && $0.role == .user) }
        }
        return all.filter { $0.agentID == agentID || ($0.agentID == nil && $0.origin == .sharedPrompt) }
    }

    /// Chips for one of your turns: the matching attempt for each agent.
    /// `agentID` is the conversation's one-agent filter: only that agent's chip is shown.
    public func chips(for turn: RemoteTurn, agentID filter: String? = nil) -> [StatusChip] {
        guard turn.role == .user else { return [] }
        let attempts = state.attempts(in: turn.conversationID).filter {
            $0.text == turn.text && (turn.agentID == nil || $0.agentID == turn.agentID) && (filter == nil || $0.agentID == filter)
        }
        var latest: [String: RemoteAttempt] = [:]
        for attempt in attempts where latest[attempt.agentID].map({ ($0.created ?? .distantPast) <= (attempt.created ?? .distantPast) }) ?? true { latest[attempt.agentID] = attempt }
        let replies = state.turns(in: turn.conversationID).filter { $0.role == .assistant }
        return latest.values.sorted { $0.agentID < $1.agentID }.map { attempt in
            var chip = ChipState(attempt.status)
            // A Messages send stays "submitted"; a reply after it means the agent answered.
            if chip == .sent, replies.contains(where: { $0.agentID == attempt.agentID && ($0.created ?? .distantPast) >= (turn.created ?? .distantFuture) }) { chip = .replied }
            return StatusChip(agentID: attempt.agentID, agentName: shortName(attempt.agentID), state: chip, reason: attempt.detail)
        }
    }

    /// Why sending to these agents is not possible now, in the Mac's words; nil when it is.
    public func disabledReason(agentIDs: [String], conversation: UUID?) -> String? {
        guard !agentIDs.isEmpty else { return "Choose who to send to." }
        if state.macLocked { return "Your Mac is locked." }
        for id in agentIDs {
            guard let agent = state.agents[id] else { return "\(id) is no longer on your Mac." }
            if !agent.readiness.acceptsSend {
                return agent.reasons.first?.userText ?? "\(agent.displayName) is not ready."
            }
            if let conversation, state.conversations[conversation]?.incompleteAttempts.contains(where: { $0.agentID == id }) == true {
                return "\(agent.displayName) has an unfinished request in this conversation. Acknowledge it first."
            }
        }
        return nil
    }

    /// "Will open ChatGPT on your Mac" for agents whose send launches a Mac app.
    public func launchNotes(agentIDs: [String]) -> [String] {
        agentIDs.compactMap { state.agents[$0] }.filter { $0.readiness == .readyWillLaunch }.map { "Will open \($0.displayName) on your Mac" }
    }

    public struct ProductGroup: Identifiable, Equatable, Sendable {
        public var id: String { product.rawValue }
        public var product: AgentProduct
        public var title: String
        public var agents: [AgentAvailability]
    }

    /// The new-conversation grid: grouped by product, in the Mac's grid order, forms labeled.
    public var productGroups: [ProductGroup] {
        let visible = state.grid.compactMap { state.agents[$0] }
        let rest = state.orderedAgents.filter { !state.grid.contains($0.agentID) && $0.readiness != .unavailable }
        var groups: [ProductGroup] = []
        for agent in visible + rest {
            if let index = groups.firstIndex(where: { $0.product == agent.product }) { groups[index].agents.append(agent) }
            else { groups.append(ProductGroup(product: agent.product, title: agent.form == .messages ? "Messages" : agent.displayName, agents: [agent])) }
        }
        return groups
    }

    public static func formLabel(_ form: AgentForm) -> String {
        switch form { case .macApp: "Mac app"; case .website: "Web"; case .cli: "CLI"; case .webhookBot: "Bot"; case .messages: "Messages" }
    }
}
