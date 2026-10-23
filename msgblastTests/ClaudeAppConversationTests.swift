import XCTest
@testable import msgblastCore

final class ClaudeAppConversationTests: XCTestCase {
    private func article(_ index: Int, _ total: Int, _ heading: String, _ body: String) -> ClaudeAXNode {
        .init(role: "AXGroup", subrole: "AXDocumentArticle", label: "Message \(index) of \(total)", children: [
            .init(role: "AXHeading", label: heading),
            .init(role: "AXGroup", children: [.init(role: "AXStaticText", value: body)]),
            .init(role: "AXToolbar", children: [.init(role: "AXStaticText", value: "just now"), .init(role: "AXButton", label: "Copy")])
        ])
    }
    private func tree(_ articles: [ClaudeAXNode] = [], draft: String? = "\n", empty: Bool = true) -> ClaudeAXNode {
        .init(role: "AXWebArea", url: URL(string: articles.isEmpty ? "https://claude.ai/new" : "https://claude.ai/chat/00000000-0000-0000-0000-000000000001"), children: [
            .init(role: "AXGroup", subrole: "AXLandmarkMain", children: [
                .init(role: "AXGroup", label: "Chat messages", children: articles),
                .init(role: "AXTextArea", label: "Write your prompt to Claude", value: draft, children: empty ? [.init(role: "AXGroup", classes: ["is-empty", "is-editor-empty"])] : [])
            ])
        ])
    }
    func testCanonicalURLsRejectExternalAndAmbiguousAddresses() {
        XCTAssertTrue(ClaudeChatURL.isChat(URL(string: "https://claude.ai/chat/00000000-0000-0000-0000-000000000001")!))
        for value in ["https://claude.ai/new", "https://claude.ai/chat/nope", "https://evil.test/chat/00000000-0000-0000-0000-000000000001", "https://claude.ai/chat/00000000-0000-0000-0000-000000000001?x=1"] {
            XCTAssertFalse(ClaudeChatURL.isChat(URL(string: value)!))
        }
    }
    func testStartupReadDoesNotAcceptAmbiguousChatSurfacesOrDialogs() {
        XCTAssertThrowsError(try ClaudeAppObservation(root: .init(role: "AXWindow"))) { error in
            guard case ClaudeObservationError.transient = error else { return XCTFail("A missing startup surface should remain observable on the same Connect") }
        }
        for children in [[tree(), tree()], [ClaudeAXNode(role: "AXDialog"), tree()]] {
            XCTAssertThrowsError(try ClaudeAppObservation(root: .init(role: "AXWindow", children: children))) { error in
                XCTAssertFalse(error is ClaudeObservationError, "Ambiguity and dialogs must fail without retrying input")
            }
        }
    }

    func testMessageBoundariesUseNativeSenderAndExcludeToolbars() throws {
        let observed = try ClaudeAppObservation(root: tree([
            article(1, 2, "You said: Prompt excerpt", "Full prompt"),
            article(2, 2, "Claude responded: Full answer", "Full answer")
        ]))
        XCTAssertEqual(observed.messages, [.init(role: .user, text: "Full prompt"), .init(role: .assistant, text: "Full answer")])
        XCTAssertEqual(observed.draft, "")
    }
    func testUnknownSenderOrMissingMessageIsNotAttributed() {
        XCTAssertThrowsError(try ClaudeAppObservation(root: tree([article(1, 1, "Unknown speaker", "Text")])))
        XCTAssertThrowsError(try ClaudeAppObservation(root: tree([article(2, 2, "Claude responded: Answer", "Answer")]))) { error in
            guard case ClaudeObservationError.transient = error else { return XCTFail("Incomplete article boundaries must remain a retryable observation failure") }
        }
    }
    func testNewlineDraftNeedsNativeEmptyEditorEvidence() throws {
        XCTAssertEqual(try ClaudeAppObservation(root: tree()).draft, "")
        XCTAssertEqual(try ClaudeAppObservation(root: tree(draft: "\n", empty: false)).draft, "\n")
        XCTAssertThrowsError(try ClaudeAppObservation(root: tree(draft: nil)))
    }
    func testNativeParagraphsPreserveBlankLinesOmittedFromAXValue() throws {
        let paragraphs: [ClaudeAXNode] = [
            .init(role: "AXGroup", children: [.init(role: "AXStaticText", value: "First")]),
            .init(role: "AXGroup", subrole: "AXEmptyGroup"),
            .init(role: "AXGroup", children: [.init(role: "AXStaticText", value: "Third")])
        ]
        let draft = try ClaudeNativeDraft.read(.init(role: "AXTextArea", value: "First\nThird", children: paragraphs))
        XCTAssertEqual(draft.raw, "First\nThird")
        XCTAssertEqual(draft.actual, "First\n\nThird")
        XCTAssertThrowsError(try ClaudeNativeDraft.read(.init(role: "AXTextArea", value: "First\nWrong", children: paragraphs)))
        XCTAssertThrowsError(try ClaudeNativeDraft.read(.init(role: "AXTextArea", value: "First", children: [.init(role: "AXGroup", children: [.init(role: "AXButton", label: "Attachment")])])))
    }
    func testReceiptPreservesHistoryAndRejectsConcurrentOutgoing() throws {
        let receipt = ClaudeAppReceipt(baseline: [.init(role: .user, text: "Old")], prompt: "Mine")
        XCTAssertNil(try receipt.reply(in: [.init(role: .user, text: "Old"), .init(role: .user, text: "Mine")]))
        XCTAssertEqual(try receipt.reply(in: [.init(role: .user, text: "Old"), .init(role: .user, text: "Mine"), .init(role: .assistant, text: "Answer")]), "Answer")
        XCTAssertThrowsError(try receipt.reply(in: [.init(role: .user, text: "Changed"), .init(role: .user, text: "Mine"), .init(role: .assistant, text: "Answer")]))
        XCTAssertThrowsError(try receipt.reply(in: [.init(role: .user, text: "Old"), .init(role: .user, text: "Someone else")]))
    }
    func testInterruptedFirstInputBindingSurvivesReload() throws {
        let id = UUID()
        var binding = ClaudeConversationBinding(comparisonID: id)
        binding.firstPrompt = binding.firstMessage("Prompt")
        let restored = try JSONDecoder().decode(ClaudeConversationBinding.self, from: JSONEncoder().encode(binding))
        XCTAssertEqual(restored, binding)
        XCTAssertNil(restored.url)
        XCTAssertTrue(restored.firstPrompt!.contains(id.uuidString))
    }
}

private final class ClaudeOneTransientRead: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !used else { return false }
        used = true
        return true
    }
}

private final class ClaudeStartupReads: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    func isLoading() -> Bool { lock.withLock { reads += 1; return reads <= 3 } }
}

private actor ClaudeRecordedBindings {
    var prepared: [ClaudeConversationBinding] = []
    var bound: [ClaudeConversationBinding] = []
    func prepare(_ value: ClaudeConversationBinding) { prepared.append(value) }
    func bind(_ value: ClaudeConversationBinding) { bound.append(value) }
}

final class ClaudeAppDriverTests: XCTestCase {
    private struct Fixture: Sendable {
        let directory: URL
        let executable: URL
        let binding: ClaudeConversationBinding
        let observations: [ClaudeAppObservation]
        var stage: URL { directory.appendingPathComponent("stage") }
        func calls() -> [[String: Any]] {
            ((try? String(contentsOf: directory.appendingPathComponent("calls.jsonl"), encoding: .utf8)) ?? "").split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
        private static func withDraft(_ draft: String, original: ClaudeAppObservation, collapseBlankParagraphs: Bool) throws -> ClaudeAppObservation {
            let lines = draft.components(separatedBy: "\n")
            let raw = collapseBlankParagraphs && !draft.hasSuffix("\n") ? lines.filter { !$0.isEmpty }.joined(separator: "\n") : draft
            let paragraphs: [ClaudeAXNode] = collapseBlankParagraphs ? lines.map { line in .init(role: "AXGroup", children: line.isEmpty ? [] : [.init(role: "AXStaticText", value: line)]) } : []
            let articles: [ClaudeAXNode] = original.messages.enumerated().map { index, message in
                .init(role: "AXGroup", subrole: "AXDocumentArticle", label: "Message \(index + 1) of \(original.messages.count)", children: [
                    .init(role: "AXHeading", label: (message.role == .user ? "You said: " : "Claude responded: ") + message.text),
                    .init(role: "AXStaticText", value: message.text)
                ])
            }
            return try .init(root: .init(role: "AXWindow", frame: .init(x: 0, y: 0, w: 100, h: 100), children: [
                .init(role: "AXWebArea", url: original.url, children: [.init(role: "AXGroup", subrole: "AXLandmarkMain", children: [
                    .init(role: "AXTextArea", label: "Write your prompt to Claude", value: raw, frame: original.composerFrame, focused: true, children: paragraphs),
                    .init(role: "AXGroup", label: "Chat messages", children: articles)
                ])])
            ]))
        }
        func adapter(transientAfterSend: Bool = false, coldStart: Bool = false) -> ClaudeAppConversation {
            let failure = ClaudeOneTransientRead()
            let startup = ClaudeStartupReads()
            let path = stage
            let observations = observations
            return ClaudeAppConversation(executable: executable, timing: .init(pollInterval: .milliseconds(5), stableDuration: .zero, replyTimeout: .seconds(5), callTimeout: 5), readNative: { _ in
                let stage = Int((try? String(contentsOf: path, encoding: .utf8)) ?? "0") ?? 0
                if coldStart, startup.isLoading() { return try ClaudeAppObservation(root: .init(role: "AXWindow")) }
                if transientAfterSend && stage == 2 && failure.claim() { throw ClaudeObservationError.transient("Claude's message history is incomplete.") }
                let original = observations[min(stage, observations.count - 1)]
                guard stage == 0, let draft = try? String(contentsOf: path.deletingLastPathComponent().appendingPathComponent("draft"), encoding: .utf8) else { return original }
                return try Self.withDraft(draft, original: original, collapseBlankParagraphs: FileManager.default.fileExists(atPath: path.deletingLastPathComponent().appendingPathComponent("collapse-native-paragraphs").path))
            })
        }
    }
    func testOnboardingWaitsForColdStartChatAddressWithoutInput() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.adapter(coldStart: true).checkAvailable()
        XCTAssertFalse(fixture.calls().contains { ["click", "type_text", "press_key", "launch_app"].contains($0["tool"] as? String ?? "") })
        XCTAssertTrue(fixture.calls().contains { $0["tool"] as? String == "get_window_state" })
    }

    private func fixture(followup: Bool = false, foreignOutgoing: Bool = false, wrongPID: Bool = false, initialDraft: String = "", reopen: Bool = false, foreignResume: Bool = false, unknownLaunchResult: Bool = false, omitEmptyDriverValue: Bool = false, question: String = "First question", stripDriverTrailingNewlines: Bool = false, corruptDriverTextAfterNewline: Bool = false, collapseNativeBlankParagraphs: Bool = false) throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = URL(string: "https://claude.ai/chat/00000000-0000-0000-0000-000000000001")!
        let id = UUID(uuidString: "AA000000-0000-0000-0000-000000000001")!
        let pending = ClaudeConversationBinding(comparisonID: id)
        let firstPrompt = pending.firstMessage(question)
        let prompt = followup ? "Follow-up" : firstPrompt
        let binding = followup ? ClaudeConversationBinding(comparisonID: id, url: url, firstPrompt: firstPrompt) : pending
        let baseline: [ClaudeAppMessage] = followup ? [.init(role: .user, text: foreignResume ? "A different comparison" : firstPrompt), .init(role: .assistant, text: "First answer")] : []
        let fieldFrame = DesktopAppSnapshot.Element.Frame(x: 0, y: 0, w: 10, h: 10)
        let windowFrame = DesktopAppSnapshot.Element.Frame(x: 0, y: 0, w: 100, h: 100)
        func observation(_ stage: Int) throws -> ClaudeAppObservation {
            let sent = stage >= 2
            let messages: [ClaudeAppMessage] = stage == 4 ? [] : baseline + (sent ? [.init(role: .user, text: foreignOutgoing ? "Someone else's prompt" : prompt)] : []) + (stage >= 3 ? [.init(role: .assistant, text: "ANSWER")] : [])
            let articles: [ClaudeAXNode] = messages.enumerated().map { index, message in
                let prefix = message.role == .user ? "You said: " : "Claude responded: "
                return .init(role: "AXGroup", subrole: "AXDocumentArticle", label: "Message \(index + 1) of \(messages.count)", children: [
                    .init(role: "AXHeading", label: prefix + message.text),
                    .init(role: "AXGroup", children: [.init(role: "AXStaticText", value: message.text)]),
                    .init(role: "AXToolbar", children: [.init(role: "AXButton", label: "Copy")])
                ])
            }
            let draft = stage == 1 ? prompt : stage == 0 ? initialDraft : ""
            let raw = collapseNativeBlankParagraphs && !draft.hasSuffix("\n") ? draft.components(separatedBy: "\n").filter { !$0.isEmpty }.joined(separator: "\n") : draft
            var controls: [ClaudeAXNode] = [
                .init(role: "AXTextArea", label: "Write your prompt to Claude", value: draft.isEmpty ? "\n" : raw, frame: fieldFrame, focused: true, children: draft.isEmpty ? [.init(role: "AXGroup", classes: ["is-empty", "is-editor-empty"])] : collapseNativeBlankParagraphs ? draft.components(separatedBy: "\n").map { line in .init(role: "AXGroup", children: line.isEmpty ? [] : [.init(role: "AXStaticText", value: line)]) } : []),
                .init(role: "AXGroup", label: "Chat messages", children: articles)
            ]
            if stage == 2 { controls.append(.init(role: "AXButton", label: "Stop")) }
            return try .init(root: .init(role: "AXWindow", frame: windowFrame, children: [
                .init(role: "AXWebArea", url: stage != 4 && (followup || sent) ? url : URL(string: "https://claude.ai/new")!, children: [.init(role: "AXGroup", subrole: "AXLandmarkMain", children: controls)])
            ]))
        }
        let observations = try (0...4).map(observation)
        let snapshots: [[String: Any]] = (0...4).map { stage in
            let draft = stage == 1 ? prompt : stage == 0 ? initialDraft : ""
            let raw = collapseNativeBlankParagraphs && !draft.hasSuffix("\n") ? draft.components(separatedBy: "\n").filter { !$0.isEmpty }.joined(separator: "\n") : draft
            var elements: [[String: Any]] = [
                ["role": "AXTextArea", "label": "Write your prompt to Claude", "value": draft.isEmpty ? "\n" : raw, "element_token": "composer-\(stage)", "enabled": true, "frame": ["x": 0, "y": 0, "w": 10, "h": 10]],
                ["role": "AXButton", "label": "New", "element_token": "new-\(stage)", "enabled": true]
            ]
            if omitEmptyDriverValue && stage == 0 { elements[0].removeValue(forKey: "value") }
            if stage == 1 { elements.append(["role": "AXButton", "label": "Send message", "element_token": "send-1", "enabled": true]) }
            if stage == 2 { elements.append(["role": "AXButton", "label": "Stop", "element_token": "stop-2", "enabled": true]) }
            return ["pid": wrongPID ? 99 : 42, "window_id": 21, "elements": elements, "window_bounds": ["x": 0, "y": 0, "width": 100, "height": 100]]
        }
        try JSONSerialization.data(withJSONObject: snapshots).write(to: dir.appendingPathComponent("snapshots.json"))
        try Data(prompt.utf8).write(to: dir.appendingPathComponent("prompt"))
        if followup { try Data().write(to: dir.appendingPathComponent("followup")) }
        if reopen { try Data("4".utf8).write(to: dir.appendingPathComponent("stage")) }
        if unknownLaunchResult { try Data().write(to: dir.appendingPathComponent("unknown-launch")) }
        if stripDriverTrailingNewlines { try Data().write(to: dir.appendingPathComponent("strip-driver-newlines")) }
        if corruptDriverTextAfterNewline { try Data().write(to: dir.appendingPathComponent("corrupt-driver-text")) }
        if collapseNativeBlankParagraphs { try Data().write(to: dir.appendingPathComponent("collapse-native-paragraphs")) }
        let script = """
        #!/usr/bin/env python3
        import sys,json,pathlib,time,base64
        p=pathlib.Path(__file__).parent
        tool=sys.argv[2];a=json.loads(sys.argv[3])
        with (p/'calls.jsonl').open('a') as f:f.write(json.dumps({'tool':tool,'arguments':a})+'\\n')
        s=int((p/'stage').read_text()) if (p/'stage').exists() else 0
        if tool=='list_apps':print(json.dumps({'apps':[{'bundle_id':'com.anthropic.claudefordesktop','pid':42,'running':True}]}))
        elif tool=='list_windows':
            assert a['pid']==42
            print(json.dumps({'windows':[{'window_id':21,'title':'Claude','is_on_screen':False,'on_current_space':False,'space_ids':[1],'bounds':{'width':1000,'height':900}}]}))
        elif tool=='launch_app':
            assert s==4
            assert a['bundle_id']=='com.anthropic.claudefordesktop'
            assert a['urls']==['claude://claude.ai/chat/00000000-0000-0000-0000-000000000001']
            assert 'https://' not in a['urls'][0]
            (p/'stage').write_text('0')
            if not (p/'unknown-launch').exists():print(json.dumps({'effect':'unverifiable'}))
        elif tool=='get_window_state':
            assert a['pid']==42 and a['window_id']==21
            state=json.loads((p/'snapshots.json').read_text())[s]
            if s==0 and (p/'draft').exists():
                actual=(p/'draft').read_text()
                state['elements'][0]['value']=actual
                if (p/'collapse-native-paragraphs').exists() and not actual.endswith('\\n'):state['elements'][0]['value']='\\n'.join(v for v in actual.split('\\n') if v)
                if (p/'strip-driver-newlines').exists():state['elements'][0]['value']=state['elements'][0]['value'].rstrip('\\n')
                if (p/'corrupt-driver-text').exists() and actual.endswith('\\n'):state['elements'][0]['value']=actual.rstrip('\\n')[:-1]
            if a['include_screenshot']:
                image=pathlib.Path(a['screenshot_out_file'])
                image.write_bytes(base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jN1sAAAAASUVORK5CYII='))
                state.update(screenshot_frame_valid=True,screenshot_width=1,screenshot_height=1,screenshot_file_path=str(image))
            print(json.dumps(state))
            if s==2 and (p/'followup').exists():(p/'stage').write_text('3')
        elif tool=='type_text':
            assert s==0
            assert a['pid']==42 and a['window_id']==21 and a['delivery_mode']=='background'
            assert 'element_token' not in a
            if not (p/'draft').exists():assert a['x']==0 and a['y']==0
            else:assert 'x' not in a and 'y' not in a
            draft=(p/'draft').read_text() if (p/'draft').exists() else ''
            draft+=a['text'].replace('\\n','')
            (p/'draft').write_text(draft)
            if draft==(p/'prompt').read_text():(p/'stage').write_text('1')
            print(json.dumps({'effect':'unverifiable'}))
        elif tool=='press_key':
            assert s==0 and a['key']=='return' and a['modifiers']==['shift']
            assert a['pid']==42 and a['window_id']==21 and a['delivery_mode']=='background'
            draft=(p/'draft').read_text() if (p/'draft').exists() else ''
            draft+='\\n'
            (p/'draft').write_text(draft)
            if draft==(p/'prompt').read_text():(p/'stage').write_text('1')
            print(json.dumps({'effect':'unverifiable'}))
        elif tool=='click':
            assert s==1 and a['element_token']=='send-1'
            assert a['pid']==42 and a['window_id']==21 and a['delivery_mode']=='background'
            (p/'stage').write_text('2');print(json.dumps({'effect':'unverifiable'}))
        elif tool=='end_session':print('{}')
        else:raise AssertionError('Unexpected tool '+tool)
        sys.stdout.flush();time.sleep(0.02)
        """
        let executable = dir.appendingPathComponent("driver")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return .init(directory: dir, executable: executable, binding: binding, observations: observations)
    }
    func testOnePromptAndOneSendPersistCanonicalURLBeforeAnswerCompletes() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let recorded = ClaudeRecordedBindings()
        let result = try await fixture.adapter().reply("First question", binding: fixture.binding, onPrepared: { await recorded.prepare($0) }, onBinding: { binding in
            XCTAssertEqual(try String(contentsOf: fixture.stage, encoding: .utf8), "2")
            // At this callback the adapter has observed the owned outgoing but
            // has not yet read the completed-answer observation at stage 3.
            await recorded.bind(binding)
            try Data("3".utf8).write(to: fixture.stage)
        })
        XCTAssertEqual(result, "ANSWER")
        let prepared = await recorded.prepared
        let bound = await recorded.bound
        XCTAssertEqual(prepared.count, 1)
        XCTAssertNil(prepared[0].url)
        XCTAssertEqual(bound.count, 1)
        XCTAssertTrue(ClaudeChatURL.isChat(bound[0].url!))
        XCTAssertEqual(fixture.calls().filter { $0["tool"] as? String == "type_text" }.count, 2)
        XCTAssertEqual(fixture.calls().filter { $0["tool"] as? String == "press_key" }.count, 2)
        XCTAssertEqual(fixture.calls().filter { $0["tool"] as? String == "click" }.count, 1)
        let input = fixture.calls().compactMap { call -> String? in
            guard let tool = call["tool"] as? String, let arguments = call["arguments"] as? [String: Any] else { return nil }
            if tool == "press_key" { return "\n" }
            if tool == "type_text" {
                let text = arguments["text"] as? String
                XCTAssertFalse(text?.contains("\n") ?? true)
                return text
            }
            return nil
        }.joined()
        XCTAssertEqual(input, fixture.binding.firstMessage("First question"))
    }
    func testTransientIncompleteHistoryAfterSendRetriesOnlyObservation() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let recorded = ClaudeRecordedBindings()
        let answer = try await fixture.adapter(transientAfterSend: true).reply("First question", binding: fixture.binding, onPrepared: { await recorded.prepare($0) }, onBinding: { saved in
            XCTAssertEqual(try String(contentsOf: fixture.stage, encoding: .utf8), "2")
            await recorded.bind(saved)
            try Data("3".utf8).write(to: fixture.stage)
        })
        XCTAssertEqual(answer, "ANSWER")
        let saved = await recorded.bound
        XCTAssertEqual(saved.count, 1)
        XCTAssertTrue(ClaudeChatURL.isChat(saved[0].url!))
        XCTAssertEqual(fixture.calls().filter { $0["tool"] as? String == "type_text" }.count, 2)
        XCTAssertEqual(fixture.calls().filter { $0["tool"] as? String == "press_key" }.count, 2)
        XCTAssertEqual(fixture.calls().filter { $0["tool"] as? String == "click" }.count, 1)
    }
    func testLongMultilinePromptUsesDisjointVerifiedChunks() async throws {
        let question = String(repeating: "A", count: 300) + "\nThird line"
        let fixture = try fixture(question: question)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let answer = try await fixture.adapter().reply(question, binding: fixture.binding, onPrepared: { _ in }, onBinding: { _ in try Data("3".utf8).write(to: fixture.stage) })
        XCTAssertEqual(answer, "ANSWER")
        let chunks = fixture.calls().filter { $0["tool"] as? String == "type_text" }.compactMap { ($0["arguments"] as? [String: Any])?["text"] as? String }
        XCTAssertEqual(chunks.count, 4)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 256 && !$0.contains("\n") })
        XCTAssertEqual(chunks[1].count, 256)
        XCTAssertEqual(chunks[2].count, 44)
        XCTAssertEqual(fixture.calls().filter { $0["tool"] as? String == "press_key" }.count, 3)
        XCTAssertEqual(fixture.calls().filter { $0["tool"] as? String == "click" }.count, 1)
    }
    func testNativeEmptyParagraphsPreserveNonceAndUserBlankLinesThroughSend() async throws {
        let question = "First line\n\nThird line"
        let fixture = try fixture(question: question, collapseNativeBlankParagraphs: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let answer = try await fixture.adapter().reply(question, binding: fixture.binding, onPrepared: { _ in }, onBinding: { saved in
            XCTAssertEqual(saved.firstPrompt, fixture.binding.firstMessage(question))
            try Data("3".utf8).write(to: fixture.stage)
        })
        XCTAssertEqual(answer, "ANSWER")
        XCTAssertEqual(try String(contentsOf: fixture.directory.appendingPathComponent("draft"), encoding: .utf8), fixture.binding.firstMessage(question))
        XCTAssertEqual(fixture.calls().filter { $0["tool"] as? String == "press_key" }.count, 4)
        XCTAssertEqual(fixture.calls().filter { $0["tool"] as? String == "click" }.count, 1)
    }
    func testDriverOmittedTerminalNewlinesPreserveExactNativePrompt() async throws {
        let question = "First question\nSecond line"
        let fixture = try fixture(question: question, stripDriverTrailingNewlines: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let answer = try await fixture.adapter().reply(question, binding: fixture.binding, onPrepared: { _ in }, onBinding: { _ in try Data("3".utf8).write(to: fixture.stage) })
        XCTAssertEqual(answer, "ANSWER")
        XCTAssertEqual(try String(contentsOf: fixture.directory.appendingPathComponent("draft"), encoding: .utf8), fixture.binding.firstMessage(question))
        XCTAssertEqual(fixture.calls().filter { $0["tool"] as? String == "press_key" }.count, 3)
        XCTAssertEqual(fixture.calls().filter { $0["tool"] as? String == "click" }.count, 1)
    }
    func testNonwhitespaceDriverDisagreementAfterNewlinePreventsSend() async throws {
        let fixture = try fixture(stripDriverTrailingNewlines: true, corruptDriverTextAfterNewline: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        do {
            _ = try await fixture.adapter().reply("First question", binding: fixture.binding, onPrepared: { _ in }, onBinding: { _ in XCTFail("No submitted conversation") })
            XCTFail("Different nonwhitespace text must stop")
        } catch { XCTAssertTrue(error.localizedDescription.contains("draft")) }
        XCTAssertEqual(fixture.calls().filter { $0["tool"] as? String == "type_text" }.count, 1)
        XCTAssertEqual(fixture.calls().filter { $0["tool"] as? String == "press_key" }.count, 1)
        XCTAssertTrue(fixture.calls().allSatisfy { $0["tool"] as? String != "click" })
    }
    func testEmptyDriverValueCanBeOmittedWhenNativeEmptyEditorIsVerified() async throws {
        let fixture = try fixture(omitEmptyDriverValue: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let binding = try await fixture.adapter().prepare(comparisonID: fixture.binding.comparisonID, binding: nil)
        XCTAssertEqual(binding, fixture.binding)
        XCTAssertTrue(fixture.calls().allSatisfy { !["type_text", "click"].contains($0["tool"] as? String ?? "") })
    }
    func testOmittedDriverValueDoesNotHideNativeNonemptyDraft() async throws {
        let fixture = try fixture(initialDraft: "Preserve native draft", omitEmptyDriverValue: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        do {
            _ = try await fixture.adapter().prepare(comparisonID: fixture.binding.comparisonID, binding: nil)
            XCTFail("Native draft must prevent preparation")
        } catch { XCTAssertTrue(error.localizedDescription.contains("draft")) }
        XCTAssertTrue(fixture.calls().allSatisfy { !["type_text", "click"].contains($0["tool"] as? String ?? "") })
    }
    func testSavedConversationFollowupUsesUnprefixedPrompt() async throws {
        let fixture = try fixture(followup: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let result = try await fixture.adapter().reply("Follow-up", binding: fixture.binding, onPrepared: { _ in }, onBinding: { _ in XCTFail("Existing binding must not be reassigned") })
        XCTAssertEqual(result, "ANSWER")
        let typed = fixture.calls().filter { $0["tool"] as? String == "type_text" }
        XCTAssertEqual((typed.first?["arguments"] as? [String: Any])?["text"] as? String, "Follow-up")
    }
    func testSavedConversationReopensThroughExactNativeURIThenSendsUnprefixed() async throws {
        let fixture = try fixture(followup: true, reopen: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let result = try await fixture.adapter().reply("Follow-up", binding: fixture.binding, onPrepared: { _ in }, onBinding: { _ in XCTFail("Existing binding must not change") })
        XCTAssertEqual(result, "ANSWER")
        let calls = fixture.calls()
        XCTAssertEqual(calls.filter { $0["tool"] as? String == "launch_app" }.count, 1)
        XCTAssertEqual(calls.filter { $0["tool"] as? String == "type_text" }.count, 1)
        let launchIndex = try XCTUnwrap(calls.firstIndex { $0["tool"] as? String == "launch_app" })
        let typeIndex = try XCTUnwrap(calls.firstIndex { $0["tool"] as? String == "type_text" })
        XCTAssertLessThan(launchIndex, typeIndex)
    }
    func testUnknownNativeURIReceiptObservesResultWithoutLaunchingAgain() async throws {
        let fixture = try fixture(followup: true, reopen: true, unknownLaunchResult: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let result = try await fixture.adapter().reply("Follow-up", binding: fixture.binding, onPrepared: { _ in }, onBinding: { _ in XCTFail("Existing binding must not change") })
        XCTAssertEqual(result, "ANSWER")
        XCTAssertEqual(fixture.calls().filter { $0["tool"] as? String == "launch_app" }.count, 1)
        XCTAssertEqual(fixture.calls().filter { $0["tool"] as? String == "type_text" }.count, 1)
        XCTAssertEqual(fixture.calls().filter { $0["tool"] as? String == "press_key" }.count, 0)
        XCTAssertEqual(fixture.calls().filter { $0["tool"] as? String == "click" }.count, 1)
    }
    func testNativeURIWithForeignFirstPromptNeverTypesOrSends() async throws {
        let fixture = try fixture(followup: true, reopen: true, foreignResume: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        do {
            _ = try await fixture.adapter().reply("Follow-up", binding: fixture.binding, onPrepared: { _ in XCTFail("Foreign chat must not reserve") }, onBinding: { _ in XCTFail("Foreign chat must not bind") })
            XCTFail("Wrong saved conversation must stop")
        } catch { XCTAssertTrue(error.localizedDescription.contains("first message")) }
        XCTAssertEqual(fixture.calls().filter { $0["tool"] as? String == "launch_app" }.count, 1)
        XCTAssertTrue(fixture.calls().allSatisfy { !["type_text", "click"].contains($0["tool"] as? String ?? "") })
    }
    func testPendingRestartDoesNotCreateReplacementOrTypeAgain() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var pending = fixture.binding
        pending.firstPrompt = pending.firstMessage("Previously attempted")
        let restored = try JSONDecoder().decode(ClaudeConversationBinding.self, from: JSONEncoder().encode(pending))
        do {
            _ = try await fixture.adapter().reply("Try again", binding: restored, onPrepared: { _ in XCTFail("Must not reserve again") }, onBinding: { _ in XCTFail("No replacement") })
            XCTFail("Pending first send must stop")
        } catch { XCTAssertTrue(error.localizedDescription.contains("unresolved")) }
        XCTAssertTrue(fixture.calls().allSatisfy { !["type_text", "click"].contains($0["tool"] as? String ?? "") })
    }
    func testForeignOutgoingNeverBindsOrAttributesReply() async throws {
        let fixture = try fixture(foreignOutgoing: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        do {
            _ = try await fixture.adapter().reply("First question", binding: fixture.binding, onPrepared: { _ in }, onBinding: { _ in XCTFail("Foreign chat cannot bind") })
            XCTFail("Foreign outgoing must stop")
        } catch { XCTAssertTrue(error.localizedDescription.contains("first prompt")) }
        XCTAssertEqual(fixture.calls().filter { $0["tool"] as? String == "type_text" }.count, 2)
        XCTAssertEqual(fixture.calls().filter { $0["tool"] as? String == "press_key" }.count, 2)
        XCTAssertEqual(fixture.calls().filter { $0["tool"] as? String == "click" }.count, 1)
    }
    func testWrongDriverWindowPreventsAllInput() async throws {
        let fixture = try fixture(wrongPID: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        do {
            _ = try await fixture.adapter().reply("First question", binding: fixture.binding, onPrepared: { _ in XCTFail("Wrong target must not reserve") }, onBinding: { _ in XCTFail("Wrong target cannot bind") })
            XCTFail("Wrong target must stop")
        } catch { XCTAssertTrue(error.localizedDescription.contains("different window")) }
        XCTAssertTrue(fixture.calls().allSatisfy { !["type_text", "click"].contains($0["tool"] as? String ?? "") })
    }
    func testExistingDraftIsPreservedBeforePendingBinding() async throws {
        let fixture = try fixture(initialDraft: "Keep my draft")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        do {
            _ = try await fixture.adapter().reply("First question", binding: fixture.binding, onPrepared: { _ in XCTFail("Draft must not reserve") }, onBinding: { _ in XCTFail("Draft cannot bind") })
            XCTFail("Draft must stop")
        } catch { XCTAssertTrue(error.localizedDescription.contains("unsent draft")) }
        XCTAssertTrue(fixture.calls().allSatisfy { !["type_text", "click"].contains($0["tool"] as? String ?? "") })
    }
}
