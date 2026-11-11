import XCTest
@testable import msgblastCore

@MainActor final class AgentControlTests: XCTestCase {
    private final class Host: AgentControlHost {
        var comparisons: [Comparison] = []
        let controlEvents = AgentControlEvents()
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

    private func call(_ name: String, _ arguments: String = "", host: Host) async throws -> Any {
        let data = try await AgentControl.call(name, arguments: Data(arguments.utf8), access: .readOnly, host: host)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func refusal(_ name: String, _ arguments: String = "", host: Host) async -> AgentControlError? {
        do { _ = try await call(name, arguments, host: host); return nil } catch { return error as? AgentControlError }
    }

    func testCatalogHasUniqueNamesAndValidSchemas() throws {
        XCTAssertEqual(Set(AgentControl.tools.map(\.name)).count, AgentControl.tools.count)
        for tool in AgentControl.tools {
            let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(tool.inputSchema.utf8)) as? [String: Any], tool.name)
            XCTAssertEqual(schema["type"] as? String, "object", tool.name)
        }
    }

    func testUnknownToolAndBadArgumentsAreRefused() async {
        let host = Host()
        let unknown = await refusal("msgblast_nope", host: host)
        XCTAssertEqual(unknown, .unknownTool("msgblast_nope"))
        let zero = await refusal("msgblast_comparisons_list", #"{"limit":0}"#, host: host)
        let text = await refusal("msgblast_comparisons_list", #"{"limit":"ten"}"#, host: host)
        for error in [zero, text] {
            guard case .invalidArguments = error else { return XCTFail("\(String(describing: error))") }
        }
    }

    func testAccessLevelsAreOrdered() {
        XCTAssertEqual(AgentControlAccess.allCases.map(\.label), ["Read only", "Full access"])
        XCTAssertLessThan(AgentControlAccess.readOnly, .full)
        XCTAssertNil(try? JSONDecoder().decode([String: AgentControlAccess].self, from: Data(#"{"Codex":1}"#.utf8)))
    }

    func testAgentsListHidesHiddenAgentsUnlessAsked() async throws {
        let host = Host()
        let shown = try await call("msgblast_agents_list", host: host) as? [[String: Any]]
        let all = try await call("msgblast_agents_list", #"{"includeHidden":true}"#, host: host) as? [[String: Any]]
        XCTAssertEqual(shown?.count, 1)
        XCTAssertEqual(all?.count, 2)
    }

    func testComparisonsListIsNewestFirstFilteredAndLimited() async throws {
        let host = Host()
        host.comparisons = [comparison("Plan a weekend in Big Sur", created: Date(timeIntervalSince1970: 1)),
                            comparison("Best espresso machine", created: Date(timeIntervalSince1970: 3)),
                            comparison("Weekend in Tahoe", created: Date(timeIntervalSince1970: 2))]
        let allReply = try await call("msgblast_comparisons_list", host: host)
        let all = try XCTUnwrap(allReply as? [[String: Any]])
        XCTAssertEqual(all.map { $0["title"] as? String }, ["Best espresso machine", "Weekend in Tahoe", "Plan a weekend in Big Sur"])
        XCTAssertEqual(all.first?["agents"] as? [String], ["Fo", "ChatGPT"])
        let weekendReply = try await call("msgblast_comparisons_list", #"{"query":"WEEKEND","limit":1}"#, host: host)
        let weekend = try XCTUnwrap(weekendReply as? [[String: Any]])
        XCTAssertEqual(weekend.map { $0["title"] as? String }, ["Weekend in Tahoe"])
    }

    func testComparisonReadReturnsSubmissionsAndTurns() async throws {
        let host = Host()
        let saved = comparison("Plan a weekend", created: Date(timeIntervalSince1970: 0))
        host.comparisons = [saved]
        let readReply = try await call("msgblast_comparison_read", #"{"id":"\#(saved.id.uuidString.lowercased())"}"#, host: host)
        let read = try XCTUnwrap(readReply as? [String: Any])
        XCTAssertEqual(read["prompt"] as? String, "Plan a weekend")
        XCTAssertEqual(read["submissions"] as? [String: String], ["Fo": "ready"])
        XCTAssertEqual((read["turns"] as? [[String: Any]])?.first?["text"] as? String, "Try the coast.")
        let missing = await refusal("msgblast_comparison_read", #"{"id":"missing"}"#, host: host)
        XCTAssertEqual(missing, .notFound("missing"))
    }

    func testWaitReturnsEarlierEventsAtOnceAndFiltersByComparison() async throws {
        let host = Host()
        let blast = UUID()
        host.controlEvents.publish(.replyArrived, comparisonID: blast, agent: "Fo")
        host.controlEvents.publish(.agentReady, comparisonID: UUID(), agent: "ChatGPT")
        let resultReply = try await call("msgblast_blast_wait", #"{"after":0,"comparisonId":"\#(blast.uuidString)","timeoutSeconds":0}"#, host: host)
        let result = try XCTUnwrap(resultReply as? [String: Any])
        XCTAssertEqual((result["events"] as? [[String: Any]])?.map { $0["kind"] as? String }, ["replyArrived"])
        XCTAssertEqual(result["next"] as? Int, 1)
    }

    func testWaitWakesOnANewEventAndTimesOutEmpty() async throws {
        let host = Host()
        Task { @MainActor in
            try await Task.sleep(for: .milliseconds(50))
            host.controlEvents.publish(.sendResult, agent: "Fo", detail: "submitted")
        }
        let wokeReply = try await call("msgblast_blast_wait", #"{"timeoutSeconds":5}"#, host: host)
        let woke = try XCTUnwrap(wokeReply as? [String: Any])
        XCTAssertEqual((woke["events"] as? [[String: Any]])?.first?["detail"] as? String, "submitted")
        let emptyReply = try await call("msgblast_blast_wait", #"{"after":1,"timeoutSeconds":0}"#, host: host)
        let empty = try XCTUnwrap(emptyReply as? [String: Any])
        XCTAssertEqual((empty["events"] as? [Any])?.count, 0)
        XCTAssertEqual(empty["next"] as? Int, 1)
    }

    func testWaitReadsFromTheStartWhenTheCursorIsFromAnEarlierRun() async throws {
        let host = Host()
        host.controlEvents.publish(.replyArrived, agent: "Fo")
        let staleReply = try await call("msgblast_blast_wait", #"{"after":99,"timeoutSeconds":0}"#, host: host)
        let stale = try XCTUnwrap(staleReply as? [String: Any])
        XCTAssertEqual((stale["events"] as? [[String: Any]])?.map { $0["agent"] as? String }, ["Fo"])
        XCTAssertEqual(stale["next"] as? Int, 1)
        let negative = await refusal("msgblast_blast_wait", #"{"after":-1,"timeoutSeconds":0}"#, host: host)
        XCTAssertEqual(negative, .invalidArguments("after must be 0 or more"))
    }

    func testTooManyWaitsEndTheOldestEarly() async {
        let feed = AgentControlEvents()
        let first = Task { @MainActor in await feed.wait(after: 0, comparisonID: nil, timeout: .seconds(30)) }
        while feed.waiterCount < 1 { await Task.yield() }
        var later: [Task<[AgentControlEvent], Never>] = []
        for _ in 0..<AgentControlEvents.maximumWaiters {
            later.append(Task { @MainActor in await feed.wait(after: 0, comparisonID: nil, timeout: .seconds(30)) })
        }
        let early = await first.value
        XCTAssertEqual(early, [])
        XCTAssertEqual(feed.waiterCount, AgentControlEvents.maximumWaiters)
        feed.publish(.agentReady)
        for task in later { let events = await task.value; XCTAssertEqual(events.count, 1) }
        XCTAssertEqual(feed.waiterCount, 0)
    }

    func testFeedKeepsOnlyRecentEvents() {
        let feed = AgentControlEvents()
        for _ in 0..<(AgentControlEvents.retained + 5) { feed.publish(.agentBusy) }
        XCTAssertEqual(feed.events.count, AgentControlEvents.retained)
        XCTAssertEqual(feed.events.first?.seq, 6)
        XCTAssertEqual(feed.cursor, AgentControlEvents.retained + 5)
    }
}
