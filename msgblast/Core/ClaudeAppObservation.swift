import Foundation
import CryptoKit

enum ClaudeChatURL {
    static func isChat(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host == "claude.ai", url.port == nil, url.user == nil,
              url.password == nil, url.query == nil, url.fragment == nil, url.absoluteString == "https://claude.ai" + url.path else { return false }
        return url.path.range(of: #"^/chat/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#, options: .regularExpression) != nil
    }
    static func isNew(_ url: URL) -> Bool { url.absoluteString == "https://claude.ai/new" }
}

public struct ClaudeConversationBinding: Codable, Equatable, Sendable {
    public let comparisonID: UUID
    public var url: URL?
    public var firstPrompt: String?
    public init(comparisonID: UUID, url: URL? = nil, firstPrompt: String? = nil) {
        self.comparisonID = comparisonID; self.url = url; self.firstPrompt = firstPrompt
    }
    func firstMessage(_ prompt: String) -> String { "[msgblast comparison \(comparisonID.uuidString)]\n\n\(prompt)" }
}

struct ClaudeAppMessage: Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }
    let role: Role
    let text: String
}

struct ClaudeAXNode: Sendable {
    let role: String
    var subrole = ""
    var label = ""
    var value: String?
    var classes: [String] = []
    var url: URL?
    var frame: DesktopAppSnapshot.Element.Frame?
    var focused = false
    var children: [ClaudeAXNode] = []
    var descendants: [ClaudeAXNode] { [self] + children.flatMap(\.descendants) }
}

enum ClaudeNativeDraft {
    static func read(_ field: ClaudeAXNode) throws -> (raw: String, actual: String) {
        guard let raw = field.value else { throw DesktopAppError.unavailable("Claude's draft is unreadable. It was preserved.") }
        let empty = field.children.count == 1 && Set(["is-empty", "is-editor-empty"]).isSubset(of: Set(field.children[0].classes))
        if raw == "\n" && empty { return (raw, "") }
        if field.children.isEmpty { return (raw, raw) }
        func paragraph(_ node: ClaudeAXNode) throws -> String {
            if node.role == "AXStaticText", let value = node.value { return value }
            guard node.role == "AXGroup" else { throw DesktopAppError.unavailable("Claude's draft contains unsupported rich content. It was preserved.") }
            return try node.children.map(paragraph).joined()
        }
        guard field.children.allSatisfy({ $0.role == "AXGroup" }) else { throw DesktopAppError.unavailable("Claude's draft paragraph boundaries are unavailable.") }
        let paragraphs = try field.children.map(paragraph)
        let actual = paragraphs.joined(separator: "\n")
        // Claude's AXValue omits empty paragraphs once later text is entered.
        // Preserve those independently exposed paragraph boundaries exactly.
        guard raw == actual || raw == paragraphs.filter({ !$0.isEmpty }).joined(separator: "\n") else {
            throw DesktopAppError.unavailable("Claude's draft text and native paragraphs disagree. It was preserved.")
        }
        return (raw, actual)
    }
}

struct ClaudeAppObservation: Sendable, Equatable {
    enum ReadMode: Sendable { case conversation, navigation }
    struct Link: Sendable, Equatable { let label: String; let url: URL }
    let url: URL
    let draft: String
    let rawNativeDraft: String
    let messages: [ClaudeAppMessage]
    let generating: Bool
    let links: [Link]
    let windowBounds: DesktopAppSnapshot.Bounds?
    let composerFrame: DesktopAppSnapshot.Element.Frame?
    let composerFocused: Bool

    init(root: ClaudeAXNode, mode: ReadMode = .conversation) throws {
        windowBounds = root.frame.map { .init(x: $0.x, y: $0.y, width: $0.w, height: $0.h) }
        let nodes = root.descendants
        guard !nodes.contains(where: { ["AXSheet", "AXDialog"].contains($0.role) || $0.subrole == "AXDialog" }) else {
            throw DesktopAppError.unavailable("Dismiss Claude's dialog before continuing.")
        }
        let areas = nodes.filter { $0.role == "AXWebArea" && $0.url.map { ClaudeChatURL.isChat($0) || ClaudeChatURL.isNew($0) } == true }
        guard !areas.isEmpty else { throw ClaudeObservationError.transient("Claude is still opening its native chat.") }
        guard areas.count == 1, let url = areas[0].url else { throw DesktopAppError.unavailable("Claude's native chat address is unavailable or ambiguous.") }
        let areaNodes = areas[0].descendants
        let main = areaNodes.filter { $0.subrole == "AXLandmarkMain" }
        guard !main.isEmpty else { throw ClaudeObservationError.transient("Claude's conversation is still loading.") }
        guard main.count == 1 else { throw DesktopAppError.unavailable("Claude's main conversation could not be separated from its sidebar.") }
        let controls = main[0].descendants
        let fields = controls.filter { $0.role == "AXTextArea" && $0.label == "Write your prompt to Claude" }
        guard !fields.isEmpty else { throw ClaudeObservationError.transient("Claude's message field is still loading.") }
        guard fields.count == 1 else { throw DesktopAppError.unavailable("Claude's draft is unreadable. It was preserved.") }
        composerFrame = fields[0].frame
        composerFocused = fields[0].focused
        let nativeDraft = try ClaudeNativeDraft.read(fields[0])
        rawNativeDraft = nativeDraft.raw
        draft = nativeDraft.actual
        let lists = controls.filter { $0.role == "AXGroup" && $0.label == "Chat messages" }
        guard lists.count <= 1 else { throw DesktopAppError.unavailable("Claude's transcript is ambiguous.") }
        let articles = mode == .navigation ? [] : lists.first?.descendants.filter { $0.subrole == "AXDocumentArticle" } ?? []
        messages = try articles.enumerated().map { index, article in
            guard article.label == "Message \(index + 1) of \(articles.count)" else { throw ClaudeObservationError.transient("Claude's message history is incomplete. No reply was attributed.") }
            let headings = article.descendants.filter { $0.role == "AXHeading" && ($0.label.hasPrefix("You said:") || $0.label.hasPrefix("Claude responded:")) }
            if headings.isEmpty, !article.descendants.contains(where: { $0.role == "AXHeading" }) {
                throw ClaudeObservationError.transient("Claude's message sender has not finished rendering. No reply was attributed.")
            }
            guard headings.count == 1 else { throw DesktopAppError.unavailable("Claude's message sender is unavailable. No reply was attributed.") }
            let senderHeading = headings[0].label
            let role: ClaudeAppMessage.Role = senderHeading.hasPrefix("Claude responded:") ? .assistant : .user
            func text(_ node: ClaudeAXNode) -> [String] {
                guard !(node.role == "AXHeading" && node.label == senderHeading), node.role != "AXToolbar", !node.classes.contains("sr-only") else { return [] }
                if node.role == "AXStaticText" { return node.value.map { [$0] } ?? [] }
                return node.children.flatMap(text)
            }
            let body = text(article).joined(separator: "\n\n")
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClaudeObservationError.transient("Claude exposed an incomplete \(role == .assistant ? "assistant" : "outgoing") message.") }
            return .init(role: role, text: body)
        }
        guard !ClaudeChatURL.isNew(url) || messages.isEmpty else { throw DesktopAppError.unavailable("Claude's New chat contains unexpected messages.") }
        self.url = url
        generating = controls.contains { $0.role == "AXProgressIndicator" || ($0.role == "AXButton" && ["Stop", "Stop response", "Stop generating"].contains($0.label)) }
        links = areaNodes.compactMap { node in
            guard node.role == "AXLink", let url = node.url, ClaudeChatURL.isChat(url) else { return nil }
            return Link(label: node.label, url: url)
        }
    }
}

struct ClaudeAppReceipt {
    let baseline: [ClaudeAppMessage]
    let prompt: String
    func reply(in messages: [ClaudeAppMessage]) throws -> String? {
        if messages == baseline { return nil }
        guard messages.starts(with: baseline), messages.count <= baseline.count + 2,
              messages.dropFirst(baseline.count).first == .init(role: .user, text: prompt) else {
            throw DesktopAppError.unavailable("Claude's chat history changed or another outgoing message appeared. No reply was attributed.")
        }
        guard messages.count == baseline.count + 2 else { return nil }
        guard let answer = messages.last, answer.role == .assistant else { throw DesktopAppError.unavailable("Claude's new message has an unexpected sender.") }
        return answer.text
    }
}

struct ClaudeReplyReceipt: Codable, Equatable, Sendable {
    var version = 1
    let comparisonID: UUID
    let initialURL: URL?
    let prompt: String
    let baselineCount: Int
    let baselineDigest: Data
    var automaticRecovery = true

    init(comparisonID: UUID, initialURL: URL?, prompt: String, baseline: [ClaudeAppMessage]) throws {
        self.comparisonID = comparisonID; self.initialURL = initialURL; self.prompt = prompt
        baselineCount = baseline.count; baselineDigest = try Self.digest(baseline)
    }

    private static func digest(_ messages: [ClaudeAppMessage]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: try encoder.encode(messages)))
    }

    func reply(in messages: [ClaudeAppMessage]) throws -> String? {
        guard version == 1, !prompt.isEmpty, baselineCount >= 0, baselineDigest.count == 32,
              messages.count >= baselineCount, messages.count <= baselineCount + 2,
              try Self.digest(Array(messages.prefix(baselineCount))) == baselineDigest else {
            throw DesktopAppError.unavailable("Claude's saved chat history changed. No reply was attributed.")
        }
        let added = messages.dropFirst(baselineCount)
        guard !added.isEmpty else { return nil }
        guard added.first == ClaudeAppMessage(role: .user, text: prompt) else {
            throw DesktopAppError.unavailable("Another request appeared in Claude. No reply was attributed.")
        }
        guard added.count == 2 else { return nil }
        guard let answer = added.last, answer.role == .assistant else {
            throw DesktopAppError.unavailable("Claude's new message has an unexpected sender.")
        }
        return answer.text.isEmpty ? nil : answer.text
    }
}

enum ClaudeObservationError: LocalizedError {
    case transient(String)
    var errorDescription: String? { switch self { case .transient(let message): message } }
}

// Claude's Electron wrapper and its conversation expose different AXWebAreas.
// Use the exact native window and the inner canonical address, never its title.
enum ClaudeAppProfile {
    static func capture(_ target: DesktopAppConversation.Target, mode: ClaudeAppObservation.ReadMode = .conversation) throws -> ClaudeAppObservation {
        do { return try parse(DesktopAccessibility.capture(target, app: .claude), mode: mode) }
        catch DesktopAccessibilityError.incomplete { throw ClaudeObservationError.transient("Claude's controls are still updating.") }
    }
    static func parse(_ root: DesktopAccessibilityNode, mode: ClaudeAppObservation.ReadMode = .conversation) throws -> ClaudeAppObservation {
        func convert(_ node: DesktopAccessibilityNode) -> ClaudeAXNode {
            .init(role: node.role, subrole: node.subrole, label: node.label, value: node.value, classes: node.classes,
                  url: node.url, frame: node.frame, focused: node.focused, children: node.children.map(convert))
        }
        return try ClaudeAppObservation(root: convert(root), mode: mode)
    }
}
