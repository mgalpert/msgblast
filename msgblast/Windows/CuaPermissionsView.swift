import SwiftUI
import AppKit
import msgblastCore

struct CuaPermissionsView: View {
    var demo: Bool
    var busy = false
    @StateObject private var permissions = CuaPermissionsController()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Desktop app control").font(.headline)
            Text("Cua lets you chat with installed Mac apps in the background. These optional permissions are separate from Messages access.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Label(permissions.installed ? "Cua driver installed" : "Cua driver required", systemImage: permissions.installed ? "checkmark.circle" : "arrow.down.circle")
                Spacer()
                if !permissions.installed {
                    Link("Installation guide", destination: URL(string: "https://cua.ai/docs/cua-driver")!).disabled(demo)
                }
            }.font(.callout)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                row("msgblast Accessibility", benefit: "Verify the selected chat and preserve unsent drafts in connected apps.", status: permissions.hostAccessibility, identifier: "cua-host") {
                    if permissions.hostAccessibility == .allowed { permissions.openSettings("Privacy_Accessibility", demo: demo) }
                    else { permissions.enableHostAccessibility(demo: demo) }
                }
                row("CuaDriver Accessibility", benefit: "Read and operate the selected app's controls.", status: permissions.driverAccessibility, identifier: "cua-driver") {
                    if permissions.driverAccessibility == .allowed { permissions.openSettings("Privacy_Accessibility", demo: demo) }
                    else { Task { await permissions.enableDriver(demo: demo) } }
                }
                row("CuaDriver Screen Recording", benefit: "Capture the selected app window to focus Muse, ChatGPT, Dots, and Claude message fields.", status: permissions.windowCapture, identifier: "cua-capture") {
                    if permissions.windowCapture == .allowed { permissions.openSettings("Privacy_ScreenCapture", demo: demo) }
                    else { Task { await permissions.enableDriver(demo: demo) } }
                }
            }
            Text("Choose CuaDriver in macOS Privacy & Security. Enable opens Cua's setup and window-capture check. Full Disk Access does not grant these permissions.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cua setup & capture check…") { Task { await permissions.enableDriver(demo: demo) } }
                    .disabled(!permissions.installed).accessibilityIdentifier("setup-cua-permissions")
                Button("Check again") { Task { await permissions.refresh(demo: demo) } }
                    .accessibilityIdentifier("check-cua-permissions")
                if permissions.checking { ProgressView().controlSize(.small) }
            }.controlSize(.small)
            Text(demo ? "Cua permissions are simulated. No system access is changed." : "Allowed reports a macOS grant. Use Cua setup to verify capture; a grant alone does not prove that a window can be captured. Restart CuaDriver if macOS asks, then check again.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let message = permissions.message { Text(message).font(.caption).foregroundStyle(.orange) }
        }
        .disabled(busy || permissions.checking)
        .task { await permissions.refresh(demo: demo) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await permissions.refresh(demo: demo) }
        }
    }

    private func row(_ title: String, benefit: String, status: CuaPermissionStatus, identifier: String,
                     action: @escaping () -> Void) -> some View {
        GridRow {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(benefit).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
            Text(status.title).font(.callout).foregroundStyle(status == .allowed ? Color.green : .secondary)
                .accessibilityIdentifier("permission-status-\(identifier)")
            Button(status == .allowed ? "Manage" : "Enable", action: action)
                .disabled(status == .checking || status == .notInstalled)
                .accessibilityLabel("\(status == .allowed ? "Manage" : "Enable") \(title)")
                .accessibilityIdentifier("enable-\(identifier)-permission")
        }
    }
}
