import Darwin
import Foundation
import ApplicationServices
import CoreGraphics

/// Owns a private runtime. Never connects to or changes the user's standalone driver.
public actor EmbeddedCuaDriver {
    public static let shared = EmbeddedCuaDriver()

    struct Permissions: Equatable, Sendable {
        let accessibility: Bool
        let screenCapture: Bool
    }

    struct Connection: Sendable {
        let executable: URL
        let socket: URL
        let environment: [String: String]
        let pid: Int32

        func arguments(tool: String, payload: String) -> [String] {
            ["call", tool, payload, "--embedded", "--socket", socket.path]
        }
    }

    private struct Runtime {
        let process: Process
        let liveness: Pipe
        let directory: URL
        let connection: Connection
        let permissions: Permissions
    }

    private let executable: URL?
    private let bundleID: String
    private let hostPID: Int32
    private let startupTimeout: TimeInterval
    private let permissionState: @Sendable () async -> Permissions
    private var runtime: Runtime?
    private var starting: Task<Connection, Error>?
    private var closed = false

    init(executable: URL? = EmbeddedCuaDriver.bundledExecutable(), bundleID: String = Bundle.main.bundleIdentifier ?? "", hostPID: Int32 = ProcessInfo.processInfo.processIdentifier, startupTimeout: TimeInterval = 10,
         permissionState: @escaping @Sendable () async -> Permissions = EmbeddedCuaDriver.hostPermissions) {
        self.executable = executable
        self.bundleID = bundleID
        self.hostPID = hostPID
        self.startupTimeout = startupTimeout
        self.permissionState = permissionState
    }

    private static func hostPermissions() async -> Permissions {
        await MainActor.run {
            Permissions(accessibility: AXIsProcessTrusted(), screenCapture: CGPreflightScreenCaptureAccess())
        }
    }

    nonisolated static func bundledExecutable(in bundle: URL = Bundle.main.bundleURL) -> URL? {
        let file = bundle.appendingPathComponent("Contents/Helpers/cua-driver")
        return FileManager.default.isExecutableFile(atPath: file.path) ? file : nil
    }

    func connection() async throws -> Connection {
        guard !closed else { throw CancellationError() }
        if let starting { return try await starting.value }
        let task = Task {
            if let runtime, runtime.process.isRunning {
                let permissions = await permissionState()
                try Task.checkCancellation()
                guard !closed else { throw CancellationError() }
                if runtime.process.isRunning, runtime.permissions == permissions { return runtime.connection }
            }
            // TCC answers are cached per process. Old calls keep their old
            // socket and may fail; replacing a generation never retries them.
            await discardRuntime()
            return try await start()
        }
        starting = task
        defer { starting = nil }
        return try await task.value
    }

    private func start() async throws -> Connection {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let permissions = await permissionState()
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        guard let executable, !bundleID.isEmpty else {
            throw DesktopAppError.unavailable("The bundled app-control component is missing. Reinstall msgblast.")
        }
        let directory = URL(fileURLWithPath: "/tmp/msgblast-cua-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CUA_DRIVER_") }
        environment["CUA_DRIVER_EMBEDDED"] = "1"
        environment["CUA_DRIVER_HOST_BUNDLE_ID"] = bundleID
        environment["CUA_DRIVER_EMBEDDED_HOST_PID"] = String(hostPID)
        environment["CUA_DRIVER_PERMISSION_MODE"] = "standard"
        let socket = directory.appendingPathComponent("driver.sock")
        let process = Process(), liveness = Pipe()
        process.executableURL = executable
        // --no-overlay: the driver's agent-cursor overlay is on by default and keeps a
        // transparent full-screen window open for the daemon's lifetime. msgblast acts in
        // the background and never shows an agent cursor.
        process.arguments = ["serve", "--embedded", "--socket", socket.path, "--parent-liveness-stdio", "--no-overlay"]
        process.environment = environment
        process.standardInput = liveness
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // Only the host retains the write end. EOF ends the daemon on host death.
            try? liveness.fileHandleForReading.close()
            let connection = Connection(executable: executable, socket: socket, environment: environment, pid: process.processIdentifier)
            runtime = Runtime(process: process, liveness: liveness, directory: directory, connection: connection, permissions: permissions)
            let deadline = ProcessInfo.processInfo.systemUptime + startupTimeout
            while !FileManager.default.fileExists(atPath: socket.path) {
                try Task.checkCancellation()
                guard !closed, process.isRunning, ProcessInfo.processInfo.systemUptime < deadline else {
                    throw DesktopAppError.unavailable("App control could not start. Restart msgblast; no action was retried.")
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            try await verifyHost(connection)
            let currentPermissions = await permissionState()
            guard permissions == currentPermissions else {
                throw DesktopAppError.unavailable("App access changed while connecting. Connect again; no action was sent.")
            }
            try Task.checkCancellation()
            guard !closed, process.isRunning else { throw CancellationError() }
            return connection
        } catch {
            if runtime == nil { try? FileManager.default.removeItem(at: directory) }
            await discardRuntime()
            throw error
        }
    }

    private func verifyHost(_ connection: Connection) async throws {
        // The configured bundle label alone is advisory. Also verify the driver's
        // observed parent application before allowing any app-control operation.
        let expectedBundle = bundleID, expectedPID = hostPID
        try await Task.detached {
            func call(_ tool: String, _ arguments: [String: Any]) throws -> [String: Any] {
                let payload = String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
                let result = try AgentProcess.run(executable: connection.executable, arguments: connection.arguments(tool: tool, payload: payload), input: "", environment: connection.environment, timeout: 10, cancellation: AgentCancellation())
                guard result.status == 0, let data = result.stdout.data(using: .utf8),
                      let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], value["isError"] as? Bool != true else {
                    throw DesktopAppError.unavailable("App control could not verify its permission owner.")
                }
                return value
            }
            let permissions = try call("check_permissions", [:])
            let source = permissions["source"] as? [String: Any]
            let health = try call("health_report", ["include": ["bundle_identity"]])
            let checks = health["checks"] as? [[String: Any]] ?? []
            let identity = checks.first { $0["name"] as? String == "bundle_identity" }
            let data = identity?["data"] as? [String: Any]
            guard source?["attribution"] as? String == "host", source?["embedded"] as? Bool == true,
                  source?["host_bundle_id"] as? String == expectedBundle,
                  source?["responsible_ppid"] as? Int32 == expectedPID,
                  identity?["status"] as? String == "pass",
                  data?["bundle_identifier"] as? String == expectedBundle,
                  data?["identity_source"] as? String == "parent_application",
                  data?["parent_process_id"] as? Int32 == expectedPID else {
                throw DesktopAppError.unavailable("App control did not inherit msgblast's permission identity. No action was sent.")
            }
        }.value
    }

    public func stop() async {
        closed = true
        starting?.cancel()
        await discardRuntime()
    }

    private func discardRuntime() async {
        guard let runtime else { return }
        self.runtime = nil
        try? runtime.liveness.fileHandleForWriting.close()
        if runtime.process.isRunning { runtime.process.terminate() }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while runtime.process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if runtime.process.isRunning { kill(runtime.process.processIdentifier, SIGKILL) }
        try? FileManager.default.removeItem(at: runtime.directory)
    }
}
