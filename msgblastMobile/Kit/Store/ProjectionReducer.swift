import Foundation
import msgblastRemoteProtocol

/// The phone's copy of the Mac projection. Derived from the Mac; replaced by every snapshot.
public struct ProjectionState: Codable, Equatable, Sendable {
    public var seq: UInt64?
    public var macStatus: MacStatus?
    public var grid: [String] = []
    public var agents: [String: AgentAvailability] = [:]
    public var agentOrder: [String] = []
    public var conversations: [UUID: RemoteConversation] = [:]
    public var turns: [String: RemoteTurn] = [:]
    public var attempts: [String: RemoteAttempt] = [:]
    /// The Mac reported it is locked; cleared by the next data it sends.
    public var macLocked = false
    /// The Mac refused this phone (forgotten or replaced): pair again.
    public var pairingLost: String?
    /// A change kind this build does not understand arrived; ask for a snapshot.
    public var needsSnapshot = false
    /// Parts of a multi-part snapshot still arriving.
    var pendingSnapshot: RemoteSnapshot?
    public init() {}

    public var orderedAgents: [AgentAvailability] { agentOrder.compactMap { agents[$0] } }
    public var sortedConversations: [RemoteConversation] { conversations.values.sorted { $0.lastActivity > $1.lastActivity } }
    public func turns(in conversation: UUID) -> [RemoteTurn] {
        turns.values.filter { $0.conversationID == conversation }.sorted { a, b in
            switch (a.created, b.created) {
            case let (x?, y?) where x != y: return x < y
            default: return (a.agentID ?? "", a.ordinal, a.id) < (b.agentID ?? "", b.ordinal, b.id)
            }
        }
    }
    public func attempts(in conversation: UUID) -> [RemoteAttempt] { attempts.values.filter { $0.conversationID == conversation } }
}

/// A pure function from client events to phone state, so it is tested with recorded fixtures.
public enum ProjectionReducer {
    public static func reduce(_ state: ProjectionState, _ event: RemoteClientDriver.Event) -> ProjectionState {
        var next = state
        switch event {
        case .snapshot(let part):
            if part.partIndex == 0 { next.pendingSnapshot = part }
            else if var pending = next.pendingSnapshot, pending.seq == part.seq { pending.turns += part.turns; next.pendingSnapshot = pending }
            else { next.needsSnapshot = true; return next }
            guard part.partIndex == part.partCount - 1, let full = next.pendingSnapshot else { return next }
            next = ProjectionState()
            next.seq = full.seq
            next.macStatus = full.macStatus
            next.grid = full.grid.visibleAgentIDs
            for agent in full.agents { next.agents[agent.agentID] = agent; next.agentOrder.append(agent.agentID) }
            for conversation in full.conversations { next.conversations[conversation.id] = conversation }
            for turn in full.turns { next.turns[turn.id] = turn }
            for attempt in full.attempts { next.attempts[attempt.id] = attempt }
        case .events(let events, let latest):
            for event in events where state.seq.map({ event.seq > $0 }) ?? true { apply(event.change, to: &next) }
            next.seq = max(latest, state.seq ?? 0)
            next.macLocked = next.macStatus?.locked ?? false
        case .error(let error):
            switch error.code {
            case .macLocked: next.macLocked = true
            case .notPaired, .authenticationFailed, .forgotten: next.pairingLost = error.message
            default: break
            }
        case .paired, .authenticated:
            next.pairingLost = nil
        case .commandResult, .pong:
            break
        }
        return next
    }

    static func apply(_ change: RemoteChange, to state: inout ProjectionState) {
        switch change {
        case .macStatus(let status): state.macStatus = status
        case .grid(let grid): state.grid = grid.visibleAgentIDs
        case .agentUpsert(let agent):
            if state.agents[agent.agentID] == nil { state.agentOrder.append(agent.agentID) }
            state.agents[agent.agentID] = agent
        case .agentRemove(let id): state.agents[id] = nil; state.agentOrder.removeAll { $0 == id }
        case .conversationUpsert(let conversation): state.conversations[conversation.id] = conversation
        case .conversationRemove(let id):
            state.conversations[id] = nil
            state.turns = state.turns.filter { $0.value.conversationID != id }
            state.attempts = state.attempts.filter { $0.value.conversationID != id }
        case .turnUpsert(let turn): state.turns[turn.id] = turn
        case .turnRemove(let id): state.turns[id] = nil
        case .attemptUpsert(let attempt): state.attempts[attempt.id] = attempt
        case .attemptRemove(let id): state.attempts[id] = nil
        case .unknown: state.needsSnapshot = true
        }
    }
}
