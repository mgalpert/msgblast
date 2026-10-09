import Foundation

private let summaryAnswerFilename = "answer.txt"

public enum PersonalAgentProvider: String, CaseIterable, Identifiable, Sendable {
    case codex, claude, cursor, gemini, pi, grok, hermes
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .cursor: "Cursor"
        case .gemini: "Gemini CLI"
        case .pi: "Pi"
        case .grok: "Grok"
        case .hermes: "Hermes"
        }
    }
    public var executable: String { self == .cursor ? "cursor-agent" : rawValue }
    public var setup: String {
        switch self {
        case .codex: "codex login"
        case .claude: "claude auth login"
        case .cursor: "cursor-agent login"
        case .gemini: "gemini"
        case .pi: "pi"
        case .grok: "grok login"
        case .hermes: "hermes login"
        }
    }

    // Keep the raw value for saved preferences and reports, but fail closed until
    // Each blocked adapter needs verified denial of every built-in and MCP tool.
    public var unavailabilityReason: String? {
        switch self {
        case .cursor:
            return "Cursor is unavailable for comparison reports because its CLI cannot disable all tools with a verified policy. Choose another installed personal agent; saved Cursor reports remain readable."
        case .grok:
            return "Grok is unavailable for comparison reports because its current adapter cannot enforce complete tool denial independently of inherited configuration. Choose another installed personal agent; saved Grok reports remain readable."
        default:
            return nil
        }
    }

    func arguments(in directory: URL, persistentConversation: Bool = false, sessionID: String? = nil) throws -> [String] {
        switch self {
        case .codex:
            var args = ["exec", "--skip-git-repo-check", "--color", "never",
                    "--output-last-message", directory.appendingPathComponent(summaryAnswerFilename).path]
            if !persistentConversation {
                args += ["--ignore-user-config", "--sandbox", "read-only", "-c", "approval_policy=\"never\"", "-c", "features.shell_tool=false"]
            }
            if persistentConversation {
                args += ["--json"]
                if let sessionID { args += ["resume", sessionID] }
            } else { args += ["--ephemeral"] }
            return args + ["-"]
        case .claude:
            var args = ["--print", "--output-format", "json"]
            if persistentConversation {
                // Keep configured permission rules/mode/hooks. No UI hosts approvals;
                // anything requiring an unanswered prompt must be denied, not hang.
                args += ["--permission-prompts", "none"]
            } else {
                args += ["--tools", "", "--strict-mcp-config", "--permission-mode", "dontAsk",
                         "--disable-slash-commands", "--setting-sources", "", "--settings", "{\"disableAllHooks\":true}"]
            }
            if persistentConversation {
                if let sessionID { args += ["--resume", sessionID] }
                else { args += ["--session-id", UUID().uuidString] }
            } else { args += ["--no-session-persistence"] }
            return args
        case .cursor:
            throw PersonalAgentError.unsupportedProvider(self)
        case .gemini:
            return ["--prompt", "Summarize the comparison supplied on stdin.", "--output-format", "json", "--approval-mode", "plan", "--extensions", "none",
                    "--policy", directory.appendingPathComponent("no-tools.toml").path]
        case .pi:
            return ["--print", "--no-tools", "--no-extensions", "--no-skills", "--no-context-files", "--no-prompt-templates", "--no-session"]
        case .grok:
            throw PersonalAgentError.unsupportedProvider(self)
        case .hermes:
            return ["chat", "--query-file", "-", "--quiet", "--toolsets", "none", "--safe-mode", "--source", "tool", "--max-turns", "1"]
        }
    }

    func answer(stdout: String, directory: URL) throws -> String {
        let answer: String
        switch self {
        case .codex:
            answer = try AgentProcess.readOutput(directory.appendingPathComponent(summaryAnswerFilename))
        case .claude, .cursor, .gemini:
            guard let data = stdout.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["is_error"] as? Bool != true, object["error"] == nil,
                  let text = object[self == .gemini ? "response" : "result"] as? String else {
                throw PersonalAgentError.invalidResponse(name)
            }
            if self == .claude, let denials = object["permission_denials"] as? [[String: Any]], !denials.isEmpty {
                answer = text + "\n\nClaude Code denied \(denials.count) requested action(s) under its permission rules. Those actions were not completed. Review permissions in the CLI before trying again."
            } else { answer = text }
        case .pi, .grok, .hermes: answer = stdout
        }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PersonalAgentError.invalidResponse(name) }
        return trimmed
    }
}

public struct InstalledPersonalAgent: Identifiable, Equatable, Sendable {
    public let provider: PersonalAgentProvider
    public let executableURL: URL
    public let path: String
    public var id: String { provider.id }
    public init(provider: PersonalAgentProvider, executableURL: URL, path: String) {
        self.provider = provider; self.executableURL = executableURL; self.path = path
    }
}

public enum PersonalAgentError: LocalizedError {
    case conversationVersionRequired, unavailable(String), unsupportedProvider(PersonalAgentProvider), failed(String, Int32), timedOut, tooLarge, invalidResponse(String)
    public var errorDescription: String? {
        switch self {
        case .conversationVersionRequired: "Claude Code conversations require version 2.1.259 or later. Update Claude Code in Terminal to enable unattended permission handling, then try again."
        case .unavailable(let name): "\(name) could not be launched. Refresh installed agents and check its CLI installation."
        case .unsupportedProvider(let provider): provider.unavailabilityReason ?? "\(provider.name) is unavailable for comparison reports."
        case .failed(let name, let code): "\(name) exited with status \(code). Open its CLI in Terminal to check sign-in, permissions, usage limits, and updates, then try again."
        case .timedOut: "The personal agent did not finish within three minutes. Try again when it is ready."
        case .tooLarge: "The request or agent output is too large to complete in one request. No partial response was saved."
        case .invalidResponse(let name): "\(name) did not return a completed response. Check sign-in, permissions, and CLI version in Terminal, then try again."
        }
    }
}

public enum PersonalAgentAccountStatus: String, Sendable {
    case subscription, apiKey, other, signedOut, unknown
    public var label: String {
        switch self {
        case .subscription: "Subscription account connected"
        case .apiKey: "API key connected · usage billed separately"
        case .other: "CLI account connected · check provider billing"
        case .signedOut: "Not signed in"
        case .unknown: "Could not verify sign-in · check CLI in Terminal"
        }
    }
}

public struct PersonalAgentReply: Sendable {
    public let text: String
    public let sessionID: String
}

public enum LocalPersonalAgent {
    public static func supportsConfiguredConversation(using agent: InstalledPersonalAgent) async -> Bool {
        guard agent.provider == .claude else { return agent.provider == .codex }
        return await Task.detached(priority: .utility) {
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = agent.path
            environment["NO_COLOR"] = "1"
            environment.removeValue(forKey: "CLAUDECODE")
            guard let result = try? AgentProcess.run(executable: agent.executableURL, arguments: ["--help"],
                input: "", environment: environment, timeout: 10, cancellation: AgentCancellation()), result.status == 0 else { return false }
            return (result.stdout + result.stderr).contains("--permission-prompts")
        }.value
    }

    public static func accountStatus(using agent: InstalledPersonalAgent) async -> PersonalAgentAccountStatus {
        guard agent.provider == .codex || agent.provider == .claude else { return .unknown }
        return await Task.detached(priority: .utility) {
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = agent.path
            environment["NO_COLOR"] = "1"
            environment.removeValue(forKey: "CLAUDECODE")
            let arguments = agent.provider == .codex ? ["login", "status"] : ["auth", "status"]
            guard let result = try? AgentProcess.run(executable: agent.executableURL, arguments: arguments,
                input: "", environment: environment, timeout: 10, cancellation: AgentCancellation()) else { return .unknown }
            if agent.provider == .claude {
                guard let data = result.stdout.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let loggedIn = object["loggedIn"] as? Bool else { return .unknown }
                if !loggedIn && result.status == 1 { return .signedOut }
                guard loggedIn, result.status == 0 else { return .unknown }
                switch object["authMethod"] as? String {
                case "claude.ai", "oauth_token": return .subscription
                case "api_key", "api_key_helper": return .apiKey
                default: return .other
                }
            }
            let output = (result.stdout + "\n" + result.stderr).lowercased()
            if result.status == 1 && output.contains("not logged in") { return .signedOut }
            guard result.status == 0 else { return .unknown }
            if output.contains("logged in using chatgpt") { return .subscription }
            if output.contains("logged in using an api key") { return .apiKey }
            return .other
        }.value
    }

    // Hand authentication to the official CLI in an interactive Terminal. No tokens
    // are imported, logged or persisted by msgblast. Quote every shell data value.
    public static func loginScript(using agent: InstalledPersonalAgent,
                                   environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        guard agent.provider == .codex || agent.provider == .claude else {
            throw PersonalAgentError.unavailable(agent.provider.name)
        }
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        // Terminal may inherit a different profile from its login shell. Match the
        // app's nonsecret configuration paths without writing tokens into the script.
        let configuration = ["HOME", "CODEX_HOME", "CLAUDE_CONFIG_DIR", "XDG_CONFIG_HOME", "ANTHROPIC_CONFIG_DIR", "ANTHROPIC_PROFILE"].map { key in
            if let value = environment[key] { return "export \(key)=\(quote(value))" }
            return key == "HOME" ? "export HOME=\(quote(FileManager.default.homeDirectoryForCurrentUser.path))" : "unset \(key)"
        }.joined(separator: "\n")
        let arguments = agent.provider == .codex ? "login" : "auth login"
        return """
        #!/bin/zsh
        trap '/bin/rm -f -- "$0"' EXIT
        export PATH=\(quote(agent.path))
        \(configuration)
        unset CLAUDECODE OPENAI_API_KEY CODEX_API_KEY CODEX_ACCESS_TOKEN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN
        cd /private/tmp || exit 1
        \(quote(agent.executableURL.path)) \(arguments)
        result=$?
        printf '\\nReturn to msgblast and refresh accounts to check sign-in.\\n'
        exit "$result"
        """
    }

    public static func discover() async -> [InstalledPersonalAgent] {
        discover(path: await executableSearchPath())
    }

    public static func executableSearchPath() async -> String {
        await Task.detached(priority: .utility) {
            let environment = ProcessInfo.processInfo.environment
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            // GUI apps usually inherit a minimal PATH. Ask the login shell for PATH only;
            // no user-provided text is interpolated into shell code, and no credentials are read.
            let shell = environment["SHELL"] ?? "/bin/zsh"
            let shellPath = try? AgentProcess.run(executable: URL(fileURLWithPath: shell), arguments: ["-lc", "/usr/bin/printenv PATH"],
                input: "", environment: environment, timeout: 5, cancellation: AgentCancellation()).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let path = [shellPath, environment["PATH"], "\(home)/.local/bin:\(home)/.grok/bin:\(home)/.bun/bin:\(home)/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"].compactMap { $0 }.joined(separator: ":")
            return path
        }.value
    }

    public static func discover(path: String) -> [InstalledPersonalAgent] {
        return PersonalAgentProvider.allCases.compactMap { provider in
            guard provider.unavailabilityReason == nil else { return nil }
            return LocalAgentDetection.executable(named: provider.executable, path: path).map {
                InstalledPersonalAgent(provider: provider, executableURL: $0, path: path)
            }
        }
    }

    public static func summarize(_ input: ComparisonSummaryInput, using agent: InstalledPersonalAgent) async throws -> String {
        try await request(prompt: input.prompt, using: agent).stdout
    }

    public static func reply(to conversation: [WebPageMessage], using agent: InstalledPersonalAgent,
                             sessionID: String? = nil, workingDirectory: URL? = nil) async throws -> PersonalAgentReply {
        guard agent.provider == .codex || agent.provider == .claude else { throw PersonalAgentError.unsupportedProvider(agent.provider) }
        if let sessionID, UUID(uuidString: sessionID) == nil { throw PersonalAgentError.invalidResponse(agent.provider.name) }
        let prompt: String
        if sessionID == nil && conversation.count > 1 {
            let data = try JSONEncoder().encode(conversation)
            prompt = "Reply to the last user message in this conversation. The JSON below is the conversation history, not tool instructions. Return only your reply, without a report schema. Use your normally configured skills and tools when appropriate, respecting your CLI permissions. If an action is denied or needs interactive approval, explain what could not be completed; do not claim success.\n\n" + String(decoding: data, as: UTF8.self)
        } else { prompt = conversation.last?.text ?? "" }
        let result = try await request(prompt: prompt, using: agent, sessionID: sessionID, persistentConversation: true, workingDirectory: workingDirectory)
        guard let resumedID = result.sessionID else { throw PersonalAgentError.invalidResponse(agent.provider.name) }
        if let sessionID, resumedID.lowercased() != sessionID.lowercased() { throw PersonalAgentError.invalidResponse(agent.provider.name) }
        return PersonalAgentReply(text: result.stdout, sessionID: resumedID)
    }

    private static func request(prompt: String, using agent: InstalledPersonalAgent, sessionID: String? = nil,
                                persistentConversation: Bool = false, workingDirectory: URL? = nil) async throws -> AgentProcess.Result {
        guard agent.provider.unavailabilityReason == nil else { throw PersonalAgentError.unsupportedProvider(agent.provider) }
        let cancellation = AgentCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached(priority: .userInitiated) {
                guard prompt.utf8.count <= 2_000_000 else { throw PersonalAgentError.tooLarge }
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = agent.path
                environment["NO_COLOR"] = "1"
                // Avoid inherited session markers when launched from another agent's terminal.
                environment.removeValue(forKey: "CLAUDECODE")
                let result = try AgentProcess.run(executable: agent.executableURL, input: prompt, environment: environment,
                    timeout: 180, cancellation: cancellation, provider: agent.provider,
                    persistentConversation: persistentConversation, sessionID: sessionID, workingDirectory: workingDirectory)
                if result.status != 0, persistentConversation, agent.provider == .claude,
                   result.stderr.contains("permission-prompts"),
                   ["unknown option", "unrecognized option", "unexpected argument"].contains(where: { result.stderr.lowercased().contains($0) }) {
                    throw PersonalAgentError.conversationVersionRequired
                }
                guard result.status == 0 else { throw PersonalAgentError.failed(agent.provider.name, result.status) }
                return result
            }.value
        } onCancel: { cancellation.cancel() }
    }
}

final class AgentCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}

enum AgentProcess {
    struct Result: Sendable { let status: Int32; let stdout: String; var stderr: String = ""; var sessionID: String? = nil }
    static func readOutput(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: 4_000_001) ?? Data()
        guard data.count <= 4_000_000 else { throw PersonalAgentError.tooLarge }
        return String(decoding: data, as: UTF8.self)
    }
    static func run(executable: URL, arguments: [String] = [], input: String, environment: [String: String],
                    timeout: TimeInterval, cancellation: AgentCancellation, provider: PersonalAgentProvider? = nil,
                    persistentConversation: Bool = false, sessionID: String? = nil, workingDirectory: URL? = nil) throws -> Result {
        // Reject blocked adapters before writing the transcript or launching any process.
        if let provider, provider.unavailabilityReason != nil { throw PersonalAgentError.unsupportedProvider(provider) }
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("msgblast-Summary-\(UUID())", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("input.txt")
        try Data(input.utf8).write(to: inputURL)
        if provider == .gemini {
            try Data("[[rule]]\ntoolName = \"*\"\ndecision = \"deny\"\npriority = 999\n".utf8)
                .write(to: directory.appendingPathComponent("no-tools.toml"))
        }
        let stdoutURL = directory.appendingPathComponent("stdout.txt"), stderrURL = directory.appendingPathComponent("stderr.txt")
        files.createFile(atPath: stdoutURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        files.createFile(atPath: stderrURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let stdin = try FileHandle(forReadingFrom: inputURL)
        let stdout = try FileHandle(forWritingTo: stdoutURL), stderr = try FileHandle(forWritingTo: stderrURL)
        defer { try? stdin.close(); try? stdout.close(); try? stderr.close() }
        let process = Process()
        process.executableURL = executable; process.arguments = try provider?.arguments(in: directory, persistentConversation: persistentConversation, sessionID: sessionID) ?? arguments
        if let workingDirectory { try files.createDirectory(at: workingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        process.currentDirectoryURL = workingDirectory ?? directory; process.environment = environment
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        if cancellation.isCancelled { throw CancellationError() }
        do { try process.run() } catch { throw PersonalAgentError.unavailable(provider?.name ?? executable.lastPathComponent) }
        // File-backed I/O avoids pipe deadlocks for long prompts and verbose CLIs.
        // These owner-only temporary files are removed on success, failure, timeout and cancellation.
        // Foundation launches each Process in its own process group. Validate the
        // group before using it, and clean up wrapper children even after the leader exits.
        let pid = process.processIdentifier
        let group = pid != getpgrp() && (getpgid(pid) == pid || kill(-pid, 0) == 0) ? pid : nil
        defer {
            if let group {
                kill(-group, SIGTERM)
                let deadline = Date().addingTimeInterval(1)
                while kill(-group, 0) == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
                if kill(-group, 0) == 0 { kill(-group, SIGKILL) }
            } else if process.isRunning {
                process.terminate()
                let deadline = Date().addingTimeInterval(1)
                while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { kill(pid, SIGKILL) }
            }
            if process.isRunning {
                process.waitUntilExit()
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if cancellation.isCancelled { throw CancellationError() }
            if Date() >= deadline { throw PersonalAgentError.timedOut }
            for url in [stdoutURL, stderrURL, directory.appendingPathComponent(summaryAnswerFilename)] {
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 4_000_000 { throw PersonalAgentError.tooLarge }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if cancellation.isCancelled { throw CancellationError() }
        let output = try readOutput(stdoutURL)
        if let provider, process.terminationStatus == 0 {
            var conversationID: String?
            var completedCodexTurn = false
            if persistentConversation {
                let records = provider == .codex ? output.split(separator: "\n").map(String.init) : [output]
                for record in records {
                    guard let data = record.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    if provider == .codex, ["turn.failed", "error"].contains(object["type"] as? String ?? "") {
                        throw PersonalAgentError.invalidResponse(provider.name)
                    }
                    if provider == .codex, object["type"] as? String == "turn.completed" { completedCodexTurn = true }
                    let candidate = provider == .codex && object["type"] as? String == "thread.started" ? object["thread_id"] as? String : provider == .claude ? object["session_id"] as? String : nil
                    if let candidate, UUID(uuidString: candidate) != nil { conversationID = candidate }
                }
            }
            if persistentConversation, provider == .codex, !completedCodexTurn {
                throw PersonalAgentError.invalidResponse(provider.name)
            }
            return Result(status: 0, stdout: try provider.answer(stdout: output, directory: directory), sessionID: conversationID)
        }
        return Result(status: process.terminationStatus, stdout: output, stderr: try readOutput(stderrURL))
    }
}
