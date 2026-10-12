import Foundation
import msgblastCore

extension AppModel {
    func businessChoiceAttempt(_ message: Message) -> BusinessChoiceAttempt? { state.businessChoiceAttempts?[message.guid] }

    func canChooseBusinessOption(_ message: Message, member: Member, optionID: Int) -> Bool {
        guard !busy, !webBroadcastBusy else { return false }
        return (try? BusinessChoiceRequest(chat: member.chat, message: message, optionID: optionID,
            history: messages[member.chat.id] ?? [], chats: chats, attempt: businessChoiceAttempt(message))) != nil
    }

    func chooseBusinessOption(_ message: Message, member: Member, optionID: Int) async {
        guard !busy, !webBroadcastBusy else { return }
        busy = true
        defer { busy = false }
        var attempted = false
        do {
            let history = try businessHistory(member.chat.id)
            let request = try BusinessChoiceRequest(chat: member.chat, message: message, optionID: optionID,
                history: history, chats: chats, attempt: businessChoiceAttempt(message))
            var attempts = state.businessChoiceAttempts ?? [:]
            attempts[message.guid] = BusinessChoiceAttempt(messageGUID: message.guid, chatID: member.chat.id, optionID: optionID)
            let previous = state.businessChoiceAttempts
            state.businessChoiceAttempts = attempts
            do { try save() } catch { state.businessChoiceAttempts = previous; throw error }
            attempted = true
            if demo {
                let selected = request.payload.options.first { $0.id == optionID }!
                appendDemo(selected.title, chat: member.chat, outgoing: true)
                appendDemo("Fixture response: \(selected.title) selected.", chat: member.chat, outgoing: false)
            } else {
                try await BusinessChoiceSender().select(request) {
                    let current = try BusinessChoiceRequest(chat: member.chat, message: message, optionID: optionID,
                        history: self.businessHistory(member.chat.id, after: request.contextRowID), chats: self.chats, attempt: nil)
                    guard current.context == request.context, current.contextRowID == request.contextRowID else {
                        throw SendFailure.notSubmitted("The question changed while Messages was loading. Nothing was selected.")
                    }
                }
            }
            state.businessChoiceAttempts?[message.guid]?.status = .submitted
            state.businessChoiceAttempts?[message.guid]?.detail = demo ? "Selected · simulated response" : "Submitted to Messages"
            try save()
            captureMessages()
            if !demo { busy = false; await refresh() }
        } catch {
            if attempted {
                let status: BusinessChoiceAttempt.Status
                if case SendFailure.notSubmitted = error { status = .failed } else { status = .uncertain }
                state.businessChoiceAttempts?[message.guid]?.status = status
                state.businessChoiceAttempts?[message.guid]?.detail = error.localizedDescription
                do { try save() } catch { self.error = "Could not save the choice status. Check Messages before taking another action."; return }
            }
            self.error = error.localizedDescription
        }
    }

    private func businessHistory(_ chatID: String, after: Int64 = 0) throws -> [Message] {
        if demo { return messages[chatID] ?? [] }
        guard let database else { throw SendFailure.notSubmitted("Messages history is unavailable. Refresh before choosing a response.") }
        return try database.messages(chatID: chatID, after: after)
    }

    func appendBusinessChoiceFixture(chat: Chat) {
        let json: [String: Any] = ["mspVersion": "1.0", "requestIdentifier": "local-fixture", "quick-reply": ["summaryText": "Plumbers", "items": [["title": "Find Plumbers", "identifier": "fixture-find"], ["title": "Not Now", "identifier": "fixture-not-now"]]]]
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let archive = try? NSKeyedArchiver.archivedData(withRootObject: ["data": data, "ldtext": "Plumbers"] as NSDictionary, requiringSecureCoding: true),
              let payload = BusinessMessagePayload.decode(archive, bundleID: "com.apple.icloud.apps.messages.business.extension") else { return }
        appendDemo("Want me to find local repair options?", chat: chat, outgoing: false)
        demoRow += 1
        messages[chat.id, default: []].append(Message(id: demoRow, guid: "business-fixture-\(demoRow)", chatID: chat.id, text: payload.title, outgoing: false, businessPayload: payload))
    }
}
