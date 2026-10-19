import AppKit
import ApplicationServices
import Combine
import Foundation

public enum CuaPermissionStatus: Sendable {
    case checking, allowed, off, unknown, notInstalled
    public var title: String {
        switch self { case .checking: "Checking…"; case .allowed: "Allowed"; case .off: "Off"; case .unknown: "Not checked"; case .notInstalled: "Not installed" }
    }
}

struct CuaDriverPermissionReport: Decodable, Sendable {
    struct Source: Decodable, Sendable { let attribution: String?; let bundle_id: String? }
    let accessibility: Bool?
    let screen_recording: Bool?
    let source: Source?
    var identifiesDriver: Bool { source?.attribution == "driver-daemon" && source?.bundle_id == "com.trycua.driver" }
}

// Status does not start a daemon or raise consent. Only the explicit setup
// command enters CuaDriver's own LaunchServices-based permission flow.
struct CuaPermissionDriver: Sendable {
    let executable: URL
    func status() async throws -> CuaDriverPermissionReport {
        let result = try await run(["permissions", "status", "--json"], operation: "permission check", timeout: 10)
        return try JSONDecoder().decode(CuaDriverPermissionReport.self, from: Data(result.utf8))
    }
    func setup() async throws { _ = try await run(["permissions", "grant"], operation: "permission setup", timeout: 120) }
    private func run(_ arguments: [String], operation: String, timeout: TimeInterval) async throws -> String {
        let cancellation = AgentCancellation()
        do {
            let result = try await withTaskCancellationHandler {
                try await Task.detached {
                    try AgentProcess.run(executable: executable, arguments: arguments, input: "", environment: ProcessInfo.processInfo.environment,
                                         timeout: timeout, cancellation: cancellation)
                }.value
            } onCancel: { cancellation.cancel() }
            guard result.status == 0 else { throw DesktopAppError.unavailable("Cua \(operation) could not finish. Open CuaDriver and check its permissions, then check again here.") }
            return result.stdout
        } catch PersonalAgentError.timedOut {
            throw DesktopAppError.unavailable("Cua \(operation) timed out after \(Int(timeout)) seconds. Open CuaDriver and check its permissions, then check again here.")
        }
    }
}

struct CuaPermissionClient: Sendable {
    var installed: @Sendable () -> Bool
    var hostAccessibility: @MainActor @Sendable (Bool) -> Bool
    var driverPermissions: @Sendable () async throws -> CuaDriverPermissionReport
    var openDriverSetup: @Sendable () async throws -> Void
    var openSettings: @MainActor @Sendable (String) -> Bool
}

@MainActor
public final class CuaPermissionsController: ObservableObject {
    @Published public private(set) var hostAccessibility = CuaPermissionStatus.checking
    @Published public private(set) var driverAccessibility = CuaPermissionStatus.checking
    @Published public private(set) var windowCapture = CuaPermissionStatus.checking
    @Published public private(set) var installed = false
    @Published public private(set) var checking = false
    @Published public private(set) var message: String?
    private let client: CuaPermissionClient
    private var pendingRefresh: Bool?

    public convenience init() { self.init(client: Self.systemClient()) }
    init(client: CuaPermissionClient) { self.client = client }

    public func refresh(demo: Bool) async {
        guard !checking else { pendingRefresh = demo; return }
        checking = true
        defer { checking = false }
        message = nil
        await checkAndDrain(demo: demo)
    }

    public func enableHostAccessibility(demo: Bool) {
        guard !checking else { return }
        if demo { hostAccessibility = .allowed; return }
        hostAccessibility = client.hostAccessibility(true) ? .allowed : .off
        if hostAccessibility != .allowed { openSettings("Privacy_Accessibility", demo: demo) }
    }

    public func enableDriver(demo: Bool) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        message = nil
        if demo { await checkAndDrain(demo: true); return }
        if client.installed() {
            do { try await client.openDriverSetup() }
            catch { message = error.localizedDescription }
        }
        // A successful setup command is not a grant or capture receipt.
        // Independently refresh the daemon's permission identity and status.
        await checkAndDrain(demo: false)
    }

    public func openSettings(_ pane: String, demo: Bool) {
        guard !demo else { return }
        if !client.openSettings(pane) { message = "Open System Settings → Privacy & Security to manage access." }
    }

    private func checkAndDrain(demo: Bool) async {
        await check(demo: demo)
        while let queuedDemo = pendingRefresh {
            pendingRefresh = nil
            await check(demo: queuedDemo)
        }
    }

    private func check(demo: Bool) async {
        if demo { installed = true; hostAccessibility = .allowed; driverAccessibility = .allowed; windowCapture = .allowed; return }
        hostAccessibility = client.hostAccessibility(false) ? .allowed : .off
        installed = client.installed()
        guard installed else { driverAccessibility = .notInstalled; windowCapture = .notInstalled; return }
        do {
            let report = try await client.driverPermissions()
            guard report.identifiesDriver else {
                driverAccessibility = .unknown; windowCapture = .unknown
                message = "CuaDriver's permission status is unavailable. Open CuaDriver, then check again."
                return
            }
            func status(_ grant: Bool?) -> CuaPermissionStatus { grant.map { $0 ? .allowed : .off } ?? .unknown }
            driverAccessibility = status(report.accessibility)
            windowCapture = status(report.screen_recording)
        } catch {
            driverAccessibility = .unknown; windowCapture = .unknown
            message = error.localizedDescription
        }
    }

    private static func systemClient() -> CuaPermissionClient {
        @Sendable func driver() throws -> CuaPermissionDriver {
            guard let executable = DesktopAppConversation.findDriver() else { throw DesktopAppError.unavailable("Install cua-driver before setting up desktop app control.") }
            return CuaPermissionDriver(executable: executable)
        }
        return CuaPermissionClient(installed: { DesktopAppConversation.findDriver() != nil }, hostAccessibility: { prompt in
            if prompt { return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }
            return AXIsProcessTrusted()
        }, driverPermissions: { try await driver().status() }, openDriverSetup: { try await driver().setup() }, openSettings: { pane in
            guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)") else { return false }
            return NSWorkspace.shared.open(url)
        })
    }
}
