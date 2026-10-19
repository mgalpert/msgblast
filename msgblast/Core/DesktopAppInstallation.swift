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
        guard let url, let bundle = Bundle(url: url), bundle.bundleIdentifier == app.bundleID,
              let executable = bundle.executableURL, FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return url
    }
}

struct DesktopAppInstallationClient: Sendable {
    var inspect: @MainActor @Sendable (DesktopAppProvider) -> DesktopAppInstallation
    var open: @MainActor @Sendable (URL) async throws -> Void

    static var system: Self {
        .init(inspect: { app in
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first { !$0.isTerminated }
            return .resolve(for: app, registeredURL: NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID),
                            runningURL: running?.bundleURL, processID: running?.processIdentifier)
        }, open: { url in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        })
    }

    static var demo: Self {
        .init(inspect: { app in .init(url: URL(fileURLWithPath: "/Demo/\(app.name).app"), processID: 1) }, open: { _ in })
    }
}
