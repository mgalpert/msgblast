import Foundation

actor GeminiAppConversation {
    static let shared = GeminiAppConversation()
    typealias NativeRead = @Sendable (DesktopAppConversation.Target, Bool) throws -> GeminiAppObservation
    private let driver: DesktopAppConversation
    private let timing: DesktopAppConversation.Timing
    private let readNative: NativeRead
    private var occupied = false
    init(executable: URL? = nil, timing: DesktopAppConversation.Timing = .init(), readNative: @escaping NativeRead = { try GeminiNativeReader.capture($0, allowingRename: $1) }) {
        driver = DesktopAppConversation(executable: executable, timing: timing)
        self.timing = timing; self.readNative = readNative
    }
    private func read(_ target: DesktopAppConversation.Target, rename: Bool = false) async throws -> GeminiAppObservation {
        let read = readNative
        var remainingRetries = 2
        while true {
            try Task.checkCancellation()
            do { return try await Task.detached { try read(target, rename) }.value }
            catch is GeminiObservationError where remainingRetries > 0 {
                remainingRetries -= 1
                try await Task.sleep(for: timing.pollInterval)
            }
        }
    }
    private func empty(_ native: GeminiAppObservation) throws {
        guard native.draft.isEmpty, !native.generating else { throw DesktopAppError.unavailable("Gemini has a draft or an active response. It was preserved.") }
    }
    // Resolve a native semantic control against one fresh driver snapshot. Titles
    // alone cannot distinguish Gemini's identically labelled toolbar buttons.
    private func token(_ control: GeminiAXNode, target: DesktopAppConversation.Target, session: String, rename: Bool = false, expected: GeminiAppObservation? = nil) async throws -> String {
        let before = try await read(target, rename: rename)
        guard expected.map({ $0.sameConversation(as: before) }) ?? true else { throw DesktopAppError.unavailable("Gemini changed before input. Nothing was typed or submitted.") }
        let state = try await driver.snapshot(target, session: session)
        try state.checkReadable()
        let after = try await read(target, rename: rename)
        guard before.sameConversation(as: after), state.pid == target.pid, state.window_id == target.window else { throw DesktopAppError.unavailable("Gemini changed during the check. Nothing was retried.") }
        let current = after.nodes.filter { $0.role == control.role && $0.id == control.id && $0.label == control.label && $0.frame == control.frame && $0.value == control.value && $0.selectedText == control.selectedText }
        let matches = state.body.filter { e in
            e.role == control.role && e.enabled != false && e.element_token != nil &&
            (control.frame != nil ? e.frame == control.frame : e.label == control.label)
        }
        guard current.count == 1, matches.count == 1 else { throw DesktopAppError.unavailable("Gemini’s control could not be verified for background input.") }
        return matches[0].element_token!
    }
    private func attemptActionOnce(_ tool: String = "click", control: GeminiAXNode, text: String? = nil, target: DesktopAppConversation.Target, session: String, rename: Bool = false, expected: GeminiAppObservation? = nil) async throws {
        let token = try await token(control, target: target, session: session, rename: rename, expected: expected)
        var args = ["element_token": token, "session": session, "delivery_mode": "background"]
        if let text { args["text"] = text }
        do { _ = try await driver.call(tool, args, numbers: ["pid": target.pid, "window_id": target.window], as: DesktopAppConversation.Action.self) }
        catch { try Task.checkCancellation() }
    }
    private func click(label: String, role: String = "AXButton", target: DesktopAppConversation.Target, session: String, rename: Bool = false) async throws {
        try await attemptActionOnce(control: read(target, rename: rename).control(label: label, role: role), target: target, session: session, rename: rename)
    }
    private func open(_ binding: GeminiConversationBinding?, mode: GeminiMode, target: DesktopAppConversation.Target, session: String) async throws -> GeminiAppObservation {
        var native = try await read(target)
        try empty(native)
        if let binding, let title = binding.title {
            guard binding.mode == mode, title == binding.dedicatedTitle,
                  binding.fallbackTitle.map({ !$0.isEmpty }) ?? true else { throw DesktopAppError.unavailable("Gemini’s saved conversation identity is invalid. It was preserved.") }
            let titles = [title, binding.fallbackTitle].compactMap { $0 }
            if !titles.contains(native.title) {
                let dedicated = native.nodes.filter { $0.role == "AXButton" && $0.label == title }
                let fallback = native.nodes.filter { $0.role == "AXButton" && $0.label == binding.fallbackTitle }
                let candidates = dedicated.isEmpty ? fallback : dedicated
                guard candidates.count == 1 else { throw DesktopAppError.unavailable("Gemini’s saved conversation is missing or ambiguous. No replacement was created.") }
                try await attemptActionOnce(control: candidates[0], target: target, session: session)
                native = try await read(target)
            }
            // The current transcript's saved nonce proves ownership even if
            // Gemini renders duplicate automatic titles as sidebar rows.
            // Navigation above still requires one unambiguous saved target.
            guard titles.contains(native.title), let prompt = binding.firstPrompt,
                  prompt.hasPrefix("[msgblast comparison \(binding.comparisonID.uuidString)]\n\n"),
                  native.messages.first == .init(role: .user, text: prompt) else { throw DesktopAppError.unavailable("Open this comparison’s dedicated Gemini conversation and check again. No replacement was created.") }
            return native
        }
        guard binding?.firstPrompt == nil else { throw DesktopAppError.unavailable("Gemini’s first submission was interrupted. Review its saved conversation before starting a new comparison; nothing will be resent.") }
        if !native.isNew {
            let buttons = native.nodes.filter { $0.id == "newChat_button" || ($0.role == "AXButton" && $0.label == "Gemini") }
            guard let control = buttons.first(where: { $0.id == "newChat_button" }) ?? buttons.first, buttons.count <= 2 else { throw DesktopAppError.unavailable("Gemini’s New chat control is unavailable.") }
            try await attemptActionOnce(control: control, target: target, session: session)
            native = try await read(target)
        }
        guard native.isNew else { throw DesktopAppError.unavailable("Gemini did not open a blank conversation. Nothing was sent.") }
        if native.mode != mode {
            try await attemptActionOnce(control: native.control(id: mode == .chat ? "chat-input-mode-ask" : "chat-input-mode-assign"), target: target, session: session)
            native = try await read(target)
        }
        try empty(native)
        guard native.isNew, native.mode == mode else { throw DesktopAppError.unavailable("Gemini did not select \(mode.name). Nothing was sent.") }
        return native
    }
    private func modelMenu(target: DesktopAppConversation.Target, session: String) async throws -> GeminiAppObservation {
        let native = try await read(target)
        guard !native.nodes.contains(where: { $0.role == "AXPopover" }) else {
            throw DesktopAppError.unavailable("Close Gemini’s model picker before checking its options.")
        }
        try await click(label: native.model, target: target, session: session)
        if let opened = try await observedModelMenu(expected: native, target: target) { return opened }

        // Gemini can accept AXPress without opening this native popover. Only
        // this non-submitting control gets a background pixel alternative,
        // after a bounded read-back and a new exact-window capture.
        try await capturedClick(label: native.model, expected: native, popovers: 0, target: target, session: session)
        guard let opened = try await observedModelMenu(expected: native, target: target) else {
            throw DesktopAppError.unavailable("Gemini’s model picker did not open. No message was sent.")
        }
        return opened
    }
    private func capturedClick(label: String, expected: GeminiAppObservation, popovers: Int, target: DesktopAppConversation.Target, session: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-gemini-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("picker.png")
        let before = try await read(target)
        guard expected.sameConversation(as: before), before.nodes.filter({ $0.role == "AXPopover" }).count == popovers else {
            throw DesktopAppError.unavailable("Gemini changed before opening its picker. Nothing was clicked.")
        }
        let control = try before.control(label: label)
        let state = try await driver.snapshot(target, session: session, screenshotURL: image)
        let after = try await read(target)
        let current = try after.control(label: label)
        guard before.sameConversation(as: after), after.nodes.filter({ $0.role == "AXPopover" }).count == popovers,
              current.frame == control.frame, current.id == control.id, current.role == control.role,
              let capture = state.capture_id else {
            throw DesktopAppError.unavailable("Gemini’s picker control changed or its capture could not be verified. Nothing was clicked.")
        }
        let matches = state.body.filter { $0.role == control.role && $0.frame == control.frame && $0.enabled != false && $0.element_token != nil }
        guard matches.count == 1 else { throw DesktopAppError.unavailable("Gemini’s picker control is missing or ambiguous. Nothing was clicked.") }
        let point = try state.pixelCenter(of: matches[0], target: target, imageURL: image, appName: "Gemini")
        do {
            _ = try await driver.call("click", ["session": session, "delivery_mode": "background", "capture_id": capture],
                                      numbers: ["pid": target.pid, "window_id": target.window, "x": point.x, "y": point.y], as: DesktopAppConversation.Action.self)
        } catch { try Task.checkCancellation() }
    }
    private func thinkingChoices(_ native: GeminiAppObservation, models: [String]) -> [GeminiAXNode] {
        (native.nodes.last { $0.role == "AXPopover" }?.descendants ?? []).filter {
            $0.role == "AXButton" && $0.enabled && !$0.label.isEmpty && $0.label != "Thinking level" && !models.contains($0.label)
        }
    }
    private func observedThinkingMenu(expected: GeminiAppObservation, models: [String], target: DesktopAppConversation.Target) async throws -> GeminiAppObservation? {
        for attempt in 0..<3 {
            let native = try await read(target)
            guard expected.sameConversation(as: native) else { throw DesktopAppError.unavailable("Gemini changed while opening its thinking levels. Nothing was retried.") }
            if !thinkingChoices(native, models: models).isEmpty { return native }
            if attempt < 2 { try await Task.sleep(for: timing.pollInterval) }
        }
        return nil
    }
    private func thinkingMenu(expected: GeminiAppObservation, models: [String], target: DesktopAppConversation.Target, session: String) async throws -> GeminiAppObservation {
        try await click(label: "Thinking level", target: target, session: session)
        if let opened = try await observedThinkingMenu(expected: expected, models: models, target: target) { return opened }
        // Some Gemini versions dismiss the parent popover on AXPress. Reopen
        // only the non-submitting picker, then verify a fresh pixel target.
        var parent = try await read(target)
        guard expected.sameConversation(as: parent) else { throw DesktopAppError.unavailable("Gemini changed before recovering its thinking picker. Nothing was clicked.") }
        if !parent.nodes.contains(where: { $0.role == "AXPopover" }) {
            parent = try await modelMenu(target: target, session: session)
        }
        guard expected.sameConversation(as: parent), modelChoices(parent).map(\.label) == models else {
            throw DesktopAppError.unavailable("Gemini’s model options changed. Nothing was clicked.")
        }
        try await capturedClick(label: "Thinking level", expected: parent, popovers: 1, target: target, session: session)
        guard let opened = try await observedThinkingMenu(expected: expected, models: models, target: target) else {
            throw DesktopAppError.unavailable("Gemini’s thinking picker did not open. Nothing was sent.")
        }
        return opened
    }
    private func observedModelMenu(expected: GeminiAppObservation, target: DesktopAppConversation.Target) async throws -> GeminiAppObservation? {
        for attempt in 0..<3 {
            let native = try await read(target)
            guard expected.sameConversation(as: native) else { throw DesktopAppError.unavailable("Gemini changed while opening its model picker. Nothing was retried.") }
            let count = native.nodes.filter { $0.role == "AXPopover" }.count
            if count == 1 { return native }
            guard count == 0 else { throw DesktopAppError.unavailable("Gemini’s model picker is ambiguous. Nothing was clicked.") }
            if attempt < 2 { try await Task.sleep(for: timing.pollInterval) }
        }
        return nil
    }
    private func modelChoices(_ native: GeminiAppObservation) -> [GeminiAXNode] {
        native.nodes.filter { $0.role == "AXPopover" }.flatMap(\.descendants).filter { $0.role == "AXButton" && $0.label.contains(", ") && $0.enabled }
    }
    private func configure(_ desired: GeminiPreferences, target: DesktopAppConversation.Target, session: String) async throws -> (GeminiPreferences, GeminiOptions) {
        var menu = try await modelMenu(target: target, session: session)
        var choices = modelChoices(menu)
        let models = choices.map(\.label)
        guard Set(models).count == models.count, !models.isEmpty,
              let selected = choices.first(where: \.selected), choices.filter(\.selected).count == 1 else { throw DesktopAppError.unavailable("Gemini’s available models could not be read.") }
        let model = desired.model ?? selected.label
        guard models.contains(model) else {
            try await click(label: selected.label, target: target, session: session)
            throw GeminiSelectionError(options: .init(models: models), message: "The selected model isn’t available in Gemini’s \(desired.mode.name) mode. Choose an available model.")
        }
        if model != selected.label {
            try await click(label: model, target: target, session: session)
            menu = try await modelMenu(target: target, session: session)
            choices = modelChoices(menu)
            guard choices.filter(\.selected).map(\.label) == [model] else { throw DesktopAppError.unavailable("Gemini did not select the requested model.") }
        }
        var levels: [String] = [], thinking: String?
        if menu.nodes.contains(where: { $0.role == "AXButton" && $0.label == "Thinking level" }) {
            let submenu = try await thinkingMenu(expected: menu, models: models, target: target, session: session)
            let options = thinkingChoices(submenu, models: models)
            levels = options.map(\.label)
            guard Set(levels).count == levels.count, !levels.isEmpty, options.filter(\.selected).count == 1 else { throw DesktopAppError.unavailable("Gemini’s thinking levels are unavailable. Nothing was sent.") }
            thinking = desired.thinking ?? options.first(where: \.selected)?.label
            guard let thinking, levels.contains(thinking) else {
                try await click(label: options.first(where: \.selected)!.label, target: target, session: session)
                throw GeminiSelectionError(options: .init(models: models, thinkingLevels: levels), message: "Choose an available Gemini thinking level.")
            }
            let alreadySelected = options.contains { $0.label == thinking && $0.selected }
            try await click(label: thinking, target: target, session: session)
            if !alreadySelected {
                let reopened = try await modelMenu(target: target, session: session)
                let checked = try await thinkingMenu(expected: reopened, models: models, target: target, session: session)
                guard checked.nodes.contains(where: { $0.role == "AXButton" && $0.label == thinking && $0.selected }) else { throw DesktopAppError.unavailable("Gemini did not apply the requested thinking level.") }
                try await click(label: thinking, target: target, session: session)
            }
        } else {
            try await click(label: model, target: target, session: session)
            guard desired.thinking == nil else {
                throw GeminiSelectionError(options: .init(models: models), message: "This Gemini model has no selectable thinking level. Use Gemini’s default thinking or choose a supported model.")
            }
        }
        let closed = try await read(target)
        guard !closed.nodes.contains(where: { $0.role == "AXPopover" }) else { throw DesktopAppError.unavailable("Close Gemini’s model picker and check again.") }
        return (.init(mode: desired.mode, model: model, thinking: thinking), .init(models: models, thinkingLevels: levels))
    }
    func checkAvailable() async throws {
        guard !occupied else { throw DesktopAppError.unavailable("Gemini is already handling a request.") }
        occupied = true; defer { occupied = false }
        let target = try await driver.target(.gemini)
        try empty(await read(target))
    }
    func prepare(binding: GeminiConversationBinding?, preferences: GeminiPreferences) async throws -> (GeminiPreferences, GeminiOptions) {
        guard !occupied else { throw DesktopAppError.unavailable("Gemini is already handling a request.") }
        occupied = true; defer { occupied = false }
        let session = "msgblast-gemini-options-\(UUID())"
        defer { Task { await driver.endSession(session) } }
        let target = try await driver.target(.gemini)
        _ = try await open(binding, mode: preferences.mode, target: target, session: session)
        return try await configure(preferences, target: target, session: session)
    }
    private func rename(_ binding: GeminiConversationBinding, expected: GeminiAppObservation, target: DesktopAppConversation.Target, session: String) async throws {
        var native = try await read(target)
        try empty(native)
        guard native.sameConversation(as: expected), native.messages.first == .init(role: .user, text: binding.firstPrompt ?? "") else { throw DesktopAppError.unavailable("Gemini changed before its optional rename. No title was edited.") }
        try await attemptActionOnce(control: native.control(id: "more_button"), target: target, session: session, expected: native)
        native = try await read(target)
        guard native.sameConversation(as: expected) else { throw DesktopAppError.unavailable("Gemini changed before Rename. No title was edited.") }
        try await attemptActionOnce(control: native.control(label: "Rename", role: "AXMenuItem"), target: target, session: session, expected: native)
        native = try await read(target, rename: true)
        let sheets = native.nodes.filter { $0.role == "AXSheet" }
        let fields = sheets.flatMap(\.descendants).filter { $0.role == "AXTextField" }
        guard native.sameConversation(as: expected), sheets.count == 1, fields.count == 1, let value = fields[0].value, value == native.title, fields[0].selectedText == value,
              sheets[0].descendants.filter({ $0.role == "AXButton" && $0.label == "Confirm" }).count == 1 else { throw DesktopAppError.unavailable("Gemini’s Rename field is not ready. No text was replaced.") }
        try await attemptActionOnce("type_text", control: fields[0], text: binding.dedicatedTitle, target: target, session: session, rename: true, expected: native)
        native = try await read(target, rename: true)
        guard native.sameConversation(as: expected), native.nodes.filter({ $0.role == "AXTextField" }).compactMap(\.value) == [binding.dedicatedTitle] else { throw DesktopAppError.unavailable("Gemini’s dedicated title could not be verified.") }
        try await attemptActionOnce(control: native.control(label: "Confirm"), target: target, session: session, rename: true, expected: native)
        let renamed = try await read(target)
        guard renamed.title == binding.dedicatedTitle, renamed.messages.first == .init(role: .user, text: binding.firstPrompt ?? "") else { throw DesktopAppError.unavailable("Gemini did not save its dedicated conversation title.") }
    }
    func reply(_ text: String, binding: GeminiConversationBinding, preferences: GeminiPreferences,
               onPrepared: @Sendable (GeminiConversationBinding) async throws -> Void,
               onBinding: @Sendable (GeminiConversationBinding) async throws -> Void) async throws -> String {
        guard !occupied else { throw DesktopAppError.unavailable("Gemini is already handling a request.") }
        occupied = true; defer { occupied = false }
        let session = "msgblast-gemini-send-\(UUID())"
        defer { Task { await driver.endSession(session) } }
        let target = try await driver.target(.gemini)
        let prompt = binding.title == nil ? binding.firstMessage(text) : text
        let opened = try await open(binding, mode: preferences.mode, target: target, session: session)
        _ = try await configure(preferences, target: target, session: session)
        var native = try await read(target)
        try empty(native)
        guard opened.sameContent(as: native) else { throw DesktopAppError.unavailable("Gemini changed during configuration. Nothing was typed or submitted.") }
        let baseline = native.messages
        let field = try native.composer()
        var pending = binding
        pending.firstPrompt = pending.firstPrompt ?? prompt
        try await onPrepared(pending)
        try await attemptActionOnce("type_text", control: field, text: prompt, target: target, session: session, expected: native)
        let prepared = try await read(target)
        guard prepared.draft == prompt, prepared.messages == baseline, prepared.title == native.title, prepared.model == native.model else { throw DesktopAppError.unavailable("Gemini’s prepared prompt changed. It was not sent or retried.") }
        try await attemptActionOnce(control: prepared.control(id: "send_button"), target: target, session: session, expected: prepared)
        let deadline = ContinuousClock.now.advanced(by: timing.replyTimeout)
        var stableText: String?, stableSince = ContinuousClock.now
        while ContinuousClock.now < deadline {
            do { native = try await read(target) }
            catch is GeminiObservationError {
                stableText = nil
                try Task.checkCancellation()
                try await Task.sleep(for: timing.pollInterval)
                continue
            }
            guard binding.title == nil || native.title == opened.title else { throw DesktopAppError.unavailable("Gemini navigated away from this comparison. No reply was attributed.") }
            guard native.draft.isEmpty || native.draft == prompt else { throw DesktopAppError.unavailable("Gemini’s draft changed while waiting. Review its conversation.") }
            let messages = native.messages
            guard messages.starts(with: baseline), messages.count <= baseline.count + 2 else { throw DesktopAppError.unavailable("Gemini’s conversation changed. No reply was attributed.") }
            if messages.count > baseline.count {
                guard messages[baseline.count] == .init(role: .user, text: prompt) else { throw DesktopAppError.unavailable("Gemini’s outgoing message did not match this request.") }
            }
            if messages.count == baseline.count + 2, let answer = messages.last, answer.role == .assistant, !native.generating, native.draft.isEmpty {
                if stableText != answer.text { stableText = answer.text; stableSince = .now }
                if ContinuousClock.now - stableSince >= timing.stableDuration {
                    var saved = pending
                    if saved.title == nil {
                        guard !native.title.isEmpty, !native.isNew else { throw DesktopAppError.unavailable("Gemini’s completed conversation title could not be read. Its reply was preserved in the native app.") }
                        saved.title = binding.dedicatedTitle
                        saved.fallbackTitle = native.title
                        // The exact first prompt owns this chat even if cosmetic
                        // renaming fails or the process stops during that edit.
                        try await onBinding(saved)
                        do { try await rename(saved, expected: native, target: target, session: session) }
                        catch {
                            try Task.checkCancellation()
                            if error is CancellationError { throw error }
                            return answer.text
                        }
                    } else { try await onBinding(saved) }
                    return answer.text
                }
            } else { stableText = nil }
            try await Task.sleep(for: timing.pollInterval)
        }
        throw DesktopAppError.unavailable("Gemini has not completed its reply. Review the dedicated conversation; nothing will be resent automatically.")
    }
}
