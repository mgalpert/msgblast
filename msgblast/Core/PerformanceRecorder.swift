import Foundation

/// Capture only through explicit enabled hooks; errors propagate to the app, never to send retry logic.
public final class PerformanceRecorder {
    public var enabled = false
    public let fixture: Bool
    private let store: PerformanceStore
    private var segments: [String: String] = [:]
    private var partialComparisons: Set<String> = []
    public func markPartial(_ comparisonID: String) { partialComparisons.insert(comparisonID) }
    public var events: [PerformanceEvent] { store.events }
    public var activeComparisonIDs: [String] { segments.keys.sorted() }
    public init(directory: URL, fixture: Bool) throws { self.fixture = fixture; store = try PerformanceStore(directory: directory) }
    private var projectionCount = 0
    private var projectedReplies: [PerformanceReply] = []
    private var replyIndexes: [String: Int] = [:]
    public var replies: [PerformanceReply] {
        for event in events.dropFirst(projectionCount) {
            guard let agent = event.agent, let message = event.messageID else { continue }
            let key = event.comparisonID + ":" + event.segmentID + ":" + agent.id + ":" + message
            if event.kind == .replyObserved, let text = event.text {
                if let i = replyIndexes[key] {
                    projectedReplies[i].text = text
                    projectedReplies[i].businessChoices = event.businessChoices
                } else {
                    replyIndexes[key] = projectedReplies.count
                    projectedReplies.append(.init(comparisonID: event.comparisonID, segmentID: event.segmentID, agent: agent, messageID: message, text: text, turnID: event.turnID, scope: event.scope ?? .unknown, businessChoices: event.businessChoices))
                }
            } else if event.kind == .feedback, let selection = event.selection,
                      let i = replyIndexes[key] {
                projectedReplies[i].feedback = selection
            }
        }
        projectionCount = events.count
        return projectedReplies
    }
    @discardableResult
    public func record(_ kind: PerformanceEventKind, comparisonID: String, agent: PerformanceAgent? = nil, turnID: String? = nil, scope: PerformanceScope? = nil, messageID: String? = nil, text: String? = nil, businessChoices: BusinessMessageCard? = nil, sourceMS: Int64? = nil, method: String? = nil, reason: String? = nil, requestGroup: PerformanceRequestGroup? = nil, at stamp: PerformanceStamp = .now) throws -> PerformanceEvent? {
        guard enabled else { return nil }
        if segments[comparisonID] == nil {
            let segment = UUID().uuidString; segments[comparisonID] = segment
            let partial = partialComparisons.contains(comparisonID) || events.contains { $0.comparisonID == comparisonID }
            _ = try store.append(.init(sequence: 0, comparisonID: comparisonID, segmentID: segment, kind: .segmentStarted, stamp: stamp, fixture: fixture, reason: partial ? "resumed-partial" : "recording-started"))
        }
        let position = kind == .turnStarted ? events.filter { $0.comparisonID == comparisonID && $0.agent?.id == agent?.id && $0.kind == .turnStarted }.count : nil
        return try store.append(.init(sequence: 0, comparisonID: comparisonID, segmentID: segments[comparisonID]!, kind: kind, stamp: stamp, fixture: fixture, agent: agent, turnID: turnID, turnPosition: position, requestGroupID: requestGroup?.id, targetAgentIDs: requestGroup?.targetAgentIDs, scope: scope, messageID: messageID, text: text, businessChoices: businessChoices, sourceMS: sourceMS, method: method, reason: reason))
    }
    @discardableResult
    public func beginTurn(comparisonID: String, agent: PerformanceAgent, text: String, scope: PerformanceScope, requestGroup: PerformanceRequestGroup? = nil, at stamp: PerformanceStamp = .now) throws -> String? {
        guard enabled else { return nil }
        let turn = UUID().uuidString
        _ = try record(.turnStarted, comparisonID: comparisonID, agent: agent, turnID: turn, scope: scope, text: text, requestGroup: requestGroup, at: stamp)
        return turn
    }
    public func reply(comparisonID: String, agent: PerformanceAgent, messageID: String, text: String, turnID: String?, businessChoices: BusinessMessageCard? = nil, sourceMS: Int64? = nil, method: String = "native-observation", at stamp: PerformanceStamp = .now) throws {
        guard enabled, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let scope = events.last { $0.kind == .turnStarted && $0.turnID == turnID && turnID != nil }?.scope ?? .unknown
        if let existing = replies.last(where: { $0.comparisonID == comparisonID && $0.segmentID == segments[comparisonID] && $0.agent.id == agent.id && $0.messageID == messageID }), existing.text == text && existing.businessChoices == businessChoices { return }
        _ = try record(.replyObserved, comparisonID: comparisonID, agent: agent, turnID: turnID, scope: scope, messageID: messageID, text: text, businessChoices: businessChoices, sourceMS: sourceMS, method: method, reason: turnID == nil ? "ambiguous-turn" : nil, at: stamp)
    }
    /// A baseline card can change after relaunch. Revise only an already recorded
    /// business reply, retaining its original turn/scope rather than importing history.
    public func updateRecordedBusinessChoices(comparisonID: String, agentID: String, messageID: String, text: String, businessChoices: BusinessMessageCard) throws {
        guard enabled, let original = events.last(where: {
            $0.kind == .replyObserved && $0.comparisonID == comparisonID && $0.agent?.id == agentID && $0.messageID == messageID
        }), original.businessChoices != nil,
        original.text != text || original.businessChoices != businessChoices else { return }
        var revision = original
        revision.id = UUID().uuidString; revision.sequence = 0; revision.previousHash = nil
        revision.stamp = .now; revision.text = text; revision.businessChoices = businessChoices
        revision.method = "messages-business-card-state; original recorded association retained"
        _ = try store.append(revision)
    }
    public func setFeedback(comparisonID: String, agentID: String, messageID: String, selection: PerformanceFeedback, segmentID: String? = nil) throws {
        guard enabled, let reply = replies.last(where: { $0.comparisonID == comparisonID && $0.agent.id == agentID && $0.messageID == messageID && (segmentID == nil || $0.segmentID == segmentID) }) else { return }
        guard reply.feedback != selection else { return }
        _ = try store.append(.init(sequence: 0, comparisonID: comparisonID, segmentID: reply.segmentID, kind: .feedback, stamp: .now, fixture: fixture, agent: reply.agent, scope: reply.scope, messageID: messageID, selection: selection))
    }
    public func stop(reason: String) throws {
        for comparison in segments.keys.sorted() {
            _ = try record(.segmentEnded, comparisonID: comparison, reason: reason)
        }
        segments = [:]
    }
    public func deleteAll() throws { try store.deleteAll(); segments = [:]; projectionCount = 0; projectedReplies = []; replyIndexes = [:] }
}
