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
    /// False when the composer's draft changed since Send, so the newer text is kept.
    var shouldClearDraft: @MainActor () -> Bool = { true }
    var clearDraft: @MainActor () -> Void
    /// The Mac composer. False for remote control: no Contacts prompt, no draft promotion,
    /// and Messages follow-ups use the supplied text and files instead of the Mac's drafts.
    var interactive = true
    /// When the user pressed Send; orders the message in the shared context.
    var created = Date()
    /// Every recipient is a Mac app: new conversations prepare them one at a time.
    @MainActor var nativeOnly: Bool { !sessions.isEmpty && sessions.allSatisfy { $0.provider.desktopApp != nil } }
}

enum SharedSendOutcome {
    /// Nothing was sent; these websites need sign-in on the Mac.
    case signInRequired([WebAgentID])
    /// A website's page was not ready for this click, or no recipient could be prepared;
    /// preparing it may have navigated a page. Nothing was created or submitted. The Mac
    /// composer waits for another click.
    case notPrepared
    /// Preparation failed or the conversation ended. Errors are on the sessions or `AppModel.error`.
    case stopped
    case sent(comparisonID: UUID, result: AgentBroadcastResult)
}

extension AppModel {
    /// Takes the shared-send slot synchronously, so a second click or remote command
    /// cannot begin another send. Pass the token to `sendShared`, which releases it.
    func beginSharedSend(_ request: SharedSendRequest) -> UUID? {
        beginSharedWebBroadcast(nativeOnly: request.nativeOnly, comparisonID: request.existingID)
    }

    /// The shared send orchestration used by the composer (`AgentsWorkspaceView`) and the
    /// remote command executor. `broadcast` comes from `beginSharedSend`; this method
    /// finishes it. Mac apps that cannot be prepared are recorded as not sent while ready
    /// agents and Messages go ahead.
    func sendShared(_ request: SharedSendRequest, broadcast: UUID) async -> SharedSendOutcome {
        defer { finishSharedWebBroadcast(broadcast) }
        let sessions = request.sessions, recipients = request.recipients, existingID = request.existingID
        let originalDraft = request.draft
        let sentAttachments = request.attachments
        let broadcastCreated = request.created
        let interactive = request.interactive
        let trimmed = originalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let needsSignIn = await webAgents.signInRequired(for: sessions)
        if !needsSignIn.isEmpty { return .signInRequired(needsSignIn) }
        // New comparisons and already-joined native apps can prepare one
        // recipient at a time while Messages submits independently.
        let nativeOnly = request.nativeOnly
        let progressiveNative = nativeOnly &&
            (existingID.map { id in sessions.allSatisfy { comparison(id)?.resolvedWebAgentIDs.contains($0.id) == true } } ?? true)
        let comparisonID: UUID
        var readySessions: [WebAgentSession] = []
        var unsent: [WebAgentID: WebSendAttempt] = [:]
        var planned: [WebAgentID: UUID] = [:]
        if progressiveNative {
            if let existingID { comparisonID = existingID }
            else {
                guard let id = await prepareWebComparison(trimmed, recipientIDs: recipients, agents: sessions.map(\.id), interactive: interactive) else { return .stopped }
                comparisonID = id
            }
        } else {
            guard let preparation = await webAgents.prepareComparisonRecipients(existingID, for: sessions, startNativeApps: true, allowSavedPrivateDraft: true, foregroundPreparation: true) else { return .notPrepared }
            guard existingID.flatMap({ comparison($0)?.endedAt }) == nil else { return .stopped }
            readySessions = sessions.filter { preparation[$0.id] == true }
            let failedSessions = sessions.filter { preparation[$0.id] != true }
            // Website sign-in and joining an existing comparison retain their explicit setup flow.
            guard failedSessions.allSatisfy({ $0.provider.desktopApp != nil }),
                  existingID.map({ id in failedSessions.allSatisfy { comparison(id)?.resolvedWebAgentIDs.contains($0.id) == true } }) ?? true,
                  !readySessions.isEmpty || !recipients.isEmpty else { return .notPrepared }
            let failures = failedSessions.map { ($0, $0.error ?? $0.snapshot.reason) }
            if let existingID { comparisonID = existingID }
            else {
                guard let id = await prepareWebComparison(trimmed, recipientIDs: recipients, agents: sessions.map(\.id), interactive: interactive) else { return .stopped }
                comparisonID = id
            }
            if existingID != nil {
                for session in readySessions where comparison(comparisonID)?.resolvedWebAgentIDs.contains(session.id) != true {
                    guard await joinWebAgent(session, comparisonID: comparisonID) else { return .stopped }
                }
            }
            for (session, reason) in failures {
                guard let attempt = session.recordUnsentPreparation(trimmed, comparisonID: comparisonID, reason: reason) else { return .stopped }
                unsent[session.id] = attempt
            }
        }
        guard bindSharedWebBroadcast(broadcast, to: comparisonID), comparison(comparisonID)?.endedAt == nil else { return .stopped }
        if let i = index(comparisonID) {
            let previous = state.comparisons[i].resolvedWebAgentIDs
            state.comparisons[i].setWebAgents(previous + sessions.map(\.id))
            do { try save() } catch { self.error = error.localizedDescription; return .stopped }
        }
        do { try freezeSharedContext(comparisonID) } catch { self.error = error.localizedDescription; return .stopped }
        if progressiveNative {
            for session in sessions {
                guard let attempt = session.planNativePreparation(trimmed, comparisonID: comparisonID) else {
                    for earlier in sessions {
                        if let id = planned[earlier.id] { _ = earlier.failNativePreparation(id, reason: "The request could not be prepared. Nothing was sent.") }
                    }
                    return .stopped
                }
                planned[session.id] = attempt.id
            }
        }
        let unsentAttempts = unsent
        let plannedAttempts = planned
        let preparedSessions = readySessions
        let allRecipients = comparison(comparisonID).map { comparison in
            Set(comparison.resolvedWebAgentIDs) == Set(sessions.map(\.id)) && Set(comparison.members.map(\.id)) == recipients
        } ?? false
        let followUpID = UUID()
        let telemetryStarted = Date()
        let web = webAgents
        let barrier = BroadcastSubmissionBarrier { [weak self] in
            guard let self, !Task.isCancelled, !sessions.isEmpty,
                  web.comparisonID == comparisonID, self.comparison(comparisonID)?.endedAt == nil else { return }
            self.finishSharedWebInputs(broadcast)
        }
        let result = await AgentBroadcast.send(draft: originalDraft, currentDraft: request.currentDraft, shouldClearDraft: {
            request.shouldClearDraft() && web.comparisonID == comparisonID
        }, clearDraft: request.clearDraft, web: { text, confirmed in
            let didConfirm: @MainActor @Sendable () -> Void = { [weak self] in
                confirmed()
                self?.confirmSharedWebSubmission(broadcast)
            }
            let submitted: [WebAgentID: WebSendAttempt]
            if progressiveNative {
                submitted = await web.prepareAndSendPlanned(text, to: sessions, comparisonID: comparisonID, plannedAttempts: plannedAttempts,
                    onInputsFinished: { barrier.finishNativeInputs() }, onConfirmedSubmission: didConfirm)
            } else {
                submitted = await WebAgents.send(text, to: preparedSessions, comparisonID: comparisonID,
                    onInputsFinished: { barrier.finishNativeInputs() }, onConfirmedSubmission: didConfirm)
            }
            return unsentAttempts.merging(submitted) { _, latest in latest }
        }, messages: { text, confirmed in
            defer { if !Task.isCancelled { barrier.finishMessages() } }
            guard !recipients.isEmpty else { return nil }
            let states: [Submission]
            if existingID != nil {
                guard let i = self.index(comparisonID) else { return nil }
                if interactive {
                    self.state.comparisons[i].allDraft = text
                    await self.followUp(comparisonID, recipients: Array(recipients), newAttemptID: followUpID, telemetryManagedExternally: true)
                } else {
                    await self.followUpWithSuppliedDraft(comparisonID, recipients: Array(recipients), text: text, attachments: sentAttachments,
                                                         newAttemptID: followUpID, telemetryManagedExternally: true)
                }
                states = self.comparison(comparisonID)?.followUps.first(where: { $0.id == followUpID }).map { Array($0.states.values) } ?? []
            } else {
                await self.submit(comparisonID, retry: false, telemetryManagedExternally: true)
                states = self.comparison(comparisonID)?.members.filter { recipients.contains($0.id) }.map(\.submission) ?? []
            }
            return AgentBroadcast.messagesResult(states: states, comparisonID: comparisonID, onConfirmed: {
                confirmed()
                self.confirmSharedWebSubmission(broadcast)
            })
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
                state.comparisons[i].recordSharedMessage(ConversationContextMessage(text: trimmed, attachments: sentAttachments, created: broadcastCreated))
            } else if result.comparisonID == comparisonID {
                state.comparisons[i].completeSharedBroadcast(followUpID: followUpID, recipients: recipients)
            }
            persist()
        }
        return .sent(comparisonID: comparisonID, result: result)
    }

    /// One website, app, CLI or bot agent, from its pane or from remote control. The caller
    /// takes the slot first: `webBroadcastBusy = true`, or `beginIndependentNativeReply()`
    /// for a private reply while a shared send's replies are still arriving (`independent`).
    /// `prepared` runs once the conversation exists (the pane uses it to show the comparison).
    func sendDirect(_ text: String, to session: WebAgentSession, existingID: UUID?, interactive: Bool = true, independent: Bool = false,
                    prepared: () -> Void = {}) async -> (comparisonID: UUID?, attempt: WebSendAttempt?) {
        defer {
            if independent { finishIndependentNativeReply() }
            else { webBroadcastBusy = false }
        }
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
    func followUpWithSuppliedDraft(_ id: UUID, only memberID: UUID? = nil, recipients: [UUID]?, text: String, attachments: [MessageAttachment], newAttemptID: UUID?,
                                   telemetryManagedExternally: Bool = false) async {
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
        await followUp(id, only: memberID, recipients: recipients, newAttemptID: newAttemptID, telemetryManagedExternally: telemetryManagedExternally)
        place(savedText, savedFiles)
        persist()
    }
}
