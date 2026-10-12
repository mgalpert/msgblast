import Foundation
import msgblastCore

/// Explicit isolated Demo only. OAuth UI/code exchange are simulated; account
/// verification and all cloud operations still use the actual loopback Worker.
@MainActor struct BenchmarkDemoFixture {
    let configuration: BenchmarkAccountConfiguration
    let browser: BenchmarkOAuthBrowser
    let transport: BenchmarkHTTPTransport
    let tokens: BenchmarkTokenStore
    static func directory(demo: Bool, arguments: [String] = ProcessInfo.processInfo.arguments) throws -> URL? {
        guard demo, arguments.contains("--isolated-demo"),
              let flag = arguments.firstIndex(of: "--benchmark-fixture"), flag + 1 < arguments.count else { return nil }
        let directory = URL(fileURLWithPath: arguments[flag + 1]).resolvingSymlinksInPath().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard directory.path.hasPrefix(temporary) else { throw BenchmarkAccountError.invalidConfiguration }
        return directory
    }
    static func load(demo: Bool, arguments: [String] = ProcessInfo.processInfo.arguments) throws -> Self? {
        guard let directory = try directory(demo: demo, arguments: arguments) else { return nil }
        struct Input: Decodable { let serviceURL: URL; let accessToken: String }
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: directory.appendingPathComponent("benchmark-fixture.json")))
        let config = try BenchmarkAccountConfiguration(serviceURL: input.serviceURL, issuer: URL(string: "https://fixture-issuer.invalid/")!, clientID: "synthetic-demo", audience: "benchmark-fixture", callbackURL: URL(string: "com.msgblast.demo:/benchmark")!, bundleIdentifier: "com.msgblast.demo", profile: directory.lastPathComponent, demoFixture: true)
        guard input.serviceURL.scheme == "http", ["127.0.0.1", "localhost", "[::1]"].contains(input.serviceURL.host ?? ""), !input.accessToken.isEmpty else { throw BenchmarkAccountError.invalidConfiguration }
        return .init(configuration: config, browser: DemoBrowser(), transport: DemoTransport(configuration: config, bearer: input.accessToken), tokens: DemoTokens())
    }
    private final class DemoBrowser: BenchmarkOAuthBrowser {
        func authenticate(url: URL, callbackScheme: String) async throws -> URL {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let state = query.first(where: { $0.name == "state" })?.value,
                  let redirect = query.first(where: { $0.name == "redirect_uri" })?.value,
                  var callback = URLComponents(string: redirect) else { throw BenchmarkAccountError.invalidCallback }
            callback.queryItems = [.init(name: "state", value: state), .init(name: "code", value: "synthetic-code")]
            return callback.url!
        }
        func cancel() {}
    }
    private final class DemoTokens: BenchmarkTokenStore {
        var items: [String: BenchmarkAccountTokens] = [:]
        func read(scope: String) throws -> BenchmarkAccountTokens? { items[scope] }
        func save(_ tokens: BenchmarkAccountTokens, scope: String) throws { items[scope] = tokens }
        func delete(scope: String) throws { items[scope] = nil }
    }
    private final class DemoTransport: BenchmarkHTTPTransport {
        let configuration: BenchmarkAccountConfiguration
        let bearer: String
        let loopback = BenchmarkURLSessionTransport()
        init(configuration: BenchmarkAccountConfiguration, bearer: String) { self.configuration = configuration; self.bearer = bearer }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            guard let url = request.url else { throw BenchmarkAccountError.invalidConfiguration }
            if url == configuration.tokenEndpoint {
                let data = try JSONSerialization.data(withJSONObject: ["access_token": bearer, "token_type": "Bearer", "expires_in": 3600])
                return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            guard url.scheme == "http", url.host == configuration.serviceURL.host, url.port == configuration.serviceURL.port, url.path.hasPrefix("/api/v1/") else { throw BenchmarkAccountError.invalidConfiguration }
            return try await loopback.send(request)
        }
        func cancelAll() { loopback.cancelAll() }
    }
}
