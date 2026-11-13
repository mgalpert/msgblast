import ApplicationServices
import Foundation
import CryptoKit

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
struct ChatGPTMessage: Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }
    var role: Role
    var text: String
}

// Saved before submission so a later read can match the same outgoing message
// without typing or submitting anything again.
struct DotsReplyReceipt: Codable, Equatable, Sendable {
    var version: Int = 1
    let comparisonID: UUID
    let title: String
    let prompt: String
    let baselineCount: Int
    let baselineDigest: Data
    let initialUnreadCount: Int?
    var refreshedUnreadCount: Int?
    var automaticRecovery = true

    init(comparisonID: UUID, title: String, prompt: String, baseline: [ChatGPTMessage], initialUnreadCount: Int?) throws {
        self.comparisonID = comparisonID; self.title = title; self.prompt = prompt
        baselineCount = baseline.count; baselineDigest = try Self.digest(baseline)
        self.initialUnreadCount = initialUnreadCount
    }

    static func digest(_ messages: [ChatGPTMessage]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: try encoder.encode(messages)))
    }

    func appendedMessages(in messages: [ChatGPTMessage]) throws -> [ChatGPTMessage] {
        try Self.appendedMessages(in: messages, count: baselineCount, digest: baselineDigest)
    }

    static func appendedMessages(in messages: [ChatGPTMessage], count baselineCount: Int, digest baselineDigest: Data) throws -> [ChatGPTMessage] {
        guard baselineCount >= 0, baselineDigest.count == 32, messages.count >= baselineCount else {
            throw DesktopAppError.unavailable("The saved Dot history cannot be verified.")
        }
        let maximumOffset = baselineCount > 0 ? messages.count - baselineCount : 0
        let firstOffset = max(0, messages.count - baselineCount - 2)
        guard firstOffset <= maximumOffset else { throw DesktopAppError.unavailable("The Dot history changed. No reply was attributed.") }
        var matching: [Int] = []
        for offset in firstOffset...maximumOffset {
            let end = offset + baselineCount
            if try Self.digest(Array(messages[offset..<end])) == baselineDigest { matching.append(offset) }
        }
        guard matching.count == 1, let offset = matching.first else {
            throw DesktopAppError.unavailable("The Dot history changed. No reply was attributed.")
        }
        return Array(messages.dropFirst(offset + baselineCount))
    }
}

struct ChatGPTReplyReceipt: Codable, Equatable, Sendable {
    var version = 1
    let comparisonID: UUID
    // A first chat has no stable title yet; its UUID-bearing first prompt is
    // the ownership proof until a title can be saved.
    let initialTitle: String?
    let firstPrompt: String
    let prompt: String
    let baselineCount: Int
    let baselineDigest: Data
    var automaticRecovery = true

    init(comparisonID: UUID, initialTitle: String?, firstPrompt: String, prompt: String, baseline: [ChatGPTMessage]) throws {
        self.comparisonID = comparisonID; self.initialTitle = initialTitle
        self.firstPrompt = firstPrompt; self.prompt = prompt
        baselineCount = baseline.count; baselineDigest = try DotsReplyReceipt.digest(baseline)
    }
    func appendedMessages(in messages: [ChatGPTMessage]) throws -> [ChatGPTMessage] {
        try DotsReplyReceipt.appendedMessages(in: messages, count: baselineCount, digest: baselineDigest)
    }
}
enum ChatGPTObservationError: LocalizedError, Sendable {
    case transient, composerUnavailable, webContentUnavailable
    var errorDescription: String? {
        switch self {
        case .transient: "ChatGPT’s native window is temporarily unavailable."
        case .composerUnavailable: "ChatGPT’s message field is unavailable. Your draft was preserved."
        case .webContentUnavailable: "This ChatGPT application version is not supported yet."
        }
    }
}
struct ChatGPTAppNavigation: Sendable {
    private let nodes: [ChatGPTAXNode]
    init(validatedNodes: [ChatGPTAXNode]) { nodes = validatedNodes }
    init(root: ChatGPTAXNode) throws {
        guard root.role == "AXWindow" else { throw DesktopAppError.unavailable("Open ChatGPT’s main window.") }
        let pages = root.descendants.filter { $0.role == "AXWebArea" && $0.url == "app://-/index.html" }
        guard pages.count == 1 else { throw DesktopAppError.unavailable("This ChatGPT application version is not supported yet.") }
        func safe(_ node: ChatGPTAXNode) -> [ChatGPTAXNode] {
            [node] + node.children.filter { $0.role != "AXWebArea" }.flatMap(safe)
        }
        nodes = safe(pages[0])
        guard !nodes.contains(where: { ["AXDialog", "AXSheet"].contains($0.role) }) else {
            throw DesktopAppError.unavailable("Dismiss ChatGPT’s dialog before continuing.")
        }
    }
    func dotButton() throws -> ChatGPTAXNode {
        let headers = nodes.filter { $0.children.contains { $0.role == "AXButton" && $0.label == "New chat" && $0.classes.contains("sidebar-item") } }
        guard headers.count == 1 else { throw DesktopAppError.unavailable("ChatGPT’s Dot navigation is unavailable.") }
        let listed = headers[0].children.filter { $0.role == "AXList" }.flatMap(\.children).flatMap(\.children)
        let buttons = (headers[0].children + listed).filter { $0.role == "AXButton" && $0.classes.contains("sidebar-item") && $0.label != "New chat" && $0.visible && $0.enabled }
        guard buttons.count == 1 else { throw DesktopAppError.unavailable("ChatGPT’s Dot navigation is unavailable or ambiguous.") }
        return buttons[0]
    }
}
struct ChatGPTAppObservation: Sendable {
    let nodes: [ChatGPTAXNode]
    let title: String
    let kind: ChatGPTAppKind
    let draft: String
    let generating: Bool
    let messages: [ChatGPTMessage]
    let composer: ChatGPTAXNode?
    let codexBootstrap: Bool
    var unreadDotReplyCount: Int? {
        guard kind == .dots, let button = try? ChatGPTAppNavigation(validatedNodes: nodes).dotButton(),
              button.label.hasPrefix(title + " ") else { return nil }
        let badge = String(button.label.dropFirst(title.count + 1))
        guard badge.range(of: #"^[1-9][0-9]* unread messages?$"#, options: .regularExpression) != nil else { return nil }
        return Int(badge.prefix(while: { $0.isNumber }))
    }
    var dotSetup: Bool { composer == nil }
    var isNew: Bool { composer != nil && kind == .chatgpt && !codexBootstrap && messages.isEmpty }
    func requiredComposer() throws -> ChatGPTAXNode {
        guard let composer else { throw DesktopAppError.unavailable("Create your Dot in ChatGPT, then connect Dots.") }
        return composer
    }
    init(root: ChatGPTAXNode) throws {
        guard root.role == "AXWindow" else { throw DesktopAppError.unavailable("Open ChatGPT’s main window.") }
        let windowTitle = root.label
        let all = root.descendants
        guard let web = all.first(where: { $0.role == "AXWebArea" && $0.url == "app://-/index.html" }) else { throw ChatGPTObservationError.webContentUnavailable }
        let conversationTitle = web.label.isEmpty ? windowTitle : web.label
        title = conversationTitle
        nodes = Self.safeNodes(web)
        guard !nodes.contains(where: { ["AXDialog", "AXSheet"].contains($0.role) }) else { throw DesktopAppError.unavailable("Dismiss ChatGPT’s dialog before continuing.") }
        try DesktopInterstitial.check(.dots, controls: nodes.map { ($0.role, $0.label) })
        if let codex = try Self.codexWork(nodes) {
            composer = codex.composer; kind = .chatgpt; codexBootstrap = true
            draft = codex.draft
            generating = false; messages = []; return
        }
        codexBootstrap = false
        if try Self.dotSetupOrTransient(nodes) {
            composer = nil; kind = .dots; draft = ""; generating = false; messages = []; return
        }
        let panel = Self.safeNodes(try Self.conversationPanel(web))
        let composer = try Self.readComposer(panel)
        self.composer = composer.node
        kind = composer.kind
        draft = composer.draft
        generating = composer.generating
        if kind == .dots { messages = try Self.dotMessages(nodes, panel: panel, title: conversationTitle) }
        else { messages = try Self.chatMessages(panel) }
    }
    // Nested web areas belong to browser tabs and embedded apps, never ChatGPT.
    private static func safeNodes(_ node: ChatGPTAXNode) -> [ChatGPTAXNode] {
        [node] + node.children.filter { $0.role != "AXWebArea" }.flatMap(safeNodes)
    }
    private static func codexWork(_ nodes: [ChatGPTAXNode]) throws -> (composer: ChatGPTAXNode, draft: String)? {
        let codexFields = nodes.filter { $0.role == "AXTextArea" && ["Work with ChatGPT", "Work with Codex"].contains($0.label) }
        if nodes.filter({ $0.role == "AXPopUpButton" && ["Switch mode, current mode: Codex", "Switch mode, current mode: ChatGPT"].contains($0.label) }).count == 1, !codexFields.isEmpty {
            let drafts = try codexFields.map(workDraft)
            // Split Codex workspaces have several editors. Switching to ChatGPT
            // is safe only when every one is empty; never choose a task to edit.
            guard codexFields.count == 1 || drafts.allSatisfy(\.isEmpty) else {
                throw DesktopAppError.unavailable("ChatGPT has an unsent work draft. It was preserved.")
            }
            return (codexFields[0], drafts[0])
        }
        return nil
    }
    private static func workDraft(_ field: ChatGPTAXNode) throws -> String {
        guard let value = field.value else { throw DesktopAppError.unavailable("ChatGPT’s work draft is unavailable. Nothing was changed.") }
        return field.descendants.contains(where: { $0.classes.contains("placeholder") }) && [field.label, field.label + "\n", "\n"].contains(value) ? "" : value
    }
    private static func dotSetupOrTransient(_ nodes: [ChatGPTAXNode]) throws -> Bool {
        let initialDotSetup = nodes.filter { $0.role == "AXHeading" && $0.label == "Create your dot" }.count == 1
        let dotComputerSetup = nodes.filter { $0.role == "AXHeading" && $0.label == "Choose where your dot can work" }.count == 1
            && nodes.filter { $0.role == "AXCheckBox" && $0.label == "Your local computer" }.count == 1
            && nodes.filter { $0.role == "AXButton" && $0.label == "Continue" }.count == 1
        if initialDotSetup || dotComputerSetup,
           nodes.filter({ $0.role == "AXButton" && $0.label == "New chat" && $0.classes.contains("sidebar-item") }).count == 1,
           !nodes.contains(where: { ["AXTextArea", "AXTextField"].contains($0.role) }) {
            return true
        }
        if nodes.filter({ $0.role == "AXButton" && $0.label == "New chat" && $0.classes.contains("sidebar-item") }).count == 1,
           nodes.filter({ $0.role == "AXButton" && $0.label == "Your dot" && $0.classes.contains("sidebar-item") }).count == 1,
           !nodes.contains(where: { ["AXTextArea", "AXTextField", "AXHeading"].contains($0.role) }) {
            throw ChatGPTObservationError.transient
        }
        return false
    }
    // ChatGPT 26.1103 dropped the -chat-panel id and marks the conversation with MainContentSurface. A nested match is the same panel.
    private static func conversationPanel(_ root: ChatGPTAXNode) throws -> ChatGPTAXNode {
        let panels = panelMatches(root)
        guard panels.count == 1 else { throw DesktopAppError.unavailable("ChatGPT’s native conversation panel is unavailable.") }
        return panels[0]
    }
    private static func panelMatches(_ node: ChatGPTAXNode) -> [ChatGPTAXNode] {
        let panel = node.id.hasSuffix("-chat-panel") || (node.subrole == "AXLandmarkMain" && node.classes.contains { $0.hasPrefix("MainContentSurface-") })
        if panel { return [node] }
        return node.children.filter { $0.role != "AXWebArea" }.flatMap(panelMatches)
    }
    private static func readComposer(_ panel: [ChatGPTAXNode]) throws -> (node: ChatGPTAXNode, kind: ChatGPTAppKind, draft: String, generating: Bool) {
        let fields = panel.filter { $0.role == "AXTextArea" && ["Ask ChatGPT", "Message"].contains($0.label) }
        guard !fields.isEmpty else { throw ChatGPTObservationError.composerUnavailable }
        guard fields.count == 1 else { throw DesktopAppError.unavailable("ChatGPT’s message field is ambiguous. Your draft was preserved.") }
        guard let value = fields[0].value else { throw ChatGPTObservationError.composerUnavailable }
        let composer = fields[0]
        let kind: ChatGPTAppKind = composer.label == "Message" ? .dots : .chatgpt
        let placeholder = kind == .dots ? "Send a message" : "Ask ChatGPT"
        let hasPlaceholder = composer.descendants.contains { $0.classes.contains("placeholder") }
        let draft = hasPlaceholder && [placeholder, placeholder + "\n"].contains(value) ? "" : try paragraphDraft(composer, raw: value)
        let generating = panel.contains { $0.role == "AXButton" && ["Stop", "Stop generating", "Stop response"].contains($0.label) }
        return (composer, kind, draft, generating)
    }
    private static func dotMessages(_ nodes: [ChatGPTAXNode], panel: [ChatGPTAXNode], title: String) throws -> [ChatGPTMessage] {
        guard nodes.filter({ $0.role == "AXPopUpButton" && $0.label == "Open \(title)’s profile" }).count == 1 else { throw DesktopAppError.unavailable("The active Dot’s identity could not be verified.") }
        let lists = panel.filter { $0.classes.contains("message-list") }
        guard lists.count == 1 else { throw DesktopAppError.unavailable("The Dot’s message list is unavailable.") }
        return lists[0].children.filter { $0.classes.contains("message-row") }.flatMap { row in
            messageBubbles(row).compactMap { body -> ChatGPTMessage? in
                let text = bodyText(body)
                return text.isEmpty ? nil : .init(role: row.classes.contains("self") ? .user : .assistant, text: text)
            }
        }
    }
    private static func messageBubbles(_ node: ChatGPTAXNode) -> [ChatGPTAXNode] {
        if node.classes.contains("message-bubble") { return [node] }
        return node.children.flatMap(messageBubbles)
    }
    private static func chatMessages(_ panel: [ChatGPTAXNode]) throws -> [ChatGPTMessage] {
        let transcripts = panel.filter { $0.classes.contains(where: { $0.hasPrefix("_transcriptContent_") || $0.hasPrefix("transcriptContent-") }) }
        guard transcripts.count <= 1 else { throw DesktopAppError.unavailable("ChatGPT’s transcript is ambiguous.") }
        var result: [ChatGPTMessage] = []
        for turn in transcripts.first?.children ?? [] {
            var role: ChatGPTMessage.Role?, parts: [String] = []
            func flush() { if let role, !parts.isEmpty { result.append(.init(role: role, text: parts.joined(separator: "\n\n"))) }; parts = [] }
            for child in turn.children {
                if child.role == "AXHeading", ["You said:", "ChatGPT said:"].contains(child.label) {
                    flush(); role = child.label == "You said:" ? .user : .assistant
                } else if role != nil {
                    let text = bodyText(child)
                    if !text.isEmpty { parts.append(text) }
                }
            }
            flush()
        }
        return result
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
    func sameContent(as other: Self) -> Bool { title == other.title && dotSetup == other.dotSetup && codexBootstrap == other.codexBootstrap && kind == other.kind && draft == other.draft && messages == other.messages }
}
enum ChatGPTAppProfile {
    private final class WebContentRequests: @unchecked Sendable {
        let lock = NSLock()
        var pids: Set<Int> = []
    }
    private static let webContentRequests = WebContentRequests()

    /// Chromium hides web content until an assistive client sets this. The call returns an error and still works.
    static func exposeWebContent(_ pid: Int) {
        webContentRequests.lock.withLock {
            guard webContentRequests.pids.insert(pid).inserted else { return }
            _ = AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid_t(pid)), "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }
    static func captureNavigation(_ target: DesktopAppConversation.Target) throws -> ChatGPTAppNavigation {
        exposeWebContent(target.pid)
        return try ChatGPTAppNavigation(root: convert(DesktopAccessibility.capture(target, app: .chatgpt, readComposer: false)))
    }
    static func capture(_ target: DesktopAppConversation.Target) throws -> ChatGPTAppObservation {
        exposeWebContent(target.pid)
        do { return try parse(DesktopAccessibility.capture(target, app: .chatgpt)) }
        catch DesktopAccessibilityError.incomplete { throw ChatGPTObservationError.transient }
    }
    static func parse(_ root: DesktopAccessibilityNode) throws -> ChatGPTAppObservation {
        return try ChatGPTAppObservation(root: convert(root))
    }
    private static func convert(_ node: DesktopAccessibilityNode) -> ChatGPTAXNode {
        .init(role: node.role, label: node.label, value: node.value, id: node.domID, subrole: node.subrole,
              classes: node.classes, url: node.url?.absoluteString ?? "", selectedText: node.selectedText,
              enabled: node.enabled, focused: node.focused, frame: node.frame, children: node.children.map(convert))
    }
}
