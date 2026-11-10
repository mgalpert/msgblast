import XCTest
@testable import msgblastCore

final class ClaudeDuetAppConversationTests: XCTestCase {
    private let prompt = "msgblast Duet test 1. Reply with exactly: ACK 1"
    private let composer = DesktopAppSnapshot.Element.Frame(x: 100, y: 400, w: 400, h: 40)
    private let sendFrame = DesktopAppSnapshot.Element.Frame(x: 70, y: 70, w: 16, h: 16)

    private final class Note: @unchecked Sendable {
        var delivery = ""
        var submitted = false
        var draftAtSubmit = ""
        var alreadySubmitted = false
    }

    private static func page(draft: String, sent: Bool, prompt: String, composer: DesktopAppSnapshot.Element.Frame, send: DesktopAppSnapshot.Element.Frame) -> ClaudeAXNode {
        func frame(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> DesktopAppSnapshot.Element.Frame { .init(x: x, y: y, w: w, h: h) }
        var children = [
            ClaudeAXNode(role: "AXStaticText", value: "Earlier note", frame: frame(100, 20, 220, 22)),
            ClaudeAXNode(role: "AXTextArea", label: "Message Claude Duet", value: draft, frame: composer)
        ]
        if sent {
            children.insert(ClaudeAXNode(role: "AXStaticText", value: prompt, frame: frame(280, 80, 220, 22)), at: 1)
            children.insert(ClaudeAXNode(role: "AXStaticText", value: "ACK 1", frame: frame(100, 120, 80, 22)), at: 2)
        } else if !draft.isEmpty {
            children.append(ClaudeAXNode(role: "AXButton", label: "Send message", frame: send))
        }
        return ClaudeAXNode(role: "AXWindow", children: [
            ClaudeAXNode(role: "AXWebArea", label: "Claude Duet - Claude", url: URL(string: "https://claude.ai/messages"), children: children)
        ])
    }

    private func fixture(_ mode: String) throws -> (directory: URL, adapter: ClaudeDuetAppConversation) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-duet-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        if mode == "refuse" || mode == "mismatch" { try Data(mode.utf8).write(to: directory.appendingPathComponent(mode)) }
        let executable = directory.appendingPathComponent("driver")
        try Data("""
        #!/usr/bin/env python3
        import sys,json,pathlib,struct,zlib
        p=pathlib.Path(__file__).parent
        tool=sys.argv[2];a=json.loads(sys.argv[3])
        with (p/'calls.jsonl').open('a') as f:f.write(json.dumps({'tool':tool,'arguments':a})+'\\n')
        def draft():
            return (p/'draft.txt').read_text() if (p/'draft.txt').exists() else ''
        if tool=='list_apps':
            print(json.dumps({'apps':[{'bundle_id':'com.anthropic.claudefordesktop','pid':42,'running':True}]}))
        elif tool=='list_windows':
            print(json.dumps({'windows':[{'window_id':21,'title':'Claude','is_on_screen':True,'bounds':{'width':800,'height':600}}]}))
        elif tool=='get_window_state':
            text=draft()
            elements=[{'role':'AXWindow','label':'Claude','enabled':True,'element_token':'window'},{'role':'AXTextArea','label':'Message Claude Duet','value':text,'enabled':True,'element_token':'composer','frame':{'x':10,'y':40,'w':80,'h':20}}]
            if text:elements.append({'role':'AXButton','label':'Send message','enabled':True,'element_token':'send','frame':{'x':70,'y':70,'w':16,'h':16}})
            state={'pid':42,'window_id':21,'elements':elements,'window_bounds':{'x':0,'y':0,'width':100,'height':100}}
            if a.get('include_screenshot'):
                image=pathlib.Path(a['screenshot_out_file'])
                def chunk(kind,data):return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
                image.write_bytes(bytes([137,80,78,71,13,10,26,10])+chunk(b'IHDR',struct.pack('>IIBBBBB',100,100,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(bytes(301)*100))+chunk(b'IEND',b''))
                state.update(screenshot_frame_valid=True,screenshot_width=100,screenshot_height=100,screenshot_file_path=str(image))
            print(json.dumps(state))
        elif tool=='type_text':
            assert a['delivery_mode']=='background' and a['pid']==42 and a['window_id']==21
            if 'element_token' in a:
                assert a['element_token']=='composer' and 'x' not in a
                if (p/'refuse').exists():
                    print(json.dumps({'status':'refused','refusal':{'code':'background_unavailable'}}));sys.stdout.flush();raise SystemExit
                (p/'draft.txt').write_text('partial' if (p/'mismatch').exists() else a['text'])
            else:
                assert 'x' in a and 'y' in a
                (p/'draft.txt').write_text(draft()+a['text'])
            print(json.dumps({'effect':'unverifiable'}))
        elif tool=='click':
            assert a['delivery_mode']=='background' and a['element_token']=='send'
            (p/'submitted').write_text('1');(p/'draft.txt').write_text('')
            print(json.dumps({'effect':'unverifiable'}))
        elif tool=='press_key':
            assert a['key']=='return' and a['delivery_mode']=='background' and a['element_token']=='composer'
            (p/'submitted').write_text('1');(p/'draft.txt').write_text('')
            print(json.dumps({'effect':'unverifiable'}))
        elif tool=='bring_to_front':
            assert a['pid']==42 and a['window_id']==21
            print(json.dumps({'activated':True,'pid':42,'window_id':21,'exact_window_effect':{'verified':True}}))
        elif tool=='end_session':print('{}')
        else:raise SystemExit('unexpected '+tool)
        sys.stdout.flush()
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let timing = DesktopAppConversation.Timing(pollInterval: .milliseconds(1), stableDuration: .zero, replyTimeout: .seconds(2), callTimeout: 3, replyClock: .init(AdvancingClock()))
        let prompt = prompt, composer = composer, send = sendFrame
        let adapter = ClaudeDuetAppConversation(executable: executable, timing: timing) { _ in
            if mode == "occupied" { return Self.page(draft: "See you there", sent: false, prompt: prompt, composer: composer, send: send) }
            let draft = (try? String(contentsOf: directory.appendingPathComponent("draft.txt"), encoding: .utf8)) ?? ""
            let sent = FileManager.default.fileExists(atPath: directory.appendingPathComponent("submitted").path)
            return Self.page(draft: sent ? "" : draft, sent: sent, prompt: prompt, composer: composer, send: send)
        }
        return (directory, adapter)
    }

    private func calls(_ directory: URL) throws -> [[String: Any]] {
        let text = try String(contentsOf: directory.appendingPathComponent("calls.jsonl"), encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                throw CocoaError(.coderReadCorrupt)
            }
            return object
        }
    }

    func testBackgroundSendReturnsOnlyTheNewAgentReply() async throws {
        let fixture = try fixture("send")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let note = Note()
        let answer = try await fixture.adapter.reply(prompt, onSubmitAction: {
            note.draftAtSubmit = (try? String(contentsOf: fixture.directory.appendingPathComponent("draft.txt"), encoding: .utf8)) ?? ""
            note.alreadySubmitted = FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("submitted").path)
        }, onSubmitted: { note.submitted = true }, onDelivery: { note.delivery = $0 })
        XCTAssertEqual(answer, "ACK 1")
        XCTAssertEqual(note.delivery, "background")
        XCTAssertEqual(note.draftAtSubmit, prompt)
        XCTAssertFalse(note.alreadySubmitted)
        XCTAssertTrue(note.submitted)
        let calls = try calls(fixture.directory)
        let typed = calls.filter { $0["tool"] as? String == "type_text" }
        XCTAssertEqual(typed.count, 1)
        let arguments = try XCTUnwrap(typed[0]["arguments"] as? [String: Any])
        XCTAssertEqual(arguments["element_token"] as? String, "composer")
        XCTAssertEqual(arguments["delivery_mode"] as? String, "background")
        XCTAssertEqual(arguments["text"] as? String, prompt)
        XCTAssertNil(arguments["x"])
        XCTAssertEqual(calls.filter { $0["tool"] as? String == "click" }.count, 1)
        XCTAssertFalse(calls.contains { $0["tool"] as? String == "bring_to_front" })
    }

    func testBackgroundUnavailableUsesForegroundTyping() async throws {
        let fixture = try fixture("refuse")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let note = Note()
        let answer = try await fixture.adapter.reply(prompt, onSubmitted: { note.submitted = true }, onDelivery: { note.delivery = $0 })
        XCTAssertEqual(answer, "ACK 1")
        XCTAssertEqual(note.delivery, "foreground")
        XCTAssertTrue(note.submitted)
        let calls = try calls(fixture.directory)
        let typed = calls.filter { $0["tool"] as? String == "type_text" }.compactMap { $0["arguments"] as? [String: Any] }
        XCTAssertEqual(typed.count, 2)
        XCTAssertEqual(typed[0]["element_token"] as? String, "composer")
        XCTAssertNil(typed[1]["element_token"])
        XCTAssertEqual(typed[1]["x"] as? Int, 50)
        XCTAssertEqual(typed[1]["y"] as? Int, 50)
        XCTAssertEqual(typed[1]["text"] as? String, prompt)
        XCTAssertTrue(calls.contains { $0["tool"] as? String == "bring_to_front" })
        XCTAssertEqual(calls.filter { $0["tool"] as? String == "click" }.count, 1)
    }

    func testMismatchedDraftNeverSubmits() async throws {
        let fixture = try fixture("mismatch")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        do {
            _ = try await fixture.adapter.reply(prompt, onSubmitAction: { XCTFail("A mismatched draft must not submit") })
            XCTFail("A mismatched draft must stop")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Claude Duet's draft did not match. Nothing was sent.")
        }
        let calls = try calls(fixture.directory)
        XCTAssertEqual(calls.filter { $0["tool"] as? String == "type_text" }.count, 1)
        XCTAssertFalse(calls.contains { ["click", "press_key", "bring_to_front"].contains($0["tool"] as? String ?? "") })
        XCTAssertEqual(try String(contentsOf: fixture.directory.appendingPathComponent("draft.txt"), encoding: .utf8), "partial")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("submitted").path))
    }

    func testOccupiedDraftNeverTypes() async throws {
        let fixture = try fixture("occupied")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        do {
            _ = try await fixture.adapter.reply(prompt)
            XCTFail("An existing draft must stop the send")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Clear the Claude Duet draft first. Nothing was sent.")
        }
        let calls = try calls(fixture.directory)
        XCTAssertFalse(calls.contains { ["type_text", "click", "press_key", "bring_to_front"].contains($0["tool"] as? String ?? "") })
    }
}
