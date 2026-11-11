import AppKit
import Combine
import msgblastCore
@preconcurrency import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject, @preconcurrency SPUStandardUserDriverDelegate {
    struct PendingUpdate {
        let version: String
        let build: String
        let isReady: Bool
    }
    @Published private(set) var pendingUpdate: PendingUpdate?
    var canCheckForUpdates: Bool { updater?.canCheckForUpdates ?? false }
    let configuration: UpdateConfiguration
    private var updater: SPUUpdater?
    private var userDriver: SidebarUpdateUserDriver?
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

    func configure(delegate: AppLifecycle) {
        guard configuration.isEnabled, updater == nil else { return }
        delegate.observeUpdates(with: self)
        let driver = SidebarUpdateUserDriver(hostBundle: .main, delegate: self)
        driver.owner = self
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: delegate)
        self.userDriver = driver
        self.updater = updater
        do { try updater.start() } catch {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Unable to Check For Updates"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
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

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        showUpdate(update, isReady: state.stage == .installing)
    }

    func showUpdate(_ item: SUAppcastItem, isReady: Bool) {
        // Resuming the same prepared installer must not downgrade its reminder.
        let ready = isReady || (pendingUpdate?.build == item.versionString && pendingUpdate?.isReady == true)
        pendingUpdate = PendingUpdate(version: item.displayVersionString, build: item.versionString, isReady: ready)
    }

    func markUpdateReady() {
        guard let update = pendingUpdate else { return }
        pendingUpdate = PendingUpdate(version: update.version, build: update.build, isReady: true)
    }

    func clearUpdate() { pendingUpdate = nil }

    var automaticallyChecks: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }
    var automaticallyInstalls: Bool {
        get { updater?.automaticallyDownloadsUpdates ?? false }
        set { updater?.automaticallyDownloadsUpdates = newValue }
    }
    var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        return "Version \(version) (\(build))"
    }
    func checkForUpdates() {
        if let updater { updater.checkForUpdates(); return }
        let alert = NSAlert()
        alert.messageText = "Updates unavailable"
        alert.informativeText = "\(configuration.unavailableReason)\n\n\(version)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// Keep Sparkle's standard UI while observing its verified manual-install readiness.
@MainActor
private final class SidebarUpdateUserDriver: SPUStandardUserDriver {
    weak var owner: AppUpdater?

    override func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        owner?.markUpdateReady()
        super.showReady(toInstallAndRelaunch: reply)
    }
}

/// Sparkle's Install and Relaunch follows the same safe-quit path as the app menu.
@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    private weak var model: AppModel?
    var reopenWorkspace: (() -> Bool)?
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, reopenWorkspace?() == true { return false }
        return true
    }
    private weak var updateUI: AppUpdater?
    private let termination = UpdateTermination()
    private var busyObservation: AnyCancellable?
    private var pendingInstall: (() -> Void)?
    #if DEBUG
    var didPostponeRelaunch: (() -> Void)?
    var terminationReplyHandler: ((Bool) -> Void)?
    var saveErrorHandler: ((String) -> Void)?
    #endif

    func observeUpdates(with updater: AppUpdater) { updateUI = updater }

    #if DEBUG
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let appearance = DesignFixture.appearance() { NSApp.appearance = appearance }
    }
    #endif

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        updateUI?.showUpdate(item, isReady: false)
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        updateUI?.showUpdate(item, isReady: true)
        // Sparkle keeps scheduling and owns installation; the sidebar opens its standard UI.
        return false
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate item: SUAppcastItem, state: SPUUserUpdateState) {
        if choice == .skip { updateUI?.clearUpdate() }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        updateUI?.clearUpdate()
    }

    func configure(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        busyObservation = model.$busy.combineLatest(model.$webBroadcastBusy).dropFirst().sink { [weak self] _ in
            Task { @MainActor in
                guard let self, let model = self.model else { return }
                let decision = self.termination.resume(isBusy: model.busy || model.webBroadcastBusy, persist: { try model.saveForTermination() })
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
    func applicationWillTerminate(_ notification: Notification) {
        guard model?.onboardingRestartRequested == true else { return }
        // Launch only after safe termination has actually been approved. Pass
        // the bundle path as an argument, never interpolate it into shell code.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; shift; app=\"$1\"; shift; /usr/bin/open \"$app\" --args \"$@\"", "msgblast-relaunch",
                              String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path] + Array(ProcessInfo.processInfo.arguments.dropFirst())
        try? relaunch.run()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--update-probe") { FileHandle.standardOutput.write(Data("update-probe: safe quit requested\n".utf8)) }
        #endif
        guard let model else { return .terminateNow }
        switch termination.request(isBusy: model.busy || model.webBroadcastBusy, persist: { try model.saveForTermination() }) {
        case .allowed:
            replyToTermination(sender, allowed: true)
            return .terminateLater
        case .deferred: return .terminateLater
        case .cancelled:
            model.onboardingRestartRequested = false
            showSaveError(termination.error ?? "Your drafts could not be saved.")
            return .terminateCancel
        }
    }
    private func replyToTermination(_ sender: NSApplication, allowed: Bool) {
        guard allowed, let model else {
            self.model?.onboardingRestartRequested = false
            completeTerminationReply(sender, allowed: false)
            return
        }
        Task {
            do { try await model.webAgents.saveBrowserDrafts() }
            catch {
                model.onboardingRestartRequested = false
                showSaveError("Your browser drafts could not be saved: \(error.localizedDescription)")
                completeTerminationReply(sender, allowed: false)
                return
            }
            model.personalAgent.beginShutdown()
            model.webAgents.beginShutdown()
            await model.personalAgent.cancelAndWait()
            await model.webAgents.cancelAndWait()
            await EmbeddedCuaDriver.shared.stop()
            completeTerminationReply(sender, allowed: true)
        }
    }
    private func completeTerminationReply(_ sender: NSApplication, allowed: Bool) {
        #if DEBUG
        if let terminationReplyHandler { terminationReplyHandler(allowed); return }
        #endif
        sender.reply(toApplicationShouldTerminate: allowed)
    }
    private func showSaveError(_ message: String) {
        #if DEBUG
        if let saveErrorHandler { saveErrorHandler(message); return }
        #endif
        model?.error = message
        let alert = NSAlert()
        alert.messageText = "msgblast could not quit safely"
        alert.informativeText = message
        alert.addButton(withTitle: "Keep msgblast Open")
        alert.runModal()
    }
}
