import SwiftUI
import AppKit
import msgblastCore

struct OnboardingPermissionsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var setup: OnboardingController
    @ObservedObject private var messages: AppPermissions
    @ObservedObject private var apps: CuaPermissionsController
    @ObservedObject private var guide: MessagesAccessGuide
    @StateObject private var appGuide = MessagesAccessGuide(pendingKey: "appAccessHandoffPending")
    @State private var openedHistorySettings = false

    init(model: AppModel, setup: OnboardingController) {
        self.model = model
        self.setup = setup
        messages = setup.messagesPermissions
        apps = setup.appPermissions
        guide = model.accessGuide
    }

    private var busy: Bool { setup.permissionChecksBusy || setup.checking || model.busy || model.webBroadcastBusy }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    Image(systemName: "shield").font(.system(size: 32, weight: .light))
                    Text("Allow access").font(.system(size: 28, weight: .semibold))
                }
                Divider()
                HStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                        .resizable().interpolation(.high).scaledToFit()
                        .frame(width: 36, height: 36).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("msgblast").font(.headline)
                        Text("Feel free to inspect how we use this information. Everything is [open source](https://github.com/mgalpert/msgblast).")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.vertical, 4)
                VStack(spacing: 0) {
                    permissionRow("Full Disk Access", icon: "externaldrive", status: messages.history.title,
                                  allowed: messages.history == .allowed, identifier: "messages-history") {
                        guard setup.checkpointPermissionChange(), !model.demo else { return }
                        if messages.history == .allowed { messages.openSettings("Privacy_AllFiles") }
                        else { openedHistorySettings = true; guide.start() }
                    }.background(PermissionSourceAnchor(guide: guide))
                    Divider()
                    permissionRow("Contacts", icon: "person.crop.rectangle", status: messages.contacts.title,
                                  allowed: messages.contacts == .allowed, identifier: "messages-contacts") {
                        guard setup.checkpointPermissionChange() else { return }
                        Task { await messages.enableContacts(model: model) }
                    }
                    Divider()
                    permissionRow("Automation", icon: "gearshape.2", status: messages.sending.title,
                                  allowed: messages.sending == .allowed, identifier: "messages-automation") {
                        guard setup.checkpointPermissionChange() else { return }
                        Task { await messages.enableSending(model: model, requestAfterOpening: true) }
                    }
                    Divider()
                    permissionRow(ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? "Device Control and Data Access" : "Accessibility", icon: "accessibility", status: apps.hostAccessibility.title,
                                  allowed: apps.hostAccessibility == .allowed, identifier: "cua-host") {
                        guard setup.checkpointPermissionChange() else { return }
                        if apps.hostAccessibility == .allowed { apps.openSettings("Privacy_Accessibility", demo: model.demo) }
                        else if model.demo { apps.enableHostAccessibility(demo: true) }
                        else { showAppAccessGuide(capture: false) }
                    }.background(PermissionSourceAnchor(guide: appGuide))
                    Divider()
                    permissionRow("Screen Recording", icon: "display", status: apps.windowCapture.title,
                                  allowed: apps.windowCapture == .allowed, identifier: "cua-capture", available: apps.installed) {
                        guard setup.checkpointPermissionChange() else { return }
                        if apps.windowCapture == .allowed { apps.openSettings("Privacy_ScreenCapture", demo: model.demo) }
                        else { showAppAccessGuide(capture: true) }
                    }
                }
                if model.demo {
                    Text("Demo permissions are simulated. No system access is changed.").font(.caption).foregroundStyle(.secondary)
                }
                if let message = messages.message ?? apps.message ?? appGuide.message ?? guide.message {
                    Text(message).font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
            }
            .padding(16).frame(maxWidth: 680, alignment: .leading)
            .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.12)))
            .padding(.horizontal, 28).padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Button("Back") { setup.reviewStats() }
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
            }.padding(20)
        }
        .task { await setup.refreshPermissions() }
        .onDisappear { appGuide.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await setup.refreshPermissions() }
        }
    }

    private func showAppAccessGuide(capture: Bool) {
        if model.demo {
            if capture { apps.enableScreenCapture(demo: true) }
            else { apps.enableHostAccessibility(demo: true) }
            return
        }
        appGuide.start(appURL: Bundle.main.bundleURL, appName: "msgblast",
                       pane: capture ? "Privacy_ScreenCapture" : "Privacy_Accessibility",
                       permissionName: capture ? "Screen Recording" : ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? "Device Control and Data Access" : "Accessibility") {
            await apps.refresh(demo: false)
            return capture ? apps.windowCapture == .allowed : apps.hostAccessibility == .allowed
        }
    }

    private func permissionRow(_ title: String, icon: String, status: String,
                               allowed: Bool, identifier: String, available: Bool = true,
                               action: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { allowed }, set: { requested in
            // macOS owns the grant. Keep showing its real state until it changes.
            if requested != allowed { action() }
        })) {
            Label(title, systemImage: icon)
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(PermissionSwitchStyle())
        .disabled(busy || !available)
        .accessibilityLabel(title)
        .accessibilityHint(status)
        .accessibilityIdentifier("enable-\(identifier)-permission")
        .padding(.vertical, 8).frame(minHeight: 42)
    }
}

private struct PermissionSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Button { configuration.isOn.toggle() } label: {
                Capsule()
                    .fill(configuration.isOn ? Color.green : Color.red)
                    .frame(width: 40, height: 24)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(.white).frame(width: 20, height: 20).padding(2)
                    }
            }
            .buttonStyle(.plain)
        }
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}
