import SwiftUI
import msgblastCore

struct ComparisonReportView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var agent: PersonalAgentController
    let comparisonID: UUID
    @State private var snapshot: ComparisonSummaryInput?
    @State private var formattedComparison = AttributedString()

    private var selected: PersonalAgentProvider? { agent.selectedProvider(model: model) }
    private func refreshSnapshot() { snapshot = try? agent.input(for: comparisonID, model: model) }

    var body: some View {
        let summary = model.comparison(comparisonID)?.summary
        let running = agent.running.contains(comparisonID)
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Comparison report", systemImage: "sparkles").font(.largeTitle.bold())
                Text(model.comparison(comparisonID)?.prompt ?? "").font(.title3).foregroundStyle(.secondary)
                    .lineLimit(3).textSelection(.enabled)
            }
            if agent.discovering {
                ProgressView("Finding installed agents…").controlSize(.small)
            } else if agent.installed.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No supported agent CLI found").font(.headline)
                    Text("Install and sign in to Codex, Claude Code, Gemini CLI, Pi, Grok, or Hermes in Terminal, then refresh.")
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Picker("Personal agent", selection: Binding(get: { selected?.rawValue ?? "" }, set: {
                        model.state.personalAgentProvider = $0; model.persist()
                    })) {
                        if let selected, !agent.installed.contains(where: { $0.provider == selected }) {
                            Text("\(selected.name) · \(selected.unavailabilityReason == nil ? "not found" : "unavailable")").tag(selected.rawValue)
                        }
                        ForEach(agent.installed) { installed in
                            Text(agent.demo ? "Demo analyst (simulated)" : installed.provider.name).tag(installed.id)
                        }
                    }.disabled(running).frame(maxWidth: 340)
                    Spacer()
                    if running {
                        ProgressView().controlSize(.small)
                        Button("Cancel report") { agent.cancel(comparisonID) }
                    } else {
                        Button(summary?.report == nil ? "Generate report" : "Update report") {
                            if let selected { agent.summarize(comparisonID, provider: selected, model: model) }
                        }.buttonStyle(.borderedProminent)
                            .disabled((snapshot?.responseCount ?? 0) == 0 || !model.databaseAvailable || !agent.installed.contains(where: { $0.provider == selected }))
                    }
                }
            }
            HStack(alignment: .top) {
                Text(agent.demo ? "Demo uses synthetic replies and a simulated report. No provider request is made." : "Summarize sends this comparison’s text to your selected agent’s provider using its existing sign-in and plan. Attachment contents are not included.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("Refresh agents") { Task { await agent.discover() } }.disabled(agent.discovering || running)
            }
            LocalAgentSettingsView(agent: agent, busy: running)
            if let selected, !agent.demo {
                Text(selected.unavailabilityReason ?? "Sign in or troubleshoot in Terminal: \(selected.setup)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Divider()
            if let error = agent.errors[comparisonID] {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let summary {
                HStack {
                    Text("\(summary.provider) · \(summary.respondingMemberCount) of \(summary.memberCount) participants · \(summary.responseCount) responses")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy report") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(summary.text, forType: .string) }
                }
                if let snapshot, snapshot.fingerprint != summary.fingerprint {
                    Label("Conversation changed · update the report to include the latest replies.", systemImage: "arrow.clockwise")
                        .font(.callout).foregroundStyle(.orange)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if let report = summary.report {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("Best next action", systemImage: "arrow.right.circle.fill")
                                    .font(.headline).foregroundStyle(.blue)
                                Text(report.bestNextAction).font(.title3.weight(.semibold))
                                    .accessibilityIdentifier("Best next action text")
                                Text(report.rationale).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                            .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                            .accessibilityElement(children: .contain)
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Comparison").font(.title2.bold())
                                Text(formattedComparison)
                                    .accessibilityIdentifier("Comparison report text")
                            }.accessibilityElement(children: .contain)
                            if !report.uncertainties.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Open questions").font(.headline)
                                    ForEach(Array(report.uncertainties.enumerated()), id: \.offset) { _, question in
                                        Text("• " + question)
                                    }
                                }.foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Saved summary · generate a report for a recommended next action.").font(.callout).foregroundStyle(.secondary)
                            Text(summary.text)
                        }
                    }
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
                Text("Saved \(summary.created.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            } else {
                ContentUnavailableView(running ? "Preparing your comparison report…" : "Ready for a comparison report", systemImage: "doc.text.magnifyingglass",
                    description: Text((snapshot?.responseCount ?? 0) == 0 ? "Waiting for the first response." : "Your personal agent will compare the replies and recommend your best next action."))
            }
        }
        .padding(24).frame(minWidth: 620, minHeight: 560)
        .task { refreshSnapshot() }
        .onChange(of: summary?.report?.comparison, initial: true) { _, text in
            let text = text ?? ""
            formattedComparison = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        }
        .onChange(of: model.comparison(comparisonID)?.members.map { model.messages[$0.chat.id] ?? [] }) { refreshSnapshot() }
        .onChange(of: model.state.comparisons.flatMap(\.members)) { refreshSnapshot() }
    }
}
