import SwiftUI
import AppKit
import msgblastCore

struct OnboardingPermissionsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var setup: OnboardingController
    @ObservedObject private var messages: AppPermissions
    @ObservedObject private var apps: CuaPermissionsController
    @ObservedObject private var guide: MessagesAccessGuide
    @State private var openedHistorySettings = false

    init(model: AppModel, setup: OnboardingController) {
        self.model = model
        self.setup = setup
        messages = setup.messagesPermissions
        apps = setup.appPermissions
        guide = model.accessGuide
    }

    private var busy: Bool { setup.permissionChecksBusy || model.busy || model.webBroadcastBusy }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 18) {
                        Image(systemName: "shield").font(.system(size: 40, weight: .light))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Allow access").font(.system(size: 28, weight: .semibold))
                            Text("System Settings · Privacy & Security").foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    Text("Messaging agents").font(.headline).foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        permissionRow("Full Disk Access", owner: "msgblast · Read Messages history", icon: "externaldrive", status: messages.history.title,
                                      allowed: messages.history == .allowed, identifier: "messages-history") {
                            guard setup.checkpointPermissionChange(), !model.demo else { return }
                            if messages.history == .allowed { messages.openSettings("Privacy_AllFiles") }
                            else { openedHistorySettings = true; guide.start() }
                        }.background(PermissionSourceAnchor(guide: guide))
                        Divider()
                        permissionRow("Contacts", owner: "msgblast · Find your messaging agents", icon: "person.crop.rectangle", status: messages.contacts.title,
                                      allowed: messages.contacts == .allowed, identifier: "messages-contacts") {
                            guard setup.checkpointPermissionChange() else { return }
                            Task { await messages.enableContacts(model: model) }
                        }
                        Divider()
                        permissionRow("Automation", owner: "msgblast → Messages · Send your prompts", icon: "gearshape.2", status: messages.sending.title,
                                      allowed: messages.sending == .allowed, identifier: "messages-automation") {
                            guard setup.checkpointPermissionChange() else { return }
                            Task { await messages.enableSending(model: model, requestAfterOpening: true) }
                        }
                    }
                    Divider()
                    Text("App agents").font(.headline).foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        Text("Accessibility").font(.callout.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
                        permissionRow("msgblast", owner: "Verify the selected chat and preserve drafts", icon: "accessibility", status: apps.hostAccessibility.title,
                                      allowed: apps.hostAccessibility == .allowed, identifier: "cua-host") {
                            guard setup.checkpointPermissionChange() else { return }
                            if apps.hostAccessibility == .allowed { apps.openSettings("Privacy_Accessibility", demo: model.demo) }
                            else { apps.enableHostAccessibility(demo: model.demo) }
                        }
                        Divider()
                        permissionRow("CuaDriver", owner: "Read and operate app controls", icon: "accessibility", status: apps.driverAccessibility.title,
                                      allowed: apps.driverAccessibility == .allowed, identifier: "cua-driver", available: apps.installed) {
                            guard setup.checkpointPermissionChange() else { return }
                            if apps.driverAccessibility == .allowed { apps.openSettings("Privacy_Accessibility", demo: model.demo) }
                            else { Task { await apps.enableDriver(demo: model.demo) } }
                        }
                        Divider()
                        permissionRow("Screen Recording", owner: "CuaDriver · Capture the selected app window", icon: "display", status: apps.windowCapture.title,
                                      allowed: apps.windowCapture == .allowed, identifier: "cua-capture", available: apps.installed) {
                            guard setup.checkpointPermissionChange() else { return }
                            if apps.windowCapture == .allowed { apps.openSettings("Privacy_ScreenCapture", demo: model.demo) }
                            else { Task { await apps.enableDriver(demo: model.demo) } }
                        }
                    }
                    if !apps.installed {
                        HStack {
                            Text("Install CuaDriver to connect Mac apps.").font(.callout).foregroundStyle(.secondary)
                            Link("Installation guide", destination: URL(string: "https://cua.ai/docs/cua-driver")!)
                        }
                    }
                    Text("Complete either section to continue. Your progress is saved before opening permission settings, so you can pick up here after restarting.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if model.demo {
                        Text("Demo permissions are simulated. No system access is changed.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let message = messages.message ?? apps.message ?? guide.message {
                        Text(message).font(.callout).foregroundStyle(.orange)
                    }
                    HStack {
                        Link("Open source", destination: URL(string: "https://github.com/mgalpert/msgblast")!)
                        Text("You can review how access is used.").foregroundStyle(.secondary)
                    }.font(.callout)
                }
                .padding(28).frame(maxWidth: 680, alignment: .leading)
                .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.12)))
                .padding(28).frame(maxWidth: .infinity)
            }
            Divider()
            HStack {
                Button("Back") { setup.reviewStats() }
                Button("Check again") { Task { await setup.refreshPermissions() } }
                    .disabled(busy).accessibilityIdentifier("check-onboarding-permissions")
                if openedHistorySettings && messages.history != .allowed {
                    Button("Restart & check access") {
                        guard setup.checkpointPermissionChange() else { return }
                        setup.restartForAccess()
                    }.disabled(busy)
                }
                if setup.permissionChecksBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Continue") { Task { await setup.finishPermissionSetup() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!setup.permissionSetupReady || busy)
                    .accessibilityIdentifier("continue-permissions")
            }.padding(24)
        }
        .task { await setup.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await setup.refreshPermissions() }
        }
    }

    private func permissionRow(_ title: String, owner: String, icon: String, status: String,
                               allowed: Bool, identifier: String, available: Bool = true,
                               action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 25)).frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(owner).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(status).font(.callout).foregroundStyle(allowed ? Color.green : .secondary)
                .accessibilityIdentifier("permission-status-\(identifier)")
            Button(allowed ? "Manage" : "Enable", action: action)
                .disabled(busy || !available)
                .accessibilityLabel("\(allowed ? "Manage" : "Enable") \(title)")
                .accessibilityIdentifier("enable-\(identifier)-permission")
        }.padding(.vertical, 12)
    }
}
