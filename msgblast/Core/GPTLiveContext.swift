import Foundation

/// Explicitly selected app data. This is never interpreted as agent instructions.
public struct GPTLiveConversationContext: Encodable, Sendable {
    public struct Entry: Codable, Sendable {
        public let role: String
        public let text: String
        public init(role: String, text: String) { self.role = role; self.text = text }
    }
    public struct Recipient: Codable, Sendable {
        public let id: String
        public let name: String
        public let messages: [Entry]
        public init(id: String, name: String, messages: [Entry]) {
            self.id = id; self.name = name; self.messages = messages
        }
    }
    public let comparisonID: String
    public let question: String
    public let recipients: [Recipient]
    public let historyTruncated: Bool
    public let attachmentContentsIncluded = false

    public init(comparisonID: String, question: String, recipients: [Recipient]) {
        self.comparisonID = comparisonID
        self.question = Self.boundedText(question, budget: 4000)
        // Divide the budget between participants instead of silently dropping later agents.
        let messageBudget = 24000 / max(1, recipients.count)
        var truncated = self.question != question
        self.recipients = recipients.map { recipient in
            var remaining = messageBudget
            var entries: [Entry] = []
            for entry in recipient.messages.reversed() {
                guard remaining > 0, entries.count < 60 else { truncated = true; break }
                let text = Self.boundedText(entry.text, budget: remaining, suffix: true)
                if text != entry.text { truncated = true }
                entries.append(Entry(role: Self.boundedText(entry.role, budget: 32), text: text))
                remaining -= Self.jsonByteCount(text)
            }
            return Recipient(id: recipient.id, name: Self.boundedText(recipient.name, budget: 160), messages: entries.reversed())
        }
        historyTruncated = truncated
    }
    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 56000 else { throw GPTLiveContextError.tooManyRecipients }
        return String(decoding: data, as: UTF8.self)
    }
    // Budget the encoded bytes, including JSON escaping, rather than Character
    // counts: emoji, CJK and control characters otherwise exceed the API limit.
    private static func scalarCost(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 8, 9, 10, 12, 13, 34, 47, 92: return 2
        case 0..<32: return 6
        default: return scalar.utf8.count
        }
    }
    private static func jsonByteCount(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + scalarCost($1) }
    }
    private static func boundedText(_ text: String, budget: Int, suffix: Bool = false) -> String {
        var remaining = budget
        var kept: [Unicode.Scalar] = []
        let scalars = suffix ? Array(text.unicodeScalars.reversed()) : Array(text.unicodeScalars)
        for scalar in scalars {
            let cost = scalarCost(scalar)
            guard cost <= remaining else { break }
            kept.append(scalar); remaining -= cost
        }
        return String(String.UnicodeScalarView(suffix ? Array(kept.reversed()) : kept))
    }
}

public enum GPTLiveContextError: LocalizedError {
    case tooManyRecipients
    public var errorDescription: String? { "This conversation has too many recipients to share at once. Select one recipient and try again." }
}

public struct GPTLiveDraft: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let comparisonID: UUID?
    public let recipientIDs: [String]
    public var text: String
    public var revision = 0
    public init(comparisonID: UUID?, recipientIDs: [String], text: String) {
        id = UUID(); self.comparisonID = comparisonID; self.recipientIDs = recipientIDs; self.text = text
    }
    public static func validated(comparisonID: UUID?, recipientIDs: [String], text: String, allowedRecipientIDs: Set<String>) throws -> Self {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recipientIDs.isEmpty, recipientIDs.count <= 20,
              Set(recipientIDs).count == recipientIDs.count,
              Set(recipientIDs).isSubset(of: allowedRecipientIDs),
              !text.isEmpty, text.count <= 8000, text.utf8.count <= 32000 else {
            throw GPTLiveDraftError.invalid
        }
        return Self(comparisonID: comparisonID, recipientIDs: recipientIDs, text: text)
    }
    public mutating func edit(_ text: String, expectedRevision: Int) throws {
        guard expectedRevision == revision, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= 8000, text.utf8.count <= 32000 else { throw GPTLiveDraftError.invalid }
        self.text = text; revision += 1
    }
}
public enum GPTLiveDraftError: LocalizedError {
    case invalid
    public var errorDescription: String? { "Choose available recipients and a message of 1–8,000 characters. Read the latest draft revision before editing it." }
}
