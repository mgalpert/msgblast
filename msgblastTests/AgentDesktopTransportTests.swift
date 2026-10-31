import XCTest
@testable import msgblastCore

final class AgentDesktopTransportTests: XCTestCase {
    private let target = DesktopAppConversation.Target(pid: 42, window: 101)
    private func snapshot(complete: Bool = true, window: String = "w-101") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["complete": complete, "window": ["id": window], "tree": [
            "role": "window", "children": [["role": "webarea", "children": [
                ["role": "list", "children": [["role": "button", "name": "Fixture Bot", "ref_id": "@snapshot:e1"]]],
                ["role": "splitter", "name": "Resize sidebar"],
                ["role": "heading", "name": "Fixture Bot", "value": "1"],
                ["role": "statictext", "name": "You", "value": "You"],
                ["role": "statictext", "name": "Old prompt", "value": "Old prompt"],
                ["role": "textfield", "name": "Prompt", "value": "Preserve this\n🦊", "ref_id": "@snapshot:e2"],
                ["role": "button", "name": "Send message", "ref_id": "@snapshot:e3", "states": ["disabled"]]
            ]]]
        ]])
    }
    func testConversionRetainsBotHierarchyExactDraftAndDisabledSend() throws {
        let data = try AgentDesktopTransport.normalizeSnapshot(snapshot(), target: target)
        let state = try JSONDecoder().decode(DesktopAppSnapshot.self, from: data)
        XCTAssertEqual(try state.grokBots().map(\.name), ["Fixture Bot"])
        XCTAssertEqual(try state.conversation(app: .grokBot), "Fixture Bot")
        XCTAssertEqual(try state.composer(app: .grokBot).draft, "Preserve this\n🦊")
        XCTAssertEqual(try state.historyText(app: .grokBot), ["You", "Old prompt"])
        XCTAssertThrowsError(try state.sendButton(app: .grokBot))
    }
    func testIncompleteAndWrongWindowNeverBecomeReadableSnapshots() throws {
        XCTAssertThrowsError(try AgentDesktopTransport.normalizeSnapshot(snapshot(complete: false), target: target))
        XCTAssertThrowsError(try AgentDesktopTransport.normalizeSnapshot(snapshot(window: "w-102"), target: target))
        XCTAssertThrowsError(try AgentDesktopTransport.normalizeSnapshot(Data("{}".utf8), target: target))
    }
    func testFailedActionIsNeverRetried() async throws {
        let calls = Calls()
        let transport = AgentDesktopTransport(executable: URL(fileURLWithPath: "/fixture/agent-desktop"), run: { _, args, _, _, _ in
            await calls.append(args)
            let payload: String
            switch args[0] {
            case "list-apps": payload = #"{"ok":true,"data":{"apps":[{"pid":42,"name":"Fixture"}]}}"#
            case "list-windows": payload = #"{"ok":true,"data":[{"pid":42,"id":"w-101"}]}"#
            default: return .init(status: 1, stdout: #"{"ok":false,"error":{"code":"ACTION_FAILED","disposition":{"delivery":"delivered_unverified","retry":"unsafe"}}}"#, stderr: "")
            }
            return .init(status: 0, stdout: payload, stderr: "")
        })
        do {
            _ = try await transport.call("click", strings: ["element_token": "@snapshot:e1"], numbers: ["pid": 42, "window_id": 101])
            XCTFail("Uncertain action must stop")
        } catch { }
        let recorded = await calls.values
        XCTAssertEqual(recorded.filter { $0.first == "click" }.count, 1)
    }
    func testTrailingEditorPaddingIsNormalizedWithoutLosingBlankLines() throws {
        var data = try JSONSerialization.jsonObject(with: snapshot()) as! [String: Any]
        data["tree"] = ["role": "window", "children": [["role": "textfield", "name": "Prompt", "value": "First\n\n\n", "ref_id": "@s:e1"]]]
        let converted = try AgentDesktopTransport.normalizeSnapshot(JSONSerialization.data(withJSONObject: data), target: target)
        let state = try JSONDecoder().decode(DesktopAppSnapshot.self, from: converted)
        XCTAssertEqual(state.elements.last?.value, "First\n\n")
    }

    func testAccessibleOtherSpaceWindowIsAcceptedAndSecondWindowIsAmbiguous() async throws {
        for count in [1, 2] {
            let transport = AgentDesktopTransport(executable: URL(fileURLWithPath: "/fixture/agent-desktop"), run: { _, args, env, _, _ in
                XCTAssertNotNil(env["AGENT_DESKTOP_HOME"], "Private refs must not go into the user's CLI state")
                let payload: [String: Any]
                if args[0] == "list-apps" {
                    payload = ["ok": true, "data": ["apps": [["pid": 42, "name": "Fixture", "bundle_id": "com.anysphere.sand"]]]]
                } else {
                    payload = ["ok": true, "data": (0..<count).map { ["id": "w-\(101 + $0)", "pid": 42, "title": "Fixture", "accessible": true, "visible": false, "bounds": ["width": 800, "height": 600]] as [String: Any] }]
                }
                return .init(status: 0, stdout: String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self))
            })
            let driver = DesktopAppConversation(agentDesktop: transport)
            if count == 1 {
                let actual = try await driver.target(.grokBot)
                XCTAssertEqual(actual, target)
            } else {
                do { _ = try await driver.target(.grokBot); XCTFail("Ambiguous windows must stop") } catch { }
            }
        }
    }

    func testBackgroundTransportCannotEscalateToHeadedSend() async throws {
        let calls = Calls()
        let transport = AgentDesktopTransport(executable: URL(fileURLWithPath: "/fixture/agent-desktop"), run: { _, args, _, _, _ in
            await calls.append(args)
            return .init(status: 1, stdout: "")
        })
        let driver = DesktopAppConversation(agentDesktop: transport)
        do {
            _ = try await driver.reply("Preserve the foreground", app: .grokBot, binding: .init(name: "Fixture"))
            XCTFail("Background sessions must not dispatch headed input")
        } catch { }
        let recorded = await calls.values
        XCTAssertTrue(recorded.isEmpty)
    }

    private actor Calls {
        var values: [[String]] = []
        func append(_ value: [String]) { values.append(value) }
    }
}
