import Foundation

public enum PerformanceMetrics {
    public static func elapsedMS(from start: PerformanceEvent, to end: PerformanceEvent, events: [PerformanceEvent]) -> Int64? {
        guard start.comparisonID == end.comparisonID, start.agent?.id == end.agent?.id,
              start.segmentID == end.segmentID, start.stamp.clockID == end.stamp.clockID,
              end.stamp.monotonicMS >= start.stamp.monotonicMS,
              !events.contains(where: { $0.comparisonID == start.comparisonID && $0.sequence > start.sequence && $0.sequence < end.sequence &&
                  ($0.kind == .segmentEnded || ($0.kind == .gap && ($0.agent == nil || $0.agent?.id == start.agent?.id))) }) else { return nil }
        return end.stamp.monotonicMS - start.stamp.monotonicMS
    }
    public static func firstReplyMS(events: [PerformanceEvent], turnID: String?) -> Int64? {
        guard let turnID, let start = events.first(where: { $0.kind == .dispatched && $0.turnID == turnID }),
              let end = events.first(where: { $0.kind == .replyObserved && $0.turnID == turnID }) else { return nil }
        return elapsedMS(from: start, to: end, events: events)
    }
    public static func additionalReplyMS(events: [PerformanceEvent], reply: PerformanceReply) -> Int64? {
        let messages = events.filter { $0.kind == .replyObserved && $0.comparisonID == reply.comparisonID && $0.segmentID == reply.segmentID && $0.agent?.id == reply.agent.id }
        var seen: Set<String> = []
        let firstVersions = messages.filter { seen.insert($0.messageID ?? $0.id).inserted }
        guard let index = firstVersions.firstIndex(where: { $0.messageID == reply.messageID }), index > 0 else { return nil }
        let previous = firstVersions[index - 1], current = firstVersions[index]
        guard previous.turnID == current.turnID, current.turnID != nil else { return nil }
        return elapsedMS(from: previous, to: current, events: events)
    }
    public static func median(_ values: [Int64]) -> Int64? {
        let sorted = values.sorted(); guard !sorted.isEmpty else { return nil }
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
    public static func label(_ milliseconds: Int64) -> String { String(format: "%.1f s", Double(milliseconds) / 1000) }
}
