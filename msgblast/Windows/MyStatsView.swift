import SwiftUI

@MainActor
struct MyStatsView: View {
    @ObservedObject var stats: LocalSubmissionStats
    let recipientNames: [String: String]
    @State private var confirmingClear = false

    var body: some View {
        Section {
            Toggle("Record submission stats", isOn: Binding(get: { stats.enabled }, set: { stats.setEnabled($0) }))
                .accessibilityIdentifier("my-stats-recording")
            Text("Recording starts with your next send. Pausing keeps your saved stats. My Stats stays on this Mac.")
                .font(.callout).foregroundStyle(.secondary)
            if let error = stats.error {
                Text(error).foregroundStyle(.secondary)
            }
            if !stats.attempts.isEmpty || stats.error != nil {
                Button("Clear Saved Stats…", role: .destructive) { confirmingClear = true }
                    .confirmationDialog("Clear all saved submission stats?", isPresented: $confirmingClear) {
                        Button("Clear Stats", role: .destructive) { stats.clear() }
                    }
            }
        }

        if stats.attempts.isEmpty {
            Section {
                Text("No submission stats yet.").foregroundStyle(.secondary)
            }
        } else {
            Section("Submission attempts") {
                LabeledContent("Recorded turns", value: Set(stats.attempts.map(\.turnID)).count.formatted())
                Text("A retry adds an attempt to its original turn. Timing uses observed submission results and excludes reply time.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(summaries, id: \.key) { group in
                Section(recipientNames[group.key] ?? "Removed recipient") {
                    if !group.value.initial.isEmpty {
                        summary("Initial turns", attempts: group.value.initial)
                    }
                    if !group.value.followUp.isEmpty {
                        summary("Follow-ups", attempts: group.value.followUp)
                    }
                }
            }
        }
    }

    private var summaries: [(key: String, value: (initial: [LocalSubmissionStats.Attempt], followUp: [LocalSubmissionStats.Attempt]))] {
        Dictionary(grouping: stats.attempts, by: \.recipientID)
            .mapValues { attempts in (attempts.filter { !$0.isFollowUp }, attempts.filter(\.isFollowUp)) }
            .sorted {
                let first = recipientNames[$0.key] ?? $0.key
                let second = recipientNames[$1.key] ?? $1.key
                return first == second ? $0.key < $1.key : first.localizedStandardCompare(second) == .orderedAscending
            }
    }

    private func summary(_ title: String, attempts: [LocalSubmissionStats.Attempt]) -> some View {
        let submitted = attempts.filter { $0.outcome == .submitted }
        let failed = attempts.filter { $0.outcome == .failed }.count
        let uncertain = attempts.count - submitted.count - failed
        let timings = submitted.compactMap(\.seconds).sorted()
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.medium))
            Text("\(submitted.count) submitted · \(failed) failed · \(uncertain) uncertain")
            if timings.isEmpty {
                Text("Median submission time unavailable")
            } else {
                let median = (timings[(timings.count - 1) / 2] + timings[timings.count / 2]) / 2
                Text("Median submission time \(median.formatted(.number.precision(.fractionLength(2)))) s · \(timings.count) timed")
            }
        }
        .foregroundStyle(.secondary)
    }
}
