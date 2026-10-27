import CryptoKit
import Foundation
import msgblastRemoteProtocol
@testable import msgblastMobileKit

/// A minimal Mac for tests, built only from the shared protocol pieces.
@MainActor
final class FakeMac {
    let identity = P256.Signing.PrivateKey()
    var code = "fake-code"
    var deviceKey: Data?
    var deviceID = UUID()
    var snapshot: RemoteSnapshot
    var commands: [RemoteCommand] = []
    var answerCommands = true
    var lockedOnConnect = false
    var forgetOnResume = false
    private(set) var connections = 0
    init() {
        let status = MacStatus(macName: "Fake Mac", variant: .demo, locked: false, awake: true, databaseAvailable: true, databaseStatus: "ok", messagesBusy: false, broadcastBusy: false,
                               sendingAgentIDs: [], keepAwakeEnabled: true, keepAwakeHeld: false, messagesSendsAllowed: false, observedAt: Date(timeIntervalSince1970: 1))
        snapshot = RemoteSnapshot(seq: 10, macStatus: status, grid: RemoteGrid(visibleAgentIDs: []), agents: [], conversations: [], turns: [], attempts: [])
    }
    var spki: Data { RemoteTLSPin.spkiSHA256(p256X963: identity.publicKey.x963Representation) }
    func offer(expires: Date = Date().addingTimeInterval(120)) -> RemotePairingOffer {
        RemotePairingOffer(macName: "Fake Mac", variant: .demo, endpoints: [RemoteEndpoint(host: "100.64.0.1", kind: .tailscale), RemoteEndpoint(host: "192.168.1.2", kind: .lan)],
                           port: 4000, spkiSHA256: spki, identityKeySHA256: RemoteHandshake.keyHash(identity.publicKey.x963Representation), code: code, expiresAt: expires)
    }

    /// One server-side session over a test transport.
    @MainActor final class Session {
        // Weak: reconnect tasks from a finished test may still deliver bytes.
        weak var mac: FakeMac?
        let transport: TestTransport
        var decoder = RemoteFrameDecoder()
        var channel: RemoteSecureChannel?
        var challenge = Data()
        var sinceSeq: UInt64?
        init(mac: FakeMac, transport: TestTransport) { self.mac = mac; self.transport = transport }
        func send(_ message: RemoteMessage) {
            guard var channel else { return }
            let frame = try! RemoteFraming.frame(try! channel.seal(message))
            self.channel = channel
            transport.deliverToClient(frame)
        }
        func receive(_ bytes: Data) {
            guard let mac else { return }
            for payload in try! decoder.append(bytes) {
                if channel == nil {
                    guard case .hello(let hello) = try! RemoteProtocol.decoder().decode(RemoteHandshakeMessage.self, from: payload) else { return }
                    let (reply, channel) = try! RemoteServerHandshake.respond(to: hello, identity: mac.identity, macName: "Fake Mac", variant: .demo)
                    transport.deliverToClient(try! RemoteFraming.frame(try! RemoteProtocol.encoder().encode(RemoteHandshakeMessage.serverHello(reply))))
                    self.channel = channel
                    if hello.intent == .pair { challenge = RemoteHandshake.randomNonce(); send(.pairChallenge(RemotePairChallenge(challenge: challenge, expiresAt: Date().addingTimeInterval(60)))) }
                    continue
                }
                var channel = self.channel!
                let message = try! channel.open(payload)
                self.channel = channel
                switch message {
                case .pairResponse(let response):
                    guard RemoteHandshake.pairingProof(code: mac.code, challenge: challenge, transcript: channel.transcript, devicePublicKey: response.devicePublicKey) == response.proof else {
                        send(.error(RemoteErrorMessage(code: .pairingFailed, message: "The pairing code did not match."))); return
                    }
                    mac.deviceKey = response.devicePublicKey
                    send(.pairComplete(RemotePairComplete(deviceID: mac.deviceID, macName: "Fake Mac")))
                case .authenticate(let auth):
                    guard !mac.forgetOnResume, let key = mac.deviceKey, auth.deviceID == mac.deviceID,
                          RemoteHandshake.verify(signature: auth.signature, over: channel.transcript, publicKey: key) else {
                        send(.error(RemoteErrorMessage(code: .notPaired, message: "This phone is not paired with this Mac."))); return
                    }
                    send(.authenticated(deviceID: auth.deviceID))
                case .subscribe(let since):
                    sinceSeq = since
                    if mac.lockedOnConnect { send(.error(RemoteErrorMessage(code: .macLocked, message: "Disconnected: your Mac is locked."))); return }
                    if let since, since == mac.snapshot.seq { send(.events(events: [], latestSeq: since)) } else { send(.snapshot(mac.snapshot)) }
                case .command(let command):
                    mac.commands.append(command)
                    if mac.answerCommands { send(.commandResult(RemoteCommandResult(clientCommandID: command.clientCommandID, outcome: .applied))) }
                case .ping(let nonce): send(.pong(nonce: nonce, seq: mac.snapshot.seq))
                default: break
                }
            }
        }
    }
    private(set) var sessions: [Session] = []
    var reachable: Set<String> = ["100.64.0.1:4000", "192.168.1.2:4000"]
    func transport(for endpoint: MacEndpoint, spki: Data) -> ClientTransport {
        let transport = TestTransport(label: endpoint.label, reachable: reachable.contains(endpoint.label) && spki == self.spki)
        transport.onConnect = { [weak self, weak transport] in
            guard let self, let transport else { return }
            connections += 1
            let session = Session(mac: self, transport: transport)
            sessions.append(session)
            transport.server = session
        }
        return transport
    }
}

/// Client end of an in-memory connection to the fake Mac. Delivery is asynchronous and ordered.
@MainActor
final class TestTransport: ClientTransport {
    var onReceive: ((Data) -> Void)?
    var onState: ((ClientTransportState) -> Void)?
    let label: String
    let reachable: Bool
    var onConnect: (() -> Void)?
    var server: FakeMac.Session?
    private(set) var closed = false
    init(label: String, reachable: Bool) { self.label = label; self.reachable = reachable }
    func start() {
        Task { @MainActor in
            guard !self.closed else { return }
            if self.reachable { self.onConnect?(); self.onState?(.ready) } else { self.onState?(.failed("unreachable")) }
        }
    }
    func send(_ data: Data) {
        guard !closed else { return }
        Task { @MainActor in if !self.closed { self.server?.receive(data) } }
    }
    func deliverToClient(_ data: Data) {
        Task { @MainActor in if !self.closed { self.onReceive?(data) } }
    }
    func cancel() { closed = true }
    /// Simulates the network dropping.
    func drop() { closed = true; onState?(.closed) }
}
