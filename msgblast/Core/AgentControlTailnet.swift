import CryptoKit
import Darwin
import Foundation
import Security

/// Tailscale's CGNAT ranges, and the per-client secret a remote MCP client must present.
public enum AgentControlTailnet {
    public static let grokBotClient = "Grok Bot (Tailscale)"
    public static let maximumClientName = 48

    /// What kind of agent an approved name is, for anonymous agent-usage counts. Names never leave the Mac;
    /// only `telemetryID` does. Settings offers these when adding an agent; any other name is `other`.
    public enum Kind: String, CaseIterable, Sendable {
        case claudeCode, codex, cursor, geminiCLI, chatGPT, claudeDesktop, grokBot, other

        public var label: String {
            switch self {
            case .claudeCode: "Claude Code"
            case .codex: "Codex"
            case .cursor: "Cursor"
            case .geminiCLI: "Gemini CLI"
            case .chatGPT: "ChatGPT"
            case .claudeDesktop: "Claude Desktop"
            case .grokBot: "Grok Bot"
            case .other: "Other"
            }
        }

        public var telemetryID: String { "outside" + rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

        /// Matches by letters only, so "claude-code", "Claude Code 2 (Tailscale)" and "Claude Code" agree.
        public init(name: String) {
            let letters = name.lowercased().replacingOccurrences(of: "(tailscale)", with: "").filter(\.isLetter)
            let order: [Kind] = [.claudeCode, .claudeDesktop, .codex, .cursor, .geminiCLI, .chatGPT, .grokBot]
            self = order.first { letters.hasPrefix($0.label.lowercased().filter(\.isLetter)) } ?? .other
        }
    }

    /// The saved name for an agent the person adds by hand, cleaned exactly as `AgentControlGate.clientName`
    /// cleans approval names (so the key's name and its approval's name always match), with one " (Tailscale)"
    /// suffix. "Grok Bot" becomes `grokBotClient`. Nil when empty or too long.
    public static func remoteClientName(_ typed: String) -> String? {
        guard var name = AgentControlGate.clientName(typed) else { return nil }
        while name.lowercased().hasSuffix("(tailscale)") {
            name = String(name.dropLast("(tailscale)".count)).trimmingCharacters(in: .whitespaces)
        }
        guard !name.isEmpty, name.count <= maximumClientName else { return nil }
        return "\(name) (Tailscale)"
    }

    /// IPv4 `100.64.0.0/10`, IPv6 `fd7a:115c:a1e0::/48`, including a zone and IPv4-mapped `::ffff:100.x`.
    public static func isTailnetPeer(_ address: String) -> Bool {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("["), let end = text.firstIndex(of: "]") {
            text = String(text[text.index(after: text.startIndex)..<end])
        }
        if let zone = text.firstIndex(of: "%") { text = String(text[..<zone]) }
        if text.contains(":") {
            guard let bytes = ipv6(text), bytes.count == 16 else { return false }
            if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
                return isCGNAT(bytes[12], bytes[13])
            }
            return bytes[0] == 0xfd && bytes[1] == 0x7a && bytes[2] == 0x11 && bytes[3] == 0x5c && bytes[4] == 0xa1 && bytes[5] == 0xe0
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, let a = octet(parts[0]), let b = octet(parts[1]), octet(parts[2]) != nil, octet(parts[3]) != nil else { return false }
        return isCGNAT(a, b)
    }

    /// Tailscale addresses on `utun` interfaces that are up and not loopback. IPv4 `100.64.0.0/10` and IPv6 `fd7a:115c:a1e0::/48`.
    public static func tailnetAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return [] }
        defer { freeifaddrs(head) }
        var found: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let current = cursor {
            let next = current.pointee.ifa_next
            if let text = utunAddress(current), isTailnetPeer(text), !found.contains(text) { found.append(text) }
            cursor = next
        }
        return found
    }

    /// 32 random bytes, base64url, no padding.
    public static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Lowercase hex SHA-256 of the token. This is what is saved.
    public static func tokenHash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time compare. Nil or empty never matches.
    public static func tokenMatches(_ given: String?, _ expected: String) -> Bool {
        guard let given, !given.isEmpty, !expected.isEmpty else { return false }
        let left = Array(given.utf8), right = Array(expected.utf8)
        var mismatch = left.count == right.count ? 0 : 1
        for index in 0..<max(left.count, right.count) {
            let a: UInt8 = index < left.count ? left[index] : 0
            let b: UInt8 = index < right.count ? right[index] : 0
            mismatch |= Int(a ^ b)
        }
        return mismatch == 0
    }

    /// Hash `given`, then compare that hash to `expectedHash` in constant time.
    public static func hashMatches(_ given: String?, _ expectedHash: String) -> Bool {
        guard let given, !given.isEmpty, !expectedHash.isEmpty else { return false }
        return tokenMatches(tokenHash(given), expectedHash.lowercased())
    }

    private static func isCGNAT(_ first: UInt8, _ second: UInt8) -> Bool {
        first == 100 && (64...127).contains(Int(second))
    }

    private static func octet(_ text: Substring) -> UInt8? {
        guard !text.isEmpty, text.count <= 3, text.allSatisfy(\.isNumber), let value = Int(text), (0...255).contains(value) else { return nil }
        return UInt8(value)
    }

    private static func utunAddress(_ interface: UnsafeMutablePointer<ifaddrs>) -> String? {
        let flags = interface.pointee.ifa_flags
        let name = String(cString: interface.pointee.ifa_name)
        guard name.hasPrefix("utun"), (flags & UInt32(IFF_UP)) != 0, (flags & UInt32(IFF_LOOPBACK)) == 0 else { return nil }
        guard let addr = interface.pointee.ifa_addr else { return nil }
        if addr.pointee.sa_family == sa_family_t(AF_INET) {
            var inet = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            return render(AF_INET, &inet, Int(INET_ADDRSTRLEN))
        }
        if addr.pointee.sa_family == sa_family_t(AF_INET6) {
            var inet = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            return render(AF_INET6, &inet, Int(INET6_ADDRSTRLEN))
        }
        return nil
    }

    private static func render(_ family: Int32, _ address: UnsafeRawPointer, _ length: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: length)
        guard inet_ntop(family, address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        let text = String(cString: buffer)
        return text.isEmpty ? nil : text
    }

    private static func ipv6(_ text: String) -> [UInt8]? {
        guard let split = ipv4Tail(text) else { return nil }
        let halves = split.head.split(separator: "::", omittingEmptySubsequences: false)
        guard (1...2).contains(halves.count), let left = groups(halves[0]), let right = halves.count == 2 ? groups(halves[1]) : [] else { return nil }
        let missing = 8 - split.tail.count / 2 - left.count - right.count
        guard halves.count == 1 ? missing == 0 : missing >= 1 else { return nil }
        let combined = left + Array(repeating: 0, count: missing) + right
        return combined.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xff)] } + split.tail
    }

    /// Splits off a trailing dotted IPv4 part (`::ffff:1.2.3.4`); an address without one has an empty tail.
    private static func ipv4Tail(_ text: String) -> (head: String, tail: [UInt8])? {
        guard text.contains(".") else { return (text, []) }
        guard let colon = text.lastIndex(of: ":") else { return nil }
        let octets = text[text.index(after: colon)...].split(separator: ".", omittingEmptySubsequences: false)
        let bytes = octets.compactMap(octet)
        guard octets.count == 4, bytes.count == 4 else { return nil }
        return (String(text[..<colon]), bytes)
    }

    private static func groups(_ part: Substring) -> [UInt16]? {
        if part.isEmpty { return [] }
        var values: [UInt16] = []
        for piece in part.split(separator: ":", omittingEmptySubsequences: false) {
            guard (1...4).contains(piece.count), let value = UInt16(piece, radix: 16) else { return nil }
            values.append(value)
        }
        return values
    }
}

/// `outside-agents-tailnet.json`: enabled, port, and one SHA-256 hash per client. The token itself is never written.
/// An unreadable file refuses every token and is never overwritten.
public struct AgentControlTailnetStore: Equatable, Sendable {
    public static let fileName = "outside-agents-tailnet.json"
    public static let defaultPort = 47480
    public var enabled: Bool
    public var port: Int
    public private(set) var hashes: [String: String]
    public let loadFailed: Bool

    public init(enabled: Bool = false, port: Int = AgentControlTailnetStore.defaultPort, hashes: [String: String] = [:], loadFailed: Bool = false) {
        self.enabled = enabled
        self.port = port
        self.hashes = hashes
        self.loadFailed = loadFailed
    }

    public static func load(_ file: URL) -> AgentControlTailnetStore {
        guard FileManager.default.fileExists(atPath: file.path) else { return AgentControlTailnetStore() }
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let enabled = root["enabled"] as? Bool,
              let port = root["port"] as? Int, (1...65535).contains(port) else {
            return AgentControlTailnetStore(loadFailed: true)
        }
        guard var hashes = clientHashes(root["clients"]) else {
            return AgentControlTailnetStore(loadFailed: true)
        }
        if let token = root["token"] as? String, !token.isEmpty, hashes[AgentControlTailnet.grokBotClient] == nil {
            hashes[AgentControlTailnet.grokBotClient] = AgentControlTailnet.tokenHash(token)
        }
        var store = AgentControlTailnetStore(enabled: enabled, port: port, hashes: hashes)
        if root["token"] != nil { try? store.save(file) }
        return store
    }

    public func save(_ file: URL) throws {
        guard !loadFailed else { return }
        let body: [String: Any] = ["clients": hashes, "enabled": enabled, "port": port]
        try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// New token for `client`. Returns the plaintext once; only its hash is kept.
    public mutating func issue(_ client: String) -> String? {
        guard !loadFailed, !client.isEmpty else { return nil }
        let token = AgentControlTailnet.newToken()
        hashes[client] = AgentControlTailnet.tokenHash(token)
        return token
    }

    public mutating func revoke(_ client: String) {
        guard !loadFailed else { return }
        hashes[client] = nil
    }

    /// The client whose saved hash matches `token`, or nil. A failed load matches nothing.
    public func client(matching token: String?) -> String? {
        guard !loadFailed, let token, !token.isEmpty else { return nil }
        var found: String?
        for (name, hash) in hashes {
            if AgentControlTailnet.hashMatches(token, hash) { found = name }
        }
        return found
    }

    /// Missing `clients` is an empty map. A present value that is not a string map is unreadable.
    private static func clientHashes(_ value: Any?) -> [String: String]? {
        guard let value else { return [:] }
        guard let object = value as? [String: Any] else { return nil }
        var hashes: [String: String] = [:]
        for (name, item) in object {
            guard let item = item as? String else { return nil }
            hashes[name] = item
        }
        return hashes
    }
}
