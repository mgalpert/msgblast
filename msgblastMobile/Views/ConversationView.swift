import SwiftUI
import msgblastMobileKit
import msgblastRemoteProtocol

struct ConversationView: View {
    @ObservedObject var app: MobileApp
    let conversationID: UUID
    /// nil = All; otherwise one agent's private thread.
    @State private var filter: String?
    @State private var recipients: [String] = []
    @State private var actionError: String?
    @State private var confirmEnd = false
    @State private var details: IncompleteSummary?

    private var presenter: ProjectionPresenter { ProjectionPresenter(state: app.store.projection, commands: app.store.commands) }
    private var conversation: RemoteConversation? { app.store.projection.conversations[conversationID] }

    var body: some View {
        if let conversation {
            content(conversation)
        } else {
            ContentUnavailableView("Not on Your Mac", systemImage: "questionmark.bubble")
        }
    }

    private func content(_ conversation: RemoteConversation) -> some View {
        let turns = presenter.turns(in: conversationID, agentID: filter)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if conversation.agentIDs.count > 1 {
                        Picker("Show", selection: $filter) {
                            Text("All").tag(String?.none)
                            ForEach(conversation.agentIDs, id: \.self) { Text(presenter.shortName($0)).tag(String?.some($0)) }
                        }.pickerStyle(.segmented)
                    }
                    ForEach(conversation.incompleteAttempts, id: \.attemptID) { incomplete in incompleteRow(incomplete) }
                    ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                        bubble(turn, showsName: turn.role != .user && (index == 0 || turns[index - 1].agentID != turn.agentID)).id(turn.id)
                    }
                    if let actionError { Text(actionError).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity) }
                    if conversation.endedAt != nil { Text("Ended").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 4) }
                }.padding()
            }
            .onChange(of: turns.last?.id) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } } }
            // Open on the latest message, as Messages does.
            .task {
                // After the first layout, so lazily sized rows are measured.
                try? await Task.sleep(for: .milliseconds(100))
                if let id = turns.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if conversation.endedAt == nil {
                ComposeBar(app: app, conversationID: conversationID, recipients: $recipients, onSent: { _ in })
            }
        }
        .navigationTitle(filter.map(presenter.name) ?? conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .macStatusSubtitle(app)
        .onAppear { recipients = filter.map { [$0] } ?? conversation.agentIDs }
        .onChange(of: filter) { _, value in recipients = value.map { [$0] } ?? conversation.agentIDs }
        .toolbar {
            Menu {
                Button("End Conversation", systemImage: "xmark.circle", role: .destructive) { confirmEnd = true }.disabled(conversation.endedAt != nil)
                Button("Request Report", systemImage: "doc.text.magnifyingglass") { run(.requestReport(conversationID: conversationID)) }
            } label: { Image(systemName: "ellipsis.circle") }
            .accessibilityLabel("More")
        }
        .confirmationDialog(conversation.canEnd ? "End This Conversation?" : "Can't End Yet", isPresented: $confirmEnd, titleVisibility: .visible) {
            if conversation.canEnd {
                Button("End Conversation", role: .destructive) { run(.endConversation(conversationID: conversationID)) }
                Button("Keep Active", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: {
            Text(conversation.canEnd ? "Later replies won't be added" : "Open it on your Mac first so its history loads")
        }
        .sheet(item: $details) { summary in RequestDetailsSheet(summary: summary, name: presenter.name(summary.agentID)) }
    }

    private func bubble(_ turn: RemoteTurn, showsName: Bool) -> some View {
        let mine = turn.role == .user
        return VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
            if showsName, let agent = turn.agentID {
                HStack(spacing: 6) {
                    AgentAvatar(app: app, agentID: agent, name: presenter.shortName(agent), size: 22)
                    Text(presenter.name(agent)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            Text(turn.text.isEmpty ? turn.attachments.map(\.filename).joined(separator: ", ") : turn.text)
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(mine ? Color("Bubble") : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                .foregroundStyle(mine ? .white : .primary)
            if !turn.attachments.isEmpty && !turn.text.isEmpty {
                Label(turn.attachments.map(\.filename).joined(separator: ", "), systemImage: "paperclip").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if mine {
                FlowChips(chips: presenter.chips(for: turn, agentID: filter))
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .padding(mine ? .leading : .trailing, 40)
    }

    /// One compact row: what is happening, and the one action that fits. Tap for the Mac's full text.
    private func incompleteRow(_ incomplete: RemoteIncompleteAttempt) -> some View {
        let summary = presenter.incompleteSummary(incomplete)
        return HStack(spacing: 10) {
            Button { details = summary } label: {
                HStack(spacing: 10) {
                    Image(systemName: summary.running ? "hourglass" : "exclamationmark.circle")
                        .foregroundStyle(summary.running ? Color.secondary : Color.orange)
                    Text(summary.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows request details")
            if summary.running {
                Button("Stop") { run(.cancelNative(agentID: incomplete.agentID)) }.buttonStyle(.bordered).controlSize(.small)
            } else {
                Button("Dismiss") { run(.acknowledgeIncomplete(agentID: incomplete.agentID, attemptID: String(incomplete.attemptID.dropFirst("wa:".count)))) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func run(_ action: RemoteAction) {
        actionError = nil
        Task {
            do {
                let result = try await app.perform(action)
                if result.outcome == .rejected { actionError = result.message }
            } catch { actionError = (error as? LocalizedError)?.errorDescription ?? MobileConnectionError.unconfirmed.errorDescription }
        }
    }
}

/// The Mac's full text for an unfinished request, and when it started.
struct RequestDetailsSheet: View {
    var summary: IncompleteSummary
    var name: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Agent", value: name)
                    LabeledContent("Status", value: summary.running ? "Running on your Mac" : "Needs review")
                    if let started = summary.started { LabeledContent("Started", value: started.formatted(date: .abbreviated, time: .shortened)) }
                }
                if !summary.details.isEmpty {
                    Section("From your Mac") { ForEach(summary.details, id: \.self) { Text($0).font(.callout) } }
                }
            }
            .navigationTitle("Request Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Sending → Sent → Replied / Not sent / Unconfirmed, per agent. Tap a chip for the Mac's reason.
struct FlowChips: View {
    var chips: [StatusChip]
    var body: some View {
        // One row when it fits; several agents stack rather than clip.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { ForEach(chips) { chip in ChipView(chip: chip, showsName: chips.count > 1) } }
            VStack(alignment: .trailing, spacing: 3) { ForEach(chips) { chip in ChipView(chip: chip, showsName: chips.count > 1) } }
        }
    }
}

struct ChipView: View {
    var chip: StatusChip
    var showsName: Bool
    @State private var showingReason = false
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        let label = content.font(.caption2).foregroundStyle(color)
        if let reason = chip.reason, !reason.isEmpty {
            Button { showingReason = true } label: { label }
                .buttonStyle(.plain)
                .accessibilityHint("Shows why")
                .popover(isPresented: $showingReason) { DetailPopover(text: reason) }
        } else {
            label
        }
    }
    /// One line, or at accessibility sizes the agent above its state, with no separator.
    @ViewBuilder private var content: some View {
        if showsName && typeSize.isAccessibilitySize {
            VStack(alignment: .trailing, spacing: 0) {
                Text(chip.agentName)
                Label(chip.state.rawValue, systemImage: chip.state.symbol)
            }
            .accessibilityElement(children: .combine)
        } else {
            Label(chip.label(showsName: showsName), systemImage: chip.state.symbol)
        }
    }
    private var color: Color {
        switch chip.state { case .notSent: .red; case .unconfirmed: .orange; default: .secondary }
    }
}
