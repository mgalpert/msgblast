import Foundation

public enum WebProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case muse, chatgpt, claude, grok, codexCLI, claudeCode, dots, grokbot, os3
    public static let webDefaults: [Self] = [.muse, .chatgpt, .claude, .grok]
    public static let optionalProviders: [Self] = [.codexCLI, .claudeCode]
    public var id: String { rawValue }
    public var usesNativeConversation: Bool { personalAgentProvider != nil || self == .grokbot }
    public var personalAgentProvider: PersonalAgentProvider? {
        switch self { case .codexCLI: .codex; case .claudeCode: .claude; default: nil }
    }
    public var name: String {
        switch self { case .muse: "Muse"; case .chatgpt: "ChatGPT"; case .claude: "Claude"; case .grok: "Grok"; case .codexCLI: "Codex CLI"; case .claudeCode: "Claude Code"; case .dots: "Dots"; case .grokbot: "Grok Bot"; case .os3: "rabbit OS3" }
    }
    public var homeURL: URL {
        switch self {
        case .muse: URL(string: "https://muse.ai/")!
        case .dots: URL(string: "https://chatgpt.com/dots")!
        case .chatgpt, .codexCLI: URL(string: "https://chatgpt.com/")!
        case .claude, .claudeCode: URL(string: "https://claude.ai/new")!
        case .grok: URL(string: "https://grok.com/")!
        case .grokbot: URL(string: "https://x.ai/bot")!
        case .os3: URL(string: "https://os3.rabbit.tech/")!
        }
    }
    // These directory names were used before CLI identities were separated. Claude
    // associates resumed sessions with their working directory; do not rename them.
    var localConversationDirectoryName: String {
        switch self { case .codexCLI: "chatgpt"; case .claudeCode: "claude"; default: rawValue }
    }
    // rabbit OS3 keeps one conversation per account, so every comparison uses it.
    public var sharesOneConversation: Bool { self == .os3 }
    public var newChatURL: URL { self == .muse ? URL(string: "https://muse.ai/thread/new")! : homeURL }
    public func isSavedConversation(_ url: URL) -> Bool {
        guard isChatURL(url), url.query == nil, url.fragment == nil else { return false }
        return sharesOneConversation || (!url.path.isEmpty && url.path != "/" && url.path != newChatURL.path && (self != .dots || url.path != "/dots/"))
    }
    // A Grok response selector is not part of the persistent conversation identity.
    public func canonicalConversationURL(_ url: URL) -> URL? {
        guard isChatURL(url), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if self == .grok, let items = parts.queryItems, items.count == 1,
           items[0].name == "rid", let value = items[0].value, value.utf8.count == 36, UUID(uuidString: value) != nil {
            parts.query = nil
        }
        guard let canonical = parts.url, isSavedConversation(canonical) else { return nil }
        return canonical
    }
    // Keep Muse's original file and WebKit data-store identifier through the upgrade.
    public var storageFilename: String { self == .muse ? "web-services.json" : "web-\(rawValue).json" }
    public func isChatURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host == homeURL.host, url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        let path = url.path
        switch self {
        case .codexCLI, .claudeCode, .grokbot: return false
        case .muse:
            return url.query == nil && url.fragment == nil && (path == "/thread/new" ||
                path.range(of: #"^/thread/[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$"#, options: .regularExpression) != nil)
        case .dots:
            return url.query == nil && url.fragment == nil && (path == "/dots" || path == "/dots/" || path == "/dots/home" ||
                path.range(of: #"^/dots/[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$"#, options: .regularExpression) != nil)
        case .chatgpt: return path.isEmpty || path == "/" || path.range(of: #"^/c/[a-zA-Z0-9-]+/?$"#, options: .regularExpression) != nil
        case .claude: return path == "/new" || path.range(of: #"^/chat/[a-zA-Z0-9-]+/?$"#, options: .regularExpression) != nil
        case .grok: return path.isEmpty || path == "/" || path.range(of: #"^/c/[a-zA-Z0-9-]+/?$"#, options: .regularExpression) != nil
        case .os3: return path.isEmpty || path == "/"
        }
    }
    // A first send can assign a conversation URL using history.replaceState.
    // Existing conversations must stay in the same saved chat; only Grok rid is normalized.
    public func acceptsReceipt(from original: URL, at current: URL) -> Bool {
        guard isChatURL(original), let destination = canonicalConversationURL(current) else { return false }
        return original == newChatURL || canonicalConversationURL(original) == destination
    }
}
