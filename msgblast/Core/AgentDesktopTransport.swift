import Foundation

/// Opt-in Grok transport. Keep the workflow, native draft verification and receipts
/// in DesktopAppConversation; only driver observation and input change here.
actor AgentDesktopTransport {
    let executable: URL
    private let run: DesktopAppConversation.ProcessRunner
    private let timeout: TimeInterval
    private let namespace = "msgblast-grok-" + UUID().uuidString
    private let stateRoot = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-agent-desktop-" + UUID().uuidString, isDirectory: true)

    init(executable: URL, timeout: TimeInterval = 30,
         run: @escaping DesktopAppConversation.ProcessRunner = DesktopAppConversation.execute) {
        self.executable = executable
        self.timeout = timeout
        self.run = run
    }

    deinit { try? FileManager.default.removeItem(at: stateRoot) }

    private func command(_ arguments: [String]) async throws -> Data {
        if !FileManager.default.fileExists(atPath: stateRoot.path) {
            try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        var environment = ProcessInfo.processInfo.environment
        environment["AGENT_DESKTOP_HOME"] = stateRoot.path
        // A caller's session configuration must not redirect private
        // Grok snapshots into an unrelated tool session.
        for key in ["AGENT_DESKTOP_SESSION", "AGENT_DESKTOP_AGENT_ID"] { environment.removeValue(forKey: key) }
        let cancellation = AgentCancellation()
        let result = try await withTaskCancellationHandler {
            try await run(executable, arguments, environment, timeout, cancellation)
        } onCancel: { cancellation.cancel() }
        guard let bytes = result.stdout.data(using: .utf8),
              let envelope = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              result.status == 0, envelope["ok"] as? Bool == true, let data = envelope["data"] else {
            // Never retry an action: even a failed command may have delivered input.
            throw DesktopAppError.unavailable("Agent Desktop could not complete this request. Review the native app; nothing will be retried automatically.")
        }
        return try JSONSerialization.data(withJSONObject: data, options: .fragmentsAllowed)
    }

    private func object(_ arguments: [String]) async throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: await command(arguments)) as? [String: Any] else {
            throw DesktopAppError.incompleteSnapshot
        }
        return object
    }

    private func appName(_ pid: Int) async throws -> String {
        // Re-enumerate rather than retaining the identity of a process that exited.
        let result = try await object(["list-apps"])
        let entries = result["apps"] as? [[String: Any]] ?? []
        let matches = entries.filter { $0["pid"] as? Int == pid }
        guard matches.count == 1, let name = matches.first?["name"] as? String else {
            throw DesktopAppError.unavailable("The native app process changed. Reconnect before sending.")
        }
        return name
    }

    private func window(_ target: DesktopAppConversation.Target) async throws -> (String, [String: Any]) {
        let name = try await appName(target.pid)
        let rows = try JSONSerialization.jsonObject(with: await command(["list-windows", "--app", name])) as? [[String: Any]] ?? []
        let matches = rows.filter { $0["id"] as? String == "w-\(target.window)" && $0["pid"] as? Int == target.pid }
        guard matches.count == 1, let row = matches.first else {
            throw DesktopAppError.unavailable("The exact native app window is no longer available.")
        }
        return (name, row)
    }

    func call(_ tool: String, strings: [String: String], numbers: [String: Int]) async throws -> Data {
        let session = namespace
        let scope = ["--session", session]
        func encode(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        if tool == "end_session" {
            // Refs are namespaced and expire in the upstream command host. Never
            // close another caller's host or delete its state on session cleanup.
            return try encode([:])
        }
        if tool == "list_apps" {
            let result = try await object(["list-apps"])
            let rows = (result["apps"] as? [[String: Any]] ?? []).compactMap { row -> [String: Any]? in
                guard let pid = row["pid"] as? Int, let bundle = row["bundle_id"] as? String else { return nil }
                return ["pid": pid, "bundle_id": bundle, "running": true]
            }
            return try encode(["apps": rows])
        }
        guard let pid = numbers["pid"] else { throw DesktopAppError.incompleteSnapshot }
        if tool == "list_windows" {
            let name = try await appName(pid)
            let rows = try JSONSerialization.jsonObject(with: await command(["list-windows", "--app", name])) as? [[String: Any]] ?? []
            let windows = rows.filter { $0["pid"] as? Int == pid && $0["accessible"] as? Bool == true }.compactMap { row -> [String: Any]? in
                guard let id = row["id"] as? String, id.hasPrefix("w-"), let number = Int(id.dropFirst(2)),
                      let bounds = row["bounds"] as? [String: Any] else { return nil }
                // Upstream inventories real AX windows across Spaces. Do not turn
                // its onscreen flag into an eligibility rule: an accessible
                // offscreen window is still a destination (or ambiguity).
                return ["window_id": number, "title": row["title"] as? String ?? "", "bounds": bounds]
            }
            return try encode(["windows": windows])
        }
        guard let id = numbers["window_id"] else { throw DesktopAppError.incompleteSnapshot }
        let target = DesktopAppConversation.Target(pid: pid, window: id)
        let (name, _) = try await window(target)
        let selector = ["--app", name, "--window-id", "w-\(id)"]
        switch tool {
        case "get_window_state":
            let data = try await command(["snapshot"] + selector + scope + ["--max-depth", "40", "--include-bounds", "--timeout-ms", "10000"])
            return try Self.normalizeSnapshot(data, target: target)
        case "bring_to_front":
            _ = try await command(["focus-window", "--headed"] + selector + scope)
            let (_, observed) = try await window(target)
            guard observed["is_focused"] as? Bool == true else { throw DesktopAppError.incompleteSnapshot }
            return try encode(["activated": true, "pid": pid, "window_id": id, "exact_window_effect": ["verified": true]])
        case "click":
            guard let ref = strings["element_token"] else {
                throw DesktopAppError.unavailable("Agent Desktop requires a fresh control reference; coordinate fallback is disabled.")
            }
            _ = try await command(["click", ref] + scope)
            return try encode(["effect": "unverifiable"])
        default:
            throw DesktopAppError.unavailable("This operation is not supported by the Grok Agent Desktop transport.")
        }
    }

    func focusComposer(ref: String, target: DesktopAppConversation.Target) async throws {
        _ = try await window(target)
        _ = try await command(["focus", ref, "--session", namespace, "--headed"])
    }

    func enter(_ input: DesktopAppWorkflow.Input, ref: String, target: DesktopAppConversation.Target, session: String) async throws {
        let (name, _) = try await window(target)
        let scope = ["--session", namespace, "--headed"]
        switch input {
        case .text(let text):
            _ = try await command(["type", ref] + scope + ["--", text])
        case .newline:
            // The workflow checks the native composer focus before and after input.
            _ = try await command(["press", "shift+return", "--app", name, "--window-id", "w-\(target.window)"] + scope)
        }
    }

    static func normalizeSnapshot(_ data: Data, target: DesktopAppConversation.Target) throws -> Data {
        guard let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              snapshot["complete"] as? Bool == true,
              let window = snapshot["window"] as? [String: Any], window["id"] as? String == "w-\(target.window)",
              let root = snapshot["tree"] as? [String: Any] else { throw DesktopAppError.incompleteSnapshot }
        let roles = ["window": "AXWindow", "webarea": "AXWebArea", "heading": "AXHeading", "button": "AXButton",
                     "textfield": "AXTextField", "textarea": "AXTextArea", "statictext": "AXStaticText", "splitter": "AXSplitter",
                     "list": "AXList", "image": "AXImage", "link": "AXLink", "group": "AXGroup", "dialog": "AXDialog",
                     "sheet": "AXSheet", "progressindicator": "AXProgressIndicator", "progressbar": "AXProgressIndicator"]
        var elements: [[String: Any]] = []
        func walk(_ node: [String: Any], parent: Int?, web: Bool, depth: Int) throws {
            guard elements.count < 5000, depth <= 40, node["truncated"] as? Bool != true,
                  let role = node["role"] as? String else { throw DesktopAppError.incompleteSnapshot }
            let index = elements.count
            let inside = web || role == "webarea"
            var row: [String: Any] = ["role": roles[role] ?? "AXUnknown", "element_index": index, "in_web_content": inside]
            row["parent_index"] = parent
            row["label"] = node["name"]
            row["element_token"] = node["ref_id"]
            if ["textfield", "textarea", "statictext"].contains(role) {
                if node["name"] as? String == "Prompt", ["textfield", "textarea"].contains(role), let value = node["value"] as? String {
                    row["value"] = GrokBotAppProfile.draftValue(value, emptyEditor: false)
                } else { row["value"] = node["value"] }
            }
            row["enabled"] = !(node["states"] as? [String] ?? []).contains("disabled")
            if let bounds = node["bounds"] as? [String: Any] {
                row["frame"] = ["x": bounds["x"], "y": bounds["y"], "w": bounds["width"], "h": bounds["height"]].compactMapValues { $0 }
            }
            elements.append(row)
            for child in node["children"] as? [[String: Any]] ?? [] { try walk(child, parent: index, web: inside, depth: depth + 1) }
        }
        try walk(root, parent: nil, web: false, depth: 0)
        return try JSONSerialization.data(withJSONObject: ["elements": elements, "pid": target.pid, "window_id": target.window,
            "truncated": false, "degraded": false, "element_count": elements.count, "total_element_count": elements.count])
    }
}
