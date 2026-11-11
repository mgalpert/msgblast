import Foundation
import msgblastCore

/// `msgblast.app/Contents/MacOS/msgblast <command>` runs as the msgblast command instead of opening a window.
/// It finds this build's socket the way the app finds its support folder, so Dev and production stay apart.
enum AgentControlCommand {
    static var executable: String { Bundle.main.executableURL?.path ?? "msgblast" }

    static var socket: URL {
        let info = Bundle.main
        let store = LocalStore(demo: info.object(forInfoDictionaryKey: "msgblastDemo") as? Bool == true,
                               supportDirectoryName: info.object(forInfoDictionaryKey: "msgblastSupportDirectory") as? String,
                               webPreview: info.object(forInfoDictionaryKey: "msgblastLiveWebPreview") as? Bool == true)
        return store.url.deletingLastPathComponent().appendingPathComponent("agent-control.sock")
    }

    /// Runs and exits when the first argument is a msgblast command. Otherwise returns and the app starts.
    static func runIfRequested() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard AgentControlCLI.isCommand(arguments) else { return }
        exit(run(arguments))
    }

    private static func run(_ arguments: [String]) -> Int32 {
        let parsed: (command: AgentControlCLI.Command, json: Bool)
        do { parsed = try AgentControlCLI.parse(arguments, environment: ProcessInfo.processInfo.environment) } catch {
            let message = (error as? AgentControlCLI.UsageError)?.message ?? error.localizedDescription
            FileHandle.standardError.write(Data("\(message)\n\n\(AgentControlCLI.usage)\n".utf8))
            return 2
        }
        let path = socket.path
        switch parsed.command {
        case .help:
            print(AgentControlCLI.usage)
            return 0
        case .mcp(let client):
            return serve(client: client, socket: path)
        case .request(let line):
            let reply: Data
            do { reply = try AgentControlSocketClient.exchange(line, socket: path) } catch is AgentControlSocketClient.NoReply {
                FileHandle.standardError.write(Data("\(AgentControlCLI.noReply)\n".utf8))
                return AgentControlCLI.noReplyStatus
            } catch {
                FileHandle.standardError.write(Data("\(AgentControlCLI.unavailable)\n".utf8))
                return AgentControlCLI.unavailableStatus
            }
            let output = AgentControlCLI.render(reply, json: parsed.json)
            FileHandle.standardOutput.write(Data(output.stdout.utf8))
            FileHandle.standardError.write(Data(output.stderr.utf8))
            return output.status
        }
    }

    /// Reads JSON-RPC lines until stdin closes. Requests run concurrently, so a long wait never blocks a ping.
    private static func serve(client: String?, socket path: String) -> Int32 {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let server = AgentControlMCPServer(version: version, client: client) { line in
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async { continuation.resume(with: Result { try AgentControlSocketClient.exchange(line, socket: path) }) }
            }
        }
        let output = LockedOutput()
        let group = DispatchGroup()
        // At most this many requests run at once; reading pauses until one finishes.
        let slots = DispatchSemaphore(value: maximumInFlight)
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard line.utf8.count <= maximumLineBytes else {
                output.write(Data((#"{"error":{"code":-32600,"message":"Message too large."},"id":null,"jsonrpc":"2.0"}"# + "\n").utf8))
                continue
            }
            slots.wait()
            group.enter()
            Task.detached {
                if let reply = await server.handle(Data(line.utf8)) { output.write(reply) }
                slots.signal()
                group.leave()
            }
        }
        group.wait()
        return 0
    }

    static let maximumInFlight = 64
    static let maximumLineBytes = 1_048_576

    private final class LockedOutput: @unchecked Sendable {
        private let lock = NSLock()
        func write(_ data: Data) { lock.withLock { FileHandle.standardOutput.write(data) } }
    }
}
