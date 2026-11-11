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
        let tools = #"{"id":1,"result":{"tools":[{"name":"msgblast_status","title":"msgblast status","description":"Status.","access":"Read only","allowed":true,"inputSchema":{"type":"object"}},{"name":"msgblast_comparisons_list","title":"List comparisons","description":"Saved.","access":"Read only","allowed":true,"inputSchema":{"type":"object","properties":{}}},{"name":"msgblast_comparison_read","title":"Read a comparison","description":"Read.","access":"Read only","allowed":true,"inputSchema":{"type":"object"}},{"name":"msgblast_blast_wait","title":"Wait for replies","description":"Wait.","access":"Read only","allowed":true,"inputSchema":{"type":"object"}}]}}"#
        let server = AgentControlMCPServer(version: "9.9", client: "Codex") { _ in Data((tools + "\n").utf8) }
        let list = try await send(server, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let listed = try XCTUnwrap((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let linked = Set(["msgblast_comparisons_list", "msgblast_comparison_read", "msgblast_blast_wait"])
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
        }
    }
}
