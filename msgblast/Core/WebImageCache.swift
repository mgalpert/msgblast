import CryptoKit
import Foundation
import os

/// HTTPS Amazon CDN hosts used for Alexa product photos. The page script uses the same allowlist.
public enum WebImageURL {
    public static func allowed(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme == "https", let host = url.host?.lowercased() else { return nil }
        let amazon = host == "m.media-amazon.com" || host == "images-na.ssl-images-amazon.com" || host.hasSuffix(".media-amazon.com")
        return amazon ? url : nil
    }
}

/// Downloads Alexa product images off the send path and remembers failures so a projection refresh does not retry immediately.
/// Files on disk outlive a launch and are reused; old files and anything past the size budget are pruned.
@MainActor
public final class WebImageCache {
    public static let maxByteCount = 2 * 1024 * 1024
    public static let maxAge: TimeInterval = 30 * 24 * 60 * 60
    public static let maxDiskBytes = 200 * 1024 * 1024
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "msgblast", category: "WebImageCache")
    public var onChange: (@MainActor () -> Void)?
    private var files: [String: MessageAttachment] = [:]
    private var inflight: Set<String> = []
    private var failedAt: [String: Date] = [:]
    private let directory: URL
    private let session: URLSession
    private let redirects = WebImageRedirectGuard()
    private let maxBytes: Int
    private let retryAfter: TimeInterval
    private let maxAge: TimeInterval
    private let maxDiskBytes: Int
    private let now: () -> Date
    private var pruning: Task<Void, Never>?
    private var prunedOnce = false
    private var pruneAgain = false

    public init(directory: URL, session: URLSession? = nil, maxBytes: Int = WebImageCache.maxByteCount, retryAfter: TimeInterval = 180,
                maxAge: TimeInterval = WebImageCache.maxAge, maxDiskBytes: Int = WebImageCache.maxDiskBytes,
                now: @escaping () -> Date = Date.init, onChange: (@MainActor () -> Void)? = nil) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.retryAfter = retryAfter
        self.maxAge = maxAge
        self.maxDiskBytes = maxDiskBytes
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

    /// A file removed from disk is forgotten here, so the next prefetch fetches it again.
    public func attachment(for url: String) -> MessageAttachment? {
        guard let file = files[url] else { return nil }
        guard FileManager.default.fileExists(atPath: file.path) else { files[url] = nil; return nil }
        return file
    }

    public func attachments(for urls: [String]) -> [String: MessageAttachment] {
        var found: [String: MessageAttachment] = [:]
        for url in urls { if let file = attachment(for: url) { found[url] = file } }
        return found
    }

    /// Starts missing downloads and returns. Callers keep sending while files arrive.
    public func prefetch(_ urls: [String]) {
        if !prunedOnce { prunedOnce = true; prune() }
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
        if attachment(for: url) != nil || inflight.contains(url) || WebImageURL.allowed(url) == nil || isCoolingDown(url) { return false }
        return true
    }

    private func download(_ urlString: String) async {
        defer { inflight.remove(urlString) }
        guard let url = WebImageURL.allowed(urlString) else { failedAt[urlString] = now(); return }
        let digest = Self.digest(urlString), host = url.host ?? ""
        Self.log.info("Downloading \(host, privacy: .public) \(digest.prefix(8), privacy: .public)")
        do {
            // Network and disk work run off the main actor; only the bookkeeping below is isolated.
            // A file kept from an earlier launch is reused without a request.
            if let kept = await Self.storedFile(digest: digest, directory: directory, now: now()) {
                files[urlString] = kept
            } else {
                files[urlString] = try await Self.fetchAndStore(url, digest: digest, session: session, maxBytes: maxBytes, directory: directory)
                prune()
            }
            failedAt[urlString] = nil
            Self.log.info("Cached \(digest.prefix(8), privacy: .public)")
            onChange?()
        } catch {
            failedAt[urlString] = now()
            Self.log.error("Image \(digest.prefix(8), privacy: .public) failed: \((error as? URLError)?.code.rawValue ?? -1, privacy: .public)")
        }
    }

    /// Removes files older than the age limit, then the oldest files until the folder fits the size budget.
    /// Runs one pass at a time, off the main actor.
    func prune() {
        guard pruning == nil else { pruneAgain = true; return }
        let directory = directory, maxDiskBytes = maxDiskBytes, cutoff = now().addingTimeInterval(-maxAge)
        pruning = Task { [weak self] in
            let removed = await Task.detached(priority: .utility) { Self.pruneDirectory(directory, olderThan: cutoff, maxBytes: maxDiskBytes) }.value
            guard let self else { return }
            self.pruning = nil
            if !removed.isEmpty { self.files = self.files.filter { !removed.contains($0.value.path) } }
            // A file stored during the pass is counted by one more pass.
            if self.pruneAgain { self.pruneAgain = false; self.prune() }
        }
    }

    /// Waits until no prune pass is running. Tests use this.
    func waitForPrune() async {
        while let pass = pruning { await pass.value }
    }

    nonisolated static func pruneDirectory(_ directory: URL, olderThan cutoff: Date, maxBytes: Int) -> Set<String> {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var files: [(path: String, modified: Date, size: Int)] = []
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            // Paths are built the way stored files are, so they match the cache's own paths.
            files.append((directory.appendingPathComponent(entry.lastPathComponent).path, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0))
        }
        // Newest first: the newest files fit the budget, and everything after them goes.
        files.sort { $0.modified > $1.modified }
        var removed: Set<String> = [], total = 0
        for file in files {
            total += file.size
            guard file.modified < cutoff || total > maxBytes else { continue }
            if (try? FileManager.default.removeItem(atPath: file.path)) != nil { removed.insert(file.path) }
        }
        return removed
    }

    /// A file this cache stored before, with its use time refreshed so pruning keeps it.
    private nonisolated static func storedFile(digest: String, directory: URL, now: Date) async -> MessageAttachment? {
        for mime in ["image/jpeg", "image/png", "image/gif", "image/webp"] {
            guard let ext = fileExtension(mime) else { continue }
            let path = directory.appendingPathComponent(digest + "." + ext).path
            guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64, size > 0 else { continue }
            try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: path)
            return MessageAttachment(id: digest, filename: "product." + ext, path: path, mimeType: mime, byteCount: size)
        }
        return nil
    }

    private nonisolated static func fetchAndStore(_ url: URL, digest: String, session: URLSession, maxBytes: Int, directory: URL) async throws -> MessageAttachment {
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        guard let mime = imageMIME(http) else { throw URLError(.cannotDecodeContentData) }
        guard http.expectedContentLength <= Int64(maxBytes) else { throw URLError(.dataLengthExceedsMaximum) }
        var data = Data()
        data.reserveCapacity(Int(max(0, min(http.expectedContentLength, Int64(maxBytes)))))
        // Stop reading as soon as a response without a length passes the cap.
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes { throw URLError(.dataLengthExceedsMaximum) }
        }
        guard withinLimit(http.expectedContentLength, count: data.count, max: maxBytes) else { throw URLError(.dataLengthExceedsMaximum) }
        let ext = fileExtension(mime) ?? "jpg"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent(digest + "." + ext)
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return MessageAttachment(id: digest, filename: "product." + ext, path: destination.path, mimeType: mime, byteCount: Int64(data.count))
    }

    /// Only raster formats the phone decodes; SVG and anything else is refused.
    nonisolated static func imageMIME(_ response: HTTPURLResponse) -> String? {
        guard let raw = response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first else { return nil }
        let mime = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return fileExtension(mime) == nil ? nil : mime
    }

    nonisolated static func withinLimit(_ expected: Int64, count: Int, max: Int) -> Bool {
        if expected > Int64(max) { return false }
        return count > 0 && count <= max
    }

    nonisolated static func digest(_ url: String) -> String {
        SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func fileExtension(_ mime: String) -> String? {
        switch mime {
        case "image/jpeg", "image/jpg": "jpg"
        case "image/png": "png"
        case "image/gif": "gif"
        case "image/webp": "webp"
        default: nil
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
