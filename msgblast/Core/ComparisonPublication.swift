import Foundation

/// A separate, owner-editable allowlist. It never mutates the source journal.
public struct ComparisonPublication: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var title: String
    public var fixture: Bool
    public var participants: [Participant]
    public var turns: [Turn]
    public var omissions: [String]
    public var limitations: [String]
    public var includesPrivate: Bool
    public var includesEarlierHistory = false
    public var includesUnknown: Bool? = nil
    public var artifacts: [Artifact] = []
    public struct Participant: Codable, Equatable, Sendable {
        public var id: String
        public var label: String
        public var connectionType: PerformanceConnection
    }
    public struct Turn: Codable, Equatable, Sendable {
        public var id: String
        public var kind: String
        public var prompt: String
        public var scope: PerformanceScope
        public var targetedAgentIDs: [String]?
        public var alignmentLabel: String?
        public var replies: [Reply]
    }
    public struct Reply: Codable, Equatable, Sendable {
        public var agentID: String
        public var outcome: String
        public var messages: [Message]
    }
    public struct Message: Codable, Equatable, Sendable {
        public var messageID: String
        public var text: String
        public var outcome: String
        public var timingLabel: String
        public var feedback: PerformanceFeedback?
        public var businessChoices: BusinessMessageCard? = nil
        public var revisions: [Revision]? = nil
        public struct Revision: Codable, Equatable, Sendable {
            public var text: String
            public var timingLabel: String
            public var businessChoices: BusinessMessageCard? = nil
        }
    }
    public struct Artifact: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var type: String
        public var base64: String
        /// Callers supply explicitly selected bytes, never a local path.
        public init(id: String, name: String, type: String, bytes: Data) throws {
            let png = bytes.starts(with: [137, 80, 78, 71])
            let jpeg = bytes.starts(with: [255, 216, 255])
            guard bytes.count <= 262144,
                  type == "text/plain" || (type == "image/png" && png) || (type == "image/jpeg" && jpeg) else {
                throw ComparisonPublicationError.unsafeArtifact
            }
            self.id = id; self.name = name; self.type = type; base64 = bytes.base64EncodedString()
        }
    }
    public func previewBytes() throws -> Data { try PerformanceCanonical.bytes(self) }
    public func previewHash() throws -> String { PerformanceCanonical.hash(try previewBytes()) }
    /// Manual transcript controls can only mask exact captured text.
    public mutating func redactLiteral(_ term: String) {
        guard !term.isEmpty else { return }
        redactText { $0.replacingOccurrences(of: term, with: "[redacted]", options: .literal) }
    }
    /// Applies owner redactions without flattening whitespace or altering IDs/timing.
    public mutating func redactText(_ transform: (String) -> String) {
        title = transform(title)
        for i in participants.indices { participants[i].label = transform(participants[i].label) }
        for i in turns.indices {
            turns[i].prompt = transform(turns[i].prompt)
            for j in turns[i].replies.indices {
                for k in turns[i].replies[j].messages.indices {
                    turns[i].replies[j].messages[k].text = transform(turns[i].replies[j].messages[k].text)
                    turns[i].replies[j].messages[k].businessChoices?.redactText(transform)
                    if let revisions = turns[i].replies[j].messages[k].revisions {
                        turns[i].replies[j].messages[k].revisions = revisions.map { revision in
                            var result = revision; result.text = transform(result.text)
                            result.businessChoices?.redactText(transform)
                            return result
                        }
                    }
                }
            }
        }
    }
}
public enum ComparisonPublicationError: Error, Equatable {
    case contractAdditionNeeded(String)
    case unsafeArtifact
    case participantMetadataMissing
}
public struct ComparisonPublicationOptions: Sendable {
    public var title = "Shared comparison"
    public var includePrivate = false
    public var includeUnknownScope = false
    public var includeEarlierHistory = false
    public var includeFeedback = true
    public var includesStreamingRevisions = false
    /// Literal names/identifiers known to the owner, beyond names present in the journal.
    public var redactedTerms: [String] = []
    public init() {}
}
public enum ComparisonPublicationBuilder {
    private struct TurnKey: Hashable {
        let segment: String; let agent: String?; let turn: String?
        init(_ event: PerformanceEvent) { segment = event.segmentID; agent = event.agent?.id; turn = event.turnID }
    }
    private struct MessageKey: Hashable {
        let segment: String; let agent: String?; let message: String?
        init(_ event: PerformanceEvent) { segment = event.segmentID; agent = event.agent?.id; message = event.messageID }
        init(segment: String, agent: String, message: String) { self.segment = segment; self.agent = agent; self.message = message }
    }
    public static func build(events source: [PerformanceEvent], comparisonID: String,
                             options: ComparisonPublicationOptions = .init()) throws -> ComparisonPublication {
        if options.includeEarlierHistory { throw ComparisonPublicationError.contractAdditionNeeded("Earlier provider history was not collected; explicit inclusion requires independently supplied, scoped source history.") }
        let events = source.filter { $0.comparisonID == comparisonID }.sorted { $0.sequence < $1.sequence }
        var agents: [PerformanceAgent] = []
        for e in events { if let a = e.agent, !agents.contains(where: { $0.id == a.id }) { agents.append(a) } }
        let ids = Dictionary(uniqueKeysWithValues: agents.enumerated().map { ($0.element.id, "agent-\($0.offset + 1)") })
        let redact: (String) -> String = { Self.redact($0, terms: agents.map(\.name) + agents.map(\.id) + options.redactedTerms) }
        var p = ComparisonPublication(title: redact(options.title), fixture: !events.isEmpty && events.allSatisfy(\.fixture),
            participants: agents.enumerated().map { .init(id: "agent-\($0.offset + 1)", label: "Agent \($0.offset + 1)", connectionType: $0.element.connection) },
            turns: [], omissions: ["Earlier provider history was not collected and is excluded.", "Attachment metadata and bodies are excluded unless explicitly selected for this preview."],
            limitations: ["Locally recorded, owner-reviewed; not independently witnessed. Automatic redaction is incomplete; inspect and redact captured text before publication.", "Owner feedback expresses preference, not accuracy or completion. Timing measures native observation, not model token generation."], includesPrivate: options.includePrivate)
        p.includesUnknown = options.includeUnknownScope ? true : nil
        let starts = events.filter { $0.kind == .turnStarted }
        let startsByTurn = Dictionary(grouping: starts, by: TurnKey.init)
        let eventsByTurn = Dictionary(grouping: events, by: TurnKey.init)
        let eventsByMessage = Dictionary(grouping: events, by: MessageKey.init)

        var groups: [[PerformanceEvent]] = []
        for start in starts {
            if let group = start.requestGroupID, !group.isEmpty,
               let index = groups.firstIndex(where: { $0.first?.requestGroupID == group }) { groups[index].append(start) }
            else { groups.append([start]) }
        }
        var omittedPrivate = 0, omittedUnknown = 0, malformed = 0, revisions = 0
        var associated: Set<String> = []
        for group in groups {
            guard let first = group.first else { continue }
            let scope = first.scope ?? .unknown
            if group.contains(where: { ($0.scope ?? .unknown) != scope }) { omittedUnknown += group.count; continue }
            if scope == .unknown && !options.includeUnknownScope { omittedUnknown += group.count; continue }
            if scope == .private && !options.includePrivate { omittedPrivate += group.count; continue }
            let declared = first.targetAgentIDs
            let valid = group.allSatisfy { e in
                guard let aid = e.agent?.id, let tid = e.turnID, !tid.isEmpty, e.text != nil else { return false }
                let sameTurn = startsByTurn[TurnKey(e)] ?? []
                return sameTurn.count == 1 && e.text == first.text && e.targetAgentIDs == declared &&
                    (declared == nil || (Set(declared!).count == declared!.count && declared!.contains(aid) && !declared!.isEmpty))
            } && Set(group.compactMap { $0.agent?.id }).count == group.count
            guard valid else { malformed += group.count; continue }
            if let declared, declared.contains(where: { ids[$0] == nil }) { throw ComparisonPublicationError.participantMetadataMissing }
            var replies: [ComparisonPublication.Reply] = []
            for start in group {
                let aid = start.agent!.id
                let local = eventsByTurn[TurnKey(start)] ?? []
                let observed = local.filter { $0.kind == .replyObserved && $0.scope == scope && $0.messageID != nil && $0.text != nil }
                var messages: [ComparisonPublication.Message] = []
                var messageIDs: [String] = []
                for e in observed { associated.insert(e.id); if !messageIDs.contains(e.messageID!) { messageIDs.append(e.messageID!) } }
                for (index, mid) in messageIDs.enumerated() {
                    let versions = observed.filter { $0.messageID == mid }
                    let initial = versions.first!, latest = versions.last!
                    if !options.includesStreamingRevisions { revisions += versions.count - 1 }
                    let messageEvents = eventsByMessage[MessageKey(segment: start.segmentID, agent: aid, message: mid)] ?? []
                    let matchingTurns = Set(messageEvents.filter { $0.kind == .replyObserved }.compactMap(\.turnID))
                    let feedback = messageEvents.last { $0.kind == .feedback && ($0.turnID == start.turnID || ($0.turnID == nil && matchingTurns.count == 1)) }?.selection
                    let endpoint: PerformanceEvent? = index == 0 ? local.first { $0.kind == .dispatched } : observed.first { $0.messageID == messageIDs[index - 1] }
                    let elapsed = endpoint.flatMap { PerformanceMetrics.elapsedMS(from: $0, to: initial, events: events) }
                    let timing = elapsed.map { (index == 0 ? "Dispatch to observed reply: " : "Previous reply to observed reply: ") + PerformanceMetrics.label($0) } ?? "Timing unavailable (missing endpoint, clock continuity or observation gap)."
                    var message = ComparisonPublication.Message(messageID: "message-\(index + 1)", text: redact(latest.text!), outcome: "observedReply", timingLabel: timing, feedback: options.includeFeedback ? (feedback ?? .unmarked) : nil)
                    message.businessChoices = latest.businessChoices
                    message.businessChoices?.redactText(redact)
                    if options.includesStreamingRevisions && versions.count > 1 {
                        message.revisions = versions.dropLast().map { revision in
                            let interval = endpoint.flatMap { PerformanceMetrics.elapsedMS(from: $0, to: revision, events: events) }
                            var card = revision.businessChoices; card?.redactText(redact)
                            return .init(text: redact(revision.text!), timingLabel: interval.map { "Observed update: " + PerformanceMetrics.label($0) } ?? "Timing unavailable.", businessChoices: card)
                        }
                    }
                    messages.append(message)
                }
                let terminal = local.last { $0.kind == .outcome || $0.kind == .completed }
                let outcome = terminal.map { $0.kind == .completed ? "observedCompletion" : allowedOutcome($0.reason) } ?? (messages.isEmpty ? "unobserved" : "observedReply")
                replies.append(.init(agentID: ids[aid]!, outcome: outcome, messages: messages))
            }
            for aid in declared ?? [] where !group.contains(where: { $0.agent?.id == aid }) {
                replies.append(.init(agentID: ids[aid]!, outcome: "unobserved", messages: []))
            }
            let aligned = first.requestGroupID != nil
            let kind = scope == .unknown ? "unknown" : aligned && group.allSatisfy({ $0.turnPosition == 0 }) ? "initial" : aligned && group.allSatisfy({ ($0.turnPosition ?? 0) > 0 }) ? "followUp" : "unknown"
            p.turns.append(.init(id: "turn-\(p.turns.count + 1)", kind: kind, prompt: redact(first.text!), scope: scope,
                targetedAgentIDs: declared?.compactMap { ids[$0] }, alignmentLabel: scope == .unknown ? "Scope unknown; owner explicitly included this uncertain recording." : aligned ? nil : "Unaligned per-agent recording; request action and target membership were not declared.", replies: replies))
        }
        if omittedPrivate > 0 { p.omissions.append("\(omittedPrivate) private per-agent requests excluded by default.") }
        if omittedUnknown > 0 { p.omissions.append("\(omittedUnknown) unknown or conflicting-scope requests excluded; scope is not permission to publish.") }
        if malformed > 0 { p.omissions.append("\(malformed) requests with ambiguous or malformed association excluded.") }
        let unassigned = events.filter { $0.kind == .replyObserved && !associated.contains($0.id) }.count
        if unassigned > 0 { p.omissions.append("\(unassigned) excluded or unassigned reply observations are not included.") }
        let ambiguousFeedback = events.filter { feedback in
            guard feedback.kind == .feedback, feedback.turnID == nil, let mid = feedback.messageID, let aid = feedback.agent?.id else { return false }
            return Set((eventsByMessage[MessageKey(segment: feedback.segmentID, agent: aid, message: mid)] ?? []).filter { $0.kind == .replyObserved }.compactMap(\.turnID)).count > 1
        }.count
        if ambiguousFeedback > 0 { p.omissions.append("\(ambiguousFeedback) feedback selections with ambiguous message-to-turn association excluded.") }
        if revisions > 0 { p.omissions.append("\(revisions) earlier streaming text revisions omitted; enable observed revisions to include them in the preview.") }
        if events.contains(where: { $0.kind == .gap || $0.reason == "resumed-partial" }) { p.limitations.append("The journal contains gaps or partial recording; this preview cannot establish complete provider history.") }
        return p
    }
    private static func allowedOutcome(_ reason: String?) -> String {
        let allowed = ["observedReply", "observedCompletion", "failed", "canceled", "timeout", "uncertain", "unsupported", "unobserved"]
        return reason.flatMap { allowed.contains($0) ? $0 : nil } ?? "uncertain"
    }
    private static func redact(_ text: String, terms: [String]) -> String {
        var result = text
        // Preserve all untouched whitespace, including code indentation.
        for pattern in [#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, #"(?<!\w)@[A-Z0-9_]+"#, #"(?:/(?:Users|home|Volumes|private|tmp|var|opt|etc|workspace|Applications)/|~/|[A-Z]:\\)[^\s\"<>]+"#, #"\b\d{4}-\d{2}-\d{2}(?:T[0-9:.+Z-]+)?\b"#, #"\b\d{1,2}/\d{1,2}/\d{4}\b"#, #"(?:\+\d{1,3}[ .-]?)?(?:\(\d{3}\)|\b\d{3})[ .-]\d{3}[ .-]\d{4}\b"#] {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "[redacted]")
            }
        }
        for term in Set(terms).sorted(by: { $0.count > $1.count }) where !term.isEmpty {
            let pattern = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: term) + "(?![\\p{L}\\p{N}_])"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "[redacted]")
            }
        }
        return result
    }
}
