import SwiftUI
import msgblastCore

struct MyStatsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var performance: PerformanceController
    @State private var days = 30
    @State private var selected: PerformanceReply?
    @State private var deleting = false
    private func providerName(_ agent: PerformanceAgent) -> String {
        agent.provider.flatMap { WebProvider(rawValue: $0)?.name } ?? (agent.connection == .messages ? "Messages" : "Unknown provider")
    }
    private func timingName(_ agent: PerformanceAgent) -> String {
        switch agent.connection {
        case .cli: "final output"
        case .grokBot: "callback answer"
        default: "observed reply"
        }
    }
    @ViewBuilder private func timingRow(_ label: String, median: Int64?, samples: Int) -> some View {
        if let median { Text("\(label) median: \(PerformanceMetrics.label(median)) · \(PersonalUsageStats.count(samples, "sample"))") }
        else { Text("\(label) timing unavailable · 0 samples").foregroundStyle(.secondary) }
    }
    var body: some View {
        let since = days == 0 ? Date.distantPast : Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let stats = PersonalUsageStats(events: performance.events, since: since)
        Form {
            Section {
                Toggle("Performance & Benchmarks", isOn: Binding(get: { model.state.performanceTrackingEnabled }, set: { model.setPerformanceTracking($0) }))
                    .accessibilityIdentifier("performance-tracking")
                Text("Record subsequent comparison activity on this Mac. No account or network is needed. This does not enable sync, publication, or contribution.").font(.caption).foregroundStyle(.secondary)
                if !model.state.performanceTrackingEnabled { Text("Tracking is off. Existing records are retained; no historical activity is estimated.").font(.caption) }
                if let error = performance.error { Text("Recording unavailable: \(error)").foregroundStyle(.orange) }
            }
            Section("My recorded activity") {
                Picker("Date range", selection: $days) {
                    Text("7 days").tag(7); Text("30 days").tag(30); Text("All recorded").tag(0)
                }.pickerStyle(.segmented)
                Text("\(PersonalUsageStats.count(stats.comparisonCount, "recorded comparison")) · \(PersonalUsageStats.count(stats.turnCount, "attempted agent turn"))")
                    .accessibilityIdentifier("stats-counts")
                Text("\(PersonalUsageStats.count(stats.partialCount, "comparison")) with partial segments or gaps. Counts cover only enabled recording boundaries.").font(.caption).foregroundStyle(.secondary)
                if stats.turnCount == 0 { Text("No recorded turns in this range. Enable tracking, then send a comparison to begin.").foregroundStyle(.secondary) }
            }
            Section("Usage by configured agent") {
                ForEach(stats.agents) { usage in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(usage.agent.name == providerName(usage.agent) ? usage.agent.name : "\(usage.agent.name) · \(providerName(usage.agent))").font(.headline)
                        Text("\(PersonalUsageStats.count(usage.turns, "attempt")) · \(usage.initialSamples) initial · \(PersonalUsageStats.count(usage.followUpSamples, "follow-up"))")
                        timingRow("Initial \(timingName(usage.agent))", median: usage.medianInitialReplyMS, samples: usage.initialTimingSamples)
                        timingRow("Follow-up \(timingName(usage.agent))", median: usage.medianFollowUpReplyMS, samples: usage.followUpTimingSamples)
                        Text("Observed reply rate: \(PersonalUsageStats.rate(usage.replied, of: usage.turns)) attempts")
                        if usage.agent.connection == .messages {
                            Text("Completion unavailable for Messages").font(.caption).foregroundStyle(.secondary)
                        } else if usage.completionSamples == 0 {
                            Text("Completion unavailable · no supported end signal recorded").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Observed answer completion: \(PersonalUsageStats.rate(usage.completed, of: usage.completionSamples)) supported attempts").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Observed outcomes: failed \(usage.failed)/\(usage.turns) · canceled \(usage.canceled)/\(usage.turns) · uncertain \(usage.uncertain)/\(usage.turns) · no terminal observation \(usage.unobserved)/\(usage.turns)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Rates use the same recorded attempt cohort. Completion uses only supported signals and describes an answer, not task quality. No token or cost estimates.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Recorded trend") {
                ForEach(stats.dailyTurns.suffix(7), id: \.day) { day in
                    HStack { Text(day.day.formatted(date: .abbreviated, time: .omitted)); Spacer(); Text(PersonalUsageStats.count(day.count, "attempted turn")) }
                }
                Text("Last 7 active dates within the selected range. Gaps are not estimated.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Favorites · all recorded dates") {
                let favorites = performance.replies.filter { $0.feedback == .favorite }
                if favorites.isEmpty { Text("Favorite replies appear here. Stars are local preferences.").foregroundStyle(.secondary) }
                ForEach(favorites) { reply in
                    Button { selected = reply } label: {
                        VStack(alignment: .leading) { Text(reply.agent.name); Text(reply.text).font(.caption).lineLimit(2) }
                    }.accessibilityLabel("Open recorded favorite from " + reply.agent.name)
                }
            }
            Section {
                Button("Delete local performance records…", role: .destructive) { deleting = true }.disabled(performance.events.isEmpty && performance.error == nil)
                Text("Conversation drafts and Messages history are retained.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
            .confirmationDialog("Delete local performance records and preferences?", isPresented: $deleting) {
                Button("Delete records", role: .destructive) { model.setPerformanceTracking(false); performance.deleteAll() }
            }
            .sheet(item: $selected) { reply in
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.state.comparisons.first { $0.id.uuidString == reply.comparisonID }?.title ?? "Recorded comparison").font(.title2)
                    Text("Saved local comparison · opens without contacting a provider").font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(performance.replies.filter { $0.comparisonID == reply.comparisonID }) { item in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.agent.name).font(.headline)
                                    Text(item.text).textSelection(.enabled)
                                    PerformanceControlsView(performance: performance, reply: item)
                                }.padding(12).background(item.id == reply.id ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                    Button("Done") { selected = nil }.keyboardShortcut(.cancelAction)
                }.padding(20).frame(width: 600, height: 500)
            }
    }
}
