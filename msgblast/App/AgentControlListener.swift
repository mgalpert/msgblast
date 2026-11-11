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
    /// Accepted connections, closed when Outside agents is switched off.
    private let sessions: AgentControlSessions<NWConnection>
    lazy var tailnet = AgentControlTailnetListener(directory: socket.deletingLastPathComponent(), gate: gate, host: host)
    private var observer: Timer?

    init(directory: URL, host: AppModel) {
        socket = directory.appendingPathComponent("agent-control.sock")
        gate = AgentControlGate(file: directory.appendingPathComponent("outside-agents.json"))
        self.host = host
        sessions = AgentControlSessions { $0.cancel() }
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
            sessions.open()
            startObserving()
            error = gate.loadFailed ? "Saved outside-agent approvals could not be read, so every agent is refused." : nil
            tailnet.noteLocal(true)
        } catch { self.error = error.localizedDescription }
    }

    /// Looks at the app once a second so `msgblast_blast_wait` wakes on replies, send
    /// results and busy changes.
    private func startObserving() {
        host?.controlEvents.resetObservation()
        observer?.invalidate()
        observer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let host = self?.host else { return }
                host.controlEvents.observe(host.controlSnapshot())
            }
        }
        if let host { host.controlEvents.observe(host.controlSnapshot()) }
    }

    private func stop() {
        observer?.invalidate()
        observer = nil
        listener?.cancel()
        listener = nil
        sessions.close()
        try? FileManager.default.removeItem(at: socket)
        tailnet.noteLocal(false)
    }

    private func serve(_ connection: NWConnection) {
        guard sessions.add(connection) else { return }
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, failure in
            Task { @MainActor in
                guard let self else { return connection.cancel() }
                guard failure == nil, self.sessions.isOpen else { return self.sessions.drop(connection) }
                let pending = buffer + (data ?? Data())
                guard pending.count <= 1_048_576 else { return self.sessions.drop(connection) }
                // One pass over the bytes, so a buffer of many short lines stays linear.
                var start = pending.startIndex
                while let end = pending[start...].firstIndex(of: 0x0A) {
                    let line = Data(pending[start..<end])
                    start = pending.index(after: end)
                    guard self.sessions.begin(connection) else { return }
                    Task { @MainActor in await self.answer(line, on: connection) }
                }
                if complete { self.sessions.end(connection) } else { self.receive(connection, buffer: Data(pending[start...])) }
            }
        }
    }

    /// Answers one request. Nothing is answered once Outside agents is off, even a request that was
    /// already running when it was switched off.
    private func answer(_ line: Data, on connection: NWConnection) async {
        guard sessions.contains(connection) else { return }
        guard let host else { return sessions.drop(connection) }
        let reply = await AgentControlWire.respond(to: line, host: host, gate: gate, approve: { await approveOutsideAgent($0) },
                                                   isLive: { sessions.contains(connection) })
        guard sessions.contains(connection) else { return }
        connection.send(content: reply, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.sessions.finish(connection) }
        })
    }
}
