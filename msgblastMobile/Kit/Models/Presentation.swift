import Foundation
import msgblastRemoteProtocol

/// One glanceable line and, when the Mac said more, the full reason shown on demand.
public struct StatusLine: Equatable, Sendable {
    public var text: String
    public var detail: String?
    public init(_ text: String, detail: String? = nil) { self.text = text; self.detail = detail == text ? nil : detail }
}

/// What stops the compose bar from sending.
public enum ComposeBlock: Equatable, Sendable {
    /// Disconnected, locked, not ready in the projection: Send is disabled.
    case blocked(String, detail: String? = nil)
    /// The last `prepareConversation` was refused. Send stays enabled and prepares again.
    case prepareFailed(String, detail: String? = nil)
    public var text: String { switch self { case .blocked(let text, _), .prepareFailed(let text, _): text } }
    /// The Mac's longer reason, for the compose bar's info popover.
    public var detail: String? { switch self { case .blocked(_, let detail), .prepareFailed(_, let detail): detail } }
    public var allowsSend: Bool { if case .prepareFailed = self { true } else { false } }
}

/// How a status chip under one of your messages reads, per agent.
public enum ChipState: String, Equatable, Sendable {
    case sending = "Sending"
    case sent = "Sent"
    case replied = "Replied"
    case notSent = "Not sent"
    case unconfirmed = "Unconfirmed"

    public init(_ status: RemoteAttemptStatus) {
        switch status {
        case .preparing, .attempting, .sending, .ready: self = .sending
        case .waiting, .submitted: self = .sent
        case .observed: self = .replied
        case .notSent, .failed, .dismissed: self = .notSent
        case .uncertain: self = .unconfirmed
        }
    }

    public var symbol: String {
        switch self { case .sending: "clock"; case .sent: "checkmark"; case .replied: "checkmark.bubble"; case .notSent: "xmark.circle"; case .unconfirmed: "questionmark.circle" }
    }
}

public struct StatusChip: Equatable, Identifiable, Sendable {
    public var id: String { agentID }
    public var agentID: String
    public var agentName: String
    public var state: ChipState
    public var reason: String?
    /// "Sent", or "Muse · Sent" when several agents' chips share a message. The separator
    /// is held by non-breaking spaces so a wrapped line never starts with it.
    public func label(showsName: Bool) -> String { showsName ? "\(agentName)\u{00A0}·\u{00A0}\(state.rawValue)" : state.rawValue }
}

/// The compact notice for an app, CLI or bot request that has not finished.
public struct IncompleteSummary: Equatable, Sendable, Identifiable {
    public var id: String { agentID }
    public var agentID: String
    /// Still running on the Mac: the row offers Stop. Otherwise it needs review: Dismiss.
    public var running: Bool
    public var title: String
    /// The Mac's full text, for the details sheet.
    public var details: [String]
    public var started: Date?
}

public struct InboxRow: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var agentNames: [String]
    public var agentIDs: [String]
    public var preview: String
    public var lastActivity: Date
    public var unconfirmed: Int
    public var ended: Bool
    public var isDirect: Bool { agentIDs.count == 1 }
}

/// Readable views of the projection for the screens. Histories of different forms of one
/// product are never merged: each agent id is its own thread.
public struct ProjectionPresenter: Sendable {
    public let state: ProjectionState
    public let commands: [UUID: CommandRecord]
    public init(state: ProjectionState, commands: [UUID: CommandRecord] = [:]) { self.state = state; self.commands = commands }

    public func name(_ agentID: String) -> String { state.agents[agentID]?.formLabel ?? agentID }
    public func shortName(_ agentID: String) -> String { state.agents[agentID]?.displayName ?? agentID }

    public var inbox: [InboxRow] {
        state.sortedConversations.map { conversation in
            let reply = state.turns(in: conversation.id).last { $0.role == .assistant }
            let unconfirmedCommands = commands.values.filter { $0.conversationID == conversation.id && $0.status == .unconfirmed }.count
            return InboxRow(id: conversation.id, title: conversation.title, agentNames: conversation.agentIDs.map(shortName), agentIDs: conversation.agentIDs,
                            // A direct row already shows the agent; only group previews name who replied.
                            preview: reply.map { conversation.agentIDs.count == 1 ? $0.text : "\(shortName($0.agentID ?? "")): \($0.text)" } ?? conversation.prompt, lastActivity: conversation.lastActivity,
                            unconfirmed: conversation.unresolvedAttemptCount + unconfirmedCommands, ended: conversation.endedAt != nil)
        }
    }

    /// `agentID == nil` is the All view: your messages and every agent's replies.
    public func turns(in conversation: UUID, agentID: String?) -> [RemoteTurn] {
        let all = state.turns(in: conversation)
        guard let agentID else {
            // In All, an agent's own copy of your shared prompt is not repeated.
            return all.filter { !($0.origin == .agentTranscript && $0.role == .user) }
        }
        return all.filter { $0.agentID == agentID || ($0.agentID == nil && $0.origin == .sharedPrompt) }
    }

    /// Chips for one of your turns: the matching attempt for each agent.
    /// `agentID` is the conversation's one-agent filter: only that agent's chip is shown.
    public func chips(for turn: RemoteTurn, agentID filter: String? = nil) -> [StatusChip] {
        guard turn.role == .user else { return [] }
        let attempts = state.attempts(in: turn.conversationID).filter {
            $0.text == turn.text && (turn.agentID == nil || $0.agentID == turn.agentID) && (filter == nil || $0.agentID == filter)
        }
        var latest: [String: RemoteAttempt] = [:]
        for attempt in attempts where latest[attempt.agentID].map({ ($0.created ?? .distantPast) <= (attempt.created ?? .distantPast) }) ?? true { latest[attempt.agentID] = attempt }
        let replies = state.turns(in: turn.conversationID).filter { $0.role == .assistant }
        return latest.values.sorted { $0.agentID < $1.agentID }.map { attempt in
            var chip = ChipState(attempt.status)
            // A Messages send stays "submitted"; a reply after it means the agent answered.
            if chip == .sent, replies.contains(where: { $0.agentID == attempt.agentID && ($0.created ?? .distantPast) >= (turn.created ?? .distantFuture) }) { chip = .replied }
            return StatusChip(agentID: attempt.agentID, agentName: shortName(attempt.agentID), state: chip, reason: attempt.detail)
        }
    }

    /// Why sending to these agents is not possible now, in the Mac's words; nil when it is.
    public func disabledReason(agentIDs: [String], conversation: UUID?) -> String? { disabledLine(agentIDs: agentIDs, conversation: conversation)?.text }

    /// `disabledReason` with the Mac's longer reason as detail.
    public func disabledLine(agentIDs: [String], conversation: UUID?) -> StatusLine? {
        guard !agentIDs.isEmpty else { return StatusLine("Choose who to send to") }
        if state.macLocked { return StatusLine("Mac locked") }
        for id in agentIDs {
            guard let agent = state.agents[id] else { return StatusLine("\(id) is gone from your Mac") }
            if !agent.readiness.acceptsSend {
                if let reason = agent.reasons.first { return StatusLine(reason.userText, detail: reason.detail) }
                if case .busy(let detail) = agent.readiness, !detail.isEmpty { return StatusLine(detail) }
                return StatusLine("\(agent.displayName) isn't ready")
            }
            if let conversation, let incomplete = state.conversations[conversation]?.incompleteAttempts.first(where: { $0.agentID == id }) {
                return StatusLine("Finish the \(agent.displayName) request first", detail: incompleteSummary(incomplete).details.joined(separator: "\n\n").nilIfEmpty)
            }
        }
        return nil
    }

    /// "Waiting for Muse…" while the request runs, "Muse didn't reply" once it needs review.
    public func incompleteSummary(_ incomplete: RemoteIncompleteAttempt) -> IncompleteSummary {
        let attempt = state.attempts[incomplete.attemptID]
        let running = attempt.map { [.attempting, .preparing].contains($0.status) } ?? false
        let name = shortName(incomplete.agentID)
        let reason = state.agents[incomplete.agentID]?.reasons.first { $0.code == .incompleteRequestBlocking }
        var details: [String] = []
        if let text = attempt?.detail, !text.isEmpty { details.append(text) }
        if let text = reason?.detail, !text.isEmpty, !details.contains(text) { details.append(text) }
        return IncompleteSummary(agentID: incomplete.agentID, running: running, title: running ? "Waiting for \(name)…" : "\(name) didn't reply",
                                 details: details, started: attempt?.created)
    }

    /// "To everyone", "Only Muse", "To 2 agents".
    public func recipientSummary(_ recipients: [String], members: [String]) -> String {
        if Set(recipients) == Set(members) { return "To everyone" }
        if recipients.count == 1 { return "Only \(shortName(recipients[0]))" }
        return recipients.isEmpty ? "Choose who to send to" : "To \(recipients.count) agents"
    }

    /// Why the compose bar cannot send right now, and whether Send may still be tapped.
    /// Disconnection and the projection's own reasons block Send. A failed
    /// `prepareConversation` only shows its reason: tapping Send prepares again first.
    public func composeBlock(canSend: Bool, connectionText: String, agentIDs: [String], conversation: UUID?,
                             prepareReasons: [String: String]) -> ComposeBlock? {
        if !canSend { return .blocked(connectionText) }
        if let line = disabledLine(agentIDs: agentIDs, conversation: conversation) { return .blocked(line.text, detail: line.detail) }
        if let first = prepareReasons.sorted(by: { $0.key < $1.key }).first {
            guard !first.key.isEmpty else { return .prepareFailed(first.value) }
            let name = shortName(first.key)
            // The Mac's line often names the agent already; never say it twice.
            let text = first.value.hasPrefix(name) ? first.value : "\(name): \(first.value)"
            let detail = state.agents[first.key]?.reasons.compactMap(\.detail).first
            return .prepareFailed(text, detail: detail)
        }
        return nil
    }

    /// Whether the agents whose prepare failed can now accept a send, so the prepare runs
    /// again by itself (for example a Mac app that finished updating its controls).
    public func shouldRetryPrepare(prepareReasons: [String: String], agentIDs: [String]) -> Bool {
        guard !prepareReasons.isEmpty else { return false }
        let failed = prepareReasons.keys.filter { !$0.isEmpty }
        let ids = failed.isEmpty ? agentIDs : failed
        return !ids.isEmpty && ids.allSatisfy { state.agents[$0]?.readiness.acceptsSend == true }
    }

    /// The readiness of each recipient, so a view can notice when one changes.
    public func readiness(agentIDs: [String]) -> [AgentReadiness?] { agentIDs.map { state.agents[$0]?.readiness } }

    /// "Opens ChatGPT on your Mac" for agents whose send launches a Mac app.
    public func launchNotes(agentIDs: [String]) -> [String] {
        agentIDs.compactMap { state.agents[$0] }.filter { $0.readiness == .readyWillLaunch }.map { "Opens \($0.displayName) on your Mac" }
    }

    /// The short status under an agent in the new-conversation list; nil when there is nothing to say.
    /// The row already shows the agent's name, so a launch reads "Opens on your Mac".
    public static func agentStatus(_ agent: AgentAvailability) -> String? {
        switch agent.readiness {
        case .ready: agent.reasons.first(where: { $0.fixOn == .mac })?.userText
        case .readyWillLaunch: "Opens on your Mac"
        case .busy: "Busy"
        case .blocked, .unavailable: agent.reasons.first?.userText
        }
    }

    /// Like Messages: the time today, "Yesterday", the weekday this week, else a short date.
    public static func inboxTimestamp(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        var calendar = calendar
        calendar.locale = locale
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? .max
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        switch days {
        case ...0: style = style.hour().minute()
        case 1: return "Yesterday"
        case 2..<7: style = style.weekday(.wide)
        default: style = style.year(.twoDigits).month(.defaultDigits).day(.defaultDigits)
        }
        return date.formatted(style)
    }

    /// The new-conversation list: one flat list in the Mac's grid order, with Messages
    /// contacts apart. Agents outside the grid follow, unless they are unavailable.
    public var newConversationAgents: (agents: [AgentAvailability], messages: [AgentAvailability]) {
        let visible = state.grid.compactMap { state.agents[$0] }
        let rest = state.orderedAgents.filter { !state.grid.contains($0.agentID) && $0.readiness != .unavailable }
        let all = visible + rest
        return (all.filter { $0.form != .messages }, all.filter { $0.form == .messages })
    }

    public static func formLabel(_ form: AgentForm) -> String {
        switch form { case .macApp: "Mac app"; case .website: "Web"; case .cli: "CLI"; case .webhookBot: "Bot"; case .messages: "Messages" }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
