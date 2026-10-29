import XCTest
@testable import msgblastCore

@MainActor
private final class GPTLiveFixtureTransport: GPTLiveTransport {
    var request: URLRequest?
    var sent: [[String: Any]] = []
    var cancelled = false
    var holdSends = false
    var failSend = false
    private var incoming: [String] = []
    private var receiver: CheckedContinuation<String, any Error>?
    private var senders: [CheckedContinuation<Void, any Error>] = []

    func start(request: URLRequest) { self.request = request }

    func send(_ text: String) async throws {
        if failSend { throw URLError(.networkConnectionLost) }
        let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        sent.append(json)
        if holdSends { try await withCheckedThrowingContinuation { senders.append($0) } }
    }

    func receive() async throws -> String {
        if !incoming.isEmpty { return incoming.removeFirst() }
        if cancelled { throw CancellationError() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }

    func cancel() {
        cancelled = true
        receiver?.resume(throwing: CancellationError())
        receiver = nil
        let waiting = senders
        senders.removeAll()
        waiting.forEach { $0.resume(throwing: CancellationError()) }
    }

    func push(_ event: [String: Any]) {
        var event = event
        if event["event_id"] == nil { event["event_id"] = UUID().uuidString }
        let text = String(data: try! JSONSerialization.data(withJSONObject: event), encoding: .utf8)!
        if let continuation = receiver { receiver = nil; continuation.resume(returning: text) }
        else { incoming.append(text) }
    }

    func nested(_ event: [String: Any], delegation: String = "fixture-delegation") {
        push(["type": "response.event", "delegation_id": delegation, "event": event])
    }

    var types: [String] { sent.compactMap { $0["type"] as? String } }

    func created(_ id: String = "response-1") {
        nested(["type": "response.created", "response": ["id": id, "output": []]])
    }

    func completed(_ id: String = "response-1", tokens: Int = 25) {
        nested(["type": "response.completed", "response": ["id": id, "status": "completed",
            "output": [], "tools": [], "instructions": NSNull(), "usage": ["total_tokens": tokens]]])
    }

    func function(_ callID: String, responseID: String = "response-1") {
        nested(["type": "response.output_item.done", "response_id": responseID,
                "item": ["type": "function_call", "call_id": callID, "name": "prepare_draft", "arguments": "{\"text\":\"Hello\"}"]])
    }
}

@MainActor
final class GPTLiveTests: XCTestCase {
    private func eventually(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("The fixture did not reach its expected state", file: file, line: line)
    }

    private func ready(maximumQueuedBytes: Int = 1024 * 1024, closeTimeout: Duration = .seconds(15)) async -> (GPTLiveSession, GPTLiveFixtureTransport) {
        let transport = GPTLiveFixtureTransport()
        let session = GPTLiveSession(transportFactory: { transport }, closeTimeout: closeTimeout, maximumQueuedBytes: maximumQueuedBytes)
        let connecting = Task { await session.connect(apiKey: "sk-fixture-test-only", instructions: "Be concise.", backendInstructions: "Prepare drafts.", tools: []) }
        await eventually { transport.types.contains("session.start") }
        transport.push(["type": "session.started", "session": ["id": "fixture-session"]])
        await connecting.value
        await eventually { transport.types.contains("session.input_audio.mute") }
        return (session, transport)
    }

    private func finish(_ session: GPTLiveSession, _ transport: GPTLiveFixtureTransport) async {
        let closing = Task { await session.close() }
        await eventually { session.state == .closing || session.state == .failed }
        if session.state == .closing {
            transport.push(["type": "session.closed", "reason": "close_requested", "usage": ["seconds": 3]])
        }
        await closing.value
    }

    func testStartupRequiresStartedAndUsesLiveProtocol() async throws {
        let transport = GPTLiveFixtureTransport()
        let session = GPTLiveSession(transportFactory: { transport })
        let connecting = Task { await session.connect(apiKey: "sk-fixture-test-only", instructions: "Voice instructions", backendInstructions: "Tool instructions", tools: []) }
        await eventually { transport.types == ["session.start"] }
        XCTAssertEqual(session.state, .connecting)
        await session.sendText("Must not be sent before ready")
        XCTAssertEqual(transport.types, ["session.start"])
        XCTAssertEqual(transport.request?.url?.absoluteString, "wss://api.openai.com/v1/live/sessions")
        XCTAssertEqual(transport.request?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-fixture-test-only")
        let configuration = try XCTUnwrap(transport.sent.first?["session"] as? [String: Any])
        XCTAssertEqual(configuration["model"] as? String, "gpt-live-1")
        XCTAssertEqual(configuration["store"] as? Bool, false)
        let delegation = try XCTUnwrap(configuration["delegation"] as? [String: Any])
        let backend = try XCTUnwrap(delegation["responses"] as? [String: Any])
        XCTAssertEqual(backend["model"] as? String, "gpt-6-luna")
        transport.push(["type": "session.started"])
        await connecting.value
        XCTAssertEqual(session.state, .connected)
        await finish(session, transport)
    }

    func testTypedTurnStreamsBackendTextWithoutDuplicatedLiveSpeechAndCountsUsageOnce() async {
        let (session, transport) = await ready()
        await session.sendText("Review this conversation")
        XCTAssertEqual(Array(transport.types.suffix(2)), ["response.item.create", "response.create"])
        XCTAssertTrue(session.backendBusy)
        transport.created()
        transport.nested(["type": "response.output_text.delta", "item_id": "answer", "delta": "A helpful "])
        transport.nested(["type": "response.output_text.delta", "item_id": "answer", "delta": "review."])
        transport.push(["type": "session.output_transcript.delta", "delta": "A helpful review."])
        transport.completed(tokens: 37)
        transport.completed(tokens: 37)
        await eventually { !session.backendBusy }
        XCTAssertEqual(session.transcript.map(\.text), ["Review this conversation", "A helpful review."])
        XCTAssertTrue(session.usageSummary.contains("37 tokens"))
        await finish(session, transport)
    }

    func testAllCompletedFunctionCallsRunOnceAndContinueOnlyAfterAllResults() async {
        let (session, transport) = await ready()
        var executed: [String] = []
        var delayed: CheckedContinuation<String, Never>?
        session.onToolCall = { call in
            executed.append(call.callID)
            if call.callID == "call-slow" { return await withCheckedContinuation { delayed = $0 } }
            return "{\"status\":\"prepared\"}"
        }
        transport.created()
        transport.function("call-fast")
        transport.function("call-slow")
        transport.function("call-fast")
        // Lifecycle output arrays are intentionally empty, as in the Live contract.
        transport.completed()
        await eventually { executed.count == 2 && delayed != nil }
        XCTAssertFalse(transport.types.contains("response.item.create"))
        XCTAssertTrue(session.backendBusy)
        delayed?.resume(returning: "{\"status\":\"prepared\"}")
        await eventually { transport.types.filter { $0 == "response.create" }.count == 1 }
        XCTAssertEqual(Array(transport.types.suffix(3)), ["response.item.create", "response.item.create", "response.create"])
        let calls = transport.sent.compactMap { ($0["item"] as? [String: Any])?["call_id"] as? String }
        XCTAssertEqual(calls, ["call-fast", "call-slow"])
        transport.function("call-fast")
        transport.completed()
        transport.created("response-2")
        transport.completed("response-2")
        await eventually { !session.backendBusy }
        XCTAssertEqual(executed.count, 2)
        XCTAssertEqual(transport.types.filter { $0 == "response.create" }.count, 1)
        await finish(session, transport)
    }

    func testArgumentDoneAloneDoesNotExecuteAndFailedResponseDoesNotContinue() async {
        let (session, transport) = await ready()
        var executed = 0
        session.onToolCall = { _ in executed += 1; return "{}" }
        transport.created()
        transport.nested(["type": "response.function_call_arguments.done", "name": "prepare_draft", "arguments": "{}"])
        transport.nested(["type": "response.failed", "response": ["id": "response-1", "status": "failed", "output": []]])
        await eventually { session.error != nil }
        XCTAssertEqual(executed, 0)
        XCTAssertFalse(session.backendBusy)
        XCTAssertFalse(transport.types.contains("response.create"))
        XCTAssertEqual(session.state, .connected)
        await finish(session, transport)
    }

    func testMicrophoneOptInAlignmentMuteAndAudioShutdown() async throws {
        let (session, transport) = await ready()
        var received: [Data] = []
        session.onOutputAudio = { received.append($0) }
        await session.sendAudio(Data([1, 2]))
        XCTAssertFalse(transport.types.contains("session.input_audio.append"))
        await session.setInputMuted(false)
        await session.sendAudio(Data([1]))
        await session.sendAudio(Data([2, 3, 4]))
        let event = try XCTUnwrap(transport.sent.last)
        XCTAssertEqual(event["type"] as? String, "session.input_audio.append")
        XCTAssertEqual(Data(base64Encoded: event["audio"] as! String), Data([1, 2, 3, 4]))
        await session.sendAudio(Data([5]))
        await session.setInputMuted(true)
        await session.setInputMuted(false)
        await session.sendAudio(Data([6, 7]))
        XCTAssertEqual(Data(base64Encoded: transport.sent.last?["audio"] as! String), Data([6, 7]))
        transport.push(["type": "session.output_audio.delta", "delta": Data([1, 2]).base64EncodedString()])
        await eventually { received.count == 1 }
        let closing = Task { await session.close() }
        await eventually { session.state == .closing }
        transport.push(["type": "session.output_audio.delta", "delta": Data([3, 4]).base64EncodedString()])
        transport.push(["type": "session.closed", "usage": ["seconds": 7]])
        await closing.value
        XCTAssertEqual(received, [Data([1, 2])])
        XCTAssertTrue(transport.cancelled)
    }

    func testCloseWaitsForFinalEventAndUsesCumulativeUsage() async {
        let (session, transport) = await ready()
        transport.push(["type": "session.usage.updated", "usage": ["seconds": 12]])
        transport.push(["type": "session.usage.updated", "usage": ["seconds": 15]])
        await eventually { session.usageSummary.contains("15.0s") }
        let closing = Task { await session.close() }
        await eventually { transport.types.contains("session.close") }
        XCTAssertEqual(session.state, .closing)
        XCTAssertFalse(transport.cancelled)
        await session.sendText("Cannot send while closing")
        transport.push(["type": "session.closed", "reason": "close_requested", "usage": ["seconds": 16]])
        await closing.value
        XCTAssertEqual(session.state, .idle)
        XCTAssertTrue(session.usageSummary.contains("16.0s"))
        XCTAssertTrue(session.usageSummary.hasSuffix(" · final"))
        XCTAssertTrue(transport.cancelled)
        XCTAssertFalse(transport.types.contains("response.item.create"))
    }

    func testCloseCancelsLateFunctionResult() async {
        let (session, transport) = await ready()
        var finishTool: CheckedContinuation<String, Never>?
        session.onToolCall = { _ in await withCheckedContinuation { finishTool = $0 } }
        transport.created()
        transport.function("pending")
        transport.completed()
        await eventually { finishTool != nil }
        await finish(session, transport)
        finishTool?.resume(returning: "{\"status\":\"prepared\"}")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(transport.types.contains("response.item.create"))
        XCTAssertFalse(session.backendBusy)
    }

    func testConnectionAndCloseTimeoutsReleaseResources() async {
        let transport = GPTLiveFixtureTransport()
        let session = GPTLiveSession(transportFactory: { transport }, connectionTimeout: .milliseconds(10))
        await session.connect(apiKey: "sk-fixture-test-only", instructions: "", backendInstructions: "", tools: [])
        XCTAssertEqual(session.state, .failed)
        XCTAssertTrue(transport.cancelled)
        XCTAssertTrue(session.error?.contains("ready in time") == true)
        let (connected, socket) = await ready(closeTimeout: .milliseconds(10))
        await connected.close()
        XCTAssertEqual(connected.state, .failed)
        XCTAssertTrue(socket.cancelled)
        XCTAssertTrue(connected.usageSummary.contains("unconfirmed"))
    }

    func testRejectedCredentialsNeverAppearInErrorsAndNoRetryOccurs() async {
        let (session, transport) = await ready()
        transport.push(["type": "error", "error": ["code": "invalid_api_key", "message": "Incorrect API key: sk-fixture-private-value"]])
        await eventually { session.state == .failed }
        XCTAssertFalse(session.error?.contains("sk-") == true)
        XCTAssertEqual(transport.types.filter { $0 == "session.start" }.count, 1)
        XCTAssertTrue(transport.cancelled)
    }

    func testBackpressureStopsInsteadOfLosingOrRetryingMessages() async {
        let (session, transport) = await ready(maximumQueuedBytes: 2_000)
        transport.holdSends = true
        let first = Task { await session.sendText("A request whose write is stalled") }
        await eventually { transport.types.contains("response.item.create") }
        await session.appendContext(String(repeating: "context ", count: 500))
        await first.value
        XCTAssertEqual(session.state, .failed)
        XCTAssertTrue(session.error?.contains("cannot keep up") == true)
        XCTAssertTrue(transport.cancelled)
        XCTAssertEqual(transport.types.filter { $0 == "response.item.create" }.count, 1)
        XCTAssertFalse(transport.types.contains("response.create"))
    }

    func testSendFailureStopsWithoutRetry() async {
        let (session, transport) = await ready()
        transport.failSend = true
        await session.sendText("Test uncertain submission")
        XCTAssertEqual(session.state, .failed)
        XCTAssertTrue(session.error?.contains("will not be retried") == true)
        XCTAssertTrue(transport.cancelled)
    }

    func testContextChunksPreserveUnicodeWithinTokenBoundAndKeychainIsPerBundle() {
        let text = String(repeating: "Hello 👩🏽‍💻 世界 ", count: 300)
        let chunks = GPTLiveSession.contextChunks(text)
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.utf8.count <= 480 })
        XCTAssertNotEqual(GPTLiveCredentials.serviceName(bundleIdentifier: "com.msgblast.mac"),
                          GPTLiveCredentials.serviceName(bundleIdentifier: "com.msgblast.dev-gptlive"))
        XCTAssertEqual(GPTLiveCredentials.serviceName(bundleIdentifier: "com.msgblast.dev-gptlive"),
                       "com.msgblast.dev-gptlive.openai.gpt-live")
    }
}
