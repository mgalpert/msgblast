import Foundation

enum ClaudeDuetURL {
    static func isDuet(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host == "claude.ai", url.port == nil, url.user == nil,
              url.password == nil, url.query == nil, url.fragment == nil,
              url.absoluteString == "https://claude.ai" + url.path else { return false }
        return url.path == "/messages"
    }
}

struct ClaudeDuetMessage: Equatable, Sendable {
    enum Author: String, Equatable, Sendable { case user, agent }
    var author: Author
    var text: String
}

enum ClaudeDuetOpen {
    enum Decision { case alreadyOpen, press(ClaudeAXNode) }
    static let buttonLabel = "Claude Duet, Preview"
    static func decide(_ root: ClaudeAXNode) throws -> Decision {
        let nodes = root.descendants
        if nodes.contains(where: { $0.role == "AXWebArea" && $0.url.map(ClaudeDuetURL.isDuet) == true }) { return .alreadyOpen }
        let buttons = nodes.filter { $0.role == "AXButton" && $0.label == buttonLabel }
        guard !buttons.isEmpty else { throw ClaudeObservationError.transient("Claude Duet is still opening.") }
        guard buttons.count == 1 else { throw DesktopAppError.unavailable("Claude Duet's navigation is ambiguous. Nothing was clicked.") }
        return .press(buttons[0])
    }
}

struct ClaudeDuetObservation: Equatable, Sendable {
    let url: URL
    let draft: String
    let messages: [ClaudeDuetMessage]

    static func agentReplies(after prompt: String, in messages: [ClaudeDuetMessage]) -> [String] {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, let index = messages.lastIndex(where: {
            $0.author == .user && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == prompt
        }) else { return [] }
        var replies: [String] = []
        for message in messages.dropFirst(index + 1) {
            if message.author == .user { break }
            replies.append(message.text)
        }
        return replies
    }

    init(root: ClaudeAXNode) throws {
        let nodes = root.descendants
        guard !nodes.contains(where: { ["AXSheet", "AXDialog"].contains($0.role) || $0.subrole == "AXDialog" }) else {
            throw DesktopAppError.unavailable("Dismiss Claude's dialog before continuing.")
        }
        let areas = nodes.filter { $0.role == "AXWebArea" && $0.url.map(ClaudeDuetURL.isDuet) == true }
        guard !areas.isEmpty else { throw ClaudeObservationError.transient("Claude Duet is still opening.") }
        guard areas.count == 1, let url = areas[0].url else { throw DesktopAppError.unavailable("Claude Duet's address is unavailable or ambiguous.") }
        let fields = areas[0].descendants.filter { $0.role == "AXTextArea" && $0.label == "Message Claude Duet" }
        guard fields.count == 1, let value = fields[0].value, let composer = fields[0].frame else {
            throw ClaudeObservationError.transient("Claude Duet's message field is still loading.")
        }
        self.url = url
        draft = value.isEmpty || value == fields[0].label ? "" : value
        messages = Self.messages(in: areas[0], composer: composer)
    }

    private static func messages(in area: ClaudeAXNode, composer: DesktopAppSnapshot.Element.Frame) -> [ClaudeDuetMessage] {
        var result: [ClaudeDuetMessage] = []
        var author: ClaudeDuetMessage.Author?
        var parts: [String] = []
        func flush() {
            if let author, !parts.isEmpty { result.append(.init(author: author, text: parts.joined(separator: "\n"))) }
            author = nil
            parts = []
        }
        for child in area.children {
            if let piece = piece(child, composer: composer) {
                if author == piece.author { parts.append(piece.text) }
                else { flush(); author = piece.author; parts = [piece.text] }
            } else { flush() }
        }
        flush()
        return result
    }

    private static func piece(_ node: ClaudeAXNode, composer: DesktopAppSnapshot.Element.Frame) -> (author: ClaudeDuetMessage.Author, text: String)? {
        let text = content(node)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let frame = node.descendants.compactMap(\.frame).first else { return nil }
        if abs(frame.x - composer.x) <= 40 { return (.agent, text) }
        if frame.x > composer.x + 40, abs(frame.x + frame.w - (composer.x + composer.w)) <= 60 { return (.user, text) }
        return nil
    }

    private static let footer = "Claude Duet is AI and can make mistakes."
    private static func isTimestamp(_ text: String) -> Bool {
        text.range(of: #"^(Today|Yesterday|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday) [0-9]{1,2}:[0-9]{2} (AM|PM)$"#, options: .regularExpression) != nil
    }
    private static func content(_ node: ClaudeAXNode) -> String {
        switch node.role {
        case "AXToolbar", "AXButton", "AXPopUpButton", "AXCheckBox", "AXTextArea", "AXHeading", "AXMenu", "AXMenuBar", "AXImage", "AXWebArea":
            return ""
        case "AXStaticText":
            guard let value = node.value, !isTimestamp(value) else { return "" }
            return value
        case "AXLink":
            if node.label == footer { return "" }
            let inner = node.children.map(content).filter { !$0.isEmpty }
            return inner.isEmpty ? node.label : inner.joined(separator: "\n")
        case "AXListMarker":
            return node.value ?? ""
        default:
            return node.children.map(content).filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }
}

enum ClaudeDuetProfile {
    static func capture(_ target: DesktopAppConversation.Target) throws -> ClaudeAXNode {
        do { return convert(try DesktopAccessibility.capture(target, app: .claudeDuet)) }
        catch DesktopAccessibilityError.incomplete { throw ClaudeObservationError.transient("Claude Duet's controls are still updating.") }
    }
    static func convert(_ node: DesktopAccessibilityNode) -> ClaudeAXNode {
        .init(role: node.role, subrole: node.subrole, label: node.label, value: node.value, classes: node.classes,
              url: node.url, frame: node.frame, focused: node.focused, children: node.children.map(convert))
    }
}

actor ClaudeDuetAppConversation {
    static let shared = ClaudeDuetAppConversation()
    typealias NativeRead = @Sendable (DesktopAppConversation.Target) throws -> ClaudeAXNode
    private let driver: DesktopAppConversation
    private let timing: DesktopAppConversation.Timing
    private let readNative: NativeRead
    private var occupied = false

    init(executable: URL? = nil, timing: DesktopAppConversation.Timing = .init(), readNative: @escaping NativeRead = ClaudeDuetProfile.capture) {
        driver = DesktopAppConversation(executable: executable, timing: timing)
        self.timing = timing
        self.readNative = readNative
    }

    func checkAvailable() async throws { _ = try await open() }
    func prepare() async throws { _ = try await open() }

    private func open() async throws -> ClaudeDuetObservation {
        guard !occupied else { throw DesktopAppError.unavailable("Claude Duet is already handling a request.") }
        occupied = true
        defer { occupied = false }
        let session = "msgblast-claude-duet-open-\(UUID())"
        defer { Task { await driver.endSession(session) } }
        let target = try await driver.target(.claudeDuet)
        let root = try await wait(target, failure: "Claude Duet is still opening.") { root in
            _ = try ClaudeDuetOpen.decide(root)
            return true
        }
        if case .press(let button) = try ClaudeDuetOpen.decide(root) {
            try await press(button, target: target, session: session)
            return try await observed(target)
        }
        return try await parsed(root, target: target)
    }

    private func native(_ target: DesktopAppConversation.Target) async throws -> ClaudeAXNode {
        try Task.checkCancellation()
        let read = readNative
        return try await Task.detached { try read(target) }.value
    }

    private func parsed(_ root: ClaudeAXNode, target: DesktopAppConversation.Target) async throws -> ClaudeDuetObservation {
        do { return try ClaudeDuetObservation(root: root) }
        catch is ClaudeObservationError { return try await observed(target) }
    }

    private func observed(_ target: DesktopAppConversation.Target) async throws -> ClaudeDuetObservation {
        try await DesktopAppWorkflow.wait(timeout: .seconds(5), interval: timing.pollInterval,
            failure: "Claude Duet's message field is still loading.",
            read: { try ClaudeDuetObservation(root: try await self.native(target)) }, ready: { _ in true })
    }

    private func wait(_ target: DesktopAppConversation.Target, failure: String, ready: @escaping (ClaudeAXNode) throws -> Bool) async throws -> ClaudeAXNode {
        try await DesktopAppWorkflow.wait(timeout: .seconds(5), interval: timing.pollInterval, failure: failure,
            read: { try await self.native(target) }, ready: ready)
    }

    private func press(_ button: ClaudeAXNode, target: DesktopAppConversation.Target, session: String) async throws {
        let state = try await driver.snapshot(target, session: session)
        try state.checkReadable()
        switch try ClaudeDuetOpen.decide(try await native(target)) {
        case .alreadyOpen: return
        case .press(let again):
            guard again.label == button.label, again.frame == button.frame else {
                throw DesktopAppError.unavailable("Claude Duet's navigation changed. Nothing was clicked.")
            }
            let matches = state.body.filter {
                $0.role == "AXButton" && $0.label == ClaudeDuetOpen.buttonLabel && $0.enabled != false && $0.element_token != nil &&
                (again.frame == nil || $0.frame == again.frame)
            }
            guard matches.count == 1, let token = matches[0].element_token else {
                throw DesktopAppError.unavailable("Claude Duet's navigation could not be verified. Nothing was clicked.")
            }
            _ = try await driver.call("click", ["element_token": token, "session": session, "delivery_mode": "background"],
                                      numbers: ["pid": target.pid, "window_id": target.window], as: DesktopAppConversation.Action.self)
        }
    }
}
