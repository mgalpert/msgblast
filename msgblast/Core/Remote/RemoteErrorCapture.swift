import Foundation

/// Collects user-facing errors raised while a remote command runs. The app routes
/// `AppModel.error` here (instead of the Mac's modal alert) when the current task,
/// or a task it started, carries a capture. Mac-originated actions are unaffected.
public final class RemoteErrorCapture: @unchecked Sendable {
    @TaskLocal public static var current: RemoteErrorCapture?
    private let lock = NSLock()
    private var recorded: [String] = []
    /// Set while the app restores its previous error value, so the restore is not recaptured.
    public var restoring = false
    public init() {}
    public func record(_ message: String) { lock.withLock { if !recorded.contains(message) { recorded.append(message) } } }
    public var messages: [String] { lock.withLock { recorded } }
    public var summary: String? { messages.isEmpty ? nil : messages.joined(separator: " ") }
}
