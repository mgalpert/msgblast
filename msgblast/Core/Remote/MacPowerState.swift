import AppKit
import CoreGraphics
import Foundation

/// Lock and sleep state for the remote service. Reading it has no side effects.
@MainActor
public final class MacPowerState: ObservableObject {
    @Published public private(set) var locked = false
    @Published public private(set) var displaysAsleep = false
    @Published public private(set) var systemSleeping = false
    public var awake: Bool { !displaysAsleep && !systemSleeping }
    private let readLocked: @MainActor () -> Bool
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    public init(readLocked: @escaping @MainActor () -> Bool = MacPowerState.sessionIsLocked, observe: Bool = true) {
        self.readLocked = readLocked
        locked = readLocked()
        guard observe else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let pairs: [(Notification.Name, @MainActor (MacPowerState) -> Void)] = [
            (NSWorkspace.screensDidSleepNotification, { $0.displaysAsleep = true }),
            (NSWorkspace.screensDidWakeNotification, { $0.displaysAsleep = false; $0.refresh() }),
            (NSWorkspace.willSleepNotification, { $0.systemSleeping = true }),
            (NSWorkspace.didWakeNotification, { $0.systemSleeping = false; $0.refresh() }),
            (NSWorkspace.sessionDidResignActiveNotification, { $0.refresh() }),
            (NSWorkspace.sessionDidBecomeActiveNotification, { $0.refresh() }),
        ]
        for (name, apply) in pairs {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { apply(self) } }
            })
        }
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            observers.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    public func refresh() {
        let value = readLocked()
        if locked != value { locked = value }
    }

    /// Test seam for fixtures; the real values come from the observers above.
    public func simulate(locked: Bool? = nil, displaysAsleep: Bool? = nil) {
        if let locked, self.locked != locked { self.locked = locked }
        if let displaysAsleep, self.displaysAsleep != displaysAsleep { self.displaysAsleep = displaysAsleep }
    }

    public nonisolated static func sessionIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    deinit {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }
}
