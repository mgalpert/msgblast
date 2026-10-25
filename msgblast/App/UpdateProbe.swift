#if DEBUG
import AppKit
import msgblastCore
@preconcurrency import Sparkle

/// Drives real Sparkle in temporary, explicitly marked local fixture bundles only.
@MainActor
final class UpdateProbe: NSObject, SPUUserDriver {
    static var isLocalFixture: Bool {
        let config = UpdateConfiguration(bundleURL: Bundle.main.bundleURL, bundleIdentifier: Bundle.main.bundleIdentifier,
            info: Bundle.main.infoDictionary ?? [:], arguments: ProcessInfo.processInfo.arguments, allowLocalFixture: true, environment: ProcessInfo.processInfo.environment)
        return config.isEnabled && config.isLocalFixture
    }
    private var updater: SPUUpdater!
    private let model = AppModel()
    private let lifecycle = AppLifecycle()
    private static func log(_ message: String) {
        FileHandle.standardOutput.write(Data(("update-probe: " + message + "\n").utf8))
    }
    static func verifyRelaunch() -> Never {
        let model = AppModel()
        do {
            let recovery = Bundle.main.object(forInfoDictionaryKey: "msgblastUpdateRecoveryFixture") as? Bool == true
            if recovery { try model.saveForTermination() } else { try model.save() }
            let data = try JSONSerialization.data(withJSONObject: ["build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "", "draft": model.state.draft, "recovery": recovery])
            try data.write(to: model.local.url.deletingLastPathComponent().appendingPathComponent("relaunch.json"), options: .atomic)
            exit(0)
        } catch { log("relaunch verification failed: \(error)"); exit(1) }
    }
    static func run() -> Never {
        log("starting")
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        log("app initialized")
        let driver = UpdateProbe()
        log("model initialized")
        if Bundle.main.object(forInfoDictionaryKey: "msgblastUpdateRecoveryFixture") as? Bool == true {
            driver.model.state.draft = "New draft after unreadable state"
            log("unreadable-state fixture; new in-memory draft entered")
        }
        driver.lifecycle.configure(model: driver.model)
        app.delegate = driver.lifecycle
        if ProcessInfo.processInfo.arguments.contains("--update-probe-busy") {
            driver.model.busy = true
            driver.lifecycle.didPostponeRelaunch = { [weak model = driver.model] in
                log("postponed for submission")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { model?.busy = false; log("submission finished") }
            }
        }
        driver.updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: driver.lifecycle)
        do { try driver.updater.start() } catch { log("start failed: \(error)"); exit(1) }
        driver.updater.checkForUpdates()
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { log("timed out"); exit(1) }
        app.run()
        exit(0)
    }
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { Self.log("checking") }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        Self.log("found build \(appcastItem.versionString)"); reply(.install)
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) { Self.log("no update"); exit(3) }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) { Self.log("failed: \(error.localizedDescription)"); exit(1) }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { Self.log("downloading") }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() { Self.log("extracting update") }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        Self.log("ready; install and quit")
        reply(.install)
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) { Self.log("installing; terminated: \(applicationTerminated)")
        // A command-line fixture is not registered with Launch Services to receive Sparkle's quit event.
        if !applicationTerminated {
            // Sparkle invokes this callback on the main dispatch queue. Quit
            // from the run loop so asynchronous draft saving can use that queue
            // while AppKit waits for its terminateLater reply.
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
        }
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { Self.log("installed; relaunched: \(relaunched)"); acknowledgement(); exit(0) }
    func dismissUpdateInstallation() {}
}

#endif
