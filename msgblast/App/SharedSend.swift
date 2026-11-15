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

/// The conversation a shared send goes to, the sessions that were prepared for it, and the
/// Mac apps already recorded as not sent.
private struct SharedSendPreparation {
    var comparisonID: UUID
    var readySessions: [WebAgentSession] = []
    var unsent: [WebAgentID: WebSendAttempt] = [:]
}

/// Preparing a shared send's recipients either continues the send or ends it with an outcome.
private enum SharedSendPreparationStep {
    case ready(SharedSendPreparation)
    case finished(SharedSendOutcome)
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
        let trimmed = request.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let needsSignIn = await webAgents.signInRequired(for: sessions)
        if !needsSignIn.isEmpty { return .signInRequired(needsSignIn) }
        // New comparisons and already-joined native apps can prepare one
        // recipient at a time while Messages submits independently.
        let nativeOnly = request.nativeOnly
        let progressiveNative = nativeOnly &&
            (existingID.map { id in sessions.allSatisfy { comparison(id)?.resolvedWebAgentIDs.contains($0.id) == true } } ?? true)
        let prepared: SharedSendPreparation
        switch await prepareSharedRecipients(request, trimmed: trimmed, progressiveNative: progressiveNative) {
        case .ready(let preparation): prepared = preparation
        case .finished(let outcome): return outcome
        }
        let comparisonID = prepared.comparisonID
        guard bindSharedSend(broadcast, comparisonID: comparisonID, sessions: sessions) else { return .stopped }
        var planned: [WebAgentID: UUID] = [:]
        if progressiveNative {
            guard let plannedAttempts = planNativePreparations(sessions, trimmed: trimmed, comparisonID: comparisonID) else { return .stopped }
            planned = plannedAttempts
        }
        let allRecipients = comparison(comparisonID).map { comparison in
            Set(comparison.resolvedWebAgentIDs) == Set(sessions.map(\.id)) && Set(comparison.members.map(\.id)) == recipients
        } ?? false
        let followUpID = UUID()
        let telemetryStarted = Date()
        let result = await broadcastShared(request, broadcast: broadcast, comparisonID: comparisonID, progressiveNative: progressiveNative,
                                           prepared: prepared, plannedAttempts: planned, followUpID: followUpID)
        // Every agent asked to send gets a result; one whose send returned nothing counts as a failure.
        recordAgentSendResults(sessions.map { ($0.provider, result.web[$0.id]) })
        recordSharedSendTelemetry(result, comparisonID: comparisonID, existingID: existingID, recipients: recipients, followUpID: followUpID, started: telemetryStarted)
        recordSharedContext(result, request: request, comparisonID: comparisonID, trimmed: trimmed, allRecipients: allRecipients, followUpID: followUpID)
        return .sent(comparisonID: comparisonID, result: result)
    }

    /// Progressive Mac app sends only need the comparison; other sends prepare every
    /// recipient first and record Mac apps that could not be prepared as not sent.
    private func prepareSharedRecipients(_ request: SharedSendRequest, trimmed: String, progressiveNative: Bool) async -> SharedSendPreparationStep {
        if progressiveNative {
            guard let id = await sharedSendComparisonID(request, trimmed: trimmed) else { return .finished(.stopped) }
            return .ready(SharedSendPreparation(comparisonID: id))
        }
        return await prepareSharedSessions(request, trimmed: trimmed)
    }

    /// The existing conversation, or a new one prepared for this send.
    private func sharedSendComparisonID(_ request: SharedSendRequest, trimmed: String) async -> UUID? {
        if let existingID = request.existingID { return existingID }
        return await prepareWebComparison(trimmed, recipientIDs: request.recipients, agents: request.sessions.map(\.id), interactive: request.interactive)
    }

    private func prepareSharedSessions(_ request: SharedSendRequest, trimmed: String) async -> SharedSendPreparationStep {
        let sessions = request.sessions, recipients = request.recipients, existingID = request.existingID
        guard let preparation = await webAgents.prepareComparisonRecipients(existingID, for: sessions, startNativeApps: true, allowSavedPrivateDraft: true, foregroundPreparation: true) else { return .finished(.notPrepared) }
        guard existingID.flatMap({ comparison($0)?.endedAt }) == nil else { return .finished(.stopped) }
        let readySessions = sessions.filter { preparation[$0.id] == true }
        let failedSessions = sessions.filter { preparation[$0.id] != true }
        // Website sign-in and joining an existing comparison retain their explicit setup flow.
        guard failedSessions.allSatisfy({ $0.provider.desktopApp != nil }),
              existingID.map({ id in failedSessions.allSatisfy { comparison(id)?.resolvedWebAgentIDs.contains($0.id) == true } }) ?? true,
              !readySessions.isEmpty || !recipients.isEmpty else { return .finished(.notPrepared) }
        let failures = failedSessions.map { ($0, $0.error ?? $0.snapshot.reason) }
        guard let comparisonID = await sharedSendComparisonID(request, trimmed: trimmed) else { return .finished(.stopped) }
        guard await joinReadySessions(readySessions, existingID: existingID, comparisonID: comparisonID) else { return .finished(.stopped) }
        guard let unsent = recordUnsentPreparations(failures, trimmed: trimmed, comparisonID: comparisonID) else { return .finished(.stopped) }
        return .ready(SharedSendPreparation(comparisonID: comparisonID, readySessions: readySessions, unsent: unsent))
    }

    /// Joins prepared sessions that are not yet in an existing conversation. False stops the send.
    private func joinReadySessions(_ readySessions: [WebAgentSession], existingID: UUID?, comparisonID: UUID) async -> Bool {
        guard existingID != nil else { return true }
        for session in readySessions where comparison(comparisonID)?.resolvedWebAgentIDs.contains(session.id) != true {
            guard await joinWebAgent(session, comparisonID: comparisonID) else { return false }
        }
        return true
    }

    /// Records each Mac app that could not be prepared as not sent; nil stops the send.
    private func recordUnsentPreparations(_ failures: [(WebAgentSession, String)], trimmed: String, comparisonID: UUID) -> [WebAgentID: WebSendAttempt]? {
        var unsent: [WebAgentID: WebSendAttempt] = [:]
        for (session, reason) in failures {
            guard let attempt = session.recordUnsentPreparation(trimmed, comparisonID: comparisonID, reason: reason) else { return nil }
            unsent[session.id] = attempt
        }
        return unsent
    }

    /// Binds the broadcast to the conversation, adds the sessions, and freezes its shared
    /// context. False stops the send.
    private func bindSharedSend(_ broadcast: UUID, comparisonID: UUID, sessions: [WebAgentSession]) -> Bool {
        guard bindSharedWebBroadcast(broadcast, to: comparisonID), comparison(comparisonID)?.endedAt == nil else { return false }
        if let i = index(comparisonID) {
            let previous = state.comparisons[i].resolvedWebAgentIDs
            state.comparisons[i].setWebAgents(previous + sessions.map(\.id))
            do { try save() } catch { self.error = error.localizedDescription; return false }
        }
        do { try freezeSharedContext(comparisonID) } catch { self.error = error.localizedDescription; return false }
        return true
    }

    /// Plans every Mac app's request; when one cannot be planned, the earlier ones are
    /// marked not sent and nil stops the send.
    private func planNativePreparations(_ sessions: [WebAgentSession], trimmed: String, comparisonID: UUID) -> [WebAgentID: UUID]? {
        var planned: [WebAgentID: UUID] = [:]
        for session in sessions {
            guard let attempt = session.planNativePreparation(trimmed, comparisonID: comparisonID) else {
                for earlier in sessions {
                    if let id = planned[earlier.id] { _ = earlier.failNativePreparation(id, reason: "The request could not be prepared. Nothing was sent.") }
                }
                return nil
            }
            planned[session.id] = attempt.id
        }
        return planned
    }

    private func broadcastShared(_ request: SharedSendRequest, broadcast: UUID, comparisonID: UUID, progressiveNative: Bool,
                                 prepared: SharedSendPreparation, plannedAttempts: [WebAgentID: UUID], followUpID: UUID) async -> AgentBroadcastResult {
        let sessions = request.sessions, recipients = request.recipients, existingID = request.existingID
        let sentAttachments = request.attachments
        let interactive = request.interactive
        let unsentAttempts = prepared.unsent
        let preparedSessions = prepared.readySessions
        let web = webAgents
        let barrier = BroadcastSubmissionBarrier { [weak self] in
            guard let self, !Task.isCancelled, !sessions.isEmpty,
                  web.comparisonID == comparisonID, self.comparison(comparisonID)?.endedAt == nil else { return }
            self.finishSharedWebInputs(broadcast)
        }
        return await AgentBroadcast.send(draft: request.draft, currentDraft: request.currentDraft, shouldClearDraft: {
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
            guard let states = await self.submitSharedMessages(text, comparisonID: comparisonID, existingID: existingID, recipients: recipients,
                                                               interactive: interactive, attachments: sentAttachments, followUpID: followUpID) else { return nil }
            return AgentBroadcast.messagesResult(states: states, comparisonID: comparisonID, onConfirmed: {
                confirmed()
                self.confirmSharedWebSubmission(broadcast)
            })
        })
    }

    /// The Messages part of a shared send: a follow-up in an existing conversation, or the
    /// first submission of a new one. Nil when the conversation is gone.
    private func submitSharedMessages(_ text: String, comparisonID: UUID, existingID: UUID?, recipients: Set<UUID>, interactive: Bool,
                                      attachments sentAttachments: [MessageAttachment], followUpID: UUID) async -> [Submission]? {
        guard existingID != nil else {
            await submit(comparisonID, retry: false, telemetryManagedExternally: true)
            return comparison(comparisonID)?.members.filter { recipients.contains($0.id) }.map(\.submission) ?? []
        }
        guard let i = index(comparisonID) else { return nil }
        if interactive {
            state.comparisons[i].allDraft = text
            await followUp(comparisonID, recipients: Array(recipients), newAttemptID: followUpID, telemetryManagedExternally: true)
        } else {
            await followUpWithSuppliedDraft(comparisonID, recipients: Array(recipients), text: text, attachments: sentAttachments,
                                            newAttemptID: followUpID, telemetryManagedExternally: true)
        }
        return comparison(comparisonID)?.followUps.first(where: { $0.id == followUpID }).map { Array($0.states.values) } ?? []
    }

    private func recordSharedSendTelemetry(_ result: AgentBroadcastResult, comparisonID: UUID, existingID: UUID?, recipients: Set<UUID>, followUpID: UUID, started telemetryStarted: Date) {
        let webSubmitted = result.web.values.filter { $0.status.confirmsSubmission }.count
        let messagesSubmitted = comparison(comparisonID).map { comparison in
            existingID == nil ? comparison.members.filter { recipients.contains($0.id) && $0.submission == .submitted }.count :
            comparison.followUps.first(where: { $0.id == followUpID })?.states.values.filter { $0 == .submitted }.count ?? 0
        } ?? 0
        if webSubmitted + messagesSubmitted > 0 {
            recordMessageSubmission(kind: .shared, recipientCount: webSubmitted + messagesSubmitted, started: telemetryStarted, logicalID: existingID == nil ? comparisonID : followUpID)
        } else { recordOperation(.send, success: false, started: telemetryStarted) }
    }

    /// After a follow-up every recipient confirmed, records it in the conversation's shared context.
    private func recordSharedContext(_ result: AgentBroadcastResult, request: SharedSendRequest, comparisonID: UUID, trimmed: String, allRecipients: Bool, followUpID: UUID) {
        guard request.existingID != nil, allRecipients,
              result.web.values.allSatisfy({ $0.status.confirmsSubmission }), result.web.count == request.sessions.count,
              let i = index(comparisonID) else { return }
        if request.recipients.isEmpty {
            state.comparisons[i].recordSharedMessage(ConversationContextMessage(text: trimmed, attachments: request.attachments, created: request.created))
        } else if result.comparisonID == comparisonID {
            state.comparisons[i].completeSharedBroadcast(followUpID: followUpID, recipients: request.recipients)
        }
        persist()
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
        recordAgentSendResults([(session.provider, attempt)])
        if let attempt, attempt.status.confirmsSubmission {
            recordMessageSubmission(kind: .private, recipientCount: 1, started: telemetryStarted, logicalID: attempt.id)
        } else { recordOperation(.send, success: false, started: telemetryStarted) }
        webAgents.setComparison(id)
        return (id, attempt)
    }

    /// A Messages follow-up with text and files supplied by a remote client. They go to the
    /// send as its payload; the Mac's saved drafts and draft files are never replaced or
    /// cleared, so quitting mid-send cannot lose them.
    func followUpWithSuppliedDraft(_ id: UUID, only memberID: UUID? = nil, recipients: [UUID]?, text: String, attachments: [MessageAttachment], newAttemptID: UUID?,
                                   telemetryManagedExternally: Bool = false) async {
        await followUp(id, only: memberID, recipients: recipients, newAttemptID: newAttemptID, telemetryManagedExternally: telemetryManagedExternally,
                       supplied: (text, attachments))
    }
}
