import Foundation
import Network
import msgblastCore

/// HTTP MCP on this Mac's Tailscale addresses, for Grok Bot. Nothing listens unless Outside agents is on and the person turns this on.
@MainActor final class AgentControlTailnetListener: ObservableObject {
    @Published private var store: AgentControlTailnetStore
    @Published private(set) var plaintext: String?
    @Published private(set) var error: String?
    @Published private var addresses: [String] = []
    @Published private var magicName: String?

    private let file: URL
    private let gate: AgentControlGate
    private weak var host: AppModel?
    private var localOn = false
    private var endpoint: AgentControlHTTPEndpoint?
    private var endpointHashes: [String: String] = [:]
    private var monitor: NWPathMonitor?
    private var listeners: [NWListener] = []
    private var links: [AgentControlTailnetLink] = []
    private var bound: [String] = []

    init(directory: URL, gate: AgentControlGate, host: AppModel?) {
        let location = directory.appendingPathComponent(AgentControlTailnetStore.fileName)
        file = location
        self.gate = gate
        self.host = host
        let loaded = AgentControlTailnetStore.load(location)
        store = loaded
        if loaded.loadFailed { error = "Saved Tailscale settings could not be read, so Grok Bot stays off." }
    }

    var loadFailed: Bool { store.loadFailed }

    var enabled: Bool {
        get { store.enabled && !store.loadFailed }
        set {
            guard !store.loadFailed, localOn || !newValue else { return }
            let previous = store
            let previousPlain = plaintext
            if newValue {
                if store.hashes[AgentControlTailnet.grokBotClient] == nil {
                    guard let issued = store.issue(AgentControlTailnet.grokBotClient) else { return }
                    plaintext = issued
                }
                store.enabled = true
            } else {
                store.enabled = false
            }
            persist(previous: previous, previousPlain: previousPlain) {
                if newValue { listen() } else { stopSockets(); error = nil }
            }
        }
    }

    /// `http://<MagicDNS>:<port>/mcp`. The first 100.x address when the name is missing.
    var serverURL: String? {
        guard store.enabled, !addresses.isEmpty else { return nil }
        if let name = magicName, !name.isEmpty { return hostURL(name) }
        guard let address = addresses.first(where: { !$0.contains(":") }) else { return nil }
        return hostURL(address)
    }

    /// True when the URL had to use a 100.x address because MagicDNS had no name.
    var showsAddressFallback: Bool { serverURL != nil && (magicName ?? "").isEmpty }

    var authorizationHeader: String? { plaintext.map { "Authorization: Bearer \($0)" } }

    /// Path token, only while the plaintext is still in memory.
    var pathURL: String? {
        guard let serverURL, let plaintext else { return nil }
        return "\(serverURL)/\(plaintext)"
    }

    func rotateToken() {
        guard store.enabled, !store.loadFailed else { return }
        let previous = store
        let previousPlain = plaintext
        guard let issued = store.issue(AgentControlTailnet.grokBotClient) else { return }
        plaintext = issued
        rebuild(previous: previous, previousPlain: previousPlain)
    }

    /// Drops the saved hash for `client`. Removing the agent in Settings calls this.
    func revoke(_ client: String) {
        guard !store.loadFailed, store.hashes[client] != nil else { return }
        let previous = store
        let previousPlain = plaintext
        store.revoke(client)
        if client == AgentControlTailnet.grokBotClient { plaintext = nil }
        rebuild(previous: previous, previousPlain: previousPlain)
    }

    /// The local Outside agents socket turned on or off. This listens only while that is on.
    func noteLocal(_ on: Bool) {
        localOn = on
        guard !store.loadFailed else { return }
        if on, store.enabled { listen() } else { stopSockets() }
    }

    private func hostURL(_ name: String) -> String {
        let host = name.contains(":") ? "[\(name)]" : name
        return "http://\(host):\(store.port)/mcp"
    }

    private func persist(previous: AgentControlTailnetStore, previousPlain: String?, then: () -> Void) {
        do { try store.save(file) } catch {
            store = previous
            plaintext = previousPlain
            self.error = error.localizedDescription
            return
        }
        then()
    }

    private func rebuild(previous: AgentControlTailnetStore, previousPlain: String?) {
        persist(previous: previous, previousPlain: previousPlain) {
            error = nil
            endpoint = nil
            endpointHashes = [:]
            if localOn, store.enabled { listen() }
        }
    }

    private func listen() {
        guard localOn, store.enabled, !store.loadFailed else { return }
        if endpoint == nil || endpointHashes != store.hashes {
            endpoint = makeEndpoint()
            endpointHashes = store.hashes
        }
        if monitor == nil {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] _ in Task { @MainActor in self?.rebind() } }
            monitor.start(queue: .main)
            self.monitor = monitor
        }
        rebind()
    }

    private func rebind() {
        guard localOn, store.enabled, !store.loadFailed else { return }
        let found = AgentControlTailnet.tailnetAddresses().sorted()
        addresses = found
        guard !found.isEmpty else {
            error = "Tailscale isn't connected on this Mac."
            cancelListeners()
            closeLinks()
            bound = []
            return
        }
        if found == bound, listeners.count == found.count, error == nil { return }
        refreshMagicDNS()
        cancelListeners()
        // A connection on an address this Mac no longer has would never be closed otherwise.
        if found != bound { closeLinks() }
        guard let port = NWEndpoint.Port(rawValue: UInt16(store.port)) else {
            error = "Could not listen on port \(store.port)."
            return
        }
        let failure = bind(found, port: port)
        bound = found
        if listeners.count == found.count { error = nil } else { self.error = failure ?? "Could not listen on the Tailscale address." }
    }

    /// Starts a listener on each Tailscale address. Returns the last error, if any.
    private func bind(_ found: [String], port: NWEndpoint.Port) -> String? {
        var failure: String?
        for address in found {
            guard AgentControlTailnet.isTailnetPeer(address) else { continue }
            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: port)
                let listener = try NWListener(using: parameters)
                listener.stateUpdateHandler = { [weak self] update in
                    Task { @MainActor in
                        if case .failed(let reason) = update { self?.error = reason.localizedDescription }
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor in self?.accept(connection) }
                }
                listener.start(queue: .main)
                listeners.append(listener)
            } catch {
                failure = error.localizedDescription
            }
        }
        return failure
    }

    private func stopSockets() {
        monitor?.cancel()
        monitor = nil
        cancelListeners()
        closeLinks()
        endpoint = nil
        endpointHashes = [:]
        bound = []
        addresses = []
    }

    private func cancelListeners() {
        listeners.forEach { $0.cancel() }
        listeners = []
    }

    private func closeLinks() {
        let open = links
        links = []
        open.forEach { $0.close() }
    }

    private func accept(_ connection: NWConnection) {
        let link = AgentControlTailnetLink(connection: connection, peer: AgentControlTailnetConnection.peer(connection), owner: self)
        links.append(link)
        link.start()
    }

    func drop(_ link: AgentControlTailnetLink) { links.removeAll { $0 === link } }

    func respond(_ request: AgentControlHTTPRequest, peer: String) async -> AgentControlHTTPResponse {
        guard let endpoint else { return AgentControlHTTPResponse(status: 503, headers: [], body: Data()) }
        return await endpoint.handle(request, peer: peer)
    }

    private func makeEndpoint() -> AgentControlHTTPEndpoint {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let bridge = AgentControlTailnetBridge(self)
        return AgentControlHTTPEndpoint(hashes: store.hashes, version: version) { try await bridge.exchange($0) }
    }

    func reply(_ line: Data) async throws -> Data {
        guard let host else { throw CocoaError(.fileReadNoSuchFile) }
        return await AgentControlWire.respond(to: line, host: host, gate: gate, approve: { await approveOutsideAgent($0, overTailscale: true) })
    }

    private func refreshMagicDNS() {
        Task { @MainActor in
            let name = await Task.detached(priority: .utility) { AgentControlTailnetDNS.magicName() }.value
            self.magicName = name
        }
    }
}
