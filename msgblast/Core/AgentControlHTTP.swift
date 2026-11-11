import Foundation

/// One HTTP/1.1 request. Header names are lowercased. `parse` is incremental so a socket can pipeline.
public struct AgentControlHTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data

    public enum ParseResult: Equatable, Sendable {
        case incomplete
        case invalid
        case tooLarge
        case complete(request: AgentControlHTTPRequest, consumed: Int)
    }

    static let headerLimit = 16 * 1024
    static let bodyLimit = 1_048_576

    /// HTTP/1.1 only. The body is `Content-Length` bytes. `Transfer-Encoding` is rejected.
    public static func parse(_ buffer: Data) -> ParseResult {
        let marker = Data([13, 10, 13, 10])
        guard let range = buffer.range(of: marker) else {
            return buffer.count > headerLimit ? .tooLarge : .incomplete
        }
        let headerCount = buffer.distance(from: buffer.startIndex, to: range.lowerBound)
        if headerCount > headerLimit { return .tooLarge }
        guard let head = String(data: buffer.subdata(in: 0..<headerCount), encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else { return .invalid }
        lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty, parts[2] == "HTTP/1.1" else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let rawName = line[..<colon]
            guard !rawName.isEmpty, rawName.unicodeScalars.allSatisfy({ (33...126).contains($0.value) && $0.value != 58 }) else { return .invalid }
            let name = rawName.lowercased()
            guard headers[name] == nil else { return .invalid }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return .invalid }
        let length: Int
        if let raw = headers["content-length"] {
            guard !raw.isEmpty, raw.allSatisfy(\.isNumber), let value = Int(raw) else { return .invalid }
            length = value
        } else {
            length = 0
        }
        if length > bodyLimit { return .tooLarge }
        let bodyStart = headerCount + marker.count
        let consumed = bodyStart + length
        guard buffer.count >= consumed else { return .incomplete }
        let request = AgentControlHTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: headers,
                                              body: buffer.subdata(in: bodyStart..<consumed))
        return .complete(request: request, consumed: consumed)
    }
}

/// One HTTP/1.1 response. `encoded` always sets the length, cache, and connection headers.
public struct AgentControlHTTPResponse: Sendable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public func encoded() -> Data {
        var fields = headers
        func has(_ name: String) -> Bool { fields.contains { $0.0.caseInsensitiveCompare(name) == .orderedSame } }
        if !has("Cache-Control") { fields.append(("Cache-Control", "no-store")) }
        if !has("Content-Length") { fields.append(("Content-Length", String(body.count))) }
        if !has("Connection") { fields.append(("Connection", status >= 400 ? "close" : "keep-alive")) }
        var text = "HTTP/1.1 \(status) \(Self.reason(status))"
        for (name, value) in fields { text += "\r\n\(name): \(value)" }
        text += "\r\n\r\n"
        var data = Data(text.utf8)
        data.append(body)
        return data
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Content Too Large"
        case 503: "Service Unavailable"
        default: "Error"
        }
    }
}

/// POST-only HTTP MCP. `Authorization: Bearer` is the token; `/mcp/<token>` is a fallback. One server per client.
public actor AgentControlHTTPEndpoint {
    private let hashes: [String: String]
    private let version: String
    private let exchange: AgentControlMCPServer.Exchange
    private var servers: [String: AgentControlMCPServer] = [:]
    /// When the last request passed the key check. Not saved.
    public private(set) var lastAuthorized: Date?

    /// `hashes` maps a client name to the hex SHA-256 of its token.
    public init(hashes: [String: String], version: String, exchange: @escaping AgentControlMCPServer.Exchange) {
        self.hashes = hashes
        self.version = version
        self.exchange = exchange
    }

    public func handle(_ request: AgentControlHTTPRequest, peer: String) async -> AgentControlHTTPResponse {
        guard AgentControlTailnet.isTailnetPeer(peer) else { return empty(403) }
        if request.headers["origin"] != nil { return empty(403) }
        switch credential(request) {
        case .elsewhere: return empty(404)
        case .rejected: return AgentControlHTTPResponse(status: 401, headers: [("WWW-Authenticate", "Bearer")], body: Data())
        case .accepted(let client):
            lastAuthorized = Date()
            guard request.method == "POST" else {
                return AgentControlHTTPResponse(status: 405, headers: [("Allow", "POST")], body: Data())
            }
            if (try? JSONSerialization.jsonObject(with: request.body)) is [Any] {
                return json(400, code: -32600, "JSON-RPC batches are not supported.")
            }
            return await finish(server(client), request.body)
        }
    }

    private enum Credential { case accepted(String), rejected, elsewhere }

    /// Bearer wins when the header is present. Otherwise `/mcp/<token>` is the token. The query string is ignored.
    private func credential(_ request: AgentControlHTTPRequest) -> Credential {
        let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        let header = request.headers["authorization"]
        let pathToken: String?
        if path == "/mcp" {
            pathToken = nil
        } else if path.hasPrefix("/mcp/") {
            let rest = String(path.dropFirst("/mcp/".count))
            guard !rest.isEmpty, !rest.contains("/") else { return .elsewhere }
            pathToken = rest
        } else {
            return .elsewhere
        }
        let given = header != nil ? bearer(header) : pathToken
        guard let given, let client = client(for: given) else { return .rejected }
        return .accepted(client)
    }

    private func bearer(_ value: String?) -> String? {
        guard let value else { return nil }
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].caseInsensitiveCompare("bearer") == .orderedSame else { return nil }
        let token = String(parts[1])
        return token.isEmpty ? nil : token
    }

    private func client(for token: String) -> String? {
        var found: String?
        for (name, hash) in hashes {
            if AgentControlTailnet.hashMatches(token, hash) { found = name }
        }
        return found
    }

    private func server(_ client: String) -> AgentControlMCPServer {
        if let existing = servers[client] { return existing }
        let created = AgentControlMCPServer(version: version, client: client, exchange: exchange)
        servers[client] = created
        return created
    }

    private func finish(_ server: AgentControlMCPServer, _ body: Data) async -> AgentControlHTTPResponse {
        guard var payload = await server.handle(body) else {
            return AgentControlHTTPResponse(status: 202, headers: [], body: Data())
        }
        if payload.last == 0x0A { payload.removeLast() }
        return AgentControlHTTPResponse(status: 200, headers: [("Content-Type", "application/json")], body: payload)
    }

    private func empty(_ status: Int) -> AgentControlHTTPResponse {
        AgentControlHTTPResponse(status: status, headers: [], body: Data())
    }

    private func json(_ status: Int, code: Int, _ message: String) -> AgentControlHTTPResponse {
        let object: [String: Any] = ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": code, "message": message]]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return AgentControlHTTPResponse(status: status, headers: [("Content-Type", "application/json")], body: data)
    }
}
