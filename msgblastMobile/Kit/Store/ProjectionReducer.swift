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
        TurnOrder.sorted(turns.values.filter { $0.conversationID == conversation })
    }
    public func attempts(in conversation: UUID) -> [RemoteAttempt] { attempts.values.filter { $0.conversationID == conversation } }

    /// The read position of each agent's undated transcript (Mac apps, websites, CLIs, bots):
    /// its highest ordinal in this conversation. Those turns carry no time, so unread is by position.
    public func transcriptPositions(in conversation: UUID) -> [String: Int] {
        var positions: [String: Int] = [:]
        for turn in turns.values where turn.conversationID == conversation && turn.created == nil {
            guard let agentID = turn.agentID else { continue }
            positions[agentID] = max(positions[agentID] ?? turn.ordinal, turn.ordinal)
        }
        return positions
    }
}

/// The order of a conversation's turns. Dated turns go by date. An undated transcript turn's
/// ordinal counts only within its agent's transcript, so it is placed after the shared question
/// it follows: the k-th question that agent's transcript shows (the prompt when it shows none).
/// Then ordinal, then agent id only as the final tie-break. A later question never comes before
/// an earlier reply, and the keys form a total order.
enum TurnOrder {
    struct Key: Comparable {
        var date: Date, undated: Int, ordinal: Int, agentID: String, id: String
        static func < (a: Key, b: Key) -> Bool {
            (a.date, a.undated, a.ordinal, a.agentID, a.id) < (b.date, b.undated, b.ordinal, b.agentID, b.id)
        }
    }

    static func sorted(_ turns: [RemoteTurn]) -> [RemoteTurn] {
        let questions = turns.filter { $0.agentID == nil && $0.role == .user }
            .map { ($0.created ?? .distantPast, $0.ordinal) }.sorted { $0 < $1 }.map { $0.0 }
        var asked: [String: [Int]] = [:]
        for turn in turns where turn.created == nil && turn.role == .user {
            asked[turn.agentID ?? "", default: []].append(turn.ordinal)
        }
        return turns.map { (key($0, questions: questions, asked: asked), $0) }.sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    static func key(_ turn: RemoteTurn, questions: [Date], asked: [String: [Int]]) -> Key {
        let agentID = turn.agentID ?? ""
        if let created = turn.created { return Key(date: created, undated: 0, ordinal: turn.ordinal, agentID: agentID, id: turn.id) }
        let seen = (asked[agentID] ?? []).filter { $0 <= turn.ordinal }.count
        let anchor = questions.isEmpty ? Date.distantPast : questions[min(max(seen - 1, 0), questions.count - 1)]
        return Key(date: anchor, undated: 1, ordinal: turn.ordinal, agentID: agentID, id: turn.id)
    }
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
