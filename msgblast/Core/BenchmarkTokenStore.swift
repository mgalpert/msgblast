import Foundation
import Security
import LocalAuthentication

@MainActor public protocol BenchmarkTokenStore: AnyObject {
    func read(scope: String) throws -> BenchmarkAccountTokens?
    func save(_ tokens: BenchmarkAccountTokens, scope: String) throws
    func delete(scope: String) throws
}

/// This account boundary deliberately has no file or UserDefaults fallback.
@MainActor public final class BenchmarkKeychainTokenStore: BenchmarkTokenStore {
    /// Provisioned signatures use access-group isolation. The supported ad-hoc
    /// distribution uses the encrypted macOS login Keychain and its code ACL.
    /// Selection occurs before any operation, never after a storage failure.
    public let usesDataProtection: Bool
    public init() {
        if let task = SecTaskCreateFromSelf(nil) {
            let identifier = SecTaskCopyValueForEntitlement(task, "com.apple.application-identifier" as CFString, nil) as? String
            let groups = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) as? [String]
            usesDataProtection = identifier?.isEmpty == false || groups?.isEmpty == false
        } else { usesDataProtection = false }
    }
    private func query(_ scope: String) -> [String: Any] {
        let context = LAContext(); context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: scope,
         kSecAttrAccount as String: "benchmark-session", kSecUseDataProtectionKeychain as String: usesDataProtection,
         kSecUseAuthenticationContext as String: context, kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }
    public func read(scope: String) throws -> BenchmarkAccountTokens? {
        var query = query(scope); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw BenchmarkAccountError.secureStorage(status) }
        guard let bytes = result as? Data else { throw BenchmarkAccountError.invalidResponse }
        do { return try JSONDecoder().decode(BenchmarkAccountTokens.self, from: bytes) }
        catch { throw BenchmarkAccountError.secureStorage(errSecDecode) }
    }
    public func save(_ tokens: BenchmarkAccountTokens, scope: String) throws {
        let bytes = try JSONEncoder().encode(tokens)
        let query = query(scope)
        let update = [kSecValueData as String: bytes]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = bytes
            if usesDataProtection { item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw BenchmarkAccountError.secureStorage(added) }
        } else if status != errSecSuccess { throw BenchmarkAccountError.secureStorage(status) }
    }
    public func delete(scope: String) throws {
        let status = SecItemDelete(query(scope) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw BenchmarkAccountError.secureStorage(status) }
    }
}
