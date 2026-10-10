import SwiftUI
import msgblastCore

struct ComparisonReportView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var agent: PersonalAgentController
    let comparisonID: UUID
    @State private var snapshot: ComparisonSummaryInput?
    @State private var formattedComparison = AttributedString()
    @State private var showingOptions = false

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
            HStack {
                if running {
                    ProgressView("Updating report…").controlSize(.small)
                } else if agent.discovering {
                    ProgressView("Finding installed agents…").controlSize(.small)
                } else {
                    Text(agent.demo ? "Simulated report · no provider request" : "Uses \(selected?.name ?? "your selected agent") · text only, attachments excluded")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if running {
                    Button("Cancel report") { agent.cancel(comparisonID) }
                } else {
                    Button(summary?.report == nil ? "Generate report" : "Update report") {
                        if let selected { agent.summarize(comparisonID, provider: selected, model: model) }
                    }.buttonStyle(.borderedProminent)
                        .disabled(agent.discovering || (snapshot?.responseCount ?? 0) == 0 || !model.databaseAvailable || !agent.installed.contains(where: { $0.provider == selected }))
                }
                Menu {
                    Button("Copy report") {
                        guard let summary else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(summary.text, forType: .string)
                    }.disabled(summary == nil)
                    Divider()
                    Button("Report options…") { showingOptions = true }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Report actions")
                .accessibilityIdentifier("Report actions")
                .help("Copy report or change report options")
                .popover(isPresented: $showingOptions) {
                    reportOptions(running: running)
                }
            }
            if !agent.discovering && agent.installed.isEmpty {
                Text("No supported agent CLI found. Open Report options to set one up.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if let selected, let reason = selected.unavailabilityReason {
                Text(reason).font(.callout).foregroundStyle(.orange)
            }
            Divider()
            if let error = agent.errors[comparisonID] {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let summary {
                Text("\(summary.respondingMemberCount) of \(summary.memberCount) participants · \(summary.responseCount) responses")
                    .font(.caption).foregroundStyle(.secondary)
                if let snapshot, snapshot.fingerprint != summary.fingerprint {
                    Label("Conversation changed · update the report to include the latest replies.", systemImage: "arrow.clockwise")
                        .font(.callout).foregroundStyle(.orange)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if let report = summary.report {
                            Text(report.overviewText).font(.title3)
                                .accessibilityIdentifier("Report overview")
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Findings").font(.title2.bold())
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
                            Text("Saved summary · update to include the latest findings.").font(.callout).foregroundStyle(.secondary)
                            Text(summary.text)
                        }
                    }
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
                Text("Prepared by \(summary.provider) · Saved \(summary.created.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            } else {
                ContentUnavailableView(running ? "Preparing your comparison report…" : "Ready for a comparison report", systemImage: "doc.text.magnifyingglass",
                    description: Text((snapshot?.responseCount ?? 0) == 0 ? "Waiting for the first response." : "Your personal agent will synthesize the conversations into shared findings, differences, and open questions."))
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

    private func reportOptions(running: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Report options").font(.headline)
            Picker("Personal agent", selection: Binding(get: { selected?.rawValue ?? "" }, set: {
                model.state.personalAgentProvider = $0; model.persist()
            })) {
                if let selected, !agent.installed.contains(where: { $0.provider == selected }) {
                    Text("\(selected.name) · unavailable").tag(selected.rawValue)
                }
                ForEach(agent.installed) { installed in
                    Text(agent.demo ? "Demo analyst (simulated)" : installed.provider.name).tag(installed.id)
                }
            }.disabled(running || agent.discovering || agent.installed.isEmpty)
            Text(agent.demo ? "Demo uses synthetic replies and a simulated report. No provider request is made." : "Report updates send this comparison’s text to the selected provider using its existing sign-in and plan. Attachment contents are not included. Changing agents does not request a report until you click Update report.")
                .font(.caption).foregroundStyle(.secondary)
            if !agent.demo {
                Text(selected?.unavailabilityReason ?? selected.map { "Sign in or troubleshoot in Terminal: \($0.setup)" } ?? "Install and sign in to Codex, Claude Code, Gemini CLI, Pi, or Hermes in Terminal, then refresh.")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Button(agent.discovering ? "Finding agents…" : "Refresh agents") {
                Task { await agent.discover() }
            }.disabled(agent.discovering || running)
        }.padding(20).frame(width: 360)
    }

}
