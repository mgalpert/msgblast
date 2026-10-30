import Foundation
import Combine

public enum GPTLiveConnectionState: String, Sendable {
    case idle, connecting, connected, closing, failed
}

public struct GPTLiveTranscriptEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let role: String
    public var text: String

    public init(id: String = UUID().uuidString, role: String, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

public struct GPTLiveFunctionCall: Sendable {
    public let callID: String
    public let name: String
    public let arguments: String

    public init(callID: String, name: String, arguments: String) {
        self.callID = callID
        self.name = name
        self.arguments = arguments
    }
}

/// Injectable at the wire boundary: fixtures exercise the actual session state machine.
@MainActor
protocol GPTLiveTransport: AnyObject {
    func start(request: URLRequest)
    func send(_ text: String) async throws
    func receive() async throws -> String
    func cancel()
}

@MainActor
private final class GPTLiveWebSocket: GPTLiveTransport {
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?

    func start(request: URLRequest) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 4 * 1024 * 1024
        self.session = session
        self.socket = socket
        socket.resume()
    }

    func send(_ text: String) async throws {
        guard let socket else { throw URLError(.notConnectedToInternet) }
        try await socket.send(.string(text))
    }

    func receive() async throws -> String {
        guard let socket else { throw URLError(.notConnectedToInternet) }
        switch try await socket.receive() {
        case .string(let text): return text
        case .data(let data):
            guard let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
            return text
        @unknown default: throw URLError(.cannotDecodeContentData)
        }
    }

    func cancel() {
        socket?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        socket = nil
        session = nil
    }
}

/// GPT-Live voice and typed Responses delegation. It never retries a submission.
@MainActor
public final class GPTLiveSession: ObservableObject {
    @Published public private(set) var state: GPTLiveConnectionState = .idle
    @Published public private(set) var error: String?
    @Published public private(set) var transcript: [GPTLiveTranscriptEntry] = []
    @Published public private(set) var backendBusy = false
    @Published public private(set) var usageSummary = "No session usage"
    public var onOutputAudio: ((Data) -> Void)?
    public var onToolCall: ((GPTLiveFunctionCall) async -> String)?
    /// Concise metadata only. Credentials, message content, raw events, and audio never enter this callback.
    public var onActivity: ((String, String) -> Void)?

    private struct ResponseWork {
        var completed = false
        var failed = false
        var calls: [String] = []
        var results: [String: String] = [:]
        var continuing = false
        var continuationSent = false
    }

    private enum BatchKind {
        case startup, application, audio, close
        func allowsSending(in state: GPTLiveConnectionState) -> Bool {
            switch self {
            case .startup: state == .connecting
            case .close: state == .closing
            case .application, .audio: state == .connected
            }
        }
    }
    private struct Batch {
        var messages: [String]
        var bytes: Int
        var kind: BatchKind
        var completion: CheckedContinuation<Bool, Never>
    }

    private let transportFactory: () -> any GPTLiveTransport
    private let connectionTimeout: Duration
    private let closeTimeout: Duration
    private let maximumQueuedBytes: Int
    private var transport: (any GPTLiveTransport)?
    private var receiver: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var generation = UUID()
    private var batches: [Batch] = []
    private var queuedBytes = 0
    private var connectWaiters: [CheckedContinuation<Void, Never>] = []
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var toolTasks: [String: Task<Void, Never>] = [:]
    private var seenCalls: Set<String> = []
    private var seenEvents: Set<String> = []
    private var responses: [String: ResponseWork] = [:]
    private var delegationResponses: [String: String] = [:]
    private var countedUsage: Set<String> = []
    private var voiceSeconds = 0.0
    private var backendTokens = 0
    private var inputMuted = true
    private var pendingAudioByte = Data()
    private var typedConversation = false
    private var liveTranscriptID: String?
    private var liveTranscriptRole: String?
    private var finalizationConfirmed = false
    private var receivedOutputAudio = false
    private var sentInputAudio = false

    public convenience init() {
        self.init(transportFactory: { GPTLiveWebSocket() })
    }

    init(transportFactory: @escaping () -> any GPTLiveTransport,
         connectionTimeout: Duration = .seconds(20), closeTimeout: Duration = .seconds(15),
         maximumQueuedBytes: Int = 1024 * 1024) {
        self.transportFactory = transportFactory
        self.connectionTimeout = connectionTimeout
        self.closeTimeout = closeTimeout
        self.maximumQueuedBytes = maximumQueuedBytes
    }

    public func connect(apiKey: String, instructions: String, backendInstructions: String, tools: [[String: Any]]) async {
        guard state == .idle || state == .failed else { return }
        cleanUp()
        generation = UUID()
        let connection = generation
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-"), (12...1024).contains(key.utf8.count), !key.contains(where: { $0.isWhitespace }) else {
            fail("Enter a valid OpenAI API key.")
            return
        }
        guard instructions.utf8.count <= 32_000, backendInstructions.utf8.count <= 64_000, tools.count <= 32 else {
            fail("The session configuration is too large.")
            return
        }
        error = nil
        transcript = []
        responses = [:]
        delegationResponses = [:]
        countedUsage = []
        seenCalls = []
        seenEvents = []
        voiceSeconds = 0
        backendTokens = 0
        finalizationConfirmed = false
        receivedOutputAudio = false
        sentInputAudio = false
        typedConversation = false
        inputMuted = true
        liveTranscriptID = nil
        liveTranscriptRole = nil
        usageSummary = "Voice 0s · Backend 0 tokens"
        state = .connecting
        onActivity?("connection", "Connecting GPT-Live 1 with \(tools.count) app tools and GPT-6 Luna delegation.")
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/live/sessions")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        let transport = transportFactory()
        self.transport = transport
        transport.start(request: request)
        receiver = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await transport.receive()
                    guard let self, self.generation == connection else { return }
                    await self.receive(message)
                } catch {
                    guard let self, self.generation == connection,
                          self.state == .connecting || self.state == .connected || self.state == .closing else { return }
                    self.fail("The GPT-Live connection ended before finalization. Check the key, project access, and network. Final usage is unconfirmed.")
                    return
                }
            }
        }
        deadline = Task { [weak self, connectionTimeout] in
            do { try await Task.sleep(for: connectionTimeout) } catch { return }
            guard let self, self.generation == connection, self.state == .connecting else { return }
            self.fail("GPT-Live did not become ready in time. Check the key, project access, and network.")
        }
        let started = await enqueue([[
            "type": "session.start",
            "session": ["model": "gpt-live-1", "store": false, "instructions": instructions,
                        "audio": ["format": ["type": "audio/pcm", "rate": 24000], "output": ["voice": "marin"]],
                        "delegation": ["type": "responses", "responses": ["model": "gpt-6-luna",
                            "instructions": backendInstructions, "tools": tools, "tool_choice": "auto",
                            "parallel_tool_calls": false, "max_output_tokens": 4096]]] as [String: Any]
        ]], kind: .startup)
        guard started, generation == connection, state == .connecting else { return }
        await withCheckedContinuation { connectWaiters.append($0) }
    }

    public func sendText(_ text: String) async {
        guard state == .connected else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.utf8.count <= 64_000 else { reportError("The message exceeds the 64 KB limit."); return }
        guard !backendBusy else { reportError("Wait for the current request to finish before sending another."); return }
        error = nil
        backendBusy = true
        typedConversation = true
        liveTranscriptID = nil
        appendTranscript(id: UUID().uuidString, role: "user", text: text)
        onActivity?("request", "Submitting typed request (\(text.utf8.count) bytes).")
        _ = await enqueue([
            ["type": "response.item.create", "item": ["type": "message", "role": "user",
                "content": [["type": "input_text", "text": text]]]],
            ["type": "response.create"]
        ])
    }

    /// Context is data for the live model. Each append is conservatively below 500 tokens.
    public func appendContext(_ text: String) async {
        guard state == .connected, !text.isEmpty else { return }
        guard text.utf8.count <= 32_000 else { reportError("The context exceeds the 32 KB limit."); return }
        let events: [[String: Any]] = Self.contextChunks(text).map {
            ["type": "session.thinking.append", "delegation_id": NSNull(), "content": $0]
        }
        onActivity?("context", "Appending app context (\(text.utf8.count) bytes in \(events.count) chunks).")
        _ = await enqueue(events)
    }

    static func contextChunks(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        var bytes = 0
        for scalar in text.unicodeScalars {
            let part = String(scalar)
            if bytes + part.utf8.count > 480 { chunks.append(current); current = ""; bytes = 0 }
            current += part
            bytes += part.utf8.count
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    public func sendAudio(_ pcm: Data) async {
        guard state == .connected, !inputMuted, !pcm.isEmpty else { return }
        guard pcm.count <= 48_000 else { fail("Microphone audio exceeded the streaming buffer limit."); return }
        var bytes = pendingAudioByte
        bytes.append(pcm)
        let complete = bytes.count - bytes.count % 2
        pendingAudioByte = Data(bytes.suffix(bytes.count - complete))
        guard complete > 0 else { return }
        if !sentInputAudio {
            sentInputAudio = true
            onActivity?("audio", "Started streaming microphone audio. Audio data is not logged.")
        }
        _ = await enqueue([["type": "session.input_audio.append", "audio": bytes.prefix(complete).base64EncodedString()]], kind: .audio)
    }

    public func setInputMuted(_ muted: Bool) async {
        inputMuted = muted
        pendingAudioByte = Data()
        guard state == .connected else { return }
        if muted { discardQueuedAudio() }
        onActivity?("audio", muted ? "Microphone muted." : "Microphone unmuted.")
        _ = await enqueue([["type": muted ? "session.input_audio.mute" : "session.input_audio.unmute"]])
    }

    public func close() async {
        if state == .closing {
            await withCheckedContinuation { closeWaiters.append($0) }
            return
        }
        guard state == .connected else {
            if state == .connecting {
                onActivity?("connection", "Cancelled connection before the session became ready.")
                state = .idle
                cleanUp()
            }
            return
        }
        state = .closing
        onActivity?("connection", "Closing GPT-Live; waiting for final usage confirmation.")
        inputMuted = true
        pendingAudioByte = Data()
        if !toolTasks.isEmpty { onActivity?("cancellation", "Cancelled \(toolTasks.count) pending tool tasks while closing.") }
        toolTasks.values.forEach { $0.cancel() }
        toolTasks.removeAll()
        discardQueuedBatches()
        let connection = generation
        deadline?.cancel()
        deadline = Task { [weak self, closeTimeout] in
            do { try await Task.sleep(for: closeTimeout) } catch { return }
            guard let self, self.generation == connection, self.state == .closing else { return }
            self.fail("GPT-Live close timed out. Final usage is unconfirmed.")
        }
        let sent = await enqueue([["type": "session.close"]], kind: .close)
        guard sent, generation == connection, state == .closing else { return }
        await withCheckedContinuation { closeWaiters.append($0) }
    }

    private func enqueue(_ events: [[String: Any]], kind: BatchKind = .application) async -> Bool {
        guard transport != nil else { return false }
        guard kind.allowsSending(in: state) else { return false }
        var messages: [String] = []
        do {
            for var event in events {
                event["event_id"] = "event_" + UUID().uuidString
                let data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
                guard let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
                messages.append(text)
            }
        } catch { fail("The GPT-Live request could not be encoded."); return false }
        let bytes = messages.reduce(0) { $0 + $1.utf8.count }
        guard bytes + queuedBytes <= maximumQueuedBytes, batches.count < 128 else {
            fail("The GPT-Live connection cannot keep up. The session stopped to avoid losing or repeating messages.")
            return false
        }
        return await withCheckedContinuation { completion in
            batches.append(Batch(messages: messages, bytes: bytes, kind: kind, completion: completion))
            queuedBytes += bytes
            if sender == nil {
                let connection = generation
                sender = Task { [weak self] in await self?.drain(connection: connection) }
            }
        }
    }

    private func drain(connection: UUID) async {
        while generation == connection, !Task.isCancelled, !batches.isEmpty {
            let batch = batches.removeFirst()
            var success = true
            for message in batch.messages {
                guard generation == connection, batch.kind.allowsSending(in: state), let transport, !Task.isCancelled else { success = false; break }
                do { try await transport.send(message) }
                catch {
                    success = false
                    if generation == connection, state != .idle, state != .failed {
                        fail("A GPT-Live request could not be sent. Its outcome is uncertain; it will not be retried. Final usage is unconfirmed.")
                    }
                    break
                }
            }
            if generation == connection { queuedBytes = max(0, queuedBytes - batch.bytes) }
            batch.completion.resume(returning: success)
        }
        if generation == connection { sender = nil }
    }

    private func receive(_ text: String) async {
        guard text.utf8.count <= 4 * 1024 * 1024,
              let data = text.data(using: .utf8), let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { fail("GPT-Live returned an invalid event."); return }
        if let id = event["event_id"] as? String {
            guard !seenEvents.contains(id) else { return }
            // Stop instead of evicting deduplication records and risking a repeated action.
            guard seenEvents.count < 100_000, id.utf8.count <= 256 else { fail("This session reached its event limit. Start a new session."); return }
            seenEvents.insert(id)
        }
        switch type {
        case "session.started":
            guard state == .connecting else { return }
            deadline?.cancel()
            state = .connected
            onActivity?("connection", "GPT-Live connected. Microphone is off.")
            _ = await enqueue([["type": "session.input_audio.mute"]])
            resumeConnectWaiters()
        case "session.input_transcript.delta", "session.output_transcript.delta":
            guard state == .connected, let delta = event["delta"] as? String else { return }
            let role = type == "session.input_transcript.delta" ? "user" : "assistant"
            if role == "user" { typedConversation = false }
            if role == "assistant", typedConversation { return }
            if liveTranscriptRole != role || liveTranscriptID == nil {
                liveTranscriptID = UUID().uuidString
                liveTranscriptRole = role
            }
            appendTranscript(id: liveTranscriptID!, role: role, text: delta)
        case "session.output_audio.delta":
            guard state == .connected, let base64 = event["delta"] as? String,
                  let audio = Data(base64Encoded: base64), audio.count % 2 == 0, audio.count <= 480_000 else { return }
            if !receivedOutputAudio {
                receivedOutputAudio = true
                onActivity?("audio", "Received spoken output. Audio data is not logged.")
            }
            onOutputAudio?(audio)
        case "session.delegation.created":
            guard state == .connected else { return }
            backendBusy = true
            onActivity?("request", "Live conversation delegated work to GPT-6 Luna.")
        case "response.event":
            guard state == .connected || state == .closing, let nested = event["event"] as? [String: Any] else { return }
            await receiveResponse(nested, delegationID: event["delegation_id"] as? String ?? "typed")
        case "session.usage.updated":
            updateUsage(event, finalized: false)
        case "session.closed":
            guard state == .closing || state == .connected || state == .connecting else { return }
            finalizationConfirmed = true
            updateUsage(event, finalized: true)
            let reason = event["reason"] as? String ?? "close_requested"
            if reason == "expired" { reportError("GPT-Live reached its session limit. Connect again to continue; prepared messages are retained.") }
            else if reason != "close_requested" { reportError("GPT-Live ended the session (\(Self.safeCode(reason))).") }
            onActivity?("connection", "GPT-Live session closed; final usage confirmed.")
            state = .idle
            cleanUp()
        case "error":
            let problem = event["error"] as? [String: Any] ?? [:]
            let code = problem["code"] as? String ?? "request_error"
            let message = Self.safeServerError(problem["message"] as? String, code: code)
            // Unsupported backend settings must be fixed before any more tool work.
            fail(message)
        default: break
        }
    }

    private func receiveResponse(_ event: [String: Any], delegationID: String) async {
        guard let type = event["type"] as? String else { return }
        let response = event["response"] as? [String: Any]
        let responseID = event["response_id"] as? String ?? response?["id"] as? String ?? delegationResponses[delegationID]
        if type == "response.created", let id = responseID {
            guard state == .connected else { return }
            guard responses[id] == nil else { return }
            guard responses.count < 1024, id.utf8.count <= 256, delegationID.utf8.count <= 256 else {
                fail("This session reached its backend response limit. Start a new session."); return
            }
            if let previous = delegationResponses[delegationID] { responses[previous]?.continuing = false }
            responses[id] = ResponseWork()
            delegationResponses[delegationID] = id
            backendBusy = true
            onActivity?("request", "Backend response started.")
            return
        }
        guard let id = responseID, responses[id] != nil else { return }
        if type == "response.output_text.delta", state == .connected, typedConversation, let delta = event["delta"] as? String {
            let itemID = event["item_id"] as? String ?? id
            appendTranscript(id: "backend-" + itemID, role: "assistant", text: delta)
        } else if type == "response.output_item.done", state == .connected, let item = event["item"] as? [String: Any], item["type"] as? String == "function_call" {
            guard let callID = item["call_id"] as? String, let name = item["name"] as? String,
                  let arguments = item["arguments"] as? String,
                  callID.utf8.count <= 256, name.utf8.count <= 128, arguments.utf8.count <= 64_000 else {
                fail("GPT-Live returned an invalid function call."); return
            }
            guard !seenCalls.contains(callID), responses[id]?.failed == false else { return }
            guard seenCalls.count < 4096, toolTasks.count < 16 else { fail("GPT-Live exceeded the tool work limit."); return }
            seenCalls.insert(callID)
            responses[id]?.calls.append(callID)
            let call = GPTLiveFunctionCall(callID: callID, name: name, arguments: arguments)
            let connection = generation
            toolTasks[callID] = Task { [weak self] in
                guard let self, !Task.isCancelled, self.generation == connection, self.state == .connected else { return }
                let result = await self.onToolCall?(call) ?? "{\"error\":\"This function is unavailable. No action was taken.\"}"
                guard !Task.isCancelled, self.generation == connection, self.state == .connected, self.responses[id]?.failed == false else { return }
                self.toolTasks[callID] = nil
                guard result.utf8.count <= 128_000 else { self.fail("The function result exceeds the 128 KB limit."); return }
                self.responses[id]?.results[callID] = result
                await self.continueResponseIfReady(id)
            }
        } else if ["response.completed", "response.failed", "response.incomplete", "response.cancelled"].contains(type) {
            guard responses[id]?.completed == false else { return }
            responses[id]?.completed = true
            let status = response?["status"] as? String
            let failed = type != "response.completed" || (status != nil && status != "completed")
            responses[id]?.failed = failed
            onActivity?("completion", failed ? "Backend response ended without completion." : "Backend response completed (\(responses[id]?.calls.count ?? 0) tool calls).")
            if let usage = response?["usage"] as? [String: Any], !countedUsage.contains(id) {
                countedUsage.insert(id)
                backendTokens += max(0, (usage["total_tokens"] as? NSNumber)?.intValue ?? 0)
                refreshUsage()
                onActivity?("usage", usageSummary)
            }
            if failed {
                for callID in responses[id]?.calls ?? [] { toolTasks.removeValue(forKey: callID)?.cancel() }
                reportError("The GPT-Live backend request did not complete. No automatic retry was made.")
            } else { await continueResponseIfReady(id) }
            refreshBusy()
        }
    }

    private func continueResponseIfReady(_ id: String) async {
        guard state == .connected, let work = responses[id], work.completed, !work.failed,
              !work.continuationSent, !work.calls.isEmpty, work.calls.allSatisfy({ work.results[$0] != nil }) else { return }
        responses[id]?.continuationSent = true
        responses[id]?.continuing = true
        backendBusy = true
        var events: [[String: Any]] = work.calls.map {
            ["type": "response.item.create", "item": ["type": "function_call_output", "call_id": $0, "output": work.results[$0]!]]
        }
        events.append(["type": "response.create"])
        responses[id]?.results.removeAll()
        onActivity?("request", "Returning \(work.calls.count) tool results and continuing the backend response.")
        _ = await enqueue(events)
    }

    private func refreshBusy() {
        backendBusy = state == .connected && responses.values.contains {
            !$0.completed || $0.continuing || (!$0.failed && !$0.calls.isEmpty && !$0.continuationSent)
        }
    }

    private func appendTranscript(id: String, role: String, text: String) {
        guard text.utf8.count <= 64_000 else { fail("GPT-Live returned an oversized transcript fragment."); return }
        if let index = transcript.firstIndex(where: { $0.id == id }) {
            transcript[index].text += text
            if transcript[index].text.utf8.count > 64_000 { transcript[index].text = String(transcript[index].text.suffix(16_000)) }
        } else { transcript.append(GPTLiveTranscriptEntry(id: id, role: role, text: text)) }
        if transcript.count > 200 { transcript.removeFirst(transcript.count - 200) }
    }

    private func updateUsage(_ event: [String: Any], finalized: Bool) {
        if let usage = event["usage"] as? [String: Any], let seconds = usage["seconds"] as? NSNumber {
            voiceSeconds = max(0, seconds.doubleValue)
        }
        refreshUsage(finalized: finalized)
        onActivity?("usage", usageSummary)
    }

    private func refreshUsage(finalized: Bool = false) {
        usageSummary = "Voice \(String(format: "%.1f", voiceSeconds))s · Backend \(backendTokens) tokens" + (finalized ? " · final" : "")
    }

    private static func safeCode(_ code: String) -> String {
        guard !code.localizedCaseInsensitiveContains("sk-"), !code.localizedCaseInsensitiveContains("bearer") else { return "redacted" }
        return String(code.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }.prefix(80))
    }

    static func safeServerError(_ message: String?, code: String) -> String {
        if code.contains("auth") || code.contains("api_key") {
            return "OpenAI rejected the API key. Check the key and project access."
        }
        // API errors can contain submitted credentials or private message content.
        // Show a useful code while keeping arbitrary server text out of UI/logs.
        return "GPT-Live rejected a request (\(safeCode(code))). Check the project access and session configuration."
    }

    private func fail(_ message: String) {
        reportError(message)
        state = .failed
        if !finalizationConfirmed {
            refreshUsage(); usageSummary += " · final usage unconfirmed"
            onActivity?("usage", usageSummary)
        }
        cleanUp()
    }

    private func reportError(_ message: String) {
        error = message
        onActivity?("error", message)
    }

    private func discardQueuedAudio() {
        let discarded = batches.filter { $0.kind == .audio }
        batches.removeAll { $0.kind == .audio }
        queuedBytes = max(0, queuedBytes - discarded.reduce(0) { $0 + $1.bytes })
        discarded.forEach { $0.completion.resume(returning: false) }
    }

    private func discardQueuedBatches() {
        let discarded = batches
        batches.removeAll()
        queuedBytes = max(0, queuedBytes - discarded.reduce(0) { $0 + $1.bytes })
        discarded.forEach { $0.completion.resume(returning: false) }
    }

    private func resumeConnectWaiters() {
        let waiters = connectWaiters
        connectWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func cleanUp() {
        if !toolTasks.isEmpty { onActivity?("cancellation", "Cancelled \(toolTasks.count) pending tool tasks during session cleanup.") }
        deadline?.cancel(); deadline = nil
        receiver?.cancel(); receiver = nil
        sender?.cancel(); sender = nil
        toolTasks.values.forEach { $0.cancel() }
        toolTasks.removeAll()
        responses.removeAll()
        delegationResponses.removeAll()
        discardQueuedBatches()
        queuedBytes = 0
        transport?.cancel(); transport = nil
        pendingAudioByte = Data()
        inputMuted = true
        backendBusy = false
        resumeConnectWaiters()
        let waiters = closeWaiters
        closeWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
