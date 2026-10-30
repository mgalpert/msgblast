import Foundation
import msgblastCore
import msgblastRemoteProtocol

/// Runs remote commands through the same AppModel and WebAgentSession paths as the
/// Mac UI, so every duplicate-send guard applies. Errors raised while a command
/// runs are captured for its result instead of the Mac's alert. Nothing retries.
@MainActor
final class AppRemoteHost: RemoteCommandHost {
    let model: AppModel
    let availabilityModel: AvailabilityModel
    let keepAwake: RemoteKeepAwake
    let power: MacPowerState
    private let settings: () -> RemoteSettings
    private var staged: [String: MessageAttachment] = [:]

    init(model: AppModel, availability: AvailabilityModel, keepAwake: RemoteKeepAwake, power: MacPowerState, settings: @escaping () -> RemoteSettings) {
        self.model = model; availabilityModel = availability; self.keepAwake = keepAwake; self.power = power; self.settings = settings
    }

    var isLocked: Bool { power.locked }
    var messagesSendsAllowed: Bool { settings().allowMessagesSends }
    var isBusy: Bool { model.busy || model.webBroadcastBusy || model.webAgents.sessions.contains { $0.isSending } }

    func availability(for agentID: String) -> AgentAvailability? { availabilityModel.availability(for: agentID) }

    func conversation(_ id: UUID) -> RemoteConversationState? {
        guard let comparison = model.comparison(id) else { return nil }
        if comparison.endedAt != nil { return .ended }
        return .active(members: comparison.members.map { RemoteAgentIDs.messages($0.id) } + comparison.resolvedWebAgentIDs.map(\.id))
    }

    private func session(_ agentID: String) -> WebAgentSession? { model.webAgents.sessions.first { $0.id.id == agentID } }

    private func captured(_ operation: () async -> RemoteHostResult) async -> RemoteHostResult {
        let capture = RemoteErrorCapture()
        var result = await RemoteErrorCapture.$current.withValue(capture) { await operation() }
        if let summary = capture.summary {
            // Short messages carry no trailing period; the Mac's own errors follow as a second sentence.
            result.message = result.message.map { $0.hasSuffix(".") ? "\($0) \(summary)" : "\($0). \(summary)" } ?? summary
        }
        return result
    }

    func performSend(_ plan: RemoteSendPlan) async -> RemoteHostResult {
        keepAwake.beginSend()
        defer { keepAwake.endSend() }
        let files = plan.attachmentIDs.compactMap { staged[$0] }
        let result = await captured { await send(plan, files: files) }
        if result.applied { for id in plan.attachmentIDs { staged[id] = nil } }
        return result
    }

    private func split(_ agentIDs: [String]) -> (recipients: [UUID], sessions: [WebAgentSession]) {
        (agentIDs.compactMap(RemoteAgentIDs.messagesAgent), agentIDs.compactMap(session))
    }

    private func statuses(_ comparisonID: UUID, web: [WebAgentID: WebSendAttempt] = [:], followUpsBefore: Int? = nil) -> [String: RemoteAttemptStatus] {
        var result: [String: RemoteAttemptStatus] = [:]
        for (agent, attempt) in web { result[agent.id] = RemoteAttemptStatus(rawValue: attempt.status.rawValue) ?? .uncertain }
        guard let comparison = model.comparison(comparisonID) else { return result }
        if let before = followUpsBefore {
            for followUp in comparison.followUps.dropFirst(before) {
                for (key, state) in followUp.states { if let id = UUID(uuidString: key) { result[RemoteAgentIDs.messages(id)] = RemoteAttemptStatus(rawValue: state.rawValue) } }
            }
        } else {
            for member in comparison.members { result[RemoteAgentIDs.messages(member.id)] = RemoteAttemptStatus(rawValue: member.submission.rawValue) }
        }
        return result
    }

    private func sharedOutcome(_ outcome: SharedSendOutcome, sessions: [WebAgentSession], followUpsBefore: Int?) -> RemoteHostResult {
        switch outcome {
        case .signInRequired(let ids):
            let names = ids.map { model.webAgents.name(for: $0) }.formatted(.list(type: .and))
            return .rejected(.agentUnavailable, "Sign in to \(names) on your Mac")
        case .notPrepared:
            return .rejected(.notReady, "Not every agent was ready")
        case .stopped:
            // Each agent's error stays with that agent, so the message is one line.
            let details = Dictionary(uniqueKeysWithValues: sessions.compactMap { session in session.error.map { (session.id.id, $0) } })
            return .rejected(.failed, "Your Mac stopped before sending", reasons: details)
        case .sent(let id, let result):
            // A Messages-only follow-up the send path refused leaves nothing submitted.
            if result.web.isEmpty && result.comparisonID == nil { return .rejected(.failed, "Not sent", conversationID: id) }
            return .applied(conversationID: id, statuses: statuses(id, web: result.web, followUpsBefore: followUpsBefore))
        }
    }

    private func send(_ plan: RemoteSendPlan, files: [MessageAttachment]) async -> RemoteHostResult {
        switch plan.kind {
        case .newConversation:
            let (recipients, sessions) = split(plan.agentIDs)
            if sessions.isEmpty {
                guard let id = await model.startBlast(text: plan.text, attachments: files, recipientIDs: Set(recipients), interactive: false) else {
                    return .rejected(.failed, "Not sent")
                }
                return .applied(conversationID: id, statuses: statuses(id))
            }
            let text = plan.text
            return await sharedSendWaitingForReadiness(SharedSendRequest(sessions: sessions, recipients: Set(recipients), existingID: nil, draft: text, attachments: [],
                                                                         currentDraft: { text }, clearDraft: {}, interactive: false), followUpsBefore: nil)
        case .sharedFollowUp:
            guard let id = plan.conversationID, let comparison = model.comparison(id) else { return .rejected(.unknownConversation, "This conversation is gone from your Mac") }
            let targets = plan.agentIDs.isEmpty
                ? comparison.members.map { RemoteAgentIDs.messages($0.id) } + comparison.resolvedWebAgentIDs.filter { $0.provider.supportsSharedSubmissions }.map(\.id)
                : plan.agentIDs
            let (recipients, sessions) = split(targets)
            let before = comparison.followUps.count
            let text = plan.text
            return await sharedSendWaitingForReadiness(SharedSendRequest(sessions: sessions.filter(\.isEnabled), recipients: Set(recipients), existingID: id, draft: text,
                                                                         attachments: files, currentDraft: { text }, clearDraft: {}, interactive: false), followUpsBefore: before)
        case .privateMessage:
            guard let agentID = plan.agentIDs.first else { return .rejected(.invalidCommand, "Choose an agent") }
            if let member = RemoteAgentIDs.messagesAgent(agentID) {
                guard let id = plan.conversationID else {
                    guard let created = await model.startBlast(text: plan.text, attachments: files, recipientIDs: [member], interactive: false) else { return .rejected(.failed, "Not sent") }
                    return .applied(conversationID: created, statuses: statuses(created))
                }
                guard let comparison = model.comparison(id), comparison.members.contains(where: { $0.id == member }) else {
                    return .rejected(.invalidCommand, "That agent isn't in this conversation")
                }
                let before = comparison.followUps.count
                await model.followUpWithSuppliedDraft(id, only: member, recipients: nil, text: plan.text, attachments: files, newAttemptID: nil)
                guard (model.comparison(id)?.followUps.count ?? before) > before else { return .rejected(.failed, "Not sent") }
                return .applied(conversationID: id, statuses: statuses(id, followUpsBefore: before))
            }
            guard let session = session(agentID) else { return .rejected(.unknownAgent, "That agent is gone from your Mac") }
            model.webBroadcastBusy = true
            let (id, attempt) = await model.sendDirect(plan.text, to: session, existingID: plan.conversationID, interactive: false)
            guard let attempt else { return .rejected(.failed, "Not sent", conversationID: id) }
            return .applied(conversationID: id, statuses: [agentID: RemoteAttemptStatus(rawValue: attempt.status.rawValue) ?? .uncertain])
        }
    }

    static let readinessWait: Duration = .seconds(20)

    /// The shared send. When an agent's page had to be prepared first, nothing has been
    /// submitted yet; wait (no new navigation) for the sessions to report ready, then make
    /// the single send. This is not a retry: the first pass submitted nothing.
    private func sharedSendWaitingForReadiness(_ request: SharedSendRequest, followUpsBefore: Int?) async -> RemoteHostResult {
        guard let broadcast = model.beginSharedSend(request) else { return Self.macBusy }
        let first = await model.sendShared(request, broadcast: broadcast)
        guard case .notPrepared = first else { return sharedOutcome(first, sessions: request.sessions, followUpsBefore: followUpsBefore) }
        // Keep the Mac's own composer blocked while waiting, as during any send.
        guard let second = model.beginSharedSend(request) else { return Self.macBusy }
        let waiting = await notReadyReasons(request.sessions, timeout: Self.readinessWait)
        guard waiting.isEmpty else {
            model.finishSharedWebBroadcast(second)
            return .rejected(.notReady, "Not every agent was ready", reasons: waiting)
        }
        let outcome = await model.sendShared(request, broadcast: second)
        if case .notPrepared = outcome {
            return .rejected(.notReady, "Not every agent was ready", reasons: currentReasons(request.sessions))
        }
        return sharedOutcome(outcome, sessions: request.sessions, followUpsBefore: followUpsBefore)
    }

    /// Another send started on the Mac between the executor's check and this one.
    static let macBusy = RemoteHostResult.rejected(.macBusy, "Your Mac is busy. Try again soon")

    private func isReady(_ session: WebAgentSession) -> Bool {
        if session.provider.usesNativeConversation { return availabilityModel.availability(for: session.id.id)?.readiness.acceptsSend == true }
        return session.snapshot.ready && !session.loading && !session.snapshot.hasDraft
    }
    private func currentReasons(_ sessions: [WebAgentSession]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: sessions.filter { !isReady($0) }.map { ($0.id.id, $0.error ?? $0.snapshot.reason) })
    }
    /// Polls published session state only; never navigates, launches or sends.
    private func notReadyReasons(_ sessions: [WebAgentSession], timeout: Duration) async -> [String: String] {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if sessions.allSatisfy(isReady) { return [:] }
            // An agent that cannot become ready by waiting (signed out, disabled) answers at once.
            if sessions.contains(where: { availabilityModel.availability(for: $0.id.id)?.readiness.acceptsSend == false }) { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return currentReasons(sessions)
    }

    func prepareConversation(_ id: UUID?, agentIDs: [String]) async -> RemoteHostResult {
        let sessions = agentIDs.compactMap(session).filter(\.isEnabled)
        guard !sessions.isEmpty else { return .applied(conversationID: id) }
        let blocked = sessions.filter { availabilityModel.availability(for: $0.id.id)?.readiness.acceptsSend == false }
        if !blocked.isEmpty {
            let reasons = Dictionary(uniqueKeysWithValues: blocked.map { ($0.id.id, availabilityModel.availability(for: $0.id.id)?.reasons.first?.userText ?? $0.snapshot.reason) })
            return .rejected(.notReady, "Not every agent was ready", conversationID: id, reasons: reasons)
        }
        let capture = RemoteErrorCapture()
        // The Mac composer does the same when it shows these agents: open their chats, never launch apps.
        await RemoteErrorCapture.$current.withValue(capture) { _ = await model.webAgents.prepareComparison(id, for: sessions, startNativeApps: false) }
        let waiting = await notReadyReasons(sessions, timeout: Self.readinessWait)
        return waiting.isEmpty ? .applied(conversationID: id) : .rejected(.notReady, "Not every agent was ready", conversationID: id, reasons: waiting)
    }

    func endConversation(_ id: UUID) -> RemoteHostResult {
        guard let comparison = model.comparison(id) else { return .rejected(.unknownConversation, "This conversation is gone from your Mac") }
        guard comparison.resolvedWebAgentIDs.allSatisfy({ model.webAgents.session(for: $0)?.canArchiveComparison(id) == true }) else {
            return .rejected(.historyNotLoaded, "Open it on your Mac first")
        }
        let capture = RemoteErrorCapture()
        let ended = RemoteErrorCapture.$current.withValue(capture) { model.endConversation(id) }
        return ended ? .applied(conversationID: id) : .rejected(.failed, capture.summary ?? "Couldn't end this conversation")
    }

    func acknowledgeIncomplete(agentID: String, attemptID: String?) -> RemoteHostResult {
        guard let session = session(agentID), session.provider.usesNativeConversation else { return .rejected(.unknownAgent, "No request to dismiss") }
        guard !session.isSending else { return .rejected(.macBusy, "Still running on your Mac") }
        guard let id = attemptID.flatMap(UUID.init(uuidString:)) ?? session.incompleteDesktopAttempt?.id else {
            return .rejected(.invalidCommand, "Choose a request to dismiss")
        }
        guard session.state.attempts.contains(where: { $0.id == id && [.waiting, .uncertain].contains($0.status) }) else {
            return .rejected(.invalidCommand, "Nothing to dismiss")
        }
        session.acknowledgeIncompleteRequest(attemptID: id)
        return .applied()
    }

    func cancelNative(agentID: String) -> RemoteHostResult {
        guard let session = session(agentID), session.provider.usesNativeConversation else { return .rejected(.unknownAgent, "No request to stop") }
        session.cancelNativeRequest()
        return .applied(message: "Stopped waiting. A reply may still arrive")
    }

    func setKeepAwake(_ enabled: Bool) -> RemoteHostResult {
        keepAwake.setClientRequested(enabled) ? .applied() : .rejected(.keepAwakeDisabled, "Keep awake is off on your Mac")
    }

    func stageAttachment(_ data: Data, filename: String) throws -> String {
        let file = try model.local.stage(data, filename: filename)
        staged[file.id] = file
        return file.id
    }
    func hasStagedAttachment(_ id: String) -> Bool { staged[id] != nil }

    func requestReport(_ id: UUID) async -> RemoteHostResult {
        await model.personalAgent.requestReport(id, model: model)
        if let error = model.personalAgent.errors[id] { return .rejected(.failed, error, conversationID: id) }
        return .applied(conversationID: id)
    }

    /// Removes staged uploads that no draft or conversation references.
    func discardStagedAttachments() {
        for file in staged.values { model.local.removeUnreferenced(file, in: model.state) }
        staged = [:]
    }
}
