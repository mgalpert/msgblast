import Foundation
import msgblastRemoteProtocol

/// The phone controller's logic (connection, store, view models) without UIKit, so it
/// builds and tests on macOS as well as iOS. The SwiftUI app lives in `msgblastMobile/`.
public enum MobileKit {
    public static let protocolVersion = RemoteProtocol.version
}

/// Where a pairing code came from.
public enum PairingCodeSource: Equatable, Sendable {
    case scanner, paste, incomingLink

    /// True only for a camera scan. The QR carries identityKeySHA256 and the handshake pins it,
    /// so a scan of the Mac's own code cannot pair a different Mac. Paste and an incoming link can be substituted, so they wait for Pair.
    public static func pairsImmediately(_ source: Self) -> Bool { source == .scanner }
}
