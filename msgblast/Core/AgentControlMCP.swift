import Foundation

/// The stdio MCP server behind `msgblast mcp`. It forwards to the running app's local socket and speaks
/// both MCP 2026-07-28 (per-request `_meta`, `server/discover`) and the older `initialize` handshake.
public actor AgentControlMCPServer {
    public typealias Exchange = @Sendable (Data) async throws -> Data
    public static let modernVersion = "2026-07-28"
    /// 2025-03-26 is left out on purpose: it requires JSON-RPC batches, which msgblast refuses.
    public static let legacyVersions = ["2025-11-25", "2025-06-18"]
    static let instructions = "msgblast sends one prompt to many AI agents and Messages contacts at once and keeps their replies side by side as a comparison. Use msgblast_agents_list to see the agents, msgblast_comparisons_list and msgblast_comparison_read to read comparisons, and msgblast_blast_wait to wait for replies instead of polling. Each agent gets the access level the person chose in msgblast."
    static let unavailable = "msgblast is not running, or Settings → Outside agents is off."

    private struct Failure: Error { let code: Int, message: String; var requested: String? = nil }
    private struct WireReply { let result: Any?, error: (code: String, message: String)? }
    private let exchange: Exchange
    private let version: String
    private let fixedClient: String?
    private var handshakeClient: String?
    private var wireID = 0

    /// `client` overrides the name the MCP client reports, for agents that report a generic one.
    public init(version: String, client: String?, exchange: @escaping Exchange) {
        self.version = version
        fixedClient = client
        self.exchange = exchange
    }

    /// One JSON-RPC message in, one line out. Notifications and stray responses get nothing back.
    public func handle(_ line: Data) async -> Data? {
        guard let parsed = try? JSONSerialization.jsonObject(with: line, options: .fragmentsAllowed) else {
            return Self.encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Each line must be one JSON-RPC message."]])
        }
        guard let message = parsed as? [String: Any] else {
            return Self.encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Send one JSON-RPC object per line. Batches are not supported."]])
        }
        // A request names a method and has an id; no id is a notification, no method a stray response.
        guard let id = message["id"], message["method"] != nil else { return nil }
        guard let method = message["method"] as? String else {
            return Self.encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32600, "message": "method must be a string."]])
        }
        let params = message["params"] as? [String: Any] ?? [:]
        do {
            return Self.encode(["jsonrpc": "2.0", "id": id, "result": try await result(method, params: params)])
        } catch let failure as Failure {
            var error: [String: Any] = ["code": failure.code, "message": failure.message]
            if let requested = failure.requested { error["data"] = ["supported": [Self.modernVersion] + Self.legacyVersions, "requested": requested] }
            return Self.encode(["jsonrpc": "2.0", "id": id, "error": error])
        } catch {
            return Self.encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": "msgblast could not handle \(method)."]])
        }
    }

    /// The result of one request. Modern requests carry their version and client in `_meta`.
    private func result(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if method == "initialize" { return initialize(params) }
        if method == "ping" { return [:] }
        let meta = params["_meta"] as? [String: Any] ?? [:]
        let requested = meta["io.modelcontextprotocol/protocolVersion"] as? String
        if let requested, requested != Self.modernVersion {
            throw Failure(code: -32022, message: "Unsupported protocol version", requested: requested)
        }
        let reported = Self.name(meta["io.modelcontextprotocol/clientInfo"] as? [String: Any])
        let client = fixedClient ?? reported ?? handshakeClient ?? "MCP client"
        var result: [String: Any]
        switch method {
        case "server/discover": result = discover()
        case "tools/list": result = try await listTools(client: client)
        case "tools/call": result = try await callTool(params, client: client)
        default: throw Failure(code: -32601, message: "msgblast has no method \(method).")
        }
        if requested != nil { result["resultType"] = "complete" }
        return result
    }

    private var serverInfo: [String: Any] { ["name": "msgblast", "title": "msgblast", "version": version] }

    private func initialize(_ params: [String: Any]) -> [String: Any] {
        handshakeClient = Self.name(params["clientInfo"] as? [String: Any])
        let asked = params["protocolVersion"] as? String ?? ""
        return ["protocolVersion": Self.legacyVersions.contains(asked) ? asked : Self.legacyVersions[0],
                "capabilities": ["tools": [String: Any]()], "serverInfo": serverInfo, "instructions": Self.instructions]
    }

    private func discover() -> [String: Any] {
        ["supportedVersions": [Self.modernVersion] + Self.legacyVersions, "capabilities": ["tools": [String: Any]()],
         "_meta": ["io.modelcontextprotocol/serverInfo": serverInfo], "instructions": Self.instructions,
         "ttlMs": 3_600_000, "cacheScope": "public"]
    }

    private func listTools(client: String) async throws -> [String: Any] {
        let reply = try await send(["method": "tools/list"], client: client)
        if let error = reply.error { throw Failure(code: -32001, message: error.message) }
        let tools = (reply.result as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        return ["tools": tools.map { tool -> [String: Any] in
            let access = tool["access"] as? String ?? ""
            var description = tool["description"] as? String ?? ""
            if tool["allowed"] as? Bool != true {
                description += " Needs \(access) access. The person can change this in msgblast → Settings → Outside agents."
            }
            return ["name": tool["name"] ?? "", "title": tool["title"] ?? "", "description": description,
                    "inputSchema": tool["inputSchema"] ?? ["type": "object"],
                    "annotations": ["readOnlyHint": access == AgentControlAccess.readOnly.label, "openWorldHint": false]]
        }]
    }

    private func callTool(_ params: [String: Any], client: String) async throws -> [String: Any] {
        guard let name = params["name"] as? String else { throw Failure(code: -32602, message: "tools/call needs a name.") }
        let reply: WireReply
        do { reply = try await send(["method": "tools/call", "name": name, "arguments": params["arguments"] ?? [String: Any]()], client: client) }
        catch { return ["content": [["type": "text", "text": (error as? Failure)?.message ?? Self.unavailable]], "isError": true] }
        let result = reply.result
        if let error = reply.error {
            if error.code == "unknownTool" { throw Failure(code: -32602, message: error.message) }
            return ["content": [["type": "text", "text": error.message]], "isError": true]
        }
        let text = (try? JSONSerialization.data(withJSONObject: result ?? NSNull(), options: [.sortedKeys, .fragmentsAllowed]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        var output: [String: Any] = ["content": [["type": "text", "text": text]], "isError": false]
        if let object = result as? [String: Any] { output["structuredContent"] = object }
        return output
    }

    /// One request on the app's socket. Throws only when the app cannot be reached, or when it
    /// got the request and stopped before answering (the request may then have run).
    private func send(_ request: [String: Any], client: String) async throws -> WireReply {
        wireID += 1
        var body = request
        body["id"] = wireID
        body["client"] = client
        var line = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        line.append(0x0A)
        let reply: Data
        do { reply = try await exchange(line) } catch is AgentControlSocketClient.NoReply {
            throw Failure(code: -32002, message: AgentControlCLI.noReply)
        } catch { throw Failure(code: -32002, message: Self.unavailable) }
        let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any]
        if let error = object?["error"] as? [String: Any] {
            return WireReply(result: nil, error: (error["code"] as? String ?? "failed", error["message"] as? String ?? "msgblast could not do that."))
        }
        return WireReply(result: object?["result"], error: nil)
    }

    /// The name the MCP client reports, made safe the same way the socket checks names.
    private static func name(_ info: [String: Any]?) -> String? {
        for key in ["title", "name"] {
            guard let raw = info?[key] as? String else { continue }
            if let name = AgentControlGate.clientName(String(raw.prefix(400))) { return String(name.prefix(80)) }
        }
        return nil
    }

    private static func encode(_ body: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
            ?? Data(#"{"error":{"code":-32603,"message":"Could not encode the reply."},"id":null,"jsonrpc":"2.0"}"#.utf8)
        data.append(0x0A)
        return data
    }
}
