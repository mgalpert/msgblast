import CryptoKit
import Foundation
import Security
import msgblastRemoteProtocol

/// What the phone remembers about its one paired Mac. No secret: the device key is in the Keychain.
public struct PairedMac: Codable, Equatable, Sendable {
    public var macName: String
    public var variant: MacVariant
    public var deviceID: UUID
    public var identityKey: Data
    public var spkiSHA256: Data
    public var addresses: [RemoteEndpoint]
    public var port: UInt16
    public var pairedAt: Date
    public init(macName: String, variant: MacVariant, deviceID: UUID, identityKey: Data, spkiSHA256: Data, addresses: [RemoteEndpoint], port: UInt16, pairedAt: Date) {
        self.macName = macName; self.variant = variant; self.deviceID = deviceID; self.identityKey = identityKey
        self.spkiSHA256 = spkiSHA256; self.addresses = addresses; self.port = port; self.pairedAt = pairedAt
    }
    /// Groups of four hex characters of SHA-256(identity key), shown to compare with the Mac.
    public var fingerprint: String { Self.fingerprint(RemoteHandshake.keyHash(identityKey)) }
    public static func fingerprint(_ hash: Data) -> String {
        let hex = hash.prefix(12).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map { start -> String in
            let a = hex.index(hex.startIndex, offsetBy: start), b = hex.index(a, offsetBy: 4)
            return String(hex[a..<b])
        }.joined(separator: " ")
    }
    public var endpoints: [MacEndpoint] { addresses.map { .host($0.host, port: port) } }
}

/// The phone's long-lived P-256 key. On a device with a Secure Enclave the key never
/// leaves it; elsewhere (simulator, tests) it is a software key in the Keychain.
public protocol DeviceKeyStore: Sendable {
    func loadOrCreate() throws -> any RemoteSigningKey
    func delete()
}

public final class MemoryDeviceKeyStore: DeviceKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: P256.Signing.PrivateKey?
    public init() {}
    public func loadOrCreate() throws -> any RemoteSigningKey {
        lock.withLock { if let key { return key }; let fresh = P256.Signing.PrivateKey(); key = fresh; return fresh }
    }
    public func delete() { lock.withLock { key = nil } }
}

public struct KeychainDeviceKeyStore: DeviceKeyStore {
    let service = "com.msgblast.ios.device-key"
    public init() {}
    private func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "paired-mac",
         kSecUseDataProtectionKeychain as String: true]
    }
    public func loadOrCreate() throws -> any RemoteSigningKey {
        var lookup = query(); lookup[kSecReturnData as String] = true; lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        if SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess, let stored = result as? Data, let first = stored.first {
            let body = stored.dropFirst()
            if first == 1, let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: body) { return key }
            if first == 0, let key = try? P256.Signing.PrivateKey(rawRepresentation: body) { return key }
        }
        let (key, data): (any RemoteSigningKey, Data)
        if SecureEnclave.isAvailable, let hardware = try? SecureEnclave.P256.Signing.PrivateKey() {
            (key, data) = (hardware, Data([1]) + hardware.dataRepresentation)
        } else {
            let software = P256.Signing.PrivateKey()
            (key, data) = (software, Data([0]) + software.rawRepresentation)
        }
        var item = query(); item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemDelete(query() as CFDictionary)
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw MobileConnectionError.keychain }
        return key
    }
    public func delete() { SecItemDelete(query() as CFDictionary) }
}

public enum MobileConnectionError: LocalizedError, Equatable, Sendable {
    case keychain, notConnected, notPaired, offerExpired
    public var errorDescription: String? {
        switch self {
        case .keychain: "This phone's key could not be saved in the Keychain."
        case .notConnected: "Not connected to your Mac. Nothing was sent."
        case .notPaired: "Pair with your Mac first."
        case .offerExpired: "This pairing code expired. Show a new one on your Mac."
        }
    }
}
