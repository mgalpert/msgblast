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
    var open: @MainActor @Sendable (URL) async throws -> Void
    var isHidden: @MainActor @Sendable (DesktopAppProvider) -> Bool = { _ in false }

    static var system: Self {
        .init(inspect: { app in
            let running = app.bundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }.first { !$0.isTerminated }
            let registered = app.bundleIDs.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first { DesktopAppInstallation.validatedURL($0, for: app) != nil }
            return .resolve(for: app, registeredURL: registered,
                            runningURL: running?.bundleURL, processID: running?.processIdentifier)
        }, open: { url in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }, isHidden: { app in
            app.bundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
                .contains { !$0.isTerminated && $0.isHidden }
        })
    }

    static var demo: Self {
        .init(inspect: { app in .init(url: URL(fileURLWithPath: "/Demo/\(app.name).app"), processID: 1) }, open: { _ in })
    }
}
