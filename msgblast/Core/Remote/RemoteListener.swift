import Darwin
import Foundation
import Network
import msgblastRemoteProtocol

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
    func close() {
        guard !closed else { return }
        connection.cancel()
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
@MainActor
public final class RemoteListener: ObservableObject {
    @Published public private(set) var endpoints: [RemoteEndpoint] = []
    @Published public private(set) var port: UInt16?
    @Published public private(set) var error: String?
    private let identity: RemoteIdentity
    private let serviceName: String
    private let onConnection: (RemoteConnection) -> Void
    private var listeners: [NWListener] = []
    private var monitor: NWPathMonitor?
    private var interfaces: [NWInterface] = []
    private var policy = RemoteBindPolicy.automatic
    private var bound: [RemoteInterfaceAddress] = []
    private var restart: Task<Void, Never>?

    public init(identity: RemoteIdentity, serviceName: String, onConnection: @escaping (RemoteConnection) -> Void) {
        self.identity = identity; self.serviceName = serviceName; self.onConnection = onConnection
    }

    public var isListening: Bool { !listeners.isEmpty }

    /// Binds every selected address. Returns the port actually used (a new one if the saved port is taken).
    @discardableResult
    public func start(policy: RemoteBindPolicy, port requested: UInt16?) async -> UInt16? {
        stop()
        self.policy = policy
        if monitor == nil { startMonitor() }
        let addresses = RemoteInterfaces.select(RemoteInterfaces.current(), policy: policy)
        guard !addresses.isEmpty else {
            error = policy == .tailscaleOnly ? "No Tailscale address on this Mac. Start Tailscale or choose another network option." : "No Tailscale or local network address on this Mac."
            return nil
        }
        var candidates = requested.map { [$0] } ?? []
        candidates += (0..<4).map { _ in UInt16.random(in: 49_152...65_000) }
        for candidate in candidates {
            if await bind(addresses, port: candidate) {
                port = candidate
                bound = addresses
                endpoints = addresses.map { RemoteEndpoint(host: $0.address, kind: $0.kind, interface: $0.interface) }
                error = nil
                return candidate
            }
            stop()
        }
        error = "msgblast could not open a port for remote control."
        return nil
    }

    public func stop() {
        listeners.forEach { $0.cancel() }
        listeners = []
        endpoints = []
        port = nil
        bound = []
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
                let port = self.port
                self.restart = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, !Task.isCancelled else { return }
                    await self.start(policy: self.policy, port: port)
                }
            }
        }
        monitor.start(queue: .main)
        self.monitor = monitor
        interfaces = monitor.currentPath.availableInterfaces
    }

    private func bind(_ addresses: [RemoteInterfaceAddress], port: UInt16) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port), let tlsIdentity = try? identity.tlsIdentity(), let secIdentity = sec_identity_create(tlsIdentity) else { return false }
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
            guard let listener = try? NWListener(using: parameters) else { return false }
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
            listeners.append(listener)
            guard ready else { return false }
        }
        return true
    }
}
