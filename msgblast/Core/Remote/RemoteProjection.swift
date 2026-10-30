import Combine
import CryptoKit
import Foundation
import msgblastRemoteProtocol

/// Everything the projection reads, gathered on the main actor from AppModel and
/// WebAgents. Derived state only: nothing here is persisted.
public struct RemoteProjectionInput: Sendable {
    public var macStatus: MacStatus
    public var gridAgentIDs: [String]
    public var agents: [AgentAvailability]
    public var comparisons: [Comparison]
    /// comparison → Messages member → transcript rows in the comparison's range.
    public var messagesTranscripts: [UUID: [UUID: [Message]]]
    /// comparison → agent → transcript read from the session (or `endedWebHistory`).
    public var webHistories: [UUID: [WebAgentID: [WebPageMessage]]]
    public var webAttempts: [UUID: [WebAgentID: [WebSendAttempt]]]
    public var canEnd: [UUID: Bool]
    public var reports: [UUID: RemoteReport]
    public init(macStatus: MacStatus, gridAgentIDs: [String], agents: [AgentAvailability], comparisons: [Comparison], messagesTranscripts: [UUID: [UUID: [Message]]] = [:],
                webHistories: [UUID: [WebAgentID: [WebPageMessage]]] = [:], webAttempts: [UUID: [WebAgentID: [WebSendAttempt]]] = [:], canEnd: [UUID: Bool] = [:], reports: [UUID: RemoteReport] = [:]) {
        self.macStatus = macStatus; self.gridAgentIDs = gridAgentIDs; self.agents = agents; self.comparisons = comparisons
        self.messagesTranscripts = messagesTranscripts; self.webHistories = webHistories; self.webAttempts = webAttempts; self.canEnd = canEnd; self.reports = reports
    }

    /// Reads website/app/CLI/bot histories and attempts without loading pages or sending.
    @MainActor public mutating func gatherWebState(from sessions: [WebAgentSession]) {
        for comparison in comparisons {
            var histories: [WebAgentID: [WebPageMessage]] = [:], attempts: [WebAgentID: [WebSendAttempt]] = [:]
            var endable = true
            for agent in comparison.resolvedWebAgentIDs {
                let session = sessions.first { $0.id == agent }
                if comparison.endedAt != nil { histories[agent] = comparison.endedWebHistory?[agent.id] ?? [] }
                else { histories[agent] = session?.messagesForComparison(comparison.id) ?? [] }
                attempts[agent] = session?.state.attempts.filter { $0.comparisonID == comparison.id } ?? []
                if session?.canArchiveComparison(comparison.id) != true { endable = false }
            }
            webHistories[comparison.id] = histories
            webAttempts[comparison.id] = attempts
            canEnd[comparison.id] = comparison.endedAt == nil && endable
        }
    }
}

/// A normalized projection keyed by stable ids, ready to diff.
public struct RemoteProjectionState: Equatable, Sendable {
    public var macStatus: MacStatus
    public var grid: RemoteGrid
    public var agents: [AgentAvailability]
    public var conversations: [RemoteConversation]
    public var turns: [RemoteTurn]
    public var attempts: [RemoteAttempt]
    public init(macStatus: MacStatus, grid: RemoteGrid, agents: [AgentAvailability], conversations: [RemoteConversation], turns: [RemoteTurn], attempts: [RemoteAttempt]) {
        self.macStatus = macStatus; self.grid = grid; self.agents = agents; self.conversations = conversations; self.turns = turns; self.attempts = attempts
    }
}

public enum RemoteProjectionBuilder {
    static func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() }
    static func refs(_ files: [MessageAttachment]) -> [RemoteAttachmentRef] {
        files.map { RemoteAttachmentRef(id: $0.id, filename: $0.filename, mimeType: $0.mimeType, byteCount: $0.byteCount) }
    }
    static func status(_ submission: Submission) -> RemoteAttemptStatus { RemoteAttemptStatus(rawValue: submission.rawValue) ?? .uncertain }
    static func status(_ web: WebSendStatus) -> RemoteAttemptStatus { RemoteAttemptStatus(rawValue: web.rawValue) ?? .uncertain }
    static func role(_ role: String) -> RemoteTurnRole { role == "user" ? .user : role == "assistant" ? .assistant : .system }

    /// The files recorded on each projected turn, by the same turn ids `state(from:)` uses.
    /// `fetchAttachment` reads only these.
    public static func attachmentFiles(from input: RemoteProjectionInput) -> [String: [MessageAttachment]] {
        var files: [String: [MessageAttachment]] = [:]
        for comparison in input.comparisons {
            let cid = comparison.id
            if let prompt = comparison.attachments, !prompt.isEmpty { files["p:\(cid.uuidString)"] = prompt }
            for member in comparison.members {
                for message in input.messagesTranscripts[cid]?[member.id] ?? [] where !message.outgoing && !message.attachments.isEmpty {
                    files["m:\(message.guid)"] = message.attachments
                }
            }
            for followUp in comparison.followUps {
                let attached = followUp.payloads?.values.first?.parts.compactMap(\.attachment) ?? []
                if !attached.isEmpty { files["f:\(followUp.id.uuidString)"] = attached }
            }
        }
        return files
    }

    public static func state(from input: RemoteProjectionInput) -> RemoteProjectionState {
        var conversations: [RemoteConversation] = [], turns: [RemoteTurn] = [], attempts: [RemoteAttempt] = []
        for comparison in input.comparisons {
            let cid = comparison.id
            var activity = comparison.created
            var conversationAttempts: [RemoteAttempt] = []
            turns.append(RemoteTurn(id: "p:\(cid.uuidString)", conversationID: cid, agentID: nil, role: .user, origin: .sharedPrompt, text: comparison.prompt,
                                    created: comparison.created, ordinal: 0, attachments: refs(comparison.attachments ?? []), contentHash: hash(comparison.prompt)))
            for member in comparison.members {
                let agentID = RemoteAgentIDs.messages(member.id)
                conversationAttempts.append(RemoteAttempt(id: "ma:\(cid.uuidString):\(member.id.uuidString)", conversationID: cid, agentID: agentID, text: comparison.prompt,
                                                          status: status(member.submission), detail: member.error, created: member.attemptedAt))
                for (index, message) in (input.messagesTranscripts[cid]?[member.id] ?? []).enumerated() where !message.outgoing {
                    turns.append(RemoteTurn(id: "m:\(message.guid)", conversationID: cid, agentID: agentID, role: .assistant, origin: .messagesHistory, text: message.text,
                                            created: message.date, ordinal: index, attachments: refs(message.attachments), contentHash: hash(message.text)))
                    activity = max(activity, message.date)
                }
            }
            for (index, followUp) in comparison.followUps.enumerated() {
                let privateMember = followUp.sharedWithAll != true && followUp.memberIDs.count == 1 ? followUp.memberIDs.first : nil
                let files = followUp.payloads?.values.first?.parts.compactMap(\.attachment) ?? []
                turns.append(RemoteTurn(id: "f:\(followUp.id.uuidString)", conversationID: cid, agentID: privateMember.map(RemoteAgentIDs.messages), role: .user, origin: .followUp,
                                        text: followUp.text, created: followUp.created, ordinal: index + 1, attachments: refs(files), contentHash: hash(followUp.text)))
                activity = max(activity, followUp.created)
                for member in followUp.memberIDs {
                    let key = member.uuidString
                    conversationAttempts.append(RemoteAttempt(id: "fa:\(followUp.id.uuidString):\(key)", conversationID: cid, agentID: RemoteAgentIDs.messages(member),
                        text: followUp.text, status: followUp.states[key].map(status) ?? .ready, detail: followUp.errors[key], created: followUp.created))
                }
            }
            for agent in comparison.resolvedWebAgentIDs {
                // Native transcripts carry stable ids. Website DOM ids may be synthetic, so a
                // website turn is keyed by its position; a re-render or a growing reply is an update.
                for (ordinal, message) in (input.webHistories[cid]?[agent] ?? []).enumerated() {
                    let key = agent.provider.usesNativeConversation ? message.id : String(ordinal)
                    turns.append(RemoteTurn(id: "w:\(agent.id):\(cid.uuidString):\(key)", conversationID: cid, agentID: agent.id, role: role(message.role), origin: .agentTranscript,
                                            text: message.text, created: nil, ordinal: ordinal, contentHash: hash(message.text)))
                }
                for attempt in input.webAttempts[cid]?[agent] ?? [] {
                    conversationAttempts.append(RemoteAttempt(id: "wa:\(attempt.id.uuidString)", conversationID: cid, agentID: agent.id, text: attempt.text,
                                                              status: status(attempt.status), detail: attempt.detail, created: attempt.created))
                    activity = max(activity, attempt.created)
                }
            }
            attempts += conversationAttempts
            // Native requests (Mac apps, CLIs, bots) that never completed block that agent here.
            let incomplete = comparison.resolvedWebAgentIDs.filter(\.provider.usesNativeConversation).flatMap { agent in
                (input.webAttempts[cid]?[agent] ?? []).filter(\.status.isUnresolved).map {
                    RemoteIncompleteAttempt(agentID: agent.id, attemptID: "wa:\($0.id.uuidString)", reasonCode: .incompleteRequestBlocking)
                }
            }
            conversations.append(RemoteConversation(id: cid, title: comparison.title, prompt: comparison.prompt, created: comparison.created, endedAt: comparison.endedAt,
                agentIDs: comparison.members.map { RemoteAgentIDs.messages($0.id) } + comparison.resolvedWebAgentIDs.map(\.id),
                canEnd: input.canEnd[cid] ?? (comparison.endedAt == nil), unresolvedAttemptCount: conversationAttempts.filter(\.status.isUnresolved).count,
                lastActivity: activity, report: input.reports[cid], incompleteAttempts: incomplete))
        }
        return RemoteProjectionState(macStatus: input.macStatus, grid: RemoteGrid(visibleAgentIDs: input.gridAgentIDs), agents: input.agents,
                                     conversations: conversations, turns: turns, attempts: attempts)
    }
}

/// Diffs successive projections by stable id into seq-numbered events and keeps
/// a bounded history for `sinceSeq` resume. Older cursors get a full snapshot.
public final class RemoteChangeJournal {
    public let capacity: Int
    public private(set) var seq: UInt64
    public private(set) var state: RemoteProjectionState?
    private var history: [RemoteEvent] = []

    /// Starting from wall-clock milliseconds keeps seq increasing across Mac restarts,
    /// so a cursor from a previous run is always older than this journal and gets a snapshot.
    public init(capacity: Int = 5000, startingSeq: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000) * 1024) {
        self.capacity = capacity
        seq = startingSeq
    }

    public var oldestResumableSeq: UInt64 { history.first.map { $0.seq - 1 } ?? seq }

    @discardableResult
    public func apply(_ next: RemoteProjectionState) -> [RemoteEvent] {
        let changes = Self.diff(from: state, to: next)
        state = next
        let events = changes.map { change -> RemoteEvent in seq += 1; return RemoteEvent(seq: seq, change: change) }
        history += events
        if history.count > capacity { history.removeFirst(history.count - capacity) }
        return events
    }

    /// Events after `cursor`, or nil when the cursor is unknown or older than the history.
    public func events(since cursor: UInt64) -> [RemoteEvent]? {
        guard cursor <= seq, cursor >= oldestResumableSeq else { return nil }
        return history.filter { $0.seq > cursor }
    }

    public func snapshot() -> RemoteSnapshot? {
        guard let state else { return nil }
        return RemoteSnapshot(seq: seq, macStatus: state.macStatus, grid: state.grid, agents: state.agents, conversations: state.conversations,
                              turns: state.turns, attempts: state.attempts)
    }

    static func diff(from old: RemoteProjectionState?, to new: RemoteProjectionState) -> [RemoteChange] {
        var upserts: [RemoteChange] = [], removals: [RemoteChange] = []
        if old.map({ !$0.macStatus.sameContent(as: new.macStatus) }) ?? true { upserts.append(.macStatus(new.macStatus)) }
        if old?.grid != new.grid { upserts.append(.grid(new.grid)) }
        func compare<T>(_ before: [T], _ after: [T], id: (T) -> String, same: (T, T) -> Bool, upsert: (T) -> RemoteChange, remove: (String) -> RemoteChange) {
            let previous = Dictionary(before.map { (id($0), $0) }, uniquingKeysWith: { _, last in last })
            var seen: Set<String> = []
            for value in after {
                let key = id(value)
                guard seen.insert(key).inserted else { continue }
                if let earlier = previous[key], same(earlier, value) { continue }
                upserts.append(upsert(value))
            }
            for value in before where !seen.contains(id(value)) { removals.insert(remove(id(value)), at: 0) }
        }
        compare(old?.agents ?? [], new.agents, id: \.agentID, same: { $0.sameContent(as: $1) }, upsert: RemoteChange.agentUpsert, remove: { .agentRemove(id: $0) })
        compare(old?.conversations ?? [], new.conversations, id: \.id.uuidString, same: ==, upsert: RemoteChange.conversationUpsert, remove: { .conversationRemove(id: UUID(uuidString: $0)!) })
        compare(old?.attempts ?? [], new.attempts, id: \.id, same: ==, upsert: RemoteChange.attemptUpsert, remove: { .attemptRemove(id: $0) })
        compare(old?.turns ?? [], new.turns, id: \.id, same: ==, upsert: RemoteChange.turnUpsert, remove: { .turnRemove(id: $0) })
        return upserts + removals
    }
}

/// Watches AppModel/WebAgents `objectWillChange`, debounces, rebuilds the projection,
/// and emits the journal's events. One reader: the connected remote client.
@MainActor
public final class RemoteProjection {
    public let journal: RemoteChangeJournal
    public var onEvents: (([RemoteEvent]) -> Void)?
    public var debounce: Duration
    private let build: @MainActor () -> RemoteProjectionState
    private let triggers: [AnyPublisher<Void, Never>]
    private var subscriptions: Set<AnyCancellable> = []
    private var pending: Task<Void, Never>?

    public init(journal: RemoteChangeJournal = RemoteChangeJournal(), debounce: Duration = .milliseconds(100), triggers: [AnyPublisher<Void, Never>], build: @escaping @MainActor () -> RemoteProjectionState) {
        self.journal = journal; self.debounce = debounce; self.triggers = triggers; self.build = build
    }

    public var isObserving: Bool { !subscriptions.isEmpty }

    public func start() {
        guard subscriptions.isEmpty else { return }
        for trigger in triggers {
            trigger.sink { [weak self] in MainActor.assumeIsolated { self?.schedule() } }.store(in: &subscriptions)
        }
        refreshNow()
    }

    public func stop() {
        subscriptions.removeAll()
        pending?.cancel(); pending = nil
    }

    public func schedule() {
        guard pending == nil else { return }
        pending = Task { [weak self] in
            guard let delay = self?.debounce else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            self.refreshNow()
        }
    }

    @discardableResult
    public func refreshNow() -> [RemoteEvent] {
        let events = journal.apply(build())
        if !events.isEmpty { onEvents?(events) }
        return events
    }
}
