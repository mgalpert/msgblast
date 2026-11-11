import XCTest
import msgblastCore

final class UpdateTests: XCTestCase {
    func testReleaseHistoryShowsOnlyInstalledAndEarlierVersionsInNumericOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for version in ["0.1.0", "0.5.1", "0.6.0", "0.10.0", "1.0.0", "draft"] {
            try "# msgblast \(version)\n\n- Changes for \(version)".write(to: directory.appendingPathComponent("\(version).md"), atomically: true, encoding: .utf8)
        }
        try "{\"0.10.0\":[\"Short highlight\"]}".write(to: directory.appendingPathComponent("highlights.json"), atomically: true, encoding: .utf8)
        try "[\"0.1.0\"]".write(to: directory.appendingPathComponent("unpublished.json"), atomically: true, encoding: .utf8)
        let history = ReleaseHistory(directory: directory, installedVersion: "0.10.0")
        XCTAssertEqual(history.entries.map(\.version), ["0.10.0", "0.6.0", "0.5.1"])
        XCTAssertEqual(history.current?.version, "0.10.0")
        XCTAssertTrue(history.current?.notes.contains("Changes for 0.10.0") == true)
        XCTAssertEqual(history.current?.highlights, ["Short highlight"])
        XCTAssertEqual(history.entries.last?.highlights, ["Changes for 0.5.1"])
        let missing = ReleaseHistory(directory: directory, installedVersion: "0.9.0")
        XCTAssertNil(missing.current, "Do not label an older release as the installed version")
        XCTAssertEqual(missing.entries.map(\.version), ["0.6.0", "0.5.1"])
    }

    func testReleaseHighlightsStayShortAndPreserveContributorCredits() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let notes = "# msgblast 0.6.0\n\n- One\n- Two\n- Three\n- Details\n\n## Contributors\n\nThanks to [@helper](https://github.com/helper)."
        try notes.write(to: directory.appendingPathComponent("0.6.0.md"), atomically: true, encoding: .utf8)
        let entry = try XCTUnwrap(ReleaseHistory(directory: directory, installedVersion: "0.6.0").current)
        XCTAssertEqual(entry.highlights, ["One", "Two", "Three"])
        XCTAssertEqual(entry.contributors, "Thanks to [@helper](https://github.com/helper).")
        XCTAssertTrue(entry.notes.contains("Details"), "The full notes remain available")
    }

    func testReleaseHistoryHandlesUnavailableNotes() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(ReleaseHistory(directory: directory, installedVersion: "0.6.0").entries.isEmpty)
        XCTAssertTrue(ReleaseHistory(directory: directory, installedVersion: "Unknown").entries.isEmpty)
    }

    private let key = Data(repeating: 7, count: 32).base64EncodedString()
    private func configuration(_ feed: String = "https://updates.example.com/appcast.xml", id: String = "com.msgblast.mac", demo: Bool = false, args: [String] = [], fixture: Bool = false, allowFixture: Bool = false, app: Bool = true) -> UpdateConfiguration {
        UpdateConfiguration(bundleURL: URL(fileURLWithPath: app ? "/Applications/msgblast.app" : "/tmp/msgblast"), bundleIdentifier: id,
            info: ["SUFeedURL": feed, "SUPublicEDKey": key, "msgblastDemo": demo, "msgblastUpdateFixture": fixture, "msgblastFixtureStore": FileManager.default.temporaryDirectory.appendingPathComponent("update-fixture").path], arguments: args, allowLocalFixture: allowFixture)
    }
    func testOnlyConfiguredRealAppsQueryTheProductionFeed() {
        XCTAssertTrue(configuration().isEnabled)
        XCTAssertFalse(configuration("").isEnabled)
        XCTAssertFalse(configuration("http://updates.example.com/appcast.xml").isEnabled)
        XCTAssertFalse(configuration(id: "com.msgblast.discover-preview").isEnabled)
        XCTAssertFalse(configuration("https://updates.msgblast.app/appcast.xml", id: "com.msgblast.development").isEnabled)
        XCTAssertFalse(configuration("https://updates.msgblast.app/appcast.xml", id: "com.msgblast.development.remote").isEnabled)
        XCTAssertFalse(configuration("https://updates.msgblast.app/appcast.xml", id: "com.msgblast.demo", demo: true).isEnabled)
        XCTAssertFalse(configuration(demo: true).isEnabled)
        XCTAssertFalse(configuration(args: ["--demo"]).isEnabled)
        XCTAssertFalse(configuration(app: false).isEnabled)
        let invalidKey = UpdateConfiguration(bundleURL: URL(fileURLWithPath: "/Applications/msgblast.app"), bundleIdentifier: "com.msgblast.mac", info: ["SUFeedURL": "https://updates.example.com/appcast.xml", "SUPublicEDKey": "not a public key"], arguments: [])
        XCTAssertFalse(invalidKey.isEnabled)
    }
    func testLocalFixtureCannotEnableOrdinaryPreviewsOrReleaseBuilds() {
        XCTAssertTrue(configuration("http://127.0.0.1:8000/appcast.xml", id: "com.msgblast.update-fixture", demo: true, fixture: true, allowFixture: true).isEnabled)
        XCTAssertFalse(configuration("http://127.0.0.1:8000/appcast.xml", id: "com.msgblast.update-fixture", demo: true, fixture: true).isEnabled)
        XCTAssertFalse(configuration("http://remote.example.com/appcast.xml", id: "com.msgblast.update-fixture", fixture: true, allowFixture: true).isEnabled)
        XCTAssertFalse(configuration("http://127.0.0.1:8000/appcast.xml", id: "com.msgblast.discover-preview", fixture: true, allowFixture: true).isEnabled)
    }
    func testXCTestHostNeverQueriesTheProductionFeed() {
        let config = UpdateConfiguration(bundleURL: URL(fileURLWithPath: "/Applications/msgblast.app"), bundleIdentifier: "com.msgblast.mac",
            info: ["SUFeedURL": "https://updates.example.com/appcast.xml", "SUPublicEDKey": key], arguments: [], environment: ["XCTestBundlePath": "/tmp/msgblastTests.xctest"])
        XCTAssertFalse(config.isEnabled)
    }
    @MainActor
    func testQuitWaitsForActiveSubmissionThenSavesDraftAndAttachmentReferences() throws {
        let gate = UpdateTermination()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let draft = "Retain this prompt and /private/staged/photo.png"
        let save = { try Data(draft.utf8).write(to: file, options: .atomic) }
        XCTAssertEqual(gate.request(isBusy: true, persist: save), .deferred)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(gate.resume(isBusy: true, persist: save))
        XCTAssertEqual(gate.resume(isBusy: false, persist: save), .allowed)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), draft)
        XCTAssertNil(gate.resume(isBusy: false, persist: save), "A pending quit must only complete once")
    }
    @MainActor
    func testFailedStateSaveCancelsQuitAndKeepsTheAppRunning() {
        let gate = UpdateTermination()
        let failure = { throw NSError(domain: "fixture.storage", code: 1) }
        XCTAssertEqual(gate.request(isBusy: false, persist: failure), .cancelled)
        XCTAssertNotNil(gate.error)
        XCTAssertEqual(gate.request(isBusy: true, persist: failure), .deferred)
        XCTAssertEqual(gate.resume(isBusy: false, persist: failure), .cancelled)
        XCTAssertEqual(gate.request(isBusy: false, persist: {}), .allowed)
        XCTAssertNil(gate.error)
    }
    @MainActor
    func testUnreadableStateCanQuitWithoutOverwritingOriginalOrLosingNewDrafts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("state.json")
        let bytes = Data("{unreadable original state".utf8)
        try bytes.write(to: original)
        var state = AppState()
        state.draft = "New draft entered after storage failed"
        state.attachmentsDraft = [MessageAttachment(id: "fixture", filename: "photo.png", path: "/private/staged/photo.png")]
        let gate = UpdateTermination()
        var snapshot: URL?
        XCTAssertEqual(gate.request(isBusy: false, persist: {
            snapshot = try QuitStateRecovery.preserve(state, originalURL: original)
        }), .allowed)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        let saved = try XCTUnwrap(snapshot)
        let recovered = try JSONDecoder().decode(AppState.self, from: Data(contentsOf: saved))
        XCTAssertEqual(recovered.draft, state.draft)
        XCTAssertEqual(recovered.attachmentsDraft?.first?.path, state.attachmentsDraft?.first?.path)
        XCTAssertEqual(try Data(contentsOf: saved.deletingLastPathComponent().appendingPathComponent("original-state.json")), bytes)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: saved.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let second = try QuitStateRecovery.preserve(state, originalURL: original)
        XCTAssertNotEqual(saved, second, "Repeated quits must retain every recovery snapshot")
    }
    @MainActor
    func testRecoveryWriteFailureStillCancelsQuit() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let gate = UpdateTermination()
        XCTAssertEqual(gate.request(isBusy: false, persist: {
            _ = try QuitStateRecovery.preserve(AppState(), originalURL: file.appendingPathComponent("state.json"))
        }), .cancelled)
        XCTAssertNotNil(gate.error)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "not a directory")
    }

    func testRecoveryRetainsDraftWhenOriginalFileIsMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var state = AppState()
        state.draft = "Retain unsaved draft"
        let snapshot = try QuitStateRecovery.preserve(state, originalURL: root.appendingPathComponent("state.json"))
        XCTAssertEqual(try JSONDecoder().decode(AppState.self, from: Data(contentsOf: snapshot)).draft, state.draft)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("state.json").path))
    }
    @MainActor
    func testUnreadableStateRecoveryStillWaitsForActiveSend() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = UpdateTermination()
        let save = { _ = try QuitStateRecovery.preserve(AppState(), originalURL: root.appendingPathComponent("state.json")) }
        XCTAssertEqual(gate.request(isBusy: true, persist: save), .deferred)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(gate.resume(isBusy: false, persist: save), .allowed)
    }

    @MainActor
    func testInaccessibleOriginalDoesNotBlockDurableDraftRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = root.appendingPathComponent("state.json", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let marker = original.appendingPathComponent("untouched")
        try Data("keep original".utf8).write(to: marker)
        defer { try? FileManager.default.removeItem(at: root) }
        var state = AppState()
        state.draft = "Draft after read error"
        var snapshot: URL?
        XCTAssertEqual(UpdateTermination().request(isBusy: false, persist: {
            snapshot = try QuitStateRecovery.preserve(state, originalURL: original)
        }), .allowed)
        let saved = try XCTUnwrap(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(AppState.self, from: Data(contentsOf: saved)).draft, state.draft)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "keep original")
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.deletingLastPathComponent().appendingPathComponent("original-read-error.txt").path))
    }

}
