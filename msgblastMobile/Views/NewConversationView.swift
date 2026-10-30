import SwiftUI
import msgblastMobileKit
import msgblastRemoteProtocol

/// A new conversation is an empty thread pushed from the inbox. The agents strip above the
/// field is open from the start; checking agents fills the header live. Once the Mac reports
/// the conversation, this same screen becomes its thread in place.
struct NewConversationView: View {
    @ObservedObject var app: MobileApp
    /// The checked agents, in the order checked. Starts empty: nothing is pre-checked, not
    /// even the Mac's own composer selection.
    @State private var selected: [String] = []
    /// The strip's order, fixed when the screen opens so icons never move under a finger
    /// while readiness changes.
    @State private var order: (agents: [String], messages: [String])?
    @State private var focusRequest = 0
    /// The conversation the send created, once known.
    @State private var created: UUID?
    private var presenter: ProjectionPresenter { ProjectionPresenter(state: app.store.projection, commands: app.store.commands) }

    var body: some View {
        if let created, app.store.projection.conversations[created] != nil {
            // Bound in place: the header already shows these agents, so nothing re-animates.
            ConversationView(app: app, conversationID: created, startFocused: true)
        } else {
            empty
        }
    }

    private var empty: some View {
        let list = order ?? Self.order(presenter.newConversationAgents)
        return Color(.systemBackground)
            .ignoresSafeArea(.container, edges: .horizontal)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Space.inset) {
                            ForEach(list.agents, id: \.self) { id in icon(id) }
                            if !list.messages.isEmpty {
                                Divider().frame(height: Space.avatarRow)
                                ForEach(list.messages, id: \.self) { id in icon(id) }
                            }
                        }
                        .padding(.horizontal, Space.screen).padding(.top, Space.gap)
                    }
                    .background(.bar)
                    ComposeBar(app: app, conversationID: nil, recipients: $selected, focusRequest: focusRequest) { id in created = id }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { NewThreadHeader(app: app, agentIDs: selected) }
                    .sharedBackgroundVisibility(.hidden)
            }
            .sensoryFeedback(.selection, trigger: selected)
            .onAppear {
                if order == nil { order = Self.order(presenter.newConversationAgents) }
                // The keyboard comes up with the screen.
                Task { focusRequest += 1 }
                #if DEBUG
                // Design review: `MSGBLAST_FIXTURE_FILTER=<id>,<id>` checks agents.
                if let agents = ProcessInfo.processInfo.environment["MSGBLAST_FIXTURE_FILTER"] { selected = agents.split(separator: ",").map(String.init) }
                #endif
            }
    }

    /// An agent as the thread's strip shows it: the avatar with the Mac's corner check,
    /// unchosen at 60%.
    private static func order(_ list: (agents: [AgentAvailability], messages: [AgentAvailability])) -> (agents: [String], messages: [String]) {
        (list.agents.map(\.agentID), list.messages.map(\.agentID))
    }

    @ViewBuilder private func icon(_ id: String) -> some View {
        if let agent = app.store.projection.agents[id] { icon(agent) }
    }

    private func icon(_ agent: AgentAvailability) -> some View {
        let checked = selected.contains(agent.agentID)
        let available = agent.readiness != .unavailable
        return Button {
            selected = ProjectionPresenter.togglingNew(agent.agentID, chosen: selected)
        } label: {
            AgentAvatar(app: app, agentID: agent.agentID, name: agent.displayName, size: Space.avatarRow)
                .opacity(checked ? 1 : 0.6)
                .overlay(alignment: .bottomTrailing) { CheckBadge(checked: checked).offset(x: Space.tight, y: Space.tight) }
                .padding(Space.tight)
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.4)
        .accessibilityLabel("\(agent.displayName), \(checked ? "selected" : "not selected")")
        .accessibilityHint([ProjectionPresenter.formLabel(agent.form), ProjectionPresenter.agentStatus(agent)].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(checked ? [.isButton, .isSelected] : .isButton)
    }
}

/// The header of a conversation that does not exist yet: a dashed placeholder, then the
/// checked agents in the thread header's cluster layout, over a pill with no chevron.
struct NewThreadHeader: View {
    @ObservedObject var app: MobileApp
    var agentIDs: [String]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var presenter: ProjectionPresenter { ProjectionPresenter(state: app.store.projection, commands: app.store.commands) }

    var body: some View {
        VStack(spacing: Space.hairline) {
            ZStack {
                if agentIDs.isEmpty {
                    Image(systemName: "person.2").font(.footnote).foregroundStyle(.secondary)
                        .frame(width: Space.avatarHeader, height: Space.avatarHeader)
                        .overlay(Circle().strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])))
                        .transition(.opacity)
                }
                HStack(spacing: -Space.gap) {
                    ForEach(Array(agentIDs.prefix(3).enumerated()), id: \.element) { index, id in
                        AgentAvatar(app: app, agentID: id, name: presenter.shortName(id), size: Space.avatarHeader)
                            .padding(Space.hairline)
                            .background(Circle().fill(Color(.systemBackground)))
                            .zIndex(Double(3 - index))
                            .transition(reduceMotion ? .identity : .scale(scale: 0.6).combined(with: .opacity)
                                .animation(.spring(duration: 0.35).delay(Double(index) * 0.04)))
                    }
                    if agentIDs.count > 3 {
                        Text("+\(agentIDs.count - 3)").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                            .frame(width: Space.avatarHeader, height: Space.avatarHeader)
                            .background(Circle().fill(Color(.tertiarySystemFill)))
                            .padding(Space.hairline)
                            .background(Circle().fill(Color(.systemBackground)))
                    }
                }
            }
            .frame(height: Space.control)
            .animation(reduceMotion ? nil : .spring(duration: 0.35), value: agentIDs)
            Text(title).lineLimit(1)
                .font(.caption.weight(.medium))
                .padding(.horizontal, Space.gap).padding(.vertical, Space.hairline)
                .glassEffect(.regular, in: .capsule)
                .contentTransition(.opacity)
            ConnectionCaption(app: app)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(agentIDs.isEmpty ? "New Conversation" : "New conversation with \(agentIDs.map(presenter.shortName).formatted(.list(type: .and)))")
    }

    private var title: String {
        switch agentIDs.count {
        case 0: "New Conversation"
        case 1: presenter.name(agentIDs[0])
        case 2: "\(presenter.shortName(agentIDs[0])) & \(presenter.shortName(agentIDs[1]))"
        default: "\(agentIDs.count) Agents"
        }
    }
}
