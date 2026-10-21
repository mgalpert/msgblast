import Foundation
import ImageIO

public enum DesktopAppProvider: String, Codable, Sendable {
    case muse, grokBot, wabi, gemini, chatgpt, dots, claude
    public var name: String { switch self { case .muse: "Muse"; case .grokBot: "Grok Bot"; case .wabi: "Wabi"; case .gemini: "Gemini"; case .chatgpt: "ChatGPT"; case .dots: "Dots"; case .claude: "Claude" } }
    var bundleIDs: [String] { switch self {
        case .muse: ["com.meta.endo"]
        case .grokBot: ["com.anysphere.sand"]
        case .wabi: ["ai.wabi.desktop"]
        case .gemini: ["com.google.GeminiMacOS"]
        case .chatgpt, .dots: ["com.openai.codex", "com.openai.chat"]
        case .claude: ["com.anthropic.claudefordesktop"]
    } }
    var bundleID: String { bundleIDs[0] }
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
        struct Frame: Decodable, Equatable, Sendable { let x: Double; let y: Double; let w: Double; let h: Double }
        let role: String
        var label: String?
        var value: String?
        var element_token: String?
        var in_web_content: Bool?
        var enabled: Bool?
        var element_index: Int?
        var parent_index: Int?
        var frame: Frame?
        var text: String { value ?? label ?? "" }
    }
    let elements: [Element]
    var degraded: Bool?
    var element_count: Int?
    var returned_element_count: Int?
    var total_element_count: Int?
    struct Bounds: Codable, Equatable, Sendable { let x: Double; let y: Double; let width: Double; let height: Double }
    var window_bounds: Bounds?
    var pid: Int?
    var window_id: Int?
    var screenshot_frame_valid: Bool?
    var screenshot_width: Int?
    var screenshot_height: Int?
    var screenshot_file_path: String?

    func pixelCenter(of element: Element, target: DesktopAppConversation.Target, imageURL: URL) throws -> (x: Int, y: Int) {
        try checkReadable()
        guard pid == target.pid, window_id == target.window, screenshot_frame_valid == true,
              screenshot_file_path.map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath() }) == imageURL.resolvingSymlinksInPath(), let width = screenshot_width, let height = screenshot_height,
              width > 0, height > 0, width <= 16_384, height <= 16_384,
              let bounds = window_bounds, let frame = element.frame, element.enabled != false,
              element.element_token != nil, body.contains(where: { $0.element_token == element.element_token }),
              [bounds.x, bounds.y, bounds.width, bounds.height, frame.x, frame.y, frame.w, frame.h].allSatisfy(\.isFinite),
              bounds.width > 0, bounds.height > 0, frame.w > 0, frame.h > 0,
              frame.x >= bounds.x, frame.y >= bounds.y,
              frame.x + frame.w <= bounds.x + bounds.width, frame.y + frame.h <= bounds.y + bounds.height,
              let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == width,
              properties[kCGImagePropertyPixelHeight] as? Int == height else {
            throw DesktopAppError.unavailable("Muse's current screenshot and control geometry could not be verified. Nothing was clicked.")
        }
        // Account for window origin and the driver's resized capture. Its scale
        // field alone does not describe the returned PNG's dimensions.
        let x = ((frame.x + frame.w / 2 - bounds.x) * Double(width) / bounds.width).rounded()
        let y = ((frame.y + frame.h / 2 - bounds.y) * Double(height) / bounds.height).rounded()
        guard x.isFinite, y.isFinite, x >= 0, x < Double(width), y >= 0, y < Double(height) else {
            throw DesktopAppError.unavailable("Muse's control geometry is outside the current capture.")
        }
        return (Int(x), Int(y))
    }

    var body: ArraySlice<Element> {
        // The embedded driver can return the application menu before the exact
        // window. Keep only that window's section, never menu controls.
        let start = elements.firstIndex { $0.role == "AXWindow" } ?? elements.startIndex
        return ArraySlice(elements[start...].prefix { $0.role != "AXMenuBar" })
    }
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
            let headers = body.filter { heading in
                heading.role == "AXHeading" && heading.element_index != nil && body.contains {
                    $0.role == "AXButton" && $0.label == "View conversation details" && $0.parent_index == heading.element_index
                }
            }
            if headers.count == 1, let name = headers[0].label, !name.isEmpty { return name }
            guard headings.count == 1 else { throw DesktopAppError.unavailable("Open one Grok Bot conversation before connecting.") }
            return headings[0]
        case .gemini, .chatgpt, .dots, .claude:
            throw DesktopAppError.unavailable("This app requires its dedicated conversation adapter.")
        case .muse:
            // The Muse heading is shared by its main chat and every side chat.
            throw DesktopAppError.unavailable("Muse requires a tracked side-chat binding. Connect Muse through its dedicated side-chat adapter.")
        }
    }
    func grokBots() throws -> [(name: String, element: Element)] {
        try checkReadable()
        guard let end = body.firstIndex(where: { $0.role == "AXSplitter" && $0.label == "Resize sidebar" }) else {
            throw DesktopAppError.unavailable("Grok Bot's bot list is unavailable. Open its sidebar and refresh the bots.")
        }
        let sidebar = body[..<end]
        let mainBotIndexes = Set(sidebar.filter { $0.role == "AXImage" && $0.label == "Main Bot" }.compactMap(\.parent_index))
        let listIndexes = Set(sidebar.filter { $0.role == "AXList" }.compactMap(\.element_index))
        return sidebar.compactMap { button in
            guard button.role == "AXButton", let index = button.element_index,
                  button.enabled != false, button.element_token != nil, var name = button.label else { return nil }
            let main = mainBotIndexes.contains(index)
            let listed = button.parent_index.map { listIndexes.contains($0) } == true
            guard main || listed else { return nil }
            if name.hasSuffix(", Unread activity") { name.removeLast(", Unread activity".count) }
            if main, name.hasSuffix(", Main Bot") { name.removeLast(", Main Bot".count) }
            return name.isEmpty ? nil : (name, button)
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
    var wabiIsBlankAIChat: Bool {
        get throws {
            let text = try transcript(app: .wabi).filter { $0.role == "AXStaticText" }.map(\.text)
                .filter { $0 != "Today" && !Self.isTimestamp($0) }
            return text == ["What can I do for you?"]
        }
    }
    func outgoingCount(_ prompt: String, app: DesktopAppProvider) throws -> Int {
        let text = app == .muse ? "User message: \(prompt)" : prompt
        return try transcript(app: app).filter { $0.role == "AXStaticText" && $0.text == text }.count
    }
    func reply(after prompt: String, app: DesktopAppProvider, outgoingOccurrence: Int = 1) throws -> String? {
        let name = app == .wabi ? "Wabi" : try conversation(app: app)
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
    private let embedded: Bool
    private let timing: Timing
    private let readGrok: @Sendable (Target) throws -> GrokBotNativeState
    init(executable: URL? = nil, timing: Timing = Timing(), readGrok: @escaping @Sendable (Target) throws -> GrokBotNativeState = GrokBotNativeReader.capture) {
        self.executable = executable ?? Self.findDriver()
        self.embedded = executable == nil
        self.timing = timing
        self.readGrok = readGrok
    }
    static func findDriver() -> URL? {
        EmbeddedCuaDriver.bundledExecutable()
    }
    struct Target: Sendable, Equatable { let pid: Int; let window: Int }
    private struct AppList: Decodable, Sendable { struct App: Decodable, Sendable { let bundle_id: String; let pid: Int; let running: Bool }; let apps: [App] }
    private struct WindowList: Decodable, Sendable {
        struct Window: Decodable, Sendable { struct Bounds: Decodable, Sendable { let width: Double; let height: Double }; let window_id: Int; let title: String?; var is_on_screen: Bool?; var space_ids: [UInt64]?; let bounds: Bounds }
        let windows: [Window]
    }
    func call<Response: Decodable & Sendable>(_ tool: String, _ arguments: [String: String], numbers: [String: Int] = [:], booleans: [String: Bool] = [:], arrays: [String: [String]] = [:], as type: Response.Type) async throws -> Response {
        guard let executable else { throw DesktopAppError.unavailable("App control is missing from this copy of msgblast. Reinstall msgblast.") }
        var object: [String: Any] = arguments
        for (key, value) in numbers { object[key] = value }
        for (key, value) in booleans { object[key] = value }
        for (key, value) in arrays { object[key] = value }
        let connection = embedded ? try await EmbeddedCuaDriver.shared.connection() : nil
        try Task.checkCancellation()
        if embedded && tool == "get_window_state" { object["tree_format"] = "elements" }
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let callArguments = connection?.arguments(tool: tool, payload: payload) ?? ["call", tool, payload]
        let environment = connection?.environment ?? ProcessInfo.processInfo.environment
        let cancellation = AgentCancellation()
        let callTimeout = timing.callTimeout
        let result = try await withTaskCancellationHandler {
            try await Task.detached {
                try AgentProcess.run(executable: executable, arguments: callArguments, input: "",
                                     environment: environment, timeout: callTimeout, cancellation: cancellation)
            }.value
        } onCancel: { cancellation.cancel() }
        guard result.status == 0, let data = result.stdout.data(using: .utf8) else {
            throw DesktopAppError.unavailable("App control could not complete this request. Review msgblast permissions; nothing will be retried automatically.")
        }
        let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if envelope?["refusal"] != nil || envelope?["status"] as? String == "refused" || envelope?["effect"] as? String == "refused" || envelope?["isError"] as? Bool == true || envelope?["error"] != nil {
            throw DesktopAppError.unavailable("App control refused this request. Review the app and msgblast permissions; foreground control is never automatic.")
        }
        return try JSONDecoder().decode(type, from: data)
    }
    struct Action: Decodable, Sendable { var effect: String? }
    private func grokState(_ state: DesktopAppSnapshot, target: Target) async throws -> GrokBotNativeState {
        try state.checkReadable()
        let read = readGrok
        let native = try await Task.detached { try read(target) }.value
        guard native.name == (try state.conversation(app: .grokBot)) else {
            throw DesktopAppError.unavailable("The Grok Bot conversation changed. Nothing was retried.")
        }
        return native
    }
    func availableGrokBots() async throws -> [String] {
        guard occupied.insert(.grokBot).inserted else { throw DesktopAppError.unavailable("Grok Bot is already handling a request.") }
        defer { occupied.remove(.grokBot) }
        let session = "msgblast-bots-\(UUID())"
        defer { Task { await endSession(session) } }
        let target = try await target(.grokBot)
        let state = try await snapshot(target, session: session)
        let grouped = Dictionary(grouping: try state.grokBots(), by: \.name)
        let names = grouped.filter { $0.value.count == 1 }.map(\.key).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        guard !names.isEmpty else { throw DesktopAppError.unavailable("No uniquely named bots were found. Open Grok Bot and refresh the bots.") }
        return names
    }
    private func checkedGrokBot(_ name: String, state: DesktopAppSnapshot, target: Target) async throws -> (native: GrokBotNativeState, element: DesktopAppSnapshot.Element) {
        let native = try await grokState(state, target: target)
        guard native.draft.isEmpty, !state.isGenerating else { throw DesktopAppError.unavailable("Grok Bot has an unsent draft or active response. It was preserved.") }
        let matches = try state.grokBots().filter { $0.name == name }
        guard matches.count == 1 else { throw DesktopAppError.unavailable("This bot is missing or has a duplicate name. Choose your bot again in msgblast.") }
        return (native, matches[0].element)
    }
    func checkGrokBot(named name: String) async throws {
        guard occupied.insert(.grokBot).inserted else { throw DesktopAppError.unavailable("Grok Bot is already handling a request.") }
        defer { occupied.remove(.grokBot) }
        let session = "msgblast-check-bot-\(UUID())"
        defer { Task { await endSession(session) } }
        let target = try await target(.grokBot)
        let state = try await snapshot(target, session: session)
        _ = try await checkedGrokBot(name, state: state, target: target)
    }
    private func openGrokBot(_ name: String, state initial: DesktopAppSnapshot, target: Target, session: String) async throws -> DesktopAppSnapshot {
        var state = initial
        let checked = try await checkedGrokBot(name, state: state, target: target)
        if checked.native.name == name { return state }
        _ = try await call("click", ["element_token": checked.element.element_token!, "session": session, "delivery_mode": "background"], numbers: ["pid": target.pid, "window_id": target.window], as: Action.self)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while true {
            state = try await snapshot(target, session: session)
            let opened = try await grokState(state, target: target)
            if opened.name == name {
                guard opened.draft.isEmpty, !state.isGenerating else { throw DesktopAppError.unavailable("Grok Bot has an unsent draft or active response. It was preserved.") }
                return state
            }
            guard ContinuousClock.now < deadline else { throw DesktopAppError.unavailable("Grok Bot did not open the selected bot. No message was sent.") }
            try await Task.sleep(for: timing.pollInterval)
        }
    }
    func connectGrokBot(named name: String) async throws -> DesktopConversationBinding {
        guard occupied.insert(.grokBot).inserted else { throw DesktopAppError.unavailable("Grok Bot is already handling a request.") }
        defer { occupied.remove(.grokBot) }
        let session = "msgblast-connect-bot-\(UUID())"
        defer { Task { await endSession(session) } }
        let target = try await target(.grokBot)
        let state = try await snapshot(target, session: session)
        _ = try await openGrokBot(name, state: state, target: target, session: session)
        return .init(name: name)
    }
    func target(_ app: DesktopAppProvider) async throws -> Target {
        let apps = try await call("list_apps", [:], as: AppList.self)
        guard let matches = app.bundleIDs.map({ bundle in apps.apps.filter { $0.bundle_id == bundle && $0.running } }).first(where: { !$0.isEmpty }) else {
            throw DesktopAppError.unavailable(app == .grokBot ? "Open Grok Bot and sign in, then choose your bot in msgblast." : "Open \(app.name), sign in, and select its conversation first.")
        }
        guard matches.count == 1, let live = matches.first else {
            throw DesktopAppError.unavailable("Quit extra copies of \(app.name) before connecting, so msgblast can use one account safely.")
        }
        let windows = try await call("list_windows", [:], numbers: ["pid": live.pid], as: WindowList.self)
        // Off-screen windows with a Space belong to another desktop. Hidden
        // application helpers have neither an on-screen surface nor a Space.
        let candidates = windows.windows.filter {
            $0.bounds.width >= 400 && $0.bounds.height >= 400 &&
            ($0.is_on_screen != false || !($0.space_ids ?? []).isEmpty) &&
            ([DesktopAppProvider.gemini, .chatgpt, .dots, .claude].contains(app) || !($0.title ?? "").isEmpty) &&
            $0.title != "Log in"
        }
        guard candidates.count == 1, let window = candidates.first else {
            throw DesktopAppError.unavailable("Keep one main \(app.name) window open and dismiss any dialogs before connecting.")
        }
        return Target(pid: live.pid, window: window.window_id)
    }
    func snapshot(_ target: Target, session: String, screenshotURL: URL? = nil) async throws -> DesktopAppSnapshot {
        var arguments = ["session": session]
        if let screenshotURL { arguments["screenshot_out_file"] = screenshotURL.path }
        return try await call("get_window_state", arguments, numbers: ["pid": target.pid, "window_id": target.window, "max_elements": 5000, "max_depth": 40], booleans: ["include_screenshot": screenshotURL != nil], as: DesktopAppSnapshot.self)
    }
    func reply(_ prompt: String, app: DesktopAppProvider, binding: DesktopConversationBinding) async throws -> String {
        guard ![DesktopAppProvider.wabi, .gemini, .chatgpt, .dots, .claude].contains(app) else { throw DesktopAppError.unavailable("Wabi requires a dedicated chat for each comparison.") }
        guard occupied.insert(app).inserted else { throw DesktopAppError.unavailable("\(app.name) is already handling a request.") }
        defer { occupied.remove(app) }
        let session = "msgblast-send-\(UUID().uuidString)"
        defer { Task { await endSession(session) } }
        let target = try await target(app)
        var state = try await snapshot(target, session: session)
        if app == .grokBot { state = try await openGrokBot(binding.name, state: state, target: target, session: session) }
        try validate(state, app: app, binding: binding)
        let previousPromptCount = try state.outgoingCount(prompt, app: app)
        let field = try state.composer(app: app)
        let draft = app == .grokBot ? try await grokState(state, target: target).draft : field.draft
        guard draft.isEmpty else { throw DesktopAppError.unavailable("\(app.name) has an unsent draft. It was preserved.") }
        _ = try await call("type_text", ["session": session, "element_token": field.element.element_token!, "text": prompt, "delivery_mode": "background"], numbers: ["pid": target.pid, "window_id": target.window], as: Action.self)
        state = try await snapshot(target, session: session)
        try validate(state, app: app, binding: binding)
        let prepared = app == .grokBot ? try await grokState(state, target: target).draft : try state.composer(app: app).draft
        guard prepared == prompt, try state.composer(app: app).element.value == prompt else {
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
            let composerCleared = app == .grokBot ? try await grokState(state, target: target).draft.isEmpty : try state.composer(app: app).draft.isEmpty
            let candidate = composerCleared && promptCount > previousPromptCount
                ? try state.reply(after: prompt, app: app, outgoingOccurrence: previousPromptCount + 1) : nil
            if candidate != previous || state.isGenerating { previous = candidate; stableSince = .now }
            if let candidate, !state.isGenerating, ContinuousClock.now - stableSince >= timing.stableDuration { return candidate }
        }
        throw DesktopAppError.unavailable("No stable reply was observed. The app may still be working. Check the conversation before explicitly allowing another request.")
    }
    func endSession(_ session: String) async {
        _ = try? await call("end_session", ["session": session], as: Action.self)
    }
    private func validate(_ state: DesktopAppSnapshot, app: DesktopAppProvider, binding: DesktopConversationBinding) throws {
        guard try state.conversation(app: app) == binding.name else {
            throw DesktopAppError.unavailable("The open \(app.name) conversation changed. Open the connected conversation or reconnect; no automatic resend.")
        }
    }
}
