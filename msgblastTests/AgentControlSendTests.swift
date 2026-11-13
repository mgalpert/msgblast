import XCTest
@testable import msgblastCore
import msgblastRemoteProtocol

@MainActor final class AgentControlSendTests: XCTestCase {
    /// Records each command and answers from `answer`, keeping results by command id like the executor's ledger.
    private final class Host: AgentControlHost {
        let controlEvents = AgentControlEvents()
        var commands: [RemoteCommand] = []
        var ledger: [UUID: RemoteCommandResult] = [:]
        var answer: (RemoteCommand) -> RemoteCommandResult = { .init(clientCommandID: $0.clientCommandID, outcome: .applied) }
        func controlStatus() -> AgentControlStatus { AgentControlStatus(version: "1.0", permissions: [:], busyAgents: []) }
        func controlAgents() -> [AgentControlAgent] {
            [AgentControlAgent(id: "web:chatgpt", name: "ChatGPT", kind: "app", visible: true, selected: true, busy: false),
             AgentControlAgent(id: "messages:\(Self.fo.uuidString)", name: "Fo", kind: "messages", visible: true, selected: true, busy: false)]
        }
        func controlComparisons() -> [Comparison] { [] }
        func controlTranscript(_ comparison: Comparison) -> [AgentControlTurn] { [] }
        var clients: [String] = []
        func controlSend(_ command: RemoteCommand, client: String) async -> RemoteCommandResult {
            if var stored = ledger[command.clientCommandID] { stored.replayed = true; return stored }
            commands.append(command)
            clients.append(client)
            let result = answer(command)
            ledger[command.clientCommandID] = result
            return result
        }
        func controlSendStatus(_ id: UUID) -> RemoteCommandResult {
            if var stored = ledger[id] { stored.replayed = true; return stored }
            return .rejected(id, .unknownCommand, "No record")
        }
        static let fo = UUID()
    }

    override func setUp() async throws { AgentControl.sendLimit = AgentControlSendLimit() }

    private func call(_ name: String, _ arguments: String, host: Host, client: String = "Codex", access: AgentControlAccess = .full) async throws -> [String: Any] {
        let data = try await AgentControl.call(name, arguments: Data(arguments.utf8), access: access, host: host, client: client)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func refusal(_ name: String, _ arguments: String, host: Host, access: AgentControlAccess = .full) async -> AgentControlError? {
        do { _ = try await call(name, arguments, host: host, access: access); return nil } catch { return error as? AgentControlError }
    }

    func testSendToolsNeedFullAccessAndStatusIsReadOnly() async {
        let tools = Dictionary(uniqueKeysWithValues: AgentControl.tools.map { ($0.name, $0.access) })
        for name in AgentControlSend.names { XCTAssertEqual(tools[name], .full, name) }
        XCTAssertEqual(tools["msgblast_request_status"], .readOnly)
        let host = Host()
        let refused = await refusal("msgblast_blast_start", #"{"text":"Hi","agents":["web:chatgpt"]}"#, host: host, access: .readOnly)
        XCTAssertEqual(refused, .needsAccess(.full))
        XCTAssertEqual(host.commands, [])
    }

    func testStartBecomesOneExecutorCommandWithAgentIDsTranslated() async throws {
        let host = Host()
        let comparison = UUID()
        host.answer = { .init(clientCommandID: $0.clientCommandID, outcome: .applied, conversationID: comparison, agentStatuses: ["chatgpt": .submitted, "messages:\(Host.fo.uuidString)": .sending]) }
        let reply = try await call("msgblast_blast_start", #"{"text":"Where to eat?","agents":["web:chatgpt","messages:\#(Host.fo.uuidString)"],"requestId":"trip-1"}"#, host: host)
        XCTAssertEqual(host.commands.count, 1)
        XCTAssertEqual(host.commands.first?.action, .createConversation(text: "Where to eat?", agentIDs: ["chatgpt", "messages:\(Host.fo.uuidString)"], attachmentIDs: []))
        XCTAssertEqual(host.commands.first?.clientCommandID, AgentControlSend.commandID(client: "Codex", requestID: "trip-1"))
        XCTAssertEqual(host.clients, ["Codex"])
        XCTAssertEqual(reply["outcome"] as? String, "done")
        XCTAssertEqual(reply["requestId"] as? String, "trip-1")
        XCTAssertEqual(reply["comparisonId"] as? String, comparison.uuidString)
        let agents = try XCTUnwrap(reply["agents"] as? [[String: Any]])
        XCTAssertEqual(agents.map { $0["id"] as? String }, ["web:chatgpt", "messages:\(Host.fo.uuidString)"])
        XCTAssertEqual(agents.map { $0["name"] as? String }, ["ChatGPT", "Fo"])
        XCTAssertEqual(agents.map { $0["status"] as? String }, ["submitted", "sending"])
    }

    func testTheSameRequestIdNeverSendsTwiceAndIsKeptApartPerAgent() async throws {
        let host = Host()
        let arguments = #"{"text":"Hi","agents":["web:chatgpt"],"requestId":"same"}"#
        _ = try await call("msgblast_blast_start", arguments, host: host)
        let again = try await call("msgblast_blast_start", arguments, host: host)
        XCTAssertEqual(host.commands.count, 1)
        XCTAssertEqual(again["replayed"] as? Bool, true)
        _ = try await call("msgblast_blast_start", arguments, host: host, client: "Claude Code")
        XCTAssertEqual(host.commands.count, 2, "another agent's requestId is its own")
        let status = try await call("msgblast_request_status", #"{"requestId":"same"}"#, host: host, access: .readOnly)
        XCTAssertEqual(status["outcome"] as? String, "done")
        let unknown = try await call("msgblast_request_status", #"{"requestId":"never"}"#, host: host, access: .readOnly)
        XCTAssertEqual(unknown["outcome"] as? String, "unknown")
    }

    func testFollowUpPrivateMessageAndEndBuildTheirCommands() async throws {
        let host = Host()
        let id = UUID()
        _ = try await call("msgblast_blast_follow_up", #"{"comparisonId":"\#(id.uuidString)","text":"And dessert?"}"#, host: host)
        _ = try await call("msgblast_agent_message", #"{"agent":"web-instance:chatgpt:\#(id.uuidString)","text":"Just you"}"#, host: host)
        _ = try await call("msgblast_comparison_end", #"{"comparisonId":"\#(id.uuidString)"}"#, host: host)
        XCTAssertEqual(host.commands.map(\.action), [
            .sendShared(conversationID: id, text: "And dessert?", agentIDs: [], attachmentIDs: []),
            .sendPrivate(conversationID: nil, agentID: "chatgpt:\(id.uuidString)", text: "Just you", attachmentIDs: []),
            .endConversation(conversationID: id)
        ])
        XCTAssertEqual(Set(host.commands.map(\.clientCommandID)).count, 3, "calls without a requestId get their own")
    }

    func testASendResultCarriesTheWaitCursorFromBeforeTheSend() async throws {
        let host = Host()
        let comparison = UUID()
        host.controlEvents.publish(.agentReady, agent: "ChatGPT")
        host.controlEvents.publish(.agentBusy, agent: "ChatGPT")
        // The reply lands while the send is still running, before the agent can start a wait.
        host.answer = { [unowned host] command in
            host.controlEvents.publish(.replyArrived, comparisonID: comparison, agent: "ChatGPT")
            return .init(clientCommandID: command.clientCommandID, outcome: .applied, conversationID: comparison)
        }
        let reply = try await call("msgblast_blast_start", #"{"text":"Hi","agents":["web:chatgpt"],"requestId":"quick"}"#, host: host)
        XCTAssertEqual(reply["after"] as? Int, 2)
        let wait = try await call("msgblast_blast_wait", #"{"after":2,"comparisonId":"\#(comparison.uuidString)","timeoutSeconds":0}"#,
                                  host: host, access: .readOnly)
        let events = try XCTUnwrap(wait["events"] as? [[String: Any]])
        XCTAssertEqual(events.map { $0["kind"] as? String }, ["replyArrived"])
        let again = try await call("msgblast_blast_start", #"{"text":"Hi","agents":["web:chatgpt"],"requestId":"quick"}"#, host: host)
        XCTAssertEqual(again["replayed"] as? Bool, true)
        XCTAssertNil(again["after"], "a replay's replies may be older than a cursor taken now")
        let status = try await call("msgblast_request_status", #"{"requestId":"quick"}"#, host: host, access: .readOnly)
        XCTAssertNil(status["after"], "a stored result has no cursor of its own")
    }

    func testBadArgumentsAreRefusedBeforeAnythingRuns() async {
        let host = Host()
        let cases: [(String, String, String)] = [
            ("msgblast_blast_start", #"{"text":"Hi","agents":["featured:fo"]}"#, "featured:fo is not an agent msgblast can send to. Use ids from msgblast_agents_list."),
            ("msgblast_blast_start", #"{"text":"  ","agents":["web:chatgpt"]}"#, "text is required"),
            ("msgblast_blast_start", #"{"text":"Hi","agents":[]}"#, "agents is required"),
            ("msgblast_blast_follow_up", #"{"comparisonId":"nope","text":"Hi"}"#, "comparisonId is not a comparison id"),
            ("msgblast_comparison_end", #"{}"#, "comparisonId is required"),
            ("msgblast_agent_message", #"{"text":"Hi"}"#, "agent is required"),
            ("msgblast_blast_start", #"{"text":"Hi","agents":["web:chatgpt"],"requestId":""}"#, "requestId must be 1 to 200 characters")
        ]
        for (name, arguments, message) in cases {
            let error = await refusal(name, arguments, host: host)
            XCTAssertEqual(error, .invalidArguments(message), arguments)
        }
        XCTAssertEqual(host.commands, [])
    }

    func testARefusalIsAnErrorThatSaysWhyForEachAgent() async {
        let host = Host()
        host.answer = { RemoteCommandResult(clientCommandID: $0.clientCommandID, outcome: .rejected, code: .agentUnavailable, message: "Not every agent was ready",
                                            agentReasons: ["chatgpt": "Open ChatGPT on your Mac and sign in"]) }
        let named = await refusal("msgblast_blast_start", #"{"text":"Hi","agents":["web:chatgpt"],"requestId":"r1"}"#, host: host)
        XCTAssertEqual(named, .refused("Not every agent was ready. ChatGPT: Open ChatGPT on your Mac and sign in. Nothing was sent (agentUnavailable). "
                                       + "A repeat with the same requestId gets this same answer, so use a new requestId to try again."))
        // Without a requestId the caller has nothing to repeat, so it isn't told how.
        let unnamed = await refusal("msgblast_blast_start", #"{"text":"Hi","agents":["web:chatgpt"]}"#, host: host)
        XCTAssertEqual(unnamed, .refused("Not every agent was ready. ChatGPT: Open ChatGPT on your Mac and sign in. Nothing was sent (agentUnavailable)."))
    }

    func testAStopRefusalSaysTheSameCallCanGoOutOnceSendsAreAllowed() async {
        let host = Host()
        host.answer = { .rejected($0.clientCommandID, .agentSendsStopped, "Agent sends are stopped in msgblast. The person can allow them again in msgblast") }
        let error = await refusal("msgblast_blast_start", #"{"text":"Hi","agents":["web:chatgpt"],"requestId":"r1"}"#, host: host)
        XCTAssertEqual(error, .refused("Agent sends are stopped in msgblast. The person can allow them again in msgblast. Nothing was sent (agentSendsStopped). "
                                       + "Once the person allows agent sends, the same call can be repeated."))
    }

    func testTooManySendsAreRefusedButRepeatsOfAKnownRequestAreNot() async throws {
        let host = Host()
        for index in 0..<6 { _ = try await call("msgblast_blast_start", #"{"text":"Hi","agents":["web:chatgpt"],"requestId":"r\#(index)"}"#, host: host) }
        let seventh = await refusal("msgblast_blast_start", #"{"text":"Hi","agents":["web:chatgpt"],"requestId":"r6"}"#, host: host)
        guard case .refused(let why)? = seventh else { return XCTFail("expected a refusal, got \(String(describing: seventh))") }
        XCTAssertTrue(why.contains("Too many sends from Codex"))
        let repeated = try await call("msgblast_blast_start", #"{"text":"Hi","agents":["web:chatgpt"],"requestId":"r0"}"#, host: host)
        XCTAssertEqual(repeated["replayed"] as? Bool, true)
        XCTAssertEqual(host.commands.count, 6)
        _ = try await call("msgblast_blast_start", #"{"text":"Hi","agents":["web:chatgpt"]}"#, host: host, client: "Claude Code")
        XCTAssertEqual(host.commands.count, 7, "the limit is per agent name")
    }

    func testLimitWindowsSlide() {
        var limit = AgentControlSendLimit()
        let start = Date(timeIntervalSince1970: 1_000_000)
        for second in 0..<6 { XCTAssertTrue(limit.allow("Codex", now: start.addingTimeInterval(Double(second)))) }
        XCTAssertFalse(limit.allow("Codex", now: start.addingTimeInterval(30)))
        XCTAssertTrue(limit.allow("Codex", now: start.addingTimeInterval(61)))
    }

    func testTheHourlyLimitStopsTheSixtyFirstSend() {
        var limit = AgentControlSendLimit()
        let start = Date(timeIntervalSince1970: 1_000_000)
        // 59 seconds apart stays under 6 a minute, so only the hourly window can refuse.
        for index in 0..<60 { XCTAssertTrue(limit.allow("Codex", now: start.addingTimeInterval(Double(index) * 59)), "send \(index)") }
        XCTAssertFalse(limit.allow("Codex", now: start.addingTimeInterval(60 * 59)))
        XCTAssertTrue(limit.allow("Claude Code", now: start.addingTimeInterval(60 * 59)))
        XCTAssertTrue(limit.allow("Codex", now: start.addingTimeInterval(3601)), "the first send has left the hour")
    }

    func testAgentIDsTranslateBothWays() {
        let fo = UUID()
        XCTAssertEqual(AgentControlSend.remoteID("web:chatgpt"), "chatgpt")
        XCTAssertEqual(AgentControlSend.remoteID("messages:\(fo.uuidString)"), "messages:\(fo.uuidString)")
        XCTAssertNil(AgentControlSend.remoteID("messages:nope"))
        XCTAssertNil(AgentControlSend.remoteID("web:nope"))
        XCTAssertNil(AgentControlSend.remoteID("runtime:codex"))
        for id in ["web:chatgpt", "web-instance:chatgpt:\(fo.uuidString)", "messages:\(fo.uuidString)"] {
            XCTAssertEqual(AgentControlSend.remoteID(id).map(AgentControlSend.listID), id)
        }
    }
}
