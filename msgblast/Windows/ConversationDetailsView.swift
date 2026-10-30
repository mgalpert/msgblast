import SwiftUI
import msgblastCore

/// One action in the Details popover: a member's menu item or a footer button.
struct DetailsAction: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    var destructive = false
    var disabled = false
    let run: () -> Void
}

/// A conversation member as the Details popover lists it: the same identity, recipient
/// state and actions as its column header.
struct DetailsMember: Identifiable {
    let id: String
    let agent: Agent?
    let name: String
    let detail: String?
    let included: Bool
    let enabled: Bool
    let busy: Bool
    let toggle: () -> Void
    let actions: [DetailsAction]
}

/// An agent that can still join the conversation.
struct DetailsAddition: Identifiable {
    let id: String
    let agent: Agent?
    let name: String
    let enabled: Bool
    let add: () -> Void
}

/// The Details popover: the members with their recipient checks and actions, the agents
/// that can be added, and the conversation-level actions. Data-driven so both workspaces
/// can use it.
struct ConversationDetailsView: View {
    let title: String
    let members: [DetailsMember]
    let additions: [DetailsAddition]
    var footer: [DetailsAction] = []
    var body: some View {
        VStack(alignment: .leading, spacing: Space.inset) {
            Text(title).font(.headline).lineLimit(2)
            ForEach(members) { member in
                HStack(spacing: Space.gap) {
                    AgentAvatar(agent: member.agent, name: member.name, size: Space.avatarList)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(member.name)
                        if let detail = member.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    if member.busy { ProgressView().controlSize(.mini) }
                    Toggle("", isOn: Binding(get: { member.included }, set: { _ in member.toggle() }))
                        .toggleStyle(.checkbox).labelsHidden()
                        .disabled(!member.enabled)
                        .accessibilityLabel("Recipient \(member.name)")
                        .accessibilityValue(member.included ? "Selected" : "Not selected")
                    if !member.actions.isEmpty {
                        Menu {
                            ForEach(member.actions) { action in
                                Button(role: action.destructive ? .destructive : nil, action: action.run) {
                                    Label(action.title, systemImage: action.systemImage)
                                }.disabled(action.disabled)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("\(member.name) actions")
                    }
                }
            }
            if !additions.isEmpty {
                Divider()
                Text("Add").font(.caption).foregroundStyle(.secondary)
                ForEach(additions) { addition in
                    HStack(spacing: Space.gap) {
                        AgentAvatar(agent: addition.agent, name: addition.name, size: Space.avatarList)
                        Text(addition.name)
                        Spacer()
                        Button(action: addition.add) { Image(systemName: "plus.circle") }
                            .buttonStyle(.borderless)
                            .disabled(!addition.enabled)
                            .accessibilityLabel("Add \(addition.name)")
                    }
                }
            }
            if !footer.isEmpty {
                Divider()
                ForEach(footer) { action in
                    Button(role: action.destructive ? .destructive : nil, action: action.run) {
                        Label(action.title, systemImage: action.systemImage)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(action.destructive ? Color.red : Color.primary)
                    .disabled(action.disabled)
                }
            }
        }
        .padding(Space.screen)
        .frame(width: Space.popoverWidth)
    }
}

/// The Details button of a Messages-only comparison window (the connected window and the
/// floating composer panel): `ConversationDetailsView` for the comparison's members, the
/// agents that can still join, and the conversation-level actions.
struct ComparisonDetailsButton: View {
    @ObservedObject var model: AppModel
    let comparisonID: UUID
    @State private var showing = false
    private var busy: Bool { model.busy || model.webBroadcastBusy }
    var body: some View {
        Button { showing.toggle() } label: { Label("Details", systemImage: "info.circle").labelStyle(.iconOnly) }
            .help("Details").accessibilityLabel("Conversation details")
            .disabled(model.comparison(comparisonID) == nil)
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                if let comparison = model.comparison(comparisonID) {
                    ConversationDetailsView(title: comparison.title, members: members(comparison),
                                            additions: additions(comparison), footer: footer(comparison))
                }
            }
    }

    private func members(_ comparison: Comparison) -> [DetailsMember] {
        let selection = comparison.recipientSelection ?? ConversationRecipients()
        let recipients = Set(selection.recipientIDs(in: comparison.members))
        return comparison.members.map { member in
            var actions = [DetailsAction(id: "open", title: "Open in Messages", systemImage: "message") { model.openMessages(member) }]
            if model.state.effectiveWindowStyle == .separate {
                actions.append(DetailsAction(id: "show", title: "Show Conversation", systemImage: "macwindow") {
                    model.coordinator?.focus(comparisonID, memberID: member.id)
                })
            }
            return DetailsMember(id: member.id.uuidString, agent: model.state.agents.first { $0.id == member.id }, name: member.name, detail: member.chat.handle,
                                 included: recipients.contains(member.id), enabled: comparison.endedAt == nil && !busy, busy: false,
                                 toggle: {
                                     var updated = selection
                                     updated.toggleRecipient(member.id, in: comparison.members)
                                     model.setRecipients(updated, for: comparisonID)
                                 }, actions: actions)
        }
    }

    private func additions(_ comparison: Comparison) -> [DetailsAddition] {
        let sessions = model.recipientWebSessions(for: comparison).filter { !comparison.resolvedWebAgentIDs.contains($0.id) }.map { session in
            DetailsAddition(id: session.id.id, agent: AgentArtwork.agent(for: session), name: session.name, enabled: !busy && session.isEnabled) {
                model.coordinator?.prepareJoiningWebAgent(comparisonID)
                model.webBroadcastBusy = true
                model.webAgents.select(session, selected: true)
                session.connect()
                Task { @MainActor in
                    _ = await model.joinWebAgent(session, comparisonID: comparisonID)
                    model.webBroadcastBusy = false
                }
            }
        }
        let agents = model.showcaseMessageAgents.filter { agent in !comparison.members.contains(where: { $0.id == agent.id }) }.map { agent in
            DetailsAddition(id: agent.id.uuidString, agent: agent, name: agent.name, enabled: !busy && model.route(agent) != nil) {
                Task { await model.addAgent(agent, to: comparisonID); model.coordinator?.open(comparisonID) }
            }
        }
        return sessions + agents
    }

    private func footer(_ comparison: Comparison) -> [DetailsAction] {
        var actions: [DetailsAction] = []
        if !model.databaseAvailable {
            actions.append(DetailsAction(id: "access", title: "Check Messages Access", systemImage: "arrow.clockwise") { model.refresh() })
        }
        actions.append(DetailsAction(id: "end", title: "End Conversation", systemImage: "xmark.circle", destructive: true, disabled: comparison.endedAt != nil) {
            _ = model.endConversation(comparisonID)
            showing = false
        })
        return actions
    }
}
