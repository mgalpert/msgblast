import XCTest
@testable import msgblastCore

final class AgentControlCLITests: XCTestCase {
    private func request(_ arguments: [String], environment: [String: String] = [:]) throws -> [String: Any] {
        guard case .request(let line) = try AgentControlCLI.parse(arguments, environment: environment).command else {
            XCTFail("\(arguments) is not a request")
            return [:]
        }
        XCTAssertEqual(line.last, 0x0A)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
    }

    private func usageError(_ arguments: [String]) -> String? {
        do { _ = try AgentControlCLI.parse(arguments, environment: [:]); return nil }
        catch { return (error as? AgentControlCLI.UsageError)?.message }
    }

    func testCommandsBecomeToolCallsForTheNamedClient() throws {
        let status = try request(["status", "--client", "Hermes"])
        XCTAssertEqual(status["method"] as? String, "tools/call")
        XCTAssertEqual(status["name"] as? String, "msgblast_status")
        XCTAssertEqual(status["client"] as? String, "Hermes")
        XCTAssertEqual((try request(["agents", "--all"])["arguments"] as? [String: Any])?["includeHidden"] as? Bool, true)
        let comparisons = try XCTUnwrap(try request(["comparisons", "--query", "trip", "--limit", "5"])["arguments"] as? [String: Any])
        XCTAssertEqual(comparisons["query"] as? String, "trip")
        XCTAssertEqual(comparisons["limit"] as? Int, 5)
        let wait = try XCTUnwrap(try request(["wait", "--after", "3", "--comparison", "ABC", "--timeout", "30"])["arguments"] as? [String: Any])
        XCTAssertEqual(wait["after"] as? Int, 3)
        XCTAssertEqual(wait["comparisonId"] as? String, "ABC")
        XCTAssertEqual(wait["timeoutSeconds"] as? Int, 30)
        XCTAssertEqual((try request(["show", "ABC"])["arguments"] as? [String: Any])?["id"] as? String, "ABC")
        XCTAssertEqual(try request(["tools"])["method"] as? String, "tools/list")
        let call = try request(["call", "msgblast_comparisons_list", #"{"limit":2}"#])
        XCTAssertEqual(call["name"] as? String, "msgblast_comparisons_list")
        XCTAssertEqual((call["arguments"] as? [String: Any])?["limit"] as? Int, 2)
    }

    func testClientNameComesFromFlagThenEnvironment() throws {
        XCTAssertEqual(try request(["status"])["client"] as? String, "Terminal")
        XCTAssertEqual(try request(["status"], environment: ["CLAUDECODE": "1"])["client"] as? String, "Claude Code")
        XCTAssertEqual(try request(["status"], environment: ["MSGBLAST_CLIENT": "Hermes", "CLAUDECODE": "1"])["client"] as? String, "Hermes")
        XCTAssertEqual(try AgentControlCLI.parse(["mcp"], environment: ["CLAUDECODE": "1"]).command, .mcp(client: nil))
        XCTAssertEqual(try AgentControlCLI.parse(["mcp", "--client", "Muse"], environment: [:]).command, .mcp(client: "Muse"))
        XCTAssertEqual(try AgentControlCLI.parse([], environment: [:]).command, .help)
    }

    func testInvalidCommandsExplainThemselves() {
        XCTAssertEqual(usageError(["show"]), "show needs one comparison id.")
        XCTAssertEqual(usageError(["comparisons", "--limit", "many"]), "--limit must be a whole number.")
        XCTAssertEqual(usageError(["status", "--client"]), "--client needs a value.")
        XCTAssertEqual(usageError(["call", "msgblast_status", "[1]"]), "Arguments must be one JSON object.")
        XCTAssertEqual(usageError(["blast"]), "Unknown command blast.")
    }

    func testLeadingOptionsStillRunTheCommandButAppLaunchOptionsOpenTheApp() throws {
        XCTAssertTrue(AgentControlCLI.isCommand(["--client", "Hermes", "status"]))
        XCTAssertTrue(AgentControlCLI.isCommand(["--json", "agents"]))
        XCTAssertTrue(AgentControlCLI.isCommand(["--help"]))
        XCTAssertTrue(AgentControlCLI.isCommand(["wait", "--timeout", "5"]))
        XCTAssertFalse(AgentControlCLI.isCommand([]))
        XCTAssertFalse(AgentControlCLI.isCommand(["--demo"]))
        XCTAssertFalse(AgentControlCLI.isCommand(["--update-probe"]))
        XCTAssertFalse(AgentControlCLI.isCommand(["-NSDocumentRevisionsDebugMode", "YES"]))
        XCTAssertEqual(try request(["--client", "Hermes", "--json", "status"])["client"] as? String, "Hermes")
        XCTAssertEqual(try AgentControlCLI.parse(["--help"], environment: [:]).command, .help)
    }

    func testClientNamesAreCheckedAndUnknownOptionsRefused() throws {
        XCTAssertEqual(try request(["status", "--client", "Her\u{202E}mes\n"])["client"] as? String, "Her mes")
        XCTAssertEqual(usageError(["status", "--client", String(repeating: "x", count: 81)]), "--client must be a name of 1 to 80 characters.")
        XCTAssertEqual(usageError(["status", "--client", "\u{0007}"]), "--client must be a name of 1 to 80 characters.")
        XCTAssertEqual(usageError(["status", "--bogus", "x"]), "Unknown option --bogus.")
    }

    func testRepliesMapToOutputAndExitStatus() {
        let ok = AgentControlCLI.render(Data(#"{"id":1,"result":{"b":1,"a":[2]}}"#.utf8), json: true)
        XCTAssertEqual(ok, AgentControlCLI.Output(stdout: "{\"a\":[2],\"b\":1}\n", stderr: "", status: 0))
        XCTAssertTrue(AgentControlCLI.render(Data(#"{"id":1,"result":{"a":1}}"#.utf8), json: false).stdout.contains("\n  \"a\""))
        let statuses = ["notApproved": 3, "needsAccess": 3, "notFound": 4, "invalidArguments": 2, "unknownTool": 2, "failed": 1]
        for (code, status) in statuses {
            let output = AgentControlCLI.render(Data(#"{"id":1,"error":{"code":"\#(code)","message":"No."}}"#.utf8), json: false)
            XCTAssertEqual(output, AgentControlCLI.Output(stdout: "", stderr: "No.\n", status: Int32(status)), code)
        }
        XCTAssertEqual(AgentControlCLI.render(Data("nope".utf8), json: false).status, 1)
    }

    func testALostReplyIsToldApartFromMsgblastNotRunning() throws {
        let path = NSTemporaryDirectory() + "mb-\(UUID().uuidString.prefix(8)).sock"
        let line = Data("{}\n".utf8)
        XCTAssertThrowsError(try AgentControlSocketClient.exchange(line, socket: path)) { XCTAssertTrue($0 is AgentControlSocketClient.Unavailable) }
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(server); unlink(path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(server, 1), 0)
        // The app reads the whole request, then goes away without answering.
        Thread {
            let client = accept(server, nil, nil)
            var buffer = [UInt8](repeating: 0, count: 64)
            _ = read(client, &buffer, buffer.count)
            close(client)
        }.start()
        XCTAssertThrowsError(try AgentControlSocketClient.exchange(line, socket: path)) { XCTAssertTrue($0 is AgentControlSocketClient.NoReply) }
    }
}
