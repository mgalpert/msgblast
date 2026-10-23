import ApplicationServices
import Darwin
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

// The driver omits AXURL. Read it independently so a title can never identify
// a saved Wabi chat.
enum WabiNativeReader {
    static func capture(_ target: DesktopAppConversation.Target, purpose: WabiReadPurpose = .conversation) throws -> WabiAppObservation {
        guard AXIsProcessTrusted() else { throw DesktopAppError.unavailable("Grant msgblast Accessibility permission to verify Wabi's dedicated chat.") }
        func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
        }
        func string(_ element: AXUIElement, _ key: String) -> String { attribute(element, key) as? String ?? "" }
        guard let window = DesktopNativeWindowLookup.resolve(target) else { throw DesktopAppError.unavailable("Wabi's exact window is unavailable. Dismiss dialogs and try again.") }
        var webAreas: [AXUIElement] = [], composers: [AXUIElement] = [], links: [WabiAppObservation.Link] = []
        var initialURL: URL?
        var count = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        func walk(_ element: AXUIElement, depth: Int) throws -> WabiAXNode {
            count += 1
            guard count <= 6000, depth <= 60, ContinuousClock.now < deadline else { throw DesktopAppError.unavailable("Wabi's accessibility tree is incomplete.") }
            let role = string(element, "AXRole")
            guard role != "AXSheet", role != "AXDialog" else { throw DesktopAppError.unavailable("Dismiss Wabi's dialog before continuing.") }
            let title = string(element, "AXTitle")
            let label = title.isEmpty ? string(element, "AXDescription") : title
            if role == "AXWebArea" { webAreas.append(element); initialURL = attribute(element, "AXURL") as? URL }
            if ["AXTextArea", "AXTextField"].contains(role), label == "Message" { composers.append(element) }
            if role == "AXLink", let url = attribute(element, "AXURL") as? URL { links.append(.init(label: label, url: url)) }
            let children = try (attribute(element, "AXChildren") as? [AXUIElement] ?? []).map { try walk($0, depth: depth + 1) }
            return WabiAXNode(role: role, label: label, value: string(element, "AXValue"),
                              classes: role == "AXGroup" ? attribute(element, "AXDOMClassList") as? [String] ?? [] : [], children: children)
        }
        let tree = try walk(window, depth: 0)
        let url = try WabiThread.verifiedURL(initialURL, currentURL: webAreas.first.flatMap { attribute($0, "AXURL") as? URL },
                                             webAreaCount: webAreas.count, composerCount: composers.count, purpose: purpose)
        let draft: String?
        if let composer = composers.first {
            guard let value = attribute(composer, "AXValue") as? String else { throw DesktopAppError.unavailable("Wabi's draft is unreadable. It was preserved.") }
            draft = value
        } else { draft = nil }
        guard attribute(webAreas[0], "AXURL") as? URL == url else { throw DesktopAppError.unavailable("Wabi navigated while reading its draft.") }
        let app = AXUIElementCreateApplication(pid_t(target.pid))
        AXUIElementSetMessagingTimeout(app, 0.2)
        let currentFocus = attribute(app, "AXFocusedUIElement")
        let focused = composers.first.map { composer in
            if let currentFocus, CFGetTypeID(currentFocus) == AXUIElementGetTypeID() {
                return CFEqual(currentFocus, composer)
            }
            return attribute(composer, "AXFocused") as? Bool == true
        } ?? false
        return .init(url: url, draft: draft, links: links, messages: try WabiNativeMessages.read(tree, purpose: purpose), composerFocused: focused)
    }
}

actor WabiAppConversation {
    static let shared = WabiAppConversation()
    typealias NativeRead = @Sendable (DesktopAppConversation.Target, WabiReadPurpose) throws -> WabiAppObservation
    private let driver: DesktopAppConversation
    private let timing: DesktopAppConversation.Timing
    private let readNative: NativeRead
    private var occupied = false
    init(executable: URL? = nil, timing: DesktopAppConversation.Timing = .init(), readNative: @escaping NativeRead = { try WabiNativeReader.capture($0, purpose: $1) }) {
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
        let before = try await native(target, purpose: purpose)
        let state = try await driver.snapshot(target, session: session, screenshotURL: screenshotURL)
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
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while true {
            do {
                let (state, native) = try await observe(target, session: session, purpose: purpose)
                if try expected(state, native) { return (state, native) }
            } catch WabiObservationError.transient { }
            guard ContinuousClock.now < deadline else { throw DesktopAppError.unavailable("Wabi did not open the expected chat. Nothing was sent or retried.") }
            try await Task.sleep(for: timing.pollInterval)
        }
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
            native.draft == nil && state.body.contains(where: { $0.role == "AXTextField" && $0.label == "Name, username, or phone number" })
        }
        guard native.url == original, native.draft == nil,
              state.body.contains(where: { $0.role == "AXTextField" && $0.label == "Name, username, or phone number" }),
              state.body.first(where: { $0.role == "AXHeading" })?.label == "New chat" else {
            throw DesktopAppError.unavailable("Wabi did not open its New chat chooser. Nothing was sent.")
        }
        try await click(button(state, "New chat"), target, session: session)
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
        // Literal Return is a submit key in Electron. Confirm disjoint text
        // chunks and explicit Shift-Return line breaks before advancing.
        enum Input { case text(String), newline }
        var inputs: [Input] = []
        let lines = prompt.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            let characters = Array(line)
            for offset in stride(from: 0, to: characters.count, by: 256) {
                inputs.append(.text(String(characters[offset..<min(offset + 256, characters.count)])))
            }
            if index < lines.count - 1 { inputs.append(.newline) }
        }
        var prefix = ""
        for (index, input) in inputs.enumerated() {
            if index > 0 { (state, native) = try await observe(target, session: session, screenshotURL: image) }
            let field = try state.composer(app: .wabi)
            guard native.url == url, native.draft == prefix, driverDraftAgrees(field, with: prefix),
                  receipt.unchanged(native.messages), !state.isGenerating,
                  prefix.isEmpty || native.composerFocused == true else {
                throw DesktopAppError.unavailable("Wabi's draft, focus, or chat changed. Send was not pressed; review the preserved text.")
            }
            let point = try state.pixelCenter(of: field.element, target: target, imageURL: image, appName: "Wabi")
            switch input {
            case .text(let chunk):
                var numbers = ["pid": target.pid, "window_id": target.window, "delay_ms": 0]
                // Focus once; clicking again could move the insertion point
                // into a previously verified prefix.
                if prefix.isEmpty { numbers["x"] = point.x; numbers["y"] = point.y }
                _ = try await driver.call("type_text", ["session": session, "text": chunk, "delivery_mode": "background"], numbers: numbers, as: DesktopAppConversation.Action.self)
                prefix += chunk
            case .newline:
                if native.composerFocused != true {
                    _ = try await driver.call("click", ["session": session, "delivery_mode": "background"], numbers: ["pid": target.pid, "window_id": target.window, "x": point.x, "y": point.y], as: DesktopAppConversation.Action.self)
                    let (focusedState, focused) = try await observe(target, session: session)
                    guard focused.url == url, focused.draft == prefix, try driverDraftAgrees(focusedState.composer(app: .wabi), with: prefix),
                          focused.composerFocused == true, receipt.unchanged(focused.messages), !focusedState.isGenerating else {
                        throw DesktopAppError.unavailable("Wabi did not retain focus in its empty composer. Nothing was submitted.")
                    }
                }
                _ = try await driver.call("press_key", ["session": session, "key": "return", "delivery_mode": "background"], numbers: ["pid": target.pid, "window_id": target.window], arrays: ["modifiers": ["shift"]], as: DesktopAppConversation.Action.self)
                prefix += "\n"
            }
            (state, native) = try await observe(target, session: session)
            guard native.url == url, native.draft == prefix, try driverDraftAgrees(state.composer(app: .wabi), with: prefix),
                  native.composerFocused == true, receipt.unchanged(native.messages), !state.isGenerating else {
                throw DesktopAppError.unavailable("Wabi's prepared draft, focus, or chat changed. Send was not pressed; review the preserved text.")
            }
        }
        try await click(state.sendButton(app: .wabi), target, session: session)
        let deadline = ContinuousClock.now.advanced(by: timing.replyTimeout)
        var previous: String?
        var stableSince = ContinuousClock.now
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: timing.pollInterval)
            do { (state, native) = try await observe(target, session: session) }
            catch WabiObservationError.transient { previous = nil; stableSince = .now; continue }
            guard native.url == url else { throw DesktopAppError.unavailable("Wabi switched chats while waiting. No automatic resend.") }
            let candidate = native.draft == "" ? try receipt.reply(in: native.messages) : nil
            if candidate != previous || state.isGenerating { previous = candidate; stableSince = .now }
            if let candidate, !state.isGenerating, ContinuousClock.now - stableSince >= timing.stableDuration { return candidate }
        }
        throw DesktopAppError.unavailable("No stable Wabi reply was observed. Review the saved chat before explicitly allowing another request.")
    }
}
