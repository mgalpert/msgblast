import Foundation

public enum BenchmarkAccountError: Error, LocalizedError, Equatable {
    case unconfigured, invalidConfiguration, invalidCallback, cancelled, authenticationFailed, invalidResponse, signedOut, accountMismatch, secureStorage(Int32), http(Int), quota
    public var errorDescription: String? {
        switch self {
        case .quota: return "The cloud storage limit was reached. Sync is paused; delete cloud records before resuming."
        case .unconfigured: return "Benchmark accounts are not configured."
        case .invalidConfiguration: return "The benchmark account configuration is invalid."
        case .invalidCallback: return "The sign-in callback could not be verified."
        case .cancelled: return "Sign-in was canceled."
        case .authenticationFailed: return "Benchmark authentication failed."
        case .invalidResponse: return "The benchmark service returned an invalid response."
        case .signedOut: return "Sign in to use benchmark cloud actions."
        case .accountMismatch: return "The verified benchmark account changed. Sign in again."
        case .secureStorage: return "Benchmark credentials could not be accessed in Keychain."
        case .http(let status): return "The benchmark service returned HTTP \(status)."
        }
    }
}

/// Public provider values only. Provisioning the native PKCE client and API is a
/// deployment prerequisite; constructing this value does not contact either.
public struct BenchmarkAccountConfiguration: Sendable {
    public let serviceURL: URL
    public let issuer: URL
    public let clientID: String
    public let audience: String
    public let callbackURL: URL
    public let bundleIdentifier: String
    public let profile: String
    public let demoFixture: Bool
    public var authorizationEndpoint: URL { issuer.appendingPathComponent("authorize") }
    public var tokenEndpoint: URL { issuer.appendingPathComponent("oauth/token") }
    public var tokenScope: String {
        let realm = [bundleIdentifier, profile, serviceURL.absoluteString, issuer.absoluteString, clientID, audience, callbackURL.absoluteString]
        let digest = PerformanceCanonical.hash(try! JSONEncoder().encode(realm))
        return "com.msgblast.benchmark-session.\(digest)"
    }
    public init(serviceURL: URL, issuer: URL, clientID: String, audience: String, callbackURL: URL, bundleIdentifier: String, profile: String, demoFixture: Bool = false) throws {
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(serviceURL.host ?? "")
        guard (serviceURL.scheme == "https" || (demoFixture && loopback && serviceURL.scheme == "http")),
              serviceURL.host != nil, serviceURL.user == nil, serviceURL.password == nil,
              serviceURL.query == nil, serviceURL.fragment == nil, ["", "/"].contains(serviceURL.path),
              issuer.scheme == "https", issuer.host != nil, issuer.user == nil, issuer.password == nil,
              issuer.query == nil, issuer.fragment == nil, ["", "/"].contains(issuer.path),
              let callbackScheme = callbackURL.scheme, callbackScheme.contains("."),
              callbackScheme != "https", callbackScheme != "http", callbackURL.query == nil, callbackURL.fragment == nil,
              callbackURL.user == nil, callbackURL.password == nil,
              !clientID.isEmpty, !audience.isEmpty, !bundleIdentifier.isEmpty, !profile.isEmpty else {
            throw BenchmarkAccountError.invalidConfiguration
        }
        self.serviceURL = serviceURL; self.issuer = issuer; self.clientID = clientID
        self.audience = audience; self.callbackURL = callbackURL
        self.bundleIdentifier = bundleIdentifier; self.profile = profile; self.demoFixture = demoFixture
    }
}

public struct BenchmarkAccountIdentity: Codable, Equatable, Sendable {
    public let accountID: String
    public let identity: String
    public init(accountID: String, identity: String) { self.accountID = accountID; self.identity = identity }
}

public struct BenchmarkAccountTokens: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date
    public let accountID: String
    public init(accessToken: String, refreshToken: String?, expiresAt: Date, accountID: String) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt; self.accountID = accountID
    }
}
