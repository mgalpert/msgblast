import XCTest
@testable import msgblastCore

final class AgentControlMCPTests: XCTestCase {
    /// Stands in for the app's socket: records each request line and answers from `replies` by method.
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

    private func forwarded(_ socket: Socket, _ index: Int = 0) async throws -> [String: Any] {
        let line = await socket.line(index)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
    }

    private static let tools = #"{"id":1,"result":{"tools":[{"name":"msgblast_status","title":"msgblast status","description":"Status.","access":"Read only","allowed":true,"inputSchema":{"type":"object"}},{"name":"msgblast_send","title":"Send","description":"Sends.","access":"Full access","allowed":false,"inputSchema":{"type":"object"}}]}}"#

    private func makeServer(_ replies: [String: String], client: String? = nil) -> (AgentControlMCPServer, Socket) {
        let socket = Socket(replies)
        return (AgentControlMCPServer(version: "9.9", client: client) { try await socket.answer($0) }, socket)
    }

    private func send(_ server: AgentControlMCPServer, _ line: String) async throws -> [String: Any] {
        let reply = await server.handle(Data(line.utf8))
        XCTAssertEqual(reply?.last, 0x0A)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(reply)) as? [String: Any])
    }

    private static func modern(_ client: String) -> String {
        #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"\#(client)","version":"1"}}"#
    }

    func testLegacyHandshakeNamesTheClientAndListsTools() async throws {
        let (server, socket) = makeServer(["tools/list": Self.tools])
        let hello = try await send(server, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"claude-code","title":"Claude Code"}}}"#)
        let info = try XCTUnwrap(hello["result"] as? [String: Any])
        XCTAssertEqual(info["protocolVersion"] as? String, "2025-06-18")
        XCTAssertEqual((info["serverInfo"] as? [String: Any])?["version"] as? String, "9.9")
        let initialized = await server.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        XCTAssertNil(initialized)
        let list = try await send(server, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = try XCTUnwrap((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.map { $0["name"] as? String }, ["msgblast_status", "msgblast_send"])
        XCTAssertEqual((tools[0]["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true)
        XCTAssertEqual((tools[1]["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, false)
        XCTAssertTrue((tools[1]["description"] as? String ?? "").contains("Needs Full access"))
        XCTAssertNil((list["result"] as? [String: Any])?["resultType"])
        let request = try await forwarded(socket)
        XCTAssertEqual(request["client"] as? String, "Claude Code")
        XCTAssertEqual(request["method"] as? String, "tools/list")
    }

    func testModernRequestsDiscoverAndCallWithPerRequestClient() async throws {
        let (server, socket) = makeServer(["msgblast_status": #"{"id":1,"result":{"version":"9.9"}}"#])
        let discover = try await send(server, #"{"jsonrpc":"2.0","id":"d","method":"server/discover","params":{\#(Self.modern("Codex"))}}"#)
        let found = try XCTUnwrap(discover["result"] as? [String: Any])
        XCTAssertEqual(found["supportedVersions"] as? [String], ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26"])
        XCTAssertEqual(found["resultType"] as? String, "complete")
        XCTAssertNotNil((found["_meta"] as? [String: Any])?["io.modelcontextprotocol/serverInfo"])
        let call = try await send(server, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"msgblast_status","arguments":{},\#(Self.modern("Codex"))}}"#)
        let result = try XCTUnwrap(call["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertEqual((result["structuredContent"] as? [String: Any])?["version"] as? String, "9.9")
        XCTAssertEqual((result["content"] as? [[String: Any]])?.first?["text"] as? String, #"{"version":"9.9"}"#)
        XCTAssertEqual(result["resultType"] as? String, "complete")
        let request = try await forwarded(socket)
        XCTAssertEqual(request["client"] as? String, "Codex")
        XCTAssertEqual(request["name"] as? String, "msgblast_status")
    }

    func testFixedClientOverridesWhatTheClientReports() async throws {
        let (server, socket) = makeServer(["tools/list": Self.tools], client: "Hermes")
        _ = try await send(server, #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{\#(Self.modern("generic"))}}"#)
        let request = try await forwarded(socket)
        XCTAssertEqual(request["client"] as? String, "Hermes")
    }

    func testProtocolErrors() async throws {
        let (server, _) = makeServer([:])
        let old = try await send(server, #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"1900-01-01"}}}"#)
        let error = try XCTUnwrap(old["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32022)
        XCTAssertEqual((error["data"] as? [String: Any])?["requested"] as? String, "1900-01-01")
        let unknown = try await send(server, #"{"jsonrpc":"2.0","id":2,"method":"resources/list"}"#)
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32601)
        let garbage = try await send(server, "{")
        XCTAssertEqual((garbage["error"] as? [String: Any])?["code"] as? Int, -32700)
        let ping = try await send(server, #"{"jsonrpc":"2.0","id":4,"method":"ping"}"#)
        XCTAssertNotNil(ping["result"] as? [String: Any])
    }

    func testRefusalsBecomeToolErrorsAndUnknownToolsBecomeProtocolErrors() async throws {
        let (server, _) = makeServer([
            "msgblast_status": #"{"id":1,"error":{"code":"notApproved","message":"msgblast has not approved Codex."}}"#,
            "msgblast_nope": #"{"id":1,"error":{"code":"unknownTool","message":"No msgblast tool is named msgblast_nope."}}"#
        ])
        let refused = try await send(server, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"msgblast_status"}}"#)
        let result = try XCTUnwrap(refused["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertEqual((result["content"] as? [[String: Any]])?.first?["text"] as? String, "msgblast has not approved Codex.")
        let unknown = try await send(server, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"msgblast_nope"}}"#)
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    func testUnreachableAppIsReportedPlainly() async throws {
        let (server, _) = makeServer([:])
        let list = try await send(server, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        XCTAssertEqual((list["error"] as? [String: Any])?["code"] as? Int, -32002)
        let call = try await send(server, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"msgblast_status"}}"#)
        let result = try XCTUnwrap(call["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertEqual((result["content"] as? [[String: Any]])?.first?["text"] as? String, AgentControlMCPServer.unavailable)
    }
}
