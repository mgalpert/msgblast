import XCTest
@testable import msgblastCore

final class EmbeddedCuaDriverTests: XCTestCase {
    private actor Grants {
        var control = false
        var capture = false
        func snapshot() -> EmbeddedCuaDriver.Permissions { .init(accessibility: control, screenCapture: capture) }
        func allowControl() { control = true }
        func allowCapture() { capture = true }
        func revokeControl() { control = false }
    }
    private actor ChangingGrants {
        var reads = 0
        func snapshot() -> EmbeddedCuaDriver.Permissions {
            reads += 1
            return .init(accessibility: reads > 1, screenCapture: false)
        }
    }
    private func fixture(wrongOwner: Bool = false, ready: Bool = true, wrongObservedParent: Bool = false) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("driver")
        let source = """
        #!/usr/bin/env python3
        import os, sys, json, socket, time
        args = sys.argv[1:]
        path = args[args.index('--socket') + 1]
        assert '--embedded' in args
        assert os.environ['CUA_DRIVER_EMBEDDED'] == '1'
        assert os.environ['CUA_DRIVER_PERMISSION_MODE'] == 'standard'
        if args[0] == 'serve':
            assert '--parent-liveness-stdio' in args
            assert '--no-overlay' in args
            assert os.stat(os.path.dirname(path)).st_mode & 0o777 == 0o700
            with open(os.path.join(os.path.dirname(__file__), 'started'), 'w') as signal:
                signal.write(str(os.getpid()))
            if \(ready ? "True" : "False"):
                server = socket.socket(socket.AF_UNIX); server.bind(path); server.listen()
            sys.stdin.buffer.read()
        else:
            assert os.path.exists(path)
            owner = os.environ['CUA_DRIVER_HOST_BUNDLE_ID']
            pid = int(os.environ['CUA_DRIVER_EMBEDDED_HOST_PID'])
            if \(wrongOwner ? "True" : "False"): pid += 1
            if args[1] == 'check_permissions':
                value = {'source': {'attribution':'host', 'embedded':True, 'host_bundle_id':owner, 'responsible_ppid':pid}}
            elif args[1] == 'health_report':
                if \(wrongObservedParent ? "True" : "False"): pid += 1
                value = {'checks':[{'name':'bundle_identity', 'status':'pass', 'data':{'bundle_identifier':owner, 'identity_source':'parent_application', 'parent_process_id':pid}}]}
            else: raise Exception('Unexpected operation')
            print(json.dumps(value), flush=True)
            time.sleep(.02)
        """
        try source.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    func testConcurrentConnectionsSharePrivateHostOwnedRuntimeAndStopRemovesSocket() async throws {
        let driver = EmbeddedCuaDriver(executable: try fixture(), bundleID: "test.msgblast", startupTimeout: 2)
        async let first = driver.connection()
        async let second = driver.connection()
        let (a, b) = try await (first, second)
        XCTAssertEqual(a.pid, b.pid)
        XCTAssertEqual(a.socket, b.socket)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.socket.path))
        await driver.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.socket.path))
        do { _ = try await driver.connection(); XCTFail("Stopped host must not restart") } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testWrongObservedParentIsRejected() async throws {
        let driver = EmbeddedCuaDriver(executable: try fixture(wrongOwner: true), bundleID: "test.msgblast", startupTimeout: 2)
        do { _ = try await driver.connection(); XCTFail("Wrong owner accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("did not inherit")) }
        await driver.stop()
    }

    func testAdvisoryBundleLabelCannotOverrideDifferentObservedParent() async throws {
        let driver = EmbeddedCuaDriver(executable: try fixture(wrongObservedParent: true), bundleID: "test.msgblast", startupTimeout: 2)
        do { _ = try await driver.connection(); XCTFail("Advisory label bypassed observed parent") } catch { XCTAssertTrue(error.localizedDescription.contains("did not inherit")) }
        await driver.stop()
    }

    func testHostShutdownDuringStartupCannotLeaveUsableConnection() async throws {
        let executable = try fixture(ready: false)
        let signal = executable.deletingLastPathComponent().appendingPathComponent("started")
        let driver = EmbeddedCuaDriver(executable: executable, bundleID: "test.msgblast", startupTimeout: 3)
        let starting = Task { try await driver.connection() }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: signal.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: signal.path), "Child must have launched before shutdown")
        await driver.stop()
        do { _ = try await starting.value; XCTFail("Connection escaped host shutdown") } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testMissingPrivateSocketTimesOutWithoutStandaloneFallback() async throws {
        let driver = EmbeddedCuaDriver(executable: try fixture(ready: false), bundleID: "test.msgblast", startupTimeout: 0.1)
        do { _ = try await driver.connection(); XCTFail("Absent private runtime accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("could not start")) }
        await driver.stop()
    }

    func testEachObservedHostGrantChangeReplacesCachedRuntime() async throws {
        let grants = Grants()
        let driver = EmbeddedCuaDriver(executable: try fixture(), bundleID: "test.msgblast", startupTimeout: 2,
                                       permissionState: { await grants.snapshot() })
        let original = try await driver.connection()
        let unchanged = try await driver.connection()
        XCTAssertEqual(unchanged.socket, original.socket)
        await grants.allowControl()
        let control = try await driver.connection()
        XCTAssertNotEqual(control.socket, original.socket)
        XCTAssertNotEqual(control.pid, original.pid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.socket.path))
        await grants.allowCapture()
        let capture = try await driver.connection()
        XCTAssertNotEqual(capture.socket, control.socket)
        XCTAssertNotEqual(capture.pid, control.pid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: control.socket.path))
        await grants.revokeControl()
        let revoked = try await driver.connection()
        XCTAssertNotEqual(revoked.socket, capture.socket)
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.socket.path))
        await driver.stop()
    }

    func testGrantChangeDuringStartupFailsClosedAndNextExplicitConnectionCanStart() async throws {
        let grants = ChangingGrants()
        let driver = EmbeddedCuaDriver(executable: try fixture(), bundleID: "test.msgblast", startupTimeout: 2,
                                       permissionState: { await grants.snapshot() })
        do { _ = try await driver.connection(); XCTFail("Changed grant accepted during startup") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed while connecting")) }
        _ = try await driver.connection()
        await driver.stop()
    }

    func testMissingBundledHelperDoesNotSearchUserInstallation() async {
        let driver = EmbeddedCuaDriver(executable: nil, bundleID: "test.msgblast")
        do { _ = try await driver.connection(); XCTFail("Missing helper accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("bundled app-control component is missing")) }
        XCTAssertNil(EmbeddedCuaDriver.bundledExecutable(in: URL(fileURLWithPath: "/nonexistent/msgblast.app")))
        await driver.stop()
    }
}
