import Foundation
import IOKit.pwr_mgt

/// Holds one `PreventUserIdleSystemSleep` assertion while a phone that asked for it is
/// connected, and during any remote send. The Mac's Settings toggle disables both.
@MainActor
public final class RemoteKeepAwake: ObservableObject {
    public struct Assertions: Sendable {
        var create: @Sendable (String) -> UInt32?
        var release: @Sendable (UInt32) -> Void
        public static let system = Assertions(create: { reason in
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
            return result == kIOReturnSuccess ? id : nil
        }, release: { id in IOPMAssertionRelease(id) })
        public init(create: @escaping @Sendable (String) -> UInt32?, release: @escaping @Sendable (UInt32) -> Void) {
            self.create = create; self.release = release
        }
    }
    @Published public private(set) var held = false
    public private(set) var settingEnabled: Bool
    private var clientConnected = false
    private var clientRequested = false
    private var activeSends = 0
    private var assertion: UInt32?
    private let assertions: Assertions

    public init(settingEnabled: Bool, assertions: Assertions = .system) {
        self.settingEnabled = settingEnabled
        self.assertions = assertions
    }

    public func setSettingEnabled(_ enabled: Bool) { settingEnabled = enabled; update() }
    public func setClient(connected: Bool) {
        clientConnected = connected
        if !connected { clientRequested = false }
        update()
    }
    /// The phone's request. Returns false when the Mac setting refuses it.
    @discardableResult
    public func setClientRequested(_ requested: Bool) -> Bool {
        clientRequested = requested
        update()
        return !requested || settingEnabled
    }
    public func beginSend() { activeSends += 1; update() }
    public func endSend() { activeSends = max(0, activeSends - 1); update() }

    private func update() {
        let wanted = settingEnabled && ((clientConnected && clientRequested) || activeSends > 0)
        if wanted, assertion == nil {
            assertion = assertions.create("msgblast remote control: a paired phone is connected or a send is running")
        } else if !wanted, let id = assertion {
            assertions.release(id)
            assertion = nil
        }
        if held != (assertion != nil) { held = assertion != nil }
    }

    deinit {
        if let assertion { assertions.release(assertion) }
    }
}
