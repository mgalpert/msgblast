import XCTest
@testable import msgblastCore

final class BenchmarkOAuthTests: XCTestCase {
    func testPKCEUsesRFC7636S256Vector() {
        XCTAssertEqual(BenchmarkOAuthAttempt.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }
    func testCallbackRequiresExactRedirectStateAndSingleCode() throws {
        let config = try BenchmarkAccountConfiguration(serviceURL: URL(string: "https://api.example")!, issuer: URL(string: "https://login.example/")!, clientID: "native", audience: "benchmarks", callbackURL: URL(string: "com.example.dev:/benchmark-account")!, bundleIdentifier: "com.example.dev", profile: "dev")
        let attempt = try BenchmarkOAuthAttempt(configuration: config)
        XCTAssertThrowsError(try attempt.authorizationCode(from: URL(string: "com.example.dev:/benchmark-account?state=wrong&code=code")!))
        XCTAssertThrowsError(try attempt.authorizationCode(from: URL(string: "com.example.dev:/other?state=\(attempt.state)&code=code")!))
        XCTAssertThrowsError(try attempt.authorizationCode(from: URL(string: "com.example.dev:/benchmark-account?state=\(attempt.state)&code=a&code=b")!))
        XCTAssertThrowsError(try attempt.authorizationCode(from: URL(string: "com.example.dev:/benchmark-account?state=\(attempt.state)&code=code&iss=https%3A%2F%2Fevil.example%2F")!))
        XCTAssertThrowsError(try attempt.authorizationCode(from: URL(string: "com.example.dev:/benchmark-account?state=\(attempt.state)&code=code&error=access_denied")!))
        XCTAssertEqual(try attempt.authorizationCode(from: URL(string: "com.example.dev:/benchmark-account?state=\(attempt.state)&code=code")!), "code")
    }
    func testHTTPServiceRequiresExplicitDemoLoopback() throws {
        func config(_ url: String, demo: Bool) throws -> BenchmarkAccountConfiguration {
            try BenchmarkAccountConfiguration(serviceURL: URL(string: url)!, issuer: URL(string: "https://login.example/")!, clientID: "native", audience: "benchmarks", callbackURL: URL(string: "com.example:/callback")!, bundleIdentifier: "com.example", profile: "demo", demoFixture: demo)
        }
        XCTAssertThrowsError(try config("http://127.0.0.1:8787", demo: false))
        XCTAssertThrowsError(try config("http://api.example", demo: true))
        XCTAssertNoThrow(try config("http://127.0.0.1:8787", demo: true))
    }
}
