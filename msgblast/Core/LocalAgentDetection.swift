import Foundation

public enum LocalAgentRuntime: String, CaseIterable, Codable, Identifiable, Sendable {
    case openclaw, hermes
    public var id: String { rawValue }
    public var name: String { self == .openclaw ? "OpenClaw" : "Hermes" }
    var setupSubcommand: String { self == .openclaw ? "configure" : "setup" }
    public var setup: String { "\(rawValue) \(setupSubcommand)" }
    public var documentation: URL {
        URL(string: self == .openclaw ? "https://docs.openclaw.ai/start/getting-started" : "https://hermes-agent.nousresearch.com/docs/getting-started/quickstart/")!
    }
}

public struct InstalledLocalAgent: Identifiable, Equatable, Sendable {
    public let runtime: LocalAgentRuntime
    public let executableURL: URL
    public var id: String { runtime.id }
    public init(runtime: LocalAgentRuntime, executableURL: URL) {
        self.runtime = runtime; self.executableURL = executableURL
    }
}

public enum LocalAgentDetection {
    // Only called by the user's setup action. Detection never executes a runtime.
    public static func setupScript(using agent: InstalledLocalAgent, path: String,
                                   environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let configuration = ["HOME", "XDG_CONFIG_HOME", "HERMES_HOME", "OPENCLAW_STATE_DIR", "OPENCLAW_CONFIG_PATH"].map { key in
            if let value = environment[key] { return "export \(key)=\(quote(value))" }
            return key == "HOME" ? "export HOME=\(quote(FileManager.default.homeDirectoryForCurrentUser.path))" : "unset \(key)"
        }.joined(separator: "\n")
        return """
        #!/bin/zsh
        trap '/bin/rm -f -- "$0"' EXIT
        export PATH=\(quote(path))
        \(configuration)
        cd "$HOME" || exit 1
        \(quote(agent.executableURL.path)) \(agent.runtime.setupSubcommand)
        result=$?
        printf '\\nReturn to msgblast when setup is complete.\\n'
        exit "$result"
        """
    }

    public static func detect() async -> [InstalledLocalAgent] {
        detect(path: await LocalPersonalAgent.executableSearchPath())
    }

    // Detect presence without launching either CLI or reading account/config files.
    public static func detect(path: String) -> [InstalledLocalAgent] {
        return LocalAgentRuntime.allCases.compactMap { runtime in
            executable(named: runtime.rawValue, path: path).map { InstalledLocalAgent(runtime: runtime, executableURL: $0) }
        }
    }

    static func executable(named name: String, path: String) -> URL? {
        let directories = path.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") && !$0.contains("\n") }
        for directory in directories {
            let executable = URL(fileURLWithPath: directory).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: executable.path, isDirectory: &isDirectory), !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: executable.path) {
                return executable
            }
        }
        return nil
    }
}
