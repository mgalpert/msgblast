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
