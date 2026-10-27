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

    private var presenter: ProjectionPresenter { ProjectionPresenter(state: app.store.projection, commands: app.store.commands) }
    private var conversation: RemoteConversation? { app.store.projection.conversations[conversationID] }

    var body: some View {
        if let conversation {
            content(conversation)
        } else {
            ContentUnavailableView("Conversation not on your Mac", systemImage: "questionmark.bubble")
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
                    if let actionError { Text(actionError).font(.footnote).foregroundStyle(.red) }
                    if conversation.endedAt != nil { Text("This conversation has ended.").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
                }.padding()
            }
            .onChange(of: turns.last?.id) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } } }
        }
        .safeAreaInset(edge: .bottom) {
            if conversation.endedAt == nil {
                ComposeBar(app: app, conversationID: conversationID, recipients: $recipients, onSent: { _ in })
            }
        }
        .navigationTitle(filter.map(presenter.name) ?? conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { recipients = filter.map { [$0] } ?? conversation.agentIDs }
        .onChange(of: filter) { _, value in recipients = value.map { [$0] } ?? conversation.agentIDs }
        .toolbar {
            Menu {
                Button("End conversation", role: .destructive) { confirmEnd = true }.disabled(!conversation.canEnd || conversation.endedAt != nil)
                if !conversation.canEnd && conversation.endedAt == nil { Text("Open it on the Mac first to end it.") }
                Button("Request a report on the Mac") { run(.requestReport(conversationID: conversationID)) }
            } label: { Image(systemName: "ellipsis.circle") }
        }
        .confirmationDialog("End this conversation?", isPresented: $confirmEnd) {
            Button("End conversation", role: .destructive) { run(.endConversation(conversationID: conversationID)) }
            Button("Keep active", role: .cancel) {}
        } message: { Text("Replies that arrive later are not added.") }
    }

    private func bubble(_ turn: RemoteTurn, showsName: Bool) -> some View {
        let mine = turn.role == .user
        return VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
            if showsName, let agent = turn.agentID {
                HStack(spacing: 6) {
                    AgentAvatar(name: presenter.shortName(agent), product: app.store.projection.agents[agent]?.product.rawValue ?? agent, size: 22)
                    Text(presenter.name(agent)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            Text(turn.text.isEmpty ? turn.attachments.map(\.filename).joined(separator: ", ") : turn.text)
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(mine ? Color.accentColor : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                .foregroundStyle(mine ? .white : .primary)
            if !turn.attachments.isEmpty && !turn.text.isEmpty {
                Label(turn.attachments.map(\.filename).joined(separator: ", "), systemImage: "paperclip").font(.caption).foregroundStyle(.secondary)
            }
            if mine {
                let chips = presenter.chips(for: turn)
                FlowChips(chips: chips)
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .padding(mine ? .leading : .trailing, 40)
    }

    private func incompleteRow(_ incomplete: RemoteIncompleteAttempt) -> some View {
        let attempt = app.store.projection.attempts[incomplete.attemptID]
        let running = attempt.map { [.attempting, .preparing].contains($0.status) } ?? false
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(presenter.shortName(incomplete.agentID)) did not finish a request here.").font(.subheadline.weight(.semibold))
            if let detail = attempt?.detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            HStack {
                if running { Button("Stop waiting") { run(.cancelNative(agentID: incomplete.agentID)) } }
                else { Button("Acknowledge") { run(.acknowledgeIncomplete(agentID: incomplete.agentID, attemptID: String(incomplete.attemptID.dropFirst("wa:".count)))) } }
            }.buttonStyle(.bordered)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
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

/// Sending on Mac → Sent → Replied / Not sent / Unconfirmed, per agent, with the Mac's reason.
struct FlowChips: View {
    var chips: [StatusChip]
    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            ForEach(chips) { chip in
                HStack(spacing: 4) {
                    Image(systemName: symbol(chip.state))
                    Text(chips.count > 1 ? "\(chip.agentName): \(chip.state.rawValue)" : chip.state.rawValue)
                }
                .font(.caption2).foregroundStyle(color(chip.state))
                .help(chip.reason ?? "")
                if let reason = chip.reason, chip.state == .unconfirmed || chip.state == .notSent {
                    Text(reason).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
            }
        }
    }
    private func symbol(_ state: ChipState) -> String {
        switch state { case .sending: "clock"; case .sent: "checkmark"; case .replied: "checkmark.bubble"; case .notSent: "xmark.circle"; case .unconfirmed: "questionmark.circle" }
    }
    private func color(_ state: ChipState) -> Color {
        switch state { case .notSent: .red; case .unconfirmed: .orange; default: .secondary }
    }
}
