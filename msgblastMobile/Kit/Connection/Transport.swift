import Foundation
import Network
import Security
import msgblastRemoteProtocol

public enum ClientTransportState: Equatable, Sendable {
    case ready
    case failed(String)
    case closed
}

/// A byte stream to the Mac. TLS on direct routes, memory in tests.
@MainActor
public protocol ClientTransport: AnyObject {
    var onReceive: ((Data) -> Void)? { get set }
    var onState: ((ClientTransportState) -> Void)? { get set }
    var label: String { get }
    func start()
    func send(_ data: Data)
    func cancel()
}

/// Where to reach a Mac: an address from the QR code or a Bonjour service on the LAN.
public enum MacEndpoint: Hashable, Sendable {
    case host(String, port: UInt16)
    case bonjour(name: String, type: String, domain: String)
    public var label: String {
        switch self {
        case .host(let host, let port): "\(host):\(port)"
        case .bonjour(let name, _, _): name
        }
    }
    var nwEndpoint: NWEndpoint {
        switch self {
        case .host(let host, let port): .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any)
        case .bonjour(let name, let type, let domain): .service(name: name, type: type, domain: domain, interface: nil)
        }
    }
}

/// TLS 1.3 to the Mac, accepting only the certificate whose SubjectPublicKeyInfo hash
/// matches the one pinned at pairing. No CA, no hostname check.
@MainActor
public final class NetworkClientTransport: ClientTransport {
    public var onReceive: ((Data) -> Void)?
    public var onState: ((ClientTransportState) -> Void)?
    public let label: String
    private let connection: NWConnection
    private var finished = false

    public init(endpoint: MacEndpoint, pinnedSPKI: Data) {
        label = endpoint.label
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let reference = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let leaf = (SecTrustCopyCertificateChain(reference) as? [SecCertificate])?.first, let key = SecCertificateCopyKey(leaf),
                  let x963 = SecKeyCopyExternalRepresentation(key, nil) as Data? else { complete(false); return }
            complete(RemoteTLSPin.spkiSHA256(p256X963: x963) == pinnedSPKI)
        }, .main)
        let parameters = NWParameters(tls: tls)
        parameters.includePeerToPeer = false
        connection = NWConnection(to: endpoint.nwEndpoint, using: parameters)
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready: self.onState?(.ready); self.read()
                case .failed(let error): self.finish(.failed(error.localizedDescription))
                case .waiting(let error): self.finish(.failed(error.localizedDescription))
                case .cancelled: self.finish(.closed)
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }
    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, !self.finished else { return }
                if let data, !data.isEmpty { self.onReceive?(data) }
                if complete || error != nil { self.finish(.closed) } else { self.read() }
            }
        }
    }
    public func send(_ data: Data) {
        guard !finished else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
    public func cancel() {
        guard !finished else { return }
        finished = true
        connection.cancel()
    }
    private func finish(_ state: ClientTransportState) {
        guard !finished else { return }
        finished = true
        connection.cancel()
        onState?(state)
    }
}

/// Tries every candidate at once and keeps the first that completes TLS with the pinned key.
@MainActor
public final class EndpointRacer {
    private var contenders: [ClientTransport] = []
    private var winner: ClientTransport?
    private var failures: [String] = []

    public init() {}

    public func race(_ endpoints: [MacEndpoint], make: (MacEndpoint) -> ClientTransport, completion: @escaping (Result<ClientTransport, RaceFailure>) -> Void) {
        cancel()
        guard !endpoints.isEmpty else { completion(.failure(RaceFailure(reasons: ["No address for this Mac."]))); return }
        var remaining = endpoints.count
        for endpoint in endpoints {
            let transport = make(endpoint)
            contenders.append(transport)
            transport.onState = { [weak self, weak transport] state in
                guard let self, let transport else { return }
                switch state {
                case .ready:
                    guard self.winner == nil else { transport.cancel(); return }
                    self.winner = transport
                    transport.onState = nil
                    for other in self.contenders where other !== transport { other.onState = nil; other.cancel() }
                    self.contenders = []
                    completion(.success(transport))
                case .failed, .closed:
                    guard self.winner == nil else { return }
                    if case .failed(let reason) = state { self.failures.append("\(transport.label): \(reason)") }
                    remaining -= 1
                    if remaining == 0 { self.contenders = []; completion(.failure(RaceFailure(reasons: self.failures))) }
                }
            }
            transport.start()
        }
    }

    public func cancel() {
        for contender in contenders { contender.onState = nil; contender.cancel() }
        contenders = []
        winner = nil
        failures = []
    }
}

public struct RaceFailure: Error, Equatable, Sendable {
    public var reasons: [String]
}
