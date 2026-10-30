import Foundation
import CryptoKit

/// The phone side of a session without I/O: feed it received bytes, send the bytes it
/// returns. Used by the command-line harness, tests, and the future iOS controller.
public final class RemoteClientDriver {
    public enum Mode {
        /// First contact from a scanned QR code.
        case pair(offer: RemotePairingOffer, deviceName: String, deviceKey: any RemoteSigningKey)
        /// A paired phone reconnecting; `macIdentityKey` was learned during pairing.
        case resume(deviceID: UUID, deviceKey: any RemoteSigningKey, macIdentityKey: Data)
    }
    public enum Event {
        case paired(RemotePairComplete, macIdentityKey: Data)
        case authenticated(deviceID: UUID)
        case snapshot(RemoteSnapshot)
        case events([RemoteEvent], latestSeq: UInt64)
        case commandResult(RemoteCommandResult)
        case pong(nonce: UInt64, seq: UInt64)
        case error(RemoteErrorMessage)
    }
    private let mode: Mode
    private let handshake: RemoteClientHandshake
    private var decoder = RemoteFrameDecoder()
    private var channel: RemoteSecureChannel?
    private var macIdentityKey: Data?
    public private(set) var authenticated = false
    public var sinceSeq: UInt64?

    public init(mode: Mode, sinceSeq: UInt64? = nil) {
        self.mode = mode
        self.sinceSeq = sinceSeq
        switch mode {
        case .pair: handshake = RemoteClientHandshake(intent: .pair)
        case .resume: handshake = RemoteClientHandshake(intent: .resume)
        }
    }

    /// The framed plaintext hello.
    public func start() throws -> Data {
        try RemoteFraming.frame(try RemoteProtocol.encoder().encode(RemoteHandshakeMessage.hello(handshake.hello)))
    }

    /// A framed, encrypted message (commands, pings, re-subscribes).
    public func frame(_ message: RemoteMessage) throws -> Data {
        guard var channel else { throw RemoteProtocolError.unexpectedMessage("not connected") }
        let sealed = try channel.seal(message)
        self.channel = channel
        return try RemoteFraming.frame(sealed)
    }

    public func receive(_ bytes: Data) throws -> (outgoing: [Data], events: [Event]) {
        var outgoing: [Data] = [], events: [Event] = []
        for payload in try decoder.append(bytes) {
            guard channel != nil else {
                switch try RemoteProtocol.decoder().decode(RemoteHandshakeMessage.self, from: payload) {
                case .serverHello(let server):
                    switch mode {
                    case .pair(let offer, _, _): channel = try handshake.complete(with: server, pinnedIdentityKeyHash: offer.identityKeySHA256)
                    case .resume(_, _, let key): channel = try handshake.complete(with: server, pinnedIdentityKey: key)
                    }
                    macIdentityKey = server.identityKey
                    if case .resume(let deviceID, let key, _) = mode {
                        outgoing.append(try frame(.authenticate(RemoteAuthenticate(deviceID: deviceID, signature: try key.remoteSignature(for: channel!.transcript)))))
                    }
                case .error(let error): events.append(.error(error))
                case .hello: throw RemoteProtocolError.unexpectedMessage("hello")
                }
                continue
            }
            var channel = channel!
            let message = try channel.open(payload)
            self.channel = channel
            switch message {
            case .pairChallenge(let challenge):
                guard case .pair(let offer, let name, let key) = mode else { throw RemoteProtocolError.unexpectedMessage("pairChallenge") }
                let publicKey = key.publicKeyX963
                let proof = RemoteHandshake.pairingProof(code: offer.code, challenge: challenge.challenge, transcript: channel.transcript, devicePublicKey: publicKey)
                let signature = try key.remoteSignature(for: RemoteHandshake.pairingSignedData(transcript: channel.transcript, challenge: challenge.challenge))
                outgoing.append(try frame(.pairResponse(RemotePairResponse(deviceName: name, devicePublicKey: publicKey, proof: proof, signature: signature))))
            case .pairComplete(let complete):
                authenticated = true
                events.append(.paired(complete, macIdentityKey: macIdentityKey ?? Data()))
                outgoing.append(try frame(.subscribe(sinceSeq: sinceSeq)))
            case .authenticated(let id):
                authenticated = true
                events.append(.authenticated(deviceID: id))
                outgoing.append(try frame(.subscribe(sinceSeq: sinceSeq)))
            case .snapshot(let snapshot):
                if snapshot.partIndex == snapshot.partCount - 1 { sinceSeq = snapshot.seq }
                events.append(.snapshot(snapshot))
            case .events(let list, let latest):
                sinceSeq = latest
                events.append(.events(list, latestSeq: latest))
            case .commandResult(let result): events.append(.commandResult(result))
            case .pong(let nonce, let seq): events.append(.pong(nonce: nonce, seq: seq))
            case .ping(let nonce): outgoing.append(try frame(.pong(nonce: nonce, seq: sinceSeq ?? 0)))
            case .error(let error): events.append(.error(error))
            case .pairResponse, .authenticate, .subscribe, .command, .unknown: break
            }
        }
        return (outgoing, events)
    }
}

/// Recorded client events (fixtures for the phone's reducer and the harness's `--record`).
extension RemoteClientDriver.Event: Codable {
    private enum CodingKeys: String, CodingKey { case kind, paired, macIdentityKey, deviceID, snapshot, events, latestSeq, result, nonce, seq, error }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "paired": self = .paired(try c.decode(RemotePairComplete.self, forKey: .paired), macIdentityKey: try c.decode(Data.self, forKey: .macIdentityKey))
        case "authenticated": self = .authenticated(deviceID: try c.decode(UUID.self, forKey: .deviceID))
        case "snapshot": self = .snapshot(try c.decode(RemoteSnapshot.self, forKey: .snapshot))
        case "events": self = .events(try c.decode([RemoteEvent].self, forKey: .events), latestSeq: try c.decode(UInt64.self, forKey: .latestSeq))
        case "commandResult": self = .commandResult(try c.decode(RemoteCommandResult.self, forKey: .result))
        case "pong": self = .pong(nonce: try c.decode(UInt64.self, forKey: .nonce), seq: try c.decode(UInt64.self, forKey: .seq))
        case "error": self = .error(try c.decode(RemoteErrorMessage.self, forKey: .error))
        case let other: throw RemoteProtocolError.unexpectedMessage(other)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .paired(let complete, let key): try c.encode("paired", forKey: .kind); try c.encode(complete, forKey: .paired); try c.encode(key, forKey: .macIdentityKey)
        case .authenticated(let id): try c.encode("authenticated", forKey: .kind); try c.encode(id, forKey: .deviceID)
        case .snapshot(let snapshot): try c.encode("snapshot", forKey: .kind); try c.encode(snapshot, forKey: .snapshot)
        case .events(let events, let latest): try c.encode("events", forKey: .kind); try c.encode(events, forKey: .events); try c.encode(latest, forKey: .latestSeq)
        case .commandResult(let result): try c.encode("commandResult", forKey: .kind); try c.encode(result, forKey: .result)
        case .pong(let nonce, let seq): try c.encode("pong", forKey: .kind); try c.encode(nonce, forKey: .nonce); try c.encode(seq, forKey: .seq)
        case .error(let error): try c.encode("error", forKey: .kind); try c.encode(error, forKey: .error)
        }
    }
}
