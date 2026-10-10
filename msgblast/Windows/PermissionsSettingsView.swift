import SwiftUI
import AppKit

struct PermissionsSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var guide: MessagesAccessGuide
    @StateObject private var permissions = AppPermissions()

    init(model: AppModel) { self.model = model; guide = model.accessGuide }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                permissionRow("Messages access", benefit: "Find the agents you already text.",
                              status: permissions.history, identifier: "history") {
                    if permissions.history == .allowed { permissions.openSettings("Privacy_AllFiles") }
                    else { guide.start() }
                }
                Divider().gridCellColumns(3)
                permissionRow("Contacts", benefit: "Match your agents’ names and photos.",
                              status: permissions.contacts, identifier: "contacts", busy: permissions.requestingContacts) {
                    Task { await permissions.enableContacts(model: model) }
                }
                Divider().gridCellColumns(3)
                permissionRow("Sending Messages", benefit: "Send messages to your agents.",
                              status: permissions.sending, identifier: "sending", busy: permissions.checkingSending) {
                    Task { await permissions.enableSending(model: model) }
                }
            }
            if model.demo {
                Text("Demo permissions are simulated. No system access is changed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = permissions.message ?? guide.message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        await permissions.refresh(model: model)
    }

    private func permissionRow(_ title: String, benefit: String, status: AppPermissionStatus,
                               identifier: String, busy: Bool = false, action: @escaping () -> Void) -> some View {
        GridRow {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                Text(benefit).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            Text(status.title).font(.callout)
                .foregroundStyle(status == .allowed ? Color.green : Color.secondary)
                .accessibilityIdentifier("permission-status-\(identifier)")
                .help(status == .needsMessages ? "Open Messages to check this permission." : "")
            Button(status.actionTitle, action: action)
                .accessibilityIdentifier("enable-\(identifier)-permission")
                .disabled(busy || status == .checking || status == .restricted || model.busy)
        }.accessibilityElement(children: .contain)
    }
}
