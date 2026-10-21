import XCTest
@testable import msgblastCore

@MainActor
final class CuaPermissionsTests: XCTestCase {
    final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        struct State {
            var installed = true
            var host = false
            var hostRequests: [Bool] = []
            var driverRequests = 0
            var setupRequests = 0
            var settings: [String] = []
            var failure = false
            var report = CuaDriverPermissionReport(accessibility: false, screen_recording: false,
                source: .init(attribution: "driver-daemon", bundle_id: "com.trycua.driver"))
        }
        private var value = State()
        func change(_ body: (inout State) -> Void) { lock.withLock { body(&value) } }
        var state: State { lock.withLock { value } }
        func client() -> CuaPermissionClient {
            CuaPermissionClient(installed: { self.state.installed }, hostAccessibility: { prompt in
                self.change { $0.hostRequests.append(prompt) }; return self.state.host
            }, driverPermissions: {
                self.change { $0.driverRequests += 1 }
                if self.state.failure { throw CocoaError(.fileReadUnknown) }
                return self.state.report
            }, openDriverSetup: {
                self.change { $0.setupRequests += 1 }
                if self.state.failure { throw CocoaError(.fileReadUnknown) }
            }, openSettings: { pane in self.change { $0.settings.append(pane) }; return true })
        }
    }

    func testRefreshChecksBothOwnersWithoutPromptingOrCapturing() async {
        let probe = Probe()
        let checked = CuaPermissionsController(client: probe.client())
        XCTAssertTrue(probe.state.hostRequests.isEmpty)
        XCTAssertEqual(probe.state.driverRequests, 0)
        await checked.refresh(demo: false)
        await checked.refresh(demo: false)
        XCTAssertEqual(checked.hostAccessibility, .off)
        XCTAssertEqual(checked.driverAccessibility, .off)
        XCTAssertEqual(checked.windowCapture, .off)
        XCTAssertEqual(probe.state.hostRequests, [false, false])
        XCTAssertEqual(probe.state.driverRequests, 2)
        XCTAssertEqual(probe.state.setupRequests, 0)
        XCTAssertTrue(probe.state.settings.isEmpty)
    }

    func testExplicitSetupRefreshesGrantsAndRevocationDoesNotTrustSetupExit() async {
        let probe = Probe(), controller = CuaPermissionsController(client: probe.client())
        await controller.refresh(demo: false)
        controller.enableHostAccessibility(demo: false)
        XCTAssertEqual(probe.state.hostRequests, [false, true])
        await controller.enableDriver(demo: false)
        XCTAssertEqual(probe.state.setupRequests, 1)
        XCTAssertEqual(probe.state.driverRequests, 2)
        XCTAssertEqual(controller.driverAccessibility, .off, "Setup success cannot invent an OS grant")
        probe.change { state in
            state.host = true
            state.report = .init(accessibility: true, screen_recording: true,
                source: .init(attribution: "driver-daemon", bundle_id: "com.trycua.driver"))
        }
        await controller.refresh(demo: false)
        XCTAssertEqual(controller.hostAccessibility, .allowed)
        XCTAssertEqual(controller.driverAccessibility, .allowed)
        XCTAssertEqual(controller.windowCapture, .allowed)
        probe.change { $0.report = .init(accessibility: false, screen_recording: false,
            source: .init(attribution: "driver-daemon", bundle_id: "com.trycua.driver")) }
        await controller.refresh(demo: false)
        XCTAssertEqual(controller.driverAccessibility, .off)
        XCTAssertEqual(controller.windowCapture, .off)
        XCTAssertEqual(probe.state.setupRequests, 1)
    }

    func testMissingDriverFailureAndWrongPermissionOwnerNeverClaimAllowed() async {
        let probe = Probe(), controller = CuaPermissionsController(client: probe.client())
        probe.change { $0.installed = false }
        await controller.refresh(demo: false)
        await controller.enableDriver(demo: false)
        XCTAssertEqual(controller.driverAccessibility, .notInstalled)
        XCTAssertEqual(probe.state.driverRequests, 0)
        probe.change { $0.installed = true; $0.failure = true }
        await controller.refresh(demo: false)
        XCTAssertEqual(controller.driverAccessibility, .unknown)
        probe.change { $0.failure = false; $0.report = .init(accessibility: true, screen_recording: true,
            source: .init(attribution: "host", bundle_id: "com.example.terminal")) }
        await controller.refresh(demo: false)
        XCTAssertEqual(controller.driverAccessibility, .unknown)
        XCTAssertEqual(controller.windowCapture, .unknown)
        XCTAssertNotNil(controller.message)
    }

    func testDemoActionsNeverTouchNativePermissionsOrSettings() async {
        let probe = Probe(), controller = CuaPermissionsController(client: probe.client())
        await controller.refresh(demo: true)
        controller.enableHostAccessibility(demo: true)
        await controller.enableDriver(demo: true)
        controller.openSettings("Privacy_Accessibility", demo: true)
        XCTAssertEqual(controller.hostAccessibility, .allowed)
        XCTAssertEqual(controller.driverAccessibility, .allowed)
        XCTAssertEqual(controller.windowCapture, .allowed)
        XCTAssertTrue(probe.state.hostRequests.isEmpty)
        XCTAssertEqual(probe.state.driverRequests, 0)
        XCTAssertTrue(probe.state.settings.isEmpty)
        XCTAssertEqual(probe.state.setupRequests, 0)
    }

    func testDriverStatusUsesReadOnlyCLIAndSetupUsesTheSupportedGrantCommand() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-cua-permissions-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("cua-driver")
        let script = #"""
        #!/usr/bin/env python3
        import json,pathlib,sys
        root=pathlib.Path(__file__).parent
        with (root/'calls.jsonl').open('a') as log: log.write(json.dumps(sys.argv[1:])+'\n')
        if sys.argv[1:]==['permissions','status','--json']:
            print(json.dumps({'accessibility':True,'screen_recording':False,'source':{'attribution':'driver-daemon','bundle_id':'com.trycua.driver'}}))
        elif sys.argv[1:]==['permissions','grant']:
            print('Permission setup closed; this output is not a grant receipt')
        else: raise SystemExit(91)
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let driver = CuaPermissionDriver(executable: executable)
        let first = try await driver.status()
        XCTAssertEqual(first.accessibility, true)
        XCTAssertEqual(first.screen_recording, false)
        try await driver.setup()
        let after = try await driver.status()
        XCTAssertEqual(after.screen_recording, false)
        let lines = try String(contentsOf: directory.appendingPathComponent("calls.jsonl"), encoding: .utf8).split(separator: "\n")
        let calls = try lines.map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) }
        XCTAssertEqual(calls, [["permissions", "status", "--json"], ["permissions", "grant"], ["permissions", "status", "--json"]])
    }

    private actor SuspendedStatus {
        private var permit: CheckedContinuation<Void, Never>?
        private var started: [CheckedContinuation<Void, Never>] = []
        private(set) var reads = 0
        func read() async -> CuaDriverPermissionReport {
            reads += 1
            let oldGrant = reads == 1
            if oldGrant {
                await withCheckedContinuation { continuation in
                    permit = continuation
                    started.forEach { $0.resume() }; started.removeAll()
                }
            }
            return .init(accessibility: oldGrant, screen_recording: oldGrant,
                         source: .init(attribution: "driver-daemon", bundle_id: "com.trycua.driver"))
        }
        func waitUntilStarted() async {
            if permit != nil { return }
            await withCheckedContinuation { started.append($0) }
        }
        func release() { permit?.resume(); permit = nil }
    }

    func testActivationDuringAnOldStatusReadQueuesOneFreshReadWithoutConsent() async {
        let probe = Probe(), gate = SuspendedStatus()
        var client = probe.client()
        client.driverPermissions = { await gate.read() }
        let controller = CuaPermissionsController(client: client)
        let original = Task { await controller.refresh(demo: false) }
        await gate.waitUntilStarted()
        await controller.refresh(demo: false)
        await controller.refresh(demo: false)
        await gate.release()
        await original.value
        let reads = await gate.reads
        XCTAssertEqual(reads, 2, "Activation checks must coalesce behind the old in-flight result")
        XCTAssertEqual(controller.driverAccessibility, .off)
        XCTAssertEqual(controller.windowCapture, .off)
        XCTAssertEqual(probe.state.hostRequests, [false, false])
        XCTAssertEqual(probe.state.setupRequests, 0)
        XCTAssertFalse(controller.checking)
    }

    func testSuccessfulGrantReadCannotEraseASeparateSetupFailure() async {
        let probe = Probe()
        probe.change { $0.report = .init(accessibility: true, screen_recording: true,
            source: .init(attribution: "driver-daemon", bundle_id: "com.trycua.driver")) }
        var client = probe.client()
        client.openDriverSetup = { throw DesktopAppError.unavailable("Capture verification did not finish") }
        let controller = CuaPermissionsController(client: client)
        await controller.enableDriver(demo: false)
        XCTAssertEqual(controller.windowCapture, .allowed)
        XCTAssertEqual(controller.message, "Capture verification did not finish")
    }

    func testPermissionErrorsDescribeTheOperationAndActualStatusDeadline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-cua-errors-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("cua-driver")
        try Data("#!/usr/bin/env python3\nraise SystemExit(3)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let driver = CuaPermissionDriver(executable: executable)
        do { _ = try await driver.status(); XCTFail("Expected a failed status command") }
        catch { XCTAssertTrue(error.localizedDescription.contains("permission check")); XCTAssertFalse(error.localizedDescription.contains("setup")) }
        do { try await driver.setup(); XCTFail("Expected a failed setup command") }
        catch { XCTAssertTrue(error.localizedDescription.contains("permission setup")) }
        try Data("#!/usr/bin/env python3\nimport time\ntime.sleep(60)\n".utf8).write(to: executable)
        do { _ = try await driver.status(); XCTFail("Expected the real status deadline") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("10 seconds"))
            XCTAssertFalse(error.localizedDescription.contains("personal agent"))
            XCTAssertFalse(error.localizedDescription.contains("three minutes"))
        }
    }

    func testDesktopOnboardingUsesNativeConnectionsWithoutBrowserImportOrCLISetup() throws {
        var state = OnboardingState()
        state.chooseConnector(.apps)
        state.selected = [.museApp, .grokBotApp, .wabi, .geminiApp]
        XCTAssertTrue(state.selected.allSatisfy { OnboardingConnector.apps.includes($0) })
        XCTAssertTrue(state.selected.allSatisfy { !OnboardingConnector.clis.includes($0) })
        state.begin()
        XCTAssertEqual(state.stage, .connecting)
        XCTAssertTrue(state.pendingWebProviders.isEmpty)
        XCTAssertEqual(Set(state.pendingSteps), [.agent(.museApp), .agent(.grokBotApp), .agent(.wabi), .agent(.geminiApp)])
        let reopened = try JSONDecoder().decode(OnboardingState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(reopened.selected, state.selected)
        state.complete(.museApp); state.skip(.grokBotApp); state.skip(.wabi); state.skip(.geminiApp)
        XCTAssertEqual(state.stage, .feedback)
        XCTAssertTrue(state.hasConnectedAgent)
    }
}
