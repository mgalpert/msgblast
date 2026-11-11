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

    func testSetupTextNamesOtherAgents() {
        let text = AgentControlTailnetSetup.text(url: "http://mac.example.ts.net:47480/mcp", key: "k", client: "Laptop Claude Code (Tailscale)")
        XCTAssertEqual(text.split(separator: "\n").first, "msgblast MCP server for Laptop Claude Code")
    }

    func testRemoteClientNames() {
        XCTAssertEqual(AgentControlTailnet.remoteClientName("Grok Bot"), AgentControlTailnet.grokBotClient)
        XCTAssertEqual(AgentControlTailnet.remoteClientName("  Laptop Claude Code  "), "Laptop Claude Code (Tailscale)")
        XCTAssertEqual(AgentControlTailnet.remoteClientName("Cursor (Tailscale)"), "Cursor (Tailscale)")
        XCTAssertEqual(AgentControlTailnet.remoteClientName("Cursor (tailscale) (Tailscale)"), "Cursor (Tailscale)")
        XCTAssertNil(AgentControlTailnet.remoteClientName("   "))
        XCTAssertNil(AgentControlTailnet.remoteClientName("(Tailscale)"))
        XCTAssertEqual(AgentControlTailnet.remoteClientName("bad\nname"), "bad name (Tailscale)")
        XCTAssertEqual(AgentControlTailnet.remoteClientName("Grok\u{200B}Bot"), AgentControlTailnet.grokBotClient)
        XCTAssertEqual(AgentControlTailnet.remoteClientName("Foo  Bar"), "Foo Bar (Tailscale)")
        XCTAssertEqual(AgentControlTailnet.remoteClientName("Evil\u{202E}Name"), "Evil Name (Tailscale)")
        for typed in ["Foo  Bar", "Grok\u{200B}Bot", "Evil\u{202E}Name", "  Laptop  "] {
            let saved = AgentControlTailnet.remoteClientName(typed)!
            XCTAssertEqual(AgentControlGate.clientName(saved), saved, "the key's name must equal its approval name")
        }
        XCTAssertNil(AgentControlTailnet.remoteClientName(String(repeating: "a", count: AgentControlTailnet.maximumClientName + 1)))
    }

    func testStoreKeepsOneKeyPerClient() {
        var store = AgentControlTailnetStore(enabled: true)
        let grok = store.issue(AgentControlTailnet.grokBotClient)
        let laptop = store.issue("Laptop (Tailscale)")
        XCTAssertNotEqual(grok, laptop)
        XCTAssertEqual(store.client(matching: grok), AgentControlTailnet.grokBotClient)
        XCTAssertEqual(store.client(matching: laptop), "Laptop (Tailscale)")
        store.revoke("Laptop (Tailscale)")
        XCTAssertNil(store.client(matching: laptop))
        XCTAssertEqual(store.client(matching: grok), AgentControlTailnet.grokBotClient)
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
        let byClient = await endpoint.lastAuthorizedByClient
        XCTAssertEqual(byClient, [AgentControlTailnet.grokBotClient: stamp!])
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
