import Foundation

/// Which outside agents the person approved, and at what level. Saved beside state.json.
/// An unreadable file refuses every agent and is never overwritten.
@MainActor public final class AgentControlGate: ObservableObject {
    public typealias Approve = @MainActor (String) async -> AgentControlAccess?
    @Published public private(set) var approvals: [String: AgentControlAccess] = [:]
    public let loadFailed: Bool
    private let file: URL
    private var pending: [String: Task<AgentControlAccess?, Never>] = [:]

    public init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file) {
            let decoded = try? JSONDecoder().decode([String: AgentControlAccess].self, from: data)
            approvals = decoded ?? [:]
            loadFailed = decoded == nil
        } else {
            loadFailed = FileManager.default.fileExists(atPath: file.path)
        }
    }

    /// The client's level, asking the person once if it is new. Nil means refused.
    public func access(for client: String, approve: @escaping Approve) async -> AgentControlAccess? {
        guard !loadFailed else { return nil }
        if let level = approvals[client] { return level }
        if let waiting = pending[client] { return await waiting.value }
        let task = Task { @MainActor in await approve(client) }
        pending[client] = task
        let level = await task.value
        pending[client] = nil
        if let level { try? set(level, for: client) }
        return level
    }

    public func set(_ level: AgentControlAccess?, for client: String) throws {
        guard !loadFailed else { return }
        var next = approvals
        next[client] = level
        try JSONEncoder().encode(next).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        approvals = next
    }
}

/// One newline-delimited JSON request per line on the local socket:
/// `{"id":1,"client":"Claude Code","method":"tools/list"}` or
/// `{"id":2,"client":"Claude Code","method":"tools/call","name":"msgblast_status","arguments":{}}`.
public enum AgentControlWire {
    @MainActor public static func respond(to line: Data, host: AgentControlHost, gate: AgentControlGate, approve: @escaping AgentControlGate.Approve) async -> Data {
        guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return reply(nil, error: "invalidRequest", "Each line must be one JSON object.")
        }
        let id = request["id"]
        guard let client = (request["client"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !client.isEmpty, client.count <= 80 else {
            return reply(id, error: "invalidRequest", "Name the agent in \"client\".")
        }
        guard let access = await gate.access(for: client, approve: approve) else {
            return reply(id, error: "notApproved", "msgblast has not approved \(client). Approve it in msgblast → Settings → Outside agents.")
        }
        switch request["method"] as? String {
        case "tools/list":
            let tools = AgentControl.tools.map { tool -> [String: Any] in
                ["name": tool.name, "title": tool.title, "description": tool.summary, "access": tool.access.label,
                 "allowed": access >= tool.access,
                 "inputSchema": (try? JSONSerialization.jsonObject(with: Data(tool.inputSchema.utf8))) ?? [:]]
            }
            return reply(id, result: ["tools": tools])
        case "tools/call":
            guard let name = request["name"] as? String else { return reply(id, error: "invalidRequest", "tools/call needs \"name\".") }
            let arguments = (request["arguments"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
            do {
                let data = try await AgentControl.call(name, arguments: arguments, access: access, host: host)
                return reply(id, result: try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed))
            } catch {
                return reply(id, error: code(error), error.localizedDescription)
            }
        default:
            return reply(id, error: "invalidRequest", "Unknown method. Use tools/list or tools/call.")
        }
    }

    private static func code(_ error: Error) -> String {
        switch error as? AgentControlError {
        case .unknownTool: "unknownTool"
        case .needsAccess: "needsAccess"
        case .invalidArguments: "invalidArguments"
        case .notFound: "notFound"
        case nil: "failed"
        }
    }

    private static func reply(_ id: Any?, result: Any? = nil, error code: String? = nil, _ message: String = "") -> Data {
        var body: [String: Any] = ["id": id ?? NSNull()]
        if let code { body["error"] = ["code": code, "message": message] } else { body["result"] = result ?? NSNull() }
        var data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data(#"{"error":{"code":"failed"}}"#.utf8)
        data.append(0x0A)
        return data
    }
}
