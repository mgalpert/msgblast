import XCTest
@testable import msgblastCore

@MainActor final class AgentControlGateTests: XCTestCase {
    private final class Host: AgentControlHost {
        let controlEvents = AgentControlEvents()
        var statusCalls = 0
        func controlStatus() -> AgentControlStatus {
            statusCalls += 1
            return AgentControlStatus(version: "1.0", permissions: [:], busyAgents: [])
        }
        func controlAgents() -> [AgentControlAgent] { [] }
        func controlComparisons() -> [Comparison] { [] }
        func controlTranscript(_ comparison: Comparison) -> [AgentControlTurn] { [] }
    }

    private final class Counter { var value = 0 }
    /// Parks an approval until `finish`, so another client can be served while it waits.
    @MainActor private final class Pause {
        private var continuation: CheckedContinuation<AgentControlAccess?, Never>?
        var started = false
        func wait() async -> AgentControlAccess? {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                started = true
            }
        }
        func finish(_ level: AgentControlAccess?) {
            continuation?.resume(returning: level)
            continuation = nil
        }
    }
    private final class Names { var values: [String] = [] }
    private final class Flag { var live = true }
    private var file: URL!

    override func setUp() async throws {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("agent-control-\(UUID().uuidString).json")
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: file) }

    private func send(_ line: String, gate: AgentControlGate, approve: @escaping AgentControlGate.Approve = { _ in .readOnly }) async throws -> [String: Any] {
        let data = await AgentControlWire.respond(to: Data(line.utf8), host: Host(), gate: gate, approve: approve)
        XCTAssertEqual(data.last, 0x0A)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testApprovalIsAskedOnceSavedAndSurvivesRestart() async throws {
        let asked = Counter()
        let gate = AgentControlGate(file: file)
        let first = Task { await gate.access(for: "Codex") { _ in asked.value += 1; try? await Task.sleep(for: .milliseconds(20)); return .full } }
        let second = Task { await gate.access(for: "Codex") { _ in asked.value += 1; return .readOnly } }
        let levels = [await first.value, await second.value]
        XCTAssertEqual(levels, [.full, .full])
        XCTAssertEqual(asked.value, 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(AgentControlGate(file: file).approvals, ["Codex": .full])
    }

    func testRefusedAndRevokedAgentsAreNotApproved() async throws {
        let gate = AgentControlGate(file: file)
        let refused = try await send(#"{"id":1,"client":"Hermes","method":"tools/list"}"#, gate: gate) { _ in nil }
        XCTAssertEqual((refused["error"] as? [String: Any])?["code"] as? String, "notApproved")
        try gate.set(.full, for: "Hermes")
        try gate.set(nil, for: "Hermes")
        XCTAssertNil(AgentControlGate(file: file).approvals["Hermes"])
    }

    func testDontAllowIsRememberedUntilClearedOrApproved() async throws {
        let asked = Counter()
        let gate = AgentControlGate(file: file)
        let refuse: AgentControlGate.Approve = { _ in asked.value += 1; return nil }
        _ = try await send(#"{"id":1,"client":"Hermes","method":"tools/list"}"#, gate: gate, approve: refuse)
        let again = try await send(#"{"id":2,"client":"Hermes","method":"tools/list"}"#, gate: gate, approve: refuse)
        XCTAssertEqual(asked.value, 1, "a refused agent is not asked again")
        XCTAssertTrue(((again["error"] as? [String: Any])?["message"] as? String)?.contains("Don’t Allow") == true)
        XCTAssertEqual(gate.refused, ["Hermes"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "a refusal is not saved")
        gate.forgetRefusal("Hermes")
        let level = await gate.access(for: "Hermes") { _ in .readOnly }
        XCTAssertEqual(level, .readOnly)
        XCTAssertEqual(gate.refused, [])
    }

    func testClientNamesAreMadeSafeToShow() async throws {
        XCTAssertEqual(AgentControlGate.clientName("  Claude\u{202E}Code \n\t "), "Claude Code")
        XCTAssertEqual(AgentControlGate.clientName("Grok Bot (Tailscale)"), "Grok Bot (Tailscale)")
        XCTAssertNil(AgentControlGate.clientName("\u{0007}\u{200B}"))
        XCTAssertNil(AgentControlGate.clientName(String(repeating: "a", count: 81)))
        let gate = AgentControlGate(file: file)
        let shown = Names()
        _ = try await send(#"{"id":1,"client":"Evil\u202eAgent","method":"tools/list"}"#, gate: gate) { name in shown.values.append(name); return .readOnly }
        XCTAssertEqual(shown.values, ["Evil Agent"])
        let empty = try await send(#"{"id":2,"client":"\u0000","method":"tools/list"}"#, gate: gate)
        XCTAssertEqual((empty["error"] as? [String: Any])?["code"] as? String, "invalidRequest")
    }

    func testUnreadableApprovalsRefuseEveryoneAndAreKept() async throws {
        try Data("not json".utf8).write(to: file)
        let gate = AgentControlGate(file: file)
        XCTAssertTrue(gate.loadFailed)
        let level = await gate.access(for: "Codex") { _ in .full }
        XCTAssertNil(level)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "not json")
    }

    func testWireListsToolsWithAllowedFlagsAndCallsTools() async throws {
        let gate = AgentControlGate(file: file)
        let list = try await send(#"{"id":1,"client":"Claude Code","method":"tools/list"}"#, gate: gate)
        XCTAssertEqual(list["id"] as? Int, 1)
        let tools = try XCTUnwrap((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, AgentControl.tools.count)
        XCTAssertTrue(tools.allSatisfy { $0["inputSchema"] is [String: Any] })
        // Read only: the read tools are allowed and the send tools are listed but not allowed.
        XCTAssertEqual(tools.compactMap { $0["allowed"] as? Bool }, AgentControl.tools.map { $0.access == .readOnly })
        XCTAssertTrue(tools.contains { $0["allowed"] as? Bool == false })
        let status = try await send(#"{"id":"a","client":"Claude Code","method":"tools/call","name":"msgblast_status","arguments":{}}"#, gate: gate)
        XCTAssertEqual((status["result"] as? [String: Any])?["version"] as? String, "1.0")
        let unknown = try await send(#"{"id":3,"client":"Claude Code","method":"tools/call","name":"msgblast_nope"}"#, gate: gate)
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? String, "unknownTool")
    }

    func testWireRefusesArgumentsThatAreNotAnObject() async throws {
        let gate = AgentControlGate(file: file)
        for arguments in [#""x""#, "[1]", "7"] {
            let reply = try await send(#"{"id":1,"client":"Claude Code","method":"tools/call","name":"msgblast_status","arguments":"# + arguments + "}", gate: gate)
            XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? String, "invalidArguments", arguments)
        }
        let null = try await send(#"{"id":2,"client":"Claude Code","method":"tools/call","name":"msgblast_status","arguments":null}"#, gate: gate)
        XCTAssertEqual((null["result"] as? [String: Any])?["version"] as? String, "1.0")
    }

    func testASettingsChangeThatCantBeSavedStillAppliesAndSaysSo() async throws {
        let unwritable = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)/approvals.json")
        let gate = AgentControlGate(file: unwritable)
        gate.change(.full, for: "Codex")
        XCTAssertEqual(gate.approvals["Codex"], .full)
        XCTAssertNotNil(gate.saveError)
        gate.change(nil, for: "Codex")
        XCTAssertNil(gate.approvals["Codex"])
        gate.change(.readOnly, for: "Claude Code")
        XCTAssertEqual(AgentControlGate(file: unwritable).approvals, [:])
        let saved = AgentControlGate(file: file)
        saved.change(.full, for: "Codex")
        XCTAssertNil(saved.saveError)
        XCTAssertEqual(AgentControlGate(file: file).approvals["Codex"], .full)
    }

    func testWireRejectsMalformedLinesAndMissingClient() async throws {
        let gate = AgentControlGate(file: file)
        let garbage = try await send("{", gate: gate)
        XCTAssertEqual((garbage["error"] as? [String: Any])?["code"] as? String, "invalidRequest")
        let anonymous = try await send(#"{"id":1,"method":"tools/list"}"#, gate: gate)
        XCTAssertEqual((anonymous["error"] as? [String: Any])?["code"] as? String, "invalidRequest")
        XCTAssertTrue(gate.approvals.isEmpty)
    }

    func testApprovedClientReturnsWhileAnotherApprovalIsPending() async throws {
        let gate = AgentControlGate(file: file)
        try gate.set(.readOnly, for: "Approved")
        let pause = Pause()
        let pending = Task { await gate.access(for: "Pending") { _ in await pause.wait() } }
        for _ in 0..<100 where !pause.started { await Task.yield() }
        XCTAssertTrue(pause.started)
        let level = await gate.access(for: "Approved") { _ in nil }
        XCTAssertEqual(level, .readOnly)
        XCTAssertNil(gate.approvals["Pending"])
        pause.finish(.full)
        let saved = await pending.value
        XCTAssertEqual(saved, .full)
        XCTAssertEqual(gate.approvals["Pending"], .full)
    }

    func testWireListsToolsWhileAnotherApprovalIsPending() async throws {
        let gate = AgentControlGate(file: file)
        try gate.set(.readOnly, for: "Approved")
        let pause = Pause()
        let pending = Task {
            await AgentControlWire.respond(to: Data(#"{"id":1,"client":"Pending","method":"tools/list"}"#.utf8), host: Host(), gate: gate) { _ in await pause.wait() }
        }
        for _ in 0..<100 where !pause.started { await Task.yield() }
        XCTAssertTrue(pause.started)
        let list = try await send(#"{"id":2,"client":"Approved","method":"tools/list"}"#, gate: gate) { _ in nil }
        XCTAssertEqual(list["id"] as? Int, 2)
        let tools = try XCTUnwrap((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, AgentControl.tools.count)
        XCTAssertNil(gate.approvals["Pending"])
        pause.finish(.full)
        let pendingData = await pending.value
        XCTAssertEqual(pendingData.last, 0x0A)
        let pendingBody = try XCTUnwrap(JSONSerialization.jsonObject(with: pendingData) as? [String: Any])
        XCTAssertEqual(pendingBody["id"] as? Int, 1)
        XCTAssertNotNil((pendingBody["result"] as? [String: Any])?["tools"])
        XCTAssertEqual(gate.approvals["Pending"], .full)
    }

    func testNothingRunsOnceTheSessionIsClosed() async throws {
        let gate = AgentControlGate(file: file)
        try gate.set(.full, for: "Agent")
        let host = Host()
        let line = #"{"id":1,"client":"Agent","method":"tools/call","name":"msgblast_status","arguments":{}}"#
        let data = await AgentControlWire.respond(to: Data(line.utf8), host: host, gate: gate, approve: { _ in nil }, isLive: { false })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((body["error"] as? [String: Any])?["code"] as? String, "unavailable")
        XCTAssertEqual(host.statusCalls, 0)
    }

    func testApprovalAnsweredAfterSwitchingOffRunsNothing() async throws {
        let gate = AgentControlGate(file: file)
        let host = Host()
        let pause = Pause()
        let flag = Flag()
        let line = #"{"id":1,"client":"New","method":"tools/call","name":"msgblast_status","arguments":{}}"#
        let pending = Task {
            await AgentControlWire.respond(to: Data(line.utf8), host: host, gate: gate, approve: { _ in await pause.wait() },
                                           isLive: { flag.live })
        }
        for _ in 0..<100 where !pause.started { await Task.yield() }
        XCTAssertTrue(pause.started)
        flag.live = false
        pause.finish(.full)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: await pending.value) as? [String: Any])
        XCTAssertEqual((body["error"] as? [String: Any])?["code"] as? String, "unavailable")
        XCTAssertEqual(host.statusCalls, 0)
        // The person's choice in the prompt is still kept.
        XCTAssertEqual(gate.approvals["New"], .full)
    }
}
