import Foundation
import msgblastCore

struct GPTLiveSendResult {
    let summary: String
    let comparisonID: UUID?
    /// Delivery routines were invoked. This does not mean submission succeeded.
    let attempted: Bool
}

extension AppModel {
    /// The caller must obtain approval for the exact text and recipients before calling.
    /// GPT-Live owns a separate reviewed draft; it never consumes the app's composers.
    func submitGPTLiveMessage(text: String, comparisonID requestedID: UUID?, recipientIDs: [String]) async -> GPTLiveSendResult {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func rejected(_ reason: String, id: UUID? = nil) -> GPTLiveSendResult {
            GPTLiveSendResult(summary: "Nothing was sent. " + reason, comparisonID: id ?? requestedID, attempted: false)
        }
        guard !body.isEmpty, body.count <= 8_000, body.utf8.count <= 32_000 else {
            return rejected("Use a message between 1 and 8,000 characters (at most 32 KB).")
        }
        guard !recipientIDs.isEmpty, recipientIDs.count <= 64, Set(recipientIDs).count == recipientIDs.count else {
            return rejected("Choose 1–64 distinct configured recipients.")
        }
        guard !busy, !webBroadcastBusy, !webAgents.sessions.contains(where: \.isSending),
              !needsOnboarding, !needsSharingChoice, !Task.isCancelled else {
            return rejected("Finish setup or the current operation before sending.")
        }

        var messageIDs = Set<UUID>()
        var sessions: [WebAgentSession] = []
        for id in recipientIDs {
            if id.hasPrefix("messages:"), let uuid = UUID(uuidString: String(id.dropFirst("messages:".count))),
               state.agents.contains(where: { $0.id == uuid }) {
                messageIDs.insert(uuid)
            } else if id.hasPrefix("agent:"),
                      let session = webAgents.sessions.first(where: { $0.id.id == String(id.dropFirst("agent:".count)) }) {
                sessions.append(session)
            } else { return rejected("A reviewed recipient is no longer configured: \(id).") }
        }
        guard messageIDs.count + Set(sessions.map(\.id)).count == recipientIDs.count else {
            return rejected("The recipient list contains duplicate destinations.")
        }
        guard !WebAgents.hasConflictingNativeRecipients(sessions.map(\.provider)) else {
            return rejected("Choose ChatGPT or Dots; they share the same app.")
        }

        let nativeOnly = !sessions.isEmpty && sessions.allSatisfy { $0.provider.desktopApp != nil }
        guard let broadcast = beginSharedWebBroadcast(nativeOnly: nativeOnly, comparisonID: requestedID) else {
            return rejected("Another broadcast owns this conversation.")
        }
        // Also block standalone Messages composers while preparation awaits account/app access.
        busy = true
        var ownsBusy = true
        defer {
            if ownsBusy { busy = false }
            finishSharedWebBroadcast(broadcast)
        }

        var destinationID = requestedID
        do {
            try save() // Fail closed if the local store cannot preserve durable intent.
            if !messageIDs.isEmpty, !demo, contacts.status == .notDetermined { try await contacts.request() }
            try Task.checkCancellation()
            try validateGPTLiveTargets(comparisonID: requestedID, messageIDs: messageIDs, sessions: sessions, text: body)
            let members = requestedID == nil && !messageIDs.isEmpty ? try validateMembers(prompt: body, selectedIDs: messageIDs) : []

            // Preserve the outgoing workspace's draft before any provider changes its page.
            if !sessions.isEmpty {
                selectWorkspace(requestedID)
                try save()
                let needsSignIn = await webAgents.signInRequired(for: sessions)
                guard needsSignIn.isEmpty else {
                    return rejected("Sign in to \(needsSignIn.map { webAgents.name(for: $0) }.joined(separator: ", ")) and review again.")
                }
                guard let prepared = await webAgents.prepareComparisonRecipients(requestedID, for: sessions,
                    startNativeApps: true, allowSavedPrivateDraft: false, foregroundPreparation: true) else {
                    return rejected("Recipient preparation stopped or the workspace changed.")
                }
                let unavailable = sessions.filter { prepared[$0.id] != true }
                guard unavailable.isEmpty else {
                    return rejected(unavailable.map { "\($0.name): \($0.error ?? $0.snapshot.reason)" }.joined(separator: "\n"))
                }
            }
            try Task.checkCancellation()
            try validateGPTLiveTargets(comparisonID: requestedID, messageIDs: messageIDs, sessions: sessions, text: body)
            guard sessions.isEmpty || webAgents.comparisonID == requestedID else {
                return rejected("The workspace changed during preparation. Review the destination again.")
            }

            let id: UUID
            if let requestedID { id = requestedID }
            else {
                // Revalidate routing after asynchronous preparation. An approval cannot follow a reroute.
                let fresh = messageIDs.isEmpty ? [] : try validateMembers(prompt: body, selectedIDs: messageIDs)
                let reviewedRoutes = Dictionary(uniqueKeysWithValues: members.map { ($0.id, [$0.chat.id, ChatResolver.normalize($0.chat.handle)]) })
                let currentRoutes = Dictionary(uniqueKeysWithValues: fresh.map { ($0.id, [$0.chat.id, ChatResolver.normalize($0.chat.handle)]) })
                guard currentRoutes == reviewedRoutes else {
                    return rejected("A Messages destination changed. Review the recipients again.")
                }
                var comparison = Comparison(prompt: body, members: fresh)
                if !sessions.isEmpty { comparison.setWebAgents(sessions.map(\.id)) }
                state.comparisons.insert(comparison, at: 0)
                do { try save() }
                catch { state.comparisons.removeAll { $0.id == comparison.id }; throw error }
                id = comparison.id
                destinationID = id
            }
            guard bindSharedWebBroadcast(broadcast, to: id), comparison(id)?.endedAt == nil else {
                return rejected("The conversation is no longer available for sending.", id: id)
            }
            if !sessions.isEmpty {
                // Unlike prepareWebComparison(promotingDraft:), this leaves every user's draft intact.
                // Native sessions otherwise promote their "new" private draft when the
                // workspace first acquires an ID, including deselected native agents.
                if requestedID == nil {
                    for session in webAgents.sessions where session.provider.usesNativeConversation && session.state.localDrafts[id.uuidString] == nil {
                        session.updateState { $0.localDrafts[id.uuidString] = "" }
                    }
                }
                selectWorkspace(id)
                try save()
                guard sessions.allSatisfy(\.isStorageAvailable) else {
                    return rejected("An agent could not save its workspace. Existing drafts were preserved.", id: id)
                }
            }
            try freezeSharedContext(id)

            var planned: [WebAgentID: UUID] = [:]
            defer {
                // The scheduler may stop before reaching a later app. Only untouched
                // preparations become notSent; accepted/uncertain attempts are preserved.
                for session in sessions {
                    if let attemptID = planned[session.id] {
                        _ = session.failNativePreparation(attemptID, reason: "Stopped before sending.")
                    }
                }
            }
            if nativeOnly {
                for session in sessions {
                    guard let attempt = session.planNativePreparation(body, comparisonID: id) else {
                        return rejected(session.error ?? "Could not save the native request.", id: id)
                    }
                    planned[session.id] = attempt.id
                }
            }
            let plannedAttempts = planned
            let followUpID = UUID()
            let started = Date()
            let targets = messageIDs
            let recipients = sessions
            let barrier = BroadcastSubmissionBarrier { [self] in finishSharedWebInputs(broadcast) }
            try Task.checkCancellation()
            // submit/followUp acquire their own Messages busy flag synchronously.
            if !targets.isEmpty { busy = false; ownsBusy = false }
            let result = await AgentBroadcast.send(draft: body, currentDraft: { body },
                shouldClearDraft: { false }, clearDraft: {}, web: { [self] text, confirmed in
                    let onConfirmed: @MainActor @Sendable () -> Void = {
                        confirmed()
                        self.confirmSharedWebSubmission(broadcast)
                    }
                    if nativeOnly {
                        return await webAgents.prepareAndSendPlanned(text, to: recipients, comparisonID: id,
                            plannedAttempts: plannedAttempts, onInputsFinished: { barrier.finishNativeInputs() },
                            onConfirmedSubmission: onConfirmed)
                    }
                    return await WebAgents.send(text, to: recipients, comparisonID: id,
                        onInputsFinished: { barrier.finishNativeInputs() }, onConfirmedSubmission: onConfirmed)
                }, messages: { [self] text, confirmed in
                    defer { barrier.finishMessages() }
                    guard !targets.isEmpty else { return nil }
                    if requestedID == nil { await submit(id, retry: false, telemetryManagedExternally: true) }
                    else {
                        // followUp consumes only this temporary, initially-empty shared composer.
                        guard let i = index(id), state.comparisons[i].allDraft.isEmpty,
                              attachmentDraft(comparisonID: id).isEmpty else { return nil }
                        state.comparisons[i].allDraft = text
                        do { try save() }
                        catch {
                            state.comparisons[i].allDraft = ""
                            self.error = error.localizedDescription
                            return nil
                        }
                        await followUp(id, recipients: Array(targets), newAttemptID: followUpID, telemetryManagedExternally: true)
                        if let i = index(id), !state.comparisons[i].followUps.contains(where: { $0.id == followUpID }),
                           state.comparisons[i].allDraft == text {
                            state.comparisons[i].allDraft = ""
                            persist()
                        }
                    }
                    let states = gptLiveMessageReceipts(id: id, newConversation: requestedID == nil,
                        followUpID: followUpID, targets: targets).map(\.status)
                    return AgentBroadcast.messagesResult(states: states, comparisonID: id, onConfirmed: {
                        confirmed()
                        self.confirmSharedWebSubmission(broadcast)
                    })
                })

            let messageReceipts = gptLiveMessageReceipts(id: id, newConversation: requestedID == nil,
                followUpID: followUpID, targets: targets)
            let submitted = messageReceipts.filter { $0.status == .submitted }.count + result.web.values.filter { $0.status.confirmsSubmission }.count
            if submitted > 0 {
                recordMessageSubmission(kind: .shared, recipientCount: submitted, started: started,
                    logicalID: requestedID == nil ? id : followUpID)
            } else { recordOperation(.send, success: false, started: started) }
            var historyError: String?
            if requestedID != nil, let i = index(id),
               Set(state.comparisons[i].members.map(\.id)) == targets,
               Set(state.comparisons[i].resolvedWebAgentIDs) == Set(recipients.map(\.id)),
               result.web.count == recipients.count, result.web.values.allSatisfy({ $0.status.confirmsSubmission }) {
                if targets.isEmpty {
                    state.comparisons[i].recordSharedMessage(ConversationContextMessage(text: body, attachments: [], created: started))
                } else { state.comparisons[i].completeSharedBroadcast(followUpID: followUpID, recipients: targets) }
                do { try save() } catch { historyError = "Could not save shared history: \(error.localizedDescription). Do not resend." }
            }
            var lines = messageReceipts.map { "\($0.name): \($0.status.label)\($0.detail.map { ". " + $0 } ?? "")" }
            for session in recipients {
                if let receipt = result.web[session.id] {
                    lines.append("\(session.name): \(receipt.status.label(for: session.provider))\(receipt.detail.map { ". " + $0 } ?? "") [\(receipt.id.uuidString)]")
                } else { lines.append("\(session.name): no submission receipt. \(session.error ?? "Check the agent before trying again.")") }
            }
            if let historyError { lines.append(historyError) }
            if lines.isEmpty { lines.append("No submission receipt. Check the conversation before trying again.") }
            let summary = (demo ? "Simulated submissions:\n" : "") + lines.joined(separator: "\n")
            return GPTLiveSendResult(summary: summary, comparisonID: id, attempted: true)
        } catch {
            return rejected(error.localizedDescription, id: destinationID)
        }
    }

    private func validateGPTLiveTargets(comparisonID id: UUID?, messageIDs: Set<UUID>, sessions: [WebAgentSession], text: String) throws {
        guard messageIDs.isSubset(of: Set(state.agents.map(\.id))) else {
            throw AppFailure.blocked("A Messages recipient was removed during preparation. Review the recipients again.")
        }
        if let id {
            guard let saved = comparison(id), saved.endedAt == nil else { throw AppFailure.blocked("The conversation has ended or is unavailable.") }
            guard messageIDs.isSubset(of: Set(saved.members.map(\.id))),
                  Set(sessions.map(\.id)).isSubset(of: Set(saved.resolvedWebAgentIDs)) else {
                throw AppFailure.blocked("Recipients must already belong to this conversation. Adding someone also shares its history and needs a separate review.")
            }
            if !messageIDs.isEmpty {
                guard saved.allDraft.isEmpty, (saved.allAttachmentsDraft ?? []).isEmpty else {
                    throw AppFailure.blocked("This conversation has an existing shared draft or attachments. They were preserved; finish that draft first.")
                }
                try RecipientSet.validate(saved.members)
                for member in saved.members where messageIDs.contains(member.id) {
                    guard (saved.privateDrafts[member.id.uuidString] ?? "").isEmpty,
                          (saved.privateAttachmentDrafts?[member.id.uuidString] ?? []).isEmpty else {
                        throw AppFailure.blocked("\(member.name) has an existing private draft or attachments. They were preserved.")
                    }
                    guard member.submission == .submitted, member.anchor != nil else {
                        throw AppFailure.blocked("Wait for \(member.name)'s original prompt receipt before following up.")
                    }
                    guard ComparisonRange.nextAnchor(for: saved, member: member, comparisons: state.comparisons) == nil else {
                        throw AppFailure.blocked("\(member.name) has joined a newer conversation. Open the original prompt in Messages to reply safely.")
                    }
                    try validate(member.chat)
                }
            }
        }
        for session in sessions {
            guard session.isEnabled, session.provider.supportsSharedSubmissions, session.isStorageAvailable,
                  !webAgents.isBusyForSelection(session) else {
                throw AppFailure.blocked("\(session.name) is disabled, busy, or its storage needs repair.")
            }
            let key = id?.uuidString ?? "new"
            let savedDraft = session.provider.usesNativeConversation ? session.state.localDrafts[key] : session.state.webDrafts[key]
            guard (savedDraft ?? "").isEmpty,
                  session.state.comparisonID != id || (!session.snapshot.hasDraft && session.state.draft.isEmpty && session.draftRecoveryText == nil) else {
                throw AppFailure.blocked("\(session.name) has an unsent private draft. It was preserved; finish that draft first.")
            }
            guard !session.state.attempts.contains(where: {
                $0.status.isUnresolved && (session.provider.desktopApp != nil || $0.comparisonID == id ||
                    (session.provider.sharesOneConversation && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == text))
            }) else { throw AppFailure.blocked("\(session.name) has an unresolved request. Check its receipt before sending again.") }
        }
    }

    private func gptLiveMessageReceipts(id: UUID, newConversation: Bool, followUpID: UUID, targets: Set<UUID>) -> [(name: String, status: Submission, detail: String?)] {
        guard let saved = comparison(id) else { return [] }
        let followUp = saved.followUps.first { $0.id == followUpID }
        return saved.members.filter { targets.contains($0.id) }.map { member in
            if newConversation { return (member.name, member.submission, member.error) }
            return (member.name, followUp?.states[member.id.uuidString] ?? .ready,
                    followUp?.errors[member.id.uuidString] ?? (followUp == nil ? error ?? "No follow-up was submitted." : nil))
        }
    }
}
