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
    func savedChatControls(titled title: String) -> [GeminiAXNode] {
        let sidebars = nodes.filter { $0.role == "AXSplitGroup" }.flatMap(\.children)
            .filter { !$0.descendants.contains(where: Self.isComposer) }
        func matches(_ node: GeminiAXNode) -> [GeminiAXNode] {
            // Newer Gemini releases expose sidebar chats as rows. Count a
            // matching row once even when it wraps a same-labelled button.
            if ["AXRow", "AXButton"].contains(node.role), node.label == title { return node.enabled ? [node] : [] }
            return node.children.flatMap(matches)
        }
        return sidebars.flatMap(matches)
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

enum GeminiAppProfile {
    static func capture(_ target: DesktopAppConversation.Target, allowingRename: Bool = false) throws -> GeminiAppObservation {
        do { return try parse(DesktopAccessibility.capture(target, app: .gemini), allowingRename: allowingRename) }
        catch DesktopAccessibilityError.incomplete { throw GeminiObservationError.transient("Gemini's controls are still updating.") }
    }
    static func parse(_ root: DesktopAccessibilityNode, allowingRename: Bool = false) throws -> GeminiAppObservation {
        func convert(_ node: DesktopAccessibilityNode) -> GeminiAXNode {
            .init(role: node.role, label: node.label, value: node.value, id: node.id, selected: node.selected,
                  enabled: node.enabled, selectedText: node.selectedText, frame: node.frame, children: node.children.map(convert))
        }
        return try GeminiAppObservation(root: convert(root), allowingRename: allowingRename)
    }
}
