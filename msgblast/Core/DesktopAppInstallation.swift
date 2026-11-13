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

    static func launchPlan(activates: Bool, running: Bool, hidden: Bool, hasStandardWindow: Bool) -> (unhide: Bool, open: Bool, activates: Bool, restoreFront: Bool) {
        guard !activates else { return (false, true, true, false) }
        guard running, hasStandardWindow else { return (hidden, true, false, true) }
        return (hidden, false, false, false)
    }

    @MainActor private static func openSystem(_ url: URL, activates: Bool) async throws {
        let target = runningApplication(for: url)
        let plan = launchPlan(activates: activates, running: target != nil, hidden: target?.isHidden == true,
                              hasStandardWindow: target.map(hasStandardWindow) == true)
        guard plan.open else { if plan.unhide { target?.unhide() }; return }
        let previous = NSWorkspace.shared.frontmostApplication
        let wasActive = target?.isActive == true
        if plan.unhide { target?.unhide() }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = plan.activates
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        guard plan.restoreFront else { return }
        let targetPID = target?.processIdentifier
        try? await restoreFront(after: .seconds(5), targetIsFrontmostActive: {
            guard let app = runningApplication(for: url), app.isActive else { return false }
            return NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        }, previousCanRestore: {
            guard let previous, !wasActive, !previous.isTerminated else { return false }
            return previous.processIdentifier != targetPID && previous.bundleIdentifier != Bundle(url: url)?.bundleIdentifier
        }, restore: { previous?.activate(options: []) })
    }

    @MainActor private static func runningApplication(for url: URL) -> NSRunningApplication? {
        Bundle(url: url)?.bundleIdentifier.flatMap { bundleID in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { !$0.isTerminated }
        }
    }

    @MainActor private static func hasStandardWindow(_ application: NSRunningApplication) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(application.processIdentifier), kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }
        return windows.contains { window in
            var subrole: CFTypeRef?
            return AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole) == .success && subrole as? String == kAXStandardWindowSubrole
        }
    }

    /// ChatGPT brings itself forward on launch and on a reopen event even when asked not to,
    /// so a background open hands the front back to the app that had it. Known limits: ChatGPT
    /// still shows as a brief flash; a launch whose window appears more than five seconds after
    /// the open returns is not handed back; a deliberate switch to ChatGPT within those five
    /// seconds is undone.
    @MainActor static func restoreFront<C: Clock>(after timeout: Duration, interval: Duration = .milliseconds(50), clock: C = ContinuousClock(),
                                                  targetIsFrontmostActive: @MainActor @Sendable () -> Bool, previousCanRestore: @MainActor @Sendable () -> Bool,
                                                  restore: @MainActor @Sendable () -> Void) async throws where C.Duration == Duration {
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if targetIsFrontmostActive() { if previousCanRestore() { restore() }; return }
            try await clock.sleep(for: min(interval, clock.now.duration(to: deadline)))
        }
    }

    static var demo: Self {
        .init(inspect: { app in .init(url: URL(fileURLWithPath: "/Demo/\(app.name).app"), processID: 1) }, open: { _, _ in })
    }
}
