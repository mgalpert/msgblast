import XCTest
@testable import msgblastCore

final class AgentControlHTTPTests: XCTestCase {
    /// Stands in for the app socket: records each request line and answers from `replies` by method or tool name.
    private actor Socket {
        var lines: [Data] = []
        let replies: [String: String]
        init(_ replies: [String: String]) { self.replies = replies }
        func answer(_ line: Data) throws -> Data {
            lines.append(line)
            let request = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
            let key = (request["name"] as? String) ?? (request["method"] as? String ?? "")
            guard let reply = replies[key] else { throw CocoaError(.fileNoSuchFile) }
            return Data((reply + "\n").utf8)
        }
        func line(_ index: Int) -> Data { lines[index] }
    }

    private func raw(_ text: String) -> Data { Data(text.utf8) }

    private func parsed(_ text: String) throws -> (AgentControlHTTPRequest, Int) {
        guard case .complete(let request, let consumed) = AgentControlHTTPRequest.parse(raw(text)) else {
            XCTFail("expected a complete request")
            throw CocoaError(.fileReadCorruptFile)
        }
        return (request, consumed)
    }

    private func request(_ method: String, _ path: String, _ body: String = "", headers: [String: String] = [:]) throws -> AgentControlHTTPRequest {
        var lines = ["\(method) \(path) HTTP/1.1", "Host: 100.64.0.1"]
        for (name, value) in headers { lines.append("\(name): \(value)") }
        if method == "POST" || !body.isEmpty { lines.append("Content-Length: \(Data(body.utf8).count)") }
        return try parsed(lines.joined(separator: "\r\n") + "\r\n\r\n" + body).0
    }

    private func header(_ response: AgentControlHTTPResponse, _ name: String) -> String? {
        response.headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }

    private func json(_ response: AgentControlHTTPResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    func testParseCompleteIncompleteAndPipelined() throws {
        let body = "{\"a\":\"\r\n\r\n\"}"
        let one = "POST /mcp/token?x=1 HTTP/1.1\r\nHost: Example\r\nContent-Length: \(Data(body.utf8).count)\r\n\r\n\(body)"
        let (request, consumed) = try parsed(one)
        XCTAssertEqual(consumed, Data(one.utf8).count)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/mcp/token?x=1")
        XCTAssertEqual(request.headers["host"], "Example")
        XCTAssertEqual(request.headers["content-length"], String(Data(body.utf8).count))
        XCTAssertEqual(request.body, Data(body.utf8))
        // `\r\n` is one Character, so the cut is in UTF-8 bytes.
        XCTAssertEqual(AgentControlHTTPRequest.parse(Data(one.utf8.dropLast(2))), .incomplete)
        let pair = one + one
        let first = try parsed(pair)
        XCTAssertEqual(first.1, Data(one.utf8).count)
        let second = try parsed(String(decoding: pair.utf8.dropFirst(first.1), as: UTF8.self))
        XCTAssertEqual(first.1 + second.1, Data(pair.utf8).count)
        XCTAssertEqual(second.0.body, Data(body.utf8))
    }

    /// The Tailscale link drops each finished request with `removeFirst`, which leaves a slice whose indices don't start at 0.
    func testParseAKeepAliveBufferAfterRemoveFirst() {
        var buffer = raw("POST /mcp HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}POST /mcp HTTP/1.1\r\nContent-Length: 3\r\n\r\n[1")
        guard case .complete(_, let first) = AgentControlHTTPRequest.parse(buffer) else { return XCTFail("first request") }
        buffer.removeFirst(first)
        XCTAssertNotEqual(buffer.startIndex, 0)
        XCTAssertEqual(AgentControlHTTPRequest.parse(buffer), .incomplete)
        buffer.append(raw("]"))
        guard case .complete(let second, let size) = AgentControlHTTPRequest.parse(buffer) else { return XCTFail("second request") }
        XCTAssertEqual(second.body, Data("[1]".utf8))
        XCTAssertEqual(size, buffer.count)
    }

    func testParseTooLargeAndChunked() {
        let chunked = "POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
        XCTAssertEqual(AgentControlHTTPRequest.parse(raw(chunked)), .invalid)
        let huge = "POST /mcp HTTP/1.1\r\nContent-Length: \(AgentControlHTTPRequest.bodyLimit + 1)\r\n\r\n"
        XCTAssertEqual(AgentControlHTTPRequest.parse(raw(huge)), .tooLarge)
        let padded = "POST /mcp HTTP/1.1\r\nX-Pad: " + String(repeating: "a", count: AgentControlHTTPRequest.headerLimit) + "\r\n\r\n"
        XCTAssertEqual(AgentControlHTTPRequest.parse(raw(padded)), .tooLarge)
        XCTAssertEqual(AgentControlHTTPRequest.parse(Data(repeating: 0x41, count: AgentControlHTTPRequest.headerLimit + 1)), .tooLarge)
    }

    func testTailnetPeersAndTokens() {
        XCTAssertTrue(AgentControlTailnet.isTailnetPeer("100.64.0.1"))
        XCTAssertFalse(AgentControlTailnet.isTailnetPeer("100.128.0.1"))
        XCTAssertFalse(AgentControlTailnet.isTailnetPeer("192.168.1.2"))
        XCTAssertTrue(AgentControlTailnet.isTailnetPeer("fd7a:115c:a1e0::1"))
        XCTAssertTrue(AgentControlTailnet.isTailnetPeer("FD7A:115C:A1E0::1%utun3"))
        XCTAssertTrue(AgentControlTailnet.isTailnetPeer("::ffff:100.68.57.78"))
        XCTAssertFalse(AgentControlTailnet.isTailnetPeer("127.0.0.1"))
        XCTAssertFalse(AgentControlTailnet.isTailnetPeer("::1"))
        let token = AgentControlTailnet.newToken()
        XCTAssertEqual(token.count, 43)
        XCTAssertTrue(token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        XCTAssertTrue(AgentControlTailnet.tokenMatches(token, token))
        XCTAssertFalse(AgentControlTailnet.tokenMatches(nil, token))
        XCTAssertFalse(AgentControlTailnet.tokenMatches("", token))
        XCTAssertFalse(AgentControlTailnet.tokenMatches(String(token.dropLast()), token))
        XCTAssertNotEqual(AgentControlTailnet.newToken(), token)
        XCTAssertTrue(AgentControlTailnet.hashMatches(token, AgentControlTailnet.tokenHash(token).uppercased()))
        XCTAssertFalse(AgentControlTailnet.hashMatches(nil, AgentControlTailnet.tokenHash(token)))
        XCTAssertFalse(AgentControlTailnet.hashMatches("", AgentControlTailnet.tokenHash(token)))
    }

    func testBearerIsPrimaryAndPathIsFallback() async throws {
        let socket = Socket(["tools/list": #"{"id":1,"result":{"tools":[]}}"#])
        let endpoint = endpoint("secret-token", socket)
        let denied = await endpoint.handle(try request("POST", "/mcp", "{}"), peer: "100.64.0.1")
        XCTAssertEqual(denied.status, 401)
        XCTAssertEqual(header(denied, "WWW-Authenticate"), "Bearer")
        XCTAssertTrue(denied.body.isEmpty)
        let elsewhere = await endpoint.handle(try request("POST", "/status", "{}"), peer: "100.64.0.1")
        XCTAssertEqual(elsewhere.status, 404)
        let offTailnet = await endpoint.handle(try request("POST", "/mcp", "{}", headers: ["Authorization": "Bearer secret-token"]), peer: "192.168.1.2")
        XCTAssertEqual(offTailnet.status, 403)
        XCTAssertTrue(String(decoding: offTailnet.encoded(), as: UTF8.self).contains("Connection: close"))

        let bearer = await endpoint.handle(try request("POST", "/mcp", toolsList, headers: ["Authorization": "bearer secret-token"]), peer: "::ffff:100.68.57.78")
        XCTAssertEqual(bearer.status, 200)
        XCTAssertEqual(header(bearer, "Content-Type"), "application/json")
        XCTAssertNil(header(bearer, "Mcp-Session-Id"))
        let encoded = String(decoding: bearer.encoded(), as: UTF8.self)
        XCTAssertTrue(encoded.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(encoded.contains("Cache-Control: no-store\r\n"))
        XCTAssertTrue(encoded.contains("Connection: keep-alive\r\n"))
        let forwardedLine = await socket.line(0)
        let forwarded = try XCTUnwrap(JSONSerialization.jsonObject(with: forwardedLine) as? [String: Any])
        XCTAssertEqual(forwarded["client"] as? String, "Grok Bot (Tailscale)")
        XCTAssertEqual(forwarded["method"] as? String, "tools/list")

        let path = await endpoint.handle(try request("POST", "/mcp/secret-token?x=1", toolsList), peer: "100.64.0.1")
        XCTAssertEqual(path.status, 200)
        let pathLine = await socket.line(1)
        let pathClient = try XCTUnwrap(JSONSerialization.jsonObject(with: pathLine) as? [String: Any])
        XCTAssertEqual(pathClient["client"] as? String, "Grok Bot (Tailscale)")

        let bearerWins = await endpoint.handle(try request("POST", "/mcp/secret-token", toolsList, headers: ["Authorization": "Bearer nope"]), peer: "100.64.0.1")
        XCTAssertEqual(bearerWins.status, 401)
        XCTAssertTrue(bearerWins.body.isEmpty)
        XCTAssertFalse(String(decoding: bearerWins.encoded(), as: UTF8.self).contains("nope"))
        XCTAssertFalse(String(decoding: bearerWins.encoded(), as: UTF8.self).contains("secret-token"))
        let calls = await socket.lines
        XCTAssertEqual(calls.count, 2)
    }

    func testWrongTokenDoesNotAskForApproval() async throws {
        let socket = Socket(["tools/list": #"{"id":1,"result":{"tools":[]}}"#])
        let endpoint = endpoint("secret-token", socket)
        let wrong = await endpoint.handle(try request("POST", "/mcp/nope", toolsList), peer: "100.64.0.1")
        XCTAssertEqual(wrong.status, 401)
        XCTAssertEqual(header(wrong, "WWW-Authenticate"), "Bearer")
        XCTAssertTrue(wrong.body.isEmpty)
        XCTAssertFalse(String(decoding: wrong.encoded(), as: UTF8.self).contains("nope"))
        XCTAssertFalse(String(decoding: wrong.encoded(), as: UTF8.self).contains("secret-token"))
        let lines = await socket.lines
        XCTAssertTrue(lines.isEmpty)
    }

    func testOriginAndMethods() async throws {
        let socket = Socket([:])
        let endpoint = endpoint("secret-token", socket)
        let origin = await endpoint.handle(try request("POST", "/mcp", toolsList, headers: ["Authorization": "Bearer secret-token", "Origin": "http://evil"]), peer: "100.64.0.1")
        XCTAssertEqual(origin.status, 403)
        let bareOrigin = await endpoint.handle(try request("GET", "/status", headers: ["Origin": "http://evil"]), peer: "100.64.0.1")
        XCTAssertEqual(bareOrigin.status, 403)
        let get = await endpoint.handle(try request("GET", "/mcp", headers: ["Authorization": "Bearer secret-token"]), peer: "fd7a:115c:a1e0::1")
        XCTAssertEqual(get.status, 405)
        XCTAssertEqual(header(get, "Allow"), "POST")
        let deleted = await endpoint.handle(try request("DELETE", "/mcp/secret-token"), peer: "100.64.0.1")
        XCTAssertEqual(deleted.status, 405)
        XCTAssertEqual(header(deleted, "Allow"), "POST")
        let put = await endpoint.handle(try request("PUT", "/mcp", headers: ["Authorization": "Bearer secret-token"]), peer: "100.64.0.1")
        XCTAssertEqual(put.status, 405)
        XCTAssertEqual(header(put, "Allow"), "POST")
        let lines = await socket.lines
        XCTAssertTrue(lines.isEmpty)
    }

    func testNotificationAndBatch() async throws {
        let socket = Socket(["tools/list": #"{"id":1,"result":{"tools":[]}}"#])
        let endpoint = endpoint("secret-token", socket)
        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"generic"}}}"#
        let hello = await endpoint.handle(try request("POST", "/mcp", initialize, headers: ["Authorization": "Bearer secret-token"]), peer: "100.64.0.1")
        XCTAssertEqual(hello.status, 200)
        XCTAssertNotNil(try json(hello)["result"])
        let discover = #"{"jsonrpc":"2.0","id":2,"method":"server/discover","params":{}}"#
        let found = await endpoint.handle(try request("POST", "/mcp/secret-token", discover), peer: "100.64.0.1")
        XCTAssertEqual(found.status, 200)
        XCTAssertNotNil(try json(found)["result"])
        let note = await endpoint.handle(try request("POST", "/mcp", #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, headers: ["Authorization": "Bearer secret-token"]), peer: "100.64.0.1")
        XCTAssertEqual(note.status, 202)
        XCTAssertTrue(note.body.isEmpty)
        let lines = await socket.lines
        XCTAssertTrue(lines.isEmpty)
        let batch = await endpoint.handle(try request("POST", "/mcp", #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#, headers: ["Authorization": "Bearer secret-token"]), peer: "100.64.0.1")
        XCTAssertEqual(batch.status, 400)
        XCTAssertEqual((try json(batch)["error"] as? [String: Any])?["code"] as? Int, -32600)
    }

    func testHashOnlyStorageAndRevoke() throws {
        let file = try scratch()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var store = AgentControlTailnetStore(enabled: true, port: 47480)
        let token = try XCTUnwrap(store.issue(AgentControlTailnet.grokBotClient))
        try store.save(file)
        let saved = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        XCTAssertFalse(saved.contains(token))
        XCTAssertFalse(saved.contains("\"token\""))
        XCTAssertTrue(saved.contains(AgentControlTailnet.tokenHash(token)))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        let loaded = AgentControlTailnetStore.load(file)
        XCTAssertFalse(loaded.loadFailed)
        XCTAssertEqual(loaded.client(matching: token), AgentControlTailnet.grokBotClient)
        XCTAssertNil(loaded.client(matching: "nope"))
        var revoked = loaded
        revoked.revoke(AgentControlTailnet.grokBotClient)
        try revoked.save(file)
        let after = AgentControlTailnetStore.load(file)
        XCTAssertNil(after.client(matching: token))
        XCTAssertNil(after.hashes[AgentControlTailnet.grokBotClient])
        XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(token))
    }

    func testLegacyTokensMigrateAndUnreadableFilesAreKept() throws {
        let file = try scratch()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let token = "never-issued"
        let legacy = file.deletingLastPathComponent().appendingPathComponent("legacy.json")
        let secret = "legacy-secret-token"
        try Data(#"{"enabled":true,"port":47480,"token":"\#(secret)"}"#.utf8).write(to: legacy)
        let migrated = AgentControlTailnetStore.load(legacy)
        XCTAssertEqual(migrated.client(matching: secret), AgentControlTailnet.grokBotClient)
        let migratedText = String(decoding: try Data(contentsOf: legacy), as: UTF8.self)
        XCTAssertFalse(migratedText.contains(secret))
        XCTAssertFalse(migratedText.contains("\"token\""))
        XCTAssertTrue(migratedText.contains(AgentControlTailnet.tokenHash(secret)))

        let broken = file.deletingLastPathComponent().appendingPathComponent("broken.json")
        let bytes = Data("not-json".utf8)
        try bytes.write(to: broken)
        let failed = AgentControlTailnetStore.load(broken)
        XCTAssertTrue(failed.loadFailed)
        XCTAssertNil(failed.client(matching: token))
        var copy = failed
        XCTAssertNil(copy.issue(AgentControlTailnet.grokBotClient))
        copy.revoke(AgentControlTailnet.grokBotClient)
        try copy.save(broken)
        XCTAssertEqual(try Data(contentsOf: broken), bytes)

        let locked = file.deletingLastPathComponent().appendingPathComponent("locked.json")
        let lockedBytes = Data("still-secret".utf8)
        try lockedBytes.write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: locked.path) }
        let unreadable = AgentControlTailnetStore.load(locked)
        XCTAssertTrue(unreadable.loadFailed)
        XCTAssertNil(unreadable.client(matching: "still-secret"))
        var lockedStore = unreadable
        XCTAssertNil(lockedStore.issue(AgentControlTailnet.grokBotClient))
        try lockedStore.save(locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: locked.path)
        XCTAssertEqual(try Data(contentsOf: locked), lockedBytes)
    }

    private var toolsList: String { #"{"jsonrpc":"2.0","id":7,"method":"tools/list","params":{}}"# }

    private func endpoint(_ token: String, _ socket: Socket) -> AgentControlHTTPEndpoint {
        AgentControlHTTPEndpoint(hashes: [AgentControlTailnet.grokBotClient: AgentControlTailnet.tokenHash(token)], version: "9.9") { try await socket.answer($0) }
    }

    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-tailnet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(AgentControlTailnetStore.fileName)
    }
}
