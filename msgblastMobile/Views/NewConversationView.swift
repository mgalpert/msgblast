import SwiftUI
import msgblastMobileKit
import msgblastRemoteProtocol

/// A new conversation is an empty thread pushed from the inbox. The agents strip above the
/// field is open from the start; checking agents fills the header live. Once the Mac reports
/// the conversation, this same screen becomes its thread in place.
struct NewConversationView: View {
    @ObservedObject var app: MobileApp
    /// The checked agents. Follows the Mac's selected agents that can take a send until the
    /// first tap; taps add and remove, and none checked means no one.
    @State private var selected: [String] = []
    @State private var touched = false
    /// After the initial fill, so only later taps spring into the header.
    @State private var settled = false
    /// The strip's agents, then Messages contacts. Icons keep their place as the Mac's list
    /// changes, so none moves under a finger; newly connected ones are added at the end.
    @State private var order: [[String]] = [[], []]
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

    /// The connected agents as the Mac reports them now.
    private var listed: [[String]] {
        let list = presenter.newConversationAgents
        return [list.agents.map(\.agentID), list.messages.map(\.agentID)]
    }

    /// Only once the Mac has answered: before its first snapshot, or while it is away, an
    /// empty list says nothing about what is connected.
    private func showsNoAgents(_ strip: [[String]]) -> Bool {
        strip.allSatisfy(\.isEmpty) && app.store.projection.seq != nil && app.connection.state.canSend
    }

    private var empty: some View {
        // Before the first refresh, the Mac's list as it is.
        let strip = order.allSatisfy(\.isEmpty) ? listed : order
        return Color(.systemBackground)
            .ignoresSafeArea(.container, edges: .horizontal)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Group {
                        if showsNoAgents(strip) {
                            Text("Connect an agent on your Mac to message it here.").font(.footnote).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, minHeight: Space.avatarRow)
                                .padding(.horizontal, Space.screen).padding(.top, Space.gap)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: Space.inset) {
                                    ForEach(strip[0], id: \.self) { id in icon(id) }
                                    if !strip[1].isEmpty {
                                        Divider().frame(height: Space.avatarRow)
                                        ForEach(strip[1], id: \.self) { id in icon(id) }
                                    }
                                }
                                .padding(.horizontal, Space.screen).padding(.top, Space.gap)
                            }
                        }
                    }
                    .background(.bar)
                    ComposeBar(app: app, conversationID: nil, recipients: $selected, focusRequest: focusRequest) { id in created = id }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { NewThreadHeader(app: app, agentIDs: selected, animates: settled) }
                    .sharedBackgroundVisibility(.hidden)
            }
            .sensoryFeedback(.selection, trigger: selected)
            .onAppear {
                refresh(listed)
                if !settled { Task { settled = true } }
                // The keyboard comes up with the screen.
                Task { focusRequest += 1 }
                #if DEBUG
                // Design review: `MSGBLAST_FIXTURE_FILTER=<id>,<id>` checks agents.
                if let agents = ProcessInfo.processInfo.environment["MSGBLAST_FIXTURE_FILTER"] { selected = agents.split(separator: ",").map(String.init); touched = true }
                #endif
            }
            // The Mac's default checks can change with readiness alone, so they are watched too.
            .onChange(of: listed + [presenter.defaultNewSelection]) { _, now in refresh(Array(now.prefix(2))) }
    }

    /// Follows the Mac's list: an agent that leaves is unchecked, and until the first tap
    /// the checks follow the Mac's selection.
    private func refresh(_ now: [[String]]) {
        order = zip(order, now).map(ProjectionPresenter.stripOrder)
        let ids = Set(now.joined())
        selected = touched ? selected.filter(ids.contains) : presenter.defaultNewSelection
    }

    /// An agent as the thread's strip shows it: the avatar with the Mac's corner check,
    /// unchosen at 60%.
    @ViewBuilder private func icon(_ id: String) -> some View {
        if let agent = app.store.projection.agents[id] { icon(agent) }
    }

    private func icon(_ agent: AgentAvailability) -> some View {
        let checked = selected.contains(agent.agentID)
        let available = agent.readiness != .unavailable
        return Button {
            touched = true
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
    /// False for the first fill, so the default agents appear at once rather than cascading.
    var animates = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var springs: Bool { animates && !reduceMotion }
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
                            .transition(!springs ? .identity : .scale(scale: 0.6).combined(with: .opacity)
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
            .animation(springs ? .spring(duration: 0.35) : nil, value: agentIDs)
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
