import Foundation
import CryptoKit
import Security
import LocalAuthentication
import msgblastRemoteProtocol

/// Where the Mac's long-lived remote identity is kept.
public enum RemoteIdentityStorage: String, Codable, Sendable {
    /// Private key encrypted at rest under a Secure Enclave key (the Grok Bot vault pattern).
    case secureEnclave
    /// Data-protection Keychain item, when the build has a Keychain access group.
    case keychain
    /// Memory only: a new identity each launch, so the phone must pair again after relaunch.
    case sessionOnly

    public var label: String {
        switch self {
        case .secureEnclave: "Protected by the Secure Enclave"
        case .keychain: "Stored in the Keychain"
        case .sessionOnly: "Session only · pair again after msgblast restarts"
        }
    }
}

/// The Mac's P-256 identity. One key signs the application-layer handshake and
/// serves the self-signed TLS certificate, so the QR pins one identity on any route.
/// The Secure Enclave cannot hold a TLS server key, so the key itself is a software
/// key wrapped at rest by a Secure Enclave key, as `GrokBotCredentialVault` does.
public struct RemoteIdentity: @unchecked Sendable {
    public let signingKey: P256.Signing.PrivateKey
    public let certificate: Data
    public let storage: RemoteIdentityStorage
    public var publicKeyX963: Data { signingKey.publicKey.x963Representation }
    public var identityKeySHA256: Data { RemoteHandshake.keyHash(publicKeyX963) }
    public var spkiSHA256: Data { RemoteTLSPin.spkiSHA256(p256X963: publicKeyX963) }

    public init(signingKey: P256.Signing.PrivateKey, certificate: Data? = nil, storage: RemoteIdentityStorage) throws {
        self.signingKey = signingKey
        self.certificate = try certificate ?? RemoteCertificate.selfSigned(key: signingKey)
        self.storage = storage
    }

    /// In-memory `SecIdentity` for `NWProtocolTLS`; no Keychain item is created.
    public func tlsIdentity() throws -> SecIdentity {
        guard let certificate = SecCertificateCreateWithData(nil, certificate as CFData) else { throw RemoteIdentityError.certificate }
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(signingKey.x963Representation as CFData, [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
              kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary, &error) else { throw RemoteIdentityError.certificate }
        guard let identity = SecIdentityCreate(nil, certificate, key) else { throw RemoteIdentityError.certificate }
        return identity
    }
}

public enum RemoteIdentityError: LocalizedError {
    case certificate, protection
    public var errorDescription: String? {
        switch self {
        case .certificate: "The remote control certificate could not be prepared."
        case .protection: "The remote control identity could not be protected on this Mac."
        }
    }
}

/// Loads or creates the identity file `remote-identity.json` (0600) in the support folder.
public struct RemoteIdentityStore: Sendable {
    public let url: URL
    let secureEnclaveAvailable: Bool
    let keychain: RemoteIdentityKeychain
    public init(directory: URL, secureEnclaveAvailable: Bool = SecureEnclave.isAvailable, keychain: RemoteIdentityKeychain = .system) {
        url = directory.appendingPathComponent("remote-identity.json")
        self.secureEnclaveAvailable = secureEnclaveAvailable
        self.keychain = keychain
    }

    private struct Envelope: Codable {
        var version = 1
        var storage: RemoteIdentityStorage
        var certificate: Data
        var publicKey: Data
        var wrappedKey: Data?
        var ephemeralPublicKey: Data?
        var salt: Data?
        var ciphertext: Data?
    }
    private var context: Data { Data("msgblast.remote.identity.v1\n\(url.standardizedFileURL.path)".utf8) }

    /// Never replaces a file it cannot read: the error is returned and pairing stays unavailable.
    public func loadOrCreate() throws -> RemoteIdentity {
        if let data = try RemotePrivateFile.read(url) { return try open(data) }
        let key = P256.Signing.PrivateKey()
        let identity: RemoteIdentity
        if secureEnclaveAvailable, let sealed = try? sealWithSecureEnclave(key) {
            identity = try RemoteIdentity(signingKey: key, storage: .secureEnclave)
            var envelope = sealed; envelope.certificate = identity.certificate
            try RemotePrivateFile.write(try JSONEncoder().encode(envelope), to: url)
        } else if keychain.save(key.rawRepresentation, url) {
            identity = try RemoteIdentity(signingKey: key, storage: .keychain)
            let envelope = Envelope(storage: .keychain, certificate: identity.certificate, publicKey: key.publicKey.x963Representation)
            try RemotePrivateFile.write(try JSONEncoder().encode(envelope), to: url)
        } else {
            // Nothing is written, so a later launch with protected storage starts cleanly.
            identity = try RemoteIdentity(signingKey: key, storage: .sessionOnly)
        }
        return identity
    }

    /// Forgetting the identity invalidates every pairing.
    public func reset() throws {
        keychain.delete(url)
        try RemotePrivateFile.remove(url)
    }

    private func open(_ data: Data) throws -> RemoteIdentity {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.version == 1 else { throw RemoteStorageError.invalid(url.lastPathComponent) }
        let raw: Data
        switch envelope.storage {
        case .secureEnclave:
            guard let wrapped = envelope.wrappedKey, let ephemeral = envelope.ephemeralPublicKey, let salt = envelope.salt, let ciphertext = envelope.ciphertext else {
                throw RemoteStorageError.invalid(url.lastPathComponent)
            }
            do {
                let hardware = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: wrapped, authenticationContext: Self.authenticationContext())
                let shared = try hardware.sharedSecretFromKeyAgreement(with: try P256.KeyAgreement.PublicKey(rawRepresentation: ephemeral))
                let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: context, outputByteCount: 32)
                raw = try AES.GCM.open(try AES.GCM.SealedBox(combined: ciphertext), using: key, authenticating: context)
            } catch { throw RemoteIdentityError.protection }
        case .keychain:
            guard let stored = keychain.read(url) else { throw RemoteIdentityError.protection }
            raw = stored
        case .sessionOnly:
            throw RemoteStorageError.invalid(url.lastPathComponent)
        }
        guard let key = try? P256.Signing.PrivateKey(rawRepresentation: raw), key.publicKey.x963Representation == envelope.publicKey else {
            throw RemoteStorageError.invalid(url.lastPathComponent)
        }
        return try RemoteIdentity(signingKey: key, certificate: envelope.certificate, storage: envelope.storage)
    }

    private func sealWithSecureEnclave(_ key: P256.Signing.PrivateKey) throws -> Envelope {
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, nil) else { throw RemoteIdentityError.protection }
        let hardware = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access, authenticationContext: Self.authenticationContext())
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: hardware.publicKey)
        let symmetric = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: context, outputByteCount: 32)
        guard let ciphertext = try AES.GCM.seal(key.rawRepresentation, using: symmetric, authenticating: context).combined else { throw RemoteIdentityError.protection }
        return Envelope(storage: .secureEnclave, certificate: Data(), publicKey: key.publicKey.x963Representation, wrappedKey: hardware.dataRepresentation,
                        ephemeralPublicKey: ephemeral.publicKey.rawRepresentation, salt: salt, ciphertext: ciphertext)
    }

    private static func authenticationContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }
}

/// Keychain fallback for Macs without a Secure Enclave. Ad-hoc builds lack a
/// Keychain access group, so `save` fails there and the identity is session-only.
public struct RemoteIdentityKeychain: Sendable {
    var read: @Sendable (URL) -> Data?
    var save: @Sendable (Data, URL) -> Bool
    var delete: @Sendable (URL) -> Void
    public init(read: @escaping @Sendable (URL) -> Data?, save: @escaping @Sendable (Data, URL) -> Bool, delete: @escaping @Sendable (URL) -> Void) {
        self.read = read; self.save = save; self.delete = delete
    }
    public static let unavailable = RemoteIdentityKeychain(read: { _ in nil }, save: { _, _ in false }, delete: { _ in })
    public static let system = RemoteIdentityKeychain(read: { url in
        var query = Self.query(url); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }, save: { data, url in
        var item = Self.query(url)
        SecItemDelete(item as CFDictionary)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }, delete: { url in SecItemDelete(Self.query(url) as CFDictionary) })

    static func query(_ url: URL) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.msgblast.remote.\(Bundle.main.bundleIdentifier ?? "unknown")",
                kSecAttrAccount as String: SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined(),
                kSecUseDataProtectionKeychain as String: true, kSecUseAuthenticationContext as String: context]
    }
}

/// Minimal DER X.509 v3 self-signed certificate for a P-256 key: no extensions,
/// `CN=msgblast remote`, 20-year validity. Phones pin the SPKI, not the chain.
public enum RemoteCertificate {
    static func der(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        var out = [tag]
        if content.count < 128 { out.append(UInt8(content.count)) }
        else {
            var length: [UInt8] = []; var value = content.count
            while value > 0 { length.insert(UInt8(value & 0xFF), at: 0); value >>= 8 }
            out.append(0x80 | UInt8(length.count)); out += length
        }
        return out + content
    }
    static func sequence(_ parts: [UInt8]...) -> [UInt8] { der(0x30, parts.flatMap { $0 }) }
    static let ecdsaWithSHA256: [UInt8] = [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]
    static func name(_ commonName: String) -> [UInt8] {
        sequence(der(0x31, sequence([0x06, 0x03, 0x55, 0x04, 0x03], der(0x0C, Array(commonName.utf8)))))
    }
    static func time(_ date: Date) -> [UInt8] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "UTC")
        // UTCTime covers 1950–2049; GeneralizedTime afterwards (RFC 5280 §4.1.2.5).
        let year = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date).year ?? 2000
        formatter.dateFormat = year < 2050 ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
        return der(year < 2050 ? 0x17 : 0x18, Array(formatter.string(from: date).utf8))
    }

    public static func selfSigned(key: P256.Signing.PrivateKey, commonName: String = "msgblast remote", now: Date = Date()) throws -> Data {
        var serial = SymmetricKey(size: .bits128).withUnsafeBytes { Array($0) }
        serial[0] = (serial[0] & 0x7F) | 0x01
        let tbs = sequence(der(0xA0, der(0x02, [2])), der(0x02, serial), sequence(ecdsaWithSHA256), name(commonName),
                           sequence(time(now.addingTimeInterval(-86_400)), time(now.addingTimeInterval(86_400 * 365 * 20))),
                           name(commonName), Array(RemoteTLSPin.subjectPublicKeyInfo(p256X963: key.publicKey.x963Representation)))
        let signature = try key.signature(for: Data(tbs)).derRepresentation
        return Data(sequence(tbs, sequence(ecdsaWithSHA256), der(0x03, [0] + Array(signature))))
    }
}
