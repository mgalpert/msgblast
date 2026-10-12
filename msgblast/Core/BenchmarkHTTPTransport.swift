import Foundation

@MainActor public protocol BenchmarkHTTPTransport: AnyObject {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func cancelAll()
}

/// Dedicated ephemeral session: never reuses agent cookies, credentials, or cache.
@MainActor public final class BenchmarkURLSessionTransport: NSObject, BenchmarkHTTPTransport, URLSessionTaskDelegate {
    private var session: URLSession!
    public override init() {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil; config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw BenchmarkAccountError.invalidResponse }
        return (data, response)
    }
    public func cancelAll() {
        session.invalidateAndCancel()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil; config.urlCache = nil
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }
    // Do not forward bearer credentials or authorization codes across redirects.
    nonisolated public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
