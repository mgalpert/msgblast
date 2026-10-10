import XCTest
import SQLite3
import CommonCrypto
import CryptoKit
import Security
@testable import SweetCookieKit
@testable import msgblastCore

final class BrowserLoginImporterTests: XCTestCase {
    func testEncryptedChromiumFixtureUsesPinnedReaderWithoutKeychainAccess() throws {
        let home = try fixtureHome(); defer { try? FileManager.default.removeItem(at: home) }
        ChromeCookieImporter.resetSafeStorageKeyCacheForTesting()
        defer { ChromeCookieImporter.resetSafeStorageKeyCacheForTesting() }
        let key = try ChromeCookieImporter.chromeSafeStorageKey(for: .chrome, labels: [("Fixture", "Fixture")], passwordLookup: { _, _, _ in (errSecSuccess, "synthetic-test-password") })
        let host = "chatgpt.com"
        let payload = Data(SHA256.hash(data: Data(host.utf8))) + Data("encrypted-local-fixture".utf8)
        var encrypted = Data(count: payload.count + kCCBlockSizeAES128)
        var length = 0
        let capacity = encrypted.count
        let status = encrypted.withUnsafeMutableBytes { output in
            key.withUnsafeBytes { keyBytes in
                payload.withUnsafeBytes { input in
                    let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
                    return iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), keyBytes.baseAddress, key.count, ivBytes.baseAddress, input.baseAddress, payload.count, output.baseAddress, capacity, &length)
                    }
                }
            }
        }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        encrypted.count = length
        let value = Data("v10".utf8) + encrypted
        let file = try chromeFixture(in: home, profile: "Default", rows: "INSERT INTO cookies VALUES('chatgpt.com','session','/','',0,1,1,2,''); INSERT INTO cookies VALUES('muse.ai','wrong-host','/','',0,1,1,2,'');")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "ALTER TABLE cookies ADD COLUMN encrypted_value BLOB; CREATE TABLE meta(key TEXT,value TEXT); INSERT INTO meta VALUES('version','24');", nil, nil, nil), SQLITE_OK)
        var update: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "UPDATE cookies SET encrypted_value = ?", -1, &update, nil), SQLITE_OK)
        defer { sqlite3_finalize(update) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        XCTAssertEqual(value.withUnsafeBytes { sqlite3_bind_blob(update, 1, $0.baseAddress, Int32(value.count), transient) }, SQLITE_OK)
        XCTAssertEqual(sqlite3_step(update), SQLITE_DONE)
        let importer = BrowserLoginImporter(homeDirectories: [home])
        let profile = try XCTUnwrap(importer.profiles(in: .chrome).first)
        let result = try importer.readCookies(in: .chrome, profileID: profile.id, providers: [.chatgpt, .muse])
        XCTAssertEqual(result.cookies[.chatgpt]?.first?.value, "encrypted-local-fixture")
        XCTAssertTrue(result.cookies[.muse, default: []].isEmpty, "Version24 cookies must bind the encrypted value to its original host")
    }

    func testSafariImportsSelectedWebsiteScopeAndAttributesWithoutNativeProviders() throws {
        let home = try fixtureHome(); defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("Library/Cookies/Cookies.binarycookies")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fixture = safariFixture([
            ("chatgpt.com", "host", "/", "host-fixture", nil, 5),
            (".chatgpt.com", "domain", "/account", "domain-fixture", future, 5),
            (".auth.chatgpt.com", "subdomain", "/", "subdomain-fixture", future, 1),
            ("evilchatgpt.com", "lookalike", "/", "unrelated-fixture", future, 1),
            (".claude.ai", "other-provider", "/", "unrelated-fixture", future, 1),
            ("chatgpt.com", "expired", "/", "expired-fixture", Date(timeIntervalSince1970: 1_100_000_000), 1),
        ])
        try fixture.write(to: file)
        let importer = BrowserLoginImporter(homeDirectories: [home])
        let profile = try XCTUnwrap(importer.profiles(in: .safari).first)
        let result = try importer.readCookies(in: .safari, profileID: profile.id, providers: [.chatgpt, .codexCLI, .claudeCode, .grokbot])
        let cookies = try XCTUnwrap(result.cookies[.chatgpt])
        XCTAssertEqual(Set(cookies.map(\.name)), ["host", "domain", "subdomain"])
        let host = try XCTUnwrap(cookies.first { $0.name == "host" })
        let domain = try XCTUnwrap(cookies.first { $0.name == "domain" })
        XCTAssertEqual(host.domain, "chatgpt.com")
        XCTAssertEqual(domain.domain, ".chatgpt.com")
        XCTAssertEqual(domain.path, "/account")
        XCTAssertTrue(host.isHTTPOnly)
        XCTAssertTrue(host.isSecure)
        XCTAssertNil(host.expiresDate)
        XCTAssertEqual(domain.expiresDate?.timeIntervalSince1970, future.timeIntervalSince1970)
        XCTAssertEqual(Set(result.cookies.keys), [.chatgpt])
        XCTAssertEqual(try Data(contentsOf: file), fixture)
    }

    // Chromium tests inject a plaintext record reader. They prove the selected
    // snapshot and HTTPCookie output; they never access a user's Keychain.
    func testChromiumSnapshotExcludesPartitionsAndLookalikesAndPreservesSameSite() throws {
        let home = try fixtureHome(); defer { try? FileManager.default.removeItem(at: home) }
        let file = try chromeFixture(in: home, profile: "Default", rows: """
        INSERT INTO cookies VALUES('chatgpt.com','host','/','host-fixture',0,1,1,2,'');
        INSERT INTO cookies VALUES('.chatgpt.com','domain','/account','domain-fixture',0,1,1,1,'');
        INSERT INTO cookies VALUES('.chatgpt.com','none','/','none-fixture',0,1,0,0,'');
        INSERT INTO cookies VALUES('.auth.chatgpt.com','subdomain','/','subdomain-fixture',0,1,0,-1,'');
        INSERT INTO cookies VALUES('chatgpt.com','partitioned','/','partition-fixture',0,1,1,0,'https://elsewhere.example');
        INSERT INTO cookies VALUES('evilchatgpt.com','lookalike','/','unrelated-fixture',0,1,1,1,'');
        INSERT INTO cookies VALUES('claude.ai','other-provider','/','unrelated-fixture',0,1,1,1,'');
        INSERT INTO cookies VALUES('chatgpt.com','expired','/','expired-fixture',11644473601000000,1,1,1,'');
        """)
        let before = try Data(contentsOf: file)
        let tracker = SnapshotTracker()
        let importer = BrowserLoginImporter(homeDirectories: [home], recordsReader: { query, store in
            let file = try XCTUnwrap(store.databaseURL)
            tracker.path = file
            let directoryPermissions = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
            let filePermissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(directoryPermissions?.intValue, 0o700)
            XCTAssertEqual(filePermissions?.intValue, 0o600)
            let records = try Self.plaintextRecords(at: file)
            XCTAssertFalse(records.contains { ["partitioned", "lookalike", "other-provider"].contains($0.name) })
            return records
        })
        let profile = try XCTUnwrap(importer.profiles(in: .chrome).first)
        let result = try importer.readCookies(in: .chrome, profileID: profile.id, providers: [.chatgpt, .dots])
        let cookies = try XCTUnwrap(result.cookies[.chatgpt])
        XCTAssertEqual(Set(cookies.map(\.name)), ["host", "domain", "none", "subdomain"])
        XCTAssertEqual(cookies.first { $0.name == "host" }?.domain, "chatgpt.com")
        XCTAssertEqual(cookies.first { $0.name == "domain" }?.domain, ".chatgpt.com")
        XCTAssertEqual(cookies.first { $0.name == "domain" }?.path, "/account")
        XCTAssertEqual(cookies.first { $0.name == "host" }?.properties?[HTTPCookiePropertyKey("SameSite")] as? String, "strict")
        XCTAssertEqual(cookies.first { $0.name == "domain" }?.properties?[HTTPCookiePropertyKey("SameSite")] as? String, "lax")
        XCTAssertEqual(cookies.first { $0.name == "none" }?.properties?[HTTPCookiePropertyKey("SameSite")] as? String, "none")
        XCTAssertEqual(Set(result.cookies[.dots, default: []].map(\.name)), Set(cookies.map(\.name)))
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(tracker.path).deletingLastPathComponent().path))
    }

    func testChromiumReadsCommittedWALAndCleansSnapshotAfterReaderFailure() throws {
        let home = try fixtureHome(); defer { try? FileManager.default.removeItem(at: home) }
        let file = try chromeFixture(in: home, profile: "Default", rows: "")
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; INSERT INTO cookies VALUES('chatgpt.com','wal','/','wal-fixture',0,1,1,1,'');", nil, nil, nil), SQLITE_OK)
        let before = try Data(contentsOf: file)
        let tracker = SnapshotTracker()
        let importer = BrowserLoginImporter(homeDirectories: [home], recordsReader: { _, store in
            let url = try XCTUnwrap(store.databaseURL)
            tracker.path = url
            XCTAssertEqual(try Self.plaintextRecords(at: url).map(\.name), ["wal"])
            throw FixtureFailure.failed
        })
        let profile = try XCTUnwrap(importer.profiles(in: .chrome).first)
        XCTAssertThrowsError(try importer.readCookies(in: .chrome, profileID: profile.id, providers: [.chatgpt]))
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(tracker.path).deletingLastPathComponent().path))
    }

    func testProfilesStaySeparateAndMissingOrEmptyStoresDoNotReadAnotherProfile() throws {
        let home = try fixtureHome(); defer { try? FileManager.default.removeItem(at: home) }
        let first = try chromeFixture(in: home, profile: "Default", rows: "INSERT INTO cookies VALUES('chatgpt.com','first','/','fixture',0,1,1,1,'');")
        let second = try chromeFixture(in: home, profile: "Profile 1", rows: "INSERT INTO cookies VALUES('chatgpt.com','second','/','fixture',0,1,1,1,'');")
        // Chrome can retain an older database beside its current Network store.
        let legacy = first.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Cookies")
        try FileManager.default.copyItem(at: first, to: legacy)
        let importer = BrowserLoginImporter(homeDirectories: [home], recordsReader: { _, store in try Self.plaintextRecords(at: XCTUnwrap(store.databaseURL)) })
        let profiles = try importer.profiles(in: .chrome)
        XCTAssertEqual(Set(profiles.map(\.id)), [first.path, second.path])
        XCTAssertEqual(try importer.readCookies(in: .chrome, profileID: first.path, providers: [.chatgpt]).cookies[.chatgpt]?.map(\.name), ["first"])
        XCTAssertEqual(try importer.readCookies(in: .chrome, profileID: second.path, providers: [.chatgpt]).cookies[.chatgpt]?.map(\.name), ["second"])
        try FileManager.default.removeItem(at: first)
        XCTAssertThrowsError(try importer.readCookies(in: .chrome, profileID: first.path, providers: [.chatgpt]))
        XCTAssertTrue(try importer.readCookies(in: .chrome, profileID: "missing", providers: [.codexCLI, .claudeCode, .grokbot]).cookies.isEmpty)
        XCTAssertTrue(try importer.readCookies(in: .chrome, profileID: second.path, providers: [.muse]).cookies[.muse, default: []].isEmpty)
        let emptyHome = try fixtureHome(); defer { try? FileManager.default.removeItem(at: emptyHome) }
        let noStores = BrowserLoginImporter(homeDirectories: [emptyHome])
        XCTAssertTrue(try noStores.profiles(in: .chrome).isEmpty)
        XCTAssertTrue(try noStores.profiles(in: .safari).isEmpty)
        XCTAssertThrowsError(try noStores.readCookies(in: .safari, profileID: "missing", providers: [.chatgpt]))
    }

    // Foundation caps distant artificial expiries; use a real browser lifetime.
    private let future = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 86_400)

    private func fixtureHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-cookie-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return home
    }

    private func chromeFixture(in home: URL, profile: String, rows: String) throws -> URL {
        let file = home.appendingPathComponent("Library/Application Support/Google/Chrome/\(profile)/Network/Cookies")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE cookies(host_key TEXT, name TEXT, path TEXT, value TEXT, expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER, samesite INTEGER, top_frame_site_key TEXT); \(rows)", nil, nil, nil), SQLITE_OK)
        return file
    }

    private static func plaintextRecords(at file: URL) throws -> [BrowserCookieRecord] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw FixtureFailure.failed }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT host_key,name,path,value,expires_utc,is_secure,is_httponly FROM cookies", -1, &statement, nil) == SQLITE_OK else { throw FixtureFailure.failed }
        defer { sqlite3_finalize(statement) }
        var records: [BrowserCookieRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let domain = String(cString: sqlite3_column_text(statement, 0))
            let expiry = sqlite3_column_int64(statement, 4)
            records.append(BrowserCookieRecord(domain: domain.hasPrefix(".") ? String(domain.dropFirst()) : domain,
                name: String(cString: sqlite3_column_text(statement, 1)), path: String(cString: sqlite3_column_text(statement, 2)),
                value: String(cString: sqlite3_column_text(statement, 3)),
                expires: expiry == 0 ? nil : Date(timeIntervalSince1970: Double(expiry) / 1_000_000 - 11_644_473_600),
                isSecure: sqlite3_column_int(statement, 5) != 0, isHTTPOnly: sqlite3_column_int(statement, 6) != 0,
                scope: domain.hasPrefix(".") ? .domain : .hostOnly))
        }
        return records
    }

    private func safariFixture(_ cookies: [(String, String, String, String, Date?, UInt32)]) -> Data {
        func u32(_ value: UInt32, big: Bool = false) -> Data {
            var value = big ? value.bigEndian : value.littleEndian
            return withUnsafeBytes(of: &value) { Data($0) }
        }
        func double(_ value: Double) -> Data {
            var bits = value.bitPattern.littleEndian
            return withUnsafeBytes(of: &bits) { Data($0) }
        }
        let records = cookies.map { domain, name, path, value, expiry, flags in
            let strings = [domain, name, path, value].map { Data($0.utf8) + Data([0]) }
            var offsets: [UInt32] = []; var offset: UInt32 = 56
            for string in strings { offsets.append(offset); offset += UInt32(string.count) }
            var record = u32(offset) + u32(0) + u32(flags) + u32(0)
            for offset in offsets { record += u32(offset) }
            record += u32(0) + u32(0) + double(expiry?.timeIntervalSinceReferenceDate ?? 0) + double(0)
            strings.forEach { record += $0 }
            return record
        }
        var page = u32(0x100) + u32(UInt32(records.count))
        var offset = UInt32(12 + 4 * records.count)
        for record in records { page += u32(offset); offset += UInt32(record.count) }
        page += u32(0)
        records.forEach { page += $0 }
        return Data("cook".utf8) + u32(1, big: true) + u32(UInt32(page.count), big: true) + page
    }
}

private enum FixtureFailure: Error { case failed }

private final class SnapshotTracker: @unchecked Sendable {
    // The injected reader and assertion run synchronously in the same test.
    var path: URL?
}
