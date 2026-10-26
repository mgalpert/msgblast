import Foundation
import CryptoKit

/// A long-lived P-256 signing identity (the Mac's or the phone's).
public protocol RemoteSigningKey {
    var publicKeyX963: Data { get }
    func remoteSignature(for data: Data) throws -> Data
}

extension P256.Signing.PrivateKey: RemoteSigningKey {
    public var publicKeyX963: Data { publicKey.x963Representation }
    public func remoteSignature(for data: Data) throws -> Data { try signature(for: data).derRepresentation }
}

#if !os(Linux)
extension SecureEnclave.P256.Signing.PrivateKey: RemoteSigningKey {
    public var publicKeyX963: Data { publicKey.x963Representation }
    public func remoteSignature(for data: Data) throws -> Data { try signature(for: data).derRepresentation }
}
#endif

/// Application-layer security that does not depend on the route. Each session:
/// ephemeral X25519 agreement, transcript signed by the Mac identity (and, after
/// pairing, by the phone identity), HKDF-SHA256 to one key per direction, and
/// ChaChaPoly per frame with a strictly increasing counter.
public enum RemoteHandshake {
    public static let label = Data("msgblast-remote-v1".utf8)
    public static let nonceBytes = 32

    public static func keyHash(_ x963: Data) -> Data { Data(SHA256.hash(data: x963)) }

    /// SHA-256 over every value both sides agreed on before keys exist.
    public static func transcript(version: Int, intent: RemoteHelloIntent, clientEphemeral: Data, clientNonce: Data,
                                  serverEphemeral: Data, serverNonce: Data, identityKey: Data) -> Data {
        var hash = SHA256()
        hash.update(data: label)
        var v = UInt16(clamping: version).bigEndian
        hash.update(data: Data(bytes: &v, count: 2))
        hash.update(data: Data(intent.rawValue.utf8))
        for part in [clientEphemeral, clientNonce, serverEphemeral, serverNonce, identityKey] {
            var length = UInt16(clamping: part.count).bigEndian
            hash.update(data: Data(bytes: &length, count: 2))
            hash.update(data: part)
        }
        return Data(hash.finalize())
    }

    public static func verify(signature: Data, over data: Data, publicKey x963: Data) -> Bool {
        guard let key = try? P256.Signing.PublicKey(x963Representation: x963),
              let parsed = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
        return key.isValidSignature(parsed, for: data)
    }

    public static func sessionKeys(ephemeral: Curve25519.KeyAgreement.PrivateKey, peerEphemeral: Data, transcript: Data) throws -> (clientToServer: SymmetricKey, serverToClient: SymmetricKey) {
        guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerEphemeral) else { throw RemoteProtocolError.invalidKey }
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: peer)
        let c2s = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript, sharedInfo: Data("msgblast remote c2s".utf8), outputByteCount: 32)
        let s2c = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript, sharedInfo: Data("msgblast remote s2c".utf8), outputByteCount: 32)
        return (c2s, s2c)
    }

    /// Binds the one-time code to this session and to the phone's identity key.
    public static func pairingProof(code: String, challenge: Data, transcript: Data, devicePublicKey: Data) -> Data {
        var message = challenge; message.append(transcript); message.append(devicePublicKey)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: Data(code.utf8))))
    }
    public static func pairingSignedData(transcript: Data, challenge: Data) -> Data { transcript + challenge }

    public static func randomNonce() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
}

public enum RemoteDirection: UInt32, Sendable {
    case clientToServer = 1, serverToClient = 2
}

/// One direction of an encrypted session. Frames: counter (8 bytes, big-endian) ‖ ciphertext ‖ tag.
/// The receiver accepts only the next counter, so replays, drops and reorders fail closed.
public struct RemoteCipher: Sendable {
    public let direction: RemoteDirection
    private let key: SymmetricKey
    private let transcript: Data
    public private(set) var counter: UInt64 = 0
    public init(key: SymmetricKey, direction: RemoteDirection, transcript: Data) {
        self.key = key; self.direction = direction; self.transcript = transcript
    }
    private func nonce(_ counter: UInt64) throws -> ChaChaPoly.Nonce {
        var d = direction.rawValue.bigEndian, c = counter.bigEndian
        var bytes = Data(bytes: &d, count: 4); bytes.append(Data(bytes: &c, count: 8))
        return try ChaChaPoly.Nonce(data: bytes)
    }
    private func aad(_ counter: UInt64) -> Data {
        var d = direction.rawValue.bigEndian, c = counter.bigEndian
        return transcript + Data(bytes: &d, count: 4) + Data(bytes: &c, count: 8)
    }
    public mutating func seal(_ plaintext: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: try nonce(counter), authenticating: aad(counter))
        var c = counter.bigEndian
        var out = Data(bytes: &c, count: 8)
        out.append(box.ciphertext); out.append(box.tag)
        counter += 1
        return out
    }
    public mutating func open(_ sealed: Data) throws -> Data {
        guard sealed.count >= 8 + 16 else { throw RemoteProtocolError.authenticationFailed }
        let bytes = [UInt8](sealed)
        let received = bytes[0..<8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard received == counter else { throw RemoteProtocolError.replayOrReorder }
        let body = Data(bytes[8..<(bytes.count - 16)]), tag = Data(bytes[(bytes.count - 16)...])
        do {
            let box = try ChaChaPoly.SealedBox(nonce: try nonce(received), ciphertext: body, tag: tag)
            let plaintext = try ChaChaPoly.open(box, using: key, authenticating: aad(received))
            counter += 1
            return plaintext
        } catch { throw RemoteProtocolError.authenticationFailed }
    }
}

/// Both directions plus the transcript both identities signed.
public struct RemoteSecureChannel: Sendable {
    public let transcript: Data
    private var sender: RemoteCipher
    private var receiver: RemoteCipher
    public init(transcript: Data, keys: (clientToServer: SymmetricKey, serverToClient: SymmetricKey), isServer: Bool) {
        self.transcript = transcript
        let c2s = RemoteCipher(key: keys.clientToServer, direction: .clientToServer, transcript: transcript)
        let s2c = RemoteCipher(key: keys.serverToClient, direction: .serverToClient, transcript: transcript)
        sender = isServer ? s2c : c2s
        receiver = isServer ? c2s : s2c
    }
    public mutating func seal(_ message: RemoteMessage) throws -> Data {
        try sender.seal(try RemoteProtocol.encoder().encode(message))
    }
    public mutating func open(_ frame: Data) throws -> RemoteMessage {
        try RemoteProtocol.decoder().decode(RemoteMessage.self, from: try receiver.open(frame))
    }
}

/// The phone's half of the handshake.
public struct RemoteClientHandshake: Sendable {
    public let hello: RemoteClientHello
    private let ephemeral: Curve25519.KeyAgreement.PrivateKey
    public init(intent: RemoteHelloIntent, ephemeral: Curve25519.KeyAgreement.PrivateKey = .init(), nonce: Data = RemoteHandshake.randomNonce()) {
        self.ephemeral = ephemeral
        hello = RemoteClientHello(intent: intent, ephemeralKey: ephemeral.publicKey.rawRepresentation, nonce: nonce)
    }
    /// Verifies the Mac's signature and that its identity matches what the phone pinned
    /// (the full key after pairing, or the key hash from the QR code before).
    public func complete(with server: RemoteServerHello, pinnedIdentityKey: Data? = nil, pinnedIdentityKeyHash: Data? = nil) throws -> RemoteSecureChannel {
        guard server.protocolVersion >= RemoteProtocol.minimumSupportedVersion else { throw RemoteProtocolError.unsupportedVersion(server.protocolVersion) }
        if let pinnedIdentityKey, pinnedIdentityKey != server.identityKey { throw RemoteProtocolError.authenticationFailed }
        if let pinnedIdentityKeyHash, pinnedIdentityKeyHash != RemoteHandshake.keyHash(server.identityKey) { throw RemoteProtocolError.authenticationFailed }
        guard pinnedIdentityKey != nil || pinnedIdentityKeyHash != nil else { throw RemoteProtocolError.authenticationFailed }
        let transcript = RemoteHandshake.transcript(version: min(hello.protocolVersion, server.protocolVersion), intent: hello.intent,
            clientEphemeral: hello.ephemeralKey, clientNonce: hello.nonce, serverEphemeral: server.ephemeralKey, serverNonce: server.nonce, identityKey: server.identityKey)
        guard RemoteHandshake.verify(signature: server.signature, over: transcript, publicKey: server.identityKey) else { throw RemoteProtocolError.authenticationFailed }
        let keys = try RemoteHandshake.sessionKeys(ephemeral: ephemeral, peerEphemeral: server.ephemeralKey, transcript: transcript)
        return RemoteSecureChannel(transcript: transcript, keys: keys, isServer: false)
    }
}

/// The Mac's half of the handshake.
public enum RemoteServerHandshake {
    public static func respond(to hello: RemoteClientHello, identity: some RemoteSigningKey, macName: String, variant: MacVariant,
                               ephemeral: Curve25519.KeyAgreement.PrivateKey = .init(), nonce: Data = RemoteHandshake.randomNonce()) throws -> (RemoteServerHello, RemoteSecureChannel) {
        guard hello.protocolVersion >= RemoteProtocol.minimumSupportedVersion else { throw RemoteProtocolError.unsupportedVersion(hello.protocolVersion) }
        guard hello.nonce.count == RemoteHandshake.nonceBytes, hello.ephemeralKey.count == 32 else { throw RemoteProtocolError.invalidKey }
        let version = min(hello.protocolVersion, RemoteProtocol.version)
        let ephemeralKey = ephemeral.publicKey.rawRepresentation
        let transcript = RemoteHandshake.transcript(version: version, intent: hello.intent, clientEphemeral: hello.ephemeralKey, clientNonce: hello.nonce,
            serverEphemeral: ephemeralKey, serverNonce: nonce, identityKey: identity.publicKeyX963)
        let signature = try identity.remoteSignature(for: transcript)
        let keys = try RemoteHandshake.sessionKeys(ephemeral: ephemeral, peerEphemeral: hello.ephemeralKey, transcript: transcript)
        let reply = RemoteServerHello(protocolVersion: RemoteProtocol.version, identityKey: identity.publicKeyX963, ephemeralKey: ephemeralKey,
                                      nonce: nonce, signature: signature, macName: macName, variant: variant)
        return (reply, RemoteSecureChannel(transcript: transcript, keys: keys, isServer: true))
    }
}
