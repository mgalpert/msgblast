import AppKit
import Foundation

public struct DesktopAppInstallation: Equatable, Sendable {
    public let url: URL?
    public let processID: Int32?
    public var isInstalled: Bool { url != nil }
    public var isRunning: Bool { isInstalled && processID != nil }

    static func resolve(for app: DesktopAppProvider, registeredURL: URL?, runningURL: URL?, processID: Int32?) -> Self {
        if let url = validatedURL(runningURL, for: app) { return .init(url: url, processID: processID) }
        return .init(url: validatedURL(registeredURL, for: app), processID: nil)
    }

    static func validatedURL(_ url: URL?, for app: DesktopAppProvider) -> URL? {
        guard let url, let bundle = Bundle(url: url), bundle.bundleIdentifier.map(app.bundleIDs.contains) == true,
              let executable = bundle.executableURL, FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return url
    }
}

struct DesktopAppInstallationClient: Sendable {
    var inspect: @MainActor @Sendable (DesktopAppProvider) -> DesktopAppInstallation
    var open: @MainActor @Sendable (URL, Bool) async throws -> Void
    var isHidden: @MainActor @Sendable (DesktopAppProvider) -> Bool = { _ in false }

    /// Gives the front back to the app that had it before a background open. Called up to
    /// `maxHandBacks` times per open, each time the guarded watch sees the target take the front.
    typealias FrontHandBack = @MainActor @Sendable (_ previousPID: Int32) async -> Void

    /// Best effort only: macOS may ignore an activation requested from the background.
    static let activatePrevious: FrontHandBack = { pid in
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
    }

    static func system(handBack: @escaping FrontHandBack) -> Self {
        .init(inspect: { app in
            let running = app.bundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }.first { !$0.isTerminated }
            let registered = app.bundleIDs.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first { DesktopAppInstallation.validatedURL($0, for: app) != nil }
            return .resolve(for: app, registeredURL: registered,
                            runningURL: running?.bundleURL, processID: running?.processIdentifier)
        }, open: { url, activates in
            try await openSystem(url, activates: activates, handBack: handBack)
        }, isHidden: { app in
            app.bundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
                .contains { !$0.isTerminated && $0.isHidden }
        })
    }

    /// Everything the hand-back decision depends on: who was in front when the open started,
    /// every app activation since then, the front right now, and the hand-backs made so far.
    struct FrontWatchState: Equatable, Sendable {
        var previousPID: Int32?
        var targetWasActive: Bool
        var activations: [Int32]
        var frontmostPID: Int32?
        var targetPID: Int32?
        var previousRunning: Bool
        var handBacks = 0
        var sinceLastHandBack: Duration?
    }

    enum HandBackDecision: Equatable, Sendable {
        case wait, handBack, cancel, done
    }

    static let maxHandBacks = 3
    static let quietAfterHandBack: Duration = .milliseconds(1500)

    /// After a launch ChatGPT keeps asking for the front for about a second, so each time it
    /// takes the front again it is handed back again, up to `maxHandBacks` times. Any
    /// activation by an app other than ChatGPT or the previous app cancels for good.
    static func handBackDecision(_ state: FrontWatchState) -> HandBackDecision {
        guard let previous = state.previousPID, !state.targetWasActive, state.previousRunning,
              previous != state.targetPID else { return .cancel }
        guard state.activations.allSatisfy({ $0 == state.targetPID || $0 == previous }) else { return .cancel }
        guard state.handBacks < maxHandBacks else { return .done }
        let targetActivations = state.activations.filter { $0 == state.targetPID }.count
        if state.frontmostPID != nil, state.frontmostPID == state.targetPID, targetActivations > state.handBacks { return .handBack }
        if state.handBacks > 0, state.frontmostPID == previous, let quiet = state.sinceLastHandBack, quiet >= quietAfterHandBack { return .done }
        return .wait
    }

    /// The effects of a background open, injected so the order of steps can be tested.
    struct BackgroundOpenSteps {
        var running: Bool
        var hidden: Bool
        var unhide: @MainActor () -> Void
        var readWindow: @MainActor () async -> Bool
        var open: @MainActor () async throws -> Void
        var afterOpen: @MainActor () async -> Void
    }

    /// A running copy is unhidden and given a second to show a standard window; only if none
    /// shows up, or the app isn't running, is it opened in the background, followed by the
    /// guarded hand-back.
    @MainActor static func openInBackground<C: Clock>(_ steps: BackgroundOpenSteps, windowWait: Duration = .seconds(1),
                                                      clock: C = ContinuousClock()) async throws where C.Duration == Duration {
        if steps.running {
            try Task.checkCancellation()
            if steps.hidden { steps.unhide() }
            if try await windowAppeared(within: windowWait, clock: clock, read: steps.readWindow) { return }
        }
        try Task.checkCancellation()
        try await steps.open()
        await steps.afterOpen()
    }

    @MainActor static func windowAppeared<C: Clock>(within timeout: Duration, interval: Duration = .milliseconds(100), clock: C,
                                                    read: @MainActor () async -> Bool) async throws -> Bool where C.Duration == Duration {
        let deadline = clock.now.advanced(by: timeout)
        while true {
            let found = await read()
            try Task.checkCancellation()
            if found { return true }
            guard clock.now < deadline else { return false }
            try await clock.sleep(for: min(interval, clock.now.duration(to: deadline)))
        }
    }

    @MainActor private static func openSystem(_ url: URL, activates: Bool, handBack: @escaping FrontHandBack) async throws {
        if activates {
            try await openApplication(url, activates: true)
            return
        }
        let target = runningApplication(for: url)
        let watch = ActivationWatch(target: target)
        defer { watch.stop() }
        let processID = target?.processIdentifier
        try await openInBackground(.init(running: target != nil, hidden: target?.isHidden == true,
                                         unhide: { target?.unhide() },
                                         readWindow: { await standardWindow(processID: processID) },
                                         open: { try await openApplication(url, activates: false) },
                                         afterOpen: {
            try? await awaitHandBack(after: .seconds(5), state: { watch.state(targetPID: runningApplication(for: url)?.processIdentifier) },
                                     handBack: handBack)
        }))
    }

    @MainActor private static func openApplication(_ url: URL, activates: Bool) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    @MainActor private static func runningApplication(for url: URL) -> NSRunningApplication? {
        Bundle(url: url)?.bundleIdentifier.flatMap { bundleID in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { !$0.isTerminated }
        }
    }

    @MainActor private static func standardWindow(processID: Int32?) async -> Bool {
        guard let processID else { return false }
        return await Task.detached { Self.standardWindowSync(processID: processID) }.value
    }

    private nonisolated static func standardWindowSync(processID: Int32) -> Bool {
        var value: CFTypeRef?
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.5)
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }
        return windows.contains { window in
            var subrole: CFTypeRef?
            AXUIElementSetMessagingTimeout(window, 0.5)
            return AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole) == .success && subrole as? String == kAXStandardWindowSubrole
        }
    }

    /// ChatGPT brings itself forward on launch and on a reopen event even when asked not to,
    /// so a background open hands the front back to the app that had it. When that app is
    /// msgblast, the hand-back goes through its accessibility driver; for any other app it is
    /// best effort and macOS may ignore it. Activations are tracked from before the open
    /// starts. Known limits: a reopen shows one brief flash (about 0.1 s); a launch can show
    /// two (about 0.1 s and 0.3 s), because ChatGPT keeps taking the front for about a second
    /// and is handed back each time, up to three times. A window that appears more than five
    /// seconds after the open is not handed back; a deliberate switch to ChatGPT within those
    /// five seconds is undone, while a switch to any other app cancels the hand-back for good.
    /// A window on another Space is missing from the accessibility window list, so it is
    /// reopened and flashes too.
    @MainActor static func awaitHandBack<C: Clock>(after timeout: Duration, interval: Duration = .milliseconds(50), clock: C = ContinuousClock(),
                                                   state: @MainActor () -> FrontWatchState,
                                                   handBack: FrontHandBack) async throws where C.Duration == Duration {
        let deadline = clock.now.advanced(by: timeout)
        var handBacks = 0, lastHandBack: C.Instant?
        while clock.now < deadline {
            var current = state()
            current.handBacks = handBacks
            current.sinceLastHandBack = lastHandBack.map { $0.duration(to: clock.now) }
            switch handBackDecision(current) {
            case .wait: break
            case .handBack:
                if let previous = current.previousPID { await handBack(previous) }
                handBacks += 1
                lastHandBack = clock.now
            case .cancel, .done: return
            }
            try await clock.sleep(for: min(interval, clock.now.duration(to: deadline)))
        }
    }

    static var demo: Self {
        .init(inspect: { app in .init(url: URL(fileURLWithPath: "/Demo/\(app.name).app"), processID: 1) }, open: { _, _ in })
    }
}

/// Records every app activation from the start of a background open until `stop()`.
@MainActor final class ActivationWatch {
    let previousPID: Int32?
    let targetWasActive: Bool
    private(set) var activations: [Int32] = []
    private var observer: NSObjectProtocol?

    init(target: NSRunningApplication?) {
        previousPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        targetWasActive = target?.isActive == true
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { if let pid { self?.activations.append(pid) } }
        }
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }

    func state(targetPID: Int32?) -> DesktopAppInstallationClient.FrontWatchState {
        let previousRunning = previousPID.flatMap { NSRunningApplication(processIdentifier: $0) }.map { !$0.isTerminated } ?? false
        return .init(previousPID: previousPID, targetWasActive: targetWasActive, activations: activations,
                     frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                     targetPID: targetPID, previousRunning: previousRunning)
    }
}

/// Hands the front back to msgblast's own window through the accessibility driver, which
/// works where activating msgblast's process from the background does not. The window is
/// captured before a background open and cleared once the open returns; the hand-back runs
/// inside the open.
@MainActor final class DesktopHandBackHost {
    private(set) var target: DesktopAppConversation.Target?
    var driver: DesktopAppConversation?
    private let ownPID: Int32
    private let fallback: DesktopAppInstallationClient.FrontHandBack

    init(ownPID: Int32 = ProcessInfo.processInfo.processIdentifier,
         fallback: @escaping DesktopAppInstallationClient.FrontHandBack = DesktopAppInstallationClient.activatePrevious) {
        self.ownPID = ownPID
        self.fallback = fallback
    }

    func systemClient(driver: DesktopAppConversation) -> DesktopAppInstallationClient {
        self.driver = driver
        return .system(handBack: { [self] pid in await handBack(previousPID: pid) })
    }

    func whileOpening(_ open: () async throws -> Void) async throws {
        target = try? await driver?.currentHostWindow()
        defer { target = nil }
        try await open()
    }

    func handBack(previousPID: Int32) async {
        if previousPID == ownPID, let target, let driver {
            let session = "msgblast-handback-\(UUID().uuidString)"
            let activated = (try? await driver.activate(target, session: session)) != nil
            await driver.endSession(session)
            if activated { return }
        }
        await fallback(previousPID)
    }
}
