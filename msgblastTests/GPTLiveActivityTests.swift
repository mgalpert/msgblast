import XCTest
@testable import msgblastCore

@MainActor
final class GPTLiveActivityTests: XCTestCase {
    func testMetadataIsRetainedWithoutDebugDetailsAndEnablingIsNotRetroactive() {
        let log = GPTLiveActivityLog()
        log.record(category: "tool", summary: "Read conversation", detail: "private previous text", callID: "call-1")
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertEqual(log.entries.first?.callID, "call-1")
        XCTAssertNil(log.entries.first?.detail)
        log.enabled = true
        log.record(category: "result", summary: "Read complete", detail: "new conversation text")
        XCTAssertNil(log.entries.first?.detail)
        XCTAssertEqual(log.entries.last?.detail, "new conversation text")
        log.enabled = false
        log.record(category: "result", summary: "Another read", detail: "hidden text")
        XCTAssertNil(log.entries.last?.detail)
    }

    func testCredentialsAndAudioAreRedactedInEveryFieldAndExport() throws {
        let log = GPTLiveActivityLog()
        log.enabled = true
        let detail = #"{"Authorization":"Bearer secret-auth-value","api_key":"arbitrary-secret","apiKey":"escaped-\"secret","password":"secret-pass","audio":"AQIDBA==","normal":"Conversation is kept","nested":{"access_token":"secret-access"}}"#
        log.record(category: "sk-category-key", summary: "Credentials Sk-Proj-Abc_def-123 and Bearer second-secret", detail: detail, callID: "sk-call-private")
        let export = String(decoding: try log.jsonExportData(), as: UTF8.self)
        for secret in ["sk-category-key", "Sk-Proj-Abc_def-123", "second-secret", "secret-auth-value", "arbitrary-secret", "escaped-", "secret-pass", "AQIDBA", "secret-access", "sk-call-private"] {
            XCTAssertFalse(export.contains(secret), "Leaked \(secret)")
        }
        XCTAssertTrue(export.contains("Conversation is kept"))
        XCTAssertTrue(export.contains("[redacted"))
    }

    func testUnstructuredCredentialsAndEncodedDataAreRedacted() {
        let input = "Authorization: Bearer not-an-openai-key\napi-key='private-value'\npassword=hidden\nBearer abc.def.ghi\n" + String(repeating: "QUJD", count: 100) + "\ndata:audio/pcm;base64,AQIDBA=="
        let result = GPTLiveActivityLog.sanitized(input, maximumBytes: 4096)
        for secret in ["not-an-openai-key", "private-value", "hidden", "abc.def.ghi", "QUJD", "AQIDBA"] { XCTAssertFalse(result.contains(secret)) }
    }

    func testStructuredRedactionHandlesEscapedKeysAndNestedAudio() {
        let input = #"{"api\u005fkey":"escaped-secret","audio":{"chunks":["AQIDBA=="]},"input_audio":["another-blob"],"safe":{"text":"Kept"}}"#
        let result = GPTLiveActivityLog.sanitized(input, maximumBytes: 4096)
        XCTAssertFalse(result.contains("escaped-secret"))
        XCTAssertFalse(result.contains("AQIDBA"))
        XCTAssertFalse(result.contains("another-blob"))
        XCTAssertTrue(result.contains("Kept"))
    }

    func testRetentionIsBoundedAndUTF8ClippingRemainsValid() throws {
        let log = GPTLiveActivityLog(maximumEntries: 4, maximumBytes: 4096)
        log.enabled = true
        for number in 0..<20 {
            log.record(category: "tool", summary: "Call \(number)", detail: String(repeating: "👩🏽‍💻", count: 4000))
        }
        XCTAssertLessThanOrEqual(log.entries.count, 4)
        XCTAssertLessThanOrEqual(log.entries.reduce(0) { $0 + $1.retainedBytes }, 4096)
        XCTAssertGreaterThan(log.droppedEntryCount, 0)
        XCTAssertEqual(log.entries.last?.summary, "Call 19")
        XCTAssertTrue(log.entries.last?.detail?.hasSuffix("[truncated]") == true)
        let decoded = try JSONSerialization.jsonObject(with: log.jsonExportData()) as? [String: Any]
        XCTAssertEqual(decoded?["formatVersion"] as? Int, 1)
        XCTAssertEqual((decoded?["entries"] as? [[String: Any]])?.count, log.entries.count)
        log.clear()
        XCTAssertTrue(log.entries.isEmpty)
        XCTAssertEqual(log.droppedEntryCount, 0)
        XCTAssertTrue(log.enabled)
    }

    func testKeyCrossingInputLimitIsNotPartiallyRetained() {
        let prefix = String(repeating: "x ", count: 131060)
        let result = GPTLiveActivityLog.sanitized(prefix + "sk-proj-private-value-too-long", maximumBytes: 300000)
        XCTAssertFalse(result.contains("sk-proj"))
        XCTAssertFalse(result.contains("private-value"))
        XCTAssertTrue(result.hasSuffix("[truncated]"))
    }

    func testSessionMetadataShowsLifecycleWithoutContentOrAudioFrameFlood() async {
        let transport = GPTLiveActivityTransport()
        let session = GPTLiveSession(transportFactory: { transport })
        var metadata: [(String, String)] = []
        session.onActivity = { metadata.append(($0, $1)) }
        await session.connect(apiKey: "sk-fixture-private", instructions: "Private instructions", backendInstructions: "Private backend", tools: [])
        await session.sendText("Private user request")
        for _ in 0..<40 {
            transport.push(["type": "session.output_audio.delta", "delta": "AQIDBA=="])
        }
        for _ in 0..<200 { await Task.yield() }
        await session.close()
        let joined = metadata.map(\.1).joined(separator: "\n")
        for privateValue in ["sk-fixture", "Private", "AQIDBA"] { XCTAssertFalse(joined.contains(privateValue)) }
        XCTAssertEqual(metadata.filter { $0.0 == "audio" }.count, 1)
        XCTAssertTrue(joined.contains("connected"))
        XCTAssertTrue(joined.contains("Backend response completed"))
        XCTAssertTrue(joined.contains("final usage confirmed"))
        XCTAssertEqual(session.state, .idle)
    }
}

@MainActor
private final class GPTLiveActivityTransport: GPTLiveTransport {
    private var queued: [String] = []
    private var waiting: CheckedContinuation<String, any Error>?
    func start(request: URLRequest) {}
    func send(_ text: String) async throws {
        let event = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        switch event["type"] as? String {
        case "session.start": push(["type": "session.started"])
        case "response.create":
            push(["type": "response.event", "event": ["type": "response.created", "response": ["id": "test-response"]]])
            push(["type": "response.event", "event": ["type": "response.completed", "response": ["id": "test-response", "status": "completed", "usage": ["total_tokens": 10]]]])
        case "session.close": push(["type": "session.closed", "usage": ["seconds": 2]])
        default: break
        }
    }
    func receive() async throws -> String {
        if !queued.isEmpty { return queued.removeFirst() }
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }
    func push(_ value: [String: Any]) {
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        if let waiting { self.waiting = nil; waiting.resume(returning: text) }
        else { queued.append(text) }
    }
    func cancel() { waiting?.resume(throwing: CancellationError()); waiting = nil }
}
