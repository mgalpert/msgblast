import ApplicationServices
import Darwin
import Foundation

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

    init(root: ClaudeAXNode) throws {
        windowBounds = root.frame.map { .init(x: $0.x, y: $0.y, width: $0.w, height: $0.h) }
        let nodes = root.descendants
        guard !nodes.contains(where: { ["AXSheet", "AXDialog"].contains($0.role) || $0.subrole == "AXDialog" }) else {
            throw DesktopAppError.unavailable("Dismiss Claude's dialog before continuing.")
        }
        let areas = nodes.filter { $0.role == "AXWebArea" && $0.url.map { ClaudeChatURL.isChat($0) || ClaudeChatURL.isNew($0) } == true }
        guard areas.count == 1, let url = areas[0].url else { throw DesktopAppError.unavailable("Claude's native chat address is unavailable or ambiguous.") }
        let areaNodes = areas[0].descendants
        let main = areaNodes.filter { $0.subrole == "AXLandmarkMain" }
        guard main.count == 1 else { throw DesktopAppError.unavailable("Claude's main conversation could not be separated from its sidebar.") }
        let controls = main[0].descendants
        let fields = controls.filter { $0.role == "AXTextArea" && $0.label == "Write your prompt to Claude" }
        guard fields.count == 1 else { throw DesktopAppError.unavailable("Claude's draft is unreadable. It was preserved.") }
        composerFrame = fields[0].frame
        composerFocused = fields[0].focused
        let nativeDraft = try ClaudeNativeDraft.read(fields[0])
        rawNativeDraft = nativeDraft.raw
        draft = nativeDraft.actual
        let lists = controls.filter { $0.role == "AXGroup" && $0.label == "Chat messages" }
        guard lists.count <= 1 else { throw DesktopAppError.unavailable("Claude's transcript is ambiguous.") }
        let articles = lists.first?.descendants.filter { $0.subrole == "AXDocumentArticle" } ?? []
        messages = try articles.enumerated().map { index, article in
            guard article.label == "Message \(index + 1) of \(articles.count)" else { throw ClaudeObservationError.transient("Claude's message history is incomplete. No reply was attributed.") }
            let headings = article.descendants.filter { $0.role == "AXHeading" && ($0.label.hasPrefix("You said:") || $0.label.hasPrefix("Claude responded:")) }
            if headings.isEmpty, !article.descendants.contains(where: { $0.role == "AXHeading" }) {
                throw ClaudeObservationError.transient("Claude's message sender has not finished rendering. No reply was attributed.")
            }
            guard headings.count == 1 else { throw DesktopAppError.unavailable("Claude's message sender is unavailable. No reply was attributed.") }
            if headings[0].label.hasPrefix("Claude responded:") {
                let body = String(headings[0].label.dropFirst("Claude responded:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { throw ClaudeObservationError.transient("Claude exposed an incomplete assistant message.") }
                return .init(role: .assistant, text: body)
            }
            func text(_ node: ClaudeAXNode) -> [String] {
                guard node.role != "AXHeading", node.role != "AXToolbar", !node.classes.contains("sr-only") else { return [] }
                if node.role == "AXStaticText" { return node.value.map { [$0] } ?? [] }
                return node.children.flatMap(text)
            }
            let body = text(article).joined(separator: "\n\n")
            guard !body.isEmpty else { throw ClaudeObservationError.transient("Claude exposed an incomplete outgoing message.") }
            return .init(role: .user, text: body)
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

enum ClaudeObservationError: LocalizedError {
    case transient(String)
    var errorDescription: String? { switch self { case .transient(let message): message } }
}

// Claude's Electron wrapper and its conversation expose different AXWebAreas.
// Use the exact native window and the inner canonical address, never its title.
enum ClaudeNativeReader {
    static func capture(_ target: DesktopAppConversation.Target) throws -> ClaudeAppObservation {
        guard AXIsProcessTrusted() else { throw DesktopAppError.unavailable("Grant msgblast Accessibility permission to verify Claude's conversation.") }
        func attr(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
        }
        func string(_ element: AXUIElement, _ key: String) -> String { attr(element, key) as? String ?? "" }
        guard let window = DesktopNativeWindowLookup.resolve(target) else { throw DesktopAppError.unavailable("Claude's exact main window is unavailable. Dismiss dialogs and try again.") }
        var count = 0
        var addresses: [(AXUIElement, URL)] = []
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        func walk(_ element: AXUIElement, depth: Int) throws -> ClaudeAXNode {
            count += 1
            guard count <= 6000, depth <= 60, ContinuousClock.now < deadline else { throw ClaudeObservationError.transient("Claude's native accessibility tree is incomplete.") }
            let role = string(element, "AXRole")
            guard !role.isEmpty else { throw ClaudeObservationError.transient("Claude's native accessibility tree changed while reading.") }
            func point(_ key: String) -> CGPoint? {
                guard let v = attr(element, key), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
                var point = CGPoint.zero
                return AXValueGetValue(v as! AXValue, .cgPoint, &point) ? point : nil
            }
            func size() -> CGSize? {
                guard let v = attr(element, "AXSize"), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
                var size = CGSize.zero
                return AXValueGetValue(v as! AXValue, .cgSize, &size) ? size : nil
            }
            let frame: DesktopAppSnapshot.Element.Frame?
            if let origin = point("AXPosition"), let size = size() { frame = .init(x: origin.x, y: origin.y, w: size.width, h: size.height) } else { frame = nil }
            let title = string(element, "AXTitle")
            let url = attr(element, "AXURL") as? URL
            if role == "AXWebArea", let url, ClaudeChatURL.isNew(url) || ClaudeChatURL.isChat(url) { addresses.append((element, url)) }
            return ClaudeAXNode(role: role, subrole: string(element, "AXSubrole"), label: title.isEmpty ? string(element, "AXDescription") : title,
                                value: attr(element, "AXValue") as? String, classes: attr(element, "AXDOMClassList") as? [String] ?? [], url: url, frame: frame, focused: attr(element, "AXFocused") as? Bool ?? false,
                                children: try (attr(element, "AXChildren") as? [AXUIElement] ?? []).map { try walk($0, depth: depth + 1) })
        }
        let observation = try ClaudeAppObservation(root: walk(window, depth: 0))
        guard addresses.count == 1, attr(addresses[0].0, "AXURL") as? URL == observation.url else { throw DesktopAppError.unavailable("Claude navigated while reading its conversation.") }
        return observation
    }
}
