import Foundation
import SQLite3

/// A small SQLite key-value file (system sqlite3) for the phone's cache: the projection,
/// per-device drafts, command records, and the paired Mac. Values are JSON.
public final class LocalDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSLock()
    public let url: URL?

    /// Nil `url` keeps everything in memory (tests and previews).
    public init(url: URL?) throws {
        self.url = url
        if let url { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        let path = url?.path ?? ":memory:"
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw LocalDatabaseError.open(String(cString: sqlite3_errmsg(handle)))
        }
        try execute("CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value BLOB NOT NULL)")
        if let url {
            // Cached conversations stay on this device and out of backups' plaintext where possible.
            #if os(iOS)
            try? (url as NSURL).setResourceValue(FileProtectionType.completeUntilFirstUserAuthentication, forKey: .fileProtectionKey)
            #endif
        }
    }
    deinit { sqlite3_close(handle) }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw LocalDatabaseError.query(String(cString: sqlite3_errmsg(handle))) }
    }

    public func data(_ key: String) -> Data? {
        lock.withLock {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(handle, "SELECT value FROM kv WHERE key = ?", -1, &statement, nil) == SQLITE_OK else { return nil }
            sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        }
    }

    public func set(_ data: Data?, for key: String) {
        lock.withLock {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            if let data {
                guard sqlite3_prepare_v2(handle, "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)", -1, &statement, nil) == SQLITE_OK else { return }
                sqlite3_bind_text(statement, 1, key, -1, transient)
                _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32($0.count), transient) }
            } else {
                guard sqlite3_prepare_v2(handle, "DELETE FROM kv WHERE key = ?", -1, &statement, nil) == SQLITE_OK else { return }
                sqlite3_bind_text(statement, 1, key, -1, transient)
            }
            sqlite3_step(statement)
        }
    }

    public func value<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        data(key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
    public func setValue<T: Encodable>(_ value: T?, _ key: String) {
        set(value.flatMap { try? JSONEncoder().encode($0) }, for: key)
    }

    public func removeAll() { lock.withLock { _ = sqlite3_exec(handle, "DELETE FROM kv", nil, nil, nil) } }
}

public enum LocalDatabaseError: Error, Equatable { case open(String), query(String) }
