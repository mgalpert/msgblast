import XCTest
@testable import msgblastCore

final class AgentControlTailnetSetupTests: XCTestCase {
    func testSetupText() {
        let text = AgentControlTailnetSetup.text(url: "http://mac.example.ts.net:47480/mcp", key: "test-key")
        XCTAssertEqual(text, [
            "msgblast MCP server for Grok Bot",
            "Server URL: http://mac.example.ts.net:47480/mcp",
            "Header: Authorization: Bearer test-key",
        ].joined(separator: "\n"))
        XCTAssertFalse(text.hasSuffix("\n"))
    }

    func testStatusParsing() {
        let named = #"{"Self":{"DNSName":"mac.example.ts.net."},"CertDomains":["mac.example.ts.net"],"Peer":{"n1":{"HostName":"laptop","DNSName":"laptop.example.ts.net."},"n2":{"HostName":"GrokBot","DNSName":"other.example.ts.net."}}}"#
        let parsed = AgentControlTailnetStatus.parse(Data(named.utf8))
        XCTAssertEqual(parsed?.magicName, "mac.example.ts.net")
        XCTAssertEqual(parsed?.httpsEnabled, true)
        XCTAssertEqual(parsed?.grokBotPeer, true)

        let emptyCerts = #"{"Self":{"DNSName":"mac.example.ts.net"},"CertDomains":[],"Peer":{"n1":{"HostName":"laptop","DNSName":"laptop.example.ts.net."}}}"#
        let off = AgentControlTailnetStatus.parse(Data(emptyCerts.utf8))
        XCTAssertEqual(off?.magicName, "mac.example.ts.net")
        XCTAssertEqual(off?.httpsEnabled, false)
        XCTAssertEqual(off?.grokBotPeer, false)

        let missing = #"{"Peer":{"n1":{"DNSName":"GROKBOT.example.ts.net."}}}"#
        let peerOnly = AgentControlTailnetStatus.parse(Data(missing.utf8))
        XCTAssertNil(peerOnly?.magicName)
        XCTAssertEqual(peerOnly?.httpsEnabled, false)
        XCTAssertEqual(peerOnly?.grokBotPeer, true)

        let selfOnly = #"{"Self":{"DNSName":"grokbot.example.ts.net.","HostName":"grokbot"},"CertDomains":"nope"}"#
        let notAPeer = AgentControlTailnetStatus.parse(Data(selfOnly.utf8))
        XCTAssertEqual(notAPeer?.magicName, "grokbot.example.ts.net")
        XCTAssertEqual(notAPeer?.httpsEnabled, false)
        XCTAssertEqual(notAPeer?.grokBotPeer, false)

        XCTAssertNil(AgentControlTailnetStatus.parse(Data("not-json".utf8)))
        XCTAssertNil(AgentControlTailnetStatus.parse(Data("[]".utf8)))
    }

    func testReadinessLines() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let missing = AgentControlTailnetSetup.lines(magicName: nil, httpsEnabled: false, grokBotPeer: false, lastCalled: nil, now: now)
        XCTAssertEqual(missing, [
            "\u{26A0}\u{FE0E} Tailscale isn't connected on this Mac.",
            "\u{2139}\u{FE0E} HTTPS certificates are off for this tailnet. Nothing to change: msgblast uses http://, and Tailscale encrypts the connection.",
            "\u{26A0}\u{FE0E} Grok Bot hasn't called msgblast yet. No Grok Bot device on your tailnet yet — connect it in Grok Bot: Connect apps → Your plugins → Tailscale → Authenticate.",
        ])
        let device = AgentControlTailnetSetup.lines(magicName: "mac.example.ts.net", httpsEnabled: true, grokBotPeer: true, lastCalled: nil, now: now)
        XCTAssertEqual(device[0], "\u{2713} Connected as mac.example.ts.net")
        XCTAssertEqual(device[1], "\u{2713} HTTPS certificates are on for this tailnet.")
        XCTAssertEqual(device[2], "\u{26A0}\u{FE0E} Grok Bot hasn't called msgblast yet. A Grok Bot device is on your tailnet.")
        let called = AgentControlTailnetSetup.lines(magicName: "mac.example.ts.net", httpsEnabled: true, grokBotPeer: false, lastCalled: now.addingTimeInterval(-120), now: now)
        XCTAssertEqual(called[2], "\u{2713} Grok Bot last called 2 minutes ago.")
        let recent = AgentControlTailnetSetup.lines(magicName: "mac.example.ts.net", httpsEnabled: true, grokBotPeer: false, lastCalled: now, now: now)
        XCTAssertEqual(recent[2], "\u{2713} Grok Bot last called just now.")
    }

    func testFirewallParseAndLines() {
        let off = "Firewall is disabled. (State = 0)"
        let on = "Firewall is enabled. (State = 1)"
        let block = "Firewall is enabled. (State = 2)"
        XCTAssertEqual(AgentControlFirewall.parse(globalState: off, appBlocked: "Incoming connection is blocked."), .off)
        XCTAssertEqual(AgentControlFirewall.parse(globalState: on, appBlocked: "Incoming connection to /Applications/msgblast.app is permitted."), .onAllowed)
        XCTAssertEqual(AgentControlFirewall.parse(globalState: on, appBlocked: "Incoming connection to /Applications/msgblast.app is blocked."), .onBlocked)
        XCTAssertEqual(AgentControlFirewall.parse(globalState: on, appBlocked: nil), .onUnknown)
        XCTAssertEqual(AgentControlFirewall.parse(globalState: on, appBlocked: "not in the firewall list"), .onUnknown)
        XCTAssertEqual(AgentControlFirewall.parse(globalState: "no such state", appBlocked: nil), .onUnknown)
        XCTAssertEqual(AgentControlFirewall.parse(globalState: block, appBlocked: "is permitted"), .blockAll)

        XCTAssertNil(AgentControlFirewall.line(.off))
        XCTAssertEqual(AgentControlFirewall.line(.onAllowed), "\u{2713} The macOS firewall allows msgblast incoming connections.")
        XCTAssertEqual(AgentControlFirewall.line(.onBlocked), "\u{26A0}\u{FE0E} The macOS firewall blocks msgblast, so Grok Bot can't reach it. Allow msgblast in System Settings → Network → Firewall → Options.")
        XCTAssertEqual(AgentControlFirewall.line(.onUnknown), "\u{26A0}\u{FE0E} The macOS firewall is on. If Grok Bot can't connect, allow msgblast in System Settings → Network → Firewall → Options.")
        XCTAssertEqual(AgentControlFirewall.line(.blockAll), "\u{26A0}\u{FE0E} The macOS firewall blocks all incoming connections, so Grok Bot can't reach msgblast. Turn off \"Block all incoming connections\" in System Settings → Network → Firewall → Options.")
    }

    func testAuthorizedRequestRecordsLastCalled() async throws {
        let token = "secret-token"
        let endpoint = AgentControlHTTPEndpoint(hashes: [AgentControlTailnet.grokBotClient: AgentControlTailnet.tokenHash(token)], version: "9.9") { _ in
            throw CocoaError(.fileNoSuchFile)
        }
        let before = await endpoint.lastAuthorized
        XCTAssertNil(before)
        let denied = await endpoint.handle(try request("POST", "/mcp", #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#), peer: "100.64.0.1")
        XCTAssertEqual(denied.status, 401)
        let afterDenied = await endpoint.lastAuthorized
        XCTAssertNil(afterDenied)
        let accepted = await endpoint.handle(try request("POST", "/mcp", #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#, headers: ["Authorization": "Bearer \(token)"]), peer: "100.64.0.1")
        XCTAssertEqual(accepted.status, 200)
        let stamp = await endpoint.lastAuthorized
        XCTAssertNotNil(stamp)
        let wrongAgain = await endpoint.handle(try request("POST", "/mcp/nope", #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#), peer: "100.64.0.1")
        XCTAssertEqual(wrongAgain.status, 401)
        let afterWrong = await endpoint.lastAuthorized
        XCTAssertEqual(afterWrong, stamp)
        let stranger = await endpoint.handle(try request("POST", "/mcp", #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#, headers: ["Authorization": "Bearer \(token)"]), peer: "192.168.1.2")
        XCTAssertEqual(stranger.status, 403)
        let afterStranger = await endpoint.lastAuthorized
        XCTAssertEqual(afterStranger, stamp)
    }

    private func request(_ method: String, _ path: String, _ body: String = "", headers: [String: String] = [:]) throws -> AgentControlHTTPRequest {
        var lines = ["\(method) \(path) HTTP/1.1", "Host: 100.64.0.1"]
        for (name, value) in headers { lines.append("\(name): \(value)") }
        if method == "POST" || !body.isEmpty { lines.append("Content-Length: \(Data(body.utf8).count)") }
        let text = lines.joined(separator: "\r\n") + "\r\n\r\n" + body
        guard case .complete(let request, _) = AgentControlHTTPRequest.parse(Data(text.utf8)) else {
            XCTFail("expected a complete request")
            throw CocoaError(.fileReadCorruptFile)
        }
        return request
    }
}
