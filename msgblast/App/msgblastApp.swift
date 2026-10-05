import SwiftUI
import AppKit
import Combine
import msgblastCore
struct msgblastApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
    @StateObject private var startup = AppStartup()
    private var model: AppModel? { startup.model }
    @StateObject private var updater = AppUpdater()
    var body: some Scene {
        WindowGroup("msgblast") {
            Group {
                if startup.needsInstallation { InstallationView() }
                else if let model {
                    MainView(model: model).onAppear { lifecycle.configure(model: model); updater.configure(delegate: lifecycle); if model.coordinator == nil { model.coordinator = WindowCoordinator(model: model) } }
                }
            }
        }.defaultSize(width: 920, height: 660).windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(updater.configuration.isEnabled && !updater.canCheckForUpdates)
            }
            CommandGroup(after: .newItem) { Button("Refresh Messages") { model?.refresh() }.keyboardShortcut("r", modifiers: .command).disabled(model == nil) }
            CommandMenu("Comparisons") {
                ForEach(model?.state.comparisons ?? []) { comparison in Button(comparison.title) { model?.coordinator?.open(comparison.id) } }
            }
        }
        Settings {
            if let model { AppSettingsView(model: model, updater: updater) }
            else { InstallationView() }
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
        // Keep comparison menus in sync without constructing the model for an
        // uninstalled copy (its initializer starts Messages history polling).
        observation = model?.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }
}
