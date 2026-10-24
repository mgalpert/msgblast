import SwiftUI
import AppKit
import msgblastCore

struct PermissionsSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var openedHistorySettings = false
    @ObservedObject private var messages: AppPermissions

    init(model: AppModel) { self.model = model; messages = model.onboarding.messagesPermissions }

    var body: some View {
        PermissionControlsView(model: model, setup: model.onboarding, checkpointOnboarding: false) {
            openedHistorySettings = true
        }
        if openedHistorySettings && messages.history != .allowed {
            Button("Restart & check access") {
                do { try model.saveForTermination() }
                catch { model.error = "Could not save before restarting: \(error.localizedDescription)"; return }
                model.onboardingRestartRequested = true
                NSApp.terminate(nil)
            }.disabled(model.busy || model.webBroadcastBusy)
        }
    }
}

struct PermissionControlsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var setup: OnboardingController
    var checkpointOnboarding = true
    var onHistorySettingsOpened: () -> Void = {}
    @ObservedObject private var messages: AppPermissions
    @ObservedObject private var apps: CuaPermissionsController
    @ObservedObject private var guide: MessagesAccessGuide
    @StateObject private var appGuide = MessagesAccessGuide(pendingKey: "appAccessHandoffPending")
    @State private var saveError: String?

    init(model: AppModel, setup: OnboardingController, checkpointOnboarding: Bool = true,
         onHistorySettingsOpened: @escaping () -> Void = {}) {
        self.model = model
        self.setup = setup
        self.checkpointOnboarding = checkpointOnboarding
        self.onHistorySettingsOpened = onHistorySettingsOpened
        messages = setup.messagesPermissions
        apps = setup.appPermissions
        guide = model.accessGuide
    }

    private var busy: Bool { setup.permissionChecksBusy || setup.checking || model.busy || model.webBroadcastBusy }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                    guard checkpoint(), !model.demo else { return }
                    if messages.history == .allowed { messages.openSettings("Privacy_AllFiles") }
                    else { onHistorySettingsOpened(); guide.start() }
                }.background(PermissionSourceAnchor(guide: guide))
                Divider()
                permissionRow("Contacts", icon: "person.crop.rectangle", status: messages.contacts.title,
                              allowed: messages.contacts == .allowed, identifier: "messages-contacts", available: messages.contacts != .restricted) {
                    guard checkpoint() else { return }
                    Task { await messages.enableContacts(model: model) }
                }
                Divider()
                permissionRow("Automation", icon: "gearshape.2", status: messages.sending.title,
                              allowed: messages.sending == .allowed, identifier: "messages-automation") {
                    guard checkpoint() else { return }
                    Task { await messages.enableSending(model: model, requestAfterOpening: true) }
                }
                Divider()
                permissionRow(ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? "Device Control and Data Access" : "Accessibility", icon: "accessibility", status: apps.hostAccessibility.title,
                              allowed: apps.hostAccessibility == .allowed, identifier: "cua-host") {
                    guard checkpoint() else { return }
                    if apps.hostAccessibility == .allowed { apps.openSettings("Privacy_Accessibility", demo: model.demo) }
                    else if model.demo { apps.enableHostAccessibility(demo: true) }
                    else { showAppAccessGuide(capture: false) }
                }.background(PermissionSourceAnchor(guide: appGuide))
                Divider()
                permissionRow("Screen Recording", icon: "display", status: apps.windowCapture.title,
                              allowed: apps.windowCapture == .allowed, identifier: "cua-capture", available: apps.installed) {
                    guard checkpoint() else { return }
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
            if let saveError { Text(saveError).font(.caption).foregroundStyle(.orange) }
        }
        .task { await refresh() }
        .onDisappear { appGuide.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        if checkpointOnboarding { await setup.refreshPermissions() }
        else {
            await messages.refresh(model: model)
            await apps.refresh(demo: model.demo)
        }
    }

    private func checkpoint() -> Bool {
        guard !busy else { return false }
        if checkpointOnboarding { return setup.checkpointPermissionChange() }
        do { try model.saveForTermination(); saveError = nil; return true }
        catch { saveError = "Could not save before changing access: \(error.localizedDescription)"; return false }
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
