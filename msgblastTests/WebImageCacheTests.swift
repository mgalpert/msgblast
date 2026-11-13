import XCTest
import msgblastRemoteProtocol
@testable import msgblastCore

@MainActor
final class WebImageCacheTests: XCTestCase {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-images-\(UUID().uuidString)", isDirectory: true)
    }

    private func cache(in directory: URL, maxBytes: Int = 32, retryAfter: TimeInterval = 180, now: @escaping () -> Date = Date.init) -> WebImageCache {
        let config = WebImageCache.makeConfiguration()
        config.protocolClasses = [WebImageProtocol.self]
        return WebImageCache(directory: directory, session: URLSession(configuration: config), maxBytes: maxBytes, retryAfter: retryAfter, now: now)
    }

    private func settle(_ ready: @MainActor () -> Bool) async {
        for _ in 0..<50 where !ready() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    func testConfigurationDisablesCookiesAndLimitsSize() {
        let config = WebImageCache.makeConfiguration()
        XCTAssertFalse(config.httpShouldSetCookies)
        XCTAssertEqual(config.httpCookieAcceptPolicy, .never)
        XCTAssertEqual(config.timeoutIntervalForRequest, 15)
        XCTAssertNil(config.urlCache)
        XCTAssertEqual(WebImageCache.maxByteCount, 2 * 1024 * 1024)
        XCTAssertFalse(WebImageCache.withinLimit(Int64(WebImageCache.maxByteCount + 1), count: 1, max: WebImageCache.maxByteCount))
        XCTAssertFalse(WebImageCache.withinLimit(-1, count: WebImageCache.maxByteCount + 1, max: WebImageCache.maxByteCount))
        XCTAssertTrue(WebImageCache.withinLimit(-1, count: 4, max: WebImageCache.maxByteCount))
    }

    func testRejectsNonAmazonHostsAndInsecureURLs() async {
        WebImageProtocol.reset()
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let images = cache(in: directory)
        let blocked = ["http://m.media-amazon.com/images/I/plain.jpg", "https://evil.example.com/x.jpg", "https://notmedia-amazon.com/x.jpg"]
        for url in blocked { XCTAssertNil(WebImageURL.allowed(url)) }
        XCTAssertNotNil(WebImageURL.allowed("https://m.media-amazon.com/images/I/test.jpg"))
        XCTAssertNotNil(WebImageURL.allowed("https://images-na.ssl-images-amazon.com/images/I/listed.jpg"))
        XCTAssertNotNil(WebImageURL.allowed("https://images.media-amazon.com/images/I/suffix.jpg"))
        images.prefetch(blocked)
        try? await Task.sleep(for: .milliseconds(50))
        for url in blocked { XCTAssertEqual(WebImageProtocol.hitCount(url), 0) }
        XCTAssertTrue(images.attachments(for: blocked).isEmpty)
    }

    func testRejectsNonImageAndOversizedPayloads() async {
        WebImageProtocol.reset()
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let html = "https://m.media-amazon.com/images/I/page.jpg"
        let huge = "https://m.media-amazon.com/images/I/huge.jpg"
        let header = "https://m.media-amazon.com/images/I/header.jpg"
        WebImageProtocol.replies[html] = WebImageProtocol.Reply(mime: "text/html", body: Data("nope".utf8))
        WebImageProtocol.replies[huge] = WebImageProtocol.Reply(body: Data(repeating: 1, count: 9))
        WebImageProtocol.replies[header] = WebImageProtocol.Reply(body: Data([1, 2, 3, 4]), contentLength: "9")
        let images = cache(in: directory, maxBytes: 8)
        images.prefetch([html, huge, header])
        await settle { images.isCoolingDown(html) && images.isCoolingDown(huge) && images.isCoolingDown(header) }
        XCTAssertTrue(images.attachments(for: [html, huge, header]).isEmpty)
        let stored = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        XCTAssertEqual(stored.count, 0)
    }

    func testCachesAValidImageByURLHash() async throws {
        WebImageProtocol.reset()
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = "https://m.media-amazon.com/images/I/cached.jpg"
        WebImageProtocol.replies[url] = WebImageProtocol.Reply(mime: "image/jpeg", body: Data([0xFF, 0xD8, 0xFF, 0xD9]))
        let images = cache(in: directory)
        images.prefetch([url, url])
        await settle { images.attachment(for: url) != nil }
        let file = try XCTUnwrap(images.attachment(for: url))
        let digest = WebImageCache.digest(url)
        XCTAssertEqual(file.id, digest)
        XCTAssertEqual(file.filename, "product.jpg")
        XCTAssertEqual(file.mimeType, "image/jpeg")
        XCTAssertEqual(file.byteCount, 4)
        XCTAssertEqual(file.path, directory.appendingPathComponent(digest + ".jpg").path)
        let stored = try Data(contentsOf: URL(fileURLWithPath: file.path))
        XCTAssertEqual(stored, Data([0xFF, 0xD8, 0xFF, 0xD9]))
        XCTAssertEqual(WebImageProtocol.hitCount(url), 1, "An in-flight duplicate and a cached URL do not download again")
        images.prefetch([url])
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(WebImageProtocol.hitCount(url), 1)
    }

    func testAFailedDownloadIsNotRetriedImmediately() async {
        WebImageProtocol.reset()
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var clock = Date(timeIntervalSince1970: 1_000)
        let url = "https://m.media-amazon.com/images/I/missing.jpg"
        WebImageProtocol.replies[url] = WebImageProtocol.Reply(status: 404, mime: "text/plain", body: Data())
        let images = cache(in: directory, retryAfter: 180, now: { clock })
        images.prefetch([url])
        await settle { images.isCoolingDown(url) }
        XCTAssertEqual(WebImageProtocol.hitCount(url), 1)
        images.prefetch([url])
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(WebImageProtocol.hitCount(url), 1)
        clock = clock.addingTimeInterval(181)
        images.prefetch([url])
        await settle { WebImageProtocol.hitCount(url) == 2 }
        XCTAssertEqual(WebImageProtocol.hitCount(url), 2)
    }

    func testGatherPrefetchesOnlyAlexaProductImages() async throws {
        WebImageProtocol.reset()
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let amazon = "https://m.media-amazon.com/images/I/gather.jpg"
        let claude = "https://m.media-amazon.com/images/I/claude-only.jpg"
        WebImageProtocol.replies[amazon] = WebImageProtocol.Reply(mime: "image/png", body: Data([0x89, 0x50, 0x4E, 0x47]))
        WebImageProtocol.replies[claude] = WebImageProtocol.Reply(mime: "image/png", body: Data([0x89, 0x50, 0x4E, 0x47]))
        let images = cache(in: directory, maxBytes: 1024)
        var comparison = Comparison(prompt: "Cable", members: [])
        comparison.setWebAgents([.alexaShopping, .claude])
        comparison.endedAt = Date()
        comparison.endedWebHistory = [
            "alexaShopping": [WebPageMessage(id: "a", role: "assistant", text: "Example Cable", images: [amazon, "https://evil.example.com/x.jpg"])],
            "claude": [WebPageMessage(id: "c", role: "assistant", text: "Note", images: [claude])],
        ]
        let status = MacStatus(macName: "Studio", variant: .demo, locked: false, awake: true, databaseAvailable: true, databaseStatus: "ok",
                               messagesBusy: false, broadcastBusy: false, sendingAgentIDs: [], keepAwakeEnabled: false, keepAwakeHeld: false,
                               messagesSendsAllowed: false, observedAt: Date())
        var input = RemoteProjectionInput(macStatus: status, gridAgentIDs: [], agents: [], comparisons: [comparison])
        input.gatherWebState(from: [], imageCache: images)
        XCTAssertTrue(input.webImages.isEmpty, "The send path does not wait for the download")
        await settle { images.attachment(for: amazon) != nil }
        input.gatherWebState(from: [], imageCache: images)
        XCTAssertEqual(input.webImages[amazon]?.filename, "product.png")
        XCTAssertNil(input.webImages[claude])
        XCTAssertEqual(WebImageProtocol.hitCount(claude), 0)
        XCTAssertEqual(WebImageProtocol.hitCount("https://evil.example.com/x.jpg"), 0)
    }
}

final class WebImageProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var mime = "image/jpeg"
        var body = Data([0xFF, 0xD8, 0xFF, 0xD9])
        var contentLength: String?
    }
    nonisolated(unsafe) static var replies: [String: Reply] = [:]
    nonisolated(unsafe) static var hits: [String: Int] = [:]
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        replies = [:]
        hits = [:]
        lock.unlock()
    }

    static func hitCount(_ url: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return hits[url, default: 0]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let key = request.url?.absoluteString ?? ""
        Self.lock.lock()
        Self.hits[key, default: 0] += 1
        let reply = Self.replies[key] ?? Reply(status: 404, mime: "text/plain", body: Data())
        Self.lock.unlock()
        var headers = ["Content-Type": reply.mime]
        if let length = reply.contentLength { headers["Content-Length"] = length }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
