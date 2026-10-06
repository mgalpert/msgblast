import AppKit
import Combine
import msgblastCore
@preconcurrency import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject {
    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates ?? false }
    let configuration: UpdateConfiguration
    private var controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []

    override init() {
        #if DEBUG
        let allowFixture = true
        #else
        let allowFixture = false
        #endif
        configuration = UpdateConfiguration(bundleURL: Bundle.main.bundleURL, bundleIdentifier: Bundle.main.bundleIdentifier,
            info: Bundle.main.infoDictionary ?? [:], arguments: ProcessInfo.processInfo.arguments, allowLocalFixture: allowFixture, environment: ProcessInfo.processInfo.environment)
        super.init()
    }

    func configure(delegate: SPUUpdaterDelegate) {
        guard configuration.isEnabled, controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.objectWillChange.send() }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.objectWillChange.send() }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.objectWillChange.send() }
            }
        ]
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }
    var automaticallyInstalls: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }
    var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        return "Version \(version) (\(build))"
    }
    func checkForUpdates() {
        if let controller { controller.checkForUpdates(nil); return }
        let alert = NSAlert()
        alert.messageText = "Updates unavailable"
        alert.informativeText = "\(configuration.unavailableReason)\n\n\(version)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// Sparkle's Install and Relaunch follows the same safe-quit path as the app menu.
@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    private weak var model: AppModel?
    private let termination = UpdateTermination()
    private var busyObservation: AnyCancellable?
    private var pendingInstall: (() -> Void)?
    #if DEBUG
    var didPostponeRelaunch: (() -> Void)?
    #endif

    func configure(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        busyObservation = model.$busy.combineLatest(model.$webBroadcastBusy).dropFirst().sink { [weak self] _ in
            Task { @MainActor in
                guard let self, let model = self.model else { return }
                let decision = self.termination.resume(isBusy: model.busy || model.webBroadcastBusy, persist: { try model.save() })
                if decision != .cancelled, !model.busy, !model.webBroadcastBusy, let install = self.pendingInstall {
                    self.pendingInstall = nil
                    install()
                }
                if let decision {
                    if let error = self.termination.error { self.showSaveError(error) }
                    self.replyToTermination(NSApp, allowed: decision == .allowed)
                }
            }
        }
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard model?.busy == true || model?.webBroadcastBusy == true else { return false }
        pendingInstall = installHandler
        #if DEBUG
        didPostponeRelaunch?()
        #endif
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--update-probe") { FileHandle.standardOutput.write(Data("update-probe: safe quit requested\n".utf8)) }
        #endif
        guard let model else { return .terminateNow }
        switch termination.request(isBusy: model.busy || model.webBroadcastBusy, persist: { try model.save() }) {
        case .allowed:
            model.personalAgent.beginShutdown()
            model.webAgents.beginShutdown()
            guard !model.personalAgent.running.isEmpty || model.webAgents.hasNativeRequests else { return .terminateNow }
            replyToTermination(sender, allowed: true)
            return .terminateLater
        case .deferred: return .terminateLater
        case .cancelled:
            showSaveError(termination.error ?? "Your drafts could not be saved.")
            return .terminateCancel
        }
    }
    private func replyToTermination(_ sender: NSApplication, allowed: Bool) {
        guard allowed, let model else {
            sender.reply(toApplicationShouldTerminate: false)
            return
        }
        model.personalAgent.beginShutdown()
        model.webAgents.beginShutdown()
        Task {
            await model.personalAgent.cancelAndWait()
            await model.webAgents.cancelAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
    }
    private func showSaveError(_ message: String) {
        model?.error = message
        let alert = NSAlert()
        alert.messageText = "msgblast could not quit safely"
        alert.informativeText = message
        alert.addButton(withTitle: "Keep msgblast Open")
        alert.runModal()
    }
}
