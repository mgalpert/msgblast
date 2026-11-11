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
    @Published private var httpsEnabled = false
    @Published private var grokBotPeer = false
    @Published private var firewall: AgentControlFirewall.State?
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
                if newValue { listen() } else { stopSockets(); error = nil; firewall = nil }
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

    /// The setup block, only while the plaintext key and a server URL are both in memory.
    var setupText: String? {
        guard let serverURL, let plaintext else { return nil }
        return AgentControlTailnetSetup.text(url: serverURL, key: plaintext)
    }

    var readiness: [String] {
        var lines = AgentControlTailnetSetup.lines(magicName: magicName, httpsEnabled: httpsEnabled, grokBotPeer: grokBotPeer, lastCalled: lastCalled)
        if enabled, let firewall, let line = AgentControlFirewall.line(firewall) {
            lines.insert(line, at: 1)
        }
        return lines
    }

    func rotateToken() {
        guard store.enabled, !store.loadFailed else { return }
        let previous = store
        let previousPlain = plaintext
        guard let issued = store.issue(AgentControlTailnet.grokBotClient) else { return }
        plaintext = issued
        lastCalled = nil
        rebuild(previous: previous, previousPlain: previousPlain)
    }

    /// Drops the saved hash for `client`. Removing the agent in Settings calls this.
    func revoke(_ client: String) {
        guard !store.loadFailed, store.hashes[client] != nil else { return }
        let previous = store
        let previousPlain = plaintext
        store.revoke(client)
        if client == AgentControlTailnet.grokBotClient { plaintext = nil; lastCalled = nil }
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

    /// Runs one request. A request still waiting when the endpoint is switched off or rebuilt for a
    /// new key runs nothing.
    func reply(_ line: Data) async throws -> Data {
        guard let host, let current = endpoint else { throw CocoaError(.fileReadNoSuchFile) }
        return await AgentControlWire.respond(to: line, host: host, gate: gate, approve: { await approveOutsideAgent($0, overTailscale: true) },
                                              isLive: { endpoint === current })
    }

    /// Status when the card appears and when the network changes. At most one fetch every 30 seconds.
    /// A Tailscale toggle that is on with no firewall reading yet fetches immediately. The firewall
    /// queries run only then, and they are read-only.
    func refreshStatus() {
        if statusTask != nil { statusQueued = true; return }
        let now = Date()
        let firewallPending = enabled && firewall == nil
        if !firewallPending, let lastStatusAt, now.timeIntervalSince(lastStatusAt) < 30 {
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
        let includeFirewall = enabled
        let appPath = Bundle.main.bundlePath
        statusTask = Task { @MainActor [weak self] in
            let parsed = await Task.detached(priority: .utility) {
                (AgentControlTailnetDNS.fetch(), includeFirewall ? AgentControlTailnetDNS.firewall(appPath: appPath) : nil)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.magicName = parsed.0?.magicName
            self.httpsEnabled = parsed.0?.httpsEnabled ?? false
            self.grokBotPeer = parsed.0?.grokBotPeer ?? false
            if includeFirewall, self.enabled { self.firewall = parsed.1 }
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
