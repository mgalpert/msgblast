import XCTest
@testable import msgblastCore

final class AgentControlMCPAppTests: XCTestCase {
    private func offline() -> AgentControlMCPServer {
        AgentControlMCPServer(version: "9.9", client: nil) { _ in throw CocoaError(.fileNoSuchFile) }
    }

    private func send(_ server: AgentControlMCPServer, _ line: String) async throws -> [String: Any] {
        let reply = await server.handle(Data(line.utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(reply)) as? [String: Any])
    }

    private func uiExtension(_ capabilities: [String: Any]?, _ key: String) -> [String: Any]? {
        (capabilities?[key] as? [String: Any])?[AgentControlMCPApp.extensionID] as? [String: Any]
    }

    private func assertResourceMeta(_ meta: [String: Any]?, file: StaticString = #filePath, line: UInt = #line) {
        let ui = meta?["ui"] as? [String: Any]
        XCTAssertEqual(ui?["prefersBorder"] as? Bool, true, file: file, line: line)
        XCTAssertNil(ui?["domain"], file: file, line: line)
        XCTAssertNil(ui?["csp"], file: file, line: line)
        let modes = (meta?["openai/ui"] as? [String: Any])?["availableDisplayModes"] as? [String]
        XCTAssertEqual(modes, ["inline", "fullscreen"], file: file, line: line)
    }

    func testInitializeAndDiscoverAdvertiseTheComparisonView() async throws {
        let server = offline()
        let hello = try await send(server, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"Codex"}}}"#)
        let caps = (hello["result"] as? [String: Any])?["capabilities"] as? [String: Any]
        XCTAssertEqual(uiExtension(caps, "extensions")?["mimeTypes"] as? [String], [AgentControlMCPApp.mimeType])
        XCTAssertEqual(uiExtension(caps, "experimental")?["mimeTypes"] as? [String], [AgentControlMCPApp.mimeType])
        XCTAssertNotNil(caps?["resources"] as? [String: Any])
        let discover = try await send(server, #"{"jsonrpc":"2.0","id":2,"method":"server/discover","params":{}}"#)
        let found = (discover["result"] as? [String: Any])?["capabilities"] as? [String: Any]
        XCTAssertEqual(uiExtension(found, "extensions")?["mimeTypes"] as? [String], [AgentControlMCPApp.mimeType])
        XCTAssertNil(found?["experimental"])
        XCTAssertNotNil(found?["resources"] as? [String: Any])
        XCTAssertEqual(Self.mentionsTool(caps, "extensions"), "msgblast_mentions")
        XCTAssertEqual(Self.mentionsTool(caps, "experimental"), "msgblast_mentions")
        XCTAssertEqual(Self.mentionsTool(found, "extensions"), "msgblast_mentions")
    }

    private static func mentionsTool(_ capabilities: [String: Any]?, _ key: String) -> String? {
        ((capabilities?[key] as? [String: Any])?["openai/mentions"] as? [String: Any])?["searchTool"] as? String
    }

    func testResourcesListAndReadTheViewWithoutTheApp() async throws {
        let server = offline()
        let list = try await send(server, #"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#)
        let resources = try XCTUnwrap((list["result"] as? [String: Any])?["resources"] as? [[String: Any]])
        XCTAssertEqual(resources.map { $0["uri"] as? String }, [AgentControlMCPApp.viewURI])
        XCTAssertEqual(resources.first?["name"] as? String, "msgblast comparison")
        XCTAssertEqual(resources.first?["mimeType"] as? String, AgentControlMCPApp.mimeType)
        assertResourceMeta(resources.first?["_meta"] as? [String: Any])
        let read = try await send(server, #"{"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"\#(AgentControlMCPApp.viewURI)"}}"#)
        let content = try XCTUnwrap(((read["result"] as? [String: Any])?["contents"] as? [[String: Any]])?.first)
        XCTAssertEqual(content["mimeType"] as? String, "text/html;profile=mcp-app")
        let html = try XCTUnwrap(content["text"] as? String)
        XCTAssertTrue(html.lowercased().hasPrefix("<!doctype html>"))
        XCTAssertTrue(html.contains("ui/initialize"))
        XCTAssertFalse(html.contains("http://"))
        XCTAssertFalse(html.contains("https://"))
        assertResourceMeta(content["_meta"] as? [String: Any])
        let missing = try await send(server, #"{"jsonrpc":"2.0","id":3,"method":"resources/read","params":{"uri":"ui://nope"}}"#)
        let error = try XCTUnwrap(missing["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32002)
        XCTAssertEqual(error["message"] as? String, "No msgblast resource at ui://nope.")
    }

    func testToolsPointAtTheComparisonView() async throws {
        await MainActor.run {
            let catalog = AgentControl.tools.first { $0.name == "msgblast_comparisons_list" }
            XCTAssertLessThanOrEqual(catalog?.title.count ?? 99, 60)
            XCTAssertFalse(catalog?.title.contains("Claude") == true)
            XCTAssertFalse(catalog?.title.contains("Anthropic") == true)
            XCTAssertFalse(catalog?.name.contains("__") == true)
            XCTAssertFalse(catalog?.name.contains(".") == true)
            XCTAssertFalse(catalog?.inputSchema.contains("\"required\"") == true)
        }
        let tools = #"{"id":1,"result":{"tools":[{"name":"msgblast_status","title":"msgblast status","description":"Status.","access":"Read only","allowed":true,"inputSchema":{"type":"object"}},{"name":"msgblast_comparisons_list","title":"List comparisons","description":"Saved.","access":"Read only","allowed":true,"inputSchema":{"type":"object","properties":{}}},{"name":"msgblast_comparison_read","title":"Read a comparison","description":"Read.","access":"Read only","allowed":true,"inputSchema":{"type":"object"}},{"name":"msgblast_blast_wait","title":"Wait for replies","description":"Wait.","access":"Read only","allowed":true,"inputSchema":{"type":"object"}},{"name":"msgblast_mentions","title":"Mention comparisons","description":"Search.","access":"Read only","allowed":true,"inputSchema":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}},{"name":"msgblast_blast_start","title":"Start a blast","description":"Sends.","access":"Full access","allowed":false,"inputSchema":{"type":"object"}}]}}"#
        let server = AgentControlMCPServer(version: "9.9", client: "Codex") { _ in Data((tools + "\n").utf8) }
        let list = try await send(server, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let listed = try XCTUnwrap((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let linked = Set(["msgblast_comparisons_list", "msgblast_comparison_read", "msgblast_blast_wait"])
        XCTAssertTrue(listed.contains { $0["name"] as? String == "msgblast_blast_start" })
        for tool in listed {
            let name = tool["name"] as? String ?? ""
            let meta = tool["_meta"] as? [String: Any]
            let uri = (meta?["ui"] as? [String: Any])?["resourceUri"] as? String
            if linked.contains(name) { XCTAssertEqual(uri, AgentControlMCPApp.viewURI, name) } else { XCTAssertNil(uri, name) }
            let entries = (meta?["openai/ui"] as? [String: Any])?["entrypoints"] as? [[String: Any]]
            if name == "msgblast_comparisons_list" {
                XCTAssertEqual(entries?.map { $0["type"] as? String }, ["global"])
                XCTAssertLessThanOrEqual((tool["title"] as? String ?? "").count, 60)
            } else {
                XCTAssertNil(entries, name)
            }
            let visibility = (meta?["ui"] as? [String: Any])?["visibility"] as? [String]
            if name == "msgblast_mentions" {
                XCTAssertEqual(visibility, ["model", "app"])
                XCTAssertEqual((tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true)
            } else if (tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == false {
                XCTAssertEqual(visibility, ["model"], name)
            } else {
                XCTAssertNil(visibility, name)
            }
        }
    }

    func testMentionsAndComparisonResources() async throws {
        let id = "00000000-0000-4000-8000-000000000001"
        let found = "00000000-0000-4000-8000-000000000002"
        let capture = Capture()
        let server = AgentControlMCPServer(version: "9.9", client: "Codex") { line in
            await capture.add(line)
            let request = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
            let name = request["name"] as? String
            if name == "msgblast_mentions" {
                return Data(("{\"id\":1,\"result\":{\"items\":[{\"type\":\"resource_link\",\"uri\":\"msgblast://comparison/\(id)\",\"name\":\"Hi\",\"description\":\"1970-01-01T00:00:00Z · 1 agent\",\"mimeType\":\"application/json\"}]}}\n").utf8)
            }
            if name == "msgblast_comparison_read" {
                let asked = (request["arguments"] as? [String: Any])?["id"] as? String ?? ""
                if asked == id { return Data(("{\"id\":1,\"error\":{\"code\":\"notFound\",\"message\":\"Nothing in msgblast matches \(id).\"}}\n").utf8) }
                return Data(("{\"id\":1,\"result\":{\"prompt\":\"Hi\",\"id\":\"\(asked)\"}}\n").utf8)
            }
            throw CocoaError(.fileNoSuchFile)
        }
        let mentioned = try await send(server, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"msgblast_mentions","arguments":{"query":""}}}"#)
        let items = ((mentioned["result"] as? [String: Any])?["structuredContent"] as? [String: Any])?["items"] as? [[String: Any]]
        XCTAssertEqual(items?.first?["type"] as? String, "resource_link")
        XCTAssertEqual(items?.first?["uri"] as? String, "msgblast://comparison/\(id)")
        let read = try await send(server, #"{"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"msgblast://comparison/\#(found)"}}"#)
        let forwardedLine = await capture.line(1)
        let forwarded = try XCTUnwrap(JSONSerialization.jsonObject(with: forwardedLine) as? [String: Any])
        XCTAssertEqual(forwarded["method"] as? String, "tools/call")
        XCTAssertEqual(forwarded["name"] as? String, "msgblast_comparison_read")
        XCTAssertEqual((forwarded["arguments"] as? [String: Any])?["id"] as? String, found)
        let content = ((read["result"] as? [String: Any])?["contents"] as? [[String: Any]])?.first
        XCTAssertEqual(content?["mimeType"] as? String, "application/json")
        XCTAssertEqual(content?["uri"] as? String, "msgblast://comparison/\(found)")
        XCTAssertTrue((content?["text"] as? String ?? "").contains("\"prompt\":\"Hi\""))
        let missing = try await send(server, #"{"jsonrpc":"2.0","id":3,"method":"resources/read","params":{"uri":"msgblast://comparison/\#(id)"}}"#)
        let error = try XCTUnwrap(missing["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32002)
        XCTAssertEqual(error["message"] as? String, "No msgblast resource at msgblast://comparison/\(id).")
        let offline = try await send(self.offline(), #"{"jsonrpc":"2.0","id":4,"method":"resources/read","params":{"uri":"msgblast://comparison/\#(id)"}}"#)
        XCTAssertEqual((offline["error"] as? [String: Any])?["code"] as? Int, -32002)
        XCTAssertEqual((offline["error"] as? [String: Any])?["message"] as? String, AgentControlMCPServer.unavailable)
        let list = try await send(self.offline(), #"{"jsonrpc":"2.0","id":5,"method":"resources/list"}"#)
        XCTAssertEqual(((list["result"] as? [String: Any])?["resources"] as? [[String: Any]])?.map { $0["uri"] as? String }, [AgentControlMCPApp.viewURI])
    }

    private actor Capture {
        private var lines: [Data] = []
        func add(_ line: Data) { lines.append(line) }
        func line(_ index: Int) -> Data { lines[index] }
    }
}
