import Foundation

public struct BusinessChoiceAttempt: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case attempting, submitted, failed, uncertain }
    public var messageGUID: String
    public var chatID: String
    public var optionID: Int
    public var status: Status
    public var detail: String?
    public init(messageGUID: String, chatID: String, optionID: Int, status: Status = .attempting, detail: String? = nil) {
        self.messageGUID = messageGUID; self.chatID = chatID; self.optionID = optionID; self.status = status; self.detail = detail
    }
}

public struct BusinessChoiceRequest: Sendable {
    public let chatID: String
    public let conversationName: String
    public let messageGUID: String
    public let payload: BusinessMessagePayload
    public let optionID: Int
    public let context: String
    public let contextRowID: Int64

    public init(chat: Chat, message: Message, optionID: Int, history: [Message], chats: [Chat], attempt: BusinessChoiceAttempt?) throws {
        guard chat.businessConversation == true, chat.businessScriptingID != nil,
              let name = chat.displayName, !name.isEmpty,
              chats.filter({ $0.businessConversation == true && $0.displayName == name }).count == 1,
              message.chatID == chat.id, !message.outgoing,
              let payload = message.businessPayload, payload.kind == .quickReply,
              payload.options.contains(where: { $0.id == optionID }),
              !payload.options.contains(where: \.selected),
              Set(payload.options.map(\.title)).count == payload.options.count,
              attempt == nil || attempt?.status == .failed,
              let current = history.first(where: { $0.guid == message.guid }), !current.outgoing,
              current.chatID == chat.id, current.id == message.id, current.businessPayload == payload,
              !history.contains(where: { $0.id > message.id }),
              let contextMessage = history.last(where: { $0.id < message.id && !$0.outgoing && $0.businessPayload == nil && !$0.text.isEmpty }) else {
            throw SendFailure.notSubmitted("These choices are no longer available or cannot be identified safely. Refresh the conversation.")
        }
        let context = contextMessage.text
        guard history.filter({ !$0.outgoing && $0.businessPayload == nil && Self.normalized($0.text) == Self.normalized(context) }).count == 1 else {
            throw SendFailure.notSubmitted("This question occurs more than once in the conversation. The native choice card cannot be identified safely.")
        }
        self.chatID = chat.id; conversationName = name; messageGUID = message.guid
        self.payload = payload; self.optionID = optionID; self.context = context; contextRowID = contextMessage.id
    }

    public func matchingButton(in snapshot: BusinessChoiceSnapshot) throws -> Int {
        let contexts = Set(snapshot.contexts.filter { Self.normalized($0.text) == Self.normalized(context) }.map(\.frame))
        guard snapshot.conversationName == conversationName, contexts.count == 1, let question = contexts.first else {
            throw SendFailure.notSubmitted("Messages is not showing one expected conversation and question. Nothing was selected.")
        }
        var cards: [[BusinessChoiceSnapshot.Button]] = []
        for group in Dictionary(grouping: snapshot.buttons, by: \.group).values {
            var ordered: [BusinessChoiceSnapshot.Button] = []
            for option in payload.options {
                let matches = group.filter { $0.title == option.title && $0.enabled }
                guard Set(matches.map(\.frame)).count == 1, let button = matches.first else { ordered = []; break }
                ordered.append(button)
            }
            guard ordered.count == payload.options.count, let first = ordered.first,
                  first.frame.y >= question.maxY - 2, first.frame.y <= question.maxY + 40,
                  abs(first.frame.x - question.x) <= 24 else { continue }
            var previous = first
            var contiguous = true
            for next in ordered.dropFirst() {
                if abs(next.frame.x - first.frame.x) > 2 || abs(next.frame.width - first.frame.width) > 2 ||
                    next.frame.y < previous.frame.maxY - 2 || next.frame.y > previous.frame.maxY + 12 { contiguous = false; break }
                previous = next
            }
            if contiguous, !cards.contains(where: { $0.map(\.frame) == ordered.map(\.frame) }) { cards.append(ordered) }
        }
        guard cards.count == 1, let card = cards.first,
              let index = payload.options.firstIndex(where: { $0.id == optionID }) else {
            throw SendFailure.notSubmitted("Messages is not showing one complete choice card immediately below this question. Nothing was selected.")
        }
        return card[index].id
    }
    private static func normalized(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
}

public struct BusinessChoiceSnapshot: Sendable {
    public struct Frame: Hashable, Sendable {
        public let x: Double, y: Double, width: Double, height: Double
        public var maxY: Double { y + height }
        public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    }
    public struct Context: Sendable {
        public let text: String
        public let frame: Frame
        public init(text: String, frame: Frame) { self.text = text; self.frame = frame }
    }
    public struct Button: Sendable {
        public let id: Int
        public let title: String
        public let group: String
        public let frame: Frame
        public let enabled: Bool
        public init(id: Int, title: String, group: String, frame: Frame, enabled: Bool = true) {
            self.id = id; self.title = title; self.group = group; self.frame = frame; self.enabled = enabled
        }
    }
    public let conversationName: String
    public let contexts: [Context]
    public let buttons: [Button]
    public init(conversationName: String, contexts: [Context], buttons: [Button]) {
        self.conversationName = conversationName; self.contexts = contexts; self.buttons = buttons
    }
}
