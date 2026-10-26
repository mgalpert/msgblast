import Foundation
import msgblastCore

/// One "Send & compare": websites, Mac apps, CLIs, bots and Messages recipients.
struct SharedSendRequest {
    var sessions: [WebAgentSession]
    var recipients: Set<UUID>
    /// Nil starts a new conversation.
    var existingID: UUID?
    /// The text as typed; the broadcast trims it.
    var draft: String
    /// Files shown with a shared Messages message in the conversation context.
    var attachments: [MessageAttachment]
    var currentDraft: @MainActor () -> String
    var clearDraft: @MainActor () -> Void
    /// The Mac composer. False for remote control: no Contacts prompt, no draft promotion,
    /// and Messages follow-ups use the supplied text and files instead of the Mac's drafts.
    var interactive = true
    /// When the user pressed Send; orders the message in the shared context.
    var created = Date()
}

enum SharedSendOutcome {
    /// Nothing was sent; these websites need sign-in on the Mac.
    case signInRequired([WebAgentID])
    /// Preparation failed or the conversation ended. Errors are on the sessions or `AppModel.error`.
    case stopped
    case sent(comparisonID: UUID, result: AgentBroadcastResult)
}

extension AppModel {
    /// The shared send orchestration used by the composer (`AgentsWorkspaceView`) and the
    /// remote command executor. Callers set `webBroadcastBusy` synchronously before
    /// starting the task so a second click or command cannot begin another send; this
    /// method clears it when it finishes.
    func sendShared(_ request: SharedSendRequest) async -> SharedSendOutcome {
        defer { webBroadcastBusy = false }
        let sessions = request.sessions, recipients = request.recipients, existingID = request.existingID
        let originalDraft = request.draft
        let sentAttachments = request.attachments
        let broadcastCreated = request.created
        let needsSignIn = await webAgents.signInRequired(for: sessions)
        if !needsSignIn.isEmpty { return .signInRequired(needsSignIn) }
        guard await webAgents.prepareComparison(existingID, for: sessions, startNativeApps: true),
              existingID.flatMap({ comparison($0)?.endedAt }) == nil else { return .stopped }
        let comparisonID: UUID
        if let existingID { comparisonID = existingID }
        else {
            guard let id = await prepareWebComparison(originalDraft.trimmingCharacters(in: .whitespacesAndNewlines), recipientIDs: recipients,
                                                      agents: sessions.map(\.id), interactive: request.interactive) else { return .stopped }
            comparisonID = id
        }
        if existingID != nil {
            for session in sessions where comparison(comparisonID)?.resolvedWebAgentIDs.contains(session.id) != true {
                guard await joinWebAgent(session, comparisonID: comparisonID) else { return .stopped }
            }
        }
        guard comparison(comparisonID)?.endedAt == nil else { return .stopped }
        if let i = index(comparisonID) {
            let previous = state.comparisons[i].resolvedWebAgentIDs
            state.comparisons[i].setWebAgents(previous + sessions.map(\.id))
            do { try save() } catch { self.error = error.localizedDescription; return .stopped }
        }
        do { try freezeSharedContext(comparisonID) } catch { self.error = error.localizedDescription; return .stopped }
        let allRecipients = comparison(comparisonID).map { comparison in
            Set(comparison.resolvedWebAgentIDs) == Set(sessions.map(\.id)) && Set(comparison.members.map(\.id)) == recipients
        } ?? false
        let followUpID = UUID()
        let telemetryStarted = Date()
        let interactive = request.interactive
        let result = await AgentBroadcast.send(draft: originalDraft, currentDraft: request.currentDraft, clearDraft: request.clearDraft, web: { text in
            await WebAgents.send(text, to: sessions, comparisonID: comparisonID)
        }, messages: { text in
            guard !recipients.isEmpty else { return nil }
            if existingID != nil {
                guard let i = self.index(comparisonID) else { return nil }
                if interactive {
                    self.state.comparisons[i].allDraft = text
                    await self.followUp(comparisonID, recipients: Array(recipients), newAttemptID: followUpID)
                } else {
                    await self.followUpWithSuppliedDraft(comparisonID, recipients: Array(recipients), text: text, attachments: [], newAttemptID: followUpID)
                }
                return self.comparison(comparisonID)?.followUps.contains(where: { $0.id == followUpID }) == true ? comparisonID : nil
            }
            await self.submit(comparisonID, retry: false)
            return comparisonID
        })
        let webSubmitted = result.web.values.filter { $0.status.confirmsSubmission }.count
        let messagesSubmitted = comparison(comparisonID).map { comparison in
            existingID == nil ? comparison.members.filter { recipients.contains($0.id) && $0.submission == .submitted }.count :
            comparison.followUps.first(where: { $0.id == followUpID })?.states.values.filter { $0 == .submitted }.count ?? 0
        } ?? 0
        if webSubmitted + messagesSubmitted > 0 {
            recordMessageSubmission(kind: .shared, recipientCount: webSubmitted + messagesSubmitted, started: telemetryStarted, logicalID: existingID == nil ? comparisonID : followUpID)
        } else { recordOperation(.send, success: false, started: telemetryStarted) }
        if existingID != nil, allRecipients,
           result.web.values.allSatisfy({ $0.status.confirmsSubmission }), result.web.count == sessions.count,
           let i = index(comparisonID) {
            if recipients.isEmpty {
                state.comparisons[i].recordSharedMessage(ConversationContextMessage(text: originalDraft.trimmingCharacters(in: .whitespacesAndNewlines), attachments: sentAttachments, created: broadcastCreated))
            } else if result.comparisonID == comparisonID {
                state.comparisons[i].completeSharedBroadcast(followUpID: followUpID, recipients: recipients)
            }
            persist()
        }
        webAgents.setComparison(comparisonID)
        return .sent(comparisonID: comparisonID, result: result)
    }

    /// One website, app, CLI or bot agent, from its pane or from remote control.
    /// Like `sendShared`, the caller sets `webBroadcastBusy` first; `prepared` runs once the
    /// conversation exists (the pane uses it to show the comparison).
    func sendDirect(_ text: String, to session: WebAgentSession, existingID: UUID?, interactive: Bool = true, prepared: () -> Void = {}) async -> (comparisonID: UUID?, attempt: WebSendAttempt?) {
        defer { webBroadcastBusy = false }
        let id: UUID
        if let existingID { id = existingID }
        else {
            guard let created = await prepareWebComparison(text, recipientIDs: [], agents: [session.id], interactive: interactive) else { return (nil, nil) }
            id = created
        }
        do { try freezeSharedContext(id) } catch { self.error = error.localizedDescription; return (id, nil) }
        guard let i = index(id) else { return (nil, nil) }
        if state.comparisons[i].resolvedWebAgentIDs.contains(session.id) != true {
            state.comparisons[i].setWebAgents(state.comparisons[i].resolvedWebAgentIDs + [session.id])
        }
        do { try save() } catch { self.error = error.localizedDescription; return (id, nil) }
        prepared()
        let telemetryStarted = Date()
        let attempt = await session.send(text, comparisonID: id)
        if let attempt, attempt.status.confirmsSubmission {
            recordMessageSubmission(kind: .private, recipientCount: 1, started: telemetryStarted, logicalID: attempt.id)
        } else { recordOperation(.send, success: false, started: telemetryStarted) }
        webAgents.setComparison(id)
        return (id, attempt)
    }

    /// A Messages follow-up with text and files supplied by a remote client. The Mac's
    /// own drafts for this conversation are set aside for the send and then restored, so
    /// neither its unsent text nor its attached files are sent or lost.
    func followUpWithSuppliedDraft(_ id: UUID, only memberID: UUID? = nil, recipients: [UUID]?, text: String, attachments: [MessageAttachment], newAttemptID: UUID?) async {
        guard let i = index(id) else { return }
        let key = memberID?.uuidString
        let savedText = key.map { state.comparisons[i].privateDrafts[$0] } ?? state.comparisons[i].allDraft
        let savedFiles = attachmentDraft(comparisonID: id, memberID: memberID)
        func place(_ text: String?, _ files: [MessageAttachment]) {
            guard let i = index(id) else { return }
            if let key {
                state.comparisons[i].privateDrafts[key] = text
                if state.comparisons[i].privateAttachmentDrafts == nil { state.comparisons[i].privateAttachmentDrafts = [:] }
                state.comparisons[i].privateAttachmentDrafts?[key] = files
            } else {
                state.comparisons[i].allDraft = text ?? ""
                state.comparisons[i].allAttachmentsDraft = files
            }
        }
        place(text, attachments)
        await followUp(id, only: memberID, recipients: recipients, newAttemptID: newAttemptID)
        place(savedText, savedFiles)
        persist()
    }
}
