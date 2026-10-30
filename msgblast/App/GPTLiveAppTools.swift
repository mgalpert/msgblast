import Foundation
import CoreFoundation
import msgblastCore

@MainActor
extension GPTLiveController {
    func handleAppTool(_ call: GPTLiveFunctionCall) async throws -> String {
        guard let schema = Self.tools.first(where: { $0["name"] as? String == call.name }),
              let parameters = schema["parameters"] as? [String: Any],
              let properties = parameters["properties"] as? [String: Any] else { throw AppFailure.blocked("Unknown app tool.") }
        let arguments = try GPTLiveToolArguments(call.arguments, keys: Set(properties.keys))
        switch call.name {
        case "get_app_state": return appStateJSON()
        case "list_agents":
            let agents: [[String: Any]] = appDestinations.map { target in
                var value: [String: Any] = ["id": target.id, "name": target.name, "kind": target.memberID == nil ? "app_or_web" : "messages"]
                if let id = target.memberID, let agent = model.state.agents.first(where: { $0.id == id }) {
                    value["status"] = model.messageConnectionStatus(agent); value["selected"] = model.state.selection.contains(id)
                } else if let id = target.webID, let session = model.webAgents.session(for: id) {
                    value["status"] = session.error ?? (session.isReadyForOnboarding ? "Ready" : "May need connection or sign-in")
                    value["selected"] = session.state.selected; value["busy"] = session.isSending
                }
                return value
            }
            return Self.json(["agents": agents, "note": "Only configured agents are listed. Open Discover or Settings to connect additional agents. IDs are exact tool destinations; readiness is rechecked before sending."])
        case "list_conversations":
            let query = try arguments.string("query", maximum: 200).trimmingCharacters(in: .whitespacesAndNewlines)
            let includeEnded = try arguments.bool("include_ended")
            let offset = try arguments.integer("offset", range: 0...100000)
            let limit = try arguments.integer("limit", range: 1...50)
            let matches = model.state.comparisons.filter { comparison in
                (includeEnded || comparison.endedAt == nil) && (query.isEmpty || comparison.prompt.localizedCaseInsensitiveContains(query) || destinations(for: comparison.id).contains { $0.name.localizedCaseInsensitiveContains(query) })
            }
            let page: [[String: Any]] = matches.dropFirst(offset).prefix(limit).map { comparison in
                ["id": comparison.id.uuidString, "title": comparison.title, "ended": comparison.endedAt != nil,
                 "recipients": destinations(for: comparison.id).map { ["id": $0.id, "name": $0.name] }]
            }
            return Self.json(["conversations": page, "total": matches.count, "next_offset": offset + page.count < matches.count ? offset + page.count as Any : NSNull()])
        case "read_conversation":
            let id = try arguments.uuid("conversation_id")
            let recipient = try arguments.string("recipient_id", maximum: 160)
            model.refresh()
            return try context(comparisonID: id, recipientID: recipient).json()
        case "navigate_app":
            let destination = try arguments.string("destination", maximum: 40)
            let rawID = try arguments.nullableString("conversation_id", maximum: 40)
            guard !sending, !model.busy, !model.webBroadcastBusy else { throw AppFailure.blocked("Wait for the current submission to finish before navigating.") }
            if destination == "conversation" {
                guard let rawID, let id = UUID(uuidString: rawID), model.comparison(id) != nil else { throw AppFailure.blocked("Choose an existing conversation ID.") }
                model.coordinator?.open(id)
                if model.coordinator == nil { model.openWebComparison(id) }
                selectedComparisonID = id; selectedRecipientID = "all"
            } else {
                guard rawID == nil else { throw AppFailure.blocked("conversation_id must be null unless opening a conversation.") }
                if destination == "new_conversation" {
                    guard model.requestNewBlast() else { throw AppFailure.blocked("Finish setup or resolve the current app error before starting a new conversation.") }
                    selectedComparisonID = nil
                } else if let target = GPTLiveDestination(rawValue: destination) {
                    if target == .permissions { model.onboarding.reviewPermissions() }
                    else {
                        guard target == .settings || (!model.needsOnboarding && !model.needsSharingChoice) else { throw AppFailure.blocked("Finish app setup before opening this page. Settings and Permissions remain available.") }
                        if target == .agents, !model.canStartNewBlast { throw AppFailure.blocked("Resolve the current app error before opening the agent grid.") }
                        model.gptLiveNavigationRequest = .init(destination: target)
                    }
                } else { throw AppFailure.blocked("Unknown navigation destination.") }
                if destination != "settings" { _ = model.coordinator?.reopenWorkspace() }
            }
            status = "Opened \(destination.replacingOccurrences(of: "_", with: " "))."
            activity.record(category: "navigation", summary: status, detail: rawID)
            return Self.json(["status": "opened", "destination": destination, "conversation_id": rawID as Any? ?? NSNull()])
        case "select_agents":
            try requireMutableWorkspace()
            guard model.webAgents.comparisonID == nil else { throw AppFailure.blocked("Open a new conversation workspace before selecting its agents. Existing conversation membership is unchanged.") }
            let ids = try arguments.ids("recipient_ids", allowEmpty: true)
            let available = appDestinations
            guard Set(ids).isSubset(of: Set(available.map(\.id))) else { throw AppFailure.blocked("One of these agents is unavailable. Use list_agents again.") }
            let requestedSessions = model.webAgents.sessions.filter { ids.contains("agent:" + $0.id.id) }
            guard !WebAgents.hasConflictingNativeRecipients(requestedSessions.map(\.provider)),
                  !requestedSessions.contains(where: { model.webAgents.isBusyForSelection($0) }) else {
                throw AppFailure.blocked("The requested agents are busy or conflict: ChatGPT and Dots share the same app. Selection is unchanged.")
            }
            guard model.webAgents.sessions.allSatisfy({ $0.isStorageAvailable }) else { throw AppFailure.blocked("An agent's saved state is unavailable.") }
            try model.save()
            model.state.selection = Set(available.filter { ids.contains($0.id) }.compactMap(\.memberID))
            for web in model.webAgents.sessions { model.webAgents.select(web, selected: ids.contains("agent:" + web.id.id)) }
            try model.save()
            let actual = Set(appDestinations.filter { target in
                if let id = target.memberID { return model.state.selection.contains(id) }
                return target.webID.flatMap { model.webAgents.session(for: $0)?.state.selected } ?? false
            }.map(\.id))
            guard actual == Set(ids), model.webAgents.sessions.allSatisfy({ $0.isStorageAvailable }) else {
                throw AppFailure.blocked("Agent selection could not be saved as requested. Read get_app_state to inspect the current selection.")
            }
            activity.record(category: "action", summary: "Selected \(ids.count) agents for a new conversation", detail: Self.json(["recipient_ids": ids]))
            return Self.json(["selected_recipient_ids": ids, "sent": false])
        case "set_workspace_draft":
            try requireMutableWorkspace()
            let expected = try arguments.string("expected_text", maximum: 32000)
            let text = try arguments.string("text", maximum: 32000)
            let expectedWorkspace = try arguments.nullableString("workspace_conversation_id", maximum: 40)
            let expectedRevision = try arguments.uuid("expected_revision")
            guard text.count <= 8000, model.state.draft == expected,
                  expectedWorkspace == model.webAgents.comparisonID?.uuidString,
                  expectedRevision == model.sharedDraftRevision.value else {
                throw AppFailure.blocked("The workspace or draft changed, or the new text is too long. Read get_app_state again before editing.")
            }
            let previous = model.state
            model.setSharedDraft(text)
            do { try model.save() } catch { model.state = previous; throw error }
            activity.record(category: "action", summary: "Updated workspace draft; attachments preserved", detail: text)
            return Self.json(["draft_text": model.state.draft, "sent": false, "attachment_count": model.state.attachmentsDraft?.count ?? 0])
        case "prepare_message":
            guard pendingDraft == nil, !sending else { throw AppFailure.blocked("A prepared message already exists. Read its revision, then update or discard it before preparing another.") }
            let rawID = try arguments.nullableString("conversation_id", maximum: 40)
            let id: UUID?
            if let rawID {
                guard let parsed = UUID(uuidString: rawID), let conversation = model.comparison(parsed), conversation.endedAt == nil else { throw AppFailure.blocked("Choose an active conversation, or null for a new one.") }
                id = parsed
            } else { id = nil }
            let allowed = Set((id == nil ? appDestinations : destinations(for: id)).map(\.id))
            pendingDraft = try GPTLiveDraft.validated(comparisonID: id, recipientIDs: arguments.ids("recipient_ids"), text: arguments.string("text", maximum: 32000), allowedRecipientIDs: allowed)
            activity.record(category: "draft", summary: "Prepared message for native review", detail: draftJSON())
            return draftJSON()
        case "update_prepared_message":
            guard !sending, var draft = pendingDraft, draft.id == (try arguments.uuid("draft_id")) else { throw AppFailure.blocked("That prepared message is unavailable. Read get_app_state again.") }
            try draft.edit(arguments.string("text", maximum: 32000), expectedRevision: arguments.integer("expected_revision", range: 0...Int.max))
            pendingDraft = draft
            activity.record(category: "draft", summary: "Updated prepared message at revision \(draft.revision)", detail: draftJSON())
            return draftJSON()
        case "discard_prepared_message":
            guard !sending, let draft = pendingDraft, draft.id == (try arguments.uuid("draft_id")), draft.revision == (try arguments.integer("expected_revision", range: 0...Int.max)) else { throw AppFailure.blocked("The prepared message changed. Read its current revision before discarding.") }
            pendingDraft = nil; activity.record(category: "draft", summary: "Discarded prepared message by app tool")
            return Self.json(["status": "discarded", "sent": false])
        case "request_end_conversation":
            let id = try arguments.uuid("conversation_id")
            guard let conversation = model.comparison(id), conversation.endedAt == nil else { throw AppFailure.blocked("Choose an active conversation.") }
            guard pendingEndConversationID == nil || pendingEndConversationID == id else { throw AppFailure.blocked("Review the existing end-conversation request first.") }
            pendingEndConversationID = id
            activity.record(category: "approval_required", summary: "Requested native confirmation to end a conversation", detail: id.uuidString)
            return Self.json(["status": "awaiting_user_confirmation", "conversation_id": id.uuidString, "ended": false])
        case "set_window_layout":
            try requireMutableWorkspace()
            guard let layout = ComparisonWindowStyle(rawValue: try arguments.string("layout", maximum: 20)) else { throw AppFailure.blocked("Choose connected or separate windows.") }
            model.setWindowStyle(layout)
            guard model.state.effectiveWindowStyle == layout else { throw AppFailure.blocked(model.error ?? "Could not save window layout.") }
            activity.record(category: "action", summary: "Set \(layout.rawValue) conversation windows")
            return Self.json(["window_layout": layout.rawValue])
        default: throw AppFailure.blocked("Unknown app tool.")
        }
    }
    private func requireMutableWorkspace() throws {
        guard !sending, !model.busy, !model.webBroadcastBusy else { throw AppFailure.blocked("Wait for the current submission to finish before changing the workspace.") }
        try model.save()
    }
    func appStateJSON() -> String {
        let selected = appDestinations.filter { target in
            if let id = target.memberID { return model.state.selection.contains(id) }
            return target.webID.flatMap { model.webAgents.session(for: $0)?.state.selected } ?? false
        }.map(\.id)
        let draftFits = model.state.draft.utf8.count <= 32000
        var value: [String: Any] = [
            "scope": "app_wide", "demo": model.demo, "conversation_count": model.state.comparisons.count,
            "agent_count": appDestinations.count, "needs_setup": model.needsOnboarding || model.needsSharingChoice,
            "active_workspace_conversation_id": model.webAgents.comparisonID?.uuidString as Any? ?? NSNull(),
            "selected_recipient_ids": selected, "submission_busy": sending || model.busy || model.webBroadcastBusy,
            "workspace_draft_text": draftFits ? model.state.draft as Any : NSNull(), "workspace_draft_too_large": !draftFits,
            "workspace_draft_revision": model.sharedDraftRevision.value.uuidString,
            "workspace_attachment_count": model.state.attachmentsDraft?.count ?? 0,
            "window_layout": model.state.effectiveWindowStyle.rawValue,
            "pending_end_conversation_id": pendingEndConversationID?.uuidString as Any? ?? NSNull(),
            "message_submission_requires_user_confirmation": true
        ]
        value["prepared_message"] = pendingDraft == nil ? NSNull() : (try? JSONSerialization.jsonObject(with: Data(draftJSON().utf8)))
        return Self.json(value)
    }
    func draftJSON() -> String {
        guard let draft = pendingDraft else { return "null" }
        return Self.json(["draft_id": draft.id.uuidString, "revision": draft.revision,
                          "conversation_id": draft.comparisonID?.uuidString as Any? ?? NSNull(),
                          "conversation_title": draftConversationTitle, "recipient_ids": draft.recipientIDs,
                          "recipient_names": draftRecipientName, "text": draft.text,
                          "status": "awaiting_user_review", "sent": false])
    }
    static let tools: [[String: Any]] = {
        let string: [String: Any] = ["type": "string"]
        let nullableString: [String: Any] = ["type": ["string", "null"]]
        let integer: [String: Any] = ["type": "integer"]
        let ids: [String: Any] = ["type": "array", "items": ["type": "string"], "maxItems": 20]
        func tool(_ name: String, _ description: String, _ properties: [String: Any]) -> [String: Any] {
            ["type": "function", "name": name, "description": description, "parameters": ["type": "object", "properties": properties, "required": properties.keys.sorted(), "additionalProperties": false], "strict": true]
        }
        return [
            tool("get_app_state", "Read current app-wide state, focused workspace, draft text, selected agents and prepared-message revision. No message history is read.", [:]),
            tool("list_agents", "List configured agents and their exact IDs, connection hints and selection. No credentials or raw contact addresses are returned.", [:]),
            tool("list_conversations", "Find saved conversations across the app by question/title or participant name. Use empty query for all; paginate with offset and limit (1–50).", ["query": string, "include_ended": ["type": "boolean"], "offset": integer, "limit": integer]),
            tool("read_conversation", "Read bounded verified history of any saved conversation. recipient_id is all or an exact participant ID from list_conversations. Attachment contents excluded. Open unloaded browser conversations before reading.", ["conversation_id": string, "recipient_id": string]),
            tool("navigate_app", "Open agents, discover, settings, permissions, new_conversation or a saved conversation. conversation_id must be null except for conversation. Never grants OS permissions or sends messages.", ["destination": ["type": "string", "enum": ["agents", "discover", "settings", "permissions", "new_conversation", "conversation"]], "conversation_id": nullableString]),
            tool("select_agents", "Select configured agents for the NEW conversation workspace. Does not change existing conversation membership or send anything. Empty array deselects all.", ["recipient_ids": ids]),
            tool("set_workspace_draft", "Edit the current main composer without sending or changing attachments, only when requested. Copy active_workspace_conversation_id, workspace_draft_revision and workspace_draft_text from get_app_state into workspace_conversation_id, expected_revision and expected_text; all must still match.", ["workspace_conversation_id": nullableString, "expected_revision": string, "expected_text": string, "text": string]),
            tool("prepare_message", "Prepare exact text and recipients for native review, only when the user asks to draft or send. conversation_id null starts a NEW conversation; existing ID follows up only to its existing participants. Does NOT send; user must click Send.", ["conversation_id": nullableString, "recipient_ids": ids, "text": string]),
            tool("update_prepared_message", "Revise the staged message when the user asks. Requires current draft_id and expected_revision from get_app_state so human edits are never overwritten. Does not send.", ["draft_id": string, "expected_revision": integer, "text": string]),
            tool("discard_prepared_message", "Discard a staged message only when the user asks. Requires its current ID and revision. Does not affect any other draft.", ["draft_id": string, "expected_revision": integer]),
            tool("request_end_conversation", "Ask the native UI to confirm ending an active conversation, only when the user asks. History is retained; the user must click End conversation. No immediate closure.", ["conversation_id": string]),
            tool("set_window_layout", "Switch the app's conversation windows between connected and separate when requested. This changes layout only.", ["layout": ["type": "string", "enum": ["connected", "separate"]]])
        ]
    }()
}

private struct GPTLiveToolArguments {
    private let values: [String: Any]
    init(_ json: String, keys: Set<String>) throws {
        guard json.utf8.count <= 100000, let data = json.data(using: .utf8),
              let values = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(values.keys) == keys else {
            throw AppFailure.blocked("Invalid app tool arguments.")
        }
        self.values = values
    }
    func string(_ key: String, maximum: Int) throws -> String {
        guard let value = values[key] as? String, value.utf8.count <= maximum else { throw AppFailure.blocked("Invalid or oversized \(key).") }
        return value
    }
    func nullableString(_ key: String, maximum: Int) throws -> String? {
        if values[key] is NSNull { return nil }
        return try string(key, maximum: maximum)
    }
    func uuid(_ key: String) throws -> UUID {
        guard let value = UUID(uuidString: try string(key, maximum: 40)) else { throw AppFailure.blocked("Invalid \(key).") }
        return value
    }
    func integer(_ key: String, range: ClosedRange<Int>) throws -> Int {
        guard let value = values[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue == Double(value.intValue), range.contains(value.intValue) else { throw AppFailure.blocked("Invalid \(key).") }
        return value.intValue
    }
    func bool(_ key: String) throws -> Bool {
        guard let value = values[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw AppFailure.blocked("Invalid \(key).") }
        return value.boolValue
    }
    func ids(_ key: String, allowEmpty: Bool = false) throws -> [String] {
        guard let values = values[key] as? [String], values.count <= 20, (allowEmpty || !values.isEmpty),
              values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 160 }), Set(values).count == values.count else { throw AppFailure.blocked("Invalid recipient IDs.") }
        return values
    }
}
