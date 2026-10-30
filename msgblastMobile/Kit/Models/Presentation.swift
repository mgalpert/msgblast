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
    /// A reply arrived after the conversation was last opened on this phone.
    public var unread: Bool = false
    /// The latest message is your own, so the preview is yours (Messages marks it with a reply glyph).
    public var fromYou: Bool = false
    public var isDirect: Bool { agentIDs.count == 1 }
}

/// Readable views of the projection for the screens. Histories of different forms of one
/// product are never merged: each agent id is its own thread.
public struct ProjectionPresenter: Sendable {
    public let state: ProjectionState
    public let commands: [UUID: CommandRecord]
    /// When each conversation was last opened on this phone, and when unread tracking began.
    public let lastOpened: [UUID: Date]
    public let unreadSince: Date?
    /// Replies made from this phone: command id → quoted turn id.
    public let replyTo: [UUID: String]
    public init(state: ProjectionState, commands: [UUID: CommandRecord] = [:], lastOpened: [UUID: Date] = [:], unreadSince: Date? = nil, replyTo: [UUID: String] = [:]) {
        self.state = state; self.commands = commands; self.lastOpened = lastOpened; self.unreadSince = unreadSince; self.replyTo = replyTo
    }

    /// The response one of your turns replied to: a reply is a private send to that agent,
    /// so the turn is that agent's, with the reply's text, sent no earlier than the command.
    /// Never another agent's turn.
    public func quotedTurn(for turn: RemoteTurn) -> RemoteTurn? {
        guard turn.role == .user, let agent = turn.agentID else { return nil }
        let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
        for (command, quotedID) in replyTo.sorted(by: { $0.value < $1.value }) {
            guard let record = commands[command], let quoted = state.turns[quotedID], quoted.agentID == agent,
                  quoted.conversationID == turn.conversationID, record.agentIDs == [agent],
                  record.conversationID == nil || record.conversationID == turn.conversationID,
                  record.text?.trimmingCharacters(in: .whitespacesAndNewlines) == text else { continue }
            if let created = turn.created, created < record.sentAt.addingTimeInterval(-300) { continue }
            return quoted
        }
        return nil
    }

    public func name(_ agentID: String) -> String { state.agents[agentID]?.formLabel ?? agentID }

    /// The caption above an incoming run in a group: the agent's name, with its form
    /// ("Claude · Web") only when another form of the same product is in the conversation.
    public func senderLabel(_ agentID: String, in conversation: UUID) -> String {
        guard let agent = state.agents[agentID] else { return agentID }
        let members = state.conversations[conversation]?.agentIDs ?? []
        let twin = members.contains { $0 != agentID && state.agents[$0]?.product == agent.product }
        return twin ? agent.formLabel : agent.displayName
    }
    public func shortName(_ agentID: String) -> String { state.agents[agentID]?.displayName ?? agentID }

    /// One list, newest activity first like Messages, groups, direct agents and Messages contacts
    /// together. The phone sorts by recency itself: the Mac's activity time, the newest turn it has
    /// seen, or the phone's own latest send, so a reply or a send moves the row to the top at once.
    public var inbox: [InboxRow] {
        let latestSend = Dictionary(commands.values.compactMap { record in record.conversationID.map { ($0, record.sentAt) } }, uniquingKeysWith: max)
        return state.conversations.values.map { conversation in
            let turns = state.turns(in: conversation.id)
            let reply = turns.last { $0.role == .assistant }
            // Your own message when it is the newest; otherwise the latest reply, or the prompt.
            let yours = turns.last.flatMap { $0.role == .user && !$0.text.isEmpty ? $0 : nil }
            let activity = [conversation.lastActivity, turns.compactMap(\.created).max(), latestSend[conversation.id]].compactMap { $0 }.max() ?? conversation.lastActivity
            let unconfirmedCommands = commands.values.filter { $0.conversationID == conversation.id && $0.status == .unconfirmed }.count
            return InboxRow(id: conversation.id, title: conversation.title, agentNames: conversation.agentIDs.map(shortName), agentIDs: conversation.agentIDs,
                            // A direct row already shows the agent; only group previews name who replied.
                            preview: yours?.text ?? reply.map { conversation.agentIDs.count == 1 ? $0.text : "\(shortName($0.agentID ?? "")): \($0.text)" } ?? conversation.prompt, lastActivity: activity,
                            unconfirmed: conversation.unresolvedAttemptCount + unconfirmedCommands, ended: conversation.endedAt != nil,
                            unread: isUnread(conversation.id, latestReply: reply?.created), fromYou: yours != nil)
        }
        .sorted { ($0.lastActivity, $1.id.uuidString) > ($1.lastActivity, $0.id.uuidString) }
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

    /// The prompt that formed a group, for the pinned row: the conversation's first turn
    /// when it is the shared prompt. Nil for direct threads, for a filtered view that does
    /// not start with it, and when there is no shared prompt.
    public func pinnedPrompt(for conversation: UUID, agentID filter: String? = nil) -> RemoteTurn? {
        guard (state.conversations[conversation]?.agentIDs.count ?? 0) > 1,
              let first = turns(in: conversation, agentID: filter).first,
              first.role == .user, first.origin == .sharedPrompt, !first.text.isEmpty else { return nil }
        return first
    }

    /// Like Messages: a reply newer than the last time this phone opened the conversation
    /// (or than when tracking began, so a fresh pairing does not mark everything unread).
    public func isUnread(_ conversation: UUID, latestReply: Date?) -> Bool {
        guard let latestReply else { return false }
        let seen = [lastOpened[conversation], unreadSince].compactMap { $0 }.max() ?? .distantPast
        return latestReply > seen
    }

    /// Which chips a turn shows, as Messages shows delivery only where it matters: all of
    /// them under your latest message or one you tapped, else only Not sent and Unconfirmed.
    public func visibleChips(for turn: RemoteTurn, agentID filter: String? = nil, isLatest: Bool, expanded: Bool) -> [StatusChip] {
        let all = chips(for: turn, agentID: filter)
        return isLatest || expanded ? all : all.filter { $0.state == .notSent || $0.state == .unconfirmed }
    }

    /// Agents whose request was submitted and has no reply yet: the conversation shows them
    /// typing. `filter` limits it to one agent's thread.
    public func typingAgents(in conversation: UUID, agentID filter: String? = nil) -> [String] {
        let replies = state.turns(in: conversation).filter { $0.role == .assistant }
        let waiting = state.attempts(in: conversation).filter { [.waiting, .submitted].contains($0.status) && (filter == nil || $0.agentID == filter) }
        let latest = Dictionary(grouping: state.attempts(in: conversation), by: \.agentID).compactMapValues { $0.max { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) } }
        return Set(waiting.filter { attempt in
            latest[attempt.agentID]?.id == attempt.id &&
                !replies.contains { $0.agentID == attempt.agentID && ($0.created ?? .distantPast) >= (attempt.created ?? .distantFuture) }
        }.map(\.agentID)).sorted()
    }

    /// Messages' separators: "Today 10:54 AM", "Yesterday 7:34 PM", "Thu, Oct 22 at 7:34 PM",
    /// and "Thu, Oct 22, 2025 at 7:34 PM" for another year. Shown above a turn that starts the
    /// conversation or follows the previous one by more than an hour; else nil.
    public static func timeHeader(_ date: Date, previous: Date?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String? {
        if let previous, date.timeIntervalSince(previous) <= 3600 { return nil }
        var calendar = calendar
        calendar.locale = locale
        let time = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).hour().minute())
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday \(time)" }
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated).month(.abbreviated).day()
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) { style = style.year() }
        return "\(date.formatted(style)) at \(time)"
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

    // MARK: Selection: the header cluster is both the thread's filter and its recipients.

    /// Who a group's selection sends to and shows: empty means everyone.
    public static func recipients(selection: Set<String>, members: [String]) -> [String] {
        selection.isEmpty ? members : members.filter(selection.contains)
    }

    /// The send for these recipients: one agent of a group is private, everyone is a shared
    /// send to all, a subset a shared send to those agents (as the recipient chips did).
    public static func sendAction(conversationID: UUID?, members: [String], recipients: [String], text: String, attachmentIDs: [String]) -> RemoteAction {
        guard let conversationID else {
            return recipients.count == 1 ? .sendPrivate(conversationID: nil, agentID: recipients[0], text: text, attachmentIDs: attachmentIDs)
                : .createConversation(text: text, agentIDs: recipients, attachmentIDs: attachmentIDs)
        }
        if recipients.count == 1 && members.count > 1 { return .sendPrivate(conversationID: conversationID, agentID: recipients[0], text: text, attachmentIDs: attachmentIDs) }
        if Set(recipients) == Set(members) { return .sendShared(conversationID: conversationID, text: text, agentIDs: [], attachmentIDs: attachmentIDs) }
        return .sendShared(conversationID: conversationID, text: text, agentIDs: recipients, attachmentIDs: attachmentIDs)
    }

    /// Whether Details checks an agent: everyone in All (an empty selection), else the chosen.
    public static func isChecked(_ agent: String, selection: Set<String>) -> Bool { selection.isEmpty || selection.contains(agent) }

    /// Details' checkmark toggle. From All, unchecking one leaves the others; unchecking the
    /// last checked agent, or checking the last missing one, returns to All.
    public static func toggling(_ agent: String, selection: Set<String>, members: [String]) -> Set<String> {
        var next = selection.isEmpty ? Set(members) : selection
        if next.contains(agent) { next.remove(agent) } else { next.insert(agent) }
        return next.isEmpty || next == Set(members) ? [] : next
    }

    /// "Message Claude" for one recipient, else "Message".
    public func placeholder(recipients: [String]) -> String { recipients.count == 1 ? "Message \(shortName(recipients[0]))" : "Message" }

    /// The header pill: "3 Agents", "Claude", "Claude & Muse", "3 of 5".
    public func selectionTitle(_ selection: Set<String>, members: [String]) -> String {
        let chosen = members.filter(selection.contains)
        switch chosen.count {
        case 0, members.count: return "\(members.count) Agents"
        case 1: return shortName(chosen[0])
        case 2: return "\(shortName(chosen[0])) & \(shortName(chosen[1]))"
        default: return "\(chosen.count) of \(members.count)"
        }
    }

    /// The turns a selection shows: All, one agent's private view, or the union of several.
    public func turns(in conversation: UUID, selection: Set<String>) -> [RemoteTurn] {
        if selection.count == 1, let only = selection.first { return turns(in: conversation, agentID: only) }
        let all = turns(in: conversation, agentID: nil)
        return selection.isEmpty ? all : all.filter { $0.agentID.map(selection.contains) ?? true }
    }
    public func visibleChips(for turn: RemoteTurn, selection: Set<String>, isLatest: Bool, expanded: Bool) -> [StatusChip] {
        let single = selection.count == 1 ? selection.first : nil
        return visibleChips(for: turn, agentID: single, isLatest: isLatest, expanded: expanded).filter { selection.isEmpty || selection.contains($0.agentID) }
    }
    public func chips(for turn: RemoteTurn, selection: Set<String>) -> [StatusChip] {
        chips(for: turn, agentID: selection.count == 1 ? selection.first : nil).filter { selection.isEmpty || selection.contains($0.agentID) }
    }
    public func typingAgents(in conversation: UUID, selection: Set<String>) -> [String] {
        typingAgents(in: conversation).filter { selection.isEmpty || selection.contains($0) }
    }
    public func pinnedPrompt(for conversation: UUID, selection: Set<String>) -> RemoteTurn? {
        guard (state.conversations[conversation]?.agentIDs.count ?? 0) > 1, let first = turns(in: conversation, selection: selection).first,
              first.role == .user, first.origin == .sharedPrompt, !first.text.isEmpty else { return nil }
        return first
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
