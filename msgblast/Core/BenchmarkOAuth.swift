import Foundation
import CryptoKit
import Security

public struct BenchmarkOAuthAttempt: Sendable {
    public let state: String
    public let verifier: String
    public let configuration: BenchmarkAccountConfiguration
    public init(configuration: BenchmarkAccountConfiguration) throws {
        self.configuration = configuration
        state = try Self.random(); verifier = try Self.random()
    }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw BenchmarkAccountError.authenticationFailed
        }
        return base64URL(Data(bytes))
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func challenge(for verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    public var authorizationURL: URL {
        var components = URLComponents(url: configuration.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.callbackURL.absoluteString),
            URLQueryItem(name: "scope", value: "openid profile offline_access benchmarks:write"), URLQueryItem(name: "audience", value: configuration.audience),
            URLQueryItem(name: "state", value: state), URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        return components.url!
    }
    public func authorizationCode(from callback: URL) throws -> String {
        guard var components = URLComponents(url: callback, resolvingAgainstBaseURL: false), components.fragment == nil else { throw BenchmarkAccountError.invalidCallback }
        let items = components.queryItems ?? []; components.query = nil
        guard components.url == configuration.callbackURL,
              items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == state,
              !items.contains(where: { $0.name == "error" }),
              items.filter({ $0.name == "iss" }).count <= 1,
              items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw BenchmarkAccountError.invalidCallback }
        if let issuer = items.first(where: { $0.name == "iss" })?.value, issuer != configuration.issuer.absoluteString { throw BenchmarkAccountError.invalidCallback }
        return code
    }
}

@MainActor public protocol BenchmarkOAuthBrowser: AnyObject {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
    func cancel()
}
