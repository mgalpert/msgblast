import AppKit
import Combine
import msgblastCore

@MainActor
final class PerformanceController: ObservableObject {
    var beforeDeleteRecords: (() throws -> Void)?
    @Published private(set) var revision = 0
    @Published private(set) var error: String?
    private(set) var recorder: PerformanceRecorder?
    private let directory: URL
    private let fixture: Bool
    private var turns: [UUID: String] = [:]
    private struct TrackedWebAttempt {
        var attempt: WebSendAttempt
        let agentID: String
        var lastRecordedStatus: WebSendStatus?
    }
    private var attempts: [UUID: TrackedWebAttempt] = [:]
    private var baseline: [String: Set<String>] = [:]
    private var documents: [String: String] = [:]
    private var generating: [String: Bool] = [:]
    private var messageTurns: [String: String] = [:]
    private struct TrackedMessagesTurn {
        let turnID: String
        let followUpID: UUID?
        let text: String
        let baselineRowID: Int64
        var observedAnchor: String?
    }
    private var messagesTurns: [String: [TrackedMessagesTurn]] = [:]
    private var ambiguousMessagesTurns: Set<String> = []
    private var messagesRows: [String: Int64] = [:]
    private var observedMessagesText: [String: String] = [:]
    private var pendingActions: [String: PerformanceStamp] = [:]
    private var subscriptions: Set<AnyCancellable> = []
    private var attachedSessions: [WebAgentSession] = []
    var events: [PerformanceEvent] { recorder?.events ?? [] }
    var replies: [PerformanceReply] { recorder?.replies ?? [] }
    var enabled: Bool { recorder?.enabled == true && error == nil }
    init(directory: URL, fixture: Bool) {
        self.directory = directory; self.fixture = fixture
        do { recorder = try PerformanceRecorder(directory: directory, fixture: fixture) }
        catch { self.error = error.localizedDescription }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name).sink { [weak self] _ in
                Task { @MainActor in self?.gapAll(reason: "sleep-or-wake") }
            }.store(in: &subscriptions)
        }
    }
    func configure(enabled: Bool, web: WebAgents, inFlight: Bool = false) {
        if !enabled {
            let unfinished = inFlight || web.sessions.contains { $0.isSending || $0.snapshot.generating == true || $0.latestComparisonAttempt?.status == .waiting }
            capture { try $0.stop(reason: unfinished ? "disabled-in-flight" : "disabled") }
        }
        recorder?.enabled = enabled && error == nil
        turns = [:]; attempts = [:]; baseline = [:]; documents = [:]; generating = [:]; messageTurns = [:]; messagesTurns = [:]; ambiguousMessagesTurns = []; observedMessagesText = [:]; messagesRows = [:]; pendingActions = [:]
        attach(web)
    }
    func attach(_ web: WebAgents) { for session in web.sessions { attachSession(session) } }
    func attachSession(_ session: WebAgentSession) {
        if !attachedSessions.contains(where: { $0 === session }) { attachedSessions.append(session) }
        let key = session.id.id + ":" + (session.state.comparisonID?.uuidString ?? "new")
        if baseline[key] == nil { baseline[key] = Set(session.snapshot.messages.map(\.id)) }
        session.onPerformanceSignal = enabled ? { [weak self, weak session] signal in
            guard let self, let session else { return }; self.observe(signal, session: session)
        } : nil
        session.performanceObservationEnabled = enabled
    }
    private func agent(_ session: WebAgentSession) -> PerformanceAgent {
        .init(id: session.id.id, name: session.name, connection: session.provider == .grokbot ? .grokBot : session.provider.usesNativeConversation ? .cli : .website, provider: session.provider.rawValue)
    }
    func capture(_ operation: (PerformanceRecorder) throws -> Void) {
        guard let recorder, error == nil else { return }
        do {
            let before = recorder.events.count
            try operation(recorder)
            if recorder.events.count != before { revision += 1 }
        }
        catch {
            self.error = error.localizedDescription; recorder.enabled = false
            for session in attachedSessions { session.performanceObservationEnabled = false; session.onPerformanceSignal = nil }
            revision += 1
        }
    }
    func gapAll(reason: String) {
        guard enabled else { return }
        capture { recorder in
            for comparison in recorder.activeComparisonIDs {
                _ = try recorder.record(.gap, comparisonID: comparison, reason: reason)
            }
        }
        generating = [:]
    }
    func markSendAction(agentIDs: [String]) {
        guard enabled else { return }
        let stamp = PerformanceStamp.now
        for id in agentIDs { pendingActions[id] = stamp }
    }
    private func observe(_ signal: WebPerformanceSignal, session: WebAgentSession) {
        guard enabled else { session.performanceObservationEnabled = false; return }
        let agent = agent(session)
        capture { recorder in
            switch signal {
            case .request(let attempt):
                guard let comparison = attempt.comparisonID else { return }
                attempts[attempt.id] = .init(attempt: attempt, agentID: agent.id)
                turns[attempt.id] = try recorder.beginTurn(comparisonID: comparison.uuidString, agent: agent, text: attempt.text, scope: attempt.performanceScope ?? .unknown, requestGroup: attempt.performanceGroup, at: pendingActions.removeValue(forKey: agent.id) ?? .now)
                let key = agent.id + ":" + comparison.uuidString
                baseline[key] = Set(session.snapshot.messages.map(\.id))
            case .status(let attempt):
                guard let comparison = attempt.comparisonID, let turn = turns[attempt.id] else { return }
                attempts[attempt.id]?.attempt = attempt
                guard attempts[attempt.id]?.lastRecordedStatus != attempt.status else { return }
                attempts[attempt.id]?.lastRecordedStatus = attempt.status
                switch attempt.status {
                case .attempting: _ = try recorder.record(.dispatched, comparisonID: comparison.uuidString, agent: agent, turnID: turn, method: "native dispatch")
                case .waiting, .observed:
                    _ = try recorder.record(.submitted, comparisonID: comparison.uuidString, agent: agent, turnID: turn, method: "submission receipt; not delivery")
                    if session.provider.usesNativeConversation, attempt.status == .observed {
                        _ = try recorder.record(.completed, comparisonID: comparison.uuidString, agent: agent, turnID: turn, method: session.provider == .grokbot ? "authenticated callback; answer completion only" : "CLI process final output; streaming unavailable")
                    }
                case .notSent, .uncertain, .dismissed:
                    _ = try recorder.record(.outcome, comparisonID: comparison.uuidString, agent: agent, turnID: turn, reason: attempt.status == .notSent ? "failed" : "uncertain")
                default: break
                }
            case .cancellationRequested(let attempt):
                guard let comparison = attempt.comparisonID, let turn = turns[attempt.id] else { return }
                _ = try recorder.record(.observationState, comparisonID: comparison.uuidString, agent: agent, turnID: turn, method: "local cancellation requested; provider execution unknown", reason: "cancellation-requested")
            case .canceled(let attempt):
                guard let comparison = attempt.comparisonID, let turn = turns[attempt.id] else { return }
                _ = try recorder.record(.outcome, comparisonID: comparison.uuidString, agent: agent, turnID: turn, method: "local CLI cancellation observed; provider execution outcome unknown", reason: "canceled")
            case .gap(let comparison, let reason):
                _ = try recorder.record(.gap, comparisonID: comparison.uuidString, agent: agent, reason: reason)
                generating[agent.id + ":" + comparison.uuidString] = nil
            case .snapshot(let comparison, let document, let snapshot):
                let key = agent.id + ":" + comparison.uuidString
                let known = attempts.values.filter { $0.agentID == agent.id && $0.attempt.comparisonID == comparison }.map(\.attempt)
                if documents[key] != document {
                    documents[key] = document; generating[key] = nil
                    // First snapshot after navigation has no receipt-owned baseline:
                    // retain no earlier provider history. Native final replies use stable IDs.
                    if !known.contains(where: { $0.status == .attempting }) { baseline[key] = Set(snapshot.messages.map(\.id)) }
                    _ = try recorder.record(.observationState, comparisonID: comparison.uuidString, agent: agent, method: "structured conversation messages; earlier history omitted", reason: snapshot.generating == nil ? "unsupported-generation" : "document-start")
                }
                let ignored = baseline[key] ?? Set(snapshot.messages.map(\.id))
                baseline[key] = ignored
                let latestUser = snapshot.messages.last(where: { $0.role == "user" })
                let eligible = known.filter { attempt in
                    attempt.messageID == latestUser?.id || (session.provider == .grokbot && attempt.id.uuidString == latestUser?.id)
                }
                var activeTurn = eligible.count == 1 ? turns[eligible[0].id] : nil
                // A manual send is attributable only in a linked, single-turn page.
                if activeTurn == nil, !known.contains(where: { $0.status.isUnresolved }),
                   let user = latestUser, !ignored.contains(user.id),
                   !known.contains(where: { $0.messageID == user.id }),
                   session.state.conversationURLs[comparison.uuidString] != nil,
                   snapshot.signedIn == true, snapshot.draftAvailable == true {
                    let identity = key + ":" + document + ":" + user.id
                    if let existing = messageTurns[identity] { activeTurn = existing }
                    else {
                        activeTurn = try recorder.beginTurn(comparisonID: comparison.uuidString, agent: agent, text: user.text, scope: .unknown)
                        messageTurns[identity] = activeTurn
                        // Dispatch time was not observed: don't create one retroactively.
                    }
                }
                let userIndex = latestUser.flatMap { user in snapshot.messages.firstIndex { $0.id == user.id } }
                // Wait for the existing receipt path to own the outgoing message.
                // No dispatch/reply metric is inferred from matching text alone.
                let pendingReceipt = known.contains { $0.status == .attempting && $0.messageID == nil } && !session.provider.usesNativeConversation
                for (index, message) in snapshot.messages.enumerated() where message.role == "assistant" && !ignored.contains(message.id) {
                    if pendingReceipt { continue }
                    let turn = userIndex.map { index > $0 } == true ? activeTurn : nil
                    try recorder.reply(comparisonID: comparison.uuidString, agent: agent, messageID: document + ":" + message.id, text: message.text, turnID: turn, method: session.provider == .grokbot ? "bot-authenticated-callback; final answer observation; streaming unavailable" : session.provider.usesNativeConversation ? "cli-final-output; native receipt; streaming unavailable" : "web-dom-observer; 1 s polling fallback; native attributed receipt; not tokens")
                }
                if let state = snapshot.generating,
                   generating[key] != state || (activeTurn != nil && !recorder.events.contains(where: { $0.kind == .observationState && $0.turnID == activeTurn })) {
                    _ = try recorder.record(.observationState, comparisonID: comparison.uuidString, agent: agent, turnID: activeTurn, reason: state ? "generating" : "idle")
                }
                if generating[key] == true, snapshot.generating == false, let activeTurn,
                   recorder.events.contains(where: { $0.kind == .replyObserved && $0.turnID == activeTurn }) {
                    _ = try recorder.record(.completed, comparisonID: comparison.uuidString, agent: agent, turnID: activeTurn, method: "observed running-to-idle in same document; answer completion only")
                }
                generating[key] = snapshot.generating
            }
        }
    }
    func beginMessages(comparisonID: UUID, member: Member, text: String, scope: PerformanceScope, requestID: UUID, followUpID: UUID? = nil, requestGroup: PerformanceRequestGroup? = nil) {
        guard enabled else { return }
        capture { recorder in
            let key = member.id.uuidString + ":" + comparisonID.uuidString
            let prior = messagesTurns[key] ?? []
            let pending = prior.filter { attempt in
                !recorder.events.contains { $0.turnID == attempt.turnID && ($0.kind == .replyObserved || ($0.kind == .outcome && $0.reason == "failed")) }
            }
            let agent = PerformanceAgent(id: member.id.uuidString, name: member.name, connection: .messages)
            guard let turn = try recorder.beginTurn(comparisonID: comparisonID.uuidString, agent: agent, text: text, scope: scope, requestGroup: requestGroup, at: pendingActions.removeValue(forKey: agent.id) ?? .now) else { return }
            turns[requestID] = turn
            messagesTurns[key, default: []].append(.init(turnID: turn, followUpID: followUpID, text: text, baselineRowID: messagesRows[key] ?? 0))
            if !pending.isEmpty {
                ambiguousMessagesTurns.formUnion(pending.map(\.turnID)); ambiguousMessagesTurns.insert(turn)
            }
        }
    }
    func messagesStatus(comparisonID: UUID, member: Member, requestID: UUID, kind: PerformanceEventKind, reason: String? = nil) {
        guard enabled, let turn = turns[requestID] else { return }
        capture { _ = try $0.record(kind, comparisonID: comparisonID.uuidString, agent: .init(id: member.id.uuidString, name: member.name, connection: .messages), turnID: turn, method: "messages-native-observation; 2 s refresh; completion unsupported", reason: reason) }
    }
    func observeMessages(comparison: Comparison, member: Member, transcript: [Message]) {
        guard enabled else { return }
        let key = member.id.uuidString + ":" + comparison.id.uuidString
        if baseline[key] == nil { baseline[key] = Set(transcript.map(\.guid)); return }
        capture { recorder in
            let agent = PerformanceAgent(id: member.id.uuidString, name: member.name, connection: .messages)
            var tracked = messagesTurns[key] ?? []
            // Plain-text legacy follow-ups have no saved payload anchor. Associate
            // only one newly observed outgoing row after a captured baseline and
            // an accepted app submission; an intervening unowned send blocks this.
            for index in tracked.indices {
                guard tracked[index].observedAnchor == nil, let followID = tracked[index].followUpID,
                      let follow = comparison.followUps.first(where: { $0.id == followID }),
                      follow.states[member.id.uuidString] == .submitted,
                      follow.payloads?[member.id.uuidString]?.parts.compactMap(\.anchor).isEmpty != false else { continue }
                let outgoing = transcript.filter { $0.outgoing && $0.id > tracked[index].baselineRowID }
                if outgoing.count == 1, outgoing[0].text == tracked[index].text { tracked[index].observedAnchor = outgoing[0].guid }
            }
            messagesTurns[key] = tracked
            func anchors(_ attempt: TrackedMessagesTurn) -> Set<String> {
                if let followID = attempt.followUpID {
                    return Set((comparison.followUps.first { $0.id == followID }?.payloads?[member.id.uuidString]?.parts.compactMap(\.anchor?.guid) ?? []) + (attempt.observedAnchor.map { [$0] } ?? []))
                }
                return Set((member.payload?.parts.compactMap(\.anchor?.guid) ?? []) + (member.anchor.map { [$0.guid] } ?? []))
            }
            var owners: [String: [TrackedMessagesTurn]] = [:]
            for attempt in tracked { for guid in anchors(attempt) { owners[guid, default: []].append(attempt) } }
            for outgoing in transcript where outgoing.outgoing {
                guard let candidates = owners[outgoing.guid], candidates.count == 1, let owner = candidates.first,
                      !recorder.events.contains(where: { $0.kind == .submitted && $0.turnID == owner.turnID && $0.messageID == outgoing.guid }) else { continue }
                _ = try recorder.record(.submitted, comparisonID: comparison.id.uuidString, agent: agent, turnID: owner.turnID, messageID: outgoing.guid,
                    sourceMS: Int64(outgoing.date.timeIntervalSince1970 * 1000), method: "messages-source-outgoing; observed history receipt; source clock separate")
            }
            for message in transcript where !message.outgoing && baseline[key]?.contains(message.guid) != true {
                let identity = key + ":" + message.guid
                guard observedMessagesText[identity] != message.text else { continue }
                let candidates: [TrackedMessagesTurn]
                if let replyTo = message.replyTo {
                    candidates = owners[replyTo] ?? []
                } else if let outgoing = transcript.last(where: { $0.outgoing && $0.id < message.id }) {
                    candidates = (owners[outgoing.guid] ?? []).filter { !ambiguousMessagesTurns.contains($0.turnID) }
                } else { candidates = [] }
                let turn = candidates.count == 1 ? candidates[0].turnID : nil
                try recorder.reply(comparisonID: comparison.id.uuidString, agent: agent, messageID: message.guid, text: message.text, turnID: turn,
                    sourceMS: Int64(message.date.timeIntervalSince1970 * 1000),
                    method: "messages-poll; owned outgoing range or explicit reply; source timestamp separate; 2 s cadence; completion unsupported")
                observedMessagesText[identity] = message.text
            }
            messagesRows[key] = transcript.map(\.id).max() ?? messagesRows[key] ?? 0
        }
    }
    func seedMessages(comparison: Comparison, member: Member, transcript: [Message]) {
        let key = member.id.uuidString + ":" + comparison.id.uuidString
        baseline[key] = Set(transcript.map(\.guid))
        messagesRows[key] = transcript.map(\.id).max() ?? 0
    }
    func feedback(_ reply: PerformanceReply, _ selection: PerformanceFeedback) {
        capture { try $0.setFeedback(comparisonID: reply.comparisonID, agentID: reply.agent.id, messageID: reply.messageID, selection: reply.feedback == selection ? .unmarked : selection, segmentID: reply.segmentID) }
    }
    func deleteAll() {
        do {
            try beforeDeleteRecords?()
            if let recorder { try recorder.deleteAll() }
            else { try FileManager.default.removeItem(at: directory.appendingPathComponent("Performance/events.jsonl")); recorder = try PerformanceRecorder(directory: directory, fixture: fixture) }
            error = nil; revision += 1
        } catch { self.error = error.localizedDescription }
    }
}
