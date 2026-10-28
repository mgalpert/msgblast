import XCTest
@testable import msgblastCore

final class TelemetryTests: XCTestCase {
    func testOnlyConfiguredOfficialAndDevelopmentBundlesCanUpload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (index, entry) in [("com.msgblast.mac", false, true), ("com.msgblast.development", false, true), ("com.msgblast.development.remote", false, true), ("com.msgblast.demo", true, false), ("com.msgblast.developmentx", false, false), ("com.example.fork", false, false)].enumerated() {
            let url = directory.appendingPathComponent("test\(index).bundle")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": entry.0, "msgblastTelemetryEndpoint": "https://msgblast.app/api/telemetry"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url.appendingPathComponent("Info.plist"))
            let bundle = try XCTUnwrap(Bundle(url: url))
            XCTAssertEqual(TelemetryCollector.endpoint(bundle: bundle, demo: entry.1) != nil, entry.2)
        }
    }

    func testConsentLinkageIsIndependentAndResetsAfterOptOut() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let first = SharingConsent(preferences: SharingPreferences(), now: start)
        var choices = first.preferences
        choices.messageCounts = false
        let changed = SharingConsent(preferences: choices, previous: first, now: start.addingTimeInterval(100))
        XCTAssertEqual(changed.installationID, first.installationID)
        XCTAssertEqual(changed.cohortStartedAt, start)
        XCTAssertNotEqual(changed.revision, first.revision)
        choices.activity = false
        let unlinked = SharingConsent(preferences: choices, previous: changed)
        let event = TelemetryEvent(name: .agentInventory, properties: TelemetryProperties(), consent: unlinked)
        XCTAssertNil(event.distinctID)
        XCTAssertNil(event.properties.cohortDay)
        choices.activity = true
        let optedBackIn = SharingConsent(preferences: choices, previous: unlinked)
        XCTAssertNotEqual(optedBackIn.installationID, first.installationID)
    }

    func testElapsedDayBoundariesForRetention() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let consent = SharingConsent(preferences: SharingPreferences(), now: start)
        for day in [0, 1, 7, 14, 30] {
            let event = TelemetryEvent(name: .appEngaged, properties: TelemetryProperties(), consent: consent, now: start.addingTimeInterval(Double(day) * 86_400))
            XCTAssertEqual(event.properties.cohortDay, day)
        }
        let event = TelemetryEvent(name: .appEngaged, properties: TelemetryProperties(), consent: consent, now: start.addingTimeInterval(86_399))
        XCTAssertEqual(event.properties.cohortDay, 0)
    }

    func testCollectorRequiresSavedConsentAndPurgesOnRevocation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = directory.appendingPathComponent("queue.json")
        let collector = TelemetryCollector(endpoint: URL(string: "https://example.invalid/api/telemetry")!, queueURL: queue)
        let consent = SharingConsent(preferences: SharingPreferences())
        let event = TelemetryEvent(name: .appActive, properties: TelemetryProperties(), consent: consent)
        await collector.record(event, revision: consent.revision)
        XCTAssertFalse(FileManager.default.fileExists(atPath: queue.path))
        await collector.configure(consent)
        await collector.record(event, revision: consent.revision)
        let pending = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: queue)) as? [String: Any])
        let pendingEvents = try XCTUnwrap(pending["events"] as? [[String: Any]])
        XCTAssertEqual(pendingEvents.count, 1)
        XCTAssertEqual(pendingEvents.first?["id"] as? String, event.id.uuidString)
        await collector.configure(nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: queue.path))
        await collector.record(event, revision: consent.revision)
        XCTAssertFalse(FileManager.default.fileExists(atPath: queue.path))
    }

    func testAcceptedRecordSurvivesRestartUntilAcknowledged() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = directory.appendingPathComponent("queue.json")
        let endpoint = URL(string: "https://telemetry-test.invalid/api/telemetry")!
        let consent = SharingConsent(preferences: SharingPreferences())
        let event = TelemetryEvent(name: .appActive, properties: TelemetryProperties(), consent: consent)
        let first = TelemetryCollector(endpoint: endpoint, queueURL: queue)
        await first.configure(consent)
        await first.record(event, revision: consent.revision)
        TelemetryTransport.requests.clear()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TelemetryTransport.self]
        let restarted = TelemetryCollector(endpoint: endpoint, queueURL: queue, session: URLSession(configuration: config))
        await restarted.configure(consent)
        await restarted.flush()
        let request = try XCTUnwrap(TelemetryTransport.requests.snapshot().first)
        let body = try XCTUnwrap(request.httpBody)
        let batch = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let uploaded = try XCTUnwrap(batch["events"] as? [[String: Any]])
        XCTAssertEqual(uploaded.first?["id"] as? String, event.id.uuidString)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: queue)) as? [String: Any])
        XCTAssertEqual((saved["events"] as? [Any])?.count, 0)
        await first.configure(nil)
        await restarted.configure(nil)
    }

    func testAbsentConsentRemainsAbsentWhenLoadingLegacyState() throws {
        var state = AppState()
        state.draft = "kept locally"
        let restored = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state))
        XCTAssertNil(restored.sharingConsent)
        XCTAssertEqual(restored.draft, "kept locally")
        XCTAssertNil(TelemetryCollector.endpoint(demo: true))
    }

    func testSubmissionIsCountedOnceAndOnlyAllowedFieldsLeaveCollector() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        TelemetryTransport.requests.clear()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TelemetryTransport.self]
        let collector = TelemetryCollector(endpoint: URL(string: "https://telemetry-test.invalid/api/telemetry")!, queueURL: directory.appendingPathComponent("queue.json"), session: URLSession(configuration: config))
        var choices = SharingPreferences(); choices.activity = false; choices.reliability = false; choices.performance = false
        let consent = SharingConsent(preferences: choices)
        await collector.configure(consent)
        var properties = TelemetryProperties(); properties.kind = .shared; properties.recipientCount = 5
        let event = TelemetryEvent(name: .messageSubmitted, properties: properties, consent: consent)
        let disabled = TelemetryEvent(name: .appEngaged, properties: TelemetryProperties(), consent: consent)
        let localReceipt = UUID()
        await collector.recordSubmission([event, disabled], revision: consent.revision, logicalID: localReceipt)
        await collector.recordSubmission([event, disabled], revision: consent.revision, logicalID: localReceipt)
        await collector.flush()
        let requests = TelemetryTransport.requests.snapshot()
        XCTAssertEqual(requests.count, 1)
        let body = try XCTUnwrap(requests.first?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["name"] as? String, "message_submitted")
        XCTAssertNil(events.first?["distinctID"])
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains(localReceipt.uuidString))
        await collector.flush()
        XCTAssertEqual(TelemetryTransport.requests.snapshot().count, 1)
        let editedConsent = SharingConsent(preferences: choices, previous: consent)
        await collector.configure(editedConsent)
        let retry = TelemetryEvent(name: .messageSubmitted, properties: properties, consent: editedConsent)
        await collector.recordSubmission([retry], revision: editedConsent.revision, logicalID: localReceipt)
        await collector.flush()
        XCTAssertEqual(TelemetryTransport.requests.snapshot().count, 1, "Saving choices must not count an old submission again")
        await collector.configure(nil)
    }
}

private final class TelemetryRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []
    func append(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; values.append(request) }
    func clear() { lock.lock(); defer { lock.unlock() }; values = [] }
    func snapshot() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return values }
}

private final class TelemetryTransport: URLProtocol, @unchecked Sendable {
    static let requests = TelemetryRequests()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "telemetry-test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        // URLSession exposes upload bodies as streams to URLProtocol on macOS.
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = body
        }
        Self.requests.append(captured)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
