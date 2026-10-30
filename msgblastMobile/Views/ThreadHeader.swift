import SwiftUI
import msgblastMobileKit
import msgblastRemoteProtocol

/// Messages' thread header: the agents' avatars above a glass pill ("3 Agents ›", or the
/// agent's name in a direct thread). It opens the Details sheet. While the Mac is not
/// connected, its status reads under the pill.
struct ThreadHeader: View {
    @ObservedObject var app: MobileApp
    var agentIDs: [String]
    var open: () -> Void
    private var presenter: ProjectionPresenter { ProjectionPresenter(state: app.store.projection, commands: app.store.commands) }

    var body: some View {
        Button(action: open) {
            VStack(spacing: Space.hairline) {
                if agentIDs.count == 1 {
                    AgentAvatar(app: app, agentID: agentIDs[0], name: presenter.shortName(agentIDs[0]), size: Space.avatarThread)
                } else {
                    AvatarCluster(app: app, agentIDs: Array(agentIDs.prefix(3)), names: agentIDs.prefix(3).map(presenter.shortName))
                }
                HStack(spacing: Space.hairline) {
                    Text(agentIDs.count == 1 ? presenter.name(agentIDs[0]) : "\(agentIDs.count) Agents").lineLimit(1)
                    Image(systemName: "chevron.forward").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, Space.gap).padding(.vertical, Space.hairline)
                .glassEffect(.regular, in: .capsule)
                ConnectionCaption(app: app)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(agentIDs.count == 1 ? presenter.name(agentIDs[0]) : "\(agentIDs.count) agents")
        .accessibilityHint("Shows details")
    }
}

/// Up to three avatars overlapping left to right, each in a 2 pt ring of the bar's color.
struct AvatarCluster: View {
    @ObservedObject var app: MobileApp
    var agentIDs: [String]
    var names: [String]
    var body: some View {
        HStack(spacing: -Space.gap) {
            ForEach(Array(agentIDs.enumerated()), id: \.offset) { index, id in
                AgentAvatar(app: app, agentID: id, name: names[index], size: Space.avatarGroup)
                    .padding(Space.hairline)
                    .background(Circle().fill(Color(.systemBackground)))
                    .zIndex(Double(agentIDs.count - index))
            }
        }
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
    var run: (RemoteAction) -> Void
    @State private var confirmEnd = false
    @Environment(\.dismiss) private var dismiss
    private var presenter: ProjectionPresenter { ProjectionPresenter(state: app.store.projection, commands: app.store.commands) }

    var body: some View {
        NavigationStack {
            if let conversation = app.store.projection.conversations[conversationID] {
                List {
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
                            }
                            .listRowInsets(Space.row)
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
