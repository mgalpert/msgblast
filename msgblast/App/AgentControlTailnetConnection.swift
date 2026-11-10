import Foundation
import Network
import msgblastCore

/// `tailscale status --json` → `Self.DNSName`, without the trailing dot. Missing or slow is ignored.
enum AgentControlTailnetDNS {
    nonisolated static func magicName() -> String? {
        let candidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["status", "--json"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let node = root["Self"] as? [String: Any], var name = node["DNSName"] as? String else { return nil }
        if name.hasSuffix(".") { name.removeLast() }
        return name.isEmpty ? nil : name
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

/// One keep-alive connection. Idle for 60 seconds with no bytes closes it.
@MainActor final class AgentControlTailnetLink {
    private let connection: NWConnection
    private let peer: String
    private weak var owner: AgentControlTailnetListener?
    private var buffer = Data()
    private var idle: Task<Void, Never>?
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

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, failure in
            Task { @MainActor in
                guard let self, self.open else { return }
                self.idle?.cancel()
                guard failure == nil else { self.close(); return }
                if let data { self.buffer.append(data) }
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
