import Darwin
import Foundation

/// The `msgblast` command. It runs from inside the app bundle and talks to the running app's local socket.
public enum AgentControlCLI {
    public enum Command: Equatable {
        case help
        /// `msgblast mcp`: a stdio MCP server. The name overrides what the MCP client reports.
        case mcp(client: String?)
        /// One newline-terminated request for the socket.
        case request(Data)
    }

    public struct Output: Equatable {
        public var stdout: String, stderr: String, status: Int32
    }

    public static let commands: Set<String> = ["help", "mcp", "status", "agents", "comparisons", "show", "wait", "tools", "call"]
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
      mcp                                 Serve MCP on stdin and stdout

    --client names the agent asking. msgblast asks the person once per name.
    Exit status: 0 done, 1 failed, 2 invalid, 3 not approved, 4 not found, 5 msgblast unreachable.
    """

    public struct UsageError: Error, Equatable { public let message: String }

    public static func parse(_ arguments: [String], environment: [String: String]) throws -> (command: Command, json: Bool) {
        var words: [String] = [], options: [String: String] = [:], flags: Set<String> = []
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            index += 1
            if ["--json", "--all"].contains(word) { flags.insert(word) }
            else if word.hasPrefix("--") {
                guard index < arguments.count else { throw UsageError(message: "\(word) needs a value.") }
                options[word] = arguments[index]
                index += 1
            } else { words.append(word) }
        }
        let json = flags.contains("--json")
        let named = options["--client"] ?? environment["MSGBLAST_CLIENT"]
        let client = named ?? (environment["CLAUDECODE"] == "1" ? "Claude Code" : "Terminal")
        func call(_ tool: String, _ input: [String: Any]) throws -> (command: Command, json: Bool) {
            (.request(try line(["method": "tools/call", "client": client, "name": tool, "arguments": input])), json)
        }
        func number(_ option: String) throws -> Int? {
            guard let raw = options[option] else { return nil }
            guard let value = Int(raw) else { throw UsageError(message: "\(option) must be a whole number.") }
            return value
        }
        switch words.first {
        case nil, "help": return (.help, json)
        case "mcp": return (.mcp(client: named), json)
        case "status": return try call("msgblast_status", [:])
        case "agents": return try call("msgblast_agents_list", ["includeHidden": flags.contains("--all")])
        case "comparisons":
            var input: [String: Any] = [:]
            input["query"] = options["--query"]
            input["limit"] = try number("--limit")
            return try call("msgblast_comparisons_list", input)
        case "show":
            guard words.count == 2 else { throw UsageError(message: "show needs one comparison id.") }
            return try call("msgblast_comparison_read", ["id": words[1]])
        case "wait":
            var input: [String: Any] = [:]
            input["after"] = try number("--after")
            input["comparisonId"] = options["--comparison"]
            input["timeoutSeconds"] = try number("--timeout")
            return try call("msgblast_blast_wait", input)
        case "tools": return (.request(try line(["method": "tools/list", "client": client])), json)
        case "call":
            guard (2...3).contains(words.count) else { throw UsageError(message: "call needs a tool name and optional JSON arguments.") }
            let raw = words.count == 3 ? words[2] : "{}"
            guard let input = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
                throw UsageError(message: "Arguments must be one JSON object.")
            }
            return try call(words[1], input)
        case let other?: throw UsageError(message: "Unknown command \(other).")
        }
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
