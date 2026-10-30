import XCTest
import SQLite3
@testable import msgblastCore
final class MessagesDatabaseTests: XCTestCase {
    func testBusinessPayloadIdentifiesSeparateDestinationAndNeverRoutesByPhone() throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        let sql = """
        ALTER TABLE chat ADD COLUMN display_name TEXT;
        ALTER TABLE chat ADD COLUMN service_name TEXT;
        ALTER TABLE message ADD COLUMN balloon_bundle_id TEXT;
        INSERT INTO chat(guid,display_name,service_name) VALUES('business-guid','Poke','iMessage');
        INSERT INTO handle VALUES('opaque-business-123456','iMessage');
        INSERT INTO chat_handle_join VALUES(5,5);
        INSERT INTO message(guid,text,date,is_from_me,balloon_bundle_id) VALUES('business-message','fixture',810000004000000000,0,'com.apple.messages.MSMessageExtensionBalloonPlugin:XXX:com.apple.icloud.apps.messages.business.extension');
        INSERT INTO chat_message_join VALUES(5,5);
        """
        XCTAssertEqual(sqlite3_exec(writer, sql, nil, nil, nil), SQLITE_OK)
        let bytes = try Data(contentsOf: url)
        let chats = try MessagesDatabase(path: url.path).chats()
        let business = try XCTUnwrap(chats.first { $0.id == "business-guid" })
        XCTAssertEqual(business.displayName, "Poke")
        XCTAssertEqual(business.businessConversation, true)
        XCTAssertFalse(business.eligible)
        XCTAssertFalse(Chat(id: "unknown", handle: "opaque-business-123456", lastActivity: 0).eligible,
                       "An opaque address is never assumed sendable without a Business payload")
        XCTAssertNil(ChatResolver.resolve(handles: ["123456", "opaque-business-123456"], chats: chats))
        var agent = Agent(name: "Poke", handles: ["123456", "999999"])
        agent.destination = MessagesDestination(chat: business)
        XCTAssertEqual(ChatResolver.conversation(agent: agent, chats: chats)?.id, business.id)
        XCTAssertNil(ChatResolver.resolve(agent: agent, chats: chats))
        XCTAssertEqual(ChatResolver.status(agent: agent, chats: chats), "Business conversation found · sending unavailable")
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
    func testDeliveryFailureIsReadFromHistoryWithoutAssumingSubmissionMeansDelivered() throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &writer), SQLITE_OK)
        let sql = """
        ALTER TABLE message ADD COLUMN error INTEGER;
        ALTER TABLE message ADD COLUMN is_delivered INTEGER;
        UPDATE message SET error=4,is_delivered=1 WHERE guid='anchor';
        UPDATE message SET error=0,is_delivered=1 WHERE guid='answer';
        UPDATE message SET is_from_me=1,error=0,is_delivered=0 WHERE guid='reply';
        """
        XCTAssertEqual(sqlite3_exec(writer, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(writer)
        let before = try Data(contentsOf: url)
        let reader = try MessagesDatabase(path: url.path)
        var messages = try reader.messages(chatID: "A")
        XCTAssertEqual(messages[0].delivery, .failed, "A failure must take precedence over a stale delivered flag")
        XCTAssertEqual(messages[1].delivery, .unknown, "Incoming messages do not have our send status")
        XCTAssertEqual(messages[2].delivery, .unknown, "Accepted or pending is not delivered")
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(sqlite3_open(url.path, &writer), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(writer, "UPDATE message SET error=0,is_delivered=1 WHERE guid='anchor';", nil, nil, nil), SQLITE_OK)
        sqlite3_close(writer)
        messages = try reader.messages(chatID: "A")
        XCTAssertEqual(messages[0].delivery, .delivered, "The same outgoing record can later report delivery")
    }
    func testAbsentDeliveryColumnsRemainUnknown() throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let messages = try MessagesDatabase(path: url.path).messages(chatID: "A")
        XCTAssertTrue(messages.allSatisfy { $0.delivery == .unknown })
    }
    func testAttachmentsRemainAssociatedWithTheirMessageAndDatabaseIsReadOnly() throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &writer), SQLITE_OK)
        let sql = """
        CREATE TABLE attachment(guid TEXT,filename TEXT,transfer_name TEXT,mime_type TEXT,total_bytes INTEGER);
        CREATE TABLE message_attachment_join(message_id INTEGER,attachment_id INTEGER);
        INSERT INTO attachment VALUES('photo','~/Library/Messages/Attachments/test/photo.png','photo.png','image/png',42),('file','/tmp/report.pdf','report.pdf','application/pdf',100);
        INSERT INTO message_attachment_join VALUES(1,1),(2,2);
        UPDATE message SET text=NULL WHERE guid='anchor';
        """
        XCTAssertEqual(sqlite3_exec(writer, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(writer)
        let before = try Data(contentsOf: url)
        let messages = try MessagesDatabase(path: url.path).messages(chatID: "A")
        XCTAssertEqual(messages[0].attachments.map(\.filename), ["photo.png"])
        XCTAssertEqual(messages[0].text, "")
        XCTAssertTrue(messages[0].attachments[0].isImage)
        XCTAssertEqual(messages[1].attachments.map(\.filename), ["report.pdf"])
        XCTAssertTrue(messages[2].attachments.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }
    func testEmptyOrdinaryMessageDoesNotBecomeAnUnavailableBusinessCard() throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "UPDATE message SET text='' WHERE guid='anchor'", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let message = try XCTUnwrap(MessagesDatabase(path: url.path).messages(chatID: "A").first)
        XCTAssertEqual(message.text, "")
        XCTAssertNil(message.businessPayload)
    }

    func testBusinessQuickReplyBlobDisplaysPromptAndOrderedChoicesWithoutChangingDatabase() throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let payload = try businessArchive(["quick-reply": ["summaryText": "Find repair options?", "items": [["identifier": "opaque-yes", "title": "Yes, please"], ["identifier": "opaque-no", "title": "Not now"]]]])
        try installBusinessPayload(payload, in: url)
        let before = try Data(contentsOf: url)
        let message = try XCTUnwrap(MessagesDatabase(path: url.path).messages(chatID: "A").first)
        let business = try XCTUnwrap(message.businessPayload)
        XCTAssertEqual(business.kind, .quickReply)
        XCTAssertEqual(business.title, "Find repair options?")
        XCTAssertEqual(business.options.map(\.title), ["Yes, please", "Not now"])
        XCTAssertEqual(message.text, "Find repair options?")
        XCTAssertTrue(business.options.allSatisfy { !$0.selected })
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testBusinessListPickerRetainsSectionsSubtitlesAndReplySelection() throws {
        let payload = try businessArchive(["receivedMessage": ["title": "Choose a repair"], "replyMessage": ["title": "Your selection"], "listPicker": ["sections": [["title": "Selected", "items": [["title": "Appliance repair", "subtitle": "Dishwasher specialist"]]], ["title": "Other options", "items": [["title": "Plumber"]]]]]])
        let business = try XCTUnwrap(BusinessMessagePayload.decode(payload, bundleID: "com.apple.icloud.apps.messages.business.extension"))
        XCTAssertEqual(business.kind, .listPicker)
        XCTAssertEqual(business.title, "Choose a repair")
        XCTAssertEqual(business.options.map(\.title), ["Appliance repair", "Plumber"])
        XCTAssertEqual(business.options.map(\.section), ["Selected", "Other options"])
        XCTAssertEqual(business.options.first?.subtitle, "Dishwasher specialist")
        XCTAssertEqual(business.options.map(\.selected), [true, false])
    }

    func testBusinessPayloadRejectsMalformedArchivesAndUnrelatedExtensions() throws {
        let payload = try businessArchive(["quick-reply": ["summaryText": "Choose", "items": [["title": "Yes"]], "selectedIndex": 0]])
        XCTAssertNil(BusinessMessagePayload.decode(payload, bundleID: "unrelated.extension"))
        XCTAssertNil(BusinessMessagePayload.decode(Data("not a plist".utf8), bundleID: "com.apple.icloud.apps.messages.business.extension"))
        XCTAssertNil(BusinessMessagePayload.decode(Data(repeating: 0, count: 1_048_577), bundleID: "com.apple.icloud.apps.messages.business.extension"))
        let selected = try XCTUnwrap(BusinessMessagePayload.decode(payload, bundleID: "com.apple.icloud.apps.messages.business.extension"))
        XCTAssertEqual(selected.options.map(\.selected), [true])
    }

    private func businessArchive(_ json: [String: Any]) throws -> Data {
        let bytes = try JSONSerialization.data(withJSONObject: json)
        return try NSKeyedArchiver.archivedData(withRootObject: ["data": bytes, "ldtext": "Business choices"] as NSDictionary, requiringSecureCoding: true)
    }

    private func installBusinessPayload(_ payload: Data, in url: URL) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "ALTER TABLE message ADD COLUMN payload_data BLOB; ALTER TABLE message ADD COLUMN balloon_bundle_id TEXT;", nil, nil, nil), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "UPDATE message SET text=NULL,is_from_me=0,payload_data=?,balloon_bundle_id='com.apple.messages.MSMessageExtensionBalloonPlugin:fixture:com.apple.icloud.apps.messages.business.extension' WHERE guid='anchor'", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        XCTAssertEqual(payload.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(payload.count), transient) }, SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }

    func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-\(UUID()).db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE chat(guid TEXT); CREATE TABLE handle(id TEXT,service TEXT);
        CREATE TABLE chat_handle_join(chat_id INTEGER,handle_id INTEGER);
        CREATE TABLE chat_message_join(chat_id INTEGER,message_id INTEGER);
        CREATE TABLE message(guid TEXT,text TEXT,date INTEGER,is_from_me INTEGER,thread_originator_guid TEXT,associated_message_type INTEGER);
        INSERT INTO chat VALUES('A'),('group'),('empty'),('sms');
        INSERT INTO handle VALUES('palcowen@gmail.com','iMessage'),('mgalpert@gmail.com','iMessage'),('empty@example.com','iMessage'),('sms@example.com','SMS');
        INSERT INTO chat_handle_join VALUES(1,1),(2,1),(2,2),(3,3),(4,4);
        INSERT INTO message VALUES('anchor','shared',810000000000000000,1,NULL,0),('answer','first',810000001000000000,0,NULL,0),('reply','older reply',810000002000000000,0,'anchor',0),('reaction',NULL,810000003000000000,0,NULL,2000);
        INSERT INTO chat_message_join VALUES(1,1),(1,2),(1,3),(1,4),(2,2),(4,2);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        return url
    }
    func testReadOnlyAdapterRoutesAndReadsWithoutMutatingDatabase() throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let before = try Data(contentsOf: url)
        let store = try MessagesDatabase(path: url.path)
        let chats = try store.chats()
        XCTAssertEqual(chats.map(\.id), ["A"])
        let messages = try store.messages(chatID: "A", after: 1)
        XCTAssertEqual(messages.map(\.guid), ["anchor", "answer", "reply"])
        XCTAssertEqual(messages.last?.replyTo, "anchor")
        XCTAssertTrue(store.supportsReplyRelationships)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertTrue(try store.messages(chatID: "A' OR 1=1 --").isEmpty)
    }
    func testMissingDatabaseDoesNotCreateFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID()).db")
        XCTAssertThrowsError(try MessagesDatabase(path: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testReactionsAttachToTheirMessageAndRespectReplacementAndRemoval() throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &writer), SQLITE_OK)
        let sql = """
        ALTER TABLE message ADD COLUMN associated_message_guid TEXT;
        ALTER TABLE message ADD COLUMN associated_message_emoji TEXT;
        ALTER TABLE message ADD COLUMN handle_id INTEGER;
        INSERT INTO message(guid,text,date,is_from_me,associated_message_type,associated_message_guid,handle_id) VALUES
        ('like',NULL,810000004000000000,0,2001,'p:0/anchor',1),
        ('love',NULL,810000005000000000,0,2000,'p:0/anchor',1),
        ('mine',NULL,810000006000000000,1,2003,'bp:anchor',0);
        INSERT INTO message(guid,date,is_from_me,associated_message_type,associated_message_guid,associated_message_emoji,handle_id) VALUES
        ('custom',810000007000000000,0,2006,'p:0/answer','✅',1),
        ('remove-love',810000008000000000,0,3000,'p:0/anchor',NULL,1),
        ('unrelated',810000009000000000,0,2006,'p:0/not-in-this-chat','🎉',1),
        ('late-synced-like',810000004500000000,0,2001,'p:0/anchor',NULL,1),
        ('late-synced-custom',810000006500000000,0,2006,'p:0/answer','🎉',1);
        INSERT INTO chat_message_join VALUES(1,5),(1,6),(1,7),(1,8),(1,9),(1,10),(1,11),(1,12);
        """
        XCTAssertEqual(sqlite3_exec(writer, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(writer)
        let before = try Data(contentsOf: url)
        let reader = try MessagesDatabase(path: url.path)
        let messages = try reader.messages(chatID: "A", after: 1)
        XCTAssertEqual(messages.map(\.guid), ["anchor", "answer", "reply"])
        XCTAssertEqual(messages[0].reactions.map(\.emoji), ["😂"])
        XCTAssertEqual(messages[0].reactions.first?.outgoing, true)
        XCTAssertEqual(messages[1].reactions.map(\.emoji), ["✅"])
        XCTAssertEqual(try Data(contentsOf: url), before)
    }
    func testEveryStandardTapbackAndItsRemovalMap() throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &writer), SQLITE_OK)
        // One contact reacts with each standard tapback in turn on "answer" (each replaces the
        // last), and you react to "anchor"; then removals 3000–3005 take them away.
        var rows: [String] = []
        for (offset, type) in (2000...2005).enumerated() { rows.append("('add-\(type)',NULL,\(810000010000000000 + offset * 1000000000),0,\(type),'p:0/answer',1)") }
        rows.append("('mine-love',NULL,810000020000000000,1,2000,'p:0/anchor',0)")
        let sql = """
        ALTER TABLE message ADD COLUMN associated_message_guid TEXT;
        ALTER TABLE message ADD COLUMN associated_message_emoji TEXT;
        ALTER TABLE message ADD COLUMN handle_id INTEGER;
        INSERT INTO message(guid,text,date,is_from_me,associated_message_type,associated_message_guid,handle_id) VALUES \(rows.joined(separator: ","));
        INSERT INTO chat_message_join SELECT 1, ROWID FROM message WHERE guid LIKE 'add-%' OR guid = 'mine-love';
        """
        XCTAssertEqual(sqlite3_exec(writer, sql, nil, nil, nil), SQLITE_OK)
        var reader = try MessagesDatabase(path: url.path)
        var messages = try reader.messages(chatID: "A", after: 1)
        XCTAssertEqual(messages.first { $0.guid == "answer" }?.reactions.map(\.emoji), ["❓"], "The latest of ❤️ 👍 👎 😂 ‼️ ❓ replaces the earlier ones")
        XCTAssertEqual(messages.first { $0.guid == "anchor" }?.reactions.map(\.emoji), ["❤️"]); XCTAssertEqual(messages.first { $0.guid == "anchor" }?.reactions.first?.outgoing, true)
        for (index, emoji) in ["❤️", "👍", "👎", "😂", "‼️", "❓"].enumerated() {
            XCTAssertEqual(sqlite3_exec(writer, "INSERT INTO message(guid,text,date,is_from_me,associated_message_type,associated_message_guid,handle_id) VALUES('add-again-\(index)',NULL,\(810000030000000000 + index * 2000000000),0,\(2000 + index),'p:0/answer',1); INSERT INTO chat_message_join VALUES(1,last_insert_rowid());", nil, nil, nil), SQLITE_OK)
            reader = try MessagesDatabase(path: url.path)
            XCTAssertEqual(try reader.messages(chatID: "A", after: 1).first { $0.guid == "answer" }?.reactions.map(\.emoji), [emoji], "Type \(2000 + index) is \(emoji)")
            XCTAssertEqual(sqlite3_exec(writer, "INSERT INTO message(guid,text,date,is_from_me,associated_message_type,associated_message_guid,handle_id) VALUES('remove-\(index)',NULL,\(810000030000000000 + index * 2000000000 + 1000000000),0,\(3000 + index),'p:0/answer',1); INSERT INTO chat_message_join VALUES(1,last_insert_rowid());", nil, nil, nil), SQLITE_OK)
            reader = try MessagesDatabase(path: url.path)
            XCTAssertEqual(try reader.messages(chatID: "A", after: 1).first { $0.guid == "answer" }?.reactions.count, 0, "Type \(3000 + index) removes it")
        }
        messages = try reader.messages(chatID: "A", after: 1)
        XCTAssertFalse(messages.contains { $0.guid.hasPrefix("add-") || $0.guid.hasPrefix("remove-") }, "Tapbacks never become messages")
        sqlite3_close(writer)
    }
    func testEmojiTextIsReadExactly() throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &writer), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(writer, "INSERT INTO message VALUES('emoji','👩‍👩‍👧‍👦 🇵🇹 👍🏽 ❤️',810000004000000000,0,NULL,0); INSERT INTO chat_message_join VALUES(1,last_insert_rowid());", nil, nil, nil), SQLITE_OK)
        sqlite3_close(writer)
        let message = try XCTUnwrap(MessagesDatabase(path: url.path).messages(chatID: "A").first { $0.guid == "emoji" })
        XCTAssertEqual(Array(message.text.utf8), Array("👩‍👩‍👧‍👦 🇵🇹 👍🏽 ❤️".utf8))
    }
    func testUnsupportedSchemaBlocksCleanly() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("unsupported-\(UUID()).db")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?; sqlite3_open(url.path, &db); sqlite3_exec(db, "CREATE TABLE message(foo TEXT)", nil, nil, nil); sqlite3_close(db)
        XCTAssertThrowsError(try MessagesDatabase(path: url.path))
    }
    func testChangeVersionDetectsOtherConnectionsCommits() throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let reader = try MessagesDatabase(path: url.path)
        let before = try reader.changeVersion()
        XCTAssertEqual(try reader.changeVersion(), before)
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, "INSERT INTO message VALUES('later','new text',810000004000000000,0,NULL,0); INSERT INTO chat_message_join VALUES(1,last_insert_rowid());", nil, nil, nil), SQLITE_OK)
        XCTAssertNotEqual(try reader.changeVersion(), before)
        XCTAssertEqual(try reader.messages(chatID: "A").last?.guid, "later")
    }
}
