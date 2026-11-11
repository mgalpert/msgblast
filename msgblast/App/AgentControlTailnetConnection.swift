import Foundation
import Network
import msgblastCore

/// One `tailscale status --json` run. Failures return nil and are ignored.
enum AgentControlTailnetDNS {
    nonisolated static func fetch() -> (magicName: String?, httpsEnabled: Bool, grokBotPeer: Bool)? {
        let candidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["status", "--json"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // A stuck tailscale is stopped after 5 seconds, which ends the read below.
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { process.terminate() } }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, data.count <= 8_388_608 else { return nil }
        return AgentControlTailnetStatus.parse(data)
    }
}

enum AgentControlTailnetConnection {
    /// The remote address, without an interface zone.
    static func peer(_ connection: NWConnection) -> String {
        guard case .hostPort(let host, _) = connection.endpoint else { return "" }
        let text: String
        switch host {
        case .ipv4(let address): text = "\(address)"
        case .ipv6(let address): text = "\(address)"
        case .name(let name, _): text = name
        @unknown default: text = "\(host)"
        }
        guard let zone = text.firstIndex(of: "%") else { return text }
        return String(text[..<zone])
    }
}

/// Holds the listener for the endpoint actor without crossing the main actor unsafely.
final class AgentControlTailnetBridge: @unchecked Sendable {
    private weak var owner: AgentControlTailnetListener?
    init(_ owner: AgentControlTailnetListener) { self.owner = owner }
    func exchange(_ line: Data) async throws -> Data {
        try await Task { @MainActor [weak self] in
            guard let owner = self?.owner else { throw CocoaError(.fileReadNoSuchFile) }
            return try await owner.reply(line)
        }.value
    }
}

/// One keep-alive connection. Idle for 60 seconds with no bytes closes it, and a request
/// that has started must arrive whole within 10 seconds.
@MainActor final class AgentControlTailnetLink {
    static let requestDeadline: Duration = .seconds(10)
    private let connection: NWConnection
    private let peer: String
    private weak var owner: AgentControlTailnetListener?
    private var buffer = Data()
    private var idle: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var open = true

    init(connection: NWConnection, peer: String, owner: AgentControlTailnetListener) {
        self.connection = connection
        self.peer = peer
        self.owner = owner
    }

    func start() {
        connection.start(queue: .main)
        arm()
        read()
    }

    func close() {
        guard open else { return }
        open = false
        idle?.cancel()
        deadline?.cancel()
        connection.cancel()
        owner?.drop(self)
    }

    private func arm() {
        idle?.cancel()
        idle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    /// Slow senders can't hold a connection by trickling bytes under the idle limit.
    private func startDeadline() {
        deadline?.cancel()
        deadline = Task { [weak self] in
            try? await Task.sleep(for: Self.requestDeadline)
            guard !Task.isCancelled else { return }
            await self?.fail(408, "request timeout")
        }
    }

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, failure in
            Task { @MainActor in
                guard let self, self.open else { return }
                self.idle?.cancel()
                guard failure == nil else { self.close(); return }
                if let data, !data.isEmpty {
                    if self.buffer.isEmpty { self.startDeadline() }
                    self.buffer.append(data)
                }
                await self.drain(closed: complete)
            }
        }
    }

    private func drain(closed: Bool) async {
        while open {
            switch AgentControlHTTPRequest.parse(buffer) {
            case .incomplete:
                if closed { close() } else { arm(); read() }
                return
            case .invalid:
                await fail(400, "bad request")
                return
            case .tooLarge:
                await fail(413, "too large")
                return
            case .complete(let request, let consumed):
                guard consumed > 0 else { close(); return }
                buffer.removeFirst(consumed)
                deadline?.cancel()
                if !buffer.isEmpty { startDeadline() }
                let response = await owner?.respond(request, peer: peer) ?? AgentControlHTTPResponse(status: 503, headers: [], body: Data())
                await send(response)
                if response.status >= 400 { close(); return }
            }
        }
    }

    private func fail(_ status: Int, _ message: String) async {
        let body = Data("{\"error\":\"\(message)\"}".utf8)
        await send(AgentControlHTTPResponse(status: status, headers: [("Content-Type", "application/json")], body: body))
        close()
    }

    private func send(_ response: AgentControlHTTPResponse) async {
        let bytes = response.encoded()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: bytes, completion: .contentProcessed { _ in continuation.resume() })
        }
    }
}
