import Foundation

/// Something an outside agent may want to wake up for.
public struct AgentControlEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case replyArrived, agentBusy, agentReady, sendResult, messageReceived, reportReady
    }
    public var seq: Int, kind: Kind, comparisonID: UUID?, agent: String?, detail: String?, date: Date
}

/// The one feed behind `msgblast_blast_wait`, and later MCP Events and Claude Code channels.
@MainActor public final class AgentControlEvents {
    public static let retained = 500
    public private(set) var events: [AgentControlEvent] = []
    private var lastSeq = 0
    private var waiters: [UUID: (after: Int, comparisonID: UUID?, resume: ([AgentControlEvent]) -> Void)] = [:]

    public init() {}

    public var cursor: Int { lastSeq }

    public func publish(_ kind: AgentControlEvent.Kind, comparisonID: UUID? = nil, agent: String? = nil, detail: String? = nil, date: Date = Date()) {
        lastSeq += 1
        events.append(AgentControlEvent(seq: lastSeq, kind: kind, comparisonID: comparisonID, agent: agent, detail: detail, date: date))
        if events.count > Self.retained { events.removeFirst(events.count - Self.retained) }
        for (id, waiter) in waiters {
            let found = matching(after: waiter.after, comparisonID: waiter.comparisonID)
            if !found.isEmpty { waiters[id] = nil; waiter.resume(found) }
        }
    }

    public func matching(after: Int, comparisonID: UUID?) -> [AgentControlEvent] {
        events.filter { $0.seq > after && (comparisonID == nil || $0.comparisonID == comparisonID) }
    }

    /// Waits held at once. A new wait past this ends the oldest one early with no events,
    /// so a client that opens waits in a loop cannot grow memory without bound.
    public static let maximumWaiters = 32
    public var waiterCount: Int { waiters.count }
    private var waiterOrder: [UUID] = []

    /// Events after `after`, waiting up to `timeout` for the first one. Empty on timeout.
    public func wait(after: Int, comparisonID: UUID?, timeout: Duration) async -> [AgentControlEvent] {
        let ready = matching(after: after, comparisonID: comparisonID)
        guard ready.isEmpty, timeout > .zero else { return ready }
        let id = UUID()
        var sleeper: Task<Void, Never>?
        let found = await withCheckedContinuation { continuation in
            waiterOrder.removeAll { waiters[$0] == nil }
            while waiterOrder.count >= Self.maximumWaiters, let oldest = waiterOrder.first {
                waiterOrder.removeFirst()
                waiters.removeValue(forKey: oldest)?.resume([])
            }
            waiters[id] = (after, comparisonID, { continuation.resume(returning: $0) })
            waiterOrder.append(id)
            sleeper = Task { @MainActor in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, let waiter = self.waiters.removeValue(forKey: id) else { return }
                waiter.resume([])
            }
        }
        sleeper?.cancel()
        return found
    }

    private var last: AgentControlSnapshot?
    private var lastLook = Date.distantPast

    /// Compares the app's state with the previous look and publishes what changed. The first
    /// look after `resetObservation()` only records, so turning agent control on replays nothing.
    public func observe(_ snapshot: AgentControlSnapshot, date: Date = Date()) {
        defer { lastLook = date }
        guard let old = last else { last = snapshot; return }
        var next = snapshot
        // A reply still streaming is counted once its agent is no longer busy.
        for key in snapshot.settling { next.replies[key] = old.replies[key] }
        for change in next.changes(since: old.adopting(next, createdBefore: lastLook)) {
            publish(change.kind, comparisonID: change.comparisonID, agent: change.agent, detail: change.detail, date: date)
        }
        last = next
    }

    public func resetObservation() { last = nil }
}

/// What the event feed compares between looks at the app: replies and send states for each
/// agent in recent comparisons, and which agents are busy.
public struct AgentControlSnapshot: Equatable, Sendable {
    /// Only the most recent open comparisons are watched, which keeps each look cheap.
    public static let watchedComparisons = 20
    public struct Key: Hashable, Sendable {
        public var comparisonID: UUID, agent: String
        public init(comparisonID: UUID, agent: String) { self.comparisonID = comparisonID; self.agent = agent }
    }
    public struct Change: Equatable, Sendable {
        public var kind: AgentControlEvent.Kind, comparisonID: UUID?, agent: String?, detail: String?
    }
    /// Replies from each agent, counted.
    public var replies: [Key: Int] = [:]
    /// Each Messages agent's send state (`Submission` raw values).
    public var states: [Key: String] = [:]
    /// Agents still writing a reply; their counts wait until they finish.
    public var settling: Set<Key> = []
    /// Agents busy right now, by name.
    public var busy: Set<String> = []
    /// When each watched comparison was created.
    public var created: [UUID: Date] = [:]

    public init() {}

    /// This look plus `next`'s counts and states for comparisons that joined the watched set
    /// but already existed at `date` (for example when a newer one ended): their history is
    /// recorded, not announced. Comparisons created since then are compared from zero.
    func adopting(_ next: Self, createdBefore date: Date) -> Self {
        let watched = Set(replies.keys.map(\.comparisonID)).union(states.keys.map(\.comparisonID))
        let joined = { (id: UUID) in !watched.contains(id) && (next.created[id] ?? .distantPast) < date }
        var base = self
        for (key, count) in next.replies where joined(key.comparisonID) { base.replies[key] = count }
        for (key, state) in next.states where joined(key.comparisonID) { base.states[key] = state }
        return base
    }

    public func changes(since old: Self) -> [Change] {
        var changes: [Change] = []
        for key in replies.keys.sorted(by: Self.order) where (replies[key] ?? 0) > (old.replies[key] ?? 0) {
            changes.append(Change(kind: .replyArrived, comparisonID: key.comparisonID, agent: key.agent, detail: nil))
        }
        for key in states.keys.sorted(by: Self.order) {
            guard let state = states[key], state != old.states[key], Self.settledStates.contains(state) else { continue }
            changes.append(Change(kind: .sendResult, comparisonID: key.comparisonID, agent: key.agent, detail: state))
        }
        for name in busy.subtracting(old.busy).sorted() { changes.append(Change(kind: .agentBusy, comparisonID: nil, agent: name, detail: nil)) }
        for name in old.busy.subtracting(busy).sorted() { changes.append(Change(kind: .agentReady, comparisonID: nil, agent: name, detail: nil)) }
        return changes
    }

    private static let settledStates: Set<String> = ["submitted", "failed", "uncertain"]
    private static func order(_ a: Key, _ b: Key) -> Bool { (a.comparisonID.uuidString, a.agent) < (b.comparisonID.uuidString, b.agent) }
}
