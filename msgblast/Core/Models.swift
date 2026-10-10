import Foundation

public struct Chat: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var handle: String
    public var lastActivity: Int64
    public var participantCount: Int
    public var service: String
    public init(id: String, handle: String, lastActivity: Int64, participantCount: Int = 1, service: String = "iMessage") {
        self.id = id; self.handle = handle; self.lastActivity = lastActivity; self.participantCount = participantCount; self.service = service
    }
    public var eligible: Bool { participantCount == 1 && service == "iMessage" }
}
public struct Agent: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var contactID: String?
    public var name: String
    public var handles: [String]
    public var avatar: Data?
    public var colorIndex: Int
    public init(contactID: String? = nil, name: String, handles: [String], avatar: Data? = nil, colorIndex: Int = 0) {
        self.contactID = contactID; self.name = name; self.handles = handles; self.avatar = avatar; self.colorIndex = colorIndex
    }
    public static func manualAccount(for query: String) -> Agent? {
        let handle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if handle.contains("@") {
            let parts = handle.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }), !handle.contains(where: \.isWhitespace) else { return nil }
        } else {
            guard handle.filter(\.isNumber).count >= 5,
                  handle.allSatisfy({ $0.isNumber || "+()- .".contains($0) }) else { return nil }
        }
        return Agent(name: handle, handles: [handle])
    }
}
public struct Anchor: Codable, Hashable, Sendable {
    public var rowID: Int64
    public var guid: String
    public init(rowID: Int64, guid: String) { self.rowID = rowID; self.guid = guid }
}
public struct MessageReaction: Identifiable, Hashable, Sendable {
    public var id: String
    public var emoji: String
    public var outgoing: Bool
    public init(id: String, emoji: String, outgoing: Bool) {
        self.id = id; self.emoji = emoji; self.outgoing = outgoing
    }
}
// History delivery is separate from acceptance of the send Apple Event.
public enum MessageDelivery: Sendable, Hashable {
    case unknown, delivered, failed
}
public struct Message: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var guid: String
    public var chatID: String
    public var text: String
    public var outgoing: Bool
    public var replyTo: String?
    public var date: Date
    public var reactions: [MessageReaction]
    public var attachments: [MessageAttachment]
    public var delivery: MessageDelivery
    public var linkPreview: (url: URL, remainingText: String)? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        guard let match = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .first(where: { ["http", "https"].contains($0.url?.scheme?.lowercased() ?? "") }),
              let url = match.url, let range = Range(match.range, in: text) else { return nil }
        var body = text
        body.removeSubrange(range)
        return (url, body.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    public init(id: Int64, guid: String, chatID: String, text: String, outgoing: Bool, replyTo: String? = nil, date: Date = Date(), reactions: [MessageReaction] = [], attachments: [MessageAttachment] = [], delivery: MessageDelivery = .unknown) {
        self.id = id; self.guid = guid; self.chatID = chatID; self.text = text; self.outgoing = outgoing; self.replyTo = replyTo; self.date = date; self.reactions = reactions
        self.attachments = attachments
        self.delivery = delivery
    }
}
public enum Submission: String, Codable, Sendable {
    case ready, sending, submitted, failed, uncertain
    public var canRetry: Bool { self == .failed }
    public static func failure(afterAttempt: Bool, error: Error) -> Submission {
        if case SendFailure.notSubmitted = error { return .failed }
        return afterAttempt ? .uncertain : .failed
    }
    public var label: String {
        switch self { case .ready: "Ready"; case .sending: "Submitting…"; case .submitted: "Submitted to Messages"; case .failed: "Failed · retry available"; case .uncertain: "Needs reconciliation · no resend" }
    }
}
public enum SendFailure: LocalizedError {
    case notSubmitted(String), ambiguous(String)
    public var errorDescription: String? {
        switch self { case .notSubmitted(let text), .ambiguous(let text): text }
    }
}
public struct Member: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID { agentID }
    public var agentID: UUID
    public var name: String
    public var chat: Chat
    public var submission: Submission = .ready
    public var anchor: Anchor?
    public var error: String?
    public var baseline: Int64?
    public var attemptedAt: Date?
    public var payload: OutgoingPayload?
    public init(agentID: UUID, name: String, chat: Chat) { self.agentID = agentID; self.name = name; self.chat = chat }
    public mutating func apply(_ payload: OutgoingPayload) {
        self.payload = payload; submission = payload.submission; anchor = payload.anchor; error = payload.error
        baseline = payload.parts.first?.baseline; attemptedAt = payload.parts.first?.attemptedAt
    }
}
public struct FollowUp: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var text: String
    public var sharedWithAll: Bool?
    public var memberIDs: [UUID]
    public var states: [String: Submission] = [:]
    public var errors: [String: String] = [:]
    public var created = Date()
    public var payloads: [String: OutgoingPayload]?
    public init(text: String, memberIDs: [UUID]) { self.text = text; self.memberIDs = memberIDs }
    public mutating func apply(_ payload: OutgoingPayload, for key: String) {
        if payloads == nil { payloads = [:] }
        payloads?[key] = payload; states[key] = payload.submission; errors[key] = payload.error
    }
    public func recipientsForRecovery(resumeUnsent: Bool) -> [UUID] {
        memberIDs.filter { states[$0.uuidString] == (resumeUnsent ? .ready : .failed) }
    }
}
public struct ConversationRecipients: Codable, Equatable, Sendable {
    public var selectedConversation: UUID?
    public var excluded: Set<UUID> = []
    public init() {}
    public mutating func selectConversation(_ id: UUID) {
        selectedConversation = id
    }
    public mutating func toggleRecipient(_ id: UUID, in members: [Member]) {
        guard members.contains(where: { $0.id == id }) else { return }
        var recipients = Set(recipientIDs(in: members))
        if recipients.contains(id) { recipients.remove(id) } else { recipients.insert(id) }
        selectedConversation = nil
        excluded = Set(members.map(\.id)).subtracting(recipients)
    }
    public func recipientIDs(in members: [Member]) -> [UUID] {
        members.filter { member in
            selectedConversation.map { $0 == member.id } ?? !excluded.contains(member.id)
        }.map(\.id)
    }
}
public struct ConversationContextMessage: Codable, Equatable, Sendable {
    public var followUpID: UUID?
    public var text: String
    public var attachments: [MessageAttachment]
    public var sharedWithAll: Bool?
    public var created: Date?
    public init(text: String, attachments: [MessageAttachment] = [], followUpID: UUID? = nil, created: Date = Date()) {
        self.followUpID = followUpID; self.text = text; self.attachments = attachments
        sharedWithAll = true; self.created = created
    }
}
public struct Comparison: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var prompt: String
    public var created = Date()
    public var members: [Member]
    public var followUps: [FollowUp] = []
    public var sharedContext: [ConversationContextMessage]?
    public var allDraft: String = ""
    public var privateDrafts: [String: String] = [:]
    public var attachments: [MessageAttachment]?
    public var allAttachmentsDraft: [MessageAttachment]?
    public var privateAttachmentDrafts: [String: [MessageAttachment]]?
    public var recipientSelection: ConversationRecipients?
    public var summary: ComparisonSummary?
    public var webProviders: [WebProvider]?
    public var webProviderIdentityVersion: Int?
    public init(prompt: String, members: [Member]) { self.prompt = prompt; self.members = members; webProviderIdentityVersion = 2; sharedContext = [] }
    public mutating func completeSharedBroadcast(followUpID: UUID, recipients: Set<UUID>) {
        guard !recipients.isEmpty, let index = followUps.firstIndex(where: { $0.id == followUpID }),
              Set(followUps[index].memberIDs) == recipients else { return }
        followUps[index].sharedWithAll = true
        recordSharedFollowUp(followUps[index])
    }
    public mutating func recordSharedMessage(_ message: ConversationContextMessage) {
        guard message.sharedWithAll == true else { return }
        var context = Array(joiningContext().dropFirst())
        if message.followUpID == nil || !context.contains(where: { $0.followUpID == message.followUpID }) {
            context.append(message)
        }
        sharedContext = context.sorted { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }
    }
    public mutating func recordSharedFollowUp(_ followUp: FollowUp) {
        guard followUp.sharedWithAll == true, !followUp.memberIDs.isEmpty,
              followUp.memberIDs.allSatisfy({ followUp.states[$0.uuidString] == .submitted }) else { return }
        let files = followUp.payloads?.values.first?.parts.compactMap(\.attachment) ?? []
        recordSharedMessage(ConversationContextMessage(text: followUp.text, attachments: files, followUpID: followUp.id, created: followUp.created))
    }
    public func joiningContext() -> [ConversationContextMessage] {
        let original = ConversationContextMessage(text: prompt, attachments: attachments ?? [], created: created)
        // Unknown legacy scope is not permission to share a private message.
        var context = (sharedContext ?? []).filter { $0.sharedWithAll == true }
        for followUp in followUps where followUp.sharedWithAll == true && !followUp.memberIDs.isEmpty {
            guard followUp.memberIDs.allSatisfy({ followUp.states[$0.uuidString] == .submitted }),
                  !context.contains(where: { $0.followUpID == followUp.id }) else { continue }
            let files = followUp.payloads?.values.first?.parts.compactMap(\.attachment) ?? []
            context.append(ConversationContextMessage(text: followUp.text, attachments: files, followUpID: followUp.id, created: followUp.created))
        }
        return [original] + context.sorted { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }
    }
    public func joiningPayload() -> OutgoingPayload {
        var payload = OutgoingPayload(text: "", attachments: [])
        payload.parts = joiningContext().flatMap { OutgoingPayload(text: $0.text, attachments: $0.attachments).parts }
        return payload
    }
    public func joiningPrompt() -> String {
        joiningContext().map(\.text).joined(separator: "\n\n")
    }
    public var title: String { String((prompt.isEmpty ? attachments?.map(\.filename).joined(separator: ", ") ?? "Attachment" : prompt).prefix(65)) }
}
public struct SavedFrame: Codable, Sendable { public var x: Double; public var y: Double; public var width: Double; public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
}
public enum ComparisonWindowStyle: String, Codable, CaseIterable, Sendable {
    case connected, separate
}
public struct AppState: Codable, Sendable {
    public var version = 1
    public var agents: [Agent] = []
    public var comparisons: [Comparison] = []
    public var draft: String = ""
    public var workspaceDrafts: [String: String]?
    public var attachmentsDraft: [MessageAttachment]?
    public var selection: Set<UUID> = []
    public var frames: [String: SavedFrame] = [:]
    public var windowStyle: ComparisonWindowStyle?
    public var personalAgentProvider: String?
    public var onboarding: OnboardingState?
    public var agentGrid: AgentGridLayout?
    public var effectiveWindowStyle: ComparisonWindowStyle { windowStyle ?? .connected }
    public init() {}
    @discardableResult
    public mutating func retainAvailableSelection(chats: [Chat]) -> Bool {
        let available = Set(agents.filter { ChatResolver.resolve(handles: $0.handles, chats: chats) != nil }.map(\.id))
        let retained = selection.intersection(available)
        guard retained != selection else { return false }
        selection = retained
        return true
    }
    public func recoveringInFlight() -> AppState {
        var result = self
        for i in result.comparisons.indices {
            for j in result.comparisons[i].members.indices {
                if let payload = result.comparisons[i].members[j].payload {
                    result.comparisons[i].members[j].apply(payload.recoveringInFlight())
                }
            }
            for j in result.comparisons[i].members.indices where result.comparisons[i].members[j].submission == .sending {
                result.comparisons[i].members[j].submission = .uncertain
                result.comparisons[i].members[j].error = "The app stopped during submission. Refresh to reconcile; do not resend blindly."
            }
            for k in result.comparisons[i].followUps.indices {
                if let payloads = result.comparisons[i].followUps[k].payloads {
                    for (key, payload) in payloads {
                        let recovered = payload.recoveringInFlight()
                        result.comparisons[i].followUps[k].apply(recovered, for: key)
                    }
                }
                for (key, value) in result.comparisons[i].followUps[k].states where value == .sending { result.comparisons[i].followUps[k].states[key] = .uncertain }
            }
        }
        return result
    }
}
