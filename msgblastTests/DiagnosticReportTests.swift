import XCTest
import msgblastCore

final class DiagnosticReportTests: XCTestCase {
    private let email = "ada@example.com"
    private let phone = "+1 (415) 555-1212"
    private let path = "/Users/secret/Library/Messages/chat.db"
    private let prompt = "Please text the launch code 42"
    private let key = "sk-live-secret"
    private let now = Date(timeIntervalSince1970: 1_759_000_000)

    private func hostileFacts() -> DiagnosticFacts {
        DiagnosticFacts(
            version: path, buildNumber: "1; rm", bundleIdentifier: "com.msgblast.mac", fixtureMode: false,
            operatingSystem: "Version 15.0 (Build 24A335) \(path)", updatesEnabled: false, updatesReason: key,
            messagesStatus: "failed at \(path) for \(email) \(phone)", permissionStage: "idle; cat chat.db",
            agentCount: -3, comparisonCount: 2, hasDraft: true, attachmentCount: 4, windowStyle: "connected/\(prompt)",
            personalAgent: "codex; \(path)", webProviderCounts: ["chatgpt": 2, "https://evil.example/\(key)": 9],
            lastError: "Send to Ada <\(email)> \(phone) failed: \(prompt)", supportFolder: path,
            stateFilePresent: true, stateFileBytes: 2048)
    }

    private func request(includeDiagnostics: Bool, contact: String = "") -> DiagnosticRequest {
        DiagnosticRequest(kind: .bug, note: "The composer stayed disabled after a failed save.", contact: contact, includeDiagnostics: includeDiagnostics, facts: hostileFacts())
    }

    func testDiagnosticsStayOutUntilTheCallerOptsIn() throws {
        let request = DiagnosticRequest(kind: .feedback, note: "Hello", facts: .empty())
        XCTAssertFalse(request.includeDiagnostics)
        let withheld = try DiagnosticReport.make(self.request(includeDiagnostics: false, contact: email), now: now)
        XCTAssertNil(withheld.diagnosticsPreview)
        XCTAssertEqual(try DiagnosticArchive.entries(withheld.archive).keys.sorted(), ["README.txt", "feedback.txt"])
        let included = try DiagnosticReport.make(self.request(includeDiagnostics: true), now: now)
        XCTAssertEqual(try DiagnosticArchive.entries(included.archive).keys.sorted(), ["README.txt", "diagnostics.json", "feedback.txt"])
        let preview = try XCTUnwrap(included.diagnosticsPreview)
        XCTAssertEqual(included.files.first { $0.0 == "diagnostics.json" }?.1, Data(preview.utf8))
    }

    func testOptInFileKeepsCountsAndDropsMessageContent() throws {
        let package = try DiagnosticReport.make(request(includeDiagnostics: true, contact: email), now: now)
        let entries = try DiagnosticArchive.entries(package.archive)
        let feedback = try XCTUnwrap(entries["feedback.txt"]).utf8String
        let diagnostics = try XCTUnwrap(entries["diagnostics.json"]).utf8String
        let readme = try XCTUnwrap(entries["README.txt"]).utf8String
        XCTAssertTrue(feedback.contains("Kind: Bug report"))
        XCTAssertTrue(feedback.contains("Contact: \(email)"))
        XCTAssertTrue(feedback.contains("Date: 2025-09-27"))
        XCTAssertTrue(readme.contains("Diagnostics: included"))
        XCTAssertTrue(readme.contains("This ZIP is a local copy created when you choose Save."))
        for topic in DiagnosticReport.excludedTopics { XCTAssertTrue(readme.contains(topic), topic) }
        let object = try JSONSerialization.jsonObject(with: Data(diagnostics.utf8)) as? [String: Any]
        XCTAssertEqual(Set(object.map { Array($0.keys) } ?? []), Set(DiagnosticReport.diagnosticKeys))
        XCTAssertEqual(object?["variant"] as? String, "production")
        XCTAssertEqual(object?["bundleIdentifier"] as? String, "com.msgblast.mac")
        XCTAssertEqual(object?["version"] as? String, "unknown")
        XCTAssertEqual(object?["operatingSystem"] as? String, "unknown")
        XCTAssertEqual(object?["messagesStatus"] as? String, "unavailable")
        XCTAssertEqual(object?["permissionStage"] as? String, "unknown")
        XCTAssertEqual(object?["personalAgent"] as? String, "none")
        XCTAssertEqual(object?["supportFolder"] as? String, "unknown")
        XCTAssertEqual(object?["updatesReason"] as? String, "unavailable")
        XCTAssertEqual(object?["windowStyle"] as? String, "unknown")
        XCTAssertEqual(object?["lastErrorCategory"] as? String, "send")
        XCTAssertEqual((object?["agentCount"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((object?["comparisonCount"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual((object?["stateFileBytes"] as? NSNumber)?.intValue, 2048)
        let counts = object?["webProviderCounts"] as? [String: Any]
        XCTAssertEqual(counts?.count, 1)
        XCTAssertEqual((counts?["chatgpt"] as? NSNumber)?.intValue, 2)
        let packed = package.archive.utf8String + diagnostics + readme
        for secret in [email, phone, path, prompt, key, "Ada", "secret"] {
            XCTAssertFalse(diagnostics.contains(secret), secret)
            XCTAssertFalse(readme.contains(secret), secret)
            XCTAssertFalse(packed.contains(secret) && secret != email, secret)
        }
        XCTAssertFalse(diagnostics.contains(email))
        XCTAssertTrue(feedback.contains(email))
    }

    func testKnownStatusStringsStayAndFreeTextDoesNot() throws {
        var facts = DiagnosticFacts.empty(bundleIdentifier: "com.msgblast.development", operatingSystem: "Version 15.1 (Build 24B83)")
        facts.version = "0.4.3"
        facts.buildNumber = "12"
        facts.messagesStatus = "Simulated Messages · no real sends"
        facts.permissionStage = "waitingForAccess"
        facts.personalAgent = "codex"
        facts.supportFolder = "msgblast-Dev"
        facts.windowStyle = "separate"
        facts.updatesReason = "Updates are disabled in previews and test runs."
        facts.lastError = "Could not save Settings: disk full"
        let json = DiagnosticReport.diagnosticsJSON(facts)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["variant"] as? String, "development")
        let remote = DiagnosticFacts.empty(bundleIdentifier: "com.msgblast.development.remote", operatingSystem: "Version 15.1 (Build 24B83)")
        let remoteObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(DiagnosticReport.diagnosticsJSON(remote).utf8)) as? [String: Any])
        XCTAssertEqual(remoteObject["variant"] as? String, "development")
        XCTAssertEqual(remoteObject["bundleIdentifier"] as? String, "com.msgblast.development.remote")
        XCTAssertEqual(object["operatingSystem"] as? String, "Version 15.1 (Build 24B83)")
        XCTAssertEqual(object["messagesStatus"] as? String, "simulated")
        XCTAssertEqual(object["permissionStage"] as? String, "waitingForAccess")
        XCTAssertEqual(object["personalAgent"] as? String, "codex")
        XCTAssertEqual(object["supportFolder"] as? String, "msgblast-Dev")
        XCTAssertEqual(object["windowStyle"] as? String, "separate")
        XCTAssertEqual(object["updatesReason"] as? String, "Updates are disabled in previews and test runs.")
        XCTAssertEqual(object["lastErrorCategory"] as? String, "storage")
        XCTAssertFalse(json.contains("disk full"))
        XCTAssertFalse(json.contains("Could not save"))
    }

    func testPackageRejectsEmptyNotesInvalidAddressesAndPrivateFiles() {
        XCTAssertThrowsError(try DiagnosticReport.make(DiagnosticRequest(kind: .feedback, note: " \n\t", facts: .empty())))
        XCTAssertThrowsError(try DiagnosticReport.make(DiagnosticRequest(kind: .feedback, note: "Hi", contact: "not-an-email", facts: .empty())))
        XCTAssertThrowsError(try DiagnosticReport.make(DiagnosticRequest(kind: .feedback, note: String(repeating: "a", count: DiagnosticReport.maximumNoteLength + 1), facts: .empty())))
        XCTAssertFalse(DiagnosticReport.isValidContact("ada example.com"))
        XCTAssertTrue(DiagnosticReport.isValidContact("ada@example.com"))
        for name in ["chat.db", "state.json", "../README.txt", "Attachments/photo.png", "feedback.txt/../../chat.db"] {
            XCTAssertThrowsError(try DiagnosticArchive.archive([(name, Data("secret".utf8))]), name)
        }
    }

    func testArchiveRoundTripAndPrivateTemporaryFile() throws {
        let package = try DiagnosticReport.make(request(includeDiagnostics: false), now: now)
        let restored = try DiagnosticArchive.entries(package.archive)
        XCTAssertEqual(restored["feedback.txt"], package.files.first { $0.0 == "feedback.txt" }?.1)
        XCTAssertTrue(String(decoding: restored["README.txt"] ?? Data(), as: UTF8.self).contains("Diagnostics: not included"))
        let url = try DiagnosticArchive.writeTemporary(package)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let fileMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
        let directoryMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(fileMode.intValue & 0o777, 0o600)
        XCTAssertEqual(directoryMode.intValue & 0o777, 0o700)
        let destination = url.deletingLastPathComponent().appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-x", "-k", url.path, destination.path]
        try task.run()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0)
        let names = try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted()
        XCTAssertEqual(names, ["README.txt", "feedback.txt"])
        let unpacked = try String(contentsOf: destination.appendingPathComponent("feedback.txt"), encoding: .utf8)
        XCTAssertFalse(unpacked.contains(path))
        XCTAssertFalse(unpacked.contains(prompt))
    }
}

private extension Data {
    var utf8String: String { String(decoding: self, as: UTF8.self) }
}
