import Foundation

actor ClaudeAppConversation {
    static let shared = ClaudeAppConversation()
    typealias NativeRead = @Sendable (DesktopAppConversation.Target) throws -> ClaudeAppObservation
    private let driver: DesktopAppConversation
    private let timing: DesktopAppConversation.Timing
    private let readNative: NativeRead
    private var occupied = false

    init(executable: URL? = nil, timing: DesktopAppConversation.Timing = .init(), readNative: @escaping NativeRead = ClaudeAppProfile.capture) {
        driver = DesktopAppConversation(executable: executable, timing: timing)
        self.timing = timing; self.readNative = readNative
    }
    private func native(_ target: DesktopAppConversation.Target) async throws -> ClaudeAppObservation {
        try Task.checkCancellation()
        let read = readNative
        return try await Task.detached { try read(target) }.value
    }
    private func observe(_ target: DesktopAppConversation.Target, session: String, screenshotURL: URL? = nil) async throws -> (DesktopAppSnapshot, ClaudeAppObservation) {
        let before = try await native(target)
        let state = try await driver.snapshot(target, session: session, screenshotURL: screenshotURL)
        try state.checkReadable()
        let after = try await native(target)
        guard before.url == after.url, before.draft == after.draft, before.windowBounds == after.windowBounds, before.composerFrame == after.composerFrame else { throw DesktopAppError.unavailable("Claude changed while verifying its conversation. No action was replayed.") }
        guard state.pid == target.pid, state.window_id == target.window else { throw DesktopAppError.unavailable("Claude's driver snapshot belongs to a different window.") }
        return (state, after)
    }
    private func composer(_ state: DesktopAppSnapshot, _ observation: ClaudeAppObservation) throws -> DesktopAppSnapshot.Element {
        let fields = state.body.filter { $0.role == "AXTextArea" && $0.label == "Write your prompt to Claude" && $0.element_token != nil && $0.enabled != false }
        var withoutTerminalNewlines = observation.rawNativeDraft
        while withoutTerminalNewlines.last == "\n" { withoutTerminalNewlines.removeLast() }
        // The driver omits terminal LF characters that native AX preserves.
        // Native draft checks still verify every append and the final prompt.
        guard fields.count == 1, fields[0].frame == observation.composerFrame,
              fields[0].value == observation.rawNativeDraft || fields[0].value == withoutTerminalNewlines ||
              (observation.draft.isEmpty && (fields[0].value == nil || fields[0].value == "\n")) else {
            throw DesktopAppError.unavailable("Claude's draft or composer geometry could not be verified. Existing text was preserved.")
        }
        return fields[0]
    }
    private func empty(_ state: DesktopAppSnapshot, _ observation: ClaudeAppObservation) throws {
        _ = try composer(state, observation)
        guard observation.draft.isEmpty, !observation.generating, !state.isGenerating else { throw DesktopAppError.unavailable("Claude has an unsent draft or active response. It was preserved.") }
    }
    private func control(_ state: DesktopAppSnapshot, role: String = "AXButton", label: String) throws -> DesktopAppSnapshot.Element {
        let matches = state.body.filter { $0.role == role && $0.label == label && $0.enabled != false && $0.element_token != nil }
        guard matches.count == 1 else { throw DesktopAppError.unavailable("Claude's \(label) control is missing or ambiguous.") }
        return matches[0]
    }
    private func click(_ element: DesktopAppSnapshot.Element, target: DesktopAppConversation.Target, session: String) async throws {
        _ = try await driver.call("click", ["element_token": element.element_token!, "session": session, "delivery_mode": "background"], numbers: ["pid": target.pid, "window_id": target.window], as: DesktopAppConversation.Action.self)
    }
    private func opened(_ binding: ClaudeConversationBinding, target: DesktopAppConversation.Target, session: String) async throws -> ClaudeAppObservation {
        var (state, observation) = try await observe(target, session: session)
        try empty(state, observation)
        if let url = binding.url {
            guard ClaudeChatURL.isChat(url), let first = binding.firstPrompt, first.hasPrefix("[msgblast comparison \(binding.comparisonID.uuidString)]\n\n") else { throw DesktopAppError.unavailable("Claude's saved conversation binding is invalid. No replacement was created.") }
            if observation.url != url {
                let links = observation.links.filter { $0.url == url }
                guard links.count <= 1 else { throw DesktopAppError.unavailable("Claude's saved chat has ambiguous sidebar links. No navigation was attempted.") }
                if let link = links.first {
                    try await click(control(state, role: "AXLink", label: link.label), target: target, session: session)
                } else {
                    // Claude registers this native URI. Keep routing scoped to
                    // its bundle; an HTTPS URL would open the default browser.
                    do {
                        _ = try await driver.call("launch_app", ["bundle_id": DesktopAppProvider.claude.bundleID],
                                                  arrays: ["urls": ["claude://claude.ai" + url.path]], as: DesktopAppConversation.Action.self)
                    } catch {
                        try Task.checkCancellation()
                        // The URI may have opened despite a missing receipt.
                        // Observe its result without launching it a second time.
                    }
                }
                (state, observation) = try await settled(target, session: session) { $0.url == url }
                try empty(state, observation)
            }
            guard observation.url == url, observation.messages.first == .init(role: .user, text: first) else { throw DesktopAppError.unavailable("Claude's saved chat does not contain this comparison's first message. Nothing was sent.") }
            return observation
        }
        guard binding.firstPrompt == nil else { throw DesktopAppError.unavailable("Claude's first send is unresolved. Review it in Claude; no replacement chat or duplicate prompt was created.") }
        if !ClaudeChatURL.isNew(observation.url) {
            try await click(control(state, label: "New"), target: target, session: session)
            (state, observation) = try await settled(target, session: session) { ClaudeChatURL.isNew($0.url) }
            try empty(state, observation)
        }
        guard ClaudeChatURL.isNew(observation.url), observation.messages.isEmpty else { throw DesktopAppError.unavailable("Claude's new conversation could not be confirmed.") }
        return observation
    }
    private func settled(_ target: DesktopAppConversation.Target, session: String, expected: (ClaudeAppObservation) -> Bool) async throws -> (DesktopAppSnapshot, ClaudeAppObservation) {
        try await DesktopAppWorkflow.wait(timeout: .seconds(8), interval: timing.pollInterval,
            failure: "Claude did not open the expected conversation. Nothing was sent.",
            read: { try await self.observe(target, session: session) }, ready: { expected($0.1) })
    }

    func checkAvailable() async throws {
        guard !occupied else { throw DesktopAppError.unavailable("Claude is already handling a request.") }
        occupied = true; defer { occupied = false }
        let session = "msgblast-claude-check-\(UUID())"
        defer { Task { await driver.endSession(session) } }
        let target = try await driver.target(.claude)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while true {
            do {
                let (state, observation) = try await observe(target, session: session)
                try empty(state, observation)
                _ = try control(state, label: "New")
                return
            } catch ClaudeObservationError.transient where ContinuousClock.now < deadline {
                try await Task.sleep(for: timing.pollInterval)
            } catch DesktopAppError.incompleteSnapshot where ContinuousClock.now < deadline {
                try await Task.sleep(for: timing.pollInterval)
            }
        }
    }
    func prepare(comparisonID: UUID, binding: ClaudeConversationBinding?) async throws -> ClaudeConversationBinding {
        guard !occupied else { throw DesktopAppError.unavailable("Claude is already handling a request.") }
        occupied = true; defer { occupied = false }
        let saved = binding ?? .init(comparisonID: comparisonID)
        guard saved.comparisonID == comparisonID else { throw DesktopAppError.unavailable("Claude's saved conversation belongs to another comparison.") }
        let session = "msgblast-claude-prepare-\(UUID())"
        defer { Task { await driver.endSession(session) } }
        let target = try await driver.target(.claude)
        _ = try await opened(saved, target: target, session: session)
        return saved
    }
    func reply(_ text: String, binding: ClaudeConversationBinding,
               onPrepared: @Sendable (ClaudeConversationBinding) async throws -> Void,
               onBinding: @Sendable (ClaudeConversationBinding) async throws -> Void) async throws -> String {
        guard !occupied else { throw DesktopAppError.unavailable("Claude is already handling a request.") }
        occupied = true; defer { occupied = false }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DesktopAppError.unavailable("Enter a prompt for Claude.") }
        let session = "msgblast-claude-send-\(UUID())"
        defer { Task { await driver.endSession(session) } }
        let target = try await driver.target(.claude)
        let baseline = try await opened(binding, target: target, session: session)
        let prompt = binding.url == nil ? binding.firstMessage(text) : text
        try DesktopAppWorkflow.validateText(prompt)
        let receipt = ClaudeAppReceipt(baseline: baseline.messages, prompt: prompt)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-claude-capture-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("window.png")
        let (captured, before) = try await observe(target, session: session, screenshotURL: image)
        try empty(captured, before)
        guard before == baseline, before.windowBounds == captured.window_bounds else { throw DesktopAppError.unavailable("Claude changed chats or moved before input. Nothing was typed.") }
        _ = try captured.pixelCenter(of: composer(captured, before), target: target, imageURL: image)
        var saved = binding
        if saved.firstPrompt == nil { saved.firstPrompt = prompt }
        try await onPrepared(saved)
        guard try await native(target) == before else { throw DesktopAppError.unavailable("Claude changed before input. Nothing was typed.") }
        var point = (x: 0, y: 0)
        var current = before
        try await DesktopAppWorkflow.enterText(prompt, before: { step in
            let (fresh, observed) = try await self.observe(target, session: session, screenshotURL: image)
            current = observed
            let field = try self.composer(fresh, current)
            guard current.url == baseline.url, current.messages == baseline.messages, current.draft == step.before,
                  !current.generating, !fresh.isGenerating, current.windowBounds == fresh.window_bounds,
                  step.before.isEmpty || current.composerFocused else {
                throw DesktopAppError.unavailable("Claude's draft, focus, or conversation changed before typing. Review the preserved text.")
            }
            point = try fresh.pixelCenter(of: field, target: target, imageURL: image)
        }, perform: { step in
            if step.input == .newline, !current.composerFocused {
                _ = try await self.driver.call("click", ["session": session, "delivery_mode": "background"], numbers: ["pid": target.pid, "window_id": target.window, "x": point.x, "y": point.y], as: DesktopAppConversation.Action.self)
                let focused = try await self.native(target)
                guard focused.url == baseline.url, focused.messages == baseline.messages, focused.draft == step.before, focused.composerFocused, !focused.generating else {
                    throw DesktopAppError.unavailable("Claude's empty composer did not retain focus. Nothing was submitted.")
                }
            }
            try await self.driver.input(step.input, focus: step.before.isEmpty, point: point, target: target, session: session)
        }, after: { step in
            let (typedState, typed) = try await self.observe(target, session: session)
            _ = try self.composer(typedState, typed)
            guard typed.url == baseline.url, typed.messages == baseline.messages, typed.draft == step.after,
                  typed.composerFocused, !typed.generating, !typedState.isGenerating else {
                throw DesktopAppError.unavailable("Claude did not confirm the prepared draft. Send was not pressed; review the preserved text.")
            }
        })
        let (draftState, draft) = try await observe(target, session: session)
        _ = try composer(draftState, draft)
        guard draft.url == baseline.url, draft.messages == baseline.messages, draft.draft == prompt, draft.composerFocused, !draft.generating, !draftState.isGenerating else { throw DesktopAppError.unavailable("Claude's prepared draft or conversation changed. Send was not pressed; review the preserved text.") }
        guard try await native(target) == draft else { throw DesktopAppError.unavailable("Claude changed before Send. Review the preserved draft.") }
        return try await DesktopAppWorkflow.reply(app: "Claude", timing: timing, submit: {
            try await self.click(self.control(draftState, label: "Send message"), target: target, session: session)
        }, observe: {
            let (state, current) = try await self.observe(target, session: session)
            if let url = saved.url {
                guard current.url == url else { throw DesktopAppError.unavailable("Claude switched conversations while waiting. No automatic resend.") }
            } else if ClaudeChatURL.isChat(current.url) {
                if !current.messages.isEmpty {
                    guard current.messages.first == .init(role: .user, text: prompt) else { throw DesktopAppError.unavailable("Claude's created chat did not contain this comparison's first prompt.") }
                    saved.url = current.url
                    try await onBinding(saved)
                }
            } else if !ClaudeChatURL.isNew(current.url) { throw DesktopAppError.unavailable("Claude's conversation address changed unexpectedly.") }
            guard saved.url != nil, current.draft.isEmpty, !current.generating, !state.isGenerating else { return nil }
            return try receipt.reply(in: current.messages)
        })
    }
}
