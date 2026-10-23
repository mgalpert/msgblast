import Foundation

actor MuseAppConversation {
    static let shared = MuseAppConversation()
    typealias NativeRead = @Sendable (DesktopAppConversation.Target) throws -> MuseAppObservation
    private let driver: DesktopAppConversation
    private let readNative: NativeRead
    private let timing: DesktopAppConversation.Timing
    private var occupied = false
    private struct NewChat: Sendable {
        let comparison: UUID
        let target: DesktopAppConversation.Target
        let composer: UInt?
        func matches(_ comparison: UUID, _ target: DesktopAppConversation.Target, _ state: MuseAppObservation) -> Bool {
            self.comparison == comparison && self.target == target && composer == state.composerIdentity
        }
    }
    private var preparedNew: NewChat?

    init(executable: URL? = nil, timing: DesktopAppConversation.Timing = .init(), readNative: @escaping NativeRead = MuseNativeReader.capture) {
        driver = DesktopAppConversation(executable: executable, timing: timing)
        self.timing = timing; self.readNative = readNative
    }
    private func observe(_ target: DesktopAppConversation.Target) async throws -> MuseAppObservation {
        try Task.checkCancellation()
        let read = readNative
        do { return try await Task.detached { try read(target) }.value }
        catch {
            // Muse briefly replaces its AX window during side-chat navigation.
            // Only a read is repeated; no input action is replayed.
            try Task.checkCancellation()
            try await Task.sleep(for: timing.pollInterval)
            return try await Task.detached { try read(target) }.value
        }
    }
    private func empty(_ state: MuseAppObservation) throws {
        guard state.draft.isEmpty, !state.generating else {
            throw DesktopAppError.unavailable("Muse has an unsent draft or an active response. It was preserved; finish it in Muse before continuing.")
        }
    }
    private func click(_ element: DesktopAppSnapshot.Element, target: DesktopAppConversation.Target, session: String) async throws {
        try empty(await observe(target))
        guard let token = element.element_token, element.enabled != false else { throw DesktopAppError.unavailable("Muse's navigation control is unavailable.") }
        _ = try await driver.call("click", ["element_token": token, "session": session, "delivery_mode": "background"], numbers: ["pid": target.pid, "window_id": target.window], as: DesktopAppConversation.Action.self)
    }
    private func snapshot(_ target: DesktopAppConversation.Target, session: String) async throws -> DesktopAppSnapshot {
        let state = try await driver.snapshot(target, session: session)
        try state.checkReadable()
        return state
    }
    private func pixelClick(_ target: DesktopAppConversation.Target, session: String, expectedURL: URL? = nil, focusOnly: Bool = false,
                            select: (DesktopAppSnapshot) throws -> DesktopAppSnapshot.Element?) async throws -> Bool {
        let before = try await observe(target)
        try empty(before)
        guard expectedURL == nil || before.url == expectedURL else { throw DesktopAppError.unavailable("Muse changed chats before navigation. Nothing was clicked.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-muse-capture-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("window.png")
        let fresh = try await driver.snapshot(target, session: session, screenshotURL: image)
        try fresh.checkReadable()
        guard let element = try select(fresh) else { return false }
        let point = try fresh.pixelCenter(of: element, target: target, imageURL: image)
        guard let capture = fresh.capture_id, !capture.isEmpty else {
            throw DesktopAppError.unavailable("Muse's current screenshot geometry could not be verified. Nothing was clicked.")
        }
        let after = try await observe(target)
        try empty(after)
        guard after.url == before.url, after.windowBounds != nil, after.windowBounds == fresh.window_bounds else {
            throw DesktopAppError.unavailable("Muse's chat or window geometry changed while its screenshot was captured. Nothing was clicked.")
        }
        // Bind screenshot pixels to this capture's scale, origin, and exact
        // window. An unbound click can miss a resized Retina capture's field.
        _ = try await driver.call("click", ["session": session, "delivery_mode": "background", "capture_id": capture, "action": focusOnly ? "focus" : "press"], numbers: ["pid": target.pid, "window_id": target.window, "x": point.x, "y": point.y], as: DesktopAppConversation.Action.self)
        return true
    }
    private func focusComposer(_ target: DesktopAppConversation.Target, session: String, at url: URL) async throws -> MuseAppObservation {
        let current = try await observe(target)
        try empty(current)
        guard current.url == url else { throw DesktopAppError.unavailable("Muse changed side chats before focusing its composer.") }
        if current.composerFocused, !current.sidebarOpen { return current }
        // Cua 0.38's pixel focus action sets AXFocused without AXPress or
        // pointer events. The compound button's press opens its attachment UI.
        _ = try await pixelClick(target, session: session, expectedURL: url, focusOnly: true) { state in
            let matches = state.body.filter {
                (["AXTextArea", "AXTextField"].contains($0.role) && $0.label == "Message") ||
                ($0.role == "AXButton" && $0.label == "Message Attach file Dictate a message Send")
            }
            guard matches.count == 1 else { throw DesktopAppError.unavailable("Muse's composer geometry is ambiguous.") }
            return matches[0]
        }
        return try await settled(target) { $0.url == url && $0.composerFocused && !$0.sidebarOpen }
    }
    private func sidebar(_ target: DesktopAppConversation.Target, session: String) async throws -> DesktopAppSnapshot {
        var state = try await snapshot(target, session: session)
        if state.body.contains(where: { $0.role == "AXButton" && $0.label == "New side chat" }) { return state }
        let open = state.body.filter { $0.role == "AXButton" && ($0.label ?? "").contains("Open chat and side chats") }
        if open.count == 1 { try await click(open[0], target: target, session: session) }
        else {
            let back = state.body.filter { $0.role == "AXButton" && $0.label == "Back to main chat" }
            guard back.count == 1 else { throw DesktopAppError.unavailable("Muse's side-chat navigation is unavailable.") }
            try await click(back[0], target: target, session: session)
            state = try await snapshot(target, session: session)
            let headers = state.body.filter { $0.role == "AXButton" && ($0.label ?? "").contains("Open chat and side chats") }
            guard headers.count == 1 else { throw DesktopAppError.unavailable("Muse's chat list could not be opened.") }
            try await click(headers[0], target: target, session: session)
        }
        state = try await snapshot(target, session: session)
        guard state.body.contains(where: { $0.role == "AXButton" && $0.label == "New side chat" }) else {
            throw DesktopAppError.unavailable("Muse did not open its side-chat list.")
        }
        return state
    }
    private func candidates(_ state: DesktopAppSnapshot) throws -> [DesktopAppSnapshot.Element] {
        let body = Array(state.body)
        guard let start = body.firstIndex(where: { $0.role == "AXButton" && $0.label == "New side chat" }),
              let end = body.dropFirst(start + 1).firstIndex(where: { $0.role == "AXSplitter" && $0.label == "Resize panel" }) else {
            throw DesktopAppError.unavailable("Muse's side-chat list is incomplete. Open the saved side chat in Muse before continuing.")
        }
        return body[(start + 1)..<end].filter { $0.role == "AXButton" && $0.element_token != nil && !($0.label ?? "").isEmpty }
    }
    private func settled(_ target: DesktopAppConversation.Target, expected: (MuseAppObservation) -> Bool) async throws -> MuseAppObservation {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while true {
            try await Task.sleep(for: timing.pollInterval)
            let state = try await observe(target)
            try empty(state)
            if expected(state) { return state }
            guard ContinuousClock.now < deadline else { throw DesktopAppError.unavailable("Muse did not open the expected side chat. Nothing was sent.") }
        }
    }

    func checkAvailable() async throws {
        guard !occupied else { throw DesktopAppError.unavailable("Muse is already handling a request.") }
        let session = "msgblast-muse-check-\(UUID())"
        defer { Task { await driver.endSession(session) } }
        let target = try await driver.target(.muse)
        // Let the driver initialize the exact window's accessibility surface
        // before the independent native identity and draft read.
        _ = try await snapshot(target, session: session)
        try empty(await observe(target))
    }

    static func firstPrompt(_ prompt: String, requestID: UUID) -> String {
        "[msgblast request \(requestID.uuidString.lowercased())]\n\n" + prompt
    }

    func recover(comparisonID: UUID, candidateURL: URL, prompt: String, requestID: UUID) async throws -> MuseSideChatBinding {
        guard let id = MuseSideChatBinding.threadID(in: candidateURL) else {
            throw DesktopAppError.unavailable("Muse's pending side-chat address is invalid. No replacement was created.")
        }
        return try await prepare(comparisonID: comparisonID, binding: .init(comparisonID: comparisonID, threadID: id, title: "Muse side chat"),
                                 recoveringPrompt: Self.firstPrompt(prompt, requestID: requestID))
    }

    func prepare(comparisonID: UUID, binding: MuseSideChatBinding?) async throws -> MuseSideChatBinding {
        try await prepare(comparisonID: comparisonID, binding: binding, recoveringPrompt: nil)
    }

    private func prepare(comparisonID: UUID, binding: MuseSideChatBinding?, recoveringPrompt: String?) async throws -> MuseSideChatBinding {
        guard !occupied else { throw DesktopAppError.unavailable("Muse is already handling a request.") }
        occupied = true
        defer { occupied = false }
        guard binding == nil || binding?.comparisonID == comparisonID else { throw DesktopAppError.unavailable("This Muse side chat belongs to a different comparison.") }
        let session = "msgblast-muse-prepare-\(UUID())"
        defer { Task { await driver.endSession(session) } }
        let target = try await driver.target(.muse)
        let current = try await observe(target)
        try empty(current)
        func verifyRecovery(_ state: MuseAppObservation) throws {
            guard let recoveringPrompt else { return }
            _ = try MuseAppReceipt(baseline: [], prompt: recoveringPrompt).reply(in: state.messages)
            guard !state.messages.isEmpty else {
                throw DesktopAppError.unavailable("Muse's pending chat has no matching request reference yet. It was preserved; no replacement was created.")
            }
        }
        if let id = binding?.threadID {
            if MuseSideChatBinding.threadID(in: current.url) == id {
                try verifyRecovery(current)
                let focused = try await focusComposer(target, session: session, at: current.url)
                return MuseSideChatBinding(comparisonID: comparisonID, threadID: id, title: focused.title)
            }
            for pass in 0..<2 {
                var index = 0
                while index < 100 {
                    _ = try await sidebar(target, session: session)
                    // Muse exposes sidebar rows as buttons, but their AXPress
                    // action is a no-op. Use fresh capture geometry for rows.
                    let clicked = try await pixelClick(target, session: session) { fresh in
                        let rows = try candidates(fresh)
                        guard index < rows.count else { return nil }
                        let hinted = pass == 0 && index == 0 ? rows.firstIndex(where: { $0.label == binding?.title }) : nil
                        return rows[hinted ?? index]
                    }
                    guard clicked else { break }
                    let selected = try await settled(target) { MuseSideChatBinding.threadID(in: $0.url) != nil && !$0.sidebarOpen }
                    if MuseSideChatBinding.threadID(in: selected.url) == id {
                        try verifyRecovery(selected)
                        let focused = try await focusComposer(target, session: session, at: selected.url)
                        return MuseSideChatBinding(comparisonID: comparisonID, threadID: id, title: focused.title)
                    }
                    index += 1
                }
                if index == 0 { break }
            }
            throw DesktopAppError.unavailable("The saved Muse side chat was not found in its accessible list. Open it in Muse and try again; no replacement chat was created.")
        }
        if preparedNew?.matches(comparisonID, target, current) == true, current.url == MuseSideChatBinding.newURL, current.messages.isEmpty, current.composerFocused {
            return MuseSideChatBinding(comparisonID: comparisonID, threadID: nil, title: "New side chat")
        }
        let list = try await sidebar(target, session: session)
        let buttons = list.body.filter { $0.role == "AXButton" && $0.label == "New side chat" }
        guard buttons.count == 1 else { throw DesktopAppError.unavailable("Muse's New side chat control is ambiguous.") }
        preparedNew = nil
        try await click(buttons[0], target: target, session: session)
        let created = try await settled(target) { $0.url == MuseSideChatBinding.newURL && $0.messages.isEmpty }
        let focused = try await focusComposer(target, session: session, at: created.url)
        preparedNew = NewChat(comparison: comparisonID, target: target, composer: focused.composerIdentity)
        return MuseSideChatBinding(comparisonID: comparisonID, threadID: nil, title: focused.title)
    }

    func reply(_ prompt: String, binding: MuseSideChatBinding, requestID: UUID = UUID(),
               onCandidate: @Sendable (URL) async throws -> Void = { _ in },
               onBinding: @Sendable (MuseSideChatBinding) async throws -> Void) async throws -> String {
        guard !occupied else { throw DesktopAppError.unavailable("Muse is already handling a request.") }
        occupied = true
        defer { occupied = false }
        let wirePrompt = binding.threadID == nil ? Self.firstPrompt(prompt, requestID: requestID) : prompt
        guard !prompt.isEmpty, wirePrompt.utf16.count <= 200_000,
              !prompt.unicodeScalars.contains(where: { ($0.value < 0x20 && $0.value != 0x0a) || $0.value == 0x7f }) else { throw DesktopAppError.unavailable("Muse's message is empty, contains unsupported control characters, or exceeds the safe draft limit.") }
        let session = "msgblast-muse-send-\(UUID())"
        defer { Task { await driver.endSession(session) } }
        let target = try await driver.target(.muse)
        let before = try await observe(target)
        try empty(before)
        func sameChat(_ state: MuseAppObservation, id: UUID?) throws {
            let matches = id.map { MuseSideChatBinding.threadID(in: state.url) == $0 } ??
                (preparedNew?.matches(binding.comparisonID, target, state) == true && state.url == MuseSideChatBinding.newURL && state.messages.isEmpty)
            guard matches else { throw DesktopAppError.unavailable("Muse's selected side chat changed. Nothing will be retried automatically.") }
        }
        try sameChat(before, id: binding.threadID)
        guard before.composerFocused else { throw DesktopAppError.unavailable("Muse's composer lost focus. Reopen the comparison before sending.") }
        let receipt = MuseAppReceipt(baseline: before.messages, prompt: wirePrompt)
        var prefix = ""
        // Small, disjoint chunks keep synthesized input within the driver's
        // transport budget. Each chunk must be read back before the next one.
        enum Input { case text(String), newline }
        var inputs: [Input] = []
        let lines = wirePrompt.split(separator: "\n", omittingEmptySubsequences: false)
        for (lineIndex, line) in lines.enumerated() {
            let characters = Array(line)
            for offset in stride(from: 0, to: characters.count, by: 256) {
                inputs.append(.text(String(characters[offset..<min(offset + 256, characters.count)])))
            }
            if lineIndex < lines.count - 1 { inputs.append(.newline) }
        }
        func matchesPreparedDraft(_ draft: String) -> Bool {
            // WebKit exposes an extra terminal line break while a new empty
            // line is being edited. This tolerance is only for intermediate
            // chunks; the final draft must match the entire prompt exactly.
            draft == prefix || (prefix.hasSuffix("\n") && draft == prefix + "\n")
        }
        for input in inputs {
            let check = try await observe(target)
            try sameChat(check, id: binding.threadID)
            guard matchesPreparedDraft(check.draft), check.composerFocused, !check.generating, check.messages == before.messages else {
                throw DesktopAppError.unavailable("Muse's draft or focus changed before typing. Review the preserved draft.")
            }
            switch input {
            case .text(let chunk):
                // Do not AX-press the compound button: that opens its file picker.
                _ = try await driver.call("type_text", ["text": chunk, "delivery_mode": "background", "session": session], numbers: ["pid": target.pid, "window_id": target.window, "delay_ms": 0], as: DesktopAppConversation.Action.self)
                prefix += chunk
            case .newline:
                // Plain newline character events submit Muse's composer.
                _ = try await driver.call("press_key", ["key": "return", "delivery_mode": "background", "session": session], numbers: ["pid": target.pid, "window_id": target.window], arrays: ["modifiers": ["shift"]], as: DesktopAppConversation.Action.self)
                prefix += "\n"
            }
            let typed = try await observe(target)
            try sameChat(typed, id: binding.threadID)
            guard matchesPreparedDraft(typed.draft), typed.composerFocused, !typed.generating, typed.messages == before.messages else {
                throw DesktopAppError.unavailable("Muse did not confirm the exact prepared draft. Send was not pressed; review the preserved text.")
            }
        }
        let ready = try await observe(target)
        try sameChat(ready, id: binding.threadID)
        guard ready.draft == wirePrompt, ready.composerFocused, !ready.generating, ready.messages == before.messages else { throw DesktopAppError.unavailable("Muse's prepared draft changed before Send.") }
        _ = try await driver.call("press_key", ["key": "return", "delivery_mode": "background", "session": session], numbers: ["pid": target.pid, "window_id": target.window], as: DesktopAppConversation.Action.self)
        var knownID = binding.threadID
        var provisionalID: UUID?
        var savedTitle: String?
        let deadline = ContinuousClock.now.advanced(by: timing.replyTimeout)
        var previous: String?, stableSince = ContinuousClock.now
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: timing.pollInterval)
            let state = try await observe(target)
            if let id = knownID {
                guard MuseSideChatBinding.threadID(in: state.url) == id else { throw DesktopAppError.unavailable("Muse switched side chats while waiting. Review the saved chat; no automatic resend.") }
            } else if let id = MuseSideChatBinding.threadID(in: state.url) {
                guard provisionalID == nil || provisionalID == id else { throw DesktopAppError.unavailable("Muse's new side chat changed before its outgoing message was confirmed.") }
                if provisionalID == nil {
                    try await onCandidate(state.url)
                    provisionalID = id
                }
            } else if state.url != MuseSideChatBinding.newURL || provisionalID != nil {
                throw DesktopAppError.unavailable("Muse's new side-chat identity could not be confirmed.")
            }
            let observedReply = try receipt.reply(in: state.messages)
            let outgoing = state.messages.count > receipt.baseline.count
            // An untracked chat can only become owned after its fresh request
            // reference is echoed as the first outgoing message.
            if knownID == nil, outgoing, let provisionalID { knownID = provisionalID; preparedNew = nil }
            if let id = knownID, outgoing, savedTitle != state.title {
                try await onBinding(MuseSideChatBinding(comparisonID: binding.comparisonID, threadID: id, title: state.title))
                savedTitle = state.title
            }
            let candidate = state.draft.isEmpty && knownID != nil ? observedReply : nil
            if candidate != previous || state.generating { previous = candidate; stableSince = .now }
            if let candidate, !state.generating, ContinuousClock.now - stableSince >= timing.stableDuration { return candidate }
        }
        throw DesktopAppError.unavailable("No stable Muse reply was observed. Check the saved side chat before explicitly allowing another request.")
    }
}
