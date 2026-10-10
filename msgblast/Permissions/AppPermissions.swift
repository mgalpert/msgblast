import AppKit
@preconcurrency import Contacts
import Carbon
import Combine

enum AppPermissionStatus: Sendable {
    case checking, allowed, notRequested, denied, restricted, notConnected, needsMessages, unavailable

    var title: String {
        switch self {
        case .checking: "Checking…"
        case .allowed: "Allowed"
        case .notRequested: "Not requested"
        case .denied: "Off"
        case .restricted: "Restricted"
        case .notConnected: "Not connected"
        case .needsMessages, .unavailable: "Not checked"
        }
    }
    var actionTitle: String {
        switch self {
        case .allowed: "Manage"
        case .notRequested: "Enable"
        case .needsMessages: "Check access"
        default: "Open Settings"
        }
    }
}

// Native checks are injectable so regression tests never request system access.
struct AppPermissionClient: Sendable {
    var historyStatus: @Sendable () -> AppPermissionStatus
    var automationStatus: @Sendable (Bool) -> AppPermissionStatus
    var messagesAvailable: Bool
    var messagesRunning: @MainActor @Sendable () -> Bool
    var openMessages: @MainActor @Sendable () async throws -> Void
    var openSettings: @MainActor @Sendable (String) -> Bool
}

@MainActor
final class AppPermissions: ObservableObject {
    @Published private(set) var history = AppPermissionStatus.checking
    @Published private(set) var contacts = AppPermissionStatus.checking
    @Published private(set) var sending = AppPermissionStatus.checking
    @Published private(set) var checkingSending = false
    @Published private(set) var requestingContacts = false
    @Published private(set) var message: String?
    nonisolated private static let messagesURL = URL(fileURLWithPath: "/System/Applications/Messages.app")
    nonisolated private static let messagesBundleID = Bundle(url: messagesURL)?.bundleIdentifier
    private let client: AppPermissionClient

    init(client: AppPermissionClient? = nil) { self.client = client ?? Self.systemClient() }

    func refresh(model: AppModel) async {
        updateContacts(model: model)
        if model.demo {
            let historyStatus: AppPermissionStatus = model.permissionGuidePreview ? .notConnected : .allowed
            if history != historyStatus { history = historyStatus }
            if sending != .allowed { sending = .allowed }
            return
        }
        let client = client
        let historyStatus = await Task.detached { client.historyStatus() }.value
        if history != historyStatus { history = historyStatus }
        guard !checkingSending else { return }
        guard client.messagesAvailable else { sending = .unavailable; return }
        guard client.messagesRunning() else {
            if sending != .needsMessages { sending = .needsMessages }
            return
        }
        checkingSending = true
        defer { checkingSending = false }
        let sendingStatus = await Task.detached { client.automationStatus(false) }.value
        if sending != sendingStatus { sending = sendingStatus }
    }

    func enableContacts(model: AppModel) async {
        guard !requestingContacts else { return }
        message = nil
        guard contacts == .notRequested else { openSettings("Privacy_Contacts"); return }
        requestingContacts = true
        defer { requestingContacts = false }
        await model.connectContacts()
        updateContacts(model: model)
        if !model.contactStatus.isEmpty { message = model.contactStatus }
    }

    func enableSending(model: AppModel) async {
        guard !checkingSending else { return }
        message = nil
        guard sending == .notRequested || sending == .needsMessages else {
            openSettings("Privacy_Automation")
            return
        }
        checkingSending = true
        defer { checkingSending = false }
        // The demo never requests real system access.
        if model.demo { sending = .allowed; return }
        let client = client
        guard client.messagesAvailable else {
            message = "Messages isn’t available on this Mac."
            return
        }
        let checkingOnly = sending == .needsMessages
        if checkingOnly {
            do {
                try await client.openMessages()
            } catch {
                message = "Messages couldn’t open. Open it yourself, then try again."
                return
            }
        }
        // Native checks and requests run off the main thread and do not send
        // an Apple event. Only an explicit Enable action may request consent.
        sending = await Task.detached { client.automationStatus(!checkingOnly) }.value
        if sending == .unavailable { message = "Couldn’t check sending access. Open Messages and try again." }
    }

    func openSettings(_ pane: String) {
        guard client.openSettings(pane) else {
            message = "Open System Settings → Privacy & Security to manage this permission."
            return
        }
    }

    private static func systemClient() -> AppPermissionClient {
        let bundleID = messagesBundleID
        return AppPermissionClient(
            historyStatus: { historyStatus() },
            automationStatus: { ask in
                guard let bundleID else { return .unavailable }
                return automationStatus(bundleID: bundleID, ask: ask)
            },
            messagesAvailable: bundleID != nil,
            messagesRunning: {
                guard let bundleID else { return false }
                return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
            },
            openMessages: {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                _ = try await NSWorkspace.shared.openApplication(at: messagesURL, configuration: configuration)
            },
            openSettings: { pane in
                guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)") else { return false }
                return NSWorkspace.shared.open(url)
            })
    }

    private func updateContacts(model: AppModel) {
        let status: AppPermissionStatus
        if model.demo { status = model.contactsAvailable ? .allowed : .notRequested }
        else {
            status = switch model.contacts.status {
            case .authorized: .allowed
            case .notDetermined: .notRequested
            case .denied: .denied
            case .restricted: .restricted
            @unknown default: .unavailable
            }
        }
        if contacts != status { contacts = status }
    }

    nonisolated private static func automationStatus(bundleID: String, ask: Bool) -> AppPermissionStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        switch AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask) {
        case noErr: return .allowed
        case OSStatus(errAEEventWouldRequireUserConsent): return .notRequested
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(procNotFound): return .needsMessages
        default: return .unavailable
        }
    }

    nonisolated private static func historyStatus() -> AppPermissionStatus {
        // macOS has no public Full Disk Access status API. A fresh read of the
        // protected file checks access without relying on an already-open DB.
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db")
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            _ = try file.read(upToCount: 1)
            return .allowed
        } catch {
            let error = error as NSError
            let errors = [error, error.userInfo[NSUnderlyingErrorKey] as? NSError].compactMap { $0 }
            if errors.contains(where: { ($0.domain == NSCocoaErrorDomain && $0.code == NSFileReadNoPermissionError) ||
                ($0.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains($0.code)) }) { return .denied }
            if errors.contains(where: { ($0.domain == NSCocoaErrorDomain && $0.code == NSFileReadNoSuchFileError) ||
                ($0.domain == NSPOSIXErrorDomain && $0.code == Int(ENOENT)) }) { return .notConnected }
            return .unavailable
        }
    }
}
