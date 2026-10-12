import XCTest
import Foundation
@testable import msgblastCore

@MainActor final class BenchmarkAccountTests: XCTestCase {
    private func configuration(profile: String = "demo") throws -> BenchmarkAccountConfiguration {
        try BenchmarkAccountConfiguration(serviceURL: URL(string: "http://127.0.0.1:8787")!, issuer: URL(string: "https://tenant.example/")!, clientID: "fixture-native", audience: "benchmarks", callbackURL: URL(string: "com.example.demo:/account")!, bundleIdentifier: "com.example.demo", profile: profile, demoFixture: true)
    }
    func testRealCodeExchangeVerifiesAPIBearerBeforeSaving() async throws {
        let config = try configuration(), browser = FixtureBrowser(), http = FixtureHTTP(), store = FixtureStore()
        http.responses = [tokenResponse(), accountResponse("opaque-A")]
        let session = BenchmarkAccountSession(configuration: config, browser: browser, transport: http, tokenStore: store)
        await session.signIn()
        XCTAssertEqual(session.account?.accountID, "opaque-A")
        XCTAssertEqual(store.items[config.tokenScope]?.accountID, "opaque-A")
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertEqual(http.requests[0].url, URL(string: "https://tenant.example/oauth/token"))
        let body = String(decoding: try XCTUnwrap(http.requests[0].httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("code_verifier=")); XCTAssertTrue(body.contains("grant_type=authorization_code"))
        XCTAssertFalse(body.contains("client_secret"))
        XCTAssertEqual(http.requests[1].url?.path, "/api/v1/account")
        XCTAssertEqual(http.requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer fixture-access")
        let items = URLComponents(url: try XCTUnwrap(browser.openedURL), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.first(where: { $0.name == "code_challenge_method" })?.value, "S256")
        XCTAssertTrue(items?.first(where: { $0.name == "scope" })?.value?.contains("benchmarks:write") == true)
        // Merely signing in sends no session data and opts into no sync.
        XCTAssertEqual(http.requests.map { $0.httpMethod ?? "GET" }, ["POST", "GET"])
    }
    func testWrongCallbackNeverExchangesOrStoresCredentials() async throws {
        let browser = FixtureBrowser(); browser.wrongState = true
        let http = FixtureHTTP(), store = FixtureStore()
        let session = BenchmarkAccountSession(configuration: try configuration(), browser: browser, transport: http, tokenStore: store)
        await session.signIn()
        XCTAssertNil(session.account); XCTAssertNotNil(session.errorMessage)
        XCTAssertTrue(http.requests.isEmpty); XCTAssertTrue(store.items.isEmpty)
    }
    func testSignOutRejectsLateBrowserCompletion() async throws {
        let browser = FixtureBrowser(); browser.hold = true
        let http = FixtureHTTP(), store = FixtureStore()
        let session = BenchmarkAccountSession(configuration: try configuration(), browser: browser, transport: http, tokenStore: store)
        let task = Task { await session.signIn() }
        while browser.pending == nil { await Task.yield() }
        session.signOut()
        browser.complete()
        await task.value
        XCTAssertNil(session.account); XCTAssertTrue(store.items.isEmpty); XCTAssertTrue(http.requests.isEmpty)
    }
    func testKeychainFailureIsVisibleAndDoesNotActivateAccount() async throws {
        let store = FixtureStore(); store.failSave = true
        let http = FixtureHTTP(); http.responses = [tokenResponse(), accountResponse("opaque-A")]
        let session = BenchmarkAccountSession(configuration: try configuration(), browser: FixtureBrowser(), transport: http, tokenStore: store)
        await session.signIn()
        XCTAssertNil(session.account); XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(session.errorMessage, "Benchmark credentials could not be accessed in Keychain.")
    }
    func testExpiredRestoreRefreshesAndRejectsChangedVerifiedAccount() async throws {
        let config = try configuration(), http = FixtureHTTP(), store = FixtureStore()
        store.items[config.tokenScope] = BenchmarkAccountTokens(accessToken: "expired", refreshToken: "refresh+A", expiresAt: .distantPast, accountID: "opaque-A")
        http.responses = [tokenResponse(), accountResponse("opaque-B")]
        let session = BenchmarkAccountSession(configuration: config, browser: FixtureBrowser(), transport: http, tokenStore: store)
        await session.restore()
        XCTAssertNil(session.account)
        XCTAssertEqual(store.items[config.tokenScope]?.accountID, "opaque-A")
        let body = String(decoding: try XCTUnwrap(http.requests.first?.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("grant_type=refresh_token")); XCTAssertTrue(body.contains("refresh_token=refresh%2BA"))
        XCTAssertEqual(session.errorMessage, "The verified benchmark account changed. Sign in again.")
    }
    func testRestoreAndCloudRequestAreAccountBoundAndLateResponseIsRejected() async throws {
        let config = try configuration(), http = FixtureHTTP(), store = FixtureStore()
        store.items[config.tokenScope] = BenchmarkAccountTokens(accessToken: "saved", refreshToken: nil, expiresAt: .distantFuture, accountID: "opaque-A")
        http.responses = [accountResponse("opaque-A")]
        let session = BenchmarkAccountSession(configuration: config, browser: FixtureBrowser(), transport: http, tokenStore: store)
        await session.restore()
        XCTAssertEqual(session.account?.accountID, "opaque-A")
        do { _ = try await session.request(path: "/api/v1/sessions", accountID: "opaque-B"); XCTFail("Wrong account cannot transmit") } catch {}
        XCTAssertEqual(http.requests.count, 1)
        http.hold = true
        let task = Task { try await session.request(path: "/api/v1/sessions", method: "POST", body: Data("fixture".utf8), accountID: "opaque-A") }
        while http.pending == nil { await Task.yield() }
        session.signOut(); http.complete()
        do { _ = try await task.value; XCTFail("Late request must remain canceled") } catch {}
        XCTAssertTrue(store.items.isEmpty); XCTAssertNil(session.account)
        XCTAssertEqual(http.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer saved")
    }
    func testTokenScopesSeparateVariantsProfilesAndRealms() throws {
        let first = try configuration(), second = try configuration(profile: "isolated-two")
        XCTAssertNotEqual(first.tokenScope, second.tokenScope)
        let other = try BenchmarkAccountConfiguration(serviceURL: URL(string: "https://other.example")!, issuer: first.issuer, clientID: first.clientID, audience: first.audience, callbackURL: first.callbackURL, bundleIdentifier: "com.example.production", profile: first.profile)
        XCTAssertNotEqual(first.tokenScope, other.tokenScope)
    }
    func testDemoCannotUseLiveBrowserOrNetworkTransport() async throws {
        let config = try configuration(), store = FixtureStore()
        let session = BenchmarkAccountSession(configuration: config, browser: FixtureBrowser(), transport: BenchmarkURLSessionTransport(), tokenStore: store)
        await session.signIn()
        XCTAssertNil(session.account)
        XCTAssertEqual(session.errorMessage, "Benchmark accounts are not configured.")
        XCTAssertTrue(store.items.isEmpty)
    }
    func testSuccessfulRefreshPersistsRotatedTokenAndRestoresVerifiedIdentity() async throws {
        let config = try configuration(), http = FixtureHTTP(), store = FixtureStore()
        store.items[config.tokenScope] = BenchmarkAccountTokens(accessToken: "expired", refreshToken: "old-refresh", expiresAt: .distantPast, accountID: "opaque-A")
        http.responses = [tokenResponse(), accountResponse("opaque-A"), accountResponse("opaque-A")]
        let session = BenchmarkAccountSession(configuration: config, browser: FixtureBrowser(), transport: http, tokenStore: store)
        await session.restore()
        XCTAssertEqual(session.account?.accountID, "opaque-A")
        XCTAssertEqual(store.items[config.tokenScope]?.refreshToken, "fixture-refresh")
        let token = try await session.accessToken(accountID: "opaque-A")
        XCTAssertEqual(token, "fixture-access")
        XCTAssertEqual(http.requests.count, 3)
    }
    func testTransientRefreshRetainsVerifiedOwnerAndRecovers() async throws {
        let config = try configuration(), http = FixtureHTTP(), store = FixtureStore()
        var clock = Date()
        store.items[config.tokenScope] = .init(accessToken: "saved", refreshToken: "old-refresh", expiresAt: clock.addingTimeInterval(60), accountID: "opaque-A")
        http.responses = [accountResponse("opaque-A")]
        let session = BenchmarkAccountSession(configuration: config, browser: FixtureBrowser(), transport: http, tokenStore: store, now: { clock })
        await session.restore(); clock = clock.addingTimeInterval(120)
        http.responses = [Data()]; http.statuses = [503]
        do { _ = try await session.accessToken(accountID: "opaque-A"); XCTFail("Refresh outage") } catch { XCTAssertEqual(error as? BenchmarkAccountError, .http(503)) }
        XCTAssertEqual(session.account?.accountID, "opaque-A")
        http.responses = [tokenResponse(), accountResponse("opaque-A")]
        let recovered = try await session.accessToken(accountID: "opaque-A")
        XCTAssertEqual(recovered, "fixture-access")
    }
    func testRotatedTokenVerificationOutageDoesNotReuseConsumedRefreshToken() async throws {
        let config = try configuration(), http = FixtureHTTP(), store = FixtureStore()
        var clock = Date()
        store.items[config.tokenScope] = .init(accessToken: "saved", refreshToken: "old-refresh", expiresAt: clock.addingTimeInterval(60), accountID: "opaque-A")
        http.responses = [accountResponse("opaque-A")]
        let session = BenchmarkAccountSession(configuration: config, browser: FixtureBrowser(), transport: http, tokenStore: store, now: { clock })
        await session.restore(); clock = clock.addingTimeInterval(120)
        http.responses = [tokenResponse(), Data()]; http.statuses = [200, 503]
        do { _ = try await session.accessToken(accountID: "opaque-A"); XCTFail("Verification outage") } catch {}
        XCTAssertEqual(session.account?.accountID, "opaque-A")
        XCTAssertEqual(store.items[config.tokenScope]?.accessToken, "saved", "Unverified candidate must not be persisted")
        http.responses = [accountResponse("opaque-A")]
        let recovered = try await session.accessToken(accountID: "opaque-A")
        XCTAssertEqual(recovered, "fixture-access")
        XCTAssertEqual(http.requests.filter { $0.url?.path == "/oauth/token" }.count, 1)
        XCTAssertEqual(store.items[config.tokenScope]?.refreshToken, "fixture-refresh")
    }
    func testDeletedAccountRestoresOnlySameOwnerPollingAndRefreshesExpiredCredential() async throws {
        let config = try configuration(), http = FixtureHTTP(), store = FixtureStore()
        var clock = Date()
        store.items[config.tokenScope] = .init(accessToken: "saved", refreshToken: "old", expiresAt: clock.addingTimeInterval(60), accountID: "opaque-A")
        let deletion = Data(#"{"accountID":"opaque-A","deletion":{"blocked_reason":"idp_unconfigured"}}"#.utf8)
        http.responses = [Data(), deletion]; http.statuses = [410, 200]
        let session = BenchmarkAccountSession(configuration: config, browser: FixtureBrowser(), transport: http, tokenStore: store, now: { clock })
        await session.restore()
        XCTAssertEqual(session.account?.accountID, "opaque-A"); XCTAssertTrue(session.deletionOnly)
        let count = http.requests.count
        do { _ = try await session.request(path: "/api/v1/sessions", accountID: "opaque-A"); XCTFail("Restricted session") } catch { XCTAssertEqual(error as? BenchmarkAccountError, .http(410)) }
        do { _ = try await session.request(path: "/api/v1/account/deletion", method: "POST", accountID: "opaque-A"); XCTFail("Read-only polling") } catch {}
        do { _ = try await session.request(path: "/api/v1/account/deletion", accountID: "opaque-B"); XCTFail("Wrong owner") } catch {}
        XCTAssertEqual(http.requests.count, count)
        clock = clock.addingTimeInterval(120)
        http.responses = [tokenResponse(), Data(), deletion, deletion]; http.statuses = [200, 410, 200, 200]
        _ = try await session.request(path: "/api/v1/account/deletion", accountID: "opaque-A")
        XCTAssertTrue(session.deletionOnly); XCTAssertEqual(store.items[config.tokenScope]?.refreshToken, "fixture-refresh")
        let second = BenchmarkAccountSession(configuration: config, browser: FixtureBrowser(), transport: http, tokenStore: store)
        http.responses = [Data(), Data(#"{"accountID":"opaque-B"}"#.utf8)]; http.statuses = [410, 200]
        await second.restore(); XCTAssertNil(second.account); XCTAssertFalse(second.deletionOnly)
    }
    func testRefreshOfflineAndRotatedStorageFailureRetainRecoveryWithoutCloudTransmission() async throws {
        let config = try configuration(), http = FixtureHTTP(), store = FixtureStore()
        var clock = Date()
        store.items[config.tokenScope] = .init(accessToken: "saved", refreshToken: "old", expiresAt: clock.addingTimeInterval(60), accountID: "opaque-A")
        http.responses = [accountResponse("opaque-A")]
        let session = BenchmarkAccountSession(configuration: config, browser: FixtureBrowser(), transport: http, tokenStore: store, now: { clock })
        await session.restore(); clock = clock.addingTimeInterval(120); http.failure = URLError(.notConnectedToInternet)
        do { _ = try await session.accessToken(accountID: "opaque-A"); XCTFail("Offline") } catch {}
        XCTAssertEqual(session.account?.accountID, "opaque-A"); http.failure = nil
        store.failSave = true; http.responses = [tokenResponse(), accountResponse("opaque-A")]
        do { _ = try await session.request(path: "/api/v1/sessions", accountID: "opaque-A"); XCTFail("Storage failed") } catch {}
        XCTAssertFalse(http.requests.contains { $0.url?.path == "/api/v1/sessions" })
        store.failSave = false; http.responses = [accountResponse("opaque-A")]
        _ = try await session.accessToken(accountID: "opaque-A")
        XCTAssertEqual(http.requests.filter { $0.url?.path == "/oauth/token" }.count, 2, "One failed offline exchange, one successful rotation")
    }
    func testLateDeletionVerificationCannotRestrictNextAccount() async throws {
        let config = try configuration(), http = FixtureHTTP(), store = FixtureStore()
        store.items[config.tokenScope] = .init(accessToken: "saved-A", refreshToken: nil, expiresAt: .distantFuture, accountID: "opaque-A")
        http.responses = [Data()]; http.statuses = [410]; http.holdPath = "/api/v1/account/deletion"
        let session = BenchmarkAccountSession(configuration: config, browser: FixtureBrowser(), transport: http, tokenStore: store)
        let restore = Task { await session.restore() }
        while http.pending == nil { await Task.yield() }
        session.signOut(); http.holdPath = nil
        http.responses = [tokenResponse(), accountResponse("opaque-B")]; http.statuses = []
        await session.signIn(); http.complete(data: Data(#"{"accountID":"opaque-A","deletion":{"blocked_reason":"idp_unconfigured"}}"#.utf8)); await restore.value
        XCTAssertEqual(session.account?.accountID, "opaque-B"); XCTAssertFalse(session.deletionOnly)
    }
    func testExpiredUnverifiedRotationRefreshesOnlyItsNewRefreshCredential() async throws {
        let config = try configuration(), http = FixtureHTTP(), store = FixtureStore()
        var clock = Date()
        store.items[config.tokenScope] = .init(accessToken: "saved", refreshToken: "consumed-old", expiresAt: clock.addingTimeInterval(60), accountID: "opaque-A")
        http.responses = [accountResponse("opaque-A")]
        let session = BenchmarkAccountSession(configuration: config, browser: FixtureBrowser(), transport: http, tokenStore: store, now: { clock })
        await session.restore(); clock = clock.addingTimeInterval(120)
        http.responses = [tokenResponse(), Data()]; http.statuses = [200, 503]
        do { _ = try await session.accessToken(accountID: "opaque-A"); XCTFail("Verification outage") } catch {}
        clock = clock.addingTimeInterval(4000)
        http.responses = [tokenResponse(), accountResponse("opaque-A")]
        _ = try await session.accessToken(accountID: "opaque-A")
        let exchanges = http.requests.filter { $0.url?.path == "/oauth/token" }
        XCTAssertEqual(exchanges.count, 2)
        XCTAssertTrue(String(decoding: exchanges[0].httpBody!, as: UTF8.self).contains("refresh_token=consumed-old"))
        XCTAssertTrue(String(decoding: exchanges[1].httpBody!, as: UTF8.self).contains("refresh_token=fixture-refresh"))
        XCTAssertEqual(session.account?.accountID, "opaque-A")
    }
    private func tokenResponse() -> Data { Data(#"{"access_token":"fixture-access","refresh_token":"fixture-refresh","expires_in":3600,"token_type":"Bearer","id_token":"untrusted-and-unused"}"#.utf8) }
    private func accountResponse(_ id: String) -> Data { Data("{\"accountID\":\"\(id)\",\"identity\":\"Fixture user\"}".utf8) }
}

@MainActor private final class FixtureBrowser: BenchmarkOAuthBrowser {
    var openedURL: URL?
    var wrongState = false
    var hold = false
    var pending: CheckedContinuation<URL, Error>?
    private var callback: URL?
    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        openedURL = url
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let redirect = items.first(where: { $0.name == "redirect_uri" })!.value!
        let state = wrongState ? "wrong" : items.first(where: { $0.name == "state" })!.value!
        callback = URL(string: "\(redirect)?state=\(state)&code=fixture-code")!
        if hold { return try await withCheckedThrowingContinuation { pending = $0 } }
        return callback!
    }
    func cancel() {} // Deliberately ignores cancellation to prove generation guard.
    func complete() { let old = pending; pending = nil; old?.resume(returning: callback!) }
}
@MainActor private final class FixtureHTTP: BenchmarkHTTPTransport {
    var requests: [URLRequest] = []
    var responses: [Data] = []
    var hold = false
    var holdPath: String?
    var statuses: [Int] = []
    var failure: Error?
    var pending: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    var pendingRequest: URLRequest?
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let failure { throw failure }
        if hold || request.url?.path == holdPath { pendingRequest = request; return try await withCheckedThrowingContinuation { pending = $0 } }
        guard !responses.isEmpty else { throw BenchmarkAccountError.invalidResponse }
        return (responses.removeFirst(), HTTPURLResponse(url: request.url!, statusCode: statuses.isEmpty ? 200 : statuses.removeFirst(), httpVersion: nil, headerFields: nil)!)
    }
    func cancelAll() {} // Simulates a transport completion racing cancellation.
    func complete(data: Data = Data()) { let old = pending, request = pendingRequest!; pending = nil; pendingRequest = nil; old?.resume(returning: (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)) }
}
@MainActor private final class FixtureStore: BenchmarkTokenStore {
    var items: [String: BenchmarkAccountTokens] = [:]
    var failSave = false
    func read(scope: String) throws -> BenchmarkAccountTokens? { items[scope] }
    func save(_ tokens: BenchmarkAccountTokens, scope: String) throws {
        if failSave { throw BenchmarkAccountError.secureStorage(-25308) }
        items[scope] = tokens
    }
    func delete(scope: String) throws { items.removeValue(forKey: scope) }
}
