import Foundation

public struct PersonalUsageStats {
    public struct AgentUsage: Identifiable {
        public var id: String { agent.id }
        public var agent: PerformanceAgent
        public var turns: Int
        public var initialSamples: Int
        public var followUpSamples: Int
        public var medianReplyMS: Int64?
        public var timingSamples: Int
        public var medianInitialReplyMS: Int64?
        public var initialTimingSamples: Int
        public var medianFollowUpReplyMS: Int64?
        public var followUpTimingSamples: Int
        public var replied: Int
        public var completionSamples: Int
        public var completed: Int
        public var failed: Int
        public var canceled: Int
        public var uncertain: Int
        public var unobserved: Int
    }
    public var comparisonCount: Int
    public var turnCount: Int
    public var partialCount: Int
    public var agents: [AgentUsage]
    public var dailyTurns: [(day: Date, count: Int)]
    /// Date range selects attempted turns. Every numerator and timing sample uses
    /// that same cohort, with outcomes observed up to `until`.
    public init(events: [PerformanceEvent], since: Date = .distantPast, until: Date = .distantFuture) {
        func date(_ event: PerformanceEvent) -> Date { Date(timeIntervalSince1970: Double(event.stamp.wallMS) / 1000) }
        let available = events.filter { date($0) <= until }
        let comparisons = Dictionary(grouping: available, by: \.comparisonID)
        let relevant = available.filter { date($0) >= since }
        let turns = relevant.filter { $0.kind == .turnStarted }
        let groups = Dictionary(grouping: available.compactMap { event -> PerformanceEvent? in event.turnID == nil ? nil : event }) { $0.turnID! }
        comparisonCount = Set(relevant.filter { $0.kind == .segmentStarted || $0.kind == .turnStarted }.map(\.comparisonID)).count
        turnCount = turns.count
        partialCount = Set(relevant.filter { ($0.kind == .segmentStarted && $0.reason != "recording-started") || $0.kind == .gap || ($0.kind == .segmentEnded && $0.reason == "disabled-in-flight") }.map(\.comparisonID)).count
        agents = Set(turns.compactMap(\.agent?.id)).sorted().compactMap { id in
            let own = turns.filter { $0.agent?.id == id }
            guard let agent = own.last?.agent else { return nil }
            let initial = own.filter { $0.turnPosition == 0 }
            let followUps = own.filter { $0.turnPosition != 0 }
            func timings(_ subset: [PerformanceEvent]) -> [Int64] { subset.compactMap { PerformanceMetrics.firstReplyMS(events: comparisons[$0.comparisonID] ?? [], turnID: $0.turnID) } }
            let timing = timings(own), initialTiming = timings(initial), followUpTiming = timings(followUps)
            var replied = 0, supported = 0, completed = 0, failed = 0, canceled = 0, uncertain = 0
            for turn in own {
                let observations = turn.turnID.flatMap { groups[$0] } ?? []
                if observations.contains(where: { $0.kind == .replyObserved }) { replied += 1 }
                let dispatched = observations.contains { $0.kind == .dispatched }
                let completionObserved = observations.contains { $0.kind == .completed }
                let generationSupported = observations.contains { $0.kind == .observationState && ["generating", "idle"].contains($0.reason ?? "") }
                if agent.connection != .messages && (completionObserved || (dispatched && ([.cli, .grokBot].contains(agent.connection) || generationSupported))) { supported += 1 }
                guard let terminal = observations.last(where: { $0.kind == .completed || ($0.kind == .outcome && ["failed", "canceled", "uncertain"].contains($0.reason ?? "")) }) else { continue }
                if terminal.kind == .completed { completed += 1 }
                else if terminal.reason == "failed" { failed += 1 }
                else if terminal.reason == "canceled" { canceled += 1 }
                else if terminal.reason == "uncertain" { uncertain += 1 }
            }
            return AgentUsage(agent: agent, turns: own.count, initialSamples: initial.count, followUpSamples: followUps.count,
                medianReplyMS: PerformanceMetrics.median(timing), timingSamples: timing.count,
                medianInitialReplyMS: PerformanceMetrics.median(initialTiming), initialTimingSamples: initialTiming.count,
                medianFollowUpReplyMS: PerformanceMetrics.median(followUpTiming), followUpTimingSamples: followUpTiming.count,
                replied: replied, completionSamples: supported, completed: completed, failed: failed, canceled: canceled, uncertain: uncertain,
                unobserved: own.count - completed - failed - canceled - uncertain)
        }
        let days = Dictionary(grouping: turns) { Calendar.current.startOfDay(for: date($0)) }
        dailyTurns = days.keys.sorted().map { ($0, days[$0]!.count) }
    }
    public static func count(_ value: Int, _ singular: String, _ plural: String? = nil) -> String { "\(value) \(value == 1 ? singular : plural ?? singular + "s")" }
    public static func rate(_ numerator: Int, of denominator: Int) -> String {
        guard denominator > 0 else { return "Unavailable (no supported attempts)" }
        return "\(numerator)/\(denominator) (\(Int((Double(numerator) / Double(denominator) * 100).rounded()))%)"
    }
}
