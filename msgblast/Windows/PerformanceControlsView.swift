import SwiftUI
import msgblastCore

struct PerformanceControlsView: View {
    @ObservedObject var performance: PerformanceController
    let reply: PerformanceReply
    @State private var details = false
    var body: some View {
        if performance.enabled {
        HStack(spacing: 8) {
            if let interval = PerformanceMetrics.additionalReplyMS(events: performance.events, reply: reply) {
                Text("Next reply +\(PerformanceMetrics.label(interval))").font(.caption).foregroundStyle(.secondary)
            } else if let latency = PerformanceMetrics.firstReplyMS(events: performance.events, turnID: reply.turnID) {
                Text("\(reply.agent.connection == .cli ? "Final observed" : reply.agent.connection == .grokBot ? "Callback observed" : "Observed") \(PerformanceMetrics.label(latency))").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Timing unavailable").font(.caption).foregroundStyle(.secondary)
            }
            Button { performance.feedback(reply, .favorite) } label: {
                Image(systemName: reply.feedback == .favorite ? "star.fill" : "star")
            }.accessibilityLabel(reply.feedback == .favorite ? "Clear favorite" : "Favorite reply")
                .accessibilityIdentifier("favorite-" + reply.messageID)
                .help("Favorite in msgblast; no provider reaction is sent")
            Button { performance.feedback(reply, .negative) } label: {
                Image(systemName: reply.feedback == .negative ? "hand.thumbsdown.fill" : "hand.thumbsdown")
            }.accessibilityLabel(reply.feedback == .negative ? "Clear thumbs down" : "Thumbs down reply")
                .accessibilityIdentifier("negative-" + reply.messageID)
                .help("Preference in msgblast; no provider reaction is sent")
            Button { details = true } label: { Image(systemName: "info.circle") }.accessibilityLabel("Measurement details")
                .popover(isPresented: $details) { PerformanceMeasurementDetails(events: performance.events, reply: reply).padding(16).frame(width: 360) }
            Spacer(minLength: 0)
        }.buttonStyle(.borderless).controlSize(.small)
            .foregroundStyle(reply.feedback == .unmarked ? Color.secondary : Color.accentColor)
            .accessibilityElement(children: .contain)
        }
    }
}

struct PerformanceMeasurementDetails: View {
    let events: [PerformanceEvent]
    let reply: PerformanceReply
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recorded measurement").font(.headline)
            Text("Scope: \(reply.scope.rawValue). Local preference; no correctness score.")
            if let first = events.first(where: { $0.kind == .replyObserved && $0.segmentID == reply.segmentID && $0.agent?.id == reply.agent.id && $0.messageID == reply.messageID }) {
                Text(first.method ?? "Observation method unknown")
                Text("Clock: native monotonic receipt times. Wall and source timestamps are separate.")
                if let turn = first.turnID, let start = events.first(where: { $0.kind == .turnStarted && $0.turnID == turn }) {
                    Text(start.turnPosition == 0 ? "Initial recorded turn" : "User follow-up")
                    if let submitted = events.first(where: { $0.kind == .submitted && $0.turnID == turn }), let ms = PerformanceMetrics.elapsedMS(from: start, to: submitted, events: events) { Text("Recorded attempt → observed submission: \(PerformanceMetrics.label(ms))") }
                    if let dispatch = events.first(where: { $0.kind == .dispatched && $0.turnID == turn }), let completion = events.first(where: { $0.kind == .completed && $0.turnID == turn }), let ms = PerformanceMetrics.elapsedMS(from: dispatch, to: completion, events: events) { Text("Dispatch → observed answer completion: \(PerformanceMetrics.label(ms))") }
                }
                if let source = first.sourceMS {
                    Text("Source timestamp: \(Date(timeIntervalSince1970: Double(source) / 1000).formatted())")
                    if let outgoing = events.last(where: { $0.kind == .submitted && $0.turnID == first.turnID && $0.sourceMS != nil && $0.sequence < first.sequence }),
                       let start = outgoing.sourceMS, source >= start { Text("Outgoing → reply source interval: \(PerformanceMetrics.label(source - start)) (separate source clock)") }
                }
                if first.turnID == nil { Text("Turn association is ambiguous or was not observed.") }
            }
            if let interval = PerformanceMetrics.additionalReplyMS(events: events, reply: reply) { Text("Previous distinct reply → this reply: \(PerformanceMetrics.label(interval))") }
            Text("DOM updates are not model tokens. Submission does not establish delivery or task success. Messages completion and final-only CLI streaming are unavailable.").foregroundStyle(.secondary)
        }.font(.caption).textSelection(.enabled)
    }
}

struct PerformanceReplyStrip: View {
    @ObservedObject var performance: PerformanceController
    let comparisonID: String
    let agentID: String
    var body: some View {
        let replies = performance.replies.filter { $0.comparisonID == comparisonID && $0.agent.id == agentID }
        VStack(alignment: .leading, spacing: 5) {
            if replies.isEmpty {
                Text("Recording locally · no observed reply yet").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(replies) { reply in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(reply.text).font(.caption).lineLimit(2).help(reply.text)
                                PerformanceControlsView(performance: performance, reply: reply)
                            }.padding(4)
                        }
                    }
                }.frame(height: min(CGFloat(replies.count) * 62, 120))
            }
        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.05))
            .accessibilityLabel("Recorded website replies")
    }
}

struct MessagesPerformanceControl: View {
    @ObservedObject var performance: PerformanceController
    let comparisonID: String
    let agentID: String
    let messageID: String
    var body: some View {
        if performance.enabled, let reply = performance.replies.last(where: { $0.comparisonID == comparisonID && $0.agent.id == agentID && $0.messageID == messageID }) {
            PerformanceControlsView(performance: performance, reply: reply)
        }
    }
}
