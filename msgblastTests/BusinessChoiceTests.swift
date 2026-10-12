import XCTest
@testable import msgblastCore

final class BusinessChoiceTests: XCTestCase {
    private let address = "urn:biz:00000000-0000-0000-0000-000000000001"
    private func fixture() throws -> (Chat, Message, [Message]) {
        let chat = Chat(id: "iMessage;-;" + address, handle: address, lastActivity: 0, displayName: "Poke", businessConversation: true)
        let json: [String: Any] = ["quick-reply": ["summaryText": "Plumbers", "items": [["title": "Find Plumbers"], ["title": "Not Now"]]]]
        let data = try JSONSerialization.data(withJSONObject: json)
        let archive = try NSKeyedArchiver.archivedData(withRootObject: ["data": data] as NSDictionary, requiringSecureCoding: true)
        let payload = try XCTUnwrap(BusinessMessagePayload.decode(archive, bundleID: "com.apple.icloud.apps.messages.business.extension"))
        let question = Message(id: 1, guid: "question", chatID: chat.id, text: "Find repair options?", outgoing: false)
        let source = Message(id: 2, guid: "choices", chatID: chat.id, text: payload.title, outgoing: false, businessPayload: payload)
        return (chat, source, [question, source])
    }
    private let questionFrame = BusinessChoiceSnapshot.Frame(x: 0, y: 0, width: 300, height: 20)
    private func button(_ id: Int, _ title: String, y: Double, group: String = "card", enabled: Bool = true) -> BusinessChoiceSnapshot.Button {
        .init(id: id, title: title, group: group, frame: .init(x: 0, y: y, width: 200, height: 20), enabled: enabled)
    }
    private func snapshot(_ buttons: [BusinessChoiceSnapshot.Button], name: String = "Poke", text: String = "Find repair options?") -> BusinessChoiceSnapshot {
        .init(conversationName: name, contexts: [.init(text: text, frame: questionFrame)], buttons: buttons)
    }
    func testDisplayCardContainsOnlyLabelsAndConfirmedSelection() throws {
        let (_, source, _) = try fixture()
        let payload = try XCTUnwrap(source.businessPayload)
        let original = BusinessMessageCard(payload: payload, selectedOptionID: nil)
        XCTAssertEqual(original.options.map(\.selected), [false, false])
        let selected = BusinessMessageCard(payload: payload, selectedOptionID: 1)
        XCTAssertEqual(selected.options.map(\.selected), [false, true])
        let json = String(decoding: try JSONEncoder().encode(selected), as: UTF8.self)
        XCTAssertFalse(json.contains("sourceFingerprint"))
        XCTAssertFalse(json.contains("identifier"))
        XCTAssertFalse(json.contains("urn:biz:"))
    }
    func testMatchingNativeControlAllowsAccessibilityAliasesAtOneLocation() throws {
        let (chat, source, history) = try fixture()
        let request = try BusinessChoiceRequest(chat: chat, message: source, optionID: 1, history: history, chats: [chat], attempt: nil)
        XCTAssertEqual(try request.matchingButton(in: snapshot([button(1, "Find Plumbers", y: 25), button(2, "Not Now", y: 45), button(3, "Not Now", y: 45)])), 2)
    }
    func testWrongConversationQuestionDuplicateCardsAndDisabledChoicesCannotAct() throws {
        let (chat, source, history) = try fixture()
        let request = try BusinessChoiceRequest(chat: chat, message: source, optionID: 0, history: history, chats: [chat], attempt: nil)
        let buttons = [button(1, "Find Plumbers", y: 25), button(2, "Not Now", y: 45)]
        XCTAssertThrowsError(try request.matchingButton(in: snapshot(buttons, name: "Another business")))
        XCTAssertThrowsError(try request.matchingButton(in: snapshot(buttons, text: "Different question")))
        XCTAssertThrowsError(try request.matchingButton(in: snapshot(buttons + [button(3, "Find Plumbers", y: 30, group: "another"), button(4, "Not Now", y: 50, group: "another")])))
        XCTAssertThrowsError(try request.matchingButton(in: snapshot([button(1, "Find Plumbers", y: 25, enabled: false), buttons[1]])))
    }
    func testOldCardAndUnboundControlsCannotMatchCurrentQuestion() throws {
        let (chat, source, history) = try fixture()
        let request = try BusinessChoiceRequest(chat: chat, message: source, optionID: 0, history: history, chats: [chat], attempt: nil)
        XCTAssertThrowsError(try request.matchingButton(in: snapshot([button(1, "Find Plumbers", y: -50), button(2, "Not Now", y: -30)])))
        XCTAssertThrowsError(try request.matchingButton(in: snapshot([button(1, "Find Plumbers", y: 25, group: "first"), button(2, "Not Now", y: 45, group: "second")])))
        let repeated = Message(id: 0, guid: "old-question", chatID: chat.id, text: history[0].text, outgoing: false)
        XCTAssertThrowsError(try BusinessChoiceRequest(chat: chat, message: source, optionID: 0, history: [repeated] + history, chats: [chat], attempt: nil))
    }
    func testChangedOpaqueIdentityWithUnchangedLabelsCannotAct() throws {
        let (chat, source, history) = try fixture()
        let json: [String: Any] = ["requestIdentifier": "different-request", "quick-reply": ["summaryText": "Plumbers", "items": [["title": "Find Plumbers", "identifier": "different-option"], ["title": "Not Now"]]]]
        let data = try JSONSerialization.data(withJSONObject: json)
        let archive = try NSKeyedArchiver.archivedData(withRootObject: ["data": data] as NSDictionary, requiringSecureCoding: true)
        var changed = source
        changed.businessPayload = try XCTUnwrap(BusinessMessagePayload.decode(archive, bundleID: "com.apple.icloud.apps.messages.business.extension"))
        XCTAssertEqual(changed.businessPayload?.options, source.businessPayload?.options)
        XCTAssertNotEqual(changed.businessPayload?.sourceFingerprint, source.businessPayload?.sourceFingerprint)
        XCTAssertThrowsError(try BusinessChoiceRequest(chat: chat, message: source, optionID: 0, history: [history[0], changed], chats: [chat], attempt: nil))
    }
    func testStaleCardAndRepeatedOrUncertainAttemptsCannotAct() throws {
        let (chat, source, history) = try fixture()
        let newer = Message(id: 3, guid: "later", chatID: chat.id, text: "A newer reply", outgoing: false)
        XCTAssertThrowsError(try BusinessChoiceRequest(chat: chat, message: source, optionID: 0, history: history + [newer], chats: [chat], attempt: nil))
        for status in [BusinessChoiceAttempt.Status.attempting, .submitted, .uncertain] {
            let attempt = BusinessChoiceAttempt(messageGUID: source.guid, chatID: chat.id, optionID: 0, status: status)
            XCTAssertThrowsError(try BusinessChoiceRequest(chat: chat, message: source, optionID: 0, history: history, chats: [chat], attempt: attempt))
        }
        let failure = BusinessChoiceAttempt(messageGUID: source.guid, chatID: chat.id, optionID: 0, status: .failed)
        XCTAssertNoThrow(try BusinessChoiceRequest(chat: chat, message: source, optionID: 0, history: history, chats: [chat], attempt: failure))
    }
    func testDuplicateBusinessNamesAndWrongChatCannotAct() throws {
        let (chat, source, history) = try fixture()
        var duplicate = chat; duplicate.id = "different"
        XCTAssertThrowsError(try BusinessChoiceRequest(chat: chat, message: source, optionID: 0, history: history, chats: [chat, duplicate], attempt: nil))
        var wrong = source; wrong.chatID = "different"
        XCTAssertThrowsError(try BusinessChoiceRequest(chat: chat, message: wrong, optionID: 0, history: history, chats: [chat], attempt: nil))
    }
    func testChoiceAttemptsPersistAndOlderStateDecodesWithoutThem() throws {
        var state = AppState()
        state.businessChoiceAttempts = ["choices": .init(messageGUID: "choices", chatID: "chat", optionID: 1, status: .uncertain)]
        let restored = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.businessChoiceAttempts?["choices"]?.status, .uncertain)
        state.businessChoiceAttempts?["choices"]?.status = .attempting
        XCTAssertEqual(state.recoveringInFlight().businessChoiceAttempts?["choices"]?.status, .uncertain)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        json.removeValue(forKey: "businessChoiceAttempts")
        let legacy = try JSONDecoder().decode(AppState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.businessChoiceAttempts)
    }
}
