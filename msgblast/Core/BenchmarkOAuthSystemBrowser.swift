import AppKit
import AuthenticationServices

/// AuthenticationServices isolates provider cookies from the app's agent web views.
@MainActor public final class BenchmarkOAuthSystemBrowser: NSObject, BenchmarkOAuthBrowser, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var generation = UUID()
    private let window: () -> NSWindow
    public init(window: @escaping () -> NSWindow) { self.window = window; super.init() }
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { window() }
    public func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        cancel()
        let expected = generation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] url, _ in
                    Task { @MainActor in guard let self, self.generation == expected else { return }; self.finish(url: url) }
                }
                self.session = session
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = true
                if !session.start() { finish(url: nil) }
            }
        } onCancel: { Task { @MainActor in if self.generation == expected { self.cancel() } } }
    }
    private func finish(url: URL?) {
        let pending = continuation; continuation = nil; session = nil
        if let url { pending?.resume(returning: url) }
        else { pending?.resume(throwing: BenchmarkAccountError.cancelled) }
    }
    public func cancel() {
        generation = UUID()
        let old = session; session = nil
        let pending = continuation; continuation = nil
        old?.cancel(); pending?.resume(throwing: BenchmarkAccountError.cancelled)
    }
}
