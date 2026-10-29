import Foundation
import Security
import LocalAuthentication

/// An API key belongs to this app identity and never enters the conversation store.
public enum GPTLiveCredentials {
    public static var service: String {
        serviceName(bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    static func serviceName(bundleIdentifier: String?) -> String {
        (bundleIdentifier ?? "com.msgblast.gptlive.local") + ".openai.gpt-live"
    }

    public enum CredentialError: LocalizedError {
        case invalidKey
        case unavailable(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .invalidKey: "Enter a valid OpenAI API key."
            case .unavailable: "Keychain is unavailable. You can use the key for this session without saving it."
            }
        }
    }

    private static var query: [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "openai-api-key",
         kSecAttrSynchronizable as String: false,
         kSecUseAuthenticationContext as String: context]
    }

    public static func save(_ apiKey: String) throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-"), key.utf8.count >= 12, key.utf8.count <= 1024,
              !key.contains(where: { $0.isWhitespace }) else { throw CredentialError.invalidKey }
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8),
                                       kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw CredentialError.unavailable(updated) }
        let added = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard added == errSecSuccess else { throw CredentialError.unavailable(added) }
    }

    public static func read() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialError.unavailable(status) }
        guard let data = result as? Data, data.count <= 1024,
              let value = String(data: data, encoding: .utf8) else { throw CredentialError.invalidKey }
        return value
    }

    public static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.unavailable(status) }
    }
}
