import XCTest
import msgblastCore

final class CrashReportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func report(bundle: String = "com.msgblast.mac", signal: String = "SIGABRT") throws -> Data {
        let header: [String: Any] = ["bug_type": "309", "incident_id": "12345678-1234-1234-1234-123456789abc"]
        let body: [String: Any] = ["bundleInfo": ["CFBundleIdentifier": bundle, "CFBundleShortVersionString": "0.9.0", "CFBundleVersion": "40"],
            "procPath": "/Applications/msgblast.app/Contents/MacOS/msgblast", "captureTime": "2026-09-21 12:26:40.000 +0000",
            "exception": ["type": "EXC_CRASH", "signal": signal, "message": "secret message"],
            "usedImages": [["uuid": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "arch": "arm64", "path": "/Users/private/token"]],
            "threads": [["triggered": true, "frames": [["imageIndex": 0, "imageOffset": 1234, "symbol": "private chat text"]]]]]
        return try JSONSerialization.data(withJSONObject: header) + Data([10]) + JSONSerialization.data(withJSONObject: body)
    }
    func testParserOnlyExportsAllowlistedCrashData() throws {
        let crash = try XCTUnwrap(CrashReport.parse(try report(), bundleIdentifier: "com.msgblast.mac", appPath: "/Applications/msgblast.app", now: now))
        let preview = crash.preview
        XCTAssertTrue(preview.contains("1234"))
        for secret in ["private", "/Users", "secret message", "symbol", "procPath"] { XCTAssertFalse(preview.contains(secret)) }
        XCTAssertEqual(crash.version, "0.9.0")
        XCTAssertEqual(crash.frames.count, 1)
    }
    func testRejectsOtherAppsNormalTerminationStaleMalformedAndOversized() throws {
        for data in [try report(bundle: "com.other.app"), try report(signal: "SIGTERM"), try report(signal: "SIGKILL"), Data("{}".utf8), Data(repeating: 32, count: 2_097_153)] {
            XCTAssertNil(CrashReport.parse(data, bundleIdentifier: "com.msgblast.mac", appPath: "/Applications/msgblast.app", now: now))
        }
        XCTAssertNil(CrashReport.parse(try report(), bundleIdentifier: "com.msgblast.mac", appPath: "/Applications/msgblast.app", now: now.addingTimeInterval(31 * 86400)))
    }
    func testDismissalSubmissionAndUncertainRetrySurviveRelaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let crash = try XCTUnwrap(CrashReport.parse(try report(), bundleIdentifier: "com.msgblast.mac", appPath: "/Applications/msgblast.app", now: now))
        let store = try CrashReportStore(directory: root)
        XCTAssertTrue(store.shouldOffer(crash))
        try store.dismiss(crash)
        XCTAssertFalse(try CrashReportStore(directory: root).shouldOffer(crash))
        let attempt = try store.prepare(crash, note: "Optional fixture context")
        let reopened = try CrashReportStore(directory: root)
        XCTAssertEqual(try reopened.prepare(crash, note: "changed after uncertain result"), attempt)
        XCTAssertFalse(reopened.isSubmitted(crash))
        XCTAssertEqual(reopened.pendingReports, [crash], "Frozen report must remain available without the original IPS")
        try reopened.confirm(crash)
        let final = try CrashReportStore(directory: root)
        XCTAssertTrue(final.isSubmitted(crash))
        XCTAssertTrue(final.pendingReports.isEmpty)
        XCTAssertThrowsError(try final.prepare(crash, note: "duplicate"))
    }
    func testCollectorFindsRetiredReportsAndIgnoresSymlinksAndOtherNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let retired = root.appendingPathComponent("Retired")
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try report()
        try data.write(to: retired.appendingPathComponent("msgblast-fixture.ips"))
        let unrelated = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "12345678-1234-1234-1234-123456789abc", with: "87654321-1234-1234-1234-123456789abc").utf8)
        try unrelated.write(to: root.appendingPathComponent("unrelated.ips"))
        let target = root.appendingPathComponent("outside.txt")
        try Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "12345678-1234-1234-1234-123456789abc", with: "99999999-1234-1234-1234-123456789abc").utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("msgblast-link.ips"), withDestinationURL: target)
        let found = CrashReport.collect(directory: root, bundleIdentifier: "com.msgblast.mac", appPath: "/Applications/msgblast.app", now: now)
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(CrashReport.collect(directory: root.appendingPathComponent("missing"), bundleIdentifier: "com.msgblast.mac", appPath: "/Applications/msgblast.app", now: now).isEmpty)
    }
    func testHelperMustBelongToThisExactAppAndPreservesFrameOffsets() throws {
        let raw = try report()
        let split = try XCTUnwrap(raw.firstIndex(of: 10))
        var body = try XCTUnwrap(JSONSerialization.jsonObject(with: raw[(split + 1)...]) as? [String: Any])
        body["bundleInfo"] = nil
        body["procPath"] = "/Applications/msgblast.app/Contents/Helpers/cloudflared"
        let helper = raw[..<split] + Data([10]) + (try JSONSerialization.data(withJSONObject: body))
        let parsed = try XCTUnwrap(CrashReport.parse(helper, bundleIdentifier: "com.msgblast.mac", appPath: "/Applications/msgblast.app", now: now))
        XCTAssertEqual(parsed.process, "helper")
        XCTAssertEqual(parsed.version, "unknown")
        XCTAssertNil(CrashReport.parse(helper, bundleIdentifier: "com.msgblast.mac", appPath: "/Applications/other.app", now: now))
    }
    func testMalformedJournalFailsClosedAndNeverChangesApplicationState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = Data("private state fixture".utf8)
        try state.write(to: root.appendingPathComponent("state.json"))
        try Data("broken".utf8).write(to: root.appendingPathComponent("crash-reports.json"))
        XCTAssertThrowsError(try CrashReportStore(directory: root))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("state.json")), state)
    }
    func testFingerprintGroupsSameStackWithoutIncidentIdentity() throws {
        let first = try XCTUnwrap(CrashReport.parse(try report(), bundleIdentifier: "com.msgblast.mac", appPath: "/Applications/msgblast.app", now: now))
        let raw = String(decoding: try report(), as: UTF8.self).replacingOccurrences(of: "12345678-1234-1234-1234-123456789abc", with: "87654321-1234-1234-1234-123456789abc")
        let second = try XCTUnwrap(CrashReport.parse(Data(raw.utf8), bundleIdentifier: "com.msgblast.mac", appPath: "/Applications/msgblast.app", now: now))
        XCTAssertNotEqual(first.incident, second.incident)
        XCTAssertEqual(first.fingerprint, second.fingerprint)
    }

    func testCrashSubmissionMatchesReviewedSummaryAndRejectsInvalidKind() throws {
        let crash = try XCTUnwrap(CrashReport.parse(try report(), bundleIdentifier: "com.msgblast.mac", appPath: "/Applications/msgblast.app", now: now))
        var request = DiagnosticRequest(kind: .crash, note: "Crash report (no additional context).", facts: .empty())
        request.crash = crash
        let bytes = try FeedbackSubmission.encodeRequest(request, id: UUID())
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(body["kind"] as? String, "crash")
        XCTAssertNil(body["diagnostics"])
        let summary = try XCTUnwrap(body["crash"] as? [String: Any])
        XCTAssertEqual(summary["incident"] as? String, crash.incident)
        XCTAssertEqual(Set(summary.keys), Set((try JSONSerialization.jsonObject(with: Data(crash.preview.utf8)) as! [String: Any]).keys))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("private"))
        request.kind = .feedback
        XCTAssertThrowsError(try FeedbackSubmission.encodeRequest(request, id: UUID()))
    }

    func testJournalWriteFailuresDoNotCreateAttemptOrConfirmSuccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let crash = try XCTUnwrap(CrashReport.parse(try report(), bundleIdentifier: "com.msgblast.mac", appPath: "/Applications/msgblast.app", now: now))
        let store = try CrashReportStore(directory: root)
        let journal = root.appendingPathComponent("crash-reports.json")
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.prepare(crash, note: "fixture"))
        XCTAssertNil(store.attempt(crash))
        try FileManager.default.removeItem(at: journal)
        let attempt = try store.prepare(crash, note: "fixture")
        try FileManager.default.removeItem(at: journal)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.confirm(crash))
        XCTAssertFalse(store.isSubmitted(crash))
        XCTAssertEqual(store.attempt(crash), attempt)
    }
    func testCollectorDeduplicatesIncidentsAndSkipsOldFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let retired = root.appendingPathComponent("Retired")
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = try report()
        for file in [root.appendingPathComponent("msgblast-first.ips"), retired.appendingPathComponent("msgblast-copy.ips")] {
            try raw.write(to: file)
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        }
        let stale = root.appendingPathComponent("msgblast-old.ips")
        try Data(String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "12345678-1234-1234-1234-123456789abc", with: "99999999-1234-1234-1234-123456789abc").utf8).write(to: stale)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-32 * 86400)], ofItemAtPath: stale.path)
        let reports = CrashReport.collect(directory: root, bundleIdentifier: "com.msgblast.mac", appPath: "/Applications/msgblast.app", now: now)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.incident, "12345678-1234-1234-1234-123456789abc")
    }

}
