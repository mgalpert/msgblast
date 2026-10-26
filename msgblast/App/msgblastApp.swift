import SwiftUI
import AppKit
import Combine
import msgblastCore
struct msgblastApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
    @StateObject private var startup = AppStartup()
    private var model: AppModel? { startup.model }
    @StateObject private var updater = AppUpdater()
    @Environment(\.openWindow) private var openWindow
    private static let menuBarIcon: NSImage = {
        let image = NSImage(contentsOf: Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png", subdirectory: "QuickAccess")!)!
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "msgblast Quick Access"
        return image
    }()
    private var preferredWindowSize: NSSize {
        if model?.needsOnboarding == true || model?.needsSharingChoice == true {
            let compact = model?.state.onboarding?.stage == .choosing || model?.state.onboarding?.currentStep == .messages
            return NSSize(width: 840, height: compact ? 760 : 860)
        }
        return NSSize(width: 1600, height: 1100)
    }
    private var initialWindowSize: NSSize {
        let screen = NSScreen.main?.visibleFrame.size ?? preferredWindowSize
        return NSSize(width: min(preferredWindowSize.width, screen.width), height: min(preferredWindowSize.height, screen.height))
    }
    var body: some Scene {
        WindowGroup(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "msgblast", id: "main") {
            Group {
                if startup.needsInstallation { InstallationView() }
                else if let model {
                    Group {
                        if model.needsSharingChoice { SharingChoiceView(model: model) }
                        else if model.needsOnboarding { OnboardingView(model: model) }
                        else { MainView(model: model, updater: updater) }
                    }.onAppear {
                        lifecycle.configure(model: model); updater.configure(delegate: lifecycle)
                        lifecycle.reopenWorkspace = { [weak model] in model?.coordinator?.reopenWorkspace() ?? false }
                        startup.shortcut.onTrigger = startNewBlast
                    }
                }
            }.background(InitialWindowFrame(size: preferredWindowSize))
        }.defaultSize(width: initialWindowSize.width, height: initialWindowSize.height).windowToolbarStyle(.unified)
        .commands {
            BlastCommands()
            CommandGroup(after: .appInfo) {
                Button("Share Feedback…") { FeedbackWindowController.show(model: model, updater: updater) }
                Button("Build a New Feature…") { BuildFeatureWindowController.show() }
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(updater.configuration.isEnabled && !updater.canCheckForUpdates)
            }
            CommandGroup(after: .newItem) {
                Button("Refresh Messages") { model?.refresh() }.keyboardShortcut("r", modifiers: .command).disabled(model == nil)
                Button("Review Messages Setup…") { model?.onboarding.reviewMessagesAgents() }
                    .disabled(model == nil || model?.busy == true || model?.webBroadcastBusy == true)
            }
            CommandMenu("Comparisons") {
                ForEach(model?.state.comparisons ?? []) { comparison in Button(comparison.title) { model?.coordinator?.open(comparison.id) } }
            }
            CommandGroup(replacing: .help) {
                Button("Share Feedback…") { FeedbackWindowController.show(model: model, updater: updater) }
                Button("Build a New Feature…") { BuildFeatureWindowController.show() }
            }
        }
        Settings {
            if let model { AppSettingsView(model: model, updater: updater, shortcut: startup.shortcut) }
            else { InstallationView() }
        }
        MenuBarExtra {
            if let model {
                QuickAccessMenu(model: model, newBlast: startNewBlast, showWorkspace: showWorkspace)
            } else { Button("Show msgblast", action: showWorkspace) }
        } label: {
            Label { Text("msgblast Quick Access") } icon: { Image(nsImage: Self.menuBarIcon) }
                .labelStyle(.iconOnly)
        }
    }
    private func showWorkspace() {
        NSApp.activate(ignoringOtherApps: true)
        if model?.coordinator?.reopenWorkspace() != true { openWindow(id: "main") }
    }
    private func startNewBlast() {
        guard model?.requestNewBlast() == true else { return }
        showWorkspace()
    }
}

private struct QuickAccessMenu: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var web: WebAgents
    @Environment(\.openSettings) private var openSettings
    let newBlast: () -> Void
    let showWorkspace: () -> Void
    init(model: AppModel, newBlast: @escaping () -> Void, showWorkspace: @escaping () -> Void) {
        self.model = model; self.web = model.webAgents
        self.newBlast = newBlast; self.showWorkspace = showWorkspace
    }
    var body: some View {
        Button("New Blast", action: newBlast).disabled(!model.canStartNewBlast)
        Menu("New Chat With") {
            ForEach(model.quickChatAgents) { agent in
                Button(agent.name) {
                    if model.requestNewBlast(agent: agent.id) { showWorkspace() }
                }
            }
            if model.quickChatAgents.isEmpty { Text("No connected agents") }
        }.disabled(!model.canStartNewBlast || model.quickChatAgents.isEmpty)
        Button("Show msgblast", action: showWorkspace)
        Divider()
        Button("Settings…") { NSApp.activate(ignoringOtherApps: true); openSettings() }
        Divider()
        Button("Quit msgblast") { NSApp.terminate(nil) }
    }
}

struct MainWindowActions {
    var newBlast: () -> Void
    var showAgents: () -> Void
    var showDiscover: () -> Void
    var canStartBlast: Bool
}

private struct MainWindowActionsKey: FocusedValueKey { typealias Value = MainWindowActions }
private struct DiscoverSearchActionKey: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
    var mainWindowActions: MainWindowActions? {
        get { self[MainWindowActionsKey.self] }
        set { self[MainWindowActionsKey.self] = newValue }
    }
    var discoverSearch: (() -> Void)? {
        get { self[DiscoverSearchActionKey.self] }
        set { self[DiscoverSearchActionKey.self] = newValue }
    }
}

private struct BlastCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.mainWindowActions) private var actions
    @FocusedValue(\.discoverSearch) private var find
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Blast") {
                if let actions { actions.newBlast() }
                else { openWindow(id: "main") }
            }
                .keyboardShortcut("n").disabled(actions?.canStartBlast == false)
        }
        CommandGroup(after: .sidebar) {
            Button("Show Agents") { actions?.showAgents() }
                .keyboardShortcut("1").disabled(actions == nil)
            Button("Show Discover") { actions?.showDiscover() }
                .keyboardShortcut("2").disabled(actions == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Find in Discover…") { find?() }
                .keyboardShortcut("f").disabled(find == nil || actions == nil)
        }
    }
}

@main
enum msgblastMain {
    @MainActor static func main() {
        #if DEBUG
        if UpdateProbe.isLocalFixture {
            if ProcessInfo.processInfo.arguments.contains("--update-probe") { UpdateProbe.run() }
            if Bundle.main.object(forInfoDictionaryKey: "msgblastUpdateProbeRelaunch") as? Bool == true { UpdateProbe.verifyRelaunch() }
        }
        #endif
        msgblastApp.main()
    }
}

@MainActor
private final class AppStartup: ObservableObject {
    let needsInstallation: Bool
    let model: AppModel?
    let shortcut = NewBlastShortcut()
    private var observation: AnyCancellable?

    init() {
        #if DEBUG
        let development = true
        let preview = ProcessInfo.processInfo.arguments.contains("--installation-preview")
        #else
        let development = false
        let preview = false
        #endif
        needsInstallation = preview || InstallationLocation.needsInstallation(
            bundleURL: Bundle.main.bundleURL,
            homeURL: FileManager.default.homeDirectoryForCurrentUser, development: development)
        model = needsInstallation ? nil : AppModel()
        if let model {
            model.coordinator = WindowCoordinator(model: model)
            // Loads remote control settings; listens only if the user turned it on.
            _ = model.remote
        }
        // Keep comparison menus in sync without constructing the model for an
        // uninstalled copy (its initializer starts Messages history polling).
        observation = model?.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        if let model {
            Task {
                await model.onboarding.resumePermissionsAtLaunch()
            }
        }
    }
}

// Apply the launch size once, after SwiftUI restores the window's previous frame.
// Subsequent user resizing is left alone.
private struct InitialWindowFrame: NSViewRepresentable {
    let size: NSSize
    func makeNSView(context: Context) -> InitialWindowSizingView {
        let view = InitialWindowSizingView()
        view.preferredSize = size
        return view
    }
    func updateNSView(_ nsView: InitialWindowSizingView, context: Context) {
        guard nsView.preferredSize != size else { return }
        nsView.preferredSize = size
        nsView.applySize()
    }
}

private final class InitialWindowSizingView: NSView {
    var preferredSize = NSSize(width: 1600, height: 1100)
    private var applied = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !applied else { return }
        applied = true
        applySize()
    }
    func applySize() {
        guard let window else { return }
        let size = preferredSize
        DispatchQueue.main.async { [weak window] in
            guard let window, let screen = window.screen ?? NSScreen.main else { return }
            let bounds = screen.visibleFrame
            let width = min(size.width, bounds.width), height = min(size.height, bounds.height)
            window.setFrame(NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2,
                                   width: width, height: height), display: true)
        }
    }
}
