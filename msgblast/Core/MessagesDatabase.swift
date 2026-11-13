import Foundation
import SQLite3

public final class MessagesDatabase {
    private var db: OpaquePointer?
    private var chatColumns: Set<String> = []
    private var columns: Set<String> = []
    private var attachmentColumns: Set<String> = []
    private var hasAttachmentJoin = false
    public init(path: String) throws {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw AppFailure.blocked("Messages history is unavailable. Enable Full Disk Access for msgblast in System Settings, quit and reopen the app, then refresh. The database is only opened read-only.")
        }
        db = handle
        sqlite3_busy_timeout(handle, 1500)
        do {
            chatColumns = Set(try rows("PRAGMA table_info(chat)").compactMap { $0["name"] })
            columns = Set(try rows("PRAGMA table_info(message)").compactMap { $0["name"] })
            attachmentColumns = Set(try rows("PRAGMA table_info(attachment)").compactMap { $0["name"] })
            hasAttachmentJoin = Set(try rows("PRAGMA table_info(message_attachment_join)").compactMap { $0["name"] }).isSuperset(of: ["message_id", "attachment_id"])
            let required: Set<String> = ["guid", "text", "date", "is_from_me"]
            guard required.isSubset(of: columns) else { throw AppFailure.blocked("This Messages database layout is unsupported. No messages were sent or changed.") }
            _ = try rows("SELECT c.guid,h.id FROM chat c JOIN chat_handle_join ch ON ch.chat_id=c.ROWID JOIN handle h ON h.ROWID=ch.handle_id LIMIT 0")
        } catch { sqlite3_close(handle); db = nil; throw error }
    }
    deinit { if let db { sqlite3_close(db) } }
    private func rows(_ sql: String, values: [String] = []) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw AppFailure.blocked("Messages history query failed: \(String(cString: sqlite3_errmsg(db)))") }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
        }
        var result: [[String: String]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw AppFailure.blocked("Messages history is busy or unavailable. Refresh to try again.") }
            var row: [String: String] = [:]
            for i in 0..<sqlite3_column_count(statement) {
                if let text = sqlite3_column_text(statement, i) { row[String(cString: sqlite3_column_name(statement, i))] = String(cString: text) }
            }
            result.append(row)
        }
    }
    public func chats() throws -> [Chat] {
        let title = chatColumns.contains("display_name") ? "c.display_name" : "NULL"
        let service = chatColumns.contains("service_name") ? "COALESCE(NULLIF(c.service_name,''),h.service,'')" : "COALESCE(h.service,'')"
        // Positive Business evidence only; names and phone numbers are not identities.
        let business = columns.contains("balloon_bundle_id")
            ? "MAX(CASE WHEN m.balloon_bundle_id='com.apple.icloud.apps.messages.business.extension' OR m.balloon_bundle_id LIKE '%:com.apple.icloud.apps.messages.business.extension' THEN 1 ELSE 0 END)"
            : "0"
        let sql = """
        SELECT c.guid AS guid,CASE WHEN COUNT(DISTINCT ch.handle_id)=1 THEN COALESCE(h.id,'') ELSE '' END AS handle,COUNT(DISTINCT ch.handle_id) AS participants,
        COALESCE(MAX(m.date),0) AS activity,\(service) AS service,\(title) AS title,\(business) AS business
        FROM chat c LEFT JOIN chat_handle_join ch ON ch.chat_id=c.ROWID
        LEFT JOIN handle h ON h.ROWID=ch.handle_id
        LEFT JOIN chat_message_join cm ON cm.chat_id=c.ROWID LEFT JOIN message m ON m.ROWID=cm.message_id
        GROUP BY c.ROWID HAVING COUNT(cm.message_id)>0 AND ((COUNT(DISTINCT ch.handle_id)=1 AND \(service)='iMessage') OR \(business)=1)
        """
        return try rows(sql).compactMap { row in
            guard let guid = row["guid"], let address = row["handle"] else { return nil }
            return Chat(id: guid, handle: address, lastActivity: Int64(row["activity"] ?? "0") ?? 0,
                        participantCount: Int(row["participants"] ?? "0") ?? 0, service: row["service"] ?? "",
                        displayName: row["title"], businessConversation: row["business"] == "1" ? true : nil)
        }
    }
    public func messages(chatID: String, after: Int64 = 0) throws -> [Message] {
        let threadColumn = columns.contains("thread_originator_guid") ? "m.thread_originator_guid" : "NULL"
        let type = columns.contains("associated_message_type") ? "COALESCE(m.associated_message_type,0)" : "0"
        let target = columns.contains("associated_message_guid") ? "m.associated_message_guid" : "NULL"
        let emoji = columns.contains("associated_message_emoji") ? "m.associated_message_emoji" : "NULL"
        let sender = columns.contains("handle_id") ? "m.handle_id" : "0"
        let error = columns.contains("error") ? "m.error" : "NULL"
        let delivered = columns.contains("is_delivered") ? "m.is_delivered" : "NULL"
        let sql = """
        SELECT m.ROWID AS rowid,m.guid,m.text,m.date,m.is_from_me,\(threadColumn) AS reply,
        \(type) AS reaction_type,\(target) AS reaction_target,\(emoji) AS reaction_emoji,\(sender) AS sender,
        \(error) AS delivery_error,\(delivered) AS delivered
        FROM message m JOIN chat_message_join cm ON cm.message_id=m.ROWID JOIN chat c ON c.ROWID=cm.chat_id
        WHERE c.guid=? AND m.ROWID>=? ORDER BY m.ROWID
        """
        let records = try rows(sql, values: [chatID, String(after)])
        let files = try attachments(chatID: chatID, after: after)
        let business = try businessPayloads(chatID: chatID, after: after)
        var messages = records.compactMap { row -> Message? in
            let type = Int(row["reaction_type"] ?? "0") ?? 0
            guard !(2000...3999).contains(type) else { return nil }
            guard let id = Int64(row["rowid"] ?? ""), let guid = row["guid"] else { return nil }
            let reply = row["reply"].flatMap { $0.isEmpty ? nil : $0 }
            let attachments = files[id] ?? []
            let body = row["text"]?.replacingOccurrences(of: "\u{FFFC}", with: "")
            let payload = business[id]
            let text: String
            if let payload, body == nil || body?.isEmpty == true { text = payload.title }
            else { text = body ?? (attachments.isEmpty ? "[Message body unavailable · view in Messages]" : "") }
            let outgoing = row["is_from_me"] == "1"
            let delivery: MessageDelivery
            if outgoing, let error = row["delivery_error"].flatMap(Int64.init), error != 0 {
                delivery = .failed
            } else if outgoing, row["delivered"] == "1" {
                delivery = .delivered
            } else {
                delivery = .unknown
            }
            return Message(id: id, guid: guid, chatID: chatID, text: text, outgoing: outgoing, replyTo: reply, date: messageDate(row["date"]), attachments: attachments, delivery: delivery, businessPayload: payload)
        }
        let indices = Dictionary(messages.enumerated().map { ($0.element.guid, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let standard = ["❤️", "👍", "👎", "😂", "‼️", "❓"]
        // Sync may insert an older event later. Fold reactions in event order, not insertion order.
        let reactionRecords = records.filter { row in
            guard let type = Int(row["reaction_type"] ?? "") else { return false }
            return (2000...2006).contains(type) || (3000...3006).contains(type)
        }.sorted { left, right in
            let a = messageDate(left["date"]), b = messageDate(right["date"])
            return a == b ? (Int64(left["rowid"] ?? "0") ?? 0) < (Int64(right["rowid"] ?? "0") ?? 0) : a < b
        }
        for row in reactionRecords {
            guard let type = Int(row["reaction_type"] ?? ""), (2000...2006).contains(type) || (3000...3006).contains(type),
                  let target = row["reaction_target"] else { continue }
            let guid: String
            let part: String
            if target.hasPrefix("p:"), let slash = target.firstIndex(of: "/") {
                part = String(target[target.index(target.startIndex, offsetBy: 2)..<slash])
                guid = String(target[target.index(after: slash)...])
            } else {
                part = "0"
                guid = target.hasPrefix("bp:") ? String(target.dropFirst(3)) : target
            }
            guard let index = indices[guid] else { continue }
            let outgoing = row["is_from_me"] == "1"
            let actor = outgoing ? "me" : "handle-\(row["sender"] ?? "0")"
            let key = "\(actor):\(part)"
            let kind = type % 1000
            let symbol = kind < standard.count ? standard[kind] : row["reaction_emoji"]
            if type >= 3000 {
                messages[index].reactions.removeAll { $0.id == key && (symbol == nil || $0.emoji == symbol) }
            } else if let symbol, !symbol.isEmpty {
                messages[index].reactions.removeAll { $0.id == key }
                messages[index].reactions.append(MessageReaction(id: key, emoji: symbol, outgoing: outgoing))
            }
        }
        return messages
    }
    private func businessPayloads(chatID: String, after: Int64) throws -> [Int64: BusinessMessagePayload] {
        guard columns.contains("payload_data"), columns.contains("balloon_bundle_id") else { return [:] }
        let sql = """
        SELECT m.ROWID,m.balloon_bundle_id,m.payload_data
        FROM message m JOIN chat_message_join cm ON cm.message_id=m.ROWID JOIN chat c ON c.ROWID=cm.chat_id
        WHERE c.guid=? AND m.ROWID>=? AND m.payload_data IS NOT NULL
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw AppFailure.blocked("Interactive Messages history query failed.")
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, chatID, -1, transient)
        sqlite3_bind_int64(statement, 2, after)
        var result: [Int64: BusinessMessagePayload] = [:]
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw AppFailure.blocked("Interactive Messages history is unavailable. Refresh to try again.") }
            guard let bundleText = sqlite3_column_text(statement, 1) else { continue }
            let bundle = String(cString: bundleText)
            let businessID = "com.apple.icloud.apps.messages.business.extension"
            guard bundle == businessID || bundle.hasSuffix(":" + businessID) else { continue }
            let count = Int(sqlite3_column_bytes(statement, 2))
            let fallback = BusinessMessagePayload(kind: .unsupported, title: "Interactive business message", options: [], sourceFingerprint: Data())
            let id = sqlite3_column_int64(statement, 0)
            guard count > 0, count <= 1_048_576, let bytes = sqlite3_column_blob(statement, 2) else {
                result[id] = fallback
                continue
            }
            result[id] = BusinessMessagePayload.decode(Data(bytes: bytes, count: count), bundleID: bundle) ?? fallback
        }
    }

    private func attachments(chatID: String, after: Int64) throws -> [Int64: [MessageAttachment]] {
        guard hasAttachmentJoin, attachmentColumns.contains("filename") else { return [:] }
        func column(_ name: String) -> String { attachmentColumns.contains(name) ? "a.\(name)" : "NULL" }
        let sql = """
        SELECT ma.message_id,a.ROWID AS attachment_id,a.filename,\(column("guid")) AS guid,
        \(column("transfer_name")) AS name,\(column("mime_type")) AS mime,\(column("total_bytes")) AS bytes,\(column("uti")) AS uti
        FROM attachment a JOIN message_attachment_join ma ON ma.attachment_id=a.ROWID
        JOIN chat_message_join cm ON cm.message_id=ma.message_id JOIN chat c ON c.ROWID=cm.chat_id
        WHERE c.guid=? AND ma.message_id>=? ORDER BY ma.message_id,a.ROWID
        """
        var result: [Int64: [MessageAttachment]] = [:]
        for row in try rows(sql, values: [chatID, String(after)]) {
            guard let id = Int64(row["message_id"] ?? ""), let path = row["filename"], !path.isEmpty else { continue }
            let name = row["name"].flatMap { $0.isEmpty ? nil : $0 } ?? URL(fileURLWithPath: path).lastPathComponent
            guard MessageAttachment.isUserFile(filename: name, path: path, uti: row["uti"], byteCount: row["bytes"].flatMap(Int64.init)) else { continue }
            result[id, default: []].append(MessageAttachment(id: row["guid"] ?? row["attachment_id"] ?? path, filename: name, path: path, mimeType: row["mime"], byteCount: row["bytes"].flatMap(Int64.init)))
        }
        return result
    }
    private func messageDate(_ value: String?) -> Date {
        let raw = Double(value ?? "0") ?? 0
        return Date(timeIntervalSinceReferenceDate: raw > 1e12 ? raw / 1e9 : raw)
    }
    public func changeVersion() throws -> Int64 {
        guard let value = try rows("PRAGMA data_version").first?["data_version"], let version = Int64(value) else { throw AppFailure.blocked("Messages change tracking is unavailable.") }
        return version
    }
    public var supportsReplyRelationships: Bool { columns.contains("thread_originator_guid") }
}
