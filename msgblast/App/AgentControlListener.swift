import Foundation
import Network
import msgblastCore

/// The local socket outside agents on this Mac reach msgblast through (`msgblast` CLI, `msgblast mcp`).
/// It lives in this build's support folder, so Dev, Demo and production never share one.
@MainActor final class AgentControlListener: ObservableObject {
    static let enabledKey = "agentControlEnabled"
    let socket: URL
    let gate: AgentControlGate
    @Published private(set) var error: String?
    private weak var host: AppModel?
    private var listener: NWListener?
    lazy var tailnet = AgentControlTailnetListener(directory: socket.deletingLastPathComponent(), gate: gate, host: host)

    init(directory: URL, host: AppModel) {
        socket = directory.appendingPathComponent("agent-control.sock")
        gate = AgentControlGate(file: directory.appendingPathComponent("outside-agents.json"))
        self.host = host
        if UserDefaults.standard.bool(forKey: Self.enabledKey) { start() }
    }

    var enabled: Bool {
        get { listener != nil }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            newValue ? start() : stop()
            objectWillChange.send()
        }
    }

    private func start() {
        guard listener == nil else { return }
        try? FileManager.default.removeItem(at: socket)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: socket.path)
        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.serve(connection) } }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    if case .ready = state {
                        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.socket.path)
                    }
                    if case .failed(let failure) = state { self.error = failure.localizedDescription; self.stop() }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            error = gate.loadFailed ? "Saved outside-agent approvals could not be read, so every agent is refused." : nil
            tailnet.noteLocal(true)
        } catch { self.error = error.localizedDescription }
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        try? FileManager.default.removeItem(at: socket)
        tailnet.noteLocal(false)
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, failure in
            Task { @MainActor in
                guard let self, failure == nil else { return connection.cancel() }
                var pending = buffer + (data ?? Data())
                guard pending.count <= 1_048_576 else { return connection.cancel() }
                while let end = pending.firstIndex(of: 0x0A) {
                    let line = pending[pending.startIndex..<end]
                    pending = Data(pending[pending.index(after: end)...])
                    Task { @MainActor in await self.answer(Data(line), on: connection) }
                }
                if !complete { self.receive(connection, buffer: pending) }
            }
        }
    }

    private func answer(_ line: Data, on connection: NWConnection) async {
        guard let host else { return }
        let reply = await AgentControlWire.respond(to: line, host: host, gate: gate, approve: { await approveOutsideAgent($0) })
        connection.send(content: reply, completion: .contentProcessed { _ in })
    }
}
