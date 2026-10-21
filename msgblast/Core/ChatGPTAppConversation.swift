import Foundation

actor ChatGPTAppConversation {
    static let shared = ChatGPTAppConversation()
    typealias NativeRead = @Sendable (DesktopAppConversation.Target) throws -> ChatGPTAppObservation
    private let driver: DesktopAppConversation
    private let timing: DesktopAppConversation.Timing
    private let readNative: NativeRead
    private var occupied = false
    init(executable: URL? = nil, timing: DesktopAppConversation.Timing = .init(), readNative: @escaping NativeRead = ChatGPTNativeReader.capture) {
        driver = DesktopAppConversation(executable: executable, timing: timing); self.timing = timing; self.readNative = readNative
    }
    private func read(_ target: DesktopAppConversation.Target) async throws -> ChatGPTAppObservation {
        let reader = readNative
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do { return try await Task.detached { try reader(target) }.value }
            catch ChatGPTObservationError.transient {
                guard attempt < 2 else { throw ChatGPTObservationError.transient }
                try await Task.sleep(for: timing.pollInterval)
            }
        }
        throw ChatGPTObservationError.transient
    }
    private func idle(_ native: ChatGPTAppObservation) throws {
        guard native.draft.isEmpty, !native.generating else { throw DesktopAppError.unavailable("ChatGPT has a draft or active response. It was preserved.") }
    }
    private func element(_ control: ChatGPTAXNode, target: DesktopAppConversation.Target, session: String, expected: ChatGPTAppObservation, imageURL: URL? = nil, semanticNavigation: Bool = false) async throws -> (DesktopAppSnapshot, DesktopAppSnapshot.Element) {
        let before = try await read(target)
        guard before.sameContent(as: expected) else { throw DesktopAppError.unavailable("ChatGPT changed before input. Nothing was retried.") }
        let state = try await driver.snapshot(target, session: session, screenshotURL: imageURL)
        try state.checkReadable()
        let after = try await read(target)
        guard before.sameContent(as: after), state.pid == target.pid, state.window_id == target.window,
              after.nodes.filter({ $0.role == control.role && $0.label == control.label && $0.frame == control.frame && $0.value == control.value && $0.selectedText == control.selectedText && $0.focused == control.focused }).count == 1 else { throw DesktopAppError.unavailable("ChatGPT changed during the input check.") }
        let semanticOnly = semanticNavigation && !control.visible && control.role == "AXButton" && control.classes.contains("sidebar-item")
        let matches = state.body.filter {
            $0.role == control.role && ($0.frame == control.frame || (semanticOnly && $0.frame == nil)) &&
            ((control.visible && !semanticOnly) || $0.label == control.label) && $0.enabled != false && $0.element_token != nil
        }
        guard control.visible || semanticOnly, matches.count == 1 else { throw DesktopAppError.unavailable("ChatGPT’s control could not be verified for background input.") }
        return (state, matches[0])
    }
    private func action(_ tool: String = "click", control: ChatGPTAXNode, text: String? = nil, key: String? = nil, target: DesktopAppConversation.Target, session: String, expected: ChatGPTAppObservation, pixel: Bool = false, semanticNavigation: Bool = false, verifyImage: Bool = false, modifiers: [String] = [], focusedInput: Bool = false) async throws {
        let image = pixel || verifyImage ? FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-chatgpt-\(UUID()).png") : nil
        defer { if let image { try? FileManager.default.removeItem(at: image) } }
        let (state, element) = try await element(control, target: target, session: session, expected: expected, imageURL: image, semanticNavigation: semanticNavigation)
        var args = ["session": session, "delivery_mode": "background", "element_token": element.element_token!]
        var numbers = ["pid": target.pid, "window_id": target.window]
        if let text { args["text"] = text }
        if let key { args["key"] = key }
        if let image {
            let center = try state.pixelCenter(of: element, target: target, imageURL: image)
            if pixel {
                numbers["x"] = center.x; numbers["y"] = center.y
                args.removeValue(forKey: "element_token")
            }
        }
        if focusedInput {
            guard control.focused else { throw DesktopAppError.unavailable("ChatGPT’s composer lost focus. Nothing was retried.") }
            args.removeValue(forKey: "element_token")
        }
        do { _ = try await driver.call(tool, args, numbers: numbers, arrays: modifiers.isEmpty ? [:] : ["modifiers": modifiers], as: DesktopAppConversation.Action.self) }
        catch { try Task.checkCancellation() }
    }
    private func open(_ binding: ChatGPTConversationBinding, target: DesktopAppConversation.Target, session: String) async throws -> ChatGPTAppObservation {
        var native = try await read(target)
        try idle(native)
        guard binding.title != nil || binding.firstPrompt == nil else { throw DesktopAppError.unavailable("The first native ChatGPT submission was interrupted. Review its conversation; nothing will be resent.") }
        if native.codexBootstrap {
            let codexMode = native.nodes.filter { $0.role == "AXPopUpButton" && $0.label == "Switch mode, current mode: Codex" }
            if !codexMode.isEmpty {
                try await action(control: native.unique(codexMode), target: target, session: session, expected: native)
                native = try await read(target)
                let choice = try native.control(label: "ChatGPT Create, learn, and explore", role: "AXMenuItem")
                try await action(control: choice, target: target, session: session, expected: native)
                native = try await read(target)
            }
            guard native.nodes.filter({ $0.role == "AXPopUpButton" && $0.label == "Switch mode, current mode: ChatGPT" }).count == 1 else { throw DesktopAppError.unavailable("ChatGPT’s mode did not change. No input was sent.") }
            try idle(native)
        }
        if binding.kind == .dots {
            if native.kind != .dots {
                let header = try native.unique(native.nodes.filter { $0.children.contains(where: { $0.role == "AXButton" && $0.label == "New chat" && $0.classes.contains("sidebar-item") }) })
                let dot = try native.unique(header.children.filter { $0.role == "AXButton" && $0.classes.contains("sidebar-item") && $0.label != "New chat" && $0.visible })
                try await action(control: dot, target: target, session: session, expected: native)
                native = try await read(target)
            }
            guard native.kind == .dots, binding.title == nil || binding.title == native.title else { throw DesktopAppError.unavailable("This comparison’s Dot is unavailable. No replacement was created.") }
            if let prompt = binding.firstPrompt {
                guard native.messages.contains(.init(role: .user, text: prompt)) else { throw DesktopAppError.unavailable("The saved Dot conversation does not contain this comparison’s first prompt.") }
            }
            return native
        }
        if let title = binding.title {
            guard title == binding.dedicatedTitle, let prompt = binding.firstPrompt,
                  binding.fallbackTitle.map({ !$0.isEmpty }) ?? true else { throw DesktopAppError.unavailable("ChatGPT’s saved conversation identity is invalid.") }
            let titles = [title, binding.fallbackTitle].compactMap { $0 }
            if native.kind != .chatgpt || !titles.contains(native.title) {
                let desired = native.nodes.filter { $0.role == "AXButton" && $0.label == title && $0.classes.contains("sidebar-item") }
                let candidates: [ChatGPTAXNode]
                if !desired.isEmpty { candidates = desired }
                else { candidates = native.nodes.filter { $0.role == "AXButton" && $0.label == binding.fallbackTitle && $0.classes.contains("sidebar-item") } }
                let button = try native.unique(candidates)
                try await action(control: button, target: target, session: session, expected: native, semanticNavigation: true)
                native = try await read(target)
            }
            guard native.kind == .chatgpt, titles.contains(native.title), native.messages.first == .init(role: .user, text: prompt) else { throw DesktopAppError.unavailable("Open this comparison’s dedicated ChatGPT chat. No replacement was created.") }
            return native
        }
        if native.kind != .chatgpt || !native.isNew {
            let new = try native.unique(native.nodes.filter { $0.role == "AXButton" && $0.label == "New chat" && $0.classes.contains("sidebar-item") && $0.visible })
            try await action(control: new, target: target, session: session, expected: native)
            native = try await read(target)
        }
        guard native.kind == .chatgpt, native.isNew else { throw DesktopAppError.unavailable("ChatGPT did not open a blank conversation.") }
        let switchers = native.nodes.filter { $0.role == "AXPopUpButton" && $0.label.hasPrefix("Switch mode, current mode:") }
        if switchers.count == 1, switchers[0].label != "Switch mode, current mode: ChatGPT" {
            try await action(control: switchers[0], target: target, session: session, expected: native)
            native = try await read(target)
            let choice = try native.control(label: "ChatGPT Create, learn, and explore", role: "AXMenuItem")
            try await action(control: choice, target: target, session: session, expected: native)
            native = try await read(target)
        }
        let chat = try native.control(label: "Chat", role: "AXCheckBox")
        if chat.value != "1" {
            try await action(control: chat, target: target, session: session, expected: native)
            native = try await read(target)
        }
        guard native.isNew, native.nodes.contains(where: { $0.role == "AXCheckBox" && $0.label == "Chat" && $0.value == "1" }) else { throw DesktopAppError.unavailable("ChatGPT’s Chat mode could not be verified. Nothing was sent.") }
        try idle(native)
        return native
    }
    func checkAvailable(kind: ChatGPTAppKind) async throws {
        guard !occupied else { throw DesktopAppError.unavailable("ChatGPT is already handling a request.") }
        occupied = true; defer { occupied = false }
        try idle(await read(driver.target(kind == .dots ? .dots : .chatgpt)))
    }
    func prepare(comparisonID: UUID, kind: ChatGPTAppKind, binding: ChatGPTConversationBinding?) async throws -> ChatGPTConversationBinding {
        guard !occupied else { throw DesktopAppError.unavailable("ChatGPT is already handling a request.") }
        occupied = true; defer { occupied = false }
        let saved = binding ?? .init(comparisonID: comparisonID, kind: kind)
        guard saved.comparisonID == comparisonID, saved.kind == kind else { throw DesktopAppError.unavailable("ChatGPT’s conversation binding belongs to another comparison.") }
        let session = "msgblast-chatgpt-prepare-\(UUID())"
        defer { Task { await driver.endSession(session) } }
        let target = try await driver.target(kind == .dots ? .dots : .chatgpt)
        let native = try await open(saved, target: target, session: session)
        var result = saved
        if kind == .dots { result.title = native.title }
        return result
    }
    private func rename(_ title: String, expected: ChatGPTAppObservation, target: DesktopAppConversation.Target, session: String) async throws {
        let headers = expected.nodes.filter { $0.subrole == "AXLandmarkBanner" || $0.classes.contains("group/titlebar") }
        let buttons = headers.flatMap(\.descendants).filter { $0.role == "AXButton" && $0.label == expected.title && $0.visible }
        let unique = Dictionary(grouping: buttons, by: { String(describing: $0.frame) }).compactMap { $0.value.first }
        try await action(control: expected.unique(unique), target: target, session: session, expected: expected)
        var native = try await read(target)
        var field = try native.control(label: "Chat title", role: "AXTextField")
        guard field.value == expected.title, field.selectedText == expected.title, native.messages == expected.messages else { throw DesktopAppError.unavailable("ChatGPT’s title field is not selected. Nothing was replaced.") }
        try await action("type_text", control: field, text: title, target: target, session: session, expected: native)
        native = try await read(target); field = try native.control(label: "Chat title", role: "AXTextField")
        guard field.value == title, native.messages == expected.messages else { throw DesktopAppError.unavailable("ChatGPT’s new title could not be verified.") }
        try await action("press_key", control: field, key: "return", target: target, session: session, expected: native)
        guard try await read(target).title == title else { throw DesktopAppError.unavailable("ChatGPT did not save the dedicated conversation title.") }
    }
    private func checkedDraft(_ expected: String, previous: ChatGPTAppObservation, target: DesktopAppConversation.Target) async throws -> ChatGPTAppObservation {
        let current = try await read(target)
        guard current.kind == previous.kind, current.title == previous.title, current.messages == previous.messages,
              !current.generating, current.draft == expected else { throw DesktopAppError.unavailable("ChatGPT did not confirm the exact prepared draft. Send was not pressed; review the preserved text.") }
        return current
    }
    func reply(_ text: String, binding: ChatGPTConversationBinding, onPrepared: @Sendable (ChatGPTConversationBinding) async throws -> Void, onBinding: @Sendable (ChatGPTConversationBinding) async throws -> Void) async throws -> String {
        guard !occupied else { throw DesktopAppError.unavailable("ChatGPT is already handling a request.") }
        occupied = true; defer { occupied = false }
        let session = "msgblast-chatgpt-send-\(UUID())"
        defer { Task { await driver.endSession(session) } }
        let target = try await driver.target(binding.kind == .dots ? .dots : .chatgpt)
        var native = try await open(binding, target: target, session: session)
        let baseline = native.messages, openedTitle = native.title, prompt = binding.firstPrompt == nil ? binding.firstMessage(text) : text
        var pending = binding
        pending.firstPrompt = binding.firstPrompt ?? prompt
        if binding.kind == .dots { pending.title = native.title }
        let preflightImage = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-chatgpt-preflight-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: preflightImage) }
        let (preflightState, preflightField) = try await element(native.composer, target: target, session: session, expected: native, imageURL: preflightImage)
        _ = try preflightState.pixelCenter(of: preflightField, target: target, imageURL: preflightImage)
        try await onPrepared(pending)
        var prepared = native
        var prefix = ""
        let chunks = prompt.components(separatedBy: "\n")
        for (index, line) in chunks.enumerated() {
            if index > 0 {
                if prefix.isEmpty && !prepared.composer.focused {
                    try await action(control: prepared.composer, target: target, session: session, expected: prepared, pixel: true)
                    prepared = try await checkedDraft(prefix, previous: prepared, target: target)
                }
                guard prepared.composer.focused else { throw DesktopAppError.unavailable("ChatGPT’s composer lost focus. Review the preserved draft; nothing was retried.") }
                try await action("press_key", control: prepared.composer, key: "return", target: target, session: session, expected: prepared, verifyImage: true, modifiers: ["shift"], focusedInput: true)
                prefix += "\n"
                prepared = try await checkedDraft(prefix, previous: prepared, target: target)
            }
            var remaining = line[...]
            while !remaining.isEmpty {
                let end = remaining.index(remaining.startIndex, offsetBy: 256, limitedBy: remaining.endIndex) ?? remaining.endIndex
                let chunk = String(remaining[..<end])
                remaining = remaining[end...]
                let first = prefix.isEmpty
                try await action("type_text", control: prepared.composer, text: chunk, target: target, session: session, expected: prepared, pixel: first, verifyImage: !first, focusedInput: !first)
                prefix += chunk
                prepared = try await checkedDraft(prefix, previous: prepared, target: target)
            }
        }
        let typed = try await read(target)
        guard typed.kind == native.kind, typed.title == native.title, typed.messages == baseline, typed.draft == prompt else { throw DesktopAppError.unavailable("ChatGPT’s prepared prompt changed. It was not submitted or retried.") }
        try await action(control: typed.control(label: "Send"), target: target, session: session, expected: typed)
        let deadline = ContinuousClock.now.advanced(by: timing.replyTimeout)
        var stable: String?, since = ContinuousClock.now
        while ContinuousClock.now < deadline {
            do { native = try await read(target) }
            catch is ChatGPTObservationError { stable = nil; try await Task.sleep(for: timing.pollInterval); continue }
            guard native.kind == binding.kind, (pending.title == nil || native.title == openedTitle), native.draft.isEmpty || native.draft == prompt,
                  native.messages.count >= baseline.count else { throw DesktopAppError.unavailable("ChatGPT’s conversation changed. No reply was attributed.") }
            let appended = try native.appendedMessages(after: baseline)
            if !appended.isEmpty {
                let outgoing = appended[0]
                if outgoing != .init(role: .user, text: prompt) {
                    guard outgoing.role == .user, !outgoing.text.isEmpty,
                          prompt.hasPrefix(outgoing.text) || outgoing.text.hasPrefix(prompt) else { throw DesktopAppError.unavailable("ChatGPT’s outgoing message did not match this request.") }
                    // While rendering, Electron can expose only part of our
                    // prompt or append its Thinking status to the same bubble.
                    // Neither form can authorize a reply until the exact prompt appears.
                    stable = nil
                    try await Task.sleep(for: timing.pollInterval)
                    continue
                }
            }
            if appended.count == 2, let answer = appended.last, answer.role == .assistant, !native.generating, native.draft.isEmpty {
                if stable != answer.text { stable = answer.text; since = .now }
                if ContinuousClock.now - since >= timing.stableDuration {
                    var saved = pending
                    if binding.kind == .chatgpt, binding.title == nil {
                        guard !native.title.isEmpty else { throw DesktopAppError.unavailable("ChatGPT’s completed conversation title could not be read. Its reply was preserved in the native app.") }
                        saved.title = binding.dedicatedTitle
                        saved.fallbackTitle = native.title
                        // Persist the verified chat before optional title cleanup.
                        // Its exact nonce remains the ownership proof on reopen.
                        try await onBinding(saved)
                        do { try await rename(binding.dedicatedTitle, expected: native, target: target, session: session) }
                        catch {
                            try Task.checkCancellation()
                            if error is CancellationError { throw error }
                            return answer.text
                        }
                    } else { try await onBinding(saved) }
                    return answer.text
                }
            } else { stable = nil }
            try await Task.sleep(for: timing.pollInterval)
        }
        throw DesktopAppError.unavailable("ChatGPT has not completed its reply. Review the native conversation; nothing will be resent automatically.")
    }
}
