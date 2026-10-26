import Foundation

public enum RemoteHelloIntent: String, Codable, Hashable, Sendable {
    case pair, resume
}

/// First frame from the phone, sent in the clear (inside TLS on direct routes).
public struct RemoteClientHello: Codable, Hashable, Sendable {
    public var protocolVersion: Int
    public var intent: RemoteHelloIntent
    public var ephemeralKey: Data
    public var nonce: Data
    public init(protocolVersion: Int = RemoteProtocol.version, intent: RemoteHelloIntent, ephemeralKey: Data, nonce: Data) {
        self.protocolVersion = protocolVersion; self.intent = intent; self.ephemeralKey = ephemeralKey; self.nonce = nonce
    }
}

/// The Mac's reply, signed by its long-lived identity over the handshake transcript.
public struct RemoteServerHello: Codable, Hashable, Sendable {
    public var protocolVersion: Int
    public var identityKey: Data
    public var ephemeralKey: Data
    public var nonce: Data
    public var signature: Data
    public var macName: String
    public var variant: MacVariant
    public init(protocolVersion: Int = RemoteProtocol.version, identityKey: Data, ephemeralKey: Data, nonce: Data, signature: Data, macName: String, variant: MacVariant) {
        self.protocolVersion = protocolVersion; self.identityKey = identityKey; self.ephemeralKey = ephemeralKey; self.nonce = nonce
        self.signature = signature; self.macName = macName; self.variant = variant
    }
}

public struct RemotePairChallenge: Codable, Hashable, Sendable {
    public var challenge: Data
    public var expiresAt: Date
    public init(challenge: Data, expiresAt: Date) { self.challenge = challenge; self.expiresAt = expiresAt }
}

public struct RemotePairResponse: Codable, Hashable, Sendable {
    public var deviceName: String
    /// The phone's long-lived P-256 signing key (x9.63).
    public var devicePublicKey: Data
    /// HMAC-SHA256 keyed by the one-time code over challenge ‖ transcript ‖ devicePublicKey.
    public var proof: Data
    /// The device key's signature over transcript ‖ challenge, proving possession.
    public var signature: Data
    public init(deviceName: String, devicePublicKey: Data, proof: Data, signature: Data) {
        self.deviceName = deviceName; self.devicePublicKey = devicePublicKey; self.proof = proof; self.signature = signature
    }
}

public struct RemotePairComplete: Codable, Hashable, Sendable {
    public var deviceID: UUID
    public var macName: String
    public init(deviceID: UUID, macName: String) { self.deviceID = deviceID; self.macName = macName }
}

public struct RemoteAuthenticate: Codable, Hashable, Sendable {
    public var deviceID: UUID
    /// The device key's signature over the handshake transcript.
    public var signature: Data
    public init(deviceID: UUID, signature: Data) { self.deviceID = deviceID; self.signature = signature }
}

public struct RemoteErrorMessage: Codable, Hashable, Sendable {
    public struct Code: RemoteOpenValue {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let unsupportedVersion: Self = "unsupportedVersion"
        public static let notPaired: Self = "notPaired"
        public static let pairingClosed: Self = "pairingClosed"
        public static let pairingFailed: Self = "pairingFailed"
        public static let pairingReplaceNeedsConfirmation: Self = "pairingReplaceNeedsConfirmation"
        public static let authenticationFailed: Self = "authenticationFailed"
        public static let anotherClientConnected: Self = "anotherClientConnected"
        public static let protocolViolation: Self = "protocolViolation"
        public static let forgotten: Self = "forgotten"
        public static let serviceStopped: Self = "serviceStopped"
    }
    public var code: Code
    public var message: String
    public init(code: Code, message: String) { self.code = code; self.message = message }
}

/// Every frame after the handshake, encrypted with the session keys.
public enum RemoteMessage: Codable, Hashable, Sendable {
    case pairChallenge(RemotePairChallenge)
    case pairResponse(RemotePairResponse)
    case pairComplete(RemotePairComplete)
    case authenticate(RemoteAuthenticate)
    case authenticated(deviceID: UUID)
    /// Ask for changes after `sinceSeq`, or a full snapshot when nil or too old.
    case subscribe(sinceSeq: UInt64?)
    case snapshot(RemoteSnapshot)
    case events(events: [RemoteEvent], latestSeq: UInt64)
    case command(RemoteCommand)
    case commandResult(RemoteCommandResult)
    case ping(nonce: UInt64)
    case pong(nonce: UInt64, seq: UInt64)
    case error(RemoteErrorMessage)
    case unknown(kind: String)

    public var kind: String {
        switch self {
        case .pairChallenge: "pairChallenge"; case .pairResponse: "pairResponse"; case .pairComplete: "pairComplete"
        case .authenticate: "authenticate"; case .authenticated: "authenticated"; case .subscribe: "subscribe"
        case .snapshot: "snapshot"; case .events: "events"; case .command: "command"; case .commandResult: "commandResult"
        case .ping: "ping"; case .pong: "pong"; case .error: "error"; case .unknown(let kind): kind
        }
    }
    private enum CodingKeys: String, CodingKey { case kind, payload, deviceID, sinceSeq, events, latestSeq, nonce, seq }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "pairChallenge": self = .pairChallenge(try c.decode(RemotePairChallenge.self, forKey: .payload))
        case "pairResponse": self = .pairResponse(try c.decode(RemotePairResponse.self, forKey: .payload))
        case "pairComplete": self = .pairComplete(try c.decode(RemotePairComplete.self, forKey: .payload))
        case "authenticate": self = .authenticate(try c.decode(RemoteAuthenticate.self, forKey: .payload))
        case "authenticated": self = .authenticated(deviceID: try c.decode(UUID.self, forKey: .deviceID))
        case "subscribe": self = .subscribe(sinceSeq: try c.decodeIfPresent(UInt64.self, forKey: .sinceSeq))
        case "snapshot": self = .snapshot(try c.decode(RemoteSnapshot.self, forKey: .payload))
        case "events": self = .events(events: try c.decode([RemoteEvent].self, forKey: .events), latestSeq: try c.decode(UInt64.self, forKey: .latestSeq))
        case "command": self = .command(try c.decode(RemoteCommand.self, forKey: .payload))
        case "commandResult": self = .commandResult(try c.decode(RemoteCommandResult.self, forKey: .payload))
        case "ping": self = .ping(nonce: try c.decode(UInt64.self, forKey: .nonce))
        case "pong": self = .pong(nonce: try c.decode(UInt64.self, forKey: .nonce), seq: try c.decode(UInt64.self, forKey: .seq))
        case "error": self = .error(try c.decode(RemoteErrorMessage.self, forKey: .payload))
        default: self = .unknown(kind: kind)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case .pairChallenge(let v): try c.encode(v, forKey: .payload)
        case .pairResponse(let v): try c.encode(v, forKey: .payload)
        case .pairComplete(let v): try c.encode(v, forKey: .payload)
        case .authenticate(let v): try c.encode(v, forKey: .payload)
        case .authenticated(let id): try c.encode(id, forKey: .deviceID)
        case .subscribe(let since): try c.encodeIfPresent(since, forKey: .sinceSeq)
        case .snapshot(let v): try c.encode(v, forKey: .payload)
        case .events(let events, let latest): try c.encode(events, forKey: .events); try c.encode(latest, forKey: .latestSeq)
        case .command(let v): try c.encode(v, forKey: .payload)
        case .commandResult(let v): try c.encode(v, forKey: .payload)
        case .ping(let nonce): try c.encode(nonce, forKey: .nonce)
        case .pong(let nonce, let seq): try c.encode(nonce, forKey: .nonce); try c.encode(seq, forKey: .seq)
        case .error(let v): try c.encode(v, forKey: .payload)
        case .unknown: break
        }
    }
}

/// Plaintext handshake frames. The server may answer a bad hello with an error before keys exist.
public enum RemoteHandshakeMessage: Codable, Hashable, Sendable {
    case hello(RemoteClientHello)
    case serverHello(RemoteServerHello)
    case error(RemoteErrorMessage)
    private enum CodingKeys: String, CodingKey { case kind, payload }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "hello": self = .hello(try c.decode(RemoteClientHello.self, forKey: .payload))
        case "serverHello": self = .serverHello(try c.decode(RemoteServerHello.self, forKey: .payload))
        case "error": self = .error(try c.decode(RemoteErrorMessage.self, forKey: .payload))
        case let other: throw RemoteProtocolError.unexpectedMessage(other)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let v): try c.encode("hello", forKey: .kind); try c.encode(v, forKey: .payload)
        case .serverHello(let v): try c.encode("serverHello", forKey: .kind); try c.encode(v, forKey: .payload)
        case .error(let v): try c.encode("error", forKey: .kind); try c.encode(v, forKey: .payload)
        }
    }
}
