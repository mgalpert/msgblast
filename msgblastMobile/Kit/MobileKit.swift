import Foundation
import msgblastRemoteProtocol

/// The phone controller's logic (connection, store, view models) without UIKit, so it
/// builds and tests on macOS as well as iOS. The SwiftUI app lives in `msgblastMobile/`.
public enum MobileKit {
    public static let protocolVersion = RemoteProtocol.version
}
