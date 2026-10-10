import Foundation
import SQLite3
internal import SweetCookieKit

public enum BrowserLoginSource: String, CaseIterable, Sendable, Identifiable {
    case chrome, safari
    public var id: String { rawValue }
    public var name: String { self == .chrome ? "Chrome" : "Safari" }
    fileprivate var browser: Browser { self == .chrome ? .chrome : .safari }
}

public struct BrowserLoginProfile: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct BrowserLoginImportResult: Sendable {
    public let cookies: [WebProvider: [HTTPCookie]]
    public init(cookies: [WebProvider: [HTTPCookie]]) { self.cookies = cookies }
}

public enum BrowserLoginImportError: LocalizedError, Sendable {
    case storeUnavailable
    case accessDenied(BrowserLoginSource)
    case unreadableStore(BrowserLoginSource)

    public var errorDescription: String? {
        switch self {
        case .storeUnavailable: "That browser profile is no longer available."
        case .accessDenied(.chrome): "macOS did not allow access to Chrome’s saved sign-ins."
        case .accessDenied(.safari): "macOS did not allow access to Safari’s saved sign-ins. Safari may require Full Disk Access for msgblast."
        case .unreadableStore(let source): "\(source.name)’s saved sign-ins could not be read."
        }
    }
}

/// Reads the explicitly selected browser store. Discovery never decrypts cookies,
/// and results contain only the selected website domains, with no native agents.
public struct BrowserLoginImporter: Sendable {
    private let client: BrowserCookieClient
    private let recordsReader: @Sendable (BrowserCookieQuery, BrowserCookieStore) throws -> [BrowserCookieRecord]

    public init() { self.init(homeDirectories: BrowserCookieClient.defaultHomeDirectories()) }

    // Isolated home directories and a plaintext reader let fixtures exercise
    // snapshot handling without consulting a user's files or Keychain.
    init(homeDirectories: [URL], recordsReader: (@Sendable (BrowserCookieQuery, BrowserCookieStore) throws -> [BrowserCookieRecord])? = nil) {
        let client = BrowserCookieClient(configuration: .init(homeDirectories: homeDirectories))
        self.client = client
        self.recordsReader = recordsReader ?? { query, store in try client.records(matching: query, in: store) }
    }

    public func profiles(in source: BrowserLoginSource) throws -> [BrowserLoginProfile] {
        selectedStores(in: source).compactMap { store in
            guard let url = store.databaseURL else { return nil }
            return BrowserLoginProfile(id: Self.storeID(url), name: store.profile.name)
        }
    }

    public func readCookies(in source: BrowserLoginSource, profileID: String, providers: Set<WebProvider>) throws -> BrowserLoginImportResult {
        let websites = providers.filter { !$0.usesNativeConversation }
        guard !websites.isEmpty else { return BrowserLoginImportResult(cookies: [:]) }
        guard let store = selectedStores(in: source).first(where: { $0.databaseURL.map(Self.storeID) == profileID }) else {
            throw BrowserLoginImportError.storeUnavailable
        }
        let hosts = Set(websites.compactMap { $0.homeURL.host?.lowercased() })
        let query = BrowserCookieQuery(domains: hosts.sorted(), domainMatch: .suffix)

        do {
            let records: [BrowserCookieRecord]
            var sameSite: [CookieIdentity: String] = [:]
            if source == .chrome {
                guard let url = store.databaseURL else { throw BrowserLoginImportError.storeUnavailable }
                let snapshot = try ChromiumSnapshot(source: url, hosts: hosts)
                defer { snapshot.remove() }
                sameSite = snapshot.sameSite
                let snapshotStore = BrowserCookieStore(browser: store.browser, profile: store.profile, kind: store.kind,
                    label: store.label, databaseURL: snapshot.url)
                records = try recordsReader(query, snapshotStore)
            } else {
                records = try recordsReader(query, store)
            }

            let now = Date()
            var imported: [WebProvider: [HTTPCookie]] = [:]
            for provider in websites {
                guard let host = provider.homeURL.host?.lowercased() else { continue }
                imported[provider] = records.compactMap { record in
                    guard Self.matches(domain: record.domain, websiteHost: host),
                          record.expires.map({ $0 > now }) ?? true else { return nil }
                    return Self.cookie(record, sameSite: sameSite[CookieIdentity(record)])
                }
            }
            return BrowserLoginImportResult(cookies: imported)
        } catch let error as BrowserLoginImportError {
            throw error
        } catch let error as BrowserCookieError {
            if case .accessDenied = error { throw BrowserLoginImportError.accessDenied(source) }
            throw BrowserLoginImportError.unreadableStore(source)
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            throw BrowserLoginImportError.accessDenied(source)
        } catch {
            // Never surface external SQLite/parser errors: their details can
            // contain browser paths or database content.
            throw BrowserLoginImportError.unreadableStore(source)
        }
    }

    private func selectedStores(in source: BrowserLoginSource) -> [BrowserCookieStore] {
        var seen: Set<String> = []
        var stores = client.stores(for: source.browser)
        if source == .chrome {
            // Prefer Chrome's current store over a stale database left by migration.
            stores = stores.filter { $0.kind == .network } + stores.filter { $0.kind != .network }
        }
        return stores.filter { store in
            guard let url = store.databaseURL else { return false }
            return seen.insert(source == .chrome ? store.profile.id : Self.storeID(url)).inserted
        }
    }

    private static func storeID(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    static func matches(domain: String, websiteHost: String) -> Bool {
        let domain = domain.lowercased()
        return domain == websiteHost || domain.hasSuffix(".\(websiteHost)")
    }

    private static func cookie(_ record: BrowserCookieRecord, sameSite: String?) -> HTTPCookie? {
        let host = record.domain.lowercased()
        guard let origin = URL(string: "https://\(host)"), origin.host == host else { return nil }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: record.scope == .domain ? ".\(host)" : host,
            .originURL: origin, .name: record.name, .value: record.value, .path: record.path,
        ]
        if record.isSecure { properties[.secure] = "TRUE" }
        if record.isHTTPOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let expires = record.expires { properties[.expires] = expires }
        if let sameSite { properties[HTTPCookiePropertyKey("SameSite")] = sameSite }
        return HTTPCookie(properties: properties)
    }
}

private struct CookieIdentity: Hashable {
    let domain: String
    let name: String
    let path: String
    init(_ record: BrowserCookieRecord) {
        domain = (record.scope == .domain ? "." : "") + record.domain.lowercased()
        name = record.name
        path = record.path
    }
    init(domain: String, name: String, path: String) {
        self.domain = domain.lowercased(); self.name = name; self.path = path
    }
}

/// sqlite3_backup includes committed WAL rows. Only the private snapshot is
/// sanitized; the selected browser database is opened read-only.
private struct ChromiumSnapshot {
    let directory: URL
    let url: URL
    let sameSite: [CookieIdentity: String]

    init(source: URL, hosts: Set<String>) throws {
        let manager = FileManager.default
        directory = manager.temporaryDirectory.appendingPathComponent("msgblast-browser-login-\(UUID())", isDirectory: true)
        url = directory.appendingPathComponent("Cookies")
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            sameSite = try Self.copyAndSanitize(source: source, target: url, hosts: hosts)
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    private static func copyAndSanitize(source: URL, target: URL, hosts: Set<String>) throws -> [CookieIdentity: String] {
        var original: OpaquePointer?
        var snapshot: OpaquePointer?
        defer { sqlite3_close(original); sqlite3_close(snapshot) }
        guard sqlite3_open_v2(source.path, &original, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw SnapshotError.failed }
        guard sqlite3_open_v2(target.path, &snapshot, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else { throw SnapshotError.failed }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        sqlite3_busy_timeout(original, 1_000)
        guard let backup = sqlite3_backup_init(snapshot, "main", original, "main") else { throw SnapshotError.failed }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else { throw SnapshotError.failed }
        try execute("PRAGMA journal_mode=DELETE; PRAGMA secure_delete=ON", in: snapshot)

        let columns = try cookieColumns(in: snapshot)
        if columns.contains("top_frame_site_key") {
            // Partition context cannot be represented by an ordinary HTTPCookie.
            try execute("DELETE FROM cookies WHERE COALESCE(top_frame_site_key, '') <> ''", in: snapshot)
        }
        let predicate = hosts.sorted().map { _ in "(lower(ltrim(host_key, '.')) = ? OR lower(ltrim(host_key, '.')) LIKE ?)" }.joined(separator: " OR ")
        var delete: OpaquePointer?
        guard sqlite3_prepare_v2(snapshot, "DELETE FROM cookies WHERE NOT (\(predicate))", -1, &delete, nil) == SQLITE_OK else { throw SnapshotError.failed }
        defer { sqlite3_finalize(delete) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, host) in hosts.sorted().enumerated() {
            guard sqlite3_bind_text(delete, Int32(index * 2 + 1), host, -1, transient) == SQLITE_OK,
                  sqlite3_bind_text(delete, Int32(index * 2 + 2), "%.\(host)", -1, transient) == SQLITE_OK else { throw SnapshotError.failed }
        }
        guard sqlite3_step(delete) == SQLITE_DONE else { throw SnapshotError.failed }
        // Remove deleted domains/partitions from free pages before the library
        // copies this snapshot for decryption.
        try execute("VACUUM", in: snapshot)

        guard columns.contains("samesite") else { return [:] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(snapshot, "SELECT host_key, name, path, samesite FROM cookies", -1, &statement, nil) == SQLITE_OK else { throw SnapshotError.failed }
        defer { sqlite3_finalize(statement) }
        var metadata: [CookieIdentity: String] = [:]
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            guard let host = text(statement, 0), let name = text(statement, 1), let path = text(statement, 2) else { throw SnapshotError.failed }
            let attribute: String?
            switch sqlite3_column_int(statement, 3) {
            case 0: attribute = "None"
            case 1: attribute = "Lax"
            case 2: attribute = "Strict"
            default: attribute = nil
            }
            if let attribute { metadata[CookieIdentity(domain: host, name: name, path: path)] = attribute }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw SnapshotError.failed }
        return metadata
    }

    private static func cookieColumns(in db: OpaquePointer?) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(cookies)", -1, &statement, nil) == SQLITE_OK else { throw SnapshotError.failed }
        defer { sqlite3_finalize(statement) }
        var columns: Set<String> = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            if let name = text(statement, 1) { columns.insert(name) }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE, !columns.isEmpty else { throw SnapshotError.failed }
        return columns
    }

    private static func execute(_ sql: String, in db: OpaquePointer?) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw SnapshotError.failed }
    }

    private static func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }
}

private enum SnapshotError: Error { case failed }
