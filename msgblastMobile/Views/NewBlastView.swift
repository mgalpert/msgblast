import SwiftUI
import msgblastMobileKit
import msgblastRemoteProtocol

/// The Mac's agent grid, grouped by product with each form labeled. Choose recipients,
/// then write the first message.
struct NewBlastView: View {
    @ObservedObject var app: MobileApp
    @State private var selected: [String] = []
    @Environment(\.dismiss) private var dismiss
    private var presenter: ProjectionPresenter { ProjectionPresenter(state: app.store.projection, commands: app.store.commands) }

    var body: some View {
        List {
            ForEach(presenter.productGroups) { group in
                Section(group.title) {
                    ForEach(group.agents, id: \.agentID) { agent in row(agent) }
                }
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
            HStack(spacing: 12) {
                AgentAvatar(name: agent.displayName, product: agent.product.rawValue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.displayName).foregroundStyle(sendable ? .primary : .secondary)
                    Text([ProjectionPresenter.formLabel(agent.form), ProjectionPresenter.agentStatus(agent)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle").foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .opacity(agent.readiness == .unavailable ? 0.5 : 1)
        .disabled(agent.readiness == .unavailable)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}
