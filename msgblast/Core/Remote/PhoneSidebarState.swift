import Foundation

/// How the sidebar's Phone section is shown. Stored in UserDefaults as `sidebarPhoneCollapsed`
/// only after the user taps; until then the state follows the phone.
public enum PhoneSidebarPreference: Int, Sendable { case automatic = 0, expanded = 1, collapsed = 2 }

public enum PhoneSidebarStatus: Sendable, Equatable { case off, on, connected }

public enum PhoneSidebarState {
    public static let preferenceKey = "sidebarPhoneCollapsed"

    /// Collapsed when the user chose it, or (automatic) once a phone is paired and connected.
    /// Expanded while Remote is off or no phone is paired, so the QR code is seen.
    public static func isCollapsed(preference: PhoneSidebarPreference, enabled: Bool, paired: Bool, connected: Bool) -> Bool {
        switch preference {
        case .expanded: false
        case .collapsed: true
        case .automatic: enabled && paired && connected
        }
    }

    /// A QR offer is wanted only while the section is expanded, Remote is on and running, no phone is
    /// paired, the Mac is unlocked and the pairing store loaded.
    public static func wantsOffer(collapsed: Bool, enabled: Bool, running: Bool, paired: Bool, locked: Bool, loadError: Bool) -> Bool {
        !collapsed && enabled && running && !paired && !locked && !loadError
    }

    public static func status(enabled: Bool, connected: Bool) -> PhoneSidebarStatus {
        guard enabled else { return .off }
        return connected ? .connected : .on
    }
}
