import AppKit
@testable import msgblastCore

// In-memory wire; lifecycle checks use the actual session/controller/audio classes.
@MainActor private final class VoiceUXTransport: GPTLiveTransport {
    var types: [String] = []
    private var incoming: [String] = []
    private var receiver: CheckedContinuation<String, Error>?
    private var cancelled = false
    func start(request: URLRequest) { }
    func send(_ text: String) async throws {
        let event = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        types.append(event["type"] as! String)
    }
    func receive() async throws -> String {
        if !incoming.isEmpty { return incoming.removeFirst() }
        if cancelled { throw CancellationError() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func push(_ type: String) {
        let text = "{\"type\":\"" + type + "\"}"
        if let receiver { self.receiver = nil; receiver.resume(returning: text) }
        else { incoming.append(text) }
    }
    func cancel() {
        cancelled = true
        receiver?.resume(throwing: CancellationError()); receiver = nil
    }
}

@main struct GPTLiveControllerChecks {
    @MainActor static var callSequence = 0

    @MainActor static func call(_ controller: GPTLiveController, _ name: String, _ arguments: [String: Any] = [:], fails: Bool = false) async throws -> [String: Any] {
        callSequence += 1
        let callID = "app-fixture-\(callSequence)"
        let result = await controller.session.onToolCall!(.init(callID: callID, name: name, arguments: GPTLiveController.json(arguments)))
        let value = try JSONSerialization.jsonObject(with: Data(result.utf8)) as! [String: Any]
        precondition((value["error"] != nil) == fails, "\(name) unexpected result: \(result)")
        let audited = controller.activity.entries.filter { $0.callID == callID }
        precondition(audited.contains { $0.category == "tool" && $0.detail != nil }, "Enabled debug must record tool arguments")
        precondition(audited.contains { $0.category == "tool_result" && $0.detail != nil }, "Debug results must retain their call ID")
        return value
    }
    static func editArguments(_ state: [String: Any], text: String) -> [String: Any] {
        ["workspace_conversation_id": state["active_workspace_conversation_id"]!,
         "expected_revision": state["workspace_draft_revision"]!, "expected_text": state["workspace_draft_text"]!, "text": text]
    }
    @MainActor static func waitUntil(_ message: String, _ predicate: () -> Bool) async throws {
        for _ in 0..<200 { if predicate() { return }; try await Task.sleep(for: .milliseconds(100)) }
        preconditionFailure(message)
    }
    @MainActor static func outgoingCount(_ model: AppModel) -> Int { model.messages.values.flatMap { $0 }.filter(\.outgoing).count }

    @MainActor static func main() {
        precondition(ProcessInfo.processInfo.arguments.contains("--demo") && ProcessInfo.processInfo.arguments.contains("--isolated-demo"), "Only isolated simulated transports are permitted")
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            do { try await checks() } catch { fatalError("GPT-Live app-wide fixture failed: \(error)") }
            app.stop(nil)
            app.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: true)
        }
        app.run()
    }

    @MainActor static func voiceLifecycleChecks(_ model: AppModel) async throws {
        // Cancel while connecting: the pending connection must not open a mic.
        let waitingWire = VoiceUXTransport()
        let waitingSession = GPTLiveSession(transportFactory: { waitingWire })
        var permissionRequests = 0
        let waitingAudio = GPTLiveAudio(requestPermission: { permissionRequests += 1; return false })
        let waiting = GPTLiveController(model: model, session: waitingSession, audio: waitingAudio)
        waiting.simulate = false; waiting.apiKey = "sk-fixture-only"; waiting.rememberKey = false
        let connection = Task { await waiting.startVoice() }
        try await waitUntil("Expected connecting state") { waitingWire.types.contains("session.start") }
        await waiting.disconnect()
        await connection.value
        precondition(permissionRequests == 0 && !waiting.startingVoice && !waiting.microphone)

        // Cancel while the real audio class awaits an injected permission answer.
        let permissionWire = VoiceUXTransport()
        let permissionSession = GPTLiveSession(transportFactory: { permissionWire })
        var permission: CheckedContinuation<Bool, Never>?
        let permissionAudio = GPTLiveAudio(requestPermission: { await withCheckedContinuation { permission = $0 } })
        let pending = GPTLiveController(model: model, session: permissionSession, audio: permissionAudio)
        pending.simulate = false; pending.apiKey = "sk-fixture-only"; pending.rememberKey = false
        let starting = Task { await pending.startVoice() }
        try await waitUntil("Expected pending session") { permissionWire.types.contains("session.start") }
        permissionWire.push("session.started")
        try await waitUntil("Expected permission request") { permission != nil }
        let closing = Task { await pending.disconnect() }
        try await waitUntil("Expected close") { permissionWire.types.contains("session.close") }
        permissionWire.push("session.closed")
        await closing.value
        permission?.resume(returning: true)
        await starting.value
        precondition(!pending.audio.isCapturing && !pending.microphone && !pending.microphoneStarting && !pending.startingVoice,
                     "Late permission approval must not restart a closed session")

        // Reopening during close waits, then starts exactly one new session.
        let first = VoiceUXTransport(), second = VoiceUXTransport()
        var starts = 0
        let restartingSession = GPTLiveSession(transportFactory: { starts += 1; return starts == 1 ? first : second })
        let restarting = GPTLiveController(model: model, session: restartingSession,
                                          audio: GPTLiveAudio(requestPermission: { false }))
        restarting.simulate = false; restarting.apiKey = "sk-fixture-only"; restarting.rememberKey = false
        let initial = Task { await restarting.startVoice() }
        try await waitUntil("Expected initial voice start") { first.types.contains("session.start") }
        first.push("session.started")
        await initial.value
        let ending = Task { await restarting.disconnect() }
        try await waitUntil("Expected old session to close") { first.types.contains("session.close") }
        restarting.beginVoice()
        first.push("session.closed")
        await ending.value
        try await waitUntil("Toolbar reopen must start the next session") { second.types.contains("session.start") }
        second.push("session.started")
        try await waitUntil("Expected resumed voice attempt to finish") { !restarting.startingVoice }
        precondition(starts == 2 && restarting.connected && !restarting.microphone)
        let finalClose = Task { await restarting.disconnect() }
        try await waitUntil("Expected final close") { second.types.contains("session.close") }
        second.push("session.closed")
        await finalClose.value
        print("PASS: one-action voice cancellation during connection and permission, late approval rejection, and automatic restart after close. No OS prompt or audio device opened.")
    }

    @MainActor static func checks() async throws {
        let model = AppModel()
        precondition(model.demo && model.webAgents.fixture)
        model.timer?.invalidate()
        let directory = model.local.url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await voiceLifecycleChecks(model)
        let controller = GPTLiveController(model: model)
        precondition(!controller.activity.enabled, "Debug details must be optional and off by default")
        controller.simulate = false
        controller.apiKey = ""
        controller.beginVoice()
        precondition(controller.showSettings && controller.voiceNeedsKey && !controller.active && !controller.audio.isCapturing,
                     "Opening voice without a key must show setup without opening the microphone")
        controller.simulate = true
        controller.activity.enabled = true
        await controller.startVoice()
        precondition(!controller.startingVoice && !controller.microphoneStarting && !controller.audio.isCapturing,
                     "The one-action voice entry must keep Demo audio simulated")
        precondition(controller.fixtureConnected && controller.session.state == .idle, "The API must remain disconnected")
        let agents = model.state.agents
        precondition(agents.count >= 4)
        let targets = agents.map { "messages:" + $0.id.uuidString }
        let attachment = try model.local.stage(Data("An unsent fixture attachment".utf8), filename: "private-note.txt")
        let originalDraft = "Keep this unsent main composer draft"
        model.setSharedDraft(originalDraft)
        model.state.attachmentsDraft = [attachment]
        try model.save()
        let beforeTools = outgoingCount(model)
        let conversationCount = model.state.comparisons.count

        precondition(Set(GPTLiveController.tools.compactMap { $0["name"] as? String }).count == GPTLiveController.tools.count)
        for tool in GPTLiveController.tools {
            let parameters = tool["parameters"] as! [String: Any]
            let properties = parameters["properties"] as! [String: Any]
            precondition(tool["strict"] as? Bool == true && parameters["additionalProperties"] as? Bool == false)
            precondition(Set(parameters["required"] as! [String]) == Set(properties.keys))
        }
        let state = try await call(controller, "get_app_state")
        precondition(state["scope"] as? String == "app_wide")
        let catalog = try await call(controller, "list_agents")
        precondition((catalog["agents"] as! [[String: Any]]).contains { $0["id"] as? String == targets[0] })
        _ = try await call(controller, "get_app_state", ["unexpected": true], fails: true)
        _ = try await call(controller, "send_message", ["text": "Must never send"], fails: true)
        _ = try await call(controller, "list_conversations", ["query": "", "include_ended": true, "offset": true, "limit": 20], fails: true)
        _ = try await call(controller, "list_conversations", ["query": "", "include_ended": 1, "offset": 0, "limit": 20], fails: true)
        _ = try await call(controller, "list_conversations", ["query": "", "include_ended": true, "offset": 0, "limit": 51], fails: true)
        _ = try await call(controller, "prepare_message", ["recipient_ids": [targets[0]], "text": "Missing destination"], fails: true)
        _ = try await call(controller, "prepare_message", ["conversation_id": NSNull(), "recipient_ids": [targets[0], targets[0]], "text": "Duplicate recipients"], fails: true)
        for destination in ["discover", "settings", "agents"] {
            _ = try await call(controller, "navigate_app", ["destination": destination, "conversation_id": NSNull()])
            precondition(model.gptLiveNavigationRequest?.destination.rawValue == destination)
        }
        _ = try await call(controller, "navigate_app", ["destination": "new_conversation", "conversation_id": NSNull()])
        _ = try await call(controller, "select_agents", ["recipient_ids": Array(targets.prefix(2))])
        precondition(model.state.selection == Set(agents.prefix(2).map(\.id)))
        _ = try await call(controller, "select_agents", ["recipient_ids": ["messages:" + UUID().uuidString]], fails: true)
        let appChat = model.webAgents.session(for: WebAgentID(provider: .chatgptApp))!
        let appDots = model.webAgents.session(for: WebAgentID(provider: .dotsApp))!
        appChat.updateState { $0.enabled = true }; appDots.updateState { $0.enabled = true }
        let selectedBeforeConflict = model.webAgents.sessions.filter { $0.state.selected }.map(\.id)
        _ = try await call(controller, "select_agents", ["recipient_ids": ["agent:" + appChat.id.id, "agent:" + appDots.id.id]], fails: true)
        precondition(model.state.selection == Set(agents.prefix(2).map(\.id)) && model.webAgents.sessions.filter { $0.state.selected }.map(\.id) == selectedBeforeConflict)
        appChat.updateState { $0.enabled = false }; appDots.updateState { $0.enabled = false }
        var stale = editArguments(try await call(controller, "get_app_state"), text: "Must not overwrite")
        stale["expected_text"] = "Stale text"
        _ = try await call(controller, "set_workspace_draft", stale, fails: true)
        precondition(model.state.draft == originalDraft)
        _ = try await call(controller, "set_workspace_draft", editArguments(try await call(controller, "get_app_state"), text: "Edited workspace draft"))
        precondition(model.state.draft == "Edited workspace draft" && model.state.attachmentsDraft == [attachment])
        _ = try await call(controller, "set_workspace_draft", editArguments(try await call(controller, "get_app_state"), text: originalDraft))
        precondition(model.state.comparisons.count == conversationCount && outgoingCount(model) == beforeTools, "Navigation, selection and composer tools must never submit")

        _ = try await call(controller, "prepare_message", ["conversation_id": NSNull(), "recipient_ids": Array(targets.prefix(2)), "text": "Compare a small pilot with a larger trial."])
        let prepared = controller.pendingDraft!
        precondition(prepared.comparisonID == nil && prepared.revision == 0)
        _ = try await call(controller, "prepare_message", ["conversation_id": NSNull(), "recipient_ids": [targets[2]], "text": "Must not replace"], fails: true)
        precondition(controller.pendingDraft == prepared)
        _ = try await call(controller, "update_prepared_message", ["draft_id": prepared.id.uuidString, "expected_revision": 0, "text": "Tool revision"])
        controller.editDraft("Human revision")
        _ = try await call(controller, "update_prepared_message", ["draft_id": prepared.id.uuidString, "expected_revision": 1, "text": "Stale overwrite"], fails: true)
        _ = try await call(controller, "discard_prepared_message", ["draft_id": prepared.id.uuidString, "expected_revision": 1], fails: true)
        precondition(controller.pendingDraft?.text == "Human revision" && controller.pendingDraft?.revision == 2)
        let initialText = "Compare a five-person pilot with a larger trial."
        _ = try await call(controller, "update_prepared_message", ["draft_id": prepared.id.uuidString, "expected_revision": 2, "text": initialText])
        precondition(outgoingCount(model) == beforeTools && model.state.comparisons.count == conversationCount, "Preparation and revisions must not create conversations or send")
        await controller.sendDraft()
        guard let firstID = controller.selectedComparisonID, let first = model.comparison(firstID) else { fatalError(controller.status) }
        precondition(controller.pendingDraft == nil && first.prompt == initialText && first.members.count == 2, controller.status)
        precondition(first.members.allSatisfy { $0.submission == .submitted && $0.anchor != nil && $0.payload == nil })
        precondition(outgoingCount(model) == beforeTools + 2 && model.state.draft == originalDraft && model.state.attachmentsDraft == [attachment])
        precondition(FileManager.default.fileExists(atPath: attachment.path))
        await controller.sendDraft()
        precondition(outgoingCount(model) == beforeTools + 2 && model.state.comparisons.count == conversationCount + 1, "A repeated click must not duplicate a send")
        precondition(controller.activity.entries.contains { $0.category == "approval" } && controller.activity.entries.contains { $0.category == "receipt" })
        print("PASS: audited app tools, strict schemas, navigation/selection, conflicting-app guard, optimistic revisions, explicit multi-recipient new send, duplicate-click protection and main draft/attachment preservation.")

        let followUpText = "What evidence would make the pilot successful?"
        _ = try await call(controller, "prepare_message", ["conversation_id": firstID.uuidString, "recipient_ids": Array(targets.prefix(2)), "text": followUpText])
        let firstIndex = model.index(firstID)!
        model.state.comparisons[firstIndex].allDraft = "Existing shared draft"
        model.state.comparisons[firstIndex].allAttachmentsDraft = [attachment]
        await controller.sendDraft()
        precondition(model.comparison(firstID)!.followUps.isEmpty && controller.pendingDraft != nil)
        precondition(model.comparison(firstID)!.allDraft == "Existing shared draft" && model.comparison(firstID)!.allAttachmentsDraft == [attachment])
        model.state.comparisons[firstIndex].allDraft = ""
        model.state.comparisons[firstIndex].allAttachmentsDraft = nil
        model.state.comparisons[firstIndex].privateDrafts[agents[0].id.uuidString] = "Existing private draft"
        model.state.comparisons[firstIndex].privateAttachmentDrafts = [agents[0].id.uuidString: [attachment]]
        await controller.sendDraft()
        precondition(model.comparison(firstID)!.followUps.isEmpty && controller.pendingDraft != nil)
        precondition(model.comparison(firstID)!.privateDrafts[agents[0].id.uuidString] == "Existing private draft" && model.attachmentDraft(comparisonID: firstID, memberID: agents[0].id) == [attachment])
        model.state.comparisons[firstIndex].privateDrafts[agents[0].id.uuidString] = ""
        model.state.comparisons[firstIndex].privateAttachmentDrafts = nil
        await controller.sendDraft()
        precondition(controller.pendingDraft == nil, controller.status)
        let followUp = model.comparison(firstID)!.followUps.last!
        precondition(followUp.text == followUpText && Set(followUp.memberIDs) == Set(agents.prefix(2).map(\.id)))
        precondition(followUp.states.values.allSatisfy { $0 == .submitted } && followUp.sharedWithAll == true)
        precondition(model.state.draft == originalDraft && model.state.attachmentsDraft == [attachment])
        await controller.sendDraft()
        precondition(model.comparison(firstID)!.followUps.count == 1)
        let nonmember = await model.submitGPTLiveMessage(text: "Must reject a nonmember", comparisonID: firstID, recipientIDs: [targets[2]])
        precondition(!nonmember.attempted && model.comparison(firstID)!.members.count == 2)
        _ = try await call(controller, "prepare_message", ["conversation_id": firstID.uuidString, "recipient_ids": [targets[2]], "text": "Must reject a nonmember"], fails: true)
        let missing = await model.submitGPTLiveMessage(text: "Must reject an unavailable target", comparisonID: nil, recipientIDs: ["agent:missing-provider"])
        precondition(!missing.attempted)
        let second = await model.submitGPTLiveMessage(text: "An independent research question", comparisonID: nil, recipientIDs: [targets[2]])
        guard second.attempted, let secondID = second.comparisonID else { fatalError(second.summary) }
        controller.selectedComparisonID = UUID()
        for id in [firstID, secondID] {
            let history = try await call(controller, "read_conversation", ["conversation_id": id.uuidString, "recipient_id": "all"])
            precondition(history["comparisonID"] as? String == id.uuidString && history["attachmentContentsIncluded"] as? Bool == false)
        }
        let page = try await call(controller, "list_conversations", ["query": "", "include_ended": true, "offset": 0, "limit": 1])
        precondition((page["conversations"] as! [[String: Any]]).count == 1 && page["next_offset"] as? Int == 1)
        _ = try await call(controller, "read_conversation", ["conversation_id": UUID().uuidString, "recipient_id": "all"], fails: true)
        model.selectWorkspace(firstID); model.setSharedDraft("Identical workspace text")
        let oldWorkspace = try await call(controller, "get_app_state")
        model.selectWorkspace(secondID); model.setSharedDraft("Identical workspace text")
        _ = try await call(controller, "set_workspace_draft", editArguments(oldWorkspace, text: "Wrong workspace edit"), fails: true)
        precondition(model.state.draft == "Identical workspace text")
        model.selectWorkspace(nil); model.setSharedDraft(originalDraft)
        _ = try await call(controller, "request_end_conversation", ["conversation_id": firstID.uuidString])
        precondition(model.comparison(firstID)?.endedAt == nil, "Closure requires native confirmation")
        controller.confirmEndConversation()
        precondition(model.comparison(firstID)?.endedAt != nil && controller.pendingEndConversationID == nil)
        let ended = await model.submitGPTLiveMessage(text: "Do not send to ended history", comparisonID: firstID, recipientIDs: [targets[0]])
        precondition(!ended.attempted && model.comparison(firstID)!.followUps.count == 1)
        _ = try await call(controller, "prepare_message", ["conversation_id": firstID.uuidString, "recipient_ids": [targets[0]], "text": "Ended conversation"], fails: true)
        print("PASS: multi-recipient follow-up, shared/private draft and attachment conflicts, nonmember/unavailable/ended rejection, independent history reads, pagination, same-text workspace-switch protection and explicit closure.")

        model.webAgents.setEnabled(true, for: .codexCLI)
        model.webAgents.setEnabled(true, for: .claudeCode)
        model.webAgents.setEnabled(true, for: .chatgpt)
        let native = model.webAgents.session(for: .codexCLI)!
        let unselected = model.webAgents.session(for: WebAgentID(provider: .claudeCode))!
        let browser = model.webAgents.session(for: .chatgpt)!
        try await waitUntil("Fixture browser never became ready") { browser.snapshot.ready }
        precondition(model.requestNewBlast())
        model.setSharedDraft(originalDraft)
        unselected.updateState { $0.selected = false; $0.draft = "Private draft for a deselected native agent" }
        let privateNewDraft = unselected.state.draft
        native.updateState { $0.enabled = false }
        let disabled = await model.submitGPTLiveMessage(text: "Disabled target", comparisonID: nil, recipientIDs: ["agent:" + native.id.id])
        precondition(!disabled.attempted)
        native.updateState { $0.enabled = true }
        var unresolved = WebSendAttempt(text: "Earlier unconfirmed request", status: .uncertain)
        unresolved.comparisonID = nil
        native.updateState { $0.attempts.insert(unresolved, at: 0) }
        let unresolvedResult = await model.submitGPTLiveMessage(text: "Must not retry", comparisonID: nil, recipientIDs: ["agent:" + native.id.id])
        precondition(!unresolvedResult.attempted && native.state.attempts.count == 1)
        native.updateState { $0.attempts.removeAll { $0.id == unresolved.id } }
        let mixedTargets = [targets[3], "agent:" + native.id.id, "agent:" + browser.id.id]
        _ = try await call(controller, "prepare_message", ["conversation_id": NSNull(), "recipient_ids": mixedTargets, "text": "Compare two approaches using the same evaluation criteria."])
        precondition(native.state.attempts.isEmpty && browser.state.attempts.isEmpty)
        await controller.sendDraft()
        guard controller.pendingDraft == nil, let mixedID = controller.selectedComparisonID, let mixed = model.comparison(mixedID) else { fatalError(controller.status) }
        precondition(mixed.members.count == 1 && mixed.members[0].submission == .submitted, controller.status)
        precondition(Set(mixed.resolvedWebAgentIDs) == [native.id, browser.id])
        precondition(native.state.attempts.first?.status == .observed && browser.state.attempts.first?.status == .observed, controller.status)
        precondition(unselected.state.localDrafts["new"] == privateNewDraft && unselected.state.localDrafts[mixedID.uuidString] == "", "An unselected native draft must retain its original workspace")
        precondition(unselected.state.attempts.isEmpty && model.state.workspaceDrafts?["new"] == originalDraft)
        precondition(model.state.attachmentsDraft == [attachment] && FileManager.default.fileExists(atPath: attachment.path))
        _ = try await call(controller, "prepare_message", ["conversation_id": mixedID.uuidString, "recipient_ids": mixedTargets, "text": "Which approach has the lowest execution risk?"])
        await controller.sendDraft()
        precondition(controller.pendingDraft == nil, controller.status)
        precondition(model.comparison(mixedID)!.followUps.last?.states[agents[3].id.uuidString] == .submitted && model.comparison(mixedID)!.followUps.last?.sharedWithAll == true)
        precondition(native.state.attempts.count == 2 && browser.state.attempts.count == 2)
        precondition(native.state.attempts.allSatisfy { $0.status == .observed } && browser.state.attempts.allSatisfy { $0.status == .observed }, controller.status)
        precondition(!model.busy && !model.webBroadcastBusy)
        print("PASS: actual mixed Messages/web/native fixture new send and follow-up, observed per-provider receipts, disabled/unresolved guards, shared history and deselected native draft preservation.")

        // Desktop-only broadcasts use the separate durable native-preparation scheduler.
        precondition(model.requestNewBlast())
        let appClaude = model.webAgents.session(for: WebAgentID(provider: .claudeApp))!
        for session in [appChat, appClaude] {
            session.setEnabled(true)
            await session.connectDesktopConversation()
            precondition(session.snapshot.ready, session.error ?? "Simulated desktop connection did not become ready")
        }
        let desktopTargets = ["agent:" + appChat.id.id, "agent:" + appClaude.id.id]
        _ = try await call(controller, "prepare_message", ["conversation_id": NSNull(), "recipient_ids": desktopTargets, "text": "Give two independent reviews of this pilot plan."])
        precondition(appChat.state.attempts.isEmpty && appClaude.state.attempts.isEmpty)
        await controller.sendDraft()
        guard controller.pendingDraft == nil, let desktopID = controller.selectedComparisonID else { fatalError(controller.status) }
        precondition(model.comparison(desktopID)?.members.isEmpty == true)
        precondition(Set(model.comparison(desktopID)!.resolvedWebAgentIDs) == [appChat.id, appClaude.id])
        for session in [appChat, appClaude] {
            precondition(session.state.attempts.count == 1 && session.state.attempts[0].status == .observed, controller.status)
            precondition(session.state.attempts[0].comparisonID == desktopID)
        }
        _ = try await call(controller, "prepare_message", ["conversation_id": desktopID.uuidString, "recipient_ids": desktopTargets, "text": "Identify one remaining risk in the plan."])
        await controller.sendDraft()
        precondition(controller.pendingDraft == nil, controller.status)
        for session in [appChat, appClaude] {
            precondition(session.state.attempts.count == 2 && session.state.attempts.allSatisfy { $0.status == .observed }, controller.status)
        }
        precondition(model.comparison(desktopID)!.sharedContext?.contains { $0.text == "Identify one remaining risk in the plan." } == true)
        precondition(!model.busy && !model.webBroadcastBusy)
        print("PASS: native-desktop ChatGPT + Claude fixture planned new broadcast and follow-up, durable observed receipts, shared history and broadcast cleanup. No native application was contacted.")

        _ = try await call(controller, "prepare_message", ["conversation_id": NSNull(), "recipient_ids": [targets[0]], "text": "Draft to discard"])
        let discard = controller.pendingDraft!
        _ = try await call(controller, "discard_prepared_message", ["draft_id": discard.id.uuidString, "expected_revision": discard.revision])
        precondition(controller.pendingDraft == nil)
        let exported = String(decoding: try controller.activity.jsonExportData(), as: UTF8.self)
        precondition(exported.contains("prepare_message") && exported.contains("tool_result") && exported.contains("recipient_ids") && exported.contains("approval"))
        controller.activity.enabled = false
        controller.activity.record(category: "fixture", summary: "Debug off", detail: "This detail must not be retained")
        precondition(controller.activity.entries.last?.detail == nil)
        controller.activity.enabled = true
        let finalCount = outgoingCount(model)
        await controller.disconnect()
        precondition(!controller.connected && !controller.microphone && controller.session.state == .idle)
        _ = try await call(controller, "prepare_message", ["conversation_id": NSNull(), "recipient_ids": [targets[0]], "text": "Inactive session"], fails: true)
        precondition(controller.pendingDraft == nil && outgoingCount(model) == finalCount)
        model.webAgents.beginShutdown()
        await model.webAgents.cancelAndWait()
        print("PASS: debug arguments/results/approvals, export, debug-off detail suppression, revision-checked discard and disconnected-tool rejection. No API calls or real messages.")
    }
}
