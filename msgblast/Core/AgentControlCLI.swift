import Darwin
import Foundation

/// The `msgblast` command. It runs from inside the app bundle and talks to the running app's local socket.
public enum AgentControlCLI {
    public enum Command: Equatable {
        case help
        /// One newline-terminated request for the socket.
        case request(Data)
    }

    public struct Output: Equatable {
        public var stdout: String, stderr: String, status: Int32
    }

    public static let commands: Set<String> = ["help", "status", "agents", "comparisons", "show", "wait", "tools", "call"]
    public static let unavailableStatus: Int32 = 5
    public static let usage = """
    usage: msgblast <command> [--client NAME] [--json]

      status                              Version, permissions, and busy agents
      agents [--all]                      Agents msgblast can send to
      comparisons [--query TEXT] [--limit N]
      show ID                             A comparison and its conversation
      wait [--after N] [--comparison ID] [--timeout SECONDS]
      tools                               Every tool and whether this agent may use it
      call TOOL [JSON]                    Run any msgblast tool

    --client names the agent asking. msgblast asks the person once per name.
    Exit status: 0 done, 1 failed, 2 invalid, 3 not approved, 4 not found, 5 msgblast unreachable.
    """

    public struct UsageError: Error, Equatable { public let message: String }

    static let flags: Set<String> = ["--json", "--all", "--help"]
    static let valueOptions: Set<String> = ["--client", "--query", "--limit", "--after", "--comparison", "--timeout"]

    /// True when the arguments ask for the msgblast command rather than the app: the first
    /// word that is not one of the command's own options names a command, or there are only
    /// such options. The app's own launch options, such as --demo, still open a window.
    public static func isCommand(_ arguments: [String]) -> Bool {
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            if flags.contains(word) { index += 1 } else if valueOptions.contains(word) { index += 2 } else { return commands.contains(word) }
        }
        return !arguments.isEmpty
    }

    public static func parse(_ arguments: [String], environment: [String: String]) throws -> (command: Command, json: Bool) {
        let words = try split(arguments)
        let json = words.flags.contains("--json")
        let names = try clientNames(words.options, environment: environment)
        if words.flags.contains("--help") { return (.help, json) }
        return (try command(words, names: names), json)
    }

    struct Words { var words: [String] = [], options: [String: String] = [:], flags: Set<String> = [] }

    /// Command words, options with their values, and flags. Unknown options are refused.
    static func split(_ arguments: [String]) throws -> Words {
        var result = Words()
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            index += 1
            if flags.contains(word) { result.flags.insert(word) }
            else if valueOptions.contains(word) {
                guard index < arguments.count else { throw UsageError(message: "\(word) needs a value.") }
                result.options[word] = arguments[index]
                index += 1
            } else if word.hasPrefix("--") { throw UsageError(message: "Unknown option \(word).") }
            else { result.words.append(word) }
        }
        return result
    }

    /// The name the person gave (--client or MSGBLAST_CLIENT), if any, and the name to send.
    static func clientNames(_ options: [String: String], environment: [String: String]) throws -> (given: String?, client: String) {
        guard let raw = options["--client"] ?? environment["MSGBLAST_CLIENT"] else {
            return (nil, environment["CLAUDECODE"] == "1" ? "Claude Code" : "Terminal")
        }
        guard let name = AgentControlGate.clientName(raw) else { throw UsageError(message: "--client must be a name of 1 to 80 characters.") }
        return (name, name)
    }

    /// Commands that call one tool with arguments taken from options.
    static let optionTools = ["status": "msgblast_status", "agents": "msgblast_agents_list", "comparisons": "msgblast_comparisons_list", "wait": "msgblast_blast_wait"]

    static func command(_ words: Words, names: (given: String?, client: String)) throws -> Command {
        let client = names.client
        switch words.words.first {
        case nil, "help": return .help
        case "tools": return .request(try line(["method": "tools/list", "client": client]))
        case "show":
            guard words.words.count == 2 else { throw UsageError(message: "show needs one comparison id.") }
            return try call("msgblast_comparison_read", ["id": words.words[1]], client: client)
        case "call": return try call(words.words, client: client)
        case let other?:
            guard let tool = optionTools[other] else { throw UsageError(message: "Unknown command \(other).") }
            return try call(tool, try arguments(other, words), client: client)
        }
    }

    static func arguments(_ command: String, _ words: Words) throws -> [String: Any] {
        var input: [String: Any] = [:]
        switch command {
        case "agents": input["includeHidden"] = words.flags.contains("--all")
        case "comparisons":
            input["query"] = words.options["--query"]
            input["limit"] = try number("--limit", words)
        case "wait":
            input["after"] = try number("--after", words)
            input["comparisonId"] = words.options["--comparison"]
            input["timeoutSeconds"] = try number("--timeout", words)
        default: break
        }
        return input
    }

    static func number(_ option: String, _ words: Words) throws -> Int? {
        guard let raw = words.options[option] else { return nil }
        guard let value = Int(raw) else { throw UsageError(message: "\(option) must be a whole number.") }
        return value
    }

    /// `call TOOL [JSON]`.
    static func call(_ words: [String], client: String) throws -> Command {
        guard (2...3).contains(words.count) else { throw UsageError(message: "call needs a tool name and optional JSON arguments.") }
        let raw = words.count == 3 ? words[2] : "{}"
        guard let input = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            throw UsageError(message: "Arguments must be one JSON object.")
        }
        return try call(words[1], input, client: client)
    }

    static func call(_ tool: String, _ input: [String: Any], client: String) throws -> Command {
        .request(try line(["method": "tools/call", "client": client, "name": tool, "arguments": input]))
    }

    /// Turns the app's reply into what the command prints and its exit status.
    public static func render(_ reply: Data, json: Bool) -> Output {
        guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
            return Output(stdout: "", stderr: "msgblast sent a reply this command could not read.\n", status: 1)
        }
        if let error = object["error"] as? [String: Any] {
            let status: Int32
            switch error["code"] as? String {
            case "notApproved", "needsAccess": status = 3
            case "notFound": status = 4
            case "invalidRequest", "invalidArguments", "unknownTool": status = 2
            default: status = 1
            }
            return Output(stdout: "", stderr: (error["message"] as? String ?? "msgblast could not do that.") + "\n", status: status)
        }
        let options: JSONSerialization.WritingOptions = json ? [.sortedKeys, .fragmentsAllowed] : [.sortedKeys, .prettyPrinted, .fragmentsAllowed]
        let data = (try? JSONSerialization.data(withJSONObject: object["result"] ?? NSNull(), options: options)) ?? Data("null".utf8)
        return Output(stdout: (String(data: data, encoding: .utf8) ?? "null") + "\n", stderr: "", status: 0)
    }

    private static func line(_ body: [String: Any]) throws -> Data {
        var request = body
        request["id"] = 1
        var data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }
}

/// A blocking client for the app's Unix socket, used by the command-line process only.
public enum AgentControlSocketClient {
    public struct Unavailable: Error {}

    /// Sends one request line and returns the reply line. Throws `Unavailable` when nothing is listening.
    public static func exchange(_ line: Data, socket path: String) throws -> Data {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Unavailable() }
        defer { close(descriptor) }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw Unavailable() }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in buffer.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw Unavailable() }
        var sent = 0
        while sent < line.count {
            let count = line[sent...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            guard count > 0 else { throw Unavailable() }
            sent += count
        }
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while !reply.contains(0x0A) {
            let count = read(descriptor, &chunk, chunk.count)
            guard count > 0 else { throw Unavailable() }
            reply.append(contentsOf: chunk[0..<count])
        }
        return reply.prefix(while: { $0 != 0x0A }) + Data([0x0A])
    }
}
