import Foundation
public enum ChatResolver {
    public static func normalize(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.contains("@") { return value }
        guard value.allSatisfy({ $0.isNumber || "+()- .".contains($0) }) else { return value }
        return value.filter { $0.isNumber || $0 == "+" }
    }
    // A chosen conversation never falls back to a contact number or a newer thread.
    public static func conversation(agent: Agent, chats: [Chat]) -> Chat? {
        if let destination = agent.destination {
            let matches = chats.filter { destination.matches($0) }
            return matches.count == 1 ? matches[0] : nil
        }
        switch businessMatch(agent: agent, chats: chats) {
        case .matched(let chat): return chat
        case .ambiguous: return nil
        case .absent: return resolve(handles: agent.handles, chats: chats)
        }
    }
    public static func automaticBusinessConversation(agent: Agent, chats: [Chat]) -> Chat? {
        if case .matched(let chat) = businessMatch(agent: agent, chats: chats) { return chat }
        return nil
    }
    private enum BusinessMatch { case absent, ambiguous, matched(Chat) }
    private static func businessMatch(agent: Agent, chats: [Chat]) -> BusinessMatch {
        func brand(_ name: String) -> String {
            name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .components(separatedBy: .alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        }
        guard ["poke", "poke ai", "poke agent"].contains(brand(agent.name)) else { return .absent }
        let matches = chats.filter {
            $0.businessConversation == true && brand($0.displayName ?? "") == "poke"
        }
        // Match only positively identified Business metadata and an exact brand.
        // Different Business identities are ambiguous; never guess from phone numbers.
        guard !matches.isEmpty else { return .absent }
        guard matches.count == 1 || (matches.allSatisfy { !$0.handle.isEmpty } && Set(matches.map(\.handle)).count == 1) else { return .ambiguous }
        return .matched(matches.min { $0.lastActivity == $1.lastActivity ? $0.id < $1.id : $0.lastActivity > $1.lastActivity }!)
    }
    public static func resolve(agent: Agent, chats: [Chat]) -> Chat? {
        guard let chat = conversation(agent: agent, chats: chats), chat.eligible else { return nil }
        return chat
    }
    public static func status(agent: Agent, chats: [Chat]) -> String {
        if agent.destination == nil, case .ambiguous = businessMatch(agent: agent, chats: chats) {
            return "Multiple Business conversations found · sending unavailable"
        }
        if let chat = conversation(agent: agent, chats: chats) {
            if chat.businessConversation == true { return chat.eligible ? "Connected · Business conversation" : "Business conversation found · sending unavailable" }
            return chat.eligible ? "Connected" : "Conversation found · sending unavailable"
        }
        return agent.destination == nil ? "No supported conversation found" : "Saved conversation unavailable · choose again"
    }
    public static func resolve(handles: [String], chats: [Chat]) -> Chat? {
        let normalized = Set(handles.map(normalize))
        let matches = chats.filter { $0.eligible && normalized.contains(normalize($0.handle)) }
        // Contact addresses are alternatives; choose one existing conversation, never broadcast.
        return matches.min { $0.lastActivity == $1.lastActivity ? $0.id < $1.id : $0.lastActivity > $1.lastActivity }
    }
}
public enum ComparisonRange {
    public static func anchorCandidate(messages: [Message], comparison: Comparison, member: Member, comparisons: [Comparison]) -> Message? {
        guard let baseline = member.baseline else { return nil }
        let others = comparisons.filter { $0.id != comparison.id }
        let claimed = Set(others.flatMap(\.members).filter { $0.chat.id == member.chat.id }.compactMap(\.anchor?.guid))
        let attemptedAt = member.attemptedAt ?? comparison.created
        let later = others.flatMap { other in
            other.members.filter { $0.chat.id == member.chat.id && ($0.attemptedAt ?? other.created) > attemptedAt }
        }
        let boundary = later.compactMap(\.baseline).min()
        let candidates = messages.filter {
            $0.id > baseline && (boundary == nil || $0.id <= boundary!) && $0.outgoing && $0.text == comparison.prompt &&
            $0.date >= attemptedAt.addingTimeInterval(-2) && !claimed.contains($0.guid)
        }
        return candidates.count == 1 ? candidates.first : nil
    }
    /// Half an hour with nothing in the chat ends a conversation's hold on a contact. Measured on real
    /// history: about 3 in 100 kept messages are misplaced and 1 in 9 follow-ups goes to the direct thread.
    public static let quietPeriod: TimeInterval = 1_800
    /// The rows a conversation shows for one member: from its start to the next conversation's
    /// send in that chat. With `own`, it also lets go when you message the contact outside
    /// msgblast, or when they write after `quiet` seconds of silence; a later send of its own
    /// takes the chat back. Inline replies to rows it holds always stay.
    public static func messages(_ messages: [Message], anchor: Anchor, next: Int64?, own: OwnSends? = nil, quiet: TimeInterval = quietPeriod) -> [Message] {
        var related: Set<String> = [anchor.guid]
        var selected: [Message] = []
        var holding = true
        var last: Date?
        for message in messages.sorted(by: { $0.id < $1.id }) {
            var inRange = message.id >= anchor.rowID && (next == nil || message.id < next!)
            if inRange, let own {
                if message.outgoing { holding = own.includes(message) }
                else if holding, let last, message.date.timeIntervalSince(last) > quiet { holding = false }
                inRange = holding
            }
            let linked = message.replyTo.map { related.contains($0) } ?? false
            if inRange || linked { selected.append(message); related.insert(message.guid) }
            if inRange { last = message.date }
        }
        return selected
    }
    /// Where a member's rows begin: its anchor, or the row after its baseline while a send
    /// Messages may have accepted has no anchor yet.
    public static func start(of member: Member) -> Anchor? {
        if let anchor = member.anchor { return anchor }
        guard [.submitted, .uncertain].contains(member.submission), let baseline = member.baseline else { return nil }
        return Anchor(rowID: baseline + 1, guid: "")
    }
    public static func transcript(_ history: [Message], comparison: Comparison, member: Member, comparisons: [Comparison]) -> [Message] {
        guard let start = start(of: member) else { return [] }
        let visible = comparison.endedAt == nil ? history : history.filter { comparison.includes($0) }
        if comparison.direct == true {
            let taken = held(history, chatID: member.chat.id, comparisons: comparisons)
            return visible.filter { $0.id >= start.rowID && !taken.contains($0.id) }.sorted { $0.id < $1.id }
        }
        return messages(visible, anchor: start,
                        next: nextAnchor(for: comparison, member: member, comparisons: comparisons), own: OwnSends(comparison: comparison, member: member))
    }
    /// The first row of the next conversation with this contact. A send with no anchor yet
    /// counts from its baseline, so the older conversation never takes its replies.
    public static func nextAnchor(for comparison: Comparison, member: Member, comparisons: [Comparison]) -> Int64? {
        guard comparison.direct != true, let anchor = start(of: member) else { return nil }
        return comparisons.filter { $0.id != comparison.id && $0.direct != true }.flatMap(\.members).filter { $0.chat.id == member.chat.id }
            .compactMap { $0.anchor?.rowID ?? ($0.submission.mayHaveBeenSent ? $0.baseline.map { $0 + 1 } : nil) }.filter { $0 > anchor.rowID }.min()
    }
    /// The rows of one chat that a conversation with a prompt holds.
    static func held(_ history: [Message], chatID: String, comparisons: [Comparison]) -> Set<Int64> {
        var rows: Set<Int64> = []
        for comparison in comparisons where comparison.direct != true {
            for member in comparison.members where member.chat.id == chatID {
                rows.formUnion(transcript(history, comparison: comparison, member: member, comparisons: comparisons).map(\.id))
            }
        }
        return rows
    }
    /// How far back a message may be and still start a direct thread, so old history never turns into threads.
    public static let directWindow: TimeInterval = 7 * 86_400
    /// A new direct thread for a contact who has written when no conversation holds the message.
    /// Nil while the contact's open direct thread exists (it takes the message) or a send is in flight.
    public static func directThread(chatID: String, history: [Message], comparisons: [Comparison], now: Date = Date()) -> Comparison? {
        let all = comparisons.flatMap { comparison in comparison.members.filter { $0.chat.id == chatID }.map { (comparison: comparison, member: $0) } }
        let threads = all.filter { $0.comparison.direct == true }.map { $0.comparison }
        guard !threads.contains(where: { $0.endedAt == nil }), !all.contains(where: { $0.member.submission == .sending }),
              let contact = all.first(where: { $0.comparison.direct != true })?.member,
              let first = all.compactMap({ start(of: $0.member)?.rowID }).min() else { return nil }
        let after = max(first, threads.compactMap { $0.endMessageRows?[chatID] }.max() ?? 0)
        let taken = held(history, chatID: chatID, comparisons: comparisons)
        let free = history.filter { $0.id > after && !taken.contains($0.id) && now.timeIntervalSince($0.date) <= directWindow }.sorted { $0.id < $1.id }
        guard let opening = free.first, free.contains(where: { !$0.outgoing }) else { return nil }
        var member = Member(agentID: contact.agentID, name: contact.name, chat: contact.chat)
        member.submission = .submitted
        member.anchor = Anchor(rowID: opening.id, guid: opening.guid)
        var thread = Comparison(prompt: "", members: [member])
        thread.direct = true
        thread.created = opening.date
        return thread
    }
}
/// What msgblast sent one member of a conversation, to tell its rows from ones you sent in Messages.
public struct OwnSends: Sendable {
    var guids: Set<String> = []
    var texts: Set<String> = []
    /// A send whose row is not identified yet, or a Business chat (its choices are sent by
    /// Messages itself): no sent row is treated as coming from outside msgblast.
    var unresolved = false
    public init(comparison: Comparison, member: Member) {
        let key = member.id.uuidString
        var payloads = [member.payload].compactMap { $0 }
        texts.insert(comparison.prompt)
        if let anchor = member.anchor { guids.insert(anchor.guid) }
        unresolved = member.chat.businessConversation == true || (member.anchor == nil && member.submission.mayHaveBeenSent)
        for followUp in comparison.followUps where followUp.memberIDs.contains(member.id) {
            texts.insert(followUp.text)
            if let payload = followUp.payloads?[key] { payloads.append(payload) }
            if let state = followUp.states[key], state == .sending || state == .uncertain { unresolved = true }
        }
        for part in payloads.flatMap(\.parts) {
            if let anchor = part.anchor { guids.insert(anchor.guid) }
            else if part.state.mayHaveBeenSent { unresolved = true }
        }
        texts.remove("")
    }
    func includes(_ message: Message) -> Bool { unresolved || guids.contains(message.guid) || texts.contains(message.text) }
}
public enum RecipientSet {
    public static func validate(_ members: [Member]) throws {
        var destinations: [String: String] = [:]
        for member in members {
            if let name = destinations[member.chat.id] {
                throw AppFailure.blocked("\(name) and \(member.name) share the same destination. Select one before sending.")
            }
            destinations[member.chat.id] = member.name
        }
    }
}
public enum WindowLayout {
    public static func chatWindowWidth(count: Int, surroundingWidth: Double, screenWidth: Double) -> Double {
        min(screenWidth, max(760, surroundingWidth + Double(max(1, count)) * 390 + Double(max(0, count - 1))))
    }

    public static func columns(count: Int, screenWidth: Double, screenHeight: Double) -> [SavedFrame] {
        let width = max(320, min(390, (screenWidth - 40) / Double(max(1, min(count, 3))) - 12))
        return (0..<count).map { SavedFrame(x: 20 + Double($0) * (width + 12), y: 320, width: width, height: max(400, screenHeight - 355)) }
    }
}
public enum AppFailure: LocalizedError {
    case blocked(String)
    public var errorDescription: String? { switch self { case .blocked(let text): text } }
}
