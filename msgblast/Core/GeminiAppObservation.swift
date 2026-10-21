import ApplicationServices
import Darwin
import Foundation

public enum GeminiMode: String, CaseIterable, Codable, Sendable { case chat, task
    public var name: String { rawValue.capitalized }
}

public struct GeminiPreferences: Codable, Equatable, Sendable {
    public var mode: GeminiMode = .chat
    public var model: String?
    public var thinking: String?
    public init(mode: GeminiMode = .chat, model: String? = nil, thinking: String? = nil) {
        self.mode = mode; self.model = model; self.thinking = thinking
    }
}

public struct GeminiConversationBinding: Codable, Equatable, Sendable {
    public let comparisonID: UUID
    public let mode: GeminiMode
    public var title: String?
    public var firstPrompt: String?
    public var fallbackTitle: String?
    public init(comparisonID: UUID, mode: GeminiMode) { self.comparisonID = comparisonID; self.mode = mode }
    public var dedicatedTitle: String { "msgblast \(comparisonID.uuidString)" }
    func firstMessage(_ prompt: String) -> String { "[msgblast comparison \(comparisonID.uuidString)]\n\n\(prompt)" }
}

public struct GeminiOptions: Equatable, Sendable {
    public var models: [String] = []
    public var thinkingLevels: [String] = []
    public init(models: [String] = [], thinkingLevels: [String] = []) { self.models = models; self.thinkingLevels = thinkingLevels }
}

enum GeminiObservationError: LocalizedError, Sendable {
    case transient(String)
    var errorDescription: String? { switch self { case .transient(let message): message } }
}

struct GeminiSelectionError: LocalizedError, Sendable {
    let options: GeminiOptions
    let message: String
    var errorDescription: String? { message }
}

struct GeminiAXNode: Sendable {
    var role: String
    var label = ""
    var value: String?
    var id = ""
    var selected = false
    var enabled = true
    var selectedText: String?
    var frame: DesktopAppSnapshot.Element.Frame?
    var children: [GeminiAXNode] = []
    var descendants: [Self] { [self] + children.flatMap(\.descendants) }
}

struct GeminiMessage: Equatable, Sendable {
    enum Role: Sendable { case user, assistant }
    var role: Role
    var text: String
}

struct GeminiAppObservation: Sendable {
    let root: GeminiAXNode
    let title: String
    let draft: String
    let mode: GeminiMode?
    let model: String
    let generating: Bool
    let messages: [GeminiMessage]
    let nodes: [GeminiAXNode]
    var isNew: Bool { mode != nil && messages.isEmpty }

    init(root: GeminiAXNode, allowingRename: Bool = false) throws {
        self.root = root
        let nodes = root.descendants
        self.nodes = nodes
        guard root.role == "AXWindow", root.label.hasPrefix("Gemini — "),
              !nodes.contains(where: { $0.role == "AXDialog" || ($0.role == "AXSheet" && !allowingRename) }) else {
            throw DesktopAppError.unavailable("Open Gemini’s main chat window and dismiss its dialogs.")
        }
        title = String(root.label.dropFirst("Gemini — ".count))
        let composers = nodes.filter(Self.isComposer)
        let models = nodes.filter { $0.role == "AXButton" && $0.label.hasSuffix(", Choose model") }
        guard composers.count == 1, let draft = composers.first?.value, models.count == 1 else {
            throw DesktopAppError.unavailable("Gemini’s message field or model control is unavailable. Your draft was preserved.")
        }
        self.draft = draft
        model = models[0].label
        let modes = nodes.filter { ["chat-input-mode-ask", "chat-input-mode-assign"].contains($0.id) && $0.selected }
        guard modes.count <= 1 else { throw DesktopAppError.unavailable("Gemini’s mode is ambiguous.") }
        mode = modes.first.map { $0.id == "chat-input-mode-ask" ? .chat : .task }
        generating = nodes.contains { $0.id == "stop_button" }
        // Only transcript rows inside the main pane, never sidebar titles or
        // reasoning headings. A completed answer owns its Copy response control.
        let panes = nodes.filter { $0.role == "AXSplitGroup" }.flatMap(\.children).filter { pane in
            pane.descendants.contains { $0.role == "AXTextArea" && $0.label == composers[0].label }
        }
        guard panes.count == 1 else { throw DesktopAppError.unavailable("Gemini’s transcript boundary is unavailable.") }
        let rows = panes[0].descendants.filter { $0.role == "AXRow" }
        var messages: [GeminiMessage] = []
        for row in rows {
            let groups = row.children.flatMap(\.children).filter { $0.role == "AXGroup" }
            guard groups.count <= 1 else { throw DesktopAppError.unavailable("Gemini’s response layout changed.") }
            guard let group = groups.first else { continue }
            if group.descendants.contains(where: { $0.id == "copy-button" }) {
                // Native answer text has an accessible description and value.
                // Usage notices and Task status headings are separate siblings.
                let text = group.children.filter { $0.role == "AXStaticText" && !$0.label.isEmpty && $0.value != nil }.compactMap(\.value).joined(separator: "\n\n")
                guard !text.isEmpty else { throw DesktopAppError.unavailable("Gemini’s completed answer text is unreadable.") }
                messages.append(.init(role: .assistant, text: text))
            } else if let heading = group.children.first,
                      group.children.count == 1, heading.role == "AXHeading", !heading.label.isEmpty,
                      !["Thinking it through", "Completed"].contains(heading.label) {
                messages.append(.init(role: .user, text: heading.label))
            }
        }
        self.messages = messages
    }

    static func isComposer(_ node: GeminiAXNode) -> Bool {
        node.role == "AXTextArea" && ["Ask Gemini", "Assign a task", "What’s next?"].contains(node.label)
    }
    func composer() throws -> GeminiAXNode { try unique(nodes.filter(Self.isComposer)) }
    func control(id: String) throws -> GeminiAXNode { try unique(nodes.filter { $0.id == id && $0.enabled }) }
    func control(label: String, role: String = "AXButton") throws -> GeminiAXNode {
        try unique(nodes.filter { $0.label == label && $0.role == role && $0.enabled })
    }
    private func unique(_ nodes: [GeminiAXNode]) throws -> GeminiAXNode {
        guard nodes.count == 1 else { throw DesktopAppError.unavailable("Gemini’s requested control is unavailable or ambiguous.") }
        return nodes[0]
    }
    func sameContent(as other: Self) -> Bool { title == other.title && draft == other.draft && mode == other.mode && messages == other.messages }
    func sameConversation(as other: Self) -> Bool { sameContent(as: other) && model == other.model }
}

enum GeminiNativeReader {
    static func capture(_ target: DesktopAppConversation.Target, allowingRename: Bool = false) throws -> GeminiAppObservation {
        guard AXIsProcessTrusted() else { throw DesktopAppError.unavailable("Allow msgblast Accessibility access to connect Gemini.") }
        func attr(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(e, key as CFString, &value) == .success ? value : nil
        }
        func string(_ e: AXUIElement, _ key: String) -> String { attr(e, key) as? String ?? "" }
        guard let window = DesktopNativeWindowLookup.resolve(target) else { throw GeminiObservationError.transient("Gemini’s exact window is unavailable for background control. Dismiss dialogs and check again.") }
        var count = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        func walk(_ e: AXUIElement, depth: Int, parentRole: String = "") throws -> GeminiAXNode {
            count += 1
            guard count <= 6000, depth <= 60, ContinuousClock.now < deadline else { throw GeminiObservationError.transient("Gemini’s accessibility tree is incomplete.") }
            let role = string(e, "AXRole")
            // Gemini retains inaccessible references for virtualized sidebar rows.
            // They cannot supply a navigation target; missing transcript/control roles still fail.
            if role.isEmpty, parentRole == "AXOutline" { return .init(role: "AXUnknown") }
            guard !role.isEmpty else { throw GeminiObservationError.transient("Gemini changed while reading its controls.") }
            let title = string(e, "AXTitle"), description = string(e, "AXDescription")
            var frame: DesktopAppSnapshot.Element.Frame?
            if let p = attr(e, "AXPosition"), let s = attr(e, "AXSize"), CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() {
                var point = CGPoint.zero, size = CGSize.zero
                if AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) {
                    frame = .init(x: point.x, y: point.y, w: size.width, h: size.height)
                }
            }
            let children = try (attr(e, "AXChildren") as? [AXUIElement] ?? []).map { try walk($0, depth: depth + 1, parentRole: role) }
            return .init(role: role, label: title.isEmpty ? description : title, value: attr(e, "AXValue") as? String,
                         id: string(e, "AXIdentifier"), selected: attr(e, "AXSelected") as? Bool == true,
                         enabled: attr(e, "AXEnabled") as? Bool != false, selectedText: attr(e, "AXSelectedText") as? String, frame: frame, children: children)
        }
        return try GeminiAppObservation(root: walk(window, depth: 0), allowingRename: allowingRename)
    }
}
