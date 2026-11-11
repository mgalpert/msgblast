import Foundation

public enum MacVariant: String, Codable, Hashable, Sendable {
    case production, development, demo
}

/// Mac-wide state. A locked Mac counts as disconnected as a whole: the phone shows
/// "Disconnected: your Mac is locked" and the Mac accepts no command until unlocked.
public struct MacStatus: Codable, Hashable, Sendable {
    public var macName: String
    public var variant: MacVariant
    public var running: Bool
    public var locked: Bool
    /// False while the displays sleep or the system is going to sleep.
    public var awake: Bool
    public var databaseAvailable: Bool
    public var databaseStatus: String
    /// A Messages send or refresh is in progress (`AppModel.busy`).
    public var messagesBusy: Bool
    /// A shared send is in progress (`AppModel.webBroadcastBusy`).
    public var broadcastBusy: Bool
    public var sendingAgentIDs: [String]
    public var keepAwakeEnabled: Bool
    public var keepAwakeHeld: Bool
    public var messagesSendsAllowed: Bool
    public var observedAt: Date
    public init(macName: String, variant: MacVariant, running: Bool = true, locked: Bool, awake: Bool, databaseAvailable: Bool, databaseStatus: String, messagesBusy: Bool, broadcastBusy: Bool, sendingAgentIDs: [String], keepAwakeEnabled: Bool, keepAwakeHeld: Bool, messagesSendsAllowed: Bool, observedAt: Date) {
        self.macName = macName; self.variant = variant; self.running = running; self.locked = locked; self.awake = awake
        self.databaseAvailable = databaseAvailable; self.databaseStatus = databaseStatus; self.messagesBusy = messagesBusy
        self.broadcastBusy = broadcastBusy; self.sendingAgentIDs = sendingAgentIDs; self.keepAwakeEnabled = keepAwakeEnabled
        self.keepAwakeHeld = keepAwakeHeld; self.messagesSendsAllowed = messagesSendsAllowed; self.observedAt = observedAt
    }
    public var anySendInFlight: Bool { messagesBusy || broadcastBusy || !sendingAgentIDs.isEmpty }
    public func sameContent(as other: MacStatus) -> Bool {
        var a = self, b = other
        a.observedAt = .distantPast; b.observedAt = .distantPast
        return a == b
    }
}
