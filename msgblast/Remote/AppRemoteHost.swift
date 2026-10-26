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
            result.message = result.applied ? [result.message, summary].compactMap { $0 }.joined(separator: " ") : (result.message.map { "\($0) \(summary)" } ?? summary)
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
            return .rejected(.agentUnavailable, "Sign in to \(names) in msgblast on your Mac. Nothing was sent.")
        case .notPrepared:
            return .rejected(.notReady, "An agent's chat was not ready on the Mac. Nothing was submitted.")
        case .stopped:
            let details = sessions.compactMap { session in session.error.map { "\(session.name): \($0)" } }
            return .rejected(.failed, (["The Mac stopped before the shared send."] + details).joined(separator: " "))
        case .sent(let id, let result):
            // A Messages-only follow-up the send path refused leaves nothing submitted.
            if result.web.isEmpty && result.comparisonID == nil { return .rejected(.failed, "Nothing was sent.", conversationID: id) }
            return .applied(conversationID: id, statuses: statuses(id, web: result.web, followUpsBefore: followUpsBefore))
        }
    }

    private func send(_ plan: RemoteSendPlan, files: [MessageAttachment]) async -> RemoteHostResult {
        switch plan.kind {
        case .newConversation:
            let (recipients, sessions) = split(plan.agentIDs)
            if sessions.isEmpty {
                guard let id = await model.startBlast(text: plan.text, attachments: files, recipientIDs: Set(recipients), interactive: false) else {
                    return .rejected(.failed, "Nothing was sent.")
                }
                return .applied(conversationID: id, statuses: statuses(id))
            }
            let text = plan.text
            return await sharedSendWaitingForReadiness(SharedSendRequest(sessions: sessions, recipients: Set(recipients), existingID: nil, draft: text, attachments: [],
                                                                         currentDraft: { text }, clearDraft: {}, interactive: false), followUpsBefore: nil)
        case .sharedFollowUp:
            guard let id = plan.conversationID, let comparison = model.comparison(id) else { return .rejected(.unknownConversation, "That conversation is no longer on the Mac.") }
            let targets = plan.agentIDs.isEmpty
                ? comparison.members.map { RemoteAgentIDs.messages($0.id) } + comparison.resolvedWebAgentIDs.filter { $0.provider.supportsSharedSubmissions }.map(\.id)
                : plan.agentIDs
            let (recipients, sessions) = split(targets)
            let before = comparison.followUps.count
            let text = plan.text
            return await sharedSendWaitingForReadiness(SharedSendRequest(sessions: sessions.filter(\.isEnabled), recipients: Set(recipients), existingID: id, draft: text,
                                                                         attachments: files, currentDraft: { text }, clearDraft: {}, interactive: false), followUpsBefore: before)
        case .privateMessage:
            guard let agentID = plan.agentIDs.first else { return .rejected(.invalidCommand, "Choose an agent.") }
            if let member = RemoteAgentIDs.messagesAgent(agentID) {
                guard let id = plan.conversationID else {
                    guard let created = await model.startBlast(text: plan.text, attachments: files, recipientIDs: [member], interactive: false) else { return .rejected(.failed, "Nothing was sent.") }
                    return .applied(conversationID: created, statuses: statuses(created))
                }
                guard let comparison = model.comparison(id), comparison.members.contains(where: { $0.id == member }) else {
                    return .rejected(.invalidCommand, "That agent is not in this conversation.")
                }
                let before = comparison.followUps.count
                await model.followUpWithSuppliedDraft(id, only: member, recipients: nil, text: plan.text, attachments: files, newAttemptID: nil)
                guard (model.comparison(id)?.followUps.count ?? before) > before else { return .rejected(.failed, "Nothing was sent.") }
                return .applied(conversationID: id, statuses: statuses(id, followUpsBefore: before))
            }
            guard let session = session(agentID) else { return .rejected(.unknownAgent, "That agent is no longer on the Mac.") }
            model.webBroadcastBusy = true
            let (id, attempt) = await model.sendDirect(plan.text, to: session, existingID: plan.conversationID, interactive: false)
            guard let attempt else { return .rejected(.failed, "Nothing was sent.", conversationID: id) }
            return .applied(conversationID: id, statuses: [agentID: RemoteAttemptStatus(rawValue: attempt.status.rawValue) ?? .uncertain])
        }
    }

    static let readinessWait: Duration = .seconds(20)

    /// The shared send. When an agent's page had to be prepared first, nothing has been
    /// submitted yet; wait (no new navigation) for the sessions to report ready, then make
    /// the single send. This is not a retry: the first pass submitted nothing.
    private func sharedSendWaitingForReadiness(_ request: SharedSendRequest, followUpsBefore: Int?) async -> RemoteHostResult {
        model.webBroadcastBusy = true
        let first = await model.sendShared(request)
        guard case .notPrepared = first else { return sharedOutcome(first, sessions: request.sessions, followUpsBefore: followUpsBefore) }
        // Keep the Mac's own composer blocked while waiting, as during any send.
        model.webBroadcastBusy = true
        let waiting = await notReadyReasons(request.sessions, timeout: Self.readinessWait)
        guard waiting.isEmpty else {
            model.webBroadcastBusy = false
            return .rejected(.notReady, "Not every agent became ready on the Mac. Nothing was submitted.", reasons: waiting)
        }
        let second = await model.sendShared(request)
        if case .notPrepared = second {
            return .rejected(.notReady, "Not every agent became ready on the Mac. Nothing was submitted.", reasons: currentReasons(request.sessions))
        }
        return sharedOutcome(second, sessions: request.sessions, followUpsBefore: followUpsBefore)
    }

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
            return .rejected(.notReady, "Some agents need attention on the Mac.", conversationID: id, reasons: reasons)
        }
        let capture = RemoteErrorCapture()
        // The Mac composer does the same when it shows these agents: open their chats, never launch apps.
        await RemoteErrorCapture.$current.withValue(capture) { _ = await model.webAgents.prepareComparison(id, for: sessions, startNativeApps: false) }
        let waiting = await notReadyReasons(sessions, timeout: Self.readinessWait)
        return waiting.isEmpty ? .applied(conversationID: id) : .rejected(.notReady, "Not every agent became ready on the Mac.", conversationID: id, reasons: waiting)
    }

    func endConversation(_ id: UUID) -> RemoteHostResult {
        guard let comparison = model.comparison(id) else { return .rejected(.unknownConversation, "That conversation is no longer on the Mac.") }
        guard comparison.resolvedWebAgentIDs.allSatisfy({ model.webAgents.session(for: $0)?.canArchiveComparison(id) == true }) else {
            return .rejected(.historyNotLoaded, "Open this conversation on the Mac and wait for its history to load, then end it.")
        }
        let capture = RemoteErrorCapture()
        let ended = RemoteErrorCapture.$current.withValue(capture) { model.endConversation(id) }
        return ended ? .applied(conversationID: id) : .rejected(.failed, capture.summary ?? "The conversation could not be ended.")
    }

    func acknowledgeIncomplete(agentID: String, attemptID: String?) -> RemoteHostResult {
        guard let session = session(agentID), session.provider.usesNativeConversation else { return .rejected(.unknownAgent, "That agent has no request to acknowledge.") }
        guard !session.isSending else { return .rejected(.macBusy, "That request is still running on the Mac.") }
        guard let id = attemptID.flatMap(UUID.init(uuidString:)) ?? session.incompleteDesktopAttempt?.id else {
            return .rejected(.invalidCommand, "Choose the request to acknowledge.")
        }
        guard session.state.attempts.contains(where: { $0.id == id && [.waiting, .uncertain].contains($0.status) }) else {
            return .rejected(.invalidCommand, "That request does not need acknowledging.")
        }
        session.acknowledgeIncompleteRequest(attemptID: id)
        return .applied()
    }

    func cancelNative(agentID: String) -> RemoteHostResult {
        guard let session = session(agentID), session.provider.usesNativeConversation else { return .rejected(.unknownAgent, "That agent has no request to stop.") }
        session.cancelNativeRequest()
        return .applied(message: "Stopped waiting on the Mac. The other app may still finish its reply.")
    }

    func setKeepAwake(_ enabled: Bool) -> RemoteHostResult {
        keepAwake.setClientRequested(enabled) ? .applied() : .rejected(.keepAwakeDisabled, "Keep awake is turned off in msgblast Settings → Remote on the Mac.")
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
