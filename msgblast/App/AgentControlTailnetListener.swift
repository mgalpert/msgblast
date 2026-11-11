import Foundation
import Network
import msgblastCore

/// HTTP MCP on this Mac's Tailscale addresses, for Grok Bot and any other MCP client on the tailnet, each with its own key. Nothing listens unless Outside agents is on and the person turns this on.
@MainActor final class AgentControlTailnetListener: ObservableObject {
    @Published private var store: AgentControlTailnetStore
    /// Keys shown once, by client, while msgblast runs. Only hashes are saved.
    @Published private(set) var keys: [String: String] = [:]
    @Published private(set) var error: String?
    @Published private var addresses: [String] = []
    @Published private var magicName: String?
    @Published private var httpsEnabled = false
    @Published private var grokBotPeer = false
    @Published private(set) var lastCalled: Date?

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
    private var lastStatusAt: Date?
    private var statusTask: Task<Void, Never>?
    private var statusQueued = false

    init(directory: URL, gate: AgentControlGate, host: AppModel?) {
        let location = directory.appendingPathComponent(AgentControlTailnetStore.fileName)
        file = location
        self.gate = gate
        self.host = host
        let loaded = AgentControlTailnetStore.load(location)
        store = loaded
        if loaded.loadFailed { error = "Saved Tailscale settings could not be read, so agents over Tailscale stay off." }
    }

    var loadFailed: Bool { store.loadFailed }

    var enabled: Bool {
        get { store.enabled && !store.loadFailed }
        set {
            guard !store.loadFailed, localOn || !newValue else { return }
            let previous = store
            let previousPlain = keys
            if newValue {
                if store.hashes.isEmpty {
                    guard let issued = store.issue(AgentControlTailnet.grokBotClient) else { return }
                    keys[AgentControlTailnet.grokBotClient] = issued
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

    /// Every agent with a Tailscale key, by name.
    var clients: [String] { store.hashes.keys.sorted() }

    func authorizationHeader(for client: String) -> String? { keys[client].map { "Authorization: Bearer \($0)" } }

    /// Path token, only while the plaintext is still in memory.
    func pathURL(for client: String) -> String? {
        guard let serverURL, let key = keys[client] else { return nil }
        return "\(serverURL)/\(key)"
    }

    /// The setup block, only while the plaintext key and a server URL are both in memory.
    func setupText(for client: String) -> String? {
        guard let serverURL, let key = keys[client] else { return nil }
        return AgentControlTailnetSetup.text(url: serverURL, key: key, client: client)
    }

    /// Tailscale and certificates; the Grok Bot line only while Grok Bot has a key.
    var readiness: [String] {
        let lines = AgentControlTailnetSetup.lines(magicName: magicName, httpsEnabled: httpsEnabled, grokBotPeer: grokBotPeer, lastCalled: lastCalled)
        return store.hashes[AgentControlTailnet.grokBotClient] == nil ? Array(lines.prefix(2)) : lines
    }

    /// Adds an agent with its own key. Returns a message when the name can't be used.
    func add(_ typed: String) -> String? {
        guard store.enabled, !store.loadFailed else { return "Turn on Tailscale access first." }
        guard let client = AgentControlTailnet.remoteClientName(typed) else {
            return "Use a name of 1 to \(AgentControlTailnet.maximumClientName) characters."
        }
        guard store.hashes[client] == nil else { return "\(client) already has a key." }
        rotateToken(client)
        return nil
    }

    func rotateToken(_ client: String = AgentControlTailnet.grokBotClient) {
        guard store.enabled, !store.loadFailed else { return }
        let previous = store
        let previousPlain = keys
        guard let issued = store.issue(client) else { return }
        keys[client] = issued
        if client == AgentControlTailnet.grokBotClient { lastCalled = nil }
        rebuild(previous: previous, previousPlain: previousPlain)
    }

    /// Drops the saved hash for `client`. Removing the agent in Settings calls this.
    func revoke(_ client: String) {
        guard !store.loadFailed, store.hashes[client] != nil else { return }
        let previous = store
        let previousPlain = keys
        store.revoke(client)
        keys[client] = nil
        if client == AgentControlTailnet.grokBotClient { lastCalled = nil }
        rebuild(previous: previous, previousPlain: previousPlain)
    }

    /// Removes the key and any approval, so the agent must be added and approved again.
    func remove(_ client: String) {
        revoke(client)
        gate.change(nil, for: client)
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

    private func persist(previous: AgentControlTailnetStore, previousPlain: [String: String], then: () -> Void) {
        do { try store.save(file) } catch {
            store = previous
            keys = previousPlain
            self.error = error.localizedDescription
            return
        }
        then()
    }

    private func rebuild(previous: AgentControlTailnetStore, previousPlain: [String: String]) {
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
        observeNetwork()
        refreshStatus()
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
        cancelListeners()
        monitor?.cancel()
        monitor = nil
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

    /// Open connections at once. Grok Bot needs a few; more are refused.
    static let maximumLinks = 16

    private func accept(_ connection: NWConnection) {
        let peer = AgentControlTailnetConnection.peer(connection)
        guard links.count < Self.maximumLinks, AgentControlTailnet.isTailnetPeer(peer) else { connection.cancel(); return }
        let link = AgentControlTailnetLink(connection: connection, peer: peer, owner: self)
        links.append(link)
        link.start()
    }

    func drop(_ link: AgentControlTailnetLink) { links.removeAll { $0 === link } }

    func respond(_ request: AgentControlHTTPRequest, peer: String) async -> AgentControlHTTPResponse {
        guard let endpoint else { return AgentControlHTTPResponse(status: 503, headers: [], body: Data()) }
        let response = await endpoint.handle(request, peer: peer)
        if let when = await endpoint.lastAuthorized, when != lastCalled { lastCalled = when }
        return response
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

    /// Status when the card appears and when the network changes. At most one fetch every 30 seconds.
    func refreshStatus() {
        if statusTask != nil { statusQueued = true; return }
        let now = Date()
        if let lastStatusAt, now.timeIntervalSince(lastStatusAt) < 30 {
            statusQueued = true
            let wait = 30 - now.timeIntervalSince(lastStatusAt)
            statusTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard let self, !Task.isCancelled else { return }
                self.statusTask = nil
                let queued = self.statusQueued
                self.statusQueued = false
                if queued { self.refreshStatus() }
            }
            return
        }
        lastStatusAt = now
        statusTask = Task { @MainActor [weak self] in
            let parsed = await Task.detached(priority: .utility) { AgentControlTailnetDNS.fetch() }.value
            guard let self, !Task.isCancelled else { return }
            self.magicName = parsed?.magicName
            self.httpsEnabled = parsed?.httpsEnabled ?? false
            self.grokBotPeer = parsed?.grokBotPeer ?? false
            self.statusTask = nil
            let queued = self.statusQueued
            self.statusQueued = false
            if queued { self.refreshStatus() }
        }
    }

    private func observeNetwork() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                self?.rebind()
                self?.refreshStatus()
            }
        }
        monitor.start(queue: .main)
        self.monitor = monitor
    }
}
