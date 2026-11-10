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
        guard let first = arguments.first, AgentControlCLI.commands.contains(first) else { return }
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
        case .request(let line):
            guard let reply = try? AgentControlSocketClient.exchange(line, socket: path) else {
                FileHandle.standardError.write(Data("msgblast is not running, or Settings → Outside agents is off.\n".utf8))
                return AgentControlCLI.unavailableStatus
            }
            let output = AgentControlCLI.render(reply, json: parsed.json)
            FileHandle.standardOutput.write(Data(output.stdout.utf8))
            FileHandle.standardError.write(Data(output.stderr.utf8))
            return output.status
        }
    }
}
