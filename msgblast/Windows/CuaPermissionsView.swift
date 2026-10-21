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
            Text("msgblast connects to installed Mac apps. These optional permissions are separate from Messages access.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Label(permissions.installed ? "msgblast driver installed" : "msgblast driver required", systemImage: permissions.installed ? "checkmark.circle" : "arrow.down.circle")
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
                row("msgblast driver Accessibility", benefit: "Read and operate the selected app's controls.", status: permissions.driverAccessibility, identifier: "cua-driver") {
                    if permissions.driverAccessibility == .allowed { permissions.openSettings("Privacy_Accessibility", demo: demo) }
                    else { Task { await permissions.enableDriver(demo: demo) } }
                }
                row("msgblast driver Screen Recording", benefit: "Capture the selected app window to focus Muse, ChatGPT, Dots, and Claude message fields.", status: permissions.windowCapture, identifier: "cua-capture") {
                    if permissions.windowCapture == .allowed { permissions.openSettings("Privacy_ScreenCapture", demo: demo) }
                    else { Task { await permissions.enableDriver(demo: demo) } }
                }
            }
            Text("Enable access for msgblast and its driver when macOS asks. Full Disk Access does not grant app control or screen capture.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Set up app access…") { Task { await permissions.enableDriver(demo: demo) } }
                    .disabled(!permissions.installed).accessibilityIdentifier("setup-cua-permissions")
                Button("Check again") { Task { await permissions.refresh(demo: demo) } }
                    .accessibilityIdentifier("check-cua-permissions")
                if permissions.checking { ProgressView().controlSize(.small) }
            }.controlSize(.small)
            Text(demo ? "App permissions are simulated. No system access is changed." : "Set up app access to verify capture. Follow any restart instructions from macOS; access refreshes when you return.")
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
