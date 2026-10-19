import Foundation

public enum DesktopAppProvider: String, Codable, Sendable {
    case muse, grokBot, wabi
    public var name: String { switch self { case .muse: "Muse"; case .grokBot: "Grok Bot"; case .wabi: "Wabi" } }
    var bundleID: String { switch self { case .muse: "com.meta.endo"; case .grokBot: "com.anysphere.sand"; case .wabi: "ai.wabi.desktop" } }
}

public struct DesktopConversationBinding: Codable, Equatable, Sendable {
    public let name: String
    public init(name: String) { self.name = name }
}

enum DesktopAppError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? { switch self { case .unavailable(let reason): reason } }
}

struct DesktopAppSnapshot: Decodable, Sendable {
    struct Element: Decodable, Sendable {
        let role: String
        var label: String?
        var value: String?
        var element_token: String?
        var in_web_content: Bool?
        var enabled: Bool?
        var text: String { value ?? label ?? "" }
    }
    let elements: [Element]
    var degraded: Bool?
    var element_count: Int?
    var returned_element_count: Int?
    var total_element_count: Int?

    var body: ArraySlice<Element> { elements.prefix { $0.role != "AXMenuBar" } }
    func checkReadable() throws {
        // 0.22 reports elements_complete=false even for an untruncated walk.
        // Require the returned-count contract and the app-specific sentinels instead.
        guard degraded != true, !body.isEmpty,
              total_element_count == nil || total_element_count == (returned_element_count ?? element_count) else {
            throw DesktopAppError.unavailable("The app's accessibility snapshot is incomplete. Nothing will be sent automatically.")
        }
    }
    func conversation(app: DesktopAppProvider) throws -> String {
        try checkReadable()
        let headings = body.filter { $0.role == "AXHeading" }.compactMap(\.label).filter { !$0.isEmpty }
        switch app {
        case .wabi:
            guard headings == ["Wabi"] else { throw DesktopAppError.unavailable("Open the Wabi AI conversation in Wabi. Human conversations are not supported.") }
            return "Wabi"
        case .grokBot:
            guard headings.count == 1 else { throw DesktopAppError.unavailable("Open one Grok Bot conversation before connecting.") }
            return headings[0]
        case .muse:
            // The Muse heading is shared by its main chat and every side chat.
            throw DesktopAppError.unavailable("Muse side-chat tracking and draft verification are not available yet. Automatic sends remain disabled.")
        }
    }
    func composer(app: DesktopAppProvider) throws -> (element: Element, draft: String) {
        try checkReadable()
        let label = app == .grokBot ? "Prompt" : "Message"
        let matches = body.filter { ["AXTextArea", "AXTextField"].contains($0.role) && $0.label == label }
        guard matches.count == 1, let field = matches.first, field.element_token != nil else {
            throw DesktopAppError.unavailable("\(app.name)'s message field is not exposed for background input. Open its composer and reconnect.")
        }
        let placeholders = ["", "Say something…", "Message", "Message \((try? conversation(app: app)) ?? "")"]
        return (field, placeholders.contains(field.value ?? "") ? "" : field.value ?? "")
    }
    func sendButton(app: DesktopAppProvider) throws -> Element {
        let label = app == .grokBot ? "Send message" : "Send"
        let matches = body.filter { $0.role == "AXButton" && $0.label == label && $0.enabled != false }
        guard matches.count == 1, let button = matches.first, button.element_token != nil else {
            throw DesktopAppError.unavailable("\(app.name)'s Send control could not be identified. Review the app's draft before retrying.")
        }
        return button
    }
    private func transcript(app: DesktopAppProvider) throws -> [Element] {
        let input = try composer(app: app).element
        guard let end = body.firstIndex(where: { $0.element_token == input.element_token && $0.role == input.role }) else {
            throw DesktopAppError.unavailable("The app's transcript boundary is unavailable.")
        }
        let content = body[..<end]
        if app == .muse { return Array(content) }
        guard let sidebar = content.lastIndex(where: { $0.role == "AXSplitter" && $0.label == "Resize sidebar" }) else {
            throw DesktopAppError.unavailable("The app's conversation cannot be separated from its sidebar. Nothing will be sent automatically.")
        }
        return Array(content.dropFirst(sidebar + 1))
    }
    func outgoingCount(_ prompt: String, app: DesktopAppProvider) throws -> Int {
        let text = app == .muse ? "User message: \(prompt)" : prompt
        return try transcript(app: app).filter { $0.role == "AXStaticText" && $0.text == text }.count
    }
    func reply(after prompt: String, app: DesktopAppProvider, outgoingOccurrence: Int = 1) throws -> String? {
        let name = try conversation(app: app)
        let transcript = try transcript(app: app)
        let outgoing = app == .muse ? "User message: \(prompt)" : prompt
        let matches = transcript.indices.filter { transcript[$0].role == "AXStaticText" && transcript[$0].text == outgoing }
        guard outgoingOccurrence > 0, matches.count >= outgoingOccurrence else { return nil }
        let sent = matches[outgoingOccurrence - 1]
        if app == .muse {
            let reply = transcript.dropFirst(sent + 1).last { $0.text.hasPrefix("Assistant message: ") }
            return reply.map { String($0.text.dropFirst("Assistant message: ".count)) }
        }
        let tail = transcript.dropFirst(sent + 1)
        if app == .grokBot, tail.contains(where: { $0.role == "AXStaticText" && $0.text == "You" }) {
            throw DesktopAppError.unavailable("Another message appeared in the app while waiting. Review the conversation before continuing.")
        }
        let content: [Element]
        if app == .grokBot {
            guard let speaker = tail.firstIndex(where: { $0.role == "AXStaticText" && $0.text == name }) else { return nil }
            content = Array(tail.suffix(from: speaker + 1))
        } else {
            let reactions = tail.indices.filter { tail[$0].role == "AXPopUpButton" && tail[$0].label == "Add reaction" }
            guard reactions.count >= 2 else { return nil }
            content = Array(tail[(reactions[0] + 1)..<reactions[1]])
        }
        var values = content.filter { $0.role == "AXStaticText" }.map(\.text).filter { !$0.isEmpty }
        if app == .grokBot {
            if values.count > 1, let last = values.last, Self.isTimestamp(last) { values.removeLast() }
        } else {
            if let first = values.first, Self.isTimestamp(first) { values.removeFirst() }
            if values.count > 1, values.first == "Read" { values.removeFirst() }
        }
        let text = values.joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }
    private static func isTimestamp(_ text: String) -> Bool {
        text.range(of: #"^(?:Today )?\d{1,2}:\d{2}\s*[AP]M$"#, options: .regularExpression) != nil
    }
    var isGenerating: Bool {
        body.contains { element in
            let text = (element.label ?? "").lowercased()
            return element.role == "AXProgressIndicator" || text == "stop" || text.hasPrefix("stop generating") || text.hasPrefix("stop response")
        }
    }
}

actor DesktopAppConversation {
    static let shared = DesktopAppConversation()
    private var occupied: Set<DesktopAppProvider> = []
    struct Timing: Sendable {
        var pollInterval: Duration = .seconds(1)
        var stableDuration: Duration = .seconds(3)
        var replyTimeout: Duration = .seconds(180)
        var callTimeout: TimeInterval = 30
    }
    private let executable: URL?
    private let timing: Timing
    init(executable: URL? = nil, timing: Timing = Timing()) {
        self.executable = executable ?? Self.findDriver()
        self.timing = timing
    }
    private static func findDriver() -> URL? {
        let paths = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
                     "/opt/homebrew/bin", "/usr/local/bin"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return paths.map { URL(fileURLWithPath: $0).appendingPathComponent("cua-driver") }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    private struct Target: Sendable { let pid: Int; let window: Int }
    private struct AppList: Decodable, Sendable { struct App: Decodable, Sendable { let bundle_id: String; let pid: Int; let running: Bool }; let apps: [App] }
    private struct WindowList: Decodable, Sendable {
        struct Window: Decodable, Sendable { struct Bounds: Decodable, Sendable { let width: Double; let height: Double }; let window_id: Int; let title: String?; let bounds: Bounds }
        let windows: [Window]
    }
    private func call<Response: Decodable & Sendable>(_ tool: String, _ arguments: [String: String], numbers: [String: Int] = [:], booleans: [String: Bool] = [:], as type: Response.Type) async throws -> Response {
        guard let executable else { throw DesktopAppError.unavailable("Install cua-driver and grant its Accessibility permission before connecting desktop apps.") }
        var object: [String: Any] = arguments
        for (key, value) in numbers { object[key] = value }
        for (key, value) in booleans { object[key] = value }
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let cancellation = AgentCancellation()
        let callTimeout = timing.callTimeout
        let result = try await withTaskCancellationHandler {
            try await Task.detached {
                try AgentProcess.run(executable: executable, arguments: ["call", tool, payload], input: "",
                                     environment: ProcessInfo.processInfo.environment, timeout: callTimeout, cancellation: cancellation)
            }.value
        } onCancel: { cancellation.cancel() }
        guard result.status == 0, let data = result.stdout.data(using: .utf8) else {
            throw DesktopAppError.unavailable("cua-driver could not complete \(tool). Check its service and permissions; nothing will be retried automatically.")
        }
        let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if envelope?["refusal"] != nil || envelope?["status"] as? String == "refused" || envelope?["effect"] as? String == "refused" || envelope?["isError"] as? Bool == true || envelope?["error"] != nil {
            throw DesktopAppError.unavailable("cua-driver refused \(tool). Review the app and driver permissions; foreground control is never automatic.")
        }
        return try JSONDecoder().decode(type, from: data)
    }
    private struct Action: Decodable, Sendable { var effect: String? }
    private func target(_ app: DesktopAppProvider) async throws -> Target {
        let apps = try await call("list_apps", [:], as: AppList.self)
        guard let live = apps.apps.first(where: { $0.bundle_id == app.bundleID && $0.running }) else {
            throw DesktopAppError.unavailable("Open \(app.name), sign in, and select its conversation first.")
        }
        let windows = try await call("list_windows", [:], numbers: ["pid": live.pid], as: WindowList.self)
        let candidates = windows.windows.filter { $0.bounds.width >= 400 && $0.bounds.height >= 400 && !($0.title ?? "").isEmpty && $0.title != "Log in" }
        guard candidates.count == 1, let window = candidates.first else {
            throw DesktopAppError.unavailable("Keep one main \(app.name) window open and dismiss any dialogs before connecting.")
        }
        return Target(pid: live.pid, window: window.window_id)
    }
    private func snapshot(_ target: Target, session: String) async throws -> DesktopAppSnapshot {
        try await call("get_window_state", ["session": session], numbers: ["pid": target.pid, "window_id": target.window, "max_elements": 5000, "max_depth": 40], booleans: ["include_screenshot": false], as: DesktopAppSnapshot.self)
    }
    func inspect(_ app: DesktopAppProvider) async throws -> DesktopConversationBinding {
        guard !occupied.contains(app) else { throw DesktopAppError.unavailable("\(app.name) is already handling a request.") }
        let session = "msgblast-inspect-\(UUID().uuidString)"
        defer { Task { await endSession(session) } }
        let target = try await target(app)
        let state = try await snapshot(target, session: session)
        let name = try state.conversation(app: app)
        guard try state.composer(app: app).draft.isEmpty else { throw DesktopAppError.unavailable("\(app.name) has an unsent draft. Send or clear it in the app first.") }
        return DesktopConversationBinding(name: name)
    }
    func reply(_ prompt: String, app: DesktopAppProvider, binding: DesktopConversationBinding) async throws -> String {
        guard occupied.insert(app).inserted else { throw DesktopAppError.unavailable("\(app.name) is already handling a request.") }
        defer { occupied.remove(app) }
        let session = "msgblast-send-\(UUID().uuidString)"
        defer { Task { await endSession(session) } }
        let target = try await target(app)
        var state = try await snapshot(target, session: session)
        try validate(state, app: app, binding: binding)
        let previousPromptCount = try state.outgoingCount(prompt, app: app)
        let field = try state.composer(app: app)
        guard field.draft.isEmpty else { throw DesktopAppError.unavailable("\(app.name) has an unsent draft. It was preserved.") }
        _ = try await call("type_text", ["session": session, "element_token": field.element.element_token!, "text": prompt, "delivery_mode": "background"], numbers: ["pid": target.pid, "window_id": target.window], as: Action.self)
        state = try await snapshot(target, session: session)
        try validate(state, app: app, binding: binding)
        guard try state.composer(app: app).draft == prompt else {
            throw DesktopAppError.unavailable("The app did not confirm the prepared draft. Check it before trying again; Send was not clicked.")
        }
        let button = try state.sendButton(app: app)
        _ = try await call("click", ["session": session, "element_token": button.element_token!, "delivery_mode": "background"], numbers: ["pid": target.pid, "window_id": target.window], as: Action.self)
        let deadline = ContinuousClock.now.advanced(by: timing.replyTimeout)
        var previous: String?
        var stableSince = ContinuousClock.now
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: timing.pollInterval)
            state = try await snapshot(target, session: session)
            try validate(state, app: app, binding: binding)
            let promptCount = try state.outgoingCount(prompt, app: app)
            let composerCleared = try state.composer(app: app).draft.isEmpty
            let candidate = composerCleared && promptCount > previousPromptCount
                ? try state.reply(after: prompt, app: app, outgoingOccurrence: previousPromptCount + 1) : nil
            if candidate != previous || state.isGenerating { previous = candidate; stableSince = .now }
            if let candidate, !state.isGenerating, ContinuousClock.now - stableSince >= timing.stableDuration { return candidate }
        }
        throw DesktopAppError.unavailable("No stable reply was observed. The app may still be working. Check the conversation before explicitly allowing another request.")
    }
    private func endSession(_ session: String) async {
        _ = try? await call("end_session", ["session": session], as: Action.self)
    }
    private func validate(_ state: DesktopAppSnapshot, app: DesktopAppProvider, binding: DesktopConversationBinding) throws {
        guard try state.conversation(app: app) == binding.name else {
            throw DesktopAppError.unavailable("The open \(app.name) conversation changed. Open the connected conversation or reconnect; no automatic resend.")
        }
    }
}
