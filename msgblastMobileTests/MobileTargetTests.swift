import XCTest
import msgblastRemoteProtocol
@testable import msgblastMobileKit

final class MobileTargetTests: XCTestCase {
    func testLinksTheSharedProtocol() { XCTAssertEqual(MobileKit.protocolVersion, RemoteProtocol.version) }
}
