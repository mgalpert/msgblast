import SwiftUI
import msgblastMobileKit
import msgblastRemoteProtocol

/// Messages' thread header, which is also the group's filter and recipient list. Tapping an
/// avatar adds or removes that agent, a long press keeps only it, and the unchosen dim; the
/// glass pill reads "3 Agents ›", "Claude ›", "Claude & Muse ›" or "3 of 5 ›" and opens Details.
struct ThreadHeader: View {
    @ObservedObject var app: MobileApp
    var agentIDs: [String]
    @Binding var selection: Set<String>
    var open: () -> Void
    private var presenter: ProjectionPresenter { ProjectionPresenter(state: app.store.projection, commands: app.store.commands) }

    var body: some View {
        VStack(spacing: Space.hairline) {
            if agentIDs.count == 1 {
                Button(action: open) { AgentAvatar(app: app, agentID: agentIDs[0], name: presenter.shortName(agentIDs[0]), size: Space.avatarThread) }
                    .buttonStyle(.plain).accessibilityHidden(true)
            } else {
                cluster
            }
            Button(action: open) {
                HStack(spacing: Space.hairline) {
                    Text(title).lineLimit(1)
                    Image(systemName: "chevron.forward").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, Space.gap).padding(.vertical, Space.hairline)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), details")
            ConnectionCaption(app: app)
        }
    }

    private var title: String {
        if agentIDs.count == 1 { return presenter.name(agentIDs[0]) }
        return presenter.selectionTitle(selection, members: agentIDs)
    }

    /// Adds or removes an agent; choosing everyone, or no one, is All.
    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        if selection.count == agentIDs.count { selection = [] }
    }

    /// Up to three avatars overlapping left to right in 2 pt rings, then "+N".
    private var cluster: some View {
        HStack(spacing: -Space.gap) {
            ForEach(Array(agentIDs.prefix(3).enumerated()), id: \.offset) { index, id in
                ClusterAvatar(app: app, agentID: id, name: presenter.shortName(id), chosen: selection.contains(id),
                              dimmed: !selection.isEmpty && !selection.contains(id),
                              toggle: { withAnimation(.snappy) { toggle(id) } },
                              only: { withAnimation(.snappy) { selection = [id] } })
                .zIndex(selection.contains(id) ? 10 : Double(3 - index))
            }
            if agentIDs.count > 3 {
                Button(action: open) {
                    Text("+\(agentIDs.count - 3)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: Space.avatarGroup, height: Space.avatarGroup)
                        .background(Circle().fill(Color(.tertiarySystemFill)))
                        .padding(Space.hairline)
                        .background(Circle().fill(Color(.systemBackground)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(agentIDs.count - 3) more agents, details")
            }
        }
    }
}

/// One avatar in the header cluster: a button that shows only that agent, or all again.
struct ClusterAvatar: View {
    @ObservedObject var app: MobileApp
    var agentID: String
    var name: String
    var chosen: Bool
    var dimmed: Bool
    var toggle: () -> Void
    var only: () -> Void
    var body: some View {
        Button(action: toggle) {
            AgentAvatar(app: app, agentID: agentID, name: name, size: Space.avatarGroup)
                .padding(Space.hairline)
                .background(Circle().fill(Color(.systemBackground)))
                .opacity(dimmed ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in only() })
        .accessibilityLabel(name)
        .accessibilityHint(chosen ? "Removes from the selection" : "Adds to the selection")
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Show Only") { only() }
    }
}

/// The Mac's connection state as one caption; nothing while connected.
struct ConnectionCaption: View {
    @ObservedObject var app: MobileApp
    @State private var now = Date()
    var body: some View {
        let state = app.store.projection.macLocked && app.connection.state.canSend ? MacConnectionState.macLocked : app.connection.state
        Group {
            if let text = state.navigationSubtitle(lastHeard: app.connection.lastHeard, reconnectingSince: app.connection.reconnectingSince, now: now) {
                Text(text).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                now = Date()
            }
        }
    }
}

/// The thread's Details sheet: each agent with its form and short status, a report request,
/// and End Conversation with the existing confirmation.
struct ThreadDetailsSheet: View {
    @ObservedObject var app: MobileApp
    let conversationID: UUID
    @Binding var selection: Set<String>
    var run: (RemoteAction) -> Void
    @State private var confirmEnd = false
    @Environment(\.dismiss) private var dismiss
    private var presenter: ProjectionPresenter { ProjectionPresenter(state: app.store.projection, commands: app.store.commands) }

    var body: some View {
        NavigationStack {
            if let conversation = app.store.projection.conversations[conversationID] {
                List {
                    if !selection.isEmpty && conversation.agentIDs.count > 1 {
                        Section { Button("Show All", systemImage: "person.3") { selection = [] } }
                    }
                    Section {
                        ForEach(conversation.agentIDs, id: \.self) { id in
                            HStack(spacing: Space.inset) {
                                AgentAvatar(app: app, agentID: id, name: presenter.shortName(id), size: Space.avatarRow)
                                VStack(alignment: .leading, spacing: Space.hairline) {
                                    Text(presenter.shortName(id))
                                    if let agent = app.store.projection.agents[id] {
                                        Text([ProjectionPresenter.formLabel(agent.form), ProjectionPresenter.agentStatus(agent) ?? "Ready"].joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: Space.gap)
                                if conversation.agentIDs.count > 1 {
                                    // Mirrors the header: a checkmark per chosen agent; All shows none.
                                    Image(systemName: selection.contains(id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selection.contains(id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                                        .font(.title3)
                                }
                            }
                            .listRowInsets(Space.row)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard conversation.agentIDs.count > 1 else { return }
                                if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
                                if selection.count == conversation.agentIDs.count { selection = [] }
                            }
                            .accessibilityAddTraits(selection.contains(id) ? [.isButton, .isSelected] : .isButton)
                        }
                    }
                    Section {
                        Button("Request Report", systemImage: "doc.text.magnifyingglass") { run(.requestReport(conversationID: conversationID)); dismiss() }
                    }
                    if conversation.endedAt == nil {
                        Section {
                            Button("End Conversation", systemImage: "xmark.circle", role: .destructive) { confirmEnd = true }
                        }
                    }
                }
                .navigationTitle(conversation.agentIDs.count == 1 ? presenter.name(conversation.agentIDs[0]) : conversation.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { dismiss() } }
                .confirmationDialog(conversation.canEnd ? "End This Conversation?" : "Can't End Yet", isPresented: $confirmEnd, titleVisibility: .visible) {
                    if conversation.canEnd {
                        Button("End Conversation", role: .destructive) { run(.endConversation(conversationID: conversationID)); dismiss() }
                        Button("Keep Active", role: .cancel) {}
                    } else {
                        Button("OK", role: .cancel) {}
                    }
                } message: {
                    Text(conversation.canEnd ? "Later replies won't be added" : "Open it on your Mac first so its history loads")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
