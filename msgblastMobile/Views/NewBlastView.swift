import SwiftUI
import msgblastMobileKit
import msgblastRemoteProtocol

/// The Mac's agents in its grid order, each row naming its form, with Messages contacts
/// in their own section. Choose recipients, then write the first message.
struct NewBlastView: View {
    @ObservedObject var app: MobileApp
    @State private var selected: [String] = []
    @Environment(\.dismiss) private var dismiss
    private var presenter: ProjectionPresenter { ProjectionPresenter(state: app.store.projection, commands: app.store.commands) }

    var body: some View {
        let list = presenter.newConversationAgents
        List {
            // One flat list in the Mac's grid order; the row says the form.
            Section { ForEach(list.agents, id: \.agentID) { agent in row(agent) } }
            if !list.messages.isEmpty {
                Section("Messages") { ForEach(list.messages, id: \.agentID) { agent in row(agent) } }
            }
        }
        .safeAreaInset(edge: .bottom) {
            ComposeBar(app: app, conversationID: nil, recipients: $selected, onSent: { id in dismiss(); _ = id })
        }
        .navigationTitle("New Conversation")
        .toolbar { Button("Cancel") { dismiss() } }
    }

    private func row(_ agent: AgentAvailability) -> some View {
        let isSelected = selected.contains(agent.agentID)
        let sendable = agent.readiness.acceptsSend
        return Button {
            if isSelected { selected.removeAll { $0 == agent.agentID } } else { selected.append(agent.agentID) }
        } label: {
            HStack(spacing: Space.inset) {
                AgentAvatar(app: app, agentID: agent.agentID, name: agent.displayName, size: Space.avatarRow)
                VStack(alignment: .leading, spacing: Space.hairline) {
                    Text(agent.displayName).foregroundStyle(sendable ? .primary : .secondary)
                    // Messages rows sit under a Messages header; they need no form label.
                    let form = agent.form == .messages ? nil : ProjectionPresenter.formLabel(agent.form)
                    if let subtitle = [form, ProjectionPresenter.agentStatus(agent)].compactMap({ $0 }).joined(separator: " · ").nilIfBlank {
                        Text(subtitle)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle").foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .listRowInsets(Space.row)
        .opacity(agent.readiness == .unavailable ? 0.5 : 1)
        .disabled(agent.readiness == .unavailable)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}
