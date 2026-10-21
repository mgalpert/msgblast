import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation

public enum CuaPermissionStatus: Sendable {
    case checking, allowed, off, unknown, notInstalled
    public var title: String {
        switch self { case .checking: "Checking…"; case .allowed: "Allowed"; case .off: "Off"; case .unknown: "Not checked"; case .notInstalled: "Not installed" }
    }
}

// Embedded CuaDriver inherits msgblast's permission identity. Query the host
// directly: starting an external daemon must never determine onboarding access.
struct CuaPermissionClient: Sendable {
    var installed: @Sendable () -> Bool
    var hostAccessibility: @MainActor @Sendable (Bool) -> Bool
    var hostScreenCapture: @MainActor @Sendable (Bool) -> Bool
    var openSettings: @MainActor @Sendable (String) -> Bool
}

@MainActor
public final class CuaPermissionsController: ObservableObject {
    @Published public private(set) var hostAccessibility = CuaPermissionStatus.checking
    @Published public private(set) var windowCapture = CuaPermissionStatus.checking
    @Published public private(set) var installed = false
    @Published public private(set) var checking = false
    @Published public private(set) var message: String?
    private let client: CuaPermissionClient
    private var demoHostAllowed: Bool
    private var demoCaptureAllowed: Bool

    public convenience init(demoInitiallyAllowed: Bool = true) { self.init(client: Self.systemClient(), demoInitiallyAllowed: demoInitiallyAllowed) }
    init(client: CuaPermissionClient, demoInitiallyAllowed: Bool = true) {
        self.client = client
        demoHostAllowed = demoInitiallyAllowed
        demoCaptureAllowed = demoInitiallyAllowed
    }

    public func refresh(demo: Bool) async {
        checking = true
        defer { checking = false }
        message = nil
        if demo {
            installed = true
            hostAccessibility = demoHostAllowed ? .allowed : .off
            windowCapture = demoCaptureAllowed ? .allowed : .off
        } else {
            installed = client.installed()
            hostAccessibility = client.hostAccessibility(false) ? .allowed : .off
            windowCapture = client.hostScreenCapture(false) ? .allowed : .off
            if !installed { message = "App control is missing from this copy of msgblast. Update or reinstall msgblast to connect Mac apps." }
        }
    }

    public func enableHostAccessibility(demo: Bool) {
        if demo { demoHostAllowed = true; hostAccessibility = .allowed; return }
        hostAccessibility = client.hostAccessibility(true) ? .allowed : .off
        if hostAccessibility != .allowed { openSettings("Privacy_Accessibility", demo: false) }
    }

    public func enableScreenCapture(demo: Bool) {
        if demo { demoCaptureAllowed = true; windowCapture = .allowed; return }
        windowCapture = client.hostScreenCapture(true) ? .allowed : .off
        if windowCapture != .allowed { openSettings("Privacy_ScreenCapture", demo: false) }
    }

    public func openSettings(_ pane: String, demo: Bool) {
        guard !demo else { return }
        if !client.openSettings(pane) { message = "Open System Settings → Privacy & Security to manage msgblast access." }
    }

    private static func systemClient() -> CuaPermissionClient {
        CuaPermissionClient(installed: { DesktopAppConversation.findDriver() != nil }, hostAccessibility: { prompt in
            if prompt { return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }
            return AXIsProcessTrusted()
        }, hostScreenCapture: { prompt in
            prompt ? CGRequestScreenCaptureAccess() : CGPreflightScreenCaptureAccess()
        }, openSettings: { pane in
            guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)") else { return false }
            return NSWorkspace.shared.open(url)
        })
    }
}
