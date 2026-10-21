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
            if !permissions.installed {
                Text("App control is missing from this copy of msgblast. Update or reinstall msgblast to connect Mac apps.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                row(ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? "Device Control and Data Access" : "Accessibility", benefit: "Verify the selected chat and preserve unsent drafts in connected apps.", status: permissions.hostAccessibility, identifier: "cua-host") {
                    if permissions.hostAccessibility == .allowed { permissions.openSettings("Privacy_Accessibility", demo: demo) }
                    else { permissions.enableHostAccessibility(demo: demo) }
                }
                row("Screen Recording", benefit: "Capture the selected app window to focus Muse, ChatGPT, Dots, and Claude message fields.", status: permissions.windowCapture, identifier: "cua-capture") {
                    if permissions.windowCapture == .allowed { permissions.openSettings("Privacy_ScreenCapture", demo: demo) }
                    else { permissions.enableScreenCapture(demo: demo) }
                }
            }
            Text("Enable access for msgblast when macOS asks. Full Disk Access does not grant app control or screen capture.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Check again") { Task { await permissions.refresh(demo: demo) } }
                    .accessibilityIdentifier("check-cua-permissions")
                if permissions.checking { ProgressView().controlSize(.small) }
            }.controlSize(.small)
            Text(demo ? "App permissions are simulated. No system access is changed." : "Follow any restart instructions from macOS; access refreshes when you return.")
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
