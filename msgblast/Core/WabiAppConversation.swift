import Foundation

enum WabiThread {
    static func isValid(_ url: URL) -> Bool {
        guard url.scheme == "wabi", url.host == "app", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath.range(of: #"^/threads/[0-9a-f]{24}$"#, options: .regularExpression) != nil
    }
    static func verifiedURL(_ url: URL?, currentURL: URL?, webAreaCount: Int, composerCount: Int, purpose: WabiReadPurpose) throws -> URL {
        guard webAreaCount <= 1, composerCount <= 1 else {
            throw DesktopAppError.unavailable("Wabi's chat address could not be verified.")
        }
        if purpose == .readiness, webAreaCount == 0 || url == nil || url?.absoluteString == "about:blank" || url?.absoluteString == "wabi://app/" || url?.absoluteString == "wabi://app" {
            throw WabiObservationError.transient("Wabi is still opening its chat. Wait for it to finish loading.")
        }
        guard webAreaCount == 1, let url, isValid(url), currentURL == url else {
            throw DesktopAppError.unavailable("Wabi's chat address could not be verified.")
        }
        return url
    }

}

struct WabiAppMessage: Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }
    let role: Role
    let text: String
}

struct WabiAXNode: Sendable {
    let role: String
    var label = ""
    var value = ""
    var classes: [String] = []
    var children: [WabiAXNode] = []
    var descendants: [WabiAXNode] { [self] + children.flatMap(\.descendants) }
}

enum WabiObservationError: LocalizedError, Sendable {
    case transient(String)
    var errorDescription: String? { switch self { case .transient(let message): message } }
}

enum WabiReadPurpose: Sendable { case readiness, conversation }

enum WabiNativeMessages {
    static func read(_ root: WabiAXNode, purpose: WabiReadPurpose = .conversation) throws -> [WabiAppMessage] {
        guard purpose == .conversation else { return [] }
        let nodes = root.descendants
        // Wabi 0.1.11 and 0.1.15 expose sender-specific message frames through native
        // AXDOMClassList. Refuse unknown frames rather than infer a speaker
        // from text, position, color, or a delivery receipt.
        let frameClasses: Set<String> = ["x1n2onr6", "x193iq5w", "x67m8t7", "xc90arz", "xza2g2e"]
        let frames = nodes.filter { $0.role == "AXGroup" && frameClasses.isSubset(of: Set($0.classes)) }
        guard !frames.isEmpty, frames.count == nodes.filter({ $0.role == "AXPopUpButton" && $0.label == "Add reaction" }).count else {
            throw WabiObservationError.transient("Wabi's messages are still updating. No sender or reply was inferred.")
        }
        return try frames.map { frame in
            let own = frame.classes.contains("xpvyfi4"), other = frame.classes.contains("xqcrz7y")
            var text = frame.descendants.filter { $0.role == "AXStaticText" }.map(\.value)
            guard own != other else { throw DesktopAppError.unavailable("Wabi's message sender is unavailable. No reply was attributed.") }
            guard text.count >= 2, let timestamp = text.last,
                  timestamp.range(of: #"^\d{1,2}:\d{2}\s*[AP]M$"#, options: .regularExpression) != nil else {
                throw WabiObservationError.transient("Wabi's message boundary is still updating. No reply was attributed.")
            }
            text.removeLast()
            let body = text.joined(separator: "\n\n")
            guard !body.isEmpty else { throw WabiObservationError.transient("Wabi's message body is still updating. No reply was attributed.") }
            return WabiAppMessage(role: own ? .user : .assistant, text: body)
        }
    }
}

struct WabiAppObservation: Codable, Sendable {
    struct Link: Codable, Equatable, Sendable { let label: String; let url: URL }
    let url: URL
    let draft: String?
    let links: [Link]
    let messages: [WabiAppMessage]
    var composerFocused: Bool? = nil
}

struct WabiAppReceipt {
    let baseline: [WabiAppMessage]
    let prompt: String

    func unchanged(_ messages: [WabiAppMessage]) -> Bool { messages == baseline || messages == Array(baseline.reversed()) }

    func reply(in messages: [WabiAppMessage]) throws -> String? {
        if unchanged(messages) { return nil }
        guard messages.count > baseline.count, messages.count <= baseline.count + 2 else {
            throw DesktopAppError.unavailable("Wabi's message history changed or another message arrived. Review the saved chat; no reply was attributed.")
        }
        // Wabi can reverse its accessible message order when reopening a chat.
        // Keep history and sender exact. Wabi flattens outgoing line breaks in
        // its rendered history; the pre-send native draft was checked exactly.
        var candidates: Set<String> = []
        var waiting = false
        for ordered in [messages, Array(messages.reversed())] {
            for old in [baseline, Array(baseline.reversed())] where ordered.starts(with: old) {
                let added = ordered.dropFirst(old.count)
                guard let outgoing = added.first, outgoing.role == .user,
                      outgoing.text.split(whereSeparator: \.isWhitespace) == prompt.split(whereSeparator: \.isWhitespace) else { continue }
                if added.count == 1 { waiting = true }
                else if let answer = added.last, answer.role == .assistant { candidates.insert(answer.text) }
            }
        }
        guard candidates.count <= 1 else { throw DesktopAppError.unavailable("Wabi's new reply is ambiguous. Review the saved chat.") }
        if let answer = candidates.first { return answer }
        if waiting { return nil }
        throw DesktopAppError.unavailable("Wabi's new message did not match this request. No reply was attributed.")
    }
}

enum WabiAppProfile {
    static func isNewChatChooser(_ state: DesktopAppSnapshot) -> Bool {
        let fields = state.body.filter { $0.role == "AXTextField" && $0.label == "Name, username, or phone number" }
        return fields.count == 1 && ["", "Name, username, or phone number"].contains(fields[0].value ?? "") &&
            state.body.first(where: { $0.role == "AXHeading" })?.label == "New chat"
    }
    static func newAIChatChoice(_ state: DesktopAppSnapshot) throws -> DesktopAppSnapshot.Element {
        guard isNewChatChooser(state) else { throw DesktopAppError.unavailable("Wabi's New chat chooser changed. Nothing was selected.") }
        let lists = Set(state.body.filter { $0.role == "AXList" }.compactMap(\.element_index))
        let choices = state.body.filter { $0.role == "AXButton" && $0.label == "New chat" && $0.enabled != false && $0.element_token != nil && $0.parent_index.map(lists.contains) == true }
        guard choices.count == 1 else { throw DesktopAppError.unavailable("Wabi's AI chat choice is unavailable or ambiguous. Nothing was selected.") }
        return choices[0]
    }
    static func capture(_ target: DesktopAppConversation.Target, purpose: WabiReadPurpose = .conversation) throws -> WabiAppObservation {
        do { return try parse(DesktopAccessibility.capture(target, app: .wabi), purpose: purpose) }
        catch DesktopAccessibilityError.incomplete { throw WabiObservationError.transient("Wabi's controls are still updating.") }
    }
    static func parse(_ root: DesktopAccessibilityNode, purpose: WabiReadPurpose = .conversation) throws -> WabiAppObservation {
        let nodes = root.descendants
        guard !nodes.contains(where: { ["AXSheet", "AXDialog"].contains($0.role) }) else { throw DesktopAppError.unavailable("Dismiss Wabi's dialog before continuing.") }
        let areas = nodes.filter { $0.role == "AXWebArea" }
        let composers = nodes.filter { DesktopAccessibility.isComposer($0, app: .wabi) }
        let url = try WabiThread.verifiedURL(areas.first?.url, currentURL: areas.first?.url, webAreaCount: areas.count, composerCount: composers.count, purpose: purpose)
        if let composer = composers.first, composer.value == nil { throw DesktopAppError.unavailable("Wabi's draft is unreadable. It was preserved.") }
        func convert(_ node: DesktopAccessibilityNode) -> WabiAXNode {
            .init(role: node.role, label: node.label, value: node.value ?? "", classes: node.classes, children: node.children.map(convert))
        }
        let links = nodes.filter { $0.role == "AXLink" }.compactMap { node in node.url.map { WabiAppObservation.Link(label: node.label, url: $0) } }
        return .init(url: url, draft: composers.first?.value, links: links,
                     messages: try WabiNativeMessages.read(convert(root), purpose: purpose), composerFocused: composers.first?.focused ?? false)
    }
}

actor WabiAppConversation {
    static let shared = WabiAppConversation()
    typealias NativeRead = @Sendable (DesktopAppConversation.Target, WabiReadPurpose) throws -> WabiAppObservation
    private let driver: DesktopAppConversation
    private let timing: DesktopAppConversation.Timing
    private let readNative: NativeRead
    private var occupied = false
    init(executable: URL? = nil, timing: DesktopAppConversation.Timing = .init(), readNative: @escaping NativeRead = { try WabiAppProfile.capture($0, purpose: $1) }) {
        driver = DesktopAppConversation(executable: executable, timing: timing)
        self.timing = timing; self.readNative = readNative
    }
    private func native(_ target: DesktopAppConversation.Target, purpose: WabiReadPurpose = .conversation) async throws -> WabiAppObservation {
        let read = readNative
        var retries = 2
        let readinessDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while true {
            try Task.checkCancellation()
            do { return try await Task.detached { try read(target, purpose) }.value }
            catch WabiObservationError.transient where purpose == .readiness ? ContinuousClock.now < readinessDeadline : retries > 0 {
                retries -= 1
                try await Task.sleep(for: timing.pollInterval)
            }
        }
    }
    private func observe(_ target: DesktopAppConversation.Target, session: String, screenshotURL: URL? = nil, purpose: WabiReadPurpose = .conversation) async throws -> (DesktopAppSnapshot, WabiAppObservation) {
        try Task.checkCancellation()
        // A cold Electron window can expose no web content until Cua enables
        // its accessibility tree. Initialize it before waiting for the native URL.
        let readinessState = purpose == .readiness ? try await driver.snapshot(target, session: session, screenshotURL: screenshotURL) : nil
        try readinessState?.checkReadable()
        let before = try await native(target, purpose: purpose)
        let state: DesktopAppSnapshot
        if let readinessState { state = readinessState }
        else { state = try await driver.snapshot(target, session: session, screenshotURL: screenshotURL) }
        try state.checkReadable()
        let after = try await native(target, purpose: purpose)
        guard before.url == after.url, before.draft == after.draft,
              screenshotURL == nil || (before.messages == after.messages && before.composerFocused == after.composerFocused) else { throw DesktopAppError.unavailable("Wabi changed while checking its chat. Nothing was retried.") }
        return (state, after)
    }
    private func driverDraftAgrees(_ composer: (element: DesktopAppSnapshot.Element, draft: String), with exact: String) -> Bool {
        // Structured values can trim whitespace or echo the empty editor's
        // placeholder. The independent native draft must still match exactly.
        let value = composer.element.value ?? ""
        let trimmed = exact.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == exact || value == trimmed || (trimmed.isEmpty && composer.draft.isEmpty)
    }
    private func empty(_ state: DesktopAppSnapshot, _ native: WabiAppObservation) throws {
        guard native.draft == "", try state.composer(app: .wabi).draft.isEmpty, !state.isGenerating else {
            throw DesktopAppError.unavailable("Wabi has an unsent draft or an active response. It was preserved.")
        }
    }
    private func button(_ state: DesktopAppSnapshot, _ label: String) throws -> DesktopAppSnapshot.Element {
        let matches = state.body.filter { $0.role == "AXButton" && $0.label == label && $0.enabled != false && $0.element_token != nil }
        guard matches.count == 1 else { throw DesktopAppError.unavailable("Wabi's \(label) control is unavailable or ambiguous.") }
        return matches[0]
    }
    private func click(_ element: DesktopAppSnapshot.Element, _ target: DesktopAppConversation.Target, session: String) async throws {
        _ = try await driver.call("click", ["element_token": element.element_token!, "session": session, "delivery_mode": "background"], numbers: ["pid": target.pid, "window_id": target.window], as: DesktopAppConversation.Action.self)
    }
    private func settled(_ target: DesktopAppConversation.Target, session: String, purpose: WabiReadPurpose = .conversation, expected: (DesktopAppSnapshot, WabiAppObservation) throws -> Bool) async throws -> (DesktopAppSnapshot, WabiAppObservation) {
        try await DesktopAppWorkflow.wait(timeout: .seconds(8), interval: timing.pollInterval,
            failure: "Wabi did not open the expected chat. Nothing was sent or retried.",
            read: { try await self.observe(target, session: session, purpose: purpose) }, ready: { try expected($0.0, $0.1) })
    }

    func checkAvailable() async throws {
        guard !occupied else { throw DesktopAppError.unavailable("Wabi is already handling a request.") }
        occupied = true
        defer { occupied = false }
        let session = "msgblast-wabi-check-\(UUID())"
        defer { Task { await driver.endSession(session) } }
        let target = try await driver.target(.wabi)
        // Connecting proves readiness to create a dedicated chat, not the
        // readability of unrelated messages in the currently open chat.
        let (state, native) = try await observe(target, session: session, purpose: .readiness)
        try empty(state, native)
        _ = try button(state, "New chat")
    }
    func prepare(savedURL: URL?) async throws -> URL {
        guard !occupied else { throw DesktopAppError.unavailable("Wabi is already handling a request.") }
        occupied = true
        defer { occupied = false }
        let session = "msgblast-wabi-prepare-\(UUID())"
        defer { Task { await driver.endSession(session) } }
        let target = try await driver.target(.wabi)
        var (state, native) = try await observe(target, session: session, purpose: .readiness)
        try empty(state, native)
        if let savedURL {
            guard WabiThread.isValid(savedURL) else { throw DesktopAppError.unavailable("The saved Wabi chat address is invalid. No replacement was created.") }
            if native.url == savedURL { return savedURL }
            let links = native.links.filter { $0.url == savedURL }
            guard links.count == 1 else { throw DesktopAppError.unavailable("Open this comparison's saved chat in Wabi and try again. No replacement chat was created.") }
            let matches = state.body.filter { $0.role == "AXLink" && $0.label == links[0].label && $0.enabled != false && $0.element_token != nil }
            guard matches.count == 1 else { throw DesktopAppError.unavailable("The saved Wabi chat's sidebar entry is ambiguous. Open it in Wabi and try again.") }
            try await click(matches[0], target, session: session)
            (state, native) = try await settled(target, session: session) { _, native in native.url == savedURL && native.draft != nil }
            try empty(state, native)
            guard native.url == savedURL else { throw DesktopAppError.unavailable("Wabi did not open the saved chat. No message was sent or replacement created.") }
            return savedURL
        }
        let original = native.url
        let existing = Set(native.links.map(\.url))
        try await click(button(state, "New chat"), target, session: session)
        (state, native) = try await settled(target, session: session, purpose: .readiness) { state, native in
            (native.draft == nil || native.draft == "") && WabiAppProfile.isNewChatChooser(state)
        }
        guard native.url == original, native.draft == nil || native.draft == "", WabiAppProfile.isNewChatChooser(state) else {
            throw DesktopAppError.unavailable("Wabi did not open its New chat chooser. Nothing was sent.")
        }
        try await click(WabiAppProfile.newAIChatChoice(state), target, session: session)
        (state, native) = try await settled(target, session: session) { _, native in native.url != original && native.draft != nil }
        try empty(state, native)
        guard native.url != original, !existing.contains(native.url),
              state.body.filter({ $0.role == "AXHeading" }).compactMap(\.label) == ["New chat"],
              native.messages == [.init(role: .assistant, text: "What can I do for you?")],
              try state.wabiIsBlankAIChat else { throw DesktopAppError.unavailable("Wabi's new AI chat could not be confirmed. Nothing was sent.") }
        return native.url
    }
    func reply(_ prompt: String, in url: URL) async throws -> String {
        guard !occupied else { throw DesktopAppError.unavailable("Wabi is already handling a request.") }
        occupied = true
        defer { occupied = false }
        guard WabiThread.isValid(url), !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DesktopAppError.unavailable("Prepare this comparison's dedicated Wabi chat first.") }
        guard !prompt.unicodeScalars.contains(where: { ($0.value < 0x20 && $0.value != 0x0a) || $0.value == 0x7f }) else {
            throw DesktopAppError.unavailable("Wabi cannot safely type control characters such as tabs. Replace them with spaces; your prompt was preserved.")
        }
        let session = "msgblast-wabi-send-\(UUID())"
        defer { Task { await driver.endSession(session) } }
        let target = try await driver.target(.wabi)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-wabi-input-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("window.png")
        var (state, native) = try await observe(target, session: session, screenshotURL: image)
        guard native.url == url else { throw DesktopAppError.unavailable("Wabi's selected chat changed. Nothing was sent.") }
        try empty(state, native)
        let receipt = WabiAppReceipt(baseline: native.messages, prompt: prompt)
        var point = (x: 0, y: 0)
        try await DesktopAppWorkflow.enterText(prompt, before: { step in
            if !step.first { (state, native) = try await self.observe(target, session: session, screenshotURL: image) }
            let field = try state.composer(app: .wabi)
            guard native.url == url, native.draft == step.before, self.driverDraftAgrees(field, with: step.before),
                  receipt.unchanged(native.messages), !state.isGenerating,
                  step.before.isEmpty || native.composerFocused == true else {
                throw DesktopAppError.unavailable("Wabi's draft, focus, or chat changed. Send was not pressed; review the preserved text.")
            }
            point = try state.pixelCenter(of: field.element, target: target, imageURL: image, appName: "Wabi")
        }, perform: { step in
            if step.input == .newline, native.composerFocused != true {
                _ = try await self.driver.call("click", ["session": session, "delivery_mode": "background"], numbers: ["pid": target.pid, "window_id": target.window, "x": point.x, "y": point.y], as: DesktopAppConversation.Action.self)
                let (focusedState, focused) = try await self.observe(target, session: session)
                guard focused.url == url, focused.draft == step.before, try self.driverDraftAgrees(focusedState.composer(app: .wabi), with: step.before),
                      focused.composerFocused == true, receipt.unchanged(focused.messages), !focusedState.isGenerating else {
                    throw DesktopAppError.unavailable("Wabi did not retain focus in its empty composer. Nothing was submitted.")
                }
            }
            try await self.driver.input(step.input, focus: step.before.isEmpty, point: point, target: target, session: session)
        }, after: { step in
            (state, native) = try await self.observe(target, session: session)
            guard native.url == url, native.draft == step.after, try self.driverDraftAgrees(state.composer(app: .wabi), with: step.after),
                  native.composerFocused == true, receipt.unchanged(native.messages), !state.isGenerating else {
                throw DesktopAppError.unavailable("Wabi's prepared draft, focus, or chat changed. Send was not pressed; review the preserved text.")
            }
        })
        return try await DesktopAppWorkflow.reply(app: "Wabi", timing: timing, submit: {
            try await self.click(state.sendButton(app: .wabi), target, session: session)
        }, observe: {
            (state, native) = try await self.observe(target, session: session)
            guard native.url == url else { throw DesktopAppError.unavailable("Wabi switched chats while waiting. No automatic resend.") }
            return native.draft == "" && !state.isGenerating ? try receipt.reply(in: native.messages) : nil
        })
    }
}
