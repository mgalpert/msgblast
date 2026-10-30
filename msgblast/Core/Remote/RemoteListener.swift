import Darwin
import Foundation
import Network
import os
import msgblastRemoteProtocol

/// One bound listener, so tests can stand in for `NWListener`.
@MainActor
protocol RemoteBoundListener: AnyObject { func cancel() }
extension NWListener: RemoteBoundListener {}

public struct RemoteInterfaceAddress: Equatable, Hashable, Sendable {
    public var interface: String
    public var address: String
    public var kind: RemoteEndpointKind
    public init(interface: String, address: String, kind: RemoteEndpointKind) { self.interface = interface; self.address = address; self.kind = kind }
}

/// Candidate addresses: a Tailscale utun with a 100.64.0.0/10 address, or a private
/// (RFC 1918) LAN address on a non-tunnel interface. Never loopback, never a wildcard.
public enum RemoteInterfaces {
    public static func classify(interface: String, ipv4 raw: UInt32) -> RemoteEndpointKind? {
        let tailscale = raw & 0xFFC0_0000 == 0x6440_0000
        let lan = raw & 0xFF00_0000 == 0x0A00_0000 || raw & 0xFFF0_0000 == 0xAC10_0000 || raw & 0xFFFF_0000 == 0xC0A8_0000
        if tailscale && interface.hasPrefix("utun") { return .tailscale }
        if lan && !interface.hasPrefix("utun") && !interface.hasPrefix("lo") && !interface.hasPrefix("bridge") { return .lan }
        return nil
    }

    public static func current() -> [RemoteInterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var result: [RemoteInterfaceAddress] = []
        var cursor = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0, entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            let name = String(cString: entry.pointee.ifa_name)
            guard let kind = classify(interface: name, ipv4: UInt32(bigEndian: ipv4.s_addr)) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(INET_ADDRSTRLEN))
            let text = String(cString: buffer)
            if !result.contains(where: { $0.address == text }) { result.append(RemoteInterfaceAddress(interface: name, address: text, kind: kind)) }
        }
        return result
    }

    public static func select(_ all: [RemoteInterfaceAddress], policy: RemoteBindPolicy) -> [RemoteInterfaceAddress] {
        let tailscale = all.filter { $0.kind == .tailscale }, lan = all.filter { $0.kind == .lan }
        switch policy {
        case .automatic: return tailscale.isEmpty ? lan : tailscale
        case .tailscaleOnly: return tailscale
        case .tailscaleAndLAN: return tailscale + lan
        case .lanOnly: return lan
        }
    }
}

/// A TLS connection accepted by the listener.
@MainActor
final class NetworkRemoteConnection: RemoteConnection {
    var onReceive: ((Data) -> Void)?
    var onClose: (() -> Void)?
    let peer: String
    private let connection: NWConnection
    private var closed = false
    init(_ connection: NWConnection) {
        self.connection = connection
        peer = "\(connection.endpoint)"
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: self?.finish()
                default: break
                }
            }
        }
        connection.start(queue: .main)
        read()
    }
    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty { self.onReceive?(data) }
                if complete || error != nil { self.close() } else { self.read() }
            }
        }
    }
    func send(_ data: Data) {
        guard !closed else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated { if error != nil { self?.close() } }
        })
    }
    /// Flushes queued frames (such as a final error) before cancelling.
    func close() {
        guard !closed else { return }
        let connection = connection
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { connection.cancel() }
        finish()
    }
    private func finish() {
        guard !closed else { return }
        closed = true
        onClose?()
    }
}

/// TLS 1.3 listeners from the Mac identity, one per selected address on one port.
/// Bonjour (`_msgblast._tcp`) is advertised on LAN listeners only, scoped to their interface.
///
/// A paired phone only knows the saved port. When it is busy (for example the previous copy
/// of msgblast is still quitting), the listener keeps trying it for `Retry.savedPortWindow`
/// before using a temporary port, and then keeps trying it in the background and moves
/// back as soon as it is free. The temporary port is never saved.
@MainActor
public final class RemoteListener: ObservableObject {
    struct Retry: Sendable {
        var savedPortWindow: Duration = .seconds(30)
        var savedPortInterval: Duration = .seconds(1)
        var reclaimInterval: Duration = .seconds(5)
        var randomAttempts = 4
    }
    typealias Binder = @MainActor (_ addresses: [RemoteInterfaceAddress], _ port: UInt16) async -> [any RemoteBoundListener]?

    @Published public private(set) var endpoints: [RemoteEndpoint] = []
    @Published public private(set) var port: UInt16?
    @Published public private(set) var error: String?
    /// The saved port while a temporary one is in use; nil once the saved port is bound.
    @Published public private(set) var waitingForPort: UInt16?
    private let identity: RemoteIdentity?
    private let serviceName: String
    private let onConnection: (RemoteConnection) -> Void
    private var listeners: [any RemoteBoundListener] = []
    private var monitor: NWPathMonitor?
    private var interfaces: [NWInterface] = []
    private var policy = RemoteBindPolicy.automatic
    private var bound: [RemoteInterfaceAddress] = []
    private var restart: Task<Void, Never>?
    private var reclaim: Task<Void, Never>?
    private var savedPort: UInt16?
    private var shouldReclaim: @MainActor () -> Bool = { true }
    private let retry: Retry
    private let addresses: @MainActor (RemoteBindPolicy) -> [RemoteInterfaceAddress]
    private var binder: Binder?
    private let randomPort: () -> UInt16
    private let watchesNetwork: Bool
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "msgblast", category: "remote-listener")

    public init(identity: RemoteIdentity, serviceName: String, onConnection: @escaping (RemoteConnection) -> Void) {
        self.identity = identity; self.serviceName = serviceName; self.onConnection = onConnection
        retry = Retry()
        addresses = { RemoteInterfaces.select(RemoteInterfaces.current(), policy: $0) }
        randomPort = { UInt16.random(in: 49_152...65_000) }
        watchesNetwork = true
    }

    /// Tests: an injected bind and address list, no network or path monitor.
    init(retry: Retry, addresses: @escaping @MainActor (RemoteBindPolicy) -> [RemoteInterfaceAddress],
         randomPort: @escaping () -> UInt16, bind: @escaping Binder) {
        identity = nil; serviceName = "test"; onConnection = { _ in }
        self.retry = retry; self.addresses = addresses; self.randomPort = randomPort; binder = bind
        watchesNetwork = false
    }

    public var isListening: Bool { !listeners.isEmpty }

    /// Binds every selected address. Returns the port actually used: the saved port, or a
    /// temporary one after the saved port stayed busy for the retry window. While a temporary
    /// port is in use and `reclaimSavedPort` is true (a phone is paired), the saved port is
    /// retried in the background.
    @discardableResult
    public func start(policy: RemoteBindPolicy, port requested: UInt16?, reclaimSavedPort: @escaping @MainActor () -> Bool = { true }) async -> UInt16? {
        stop()
        self.policy = policy
        savedPort = requested
        shouldReclaim = reclaimSavedPort
        if monitor == nil && watchesNetwork { startMonitor() }
        let selected = addresses(policy)
        guard !selected.isEmpty else {
            error = policy == .tailscaleOnly ? "No Tailscale address on this Mac. Start Tailscale or choose another network option." : "No Tailscale or local network address on this Mac."
            return nil
        }
        if let requested {
            let deadline = ContinuousClock.now + retry.savedPortWindow
            var attempt = 0
            while true {
                attempt += 1
                if let opened = await open(selected, port: requested) {
                    adopt(opened, addresses: selected, port: requested)
                    if attempt > 1 { Self.logger.info("Remote control is listening on saved port \(requested, privacy: .public) after \(attempt, privacy: .public) attempts") }
                    return requested
                }
                guard ContinuousClock.now + retry.savedPortInterval < deadline, !Task.isCancelled else { break }
                try? await Task.sleep(for: retry.savedPortInterval)
            }
            Self.logger.notice("Saved port \(requested, privacy: .public) stayed busy; using a temporary port")
        }
        for _ in 0..<retry.randomAttempts {
            let candidate = randomPort()
            guard let opened = await open(selected, port: candidate) else { continue }
            adopt(opened, addresses: selected, port: candidate)
            if let requested { waitingForPort = requested; startReclaiming(requested) }
            return candidate
        }
        error = "msgblast could not open a port for remote control."
        return nil
    }

    private func adopt(_ opened: [any RemoteBoundListener], addresses selected: [RemoteInterfaceAddress], port: UInt16) {
        listeners = opened
        self.port = port
        bound = selected
        endpoints = selected.map { RemoteEndpoint(host: $0.address, kind: $0.kind, interface: $0.interface) }
        error = nil
        waitingForPort = nil
    }

    /// Opens listeners on every address, or none: a partial bind is cancelled.
    private func open(_ selected: [RemoteInterfaceAddress], port: UInt16) async -> [any RemoteBoundListener]? {
        if let binder { return await binder(selected, port) }
        return await bind(selected, port: port)
    }

    private func startReclaiming(_ saved: UInt16) {
        reclaim?.cancel()
        reclaim = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.retry.reclaimInterval else { return }
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled, self.waitingForPort == saved, self.isListening else { return }
                guard self.shouldReclaim() else { continue }
                let selected = self.bound
                guard let opened = await self.open(selected, port: saved) else { continue }
                guard !Task.isCancelled, self.waitingForPort == saved else { opened.forEach { $0.cancel() }; return }
                let temporary = self.port
                self.listeners.forEach { $0.cancel() }
                self.adopt(opened, addresses: selected, port: saved)
                Self.logger.notice("Remote control moved from temporary port \(temporary ?? 0, privacy: .public) back to saved port \(saved, privacy: .public)")
                return
            }
        }
    }

    public func stop() {
        reclaim?.cancel(); reclaim = nil
        listeners.forEach { $0.cancel() }
        listeners = []
        endpoints = []
        port = nil
        bound = []
        waitingForPort = nil
    }

    public func shutdown() {
        stop()
        restart?.cancel()
        monitor?.cancel(); monitor = nil
    }

    private func startMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.availableInterfaces
            MainActor.assumeIsolated {
                guard let self else { return }
                self.interfaces = available
                // Tailscale or Wi-Fi addresses changed: rebind on the same port.
                guard self.isListening, RemoteInterfaces.select(RemoteInterfaces.current(), policy: self.policy) != self.bound else { return }
                self.restart?.cancel()
                let port = self.savedPort ?? self.port
                self.restart = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, !Task.isCancelled else { return }
                    await self.start(policy: self.policy, port: port, reclaimSavedPort: self.shouldReclaim)
                }
            }
        }
        monitor.start(queue: .main)
        self.monitor = monitor
        interfaces = monitor.currentPath.availableInterfaces
    }

    private func bind(_ addresses: [RemoteInterfaceAddress], port: UInt16) async -> [any RemoteBoundListener]? {
        guard let identity, let nwPort = NWEndpoint.Port(rawValue: port), let tlsIdentity = try? identity.tlsIdentity(),
              let secIdentity = sec_identity_create(tlsIdentity) else { return nil }
        var opened: [NWListener] = []
        func fail() -> [any RemoteBoundListener]? { opened.forEach { $0.cancel() }; return nil }
        for address in addresses {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
            sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
            let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address.address), port: nwPort)
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = false
            if let interface = interfaces.first(where: { $0.name == address.interface }) { parameters.requiredInterface = interface }
            guard let listener = try? NWListener(using: parameters) else { return fail() }
            if address.kind == .lan { listener.service = NWListener.Service(name: serviceName, type: RemoteProtocol.bonjourServiceType) }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.onConnection(NetworkRemoteConnection(connection)) }
            }
            let ready = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                var resumed = false
                listener.stateUpdateHandler = { [weak self] state in
                    MainActor.assumeIsolated {
                        switch state {
                        case .ready: if !resumed { resumed = true; continuation.resume(returning: true) }
                        case .failed(let failure):
                            if !resumed { resumed = true; continuation.resume(returning: false) }
                            else { self?.error = "Remote control stopped listening: \(failure.localizedDescription)" }
                        case .cancelled: if !resumed { resumed = true; continuation.resume(returning: false) }
                        default: break
                        }
                    }
                }
                listener.start(queue: .main)
            }
            opened.append(listener)
            guard ready else { return fail() }
        }
        return opened
    }
}
