import Foundation
import Combine

/// Account identity comes only from the API's verified bearer-token response.
/// ID tokens are not decoded or trusted as account identifiers. The API must
/// validate access-token issuer, audience, signature, and expiry before replying.
@MainActor public final class BenchmarkAccountSession: ObservableObject {
    @Published public private(set) var account: BenchmarkAccountIdentity?
    @Published public private(set) var deletionOnly = false
    @Published public private(set) var isWorking = false
    @Published public private(set) var errorMessage: String?
    public private(set) var generation: UInt64 = 0
    public let configuration: BenchmarkAccountConfiguration?
    private let browser: BenchmarkOAuthBrowser
    private let transport: BenchmarkHTTPTransport
    private let tokenStore: BenchmarkTokenStore
    private let now: () -> Date
    private var tokens: BenchmarkAccountTokens?
    // A rotated credential must be reverified/persisted before it can authorize
    // cloud actions; never exchange its already-consumed predecessor again.
    private var pendingTokens: BenchmarkAccountTokens?
    private var refreshTask: Task<BenchmarkAccountTokens, Error>?

    public init(configuration: BenchmarkAccountConfiguration?, browser: BenchmarkOAuthBrowser, transport: BenchmarkHTTPTransport, tokenStore: BenchmarkTokenStore, now: @escaping () -> Date = Date.init) {
        self.configuration = configuration; self.browser = browser; self.transport = transport
        self.tokenStore = tokenStore; self.now = now
    }
    public var isConfigured: Bool { configuration != nil }
    private func validateTransport(_ config: BenchmarkAccountConfiguration) throws {
        if config.demoFixture && transport is BenchmarkURLSessionTransport { throw BenchmarkAccountError.unconfigured }
    }
    private func check(_ expected: UInt64) throws {
        guard generation == expected, !Task.isCancelled else { throw BenchmarkAccountError.cancelled }
    }
    private func begin(preservePending: Bool = false) -> UInt64 {
        generation &+= 1; browser.cancel(); transport.cancelAll(); refreshTask?.cancel(); refreshTask = nil
        if !preservePending { pendingTokens = nil }
        deletionOnly = false
        account = nil; tokens = nil; errorMessage = nil; isWorking = true
        return generation
    }
    private func report(_ error: Error, generation expected: UInt64) {
        guard generation == expected else { return }
        if !recoverable(error) { account = nil; tokens = nil; pendingTokens = nil; deletionOnly = false }
        isWorking = false
        errorMessage = (error as? BenchmarkAccountError ?? .authenticationFailed).localizedDescription
    }
    private func recoverable(_ error: Error) -> Bool {
        if case BenchmarkAccountError.secureStorage = error { return true }
        return BenchmarkCloudRetry.isRetryable(error)
    }
    public func signIn() async {
        let expected = begin()
        do {
            guard let config = configuration else { throw BenchmarkAccountError.unconfigured }
            // A Demo client must inject a fixture browser and transport. The
            // system browser is never allowed to launch a live provider in Demo.
            if config.demoFixture && browser is BenchmarkOAuthSystemBrowser { throw BenchmarkAccountError.unconfigured }
            try validateTransport(config)
            let attempt = try BenchmarkOAuthAttempt(configuration: config)
            let callback = try await browser.authenticate(url: attempt.authorizationURL, callbackScheme: config.callbackURL.scheme!)
            try check(expected)
            let code = try attempt.authorizationCode(from: callback)
            let response = try await exchange(config, fields: ["grant_type": "authorization_code", "code": code, "code_verifier": attempt.verifier, "redirect_uri": config.callbackURL.absoluteString])
            try check(expected)
            let identity = try await verify(config, accessToken: response.accessToken)
            try check(expected)
            let saved = BenchmarkAccountTokens(accessToken: response.accessToken, refreshToken: response.refreshToken, expiresAt: now().addingTimeInterval(response.expiresIn), accountID: identity.accountID)
            try tokenStore.save(saved, scope: config.tokenScope)
            tokens = saved; account = identity; isWorking = false
        } catch { report(error, generation: expected) }
    }
    public func restore() async {
        let expected = begin(preservePending: true)
        do {
            guard let config = configuration else { isWorking = false; return }
            try validateTransport(config)
            guard let saved = try tokenStore.read(scope: config.tokenScope) else { isWorking = false; return }
            tokens = saved
            let restored = try await validTokens(config, expected: expected)
            let identity = try await verify(config, accessToken: restored.accessToken, expectedOwner: restored.accountID)
            try check(expected)
            guard identity.accountID == restored.accountID else { throw BenchmarkAccountError.accountMismatch }
            account = identity; isWorking = false
        } catch { report(error, generation: expected) }
    }
    /// Local revocation is immediate even if Keychain deletion fails. A visible
    /// failure asks the user to retry, and credentials never fall back to disk.
    public func signOut() {
        _ = begin(); isWorking = false
        guard let config = configuration else { return }
        do { try tokenStore.delete(scope: config.tokenScope) }
        catch { errorMessage = (error as? BenchmarkAccountError ?? .authenticationFailed).localizedDescription }
    }
    public func accessToken(accountID: String) async throws -> String {
        guard let config = configuration, account?.accountID == accountID else { throw BenchmarkAccountError.signedOut }
        guard !deletionOnly else { throw BenchmarkAccountError.http(410) }
        let expected = generation
        let saved = try await validTokens(config, expected: expected)
        try check(expected)
        guard saved.accountID == accountID else { throw BenchmarkAccountError.accountMismatch }
        guard !deletionOnly else { throw BenchmarkAccountError.http(410) }
        return saved.accessToken
    }
    /// Cloud clients use this entry point so sign-out also cancels their request
    /// and rejects an old response, including cancellation-insensitive fixtures.
    public func request(path: String, method: String = "GET", body: Data? = nil, accountID: String) async throws -> (Data, HTTPURLResponse) {
        guard let config = configuration, path.hasPrefix("/api/v1/"),
              !path.contains("?"), !path.contains("#"), !path.contains(".."), !path.contains("%"), !path.contains("\\") else { throw BenchmarkAccountError.invalidConfiguration }
        try validateTransport(config)
        let expected = generation
        guard account?.accountID == accountID else { throw BenchmarkAccountError.signedOut }
        guard !deletionOnly || (path == "/api/v1/account/deletion" && method == "GET") else { throw BenchmarkAccountError.http(410) }
        let saved = try await validTokens(config, expected: expected)
        try check(expected)
        guard saved.accountID == accountID else { throw BenchmarkAccountError.accountMismatch }
        guard !deletionOnly || (path == "/api/v1/account/deletion" && method == "GET") else { throw BenchmarkAccountError.http(410) }
        let token = saved.accessToken
        try check(expected)
        var request = URLRequest(url: config.serviceURL.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let result = try await transport.send(request)
        try check(expected)
        if result.1.statusCode == 429, result.0.count <= 4096,
           let body = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any],
           let code = body["error"] as? String,
           ["session_quota", "account_quota", "snapshot_quota", "publication_quota", "session_event_limit", "revision_limit", "chunk_conflict_or_quota"].contains(code) { throw BenchmarkAccountError.quota }
        if result.1.statusCode == 410, !deletionOnly {
            let identity = try await verify(config, accessToken: token, expectedOwner: accountID)
            try check(expected)
            guard identity.accountID == accountID else { throw BenchmarkAccountError.accountMismatch }
        }
        guard (200..<300).contains(result.1.statusCode) else { throw BenchmarkAccountError.http(result.1.statusCode) }
        if path == "/api/v1/account", method == "DELETE" { deletionOnly = true }
        return result
    }
    private func validTokens(_ config: BenchmarkAccountConfiguration, expected: UInt64) async throws -> BenchmarkAccountTokens {
        try check(expected)
        guard let saved = tokens else { throw BenchmarkAccountError.signedOut }
        if pendingTokens == nil, saved.expiresAt.timeIntervalSince(now()) > 30 { return saved }
        if let task = refreshTask { return try await task.value }
        let task = Task { @MainActor in
            let candidate: BenchmarkAccountTokens
            if let pending = self.pendingTokens, pending.expiresAt.timeIntervalSince(self.now()) > 30 {
                guard pending.accountID == saved.accountID else { throw BenchmarkAccountError.accountMismatch }
                candidate = pending
            } else {
                let predecessor = self.pendingTokens ?? saved
                guard predecessor.accountID == saved.accountID else { throw BenchmarkAccountError.accountMismatch }
                guard let refresh = predecessor.refreshToken else { throw BenchmarkAccountError.signedOut }
                let response = try await self.exchange(config, fields: ["grant_type": "refresh_token", "refresh_token": refresh])
                try self.check(expected)
                candidate = BenchmarkAccountTokens(accessToken: response.accessToken, refreshToken: response.refreshToken ?? refresh, expiresAt: self.now().addingTimeInterval(response.expiresIn), accountID: saved.accountID)
                self.pendingTokens = candidate
            }
            let identity = try await self.verify(config, accessToken: candidate.accessToken, expectedOwner: saved.accountID)
            try self.check(expected)
            guard identity.accountID == saved.accountID else { throw BenchmarkAccountError.accountMismatch }
            try self.tokenStore.save(candidate, scope: config.tokenScope)
            self.tokens = candidate; self.pendingTokens = nil
            return candidate
        }
        refreshTask = task
        defer { if generation == expected { refreshTask = nil } }
        do { return try await task.value }
        catch {
            if generation == expected {
                if !recoverable(error) { account = nil; tokens = nil; pendingTokens = nil; deletionOnly = false }
                errorMessage = (error as? BenchmarkAccountError ?? .authenticationFailed).localizedDescription
            }
            throw error
        }
    }
    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: TimeInterval
        let tokenType: String
        enum CodingKeys: String, CodingKey { case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in", tokenType = "token_type" }
    }
    private func exchange(_ config: BenchmarkAccountConfiguration, fields: [String: String]) async throws -> TokenResponse {
        var fields = fields; fields["client_id"] = config.clientID
        var form = URLComponents()
        form.queryItems = fields.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: config.tokenEndpoint)
        request.httpMethod = "POST"
        // URLComponents leaves literal '+' unescaped; form encoding must not.
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else { throw BenchmarkAccountError.http(response.statusCode) }
        guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data), !token.accessToken.isEmpty,
              !token.accessToken.contains(where: { $0.isNewline }), token.tokenType.lowercased() == "bearer",
              token.expiresIn.isFinite, token.expiresIn > 0 else { throw BenchmarkAccountError.invalidResponse }
        return token
    }
    private func verify(_ config: BenchmarkAccountConfiguration, accessToken: String, expectedOwner: String? = nil) async throws -> BenchmarkAccountIdentity {
        let verificationGeneration = generation
        var request = URLRequest(url: config.serviceURL.appendingPathComponent("api/v1/account"))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.send(request)
        try check(verificationGeneration)
        if response.statusCode == 410, let expectedOwner {
            var deletion = URLRequest(url: config.serviceURL.appendingPathComponent("api/v1/account/deletion"))
            deletion.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let (body, status) = try await transport.send(deletion)
            try check(verificationGeneration)
            guard status.statusCode == 200 else { throw BenchmarkAccountError.http(status.statusCode) }
            guard let value = try JSONSerialization.jsonObject(with: body) as? [String: Any], let owner = value["accountID"] as? String else { throw BenchmarkAccountError.invalidResponse }
            guard owner == expectedOwner else { throw BenchmarkAccountError.accountMismatch }
            deletionOnly = true
            return .init(accountID: owner, identity: "Account deletion pending")
        }
        guard response.statusCode == 200 else { throw BenchmarkAccountError.http(response.statusCode) }
        guard let identity = try? JSONDecoder().decode(BenchmarkAccountIdentity.self, from: data), !identity.accountID.isEmpty else { throw BenchmarkAccountError.invalidResponse }
        return identity
    }
}
