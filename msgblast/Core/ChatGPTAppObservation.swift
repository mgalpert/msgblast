import ApplicationServices
import Darwin
import Foundation

public enum ChatGPTAppKind: String, Codable, Sendable { case chatgpt, dots }
public struct ChatGPTConversationBinding: Codable, Equatable, Sendable {
    public let comparisonID: UUID
    public let kind: ChatGPTAppKind
    public var title: String?
    public var firstPrompt: String?
    public var fallbackTitle: String?
    public init(comparisonID: UUID, kind: ChatGPTAppKind, title: String? = nil, firstPrompt: String? = nil, fallbackTitle: String? = nil) {
        self.comparisonID = comparisonID; self.kind = kind; self.title = title; self.firstPrompt = firstPrompt; self.fallbackTitle = fallbackTitle
    }
    public var dedicatedTitle: String { "msgblast \(comparisonID.uuidString)" }
    func firstMessage(_ prompt: String) -> String { "[msgblast comparison \(comparisonID.uuidString)]\n\n\(prompt)" }
}
struct ChatGPTAXNode: Sendable {
    var role: String
    var label = ""
    var value: String?
    var id = ""
    var subrole = ""
    var classes: [String] = []
    var url = ""
    var selectedText: String?
    var enabled = true
    var focused = false
    var frame: DesktopAppSnapshot.Element.Frame?
    var children: [Self] = []
    var descendants: [Self] { [self] + children.flatMap(\.descendants) }
    var visible: Bool { frame.map { $0.w > 0 && $0.h > 0 } ?? false }
}
struct ChatGPTMessage: Equatable, Sendable {
    enum Role: Sendable { case user, assistant }
    var role: Role
    var text: String
}
enum ChatGPTObservationError: LocalizedError, Sendable {
    case transient
    var errorDescription: String? { "ChatGPT’s native window is temporarily unavailable." }
}
struct ChatGPTAppObservation: Sendable {
    let nodes: [ChatGPTAXNode]
    let title: String
    let kind: ChatGPTAppKind
    let draft: String
    let generating: Bool
    let messages: [ChatGPTMessage]
    let composer: ChatGPTAXNode
    let codexBootstrap: Bool
    var isNew: Bool { kind == .chatgpt && !codexBootstrap && messages.isEmpty }
    init(root: ChatGPTAXNode) throws {
        guard root.role == "AXWindow" else { throw DesktopAppError.unavailable("Open ChatGPT’s main window.") }
        let windowTitle = root.label
        title = windowTitle
        let all = root.descendants
        guard let web = all.first(where: { $0.role == "AXWebArea" && $0.url == "app://-/index.html" }) else { throw DesktopAppError.unavailable("This ChatGPT application version is not supported yet.") }
        // Nested web areas belong to browser tabs and embedded apps, never ChatGPT.
        func safe(_ n: ChatGPTAXNode) -> [ChatGPTAXNode] {
            [n] + n.children.filter { $0.role != "AXWebArea" }.flatMap(safe)
        }
        nodes = safe(web)
        guard !nodes.contains(where: { ["AXDialog", "AXSheet"].contains($0.role) }) else { throw DesktopAppError.unavailable("Dismiss ChatGPT’s dialog before continuing.") }
        let codexFields = nodes.filter { $0.role == "AXTextArea" && $0.label == "Work with ChatGPT" }
        if nodes.filter({ $0.role == "AXPopUpButton" && ["Switch mode, current mode: Codex", "Switch mode, current mode: ChatGPT"].contains($0.label) }).count == 1, codexFields.count == 1, let value = codexFields[0].value {
            composer = codexFields[0]; kind = .chatgpt; codexBootstrap = true
            draft = composer.descendants.contains(where: { $0.classes.contains("placeholder") }) && ["Work with ChatGPT\n", "\n"].contains(value) ? "" : value
            generating = false; messages = []; return
        }
        codexBootstrap = false
        let panels = nodes.filter { $0.id.hasSuffix("-chat-panel") }
        guard panels.count == 1 else { throw DesktopAppError.unavailable("ChatGPT’s native conversation panel is unavailable.") }
        let panel = safe(panels[0])
        let fields = panel.filter { $0.role == "AXTextArea" && ["Ask ChatGPT", "Message"].contains($0.label) }
        guard fields.count == 1, let value = fields[0].value else { throw DesktopAppError.unavailable("ChatGPT’s message field is unavailable. Your draft was preserved.") }
        composer = fields[0]
        kind = composer.label == "Message" ? .dots : .chatgpt
        let placeholder = kind == .dots ? "Send a message" : "Ask ChatGPT"
        let hasPlaceholder = composer.descendants.contains { $0.classes.contains("placeholder") }
        draft = hasPlaceholder && value == placeholder + "\n" ? "" : try Self.paragraphDraft(composer, raw: value)
        generating = panel.contains { $0.role == "AXButton" && ["Stop", "Stop generating", "Stop response"].contains($0.label) }
        if kind == .dots {
            guard nodes.filter({ $0.role == "AXPopUpButton" && $0.label == "Open \(windowTitle)’s profile" }).count == 1 else { throw DesktopAppError.unavailable("The active Dot’s identity could not be verified.") }
            let lists = panel.filter { $0.classes.contains("message-list") }
            guard lists.count == 1 else { throw DesktopAppError.unavailable("The Dot’s message list is unavailable.") }
            messages = try lists[0].children.filter { $0.classes.contains("message-row") }.compactMap { row in
                let bubbles = row.descendants.filter { $0.classes.contains("message-bubble") }
                guard bubbles.count <= 1 else { throw DesktopAppError.unavailable("The Dot’s message layout changed.") }
                guard let body = bubbles.first else { return nil }
                let text = Self.bodyText(body)
                return text.isEmpty ? nil : .init(role: row.classes.contains("self") ? .user : .assistant, text: text)
            }
        } else {
            let transcripts = panel.filter { $0.classes.contains(where: { $0.hasPrefix("_transcriptContent_") }) }
            guard transcripts.count <= 1 else { throw DesktopAppError.unavailable("ChatGPT’s transcript is ambiguous.") }
            var result: [ChatGPTMessage] = []
            for turn in transcripts.first?.children ?? [] {
                var role: ChatGPTMessage.Role?, parts: [String] = []
                func flush() { if let role, !parts.isEmpty { result.append(.init(role: role, text: parts.joined(separator: "\n\n"))) }; parts = [] }
                for child in turn.children {
                    if child.role == "AXHeading", ["You said:", "ChatGPT said:"].contains(child.label) {
                        flush(); role = child.label == "You said:" ? .user : .assistant
                    } else if role != nil {
                        let text = Self.bodyText(child)
                        if !text.isEmpty { parts.append(text) }
                    }
                }
                flush()
            }
            messages = result
        }
    }
    private static func paragraphDraft(_ field: ChatGPTAXNode, raw: String) throws -> String {
        if field.children.isEmpty { return raw }
        func paragraph(_ node: ChatGPTAXNode) throws -> String {
            if node.role == "AXStaticText", let value = node.value { return value }
            guard node.role == "AXGroup" else { throw DesktopAppError.unavailable("ChatGPT’s draft contains unsupported rich content. It was preserved.") }
            return try node.children.map(paragraph).joined()
        }
        guard field.children.allSatisfy({ $0.role == "AXGroup" }) else { throw DesktopAppError.unavailable("ChatGPT’s draft paragraph boundaries are unavailable.") }
        let paragraphs = try field.children.map(paragraph)
        let actual = paragraphs.joined(separator: "\n")
        // Electron's AXValue omits empty paragraphs after later text is entered.
        // The independently exposed paragraph groups preserve those line breaks.
        guard raw == actual || raw == paragraphs.filter({ !$0.isEmpty }).joined(separator: "\n") else {
            throw DesktopAppError.unavailable("ChatGPT’s draft text and native paragraphs disagree. It was preserved.")
        }
        return actual
    }
    private static func bodyText(_ node: ChatGPTAXNode) -> String {
        if ["AXButton", "AXPopUpButton", "AXCheckBox", "AXWebArea"].contains(node.role) || node.classes.contains("sr-only") || node.subrole == "AXApplicationStatus" { return "" }
        if node.role == "AXStaticText" { return node.value ?? "" }
        if node.role == "AXHeading", node.children.isEmpty { return node.label }
        let paragraphs = !node.children.isEmpty && node.children.allSatisfy {
            $0.role == "AXGroup" && $0.classes.contains { $0.hasPrefix("_Paragraph_") }
        }
        return node.children.map(bodyText).filter { !$0.isEmpty }.joined(separator: paragraphs ? "\n\n" : "\n")
    }
    func appendedMessages(after baseline: [ChatGPTMessage]) throws -> [ChatGPTMessage] {
        guard messages.count >= baseline.count else { throw DesktopAppError.unavailable("ChatGPT’s conversation changed. No reply was attributed.") }
        // Dots may load older history above an unchanged, exact baseline after Send.
        let maximumOffset = kind == .dots && !baseline.isEmpty ? messages.count - baseline.count : 0
        let offsets = (0...maximumOffset).filter { offset in
            let end = offset + baseline.count
            return messages.count - end <= 2 && Array(messages[offset..<end]) == baseline
        }
        guard offsets.count == 1, let offset = offsets.first else { throw DesktopAppError.unavailable("ChatGPT’s conversation changed. No reply was attributed.") }
        return Array(messages.dropFirst(offset + baseline.count))
    }
    func control(label: String, role: String = "AXButton") throws -> ChatGPTAXNode {
        try unique(nodes.filter { $0.label == label && $0.role == role && $0.enabled && $0.visible })
    }
    func unique(_ candidates: [ChatGPTAXNode]) throws -> ChatGPTAXNode {
        guard candidates.count == 1 else { throw DesktopAppError.unavailable("ChatGPT’s requested control is unavailable or ambiguous.") }
        return candidates[0]
    }
    func sameContent(as other: Self) -> Bool { title == other.title && codexBootstrap == other.codexBootstrap && kind == other.kind && draft == other.draft && messages == other.messages }
}
enum ChatGPTNativeReader {
    static func capture(_ target: DesktopAppConversation.Target) throws -> ChatGPTAppObservation {
        guard AXIsProcessTrusted() else { throw DesktopAppError.unavailable("Allow msgblast Accessibility access to connect ChatGPT.") }
        func attr(_ e: AXUIElement, _ key: String) -> CFTypeRef? { var value: CFTypeRef?; return AXUIElementCopyAttributeValue(e, key as CFString, &value) == .success ? value : nil }
        func string(_ e: AXUIElement, _ key: String) -> String { attr(e, key) as? String ?? "" }
        guard let window = DesktopNativeWindowLookup.resolve(target) else { throw ChatGPTObservationError.transient }
        var count = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        func walk(_ e: AXUIElement, depth: Int, insideWeb: Bool = false) throws -> ChatGPTAXNode {
            count += 1
            guard count <= 6000, depth <= 60, ContinuousClock.now < deadline else { throw ChatGPTObservationError.transient }
            let role = string(e, "AXRole")
            guard !role.isEmpty else { throw ChatGPTObservationError.transient }
            let title = string(e, "AXTitle"), desc = string(e, "AXDescription")
            var frame: DesktopAppSnapshot.Element.Frame?
            if let p = attr(e, "AXPosition"), let s = attr(e, "AXSize"), CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() {
                var point = CGPoint.zero, size = CGSize.zero
                if AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) { frame = .init(x: point.x, y: point.y, w: size.width, h: size.height) }
            }
            let nestedWeb = role == "AXWebArea" && insideWeb
            let children = nestedWeb ? [] : try (attr(e, "AXChildren") as? [AXUIElement] ?? []).map { try walk($0, depth: depth + 1, insideWeb: insideWeb || role == "AXWebArea") }
            let value = attr(e, "AXValue"), url = attr(e, "AXURL")
            return .init(role: role, label: title.isEmpty ? desc : title, value: (value as? String) ?? (value as? NSNumber)?.stringValue,
                         id: string(e, "AXDOMIdentifier"), subrole: string(e, "AXSubrole"), classes: attr(e, "AXDOMClassList") as? [String] ?? [],
                         url: (url as? URL)?.absoluteString ?? (url as? String ?? ""), selectedText: attr(e, "AXSelectedText") as? String,
                         enabled: attr(e, "AXEnabled") as? Bool != false, focused: attr(e, "AXFocused") as? Bool == true, frame: frame, children: children)
        }
        return try ChatGPTAppObservation(root: walk(window, depth: 0))
    }
}
