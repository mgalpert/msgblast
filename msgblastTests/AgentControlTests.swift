import XCTest
@testable import msgblastCore

@MainActor final class AgentControlTests: XCTestCase {
    private final class Host: AgentControlHost {
        var comparisons: [Comparison] = []
        func controlStatus() -> AgentControlStatus { AgentControlStatus(version: "1.0", permissions: ["contacts": true], busyAgents: []) }
        func controlAgents() -> [AgentControlAgent] {
            [AgentControlAgent(id: AgentGridID.web(.chatgptApp).id, name: "ChatGPT", kind: "app", visible: true, selected: true, busy: false),
             AgentControlAgent(id: "messages:hidden", name: "Hidden", kind: "messages", visible: false, selected: false, busy: false)]
        }
        func controlComparisons() -> [Comparison] { comparisons }
        func controlTranscript(_ comparison: Comparison) -> [AgentControlTurn] {
            [AgentControlTurn(agent: "Fo", outgoing: false, text: "Try the coast.", date: comparison.created)]
        }
    }

    private func comparison(_ prompt: String, created: Date) -> Comparison {
        var result = Comparison(prompt: prompt, members: [Member(agentID: UUID(), name: "Fo", chat: Chat(id: "fo", handle: "fo", lastActivity: 0))])
        result.created = created
        result.setWebAgents([WebAgentID(provider: .chatgptApp)])
        return result
    }

    private func call(_ name: String, _ arguments: String = "", access: AgentControlAccess = .readOnly, host: Host) throws -> Any {
        let data = try AgentControl.call(name, arguments: Data(arguments.utf8), access: access, host: host)
        return try JSONSerialization.jsonObject(with: data)
    }

    func testCatalogHasUniqueNamesAndValidSchemas() throws {
        XCTAssertEqual(Set(AgentControl.tools.map(\.name)).count, AgentControl.tools.count)
        for tool in AgentControl.tools {
            let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(tool.inputSchema.utf8)) as? [String: Any], tool.name)
            XCTAssertEqual(schema["type"] as? String, "object", tool.name)
        }
    }

    func testUnknownToolAndBadArgumentsAreRefused() {
        let host = Host()
        XCTAssertThrowsError(try call("msgblast_nope", host: host)) { XCTAssertEqual($0 as? AgentControlError, .unknownTool("msgblast_nope")) }
        XCTAssertThrowsError(try call("msgblast_comparisons_list", #"{"limit":0}"#, host: host))
        XCTAssertThrowsError(try call("msgblast_comparisons_list", #"{"limit":"ten"}"#, host: host)) {
            guard case .invalidArguments = $0 as? AgentControlError else { return XCTFail("\($0)") }
        }
    }

    func testAccessLevelsAreOrdered() {
        XCTAssertLessThan(AgentControlAccess.readOnly, .sendToAgents)
        XCTAssertLessThan(AgentControlAccess.sendToAgents, .full)
    }

    func testAgentsListHidesHiddenAgentsUnlessAsked() throws {
        let host = Host()
        XCTAssertEqual((try call("msgblast_agents_list", host: host) as? [[String: Any]])?.count, 1)
        XCTAssertEqual((try call("msgblast_agents_list", #"{"includeHidden":true}"#, host: host) as? [[String: Any]])?.count, 2)
    }

    func testComparisonsListIsNewestFirstFilteredAndLimited() throws {
        let host = Host()
        host.comparisons = [comparison("Plan a weekend in Big Sur", created: Date(timeIntervalSince1970: 1)),
                            comparison("Best espresso machine", created: Date(timeIntervalSince1970: 3)),
                            comparison("Weekend in Tahoe", created: Date(timeIntervalSince1970: 2))]
        let all = try XCTUnwrap(try call("msgblast_comparisons_list", host: host) as? [[String: Any]])
        XCTAssertEqual(all.map { $0["title"] as? String }, ["Best espresso machine", "Weekend in Tahoe", "Plan a weekend in Big Sur"])
        XCTAssertEqual(all.first?["agents"] as? [String], ["Fo", "ChatGPT"])
        let weekend = try XCTUnwrap(try call("msgblast_comparisons_list", #"{"query":"WEEKEND","limit":1}"#, host: host) as? [[String: Any]])
        XCTAssertEqual(weekend.map { $0["title"] as? String }, ["Weekend in Tahoe"])
    }

    func testComparisonReadReturnsSubmissionsAndTurns() throws {
        let host = Host()
        let saved = comparison("Plan a weekend", created: Date(timeIntervalSince1970: 0))
        host.comparisons = [saved]
        let read = try XCTUnwrap(try call("msgblast_comparison_read", #"{"id":"\#(saved.id.uuidString.lowercased())"}"#, host: host) as? [String: Any])
        XCTAssertEqual(read["prompt"] as? String, "Plan a weekend")
        XCTAssertEqual(read["submissions"] as? [String: String], ["Fo": "ready"])
        XCTAssertEqual((read["turns"] as? [[String: Any]])?.first?["text"] as? String, "Try the coast.")
        XCTAssertThrowsError(try call("msgblast_comparison_read", #"{"id":"missing"}"#, host: host)) {
            XCTAssertEqual($0 as? AgentControlError, .notFound("missing"))
        }
    }
}
