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

    static var system: Self {
        .init(inspect: { app in
            let running = app.bundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }.first { !$0.isTerminated }
            let registered = app.bundleIDs.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first { DesktopAppInstallation.validatedURL($0, for: app) != nil }
            return .resolve(for: app, registeredURL: registered,
                            runningURL: running?.bundleURL, processID: running?.processIdentifier)
        }, open: { url, activates in
            try await openSystem(url, activates: activates)
        }, isHidden: { app in
            app.bundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
                .contains { !$0.isTerminated && $0.isHidden }
        })
    }

    enum FrontObservation: Equatable, Sendable {
        case previous, target, other
    }

    static func launchPlan(activates: Bool, running: Bool, hidden: Bool, hasStandardWindow: Bool) -> (unhide: Bool, open: Bool, activates: Bool, restoreFront: Bool) {
        guard !activates else { return (false, true, true, false) }
        guard running, hasStandardWindow else { return (hidden, true, false, true) }
        return (hidden, false, false, false)
    }

    static func shouldCheckWindow(activates: Bool, running: Bool) -> Bool {
        !activates && running
    }

    static func afterUnhide(windowAppeared: Bool) -> (open: Bool, restoreFront: Bool) {
        (open: !windowAppeared, restoreFront: !windowAppeared)
    }

    static func frontObservation(frontmostPID: Int32?, previousPID: Int32, targetPID: Int32?) -> FrontObservation {
        guard let frontmostPID else { return .other }
        if let targetPID, frontmostPID == targetPID { return .target }
        return frontmostPID == previousPID ? .previous : .other
    }

    @MainActor private static func openSystem(_ url: URL, activates: Bool) async throws {
        if activates {
            try await openApplication(url, activates: true)
            return
        }
        let target = runningApplication(for: url)
        var hasStandardWindow = false
        if shouldCheckWindow(activates: activates, running: target != nil) {
            hasStandardWindow = await standardWindow(processID: target?.processIdentifier)
        }
        let plan = launchPlan(activates: activates, running: target != nil, hidden: target?.isHidden == true,
                              hasStandardWindow: hasStandardWindow)
        if plan.open {
            try await openBackground(url, target: target, plan: plan)
            return
        }
        if plan.unhide { target?.unhide() }
        let postUnhide = afterUnhide(windowAppeared: await standardWindowAppeared(processID: target?.processIdentifier))
        guard postUnhide.open else { return }
        try await openBackground(url, target: target, plan: (false, postUnhide.open, false, postUnhide.restoreFront))
    }

    @MainActor private static func openBackground(_ url: URL, target: NSRunningApplication?, plan: (unhide: Bool, open: Bool, activates: Bool, restoreFront: Bool)) async throws {
        let previous = NSWorkspace.shared.frontmostApplication
        let wasActive = target?.isActive == true
        if plan.unhide { target?.unhide() }
        try await openApplication(url, activates: plan.activates)
        guard plan.restoreFront else { return }
        guard let previous else { return }
        try? await restoreFront(after: .seconds(5), observeFront: {
            let targetPID = runningApplication(for: url)?.processIdentifier
            return frontObservation(frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                    previousPID: previous.processIdentifier, targetPID: targetPID)
        }, previousCanRestore: {
            guard !wasActive, !previous.isTerminated else { return false }
            return previous.processIdentifier != runningApplication(for: url)?.processIdentifier
        }, restore: { previous.activate(options: []) })
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
            return AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole) == .success && subrole as? String == kAXStandardWindowSubrole
        }
    }

    @MainActor private static func standardWindowAppeared(processID: Int32?) async -> Bool {
        guard let processID else { return false }
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if await standardWindow(processID: processID) { return true }
            try? await clock.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// ChatGPT brings itself forward on launch and on a reopen event even when asked not to,
    /// so a background open hands the front back to the app that had it. Known limits: ChatGPT
    /// still shows as a brief flash; a launch whose window appears more than five seconds after
    /// the open is not handed back; a deliberate switch to ChatGPT within those five
    /// seconds is undone, while a switch to another app cancels the hand-back. A window on
    /// another Space is reopened, so it also flashes.
    @MainActor static func restoreFront<C: Clock>(after timeout: Duration, interval: Duration = .milliseconds(50), clock: C = ContinuousClock(),
                                                  observeFront: @MainActor @Sendable () -> FrontObservation, previousCanRestore: @MainActor @Sendable () -> Bool,
                                                  restore: @MainActor @Sendable () -> Void) async throws where C.Duration == Duration {
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            switch observeFront() {
            case .previous: try await clock.sleep(for: min(interval, clock.now.duration(to: deadline)))
            case .target: if previousCanRestore() { restore() }; return
            case .other: return
            }
        }
    }

    static var demo: Self {
        .init(inspect: { app in .init(url: URL(fileURLWithPath: "/Demo/\(app.name).app"), processID: 1) }, open: { _, _ in })
    }
}
