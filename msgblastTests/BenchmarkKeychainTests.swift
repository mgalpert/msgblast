import XCTest
@testable import msgblastCore

@MainActor final class BenchmarkKeychainTests: XCTestCase {
    func testEncryptedAdapterRoundTripRemovesSyntheticItem() throws {
        let scope = "com.msgblast.benchmark-keychain-test." + UUID().uuidString
        let store = BenchmarkKeychainTokenStore()
        defer { try? store.delete(scope: scope) }
        XCTAssertNil(try store.read(scope: scope))
        let synthetic = BenchmarkAccountTokens(accessToken: "synthetic-keychain-test-only", refreshToken: nil, expiresAt: .distantFuture, accountID: "synthetic-account")
        try store.save(synthetic, scope: scope)
        let restored = try XCTUnwrap(store.read(scope: scope))
        XCTAssertEqual(restored.accountID, synthetic.accountID)
        XCTAssertEqual(restored.accessToken, synthetic.accessToken)
        try store.delete(scope: scope)
        XCTAssertNil(try store.read(scope: scope))
    }
}
