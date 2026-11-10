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

    /// Events after `after`, waiting up to `timeout` for the first one. Empty on timeout.
    public func wait(after: Int, comparisonID: UUID?, timeout: Duration) async -> [AgentControlEvent] {
        let ready = matching(after: after, comparisonID: comparisonID)
        guard ready.isEmpty else { return ready }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiters[id] = (after, comparisonID, { continuation.resume(returning: $0) })
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                guard let waiter = self.waiters.removeValue(forKey: id) else { return }
                waiter.resume([])
            }
        }
    }
}
