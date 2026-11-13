import CryptoKit
import Foundation

/// HTTPS Amazon CDN hosts used for Alexa product photos. The page script uses the same allowlist.
public enum WebImageURL {
    public static func allowed(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme == "https", let host = url.host?.lowercased() else { return nil }
        let amazon = host == "m.media-amazon.com" || host == "images-na.ssl-images-amazon.com" || host.hasSuffix(".media-amazon.com")
        return amazon ? url : nil
    }
}

/// Downloads Alexa product images off the send path and remembers failures so a projection refresh does not retry immediately.
@MainActor
public final class WebImageCache {
    public static let maxByteCount = 2 * 1024 * 1024
    public var onChange: (@MainActor () -> Void)?
    private var files: [String: MessageAttachment] = [:]
    private var inflight: Set<String> = []
    private var failedAt: [String: Date] = [:]
    private let directory: URL
    private let session: URLSession
    private let redirects = WebImageRedirectGuard()
    private let maxBytes: Int
    private let retryAfter: TimeInterval
    private let now: () -> Date

    public init(directory: URL, session: URLSession? = nil, maxBytes: Int = WebImageCache.maxByteCount, retryAfter: TimeInterval = 180, now: @escaping () -> Date = Date.init, onChange: (@MainActor () -> Void)? = nil) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.retryAfter = retryAfter
        self.now = now
        self.onChange = onChange
        self.session = session ?? URLSession(configuration: Self.makeConfiguration(), delegate: redirects, delegateQueue: nil)
    }

    public static func makeConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return config
    }

    public func attachment(for url: String) -> MessageAttachment? { files[url] }

    public func attachments(for urls: [String]) -> [String: MessageAttachment] {
        var found: [String: MessageAttachment] = [:]
        for url in urls { if let file = files[url] { found[url] = file } }
        return found
    }

    /// Starts missing downloads and returns. Callers keep sending while files arrive.
    public func prefetch(_ urls: [String]) {
        for url in urls where shouldStart(url) {
            inflight.insert(url)
            Task { await download(url) }
        }
    }

    func isCoolingDown(_ url: String) -> Bool {
        guard let failed = failedAt[url] else { return false }
        return now().timeIntervalSince(failed) < retryAfter
    }

    private func shouldStart(_ url: String) -> Bool {
        if files[url] != nil || inflight.contains(url) || WebImageURL.allowed(url) == nil || isCoolingDown(url) { return false }
        return true
    }

    private func download(_ urlString: String) async {
        defer { inflight.remove(urlString) }
        guard let url = WebImageURL.allowed(urlString) else { failedAt[urlString] = now(); return }
        do {
            let image = try await fetched(url)
            files[urlString] = try store(image, urlString: urlString)
            failedAt[urlString] = nil
            onChange?()
        } catch {
            failedAt[urlString] = now()
        }
    }

    private func fetched(_ url: URL) async throws -> (data: Data, mime: String) {
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        guard let mime = Self.imageMIME(http) else { throw URLError(.cannotDecodeContentData) }
        guard http.expectedContentLength <= Int64(maxBytes) else { throw URLError(.dataLengthExceedsMaximum) }
        var data = Data()
        // Stop reading as soon as a response without a length passes the cap.
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes { throw URLError(.dataLengthExceedsMaximum) }
        }
        guard Self.withinLimit(http.expectedContentLength, count: data.count, max: maxBytes) else { throw URLError(.dataLengthExceedsMaximum) }
        return (data, mime)
    }

    private func store(_ image: (data: Data, mime: String), urlString: String) throws -> MessageAttachment {
        let digest = Self.digest(urlString)
        let ext = Self.fileExtension(image.mime)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent(digest + "." + ext)
        try image.data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return MessageAttachment(id: digest, filename: "product." + ext, path: destination.path, mimeType: image.mime, byteCount: Int64(image.data.count))
    }

    static func imageMIME(_ response: HTTPURLResponse) -> String? {
        guard let raw = response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first else { return nil }
        let mime = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return mime.hasPrefix("image/") ? mime : nil
    }

    static func withinLimit(_ expected: Int64, count: Int, max: Int) -> Bool {
        if expected > Int64(max) { return false }
        return count > 0 && count <= max
    }

    static func digest(_ url: String) -> String {
        SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func fileExtension(_ mime: String) -> String {
        switch mime {
        case "image/jpeg", "image/jpg": "jpg"
        case "image/png": "png"
        case "image/gif": "gif"
        case "image/webp": "webp"
        default: "img"
        }
    }
}

/// Drops a redirect that leaves the Amazon image allowlist. The redirect body is then rejected as a non-image.
final class WebImageRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        guard let raw = request.url?.absoluteString, WebImageURL.allowed(raw) != nil else { return nil }
        return request
    }
}
