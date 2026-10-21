import XCTest
@testable import msgblastCore

final class GeminiAppConversationTests: XCTestCase {
    private func row(_ children: [GeminiAXNode]) -> GeminiAXNode {
        .init(role: "AXRow", children: [.init(role: "AXCell", children: [.init(role: "AXGroup", children: children)])])
    }
    private func tree(rows: [GeminiAXNode] = [], mode: GeminiMode? = .chat, draft: String = "", generating: Bool = false) -> GeminiAXNode {
        var controls: [GeminiAXNode] = [
            .init(role: "AXScrollArea", children: [.init(role: "AXTextArea", label: mode == .task ? "Assign a task" : "Ask Gemini", value: draft)]),
            .init(role: "AXButton", label: "Argon, Choose model"),
            .init(role: "AXScrollArea", children: [.init(role: "AXGroup", children: rows)])
        ]
        if let mode { controls.append(.init(role: "AXButton", label: mode.name, id: mode == .chat ? "chat-input-mode-ask" : "chat-input-mode-assign", selected: true)) }
        if generating { controls.append(.init(role: "AXButton", label: "Stop response", id: "stop_button")) }
        return .init(role: "AXWindow", label: "Gemini — New chat", children: [.init(role: "AXSplitGroup", children: [
            .init(role: "AXGroup", children: [.init(role: "AXHeading", label: "Private sidebar title")]),
            .init(role: "AXGroup", children: controls)
        ])])
    }
    func testTaskProgressAndSidebarAreNotAnswers() throws {
        let outgoing = row([.init(role: "AXHeading", label: "Echo this")])
        let progress = row([.init(role: "AXHeading", label: "Thinking it through")])
        let working = try GeminiAppObservation(root: tree(rows: [outgoing, progress], mode: nil, generating: true))
        XCTAssertTrue(working.generating)
        XCTAssertEqual(working.messages, [.init(role: .user, text: "Echo this")])
        let answer = row([
            .init(role: "AXHeading", label: "Completed"),
            .init(role: "AXStaticText", label: "ANSWER\n", value: "ANSWER"),
            .init(role: "AXGroup", children: [.init(role: "AXButton", label: "Copy response", id: "copy-button")]),
            .init(role: "AXStaticText", value: "Argon can take up more usage")
        ])
        let complete = try GeminiAppObservation(root: tree(rows: [outgoing, answer], mode: nil))
        XCTAssertFalse(complete.generating)
        XCTAssertEqual(complete.messages, [.init(role: .user, text: "Echo this"), .init(role: .assistant, text: "ANSWER")])
    }
    func testConsecutiveOutgoingMessagesRemainVisibleToReceiptChecks() throws {
        let first = row([.init(role: "AXHeading", label: "This request")])
        let foreign = row([.init(role: "AXHeading", label: "Another outgoing request")])
        let answer = row([.init(role: "AXStaticText", label: "Answer\n", value: "Answer"), .init(role: "AXButton", id: "copy-button")])
        let observed = try GeminiAppObservation(root: tree(rows: [first, foreign, answer], mode: nil))
        XCTAssertEqual(observed.messages, [.init(role: .user, text: "This request"), .init(role: .user, text: "Another outgoing request"), .init(role: .assistant, text: "Answer")])
    }
    func testDraftIsActualValueRatherThanPlaceholder() throws {
        for draft in ["", "Ask Gemini", "Assign a task", "Keep my unsent draft"] {
            XCTAssertEqual(try GeminiAppObservation(root: tree(mode: .task, draft: draft)).draft, draft)
        }
        var unknown = tree()
        unknown.children[0].children[1].children[0].children[0].value = nil
        XCTAssertThrowsError(try GeminiAppObservation(root: unknown))
    }
    func testUnknownCompletedLayoutIsRefusedInsteadOfReturningStatus() {
        let unknown = row([.init(role: "AXHeading", label: "Completed"), .init(role: "AXButton", label: "Copy response", id: "copy-button")])
        XCTAssertThrowsError(try GeminiAppObservation(root: tree(rows: [unknown], mode: nil)))
    }
    func testBindingMigrationAndInterruptedFirstSubmissionSurviveReload() throws {
        var state = WebWorkspaceState()
        let id = UUID()
        state.draft = "Keep draft"
        var binding = GeminiConversationBinding(comparisonID: id, mode: .task)
        binding.firstPrompt = "One send only"
        try state.recordGeminiBinding(binding)
        state.geminiComparisonPreferences[id.uuidString] = .init(mode: .task, model: "4 Argon, Complex tasks")
        let restored = try JSONDecoder().decode(WebWorkspaceState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(try restored.geminiBinding(for: id), binding)
        XCTAssertEqual(restored.draft, "Keep draft")
        XCTAssertEqual(restored.geminiComparisonPreferences[id.uuidString]?.mode, .task)
        let old = Data("{\"sessionID\":\"\(UUID())\",\"draft\":\"Old draft\"}".utf8)
        let legacy = try JSONDecoder().decode(WebWorkspaceState.self, from: old)
        XCTAssertTrue(legacy.geminiConversations.isEmpty)
        XCTAssertEqual(legacy.geminiPreferences, .init())
        XCTAssertEqual(legacy.draft, "Old draft")
    }
    func testBoundModeAndFirstPromptCannotBeReassigned() throws {
        var state = WebWorkspaceState()
        let id = UUID()
        var first = GeminiConversationBinding(comparisonID: id, mode: .task)
        first.firstPrompt = "Original"
        first.title = first.dedicatedTitle
        try state.recordGeminiBinding(first)
        var changed = GeminiConversationBinding(comparisonID: id, mode: .chat)
        changed.firstPrompt = "Different"
        XCTAssertThrowsError(try state.recordGeminiBinding(changed))
        XCTAssertEqual(try state.geminiBinding(for: id), first)
        let other = UUID()
        state.geminiConversations[other.uuidString] = first
        XCTAssertThrowsError(try state.geminiBinding(for: id))
    }
    func testNativeGeminiHasIndependentStorageAndNoWebAdapter() {
        XCTAssertEqual(WebProvider.geminiApp.desktopApp, .gemini)
        XCTAssertTrue(WebProvider.geminiApp.usesNativeConversation)
        XCTAssertFalse(WebProvider.geminiApp.sharesOneConversation)
        XCTAssertFalse(WebProvider.geminiApp.isChatURL(URL(string: "https://gemini.google/mac")!))
        XCTAssertEqual(OnboardingChoice.geminiApp.provider, .geminiApp)
        XCTAssertNotEqual(WebProvider.geminiApp.storageFilename, WebProvider.chatgpt.storageFilename)
    }

    @MainActor
    func testComparisonModeLocksAfterFirstPromptAndChoicesPersistSeparately() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = WebAgentSession(provider: .geminiApp, storageURL: directory.appendingPathComponent("state.json"), fixture: true)
        session.setEnabled(true)
        await session.connectDesktopConversation()
        await session.configureGemini(.init(mode: .chat, model: "4 Argon, Complex tasks"))
        XCTAssertEqual(session.geminiOptions.thinkingLevels.count, 3)
        XCTAssertEqual(session.geminiPreferences.thinking, "Low, Quick and efficient")
        let id = UUID()
        _ = await session.openComparison(id)
        await session.configureGemini(.init(mode: .task, model: "4 Argon, Complex tasks"))
        XCTAssertEqual(session.geminiPreferences.mode, .task)
        XCTAssertTrue(session.geminiOptions.thinkingLevels.isEmpty)
        let attempt = await session.send("Synthetic Task prompt", comparisonID: id)
        XCTAssertEqual(attempt?.status, .observed)
        XCTAssertTrue(session.geminiModeLocked)
        await session.configureGemini(.init(mode: .chat))
        XCTAssertEqual(session.geminiPreferences.mode, .task)
        _ = await session.openComparison(UUID())
        XCTAssertFalse(session.geminiModeLocked)
        XCTAssertEqual(session.geminiPreferences.mode, .chat)
        _ = await session.openComparison(id)
        XCTAssertEqual(session.geminiPreferences.mode, .task)
        XCTAssertEqual(session.state.geminiConversations[id.uuidString]?.title, "msgblast \(id.uuidString)")
        session.beginShutdown()
    }
}

final class GeminiAppDriverTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let executable: URL
        let observations: [GeminiAppObservation]
        var log: URL { directory.appendingPathComponent("calls.jsonl") }
        var stage: URL { directory.appendingPathComponent("stage") }
        func calls() -> [[String: Any]] {
            (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? []
        }
    }
    private func fixture(foreignPrompt: Bool = false, driverPID: Int = 42) throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID(uuidString: "AA000000-0000-0000-0000-000000000001")!
        let binding = GeminiConversationBinding(comparisonID: id, mode: .chat)
        let prompt = binding.firstMessage("Echo check")
        func control(_ role: String, _ label: String, _ id: String, _ x: Double, value: String? = nil, selected: Bool = false, selectedText: String? = nil) -> GeminiAXNode {
            .init(role: role, label: label, value: value, id: id, selected: selected, selectedText: selectedText, frame: .init(x: x, y: 10, w: 30, h: 20))
        }
        let model = control("AXButton", "Flash, Choose model", "model", 50)
        let choice = control("AXButton", "3.8 Flash, All-around help", "", 80, selected: true)
        let send = control("AXButton", "Submit", "send_button", 110)
        let more = control("AXButton", "More actions", "more_button", 140)
        func row(_ children: [GeminiAXNode]) -> GeminiAXNode { .init(role: "AXRow", children: [.init(role: "AXCell", children: [.init(role: "AXGroup", children: children)])]) }
        let messages = [row([.init(role: "AXHeading", label: foreignPrompt ? "Another prompt" : prompt)]),
                        row([.init(role: "AXStaticText", label: "ECHO-OK\n", value: "ECHO-OK"), .init(role: "AXButton", label: "Copy response", id: "copy-button")])]
        var roots: [GeminiAXNode] = []
        // Independently specified application states at each mutation boundary:
        // picker open/closed twice, prepared prompt, sent reply, Rename, Confirm.
        for stage in 0...10 {
            let hasReply = stage >= 6
            var main = [control("AXTextArea", "Ask Gemini", "", 10, value: stage == 5 ? prompt : ""), model]
            if stage < 6 { main.append(control("AXButton", "Chat", "chat-input-mode-ask", 170, selected: true)) }
            if [1, 3].contains(stage) { main.append(.init(role: "AXPopover", children: [choice])) }
            if stage == 5 { main.append(send) }
            if hasReply { main += [more, .init(role: "AXScrollArea", children: [.init(role: "AXGroup", children: messages)])] }
            if stage == 7 { main.append(control("AXMenuItem", "Rename", "", 200)) }
            let title = stage == 10 ? binding.dedicatedTitle : hasReply ? "Automatic title" : "New chat"
            var root = GeminiAXNode(role: "AXWindow", label: "Gemini — \(title)", children: [.init(role: "AXSplitGroup", children: [
                .init(role: "AXGroup", children: stage == 10 ? [control("AXButton", title, "", 230)] : []),
                .init(role: "AXGroup", children: main)
            ])])
            if [8, 9].contains(stage) {
                root.children.append(.init(role: "AXSheet", children: [
                    control("AXTextField", "", "", 260, value: stage == 8 ? "Automatic title" : binding.dedicatedTitle, selectedText: stage == 8 ? "Automatic title" : ""),
                    control("AXButton", "Confirm", "", 290)
                ]))
            }
            roots.append(root)
        }
        let observations = try roots.map { try GeminiAppObservation(root: $0, allowingRename: true) }
        try snapshotData(roots, driverPID: driverPID).write(to: dir.appendingPathComponent("snapshots.json"))
        let actions: [[String: String]] = [
            ["tool": "click", "role": "AXButton", "label": "Flash, Choose model"],
            ["tool": "click", "role": "AXButton", "label": "3.8 Flash, All-around help"],
            ["tool": "click", "role": "AXButton", "label": "Flash, Choose model"],
            ["tool": "click", "role": "AXButton", "label": "3.8 Flash, All-around help"],
            ["tool": "type_text", "role": "AXTextArea", "label": "Ask Gemini", "text": prompt],
            ["tool": "click", "role": "AXButton", "label": "Submit"],
            ["tool": "click", "role": "AXButton", "label": "More actions"],
            ["tool": "click", "role": "AXMenuItem", "label": "Rename"],
            ["tool": "type_text", "role": "AXTextField", "label": "", "text": binding.dedicatedTitle],
            ["tool": "click", "role": "AXButton", "label": "Confirm"]
        ]
        try JSONSerialization.data(withJSONObject: actions).write(to: dir.appendingPathComponent("actions.json"))
        let executable = dir.appendingPathComponent("driver")
        try Data("""
        #!/usr/bin/env python3
        import sys,json,pathlib
        p=pathlib.Path(__file__).parent
        tool=sys.argv[2];args=json.loads(sys.argv[3])
        with (p/'calls.jsonl').open('a') as f:f.write(json.dumps({'tool':tool,'arguments':args})+'\\n')
        s=int((p/'stage').read_text()) if (p/'stage').exists() else 0
        if tool=='list_apps': print(json.dumps({'apps':[{'bundle_id':'com.google.GeminiMacOS','pid':42,'running':True}]}))
        elif tool=='list_windows': print(json.dumps({'windows':[{'window_id':21,'title':'','is_on_screen':False,'on_current_space':False,'space_ids':[1],'bounds':{'width':1000,'height':900}}]}))
        elif tool=='get_window_state': print(json.dumps(json.loads((p/'snapshots.json').read_text())[s]))
        elif tool in ['click','type_text']:
            expected=json.loads((p/'actions.json').read_text())[s]
            candidates=[e for e in json.loads((p/'snapshots.json').read_text())[s]['elements'] if e['role']==expected['role'] and e['label']==expected['label']]
            assert len(candidates)==1
            assert tool==expected['tool'] and args['element_token']==candidates[0]['element_token']
            assert args['pid']==42 and args['window_id']==21 and args['delivery_mode']=='background'
            if tool=='type_text':assert args['text']==expected['text']
            (p/'stage').write_text(str(s+1))
            if s!=5:print(json.dumps({'effect':'unverifiable'}))
        else: print('{}')
        sys.stdout.flush()
        import time;time.sleep(0.02)
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return .init(directory: dir, executable: executable, observations: observations)
    }
    private func snapshotData(_ roots: [GeminiAXNode], driverPID: Int = 42) throws -> Data {
        let snapshots: [[String: Any]] = roots.enumerated().map { stage, root in
            let elements: [[String: Any]] = root.descendants.enumerated().compactMap { index, n in
                guard let f = n.frame else { return nil }
                return ["role": n.role, "label": n.label, "element_token": "s\(stage):\(index)", "enabled": true,
                        "frame": ["x": f.x, "y": f.y, "w": f.w, "h": f.h]]
            }
            return ["pid": driverPID, "window_id": 21, "elements": elements]
        }
        return try JSONSerialization.data(withJSONObject: snapshots)
    }
    private func scenario(_ roots: [GeminiAXNode], actions: [[String: String]], in fixture: Fixture) throws -> Fixture {
        try snapshotData(roots).write(to: fixture.directory.appendingPathComponent("snapshots.json"))
        try JSONSerialization.data(withJSONObject: actions).write(to: fixture.directory.appendingPathComponent("actions.json"))
        return .init(directory: fixture.directory, executable: fixture.executable, observations: try roots.map { try GeminiAppObservation(root: $0, allowingRename: true) })
    }
    private func adapter(_ fixture: Fixture, navigateBeforeTyping: Bool = false, failReadAfterSendOnce: Bool = false, failRenameReadOnce: Bool = false, failRenamePermanently: Bool = false, cancelDuringRename: Bool = false) -> GeminiAppConversation {
        let race = NavigationRace()
        let fault = NativeReadFault()
        return GeminiAppConversation(executable: fixture.executable, timing: .init(pollInterval: .milliseconds(1), stableDuration: .zero, replyTimeout: .seconds(2), callTimeout: 3), readNative: { target, _ in
            guard target == .init(pid: 42, window: 21) else { throw DesktopAppError.unavailable("Wrong exact window") }
            let stage = Int((try? String(contentsOf: fixture.stage, encoding: .utf8)) ?? "0") ?? 0
            if failReadAfterSendOnce, fault.shouldFail(stage: stage, at: 6) { throw GeminiObservationError.transient("Gemini’s accessibility tree is incomplete.") }
            if failRenameReadOnce, fault.shouldFail(stage: stage, at: 8) { throw GeminiObservationError.transient("Gemini’s exact window is unavailable during the Rename transition.") }
            if stage >= 7, failRenamePermanently { throw DesktopAppError.unavailable("Gemini's Rename is permanently unavailable") }
            if stage >= 7, cancelDuringRename { throw CancellationError() }
            if navigateBeforeTyping, race.shouldNavigate(stage: stage) {
                var root = fixture.observations[stage].root
                root.label = "Gemini — Another conversation"
                root.children[0].children[1].children.removeAll { $0.id == "chat-input-mode-ask" }
                return try GeminiAppObservation(root: root)
            }
            return fixture.observations[stage]
        })
    }
    func testOneBackgroundSubmissionIsAttributedAndBoundDespiteUnknownClickResponse() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let id = UUID(uuidString: "AA000000-0000-0000-0000-000000000001")!
        let saved = BindingRecorder()
        let answer = try await adapter(f).reply("Echo check", binding: .init(comparisonID: id, mode: .chat), preferences: .init(), onPrepared: { _ in }) { await saved.record($0) }
        XCTAssertEqual(answer, "ECHO-OK")
        let result = await saved.value
        XCTAssertEqual(result?.title, "msgblast \(id.uuidString)")
        XCTAssertEqual(result?.firstPrompt, "[msgblast comparison \(id.uuidString)]\n\nEcho check")
        let calls = f.calls()
        XCTAssertEqual(calls.filter { $0["tool"] as? String == "type_text" }.count, 2, "One prompt and one Rename edit")
        let submits = calls.filter { call in
            guard call["tool"] as? String == "click", let args = call["arguments"] as? [String: Any] else { return false }
            return (args["element_token"] as? String)?.hasPrefix("s5:") == true
        }
        XCTAssertEqual(submits.count, 1)
        for call in calls where ["click", "type_text"].contains(call["tool"] as? String ?? "") {
            let args = call["arguments"] as? [String: Any]
            XCTAssertEqual(args?["delivery_mode"] as? String, "background")
            XCTAssertEqual(args?["pid"] as? Int, 42)
            XCTAssertEqual(args?["window_id"] as? Int, 21)
        }
    }
    func testForeignOutgoingCannotBecomeReplyOrBinding() async throws {
        let f = try fixture(foreignPrompt: true); defer { try? FileManager.default.removeItem(at: f.directory) }
        do {
            _ = try await adapter(f).reply("Echo check", binding: .init(comparisonID: UUID(uuidString: "AA000000-0000-0000-0000-000000000001")!, mode: .chat), preferences: .init(), onPrepared: { _ in }) { _ in XCTFail("Foreign conversation must not be bound") }
            XCTFail("Expected attribution refusal")
        } catch { XCTAssertTrue(error.localizedDescription.contains("outgoing message")) }
        XCTAssertEqual(f.calls().filter { $0["tool"] as? String == "type_text" }.count, 1)
    }
    func testAlreadySelectedModelNeedsOnlyOnePickerRoundTrip() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let (selected, options) = try await adapter(f).prepare(binding: nil, preferences: .init(model: "3.8 Flash, All-around help"))
        XCTAssertEqual(selected.model, "3.8 Flash, All-around help")
        XCTAssertEqual(options.models, ["3.8 Flash, All-around help"])
        XCTAssertEqual(f.calls().filter { $0["tool"] as? String == "click" }.count, 2, "Open the picker, verify its selected model, close it once")
        XCTAssertFalse(f.calls().contains { $0["tool"] as? String == "type_text" })
    }
    func testNavigationAfterBaselineCannotReceiveEvenPreparedText() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        do {
            _ = try await adapter(f, navigateBeforeTyping: true).reply("Echo check", binding: .init(comparisonID: UUID(uuidString: "AA000000-0000-0000-0000-000000000001")!, mode: .chat), preferences: .init(), onPrepared: { _ in }) { _ in XCTFail("Wrong chat must not bind") }
            XCTFail("Expected navigation refusal")
        } catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        XCTAssertFalse(f.calls().contains { $0["tool"] as? String == "type_text" }, "A prompt must never enter the chat selected after the captured baseline")
    }
    private final class NavigationRace: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        private var navigated = false
        func shouldNavigate(stage: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if stage == 4 { reads += 1; if reads >= 3 { navigated = true } }
            return navigated
        }
    }
    @MainActor
    func testUnavailableModelDoesNotReserveAnUnsubmittedConversation() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let id = UUID()
        let session = WebAgentSession(provider: .geminiApp, storageURL: f.directory.appendingPathComponent("session.json"), fixture: false,
                                      museApp: .shared, desktopApps: .demo, desktopDriver: DesktopAppConversation(executable: f.executable), geminiApp: adapter(f))
        session.setEnabled(true)
        session.updateState {
            $0.comparisonID = id
            $0.geminiComparisonPreferences[id.uuidString] = .init(model: "Unavailable saved model")
        }
        await session.connectDesktopConversation()
        let attempt = await session.send("Echo check", comparisonID: id)
        XCTAssertTrue(attempt?.detail?.contains("selected model isn’t available") == true)
        XCTAssertNil(try session.state.geminiBinding(for: id), "A configuration failure before input must not lock the comparison to an interrupted submission")
        XCTAssertEqual(attempt?.status, .notSent)
        XCTAssertEqual(session.geminiOptions.models, ["3.8 Flash, All-around help"])
        await session.configureGemini(.init(model: "3.8 Flash, All-around help"))
        XCTAssertTrue(session.snapshot.ready)
        XCTAssertEqual(session.state.comparisonID, id)
        XCTAssertEqual(session.geminiPreferences.model, "3.8 Flash, All-around help")
        XCTAssertNil(try session.state.geminiBinding(for: id))
        XCTAssertFalse(f.calls().contains { $0["tool"] as? String == "type_text" })
        session.beginShutdown()
    }
    func testTransientNativeReadAfterSubmissionDoesNotReplayOrAbandonReply() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let saved = BindingRecorder()
        let result: String
        do {
            result = try await adapter(f, failReadAfterSendOnce: true).reply("Echo check", binding: .init(comparisonID: UUID(uuidString: "AA000000-0000-0000-0000-000000000001")!, mode: .chat), preferences: .init(), onPrepared: { _ in }) { await saved.record($0) }
        } catch {
            XCTFail("Native read recovery failed after calls: \(f.calls().compactMap { $0["tool"] as? String }); stage: \((try? String(contentsOf: f.stage, encoding: .utf8)) ?? "missing"); error: \(error.localizedDescription)")
            return
        }
        XCTAssertEqual(result, "ECHO-OK")
        let binding = await saved.value
        XCTAssertNotNil(binding?.title)
        XCTAssertEqual(f.calls().filter { $0["tool"] as? String == "type_text" }.count, 2, "Only the original prompt and Rename field may be typed")
    }
    func testRenameWindowTransitionRecoversWithoutReplayingSubmissionOrRename() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let saved = BindingRecorder()
        let answer = try await adapter(f, failRenameReadOnce: true).reply("Echo check", binding: .init(comparisonID: UUID(uuidString: "AA000000-0000-0000-0000-000000000001")!, mode: .chat), preferences: .init(), onPrepared: { _ in }) { await saved.record($0) }
        XCTAssertEqual(answer, "ECHO-OK")
        let binding = await saved.value
        XCTAssertEqual(binding?.title, "msgblast AA000000-0000-0000-0000-000000000001")
        XCTAssertEqual(f.calls().filter { $0["tool"] as? String == "type_text" }.count, 2)
        XCTAssertEqual(try String(contentsOf: f.stage, encoding: .utf8), "10", "Each expected mutation happened exactly once")
    }
    private final class NativeReadFault: @unchecked Sendable {
        private let lock = NSLock()
        private var failed = false
        func shouldFail(stage: Int, at expectedStage: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if stage == expectedStage, !failed { failed = true; return true }
            return false
        }
    }
    private func savedConversationScenario(_ binding: GeminiConversationBinding, foreignFirst: Bool = false) throws -> Fixture {
        let base = try fixture()
        let menu = base.observations[1].nodes.first { $0.role == "AXPopover" }!
        let submit = try base.observations[5].control(id: "send_button")
        var roots: [GeminiAXNode] = []
        for stage in 0...5 {
            var root = base.observations[10].root
            let visibleTitle = binding.fallbackTitle ?? binding.dedicatedTitle
            root.label = "Gemini — \(visibleTitle)"
            root.children[0].children[0].children[0].label = visibleTitle
            if stage == 0 { root.label = "Gemini — Another conversation" }
            if foreignFirst {
                let transcript = root.children[0].children[1].children.firstIndex { $0.role == "AXScrollArea" }!
                root.children[0].children[1].children[transcript].children[0].children[0].children[0].children[0].children[0].label = "Foreign first prompt"
            }
            if stage == 2 { root.children[0].children[1].children.append(menu) }
            if stage == 4 {
                root.children[0].children[1].children[0].value = "Follow up"
                root.children[0].children[1].children.append(submit)
            }
            if stage == 5 {
                let user = GeminiAXNode(role: "AXRow", children: [.init(role: "AXCell", children: [.init(role: "AXGroup", children: [.init(role: "AXHeading", label: "Follow up")])])])
                let answer = GeminiAXNode(role: "AXRow", children: [.init(role: "AXCell", children: [.init(role: "AXGroup", children: [.init(role: "AXStaticText", label: "FOLLOWUP-OK\n", value: "FOLLOWUP-OK"), .init(role: "AXButton", id: "copy-button")])])])
                let transcript = root.children[0].children[1].children.firstIndex { $0.role == "AXScrollArea" }!
                root.children[0].children[1].children[transcript].children[0].children += [user, answer]
            }
            roots.append(root)
        }
        return try scenario(roots, actions: [
            ["tool": "click", "role": "AXButton", "label": binding.fallbackTitle ?? binding.dedicatedTitle],
            ["tool": "click", "role": "AXButton", "label": "Flash, Choose model"],
            ["tool": "click", "role": "AXButton", "label": "3.8 Flash, All-around help"],
            ["tool": "type_text", "role": "AXTextArea", "label": "Ask Gemini", "text": "Follow up"],
            ["tool": "click", "role": "AXButton", "label": "Submit"]
        ], in: base)
    }
    func testSavedConversationReopensAndFollowUpHasNoFirstMessageReference() async throws {
        let id = UUID(uuidString: "AA000000-0000-0000-0000-000000000001")!
        var binding = GeminiConversationBinding(comparisonID: id, mode: .chat)
        binding.firstPrompt = binding.firstMessage("Echo check")
        binding.title = binding.dedicatedTitle
        let f = try savedConversationScenario(binding)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let saved = BindingRecorder()
        let answer = try await adapter(f).reply("Follow up", binding: binding, preferences: .init(model: "3.8 Flash, All-around help"), onPrepared: { await saved.record($0) }) { await saved.record($0) }
        XCTAssertEqual(answer, "FOLLOWUP-OK")
        let result = await saved.value
        XCTAssertEqual(result, binding)
        XCTAssertEqual(f.calls().filter { $0["tool"] as? String == "type_text" }.compactMap { ($0["arguments"] as? [String: Any])?["text"] as? String }, ["Follow up"])
    }
    func testPermanentRenameFailureKeepsAnswerAndDurableFallbackForResume() async throws {
        let first = try fixture(); defer { try? FileManager.default.removeItem(at: first.directory) }
        let id = UUID(uuidString: "AA000000-0000-0000-0000-000000000001")!
        let recorded = BindingRecorder()
        let answer = try await adapter(first, failRenamePermanently: true).reply("Echo check", binding: .init(comparisonID: id, mode: .chat), preferences: .init(), onPrepared: { _ in }) { binding in
            XCTAssertEqual(try String(contentsOf: first.stage, encoding: .utf8), "6", "Verified binding must be durable before Rename starts")
            await recorded.record(binding)
        }
        XCTAssertEqual(answer, "ECHO-OK")
        var state = WebWorkspaceState()
        let recordedValue = await recorded.value
        let saved = try XCTUnwrap(recordedValue)
        XCTAssertEqual(saved.title, saved.dedicatedTitle)
        XCTAssertEqual(saved.fallbackTitle, "Automatic title")
        XCTAssertEqual(saved.firstPrompt, saved.firstMessage("Echo check"))
        try state.recordGeminiBinding(saved)
        var reassigned = saved
        reassigned.fallbackTitle = "Another chat"
        XCTAssertThrowsError(try state.recordGeminiBinding(reassigned))
        XCTAssertEqual(try state.geminiBinding(for: id), saved)
        let restored = try JSONDecoder().decode(WebWorkspaceState.self, from: JSONEncoder().encode(state))
        let binding = try XCTUnwrap(restored.geminiBinding(for: id))
        XCTAssertEqual(binding, saved)
        XCTAssertEqual(first.calls().filter { $0["tool"] as? String == "type_text" }.count, 1, "Only the first prompt was typed; a failed Rename was not replayed")
        XCTAssertEqual(try String(contentsOf: first.stage, encoding: .utf8), "7")
        let resumed = try savedConversationScenario(binding)
        defer { try? FileManager.default.removeItem(at: resumed.directory) }
        let reply = try await adapter(resumed).reply("Follow up", binding: binding, preferences: .init(model: "3.8 Flash, All-around help"), onPrepared: { _ in }) { _ in }
        XCTAssertEqual(reply, "FOLLOWUP-OK")
        XCTAssertEqual(resumed.calls().filter { $0["tool"] as? String == "type_text" }.compactMap { ($0["arguments"] as? [String: Any])?["text"] as? String }, ["Follow up"])
    }
    func testFallbackTitleCannotResumeForeignFirstPrompt() async throws {
        let id = UUID(uuidString: "AA000000-0000-0000-0000-000000000001")!
        var binding = GeminiConversationBinding(comparisonID: id, mode: .chat)
        binding.title = binding.dedicatedTitle
        binding.fallbackTitle = "Automatic title"
        binding.firstPrompt = binding.firstMessage("Echo check")
        let f = try savedConversationScenario(binding, foreignFirst: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        do {
            _ = try await adapter(f).reply("Follow up", binding: binding, preferences: .init(), onPrepared: { _ in XCTFail("Wrong nonce cannot reserve") }) { _ in XCTFail("Wrong nonce cannot bind") }
            XCTFail("A matching fallback title must never establish ownership")
        } catch { XCTAssertTrue(error.localizedDescription.contains("dedicated Gemini conversation")) }
        XCTAssertFalse(f.calls().contains { $0["tool"] as? String == "type_text" })
    }
    func testCompletedBindingStorageFailureIsNotSwallowedAsRenameFailure() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        do {
            _ = try await adapter(f).reply("Echo check", binding: .init(comparisonID: UUID(uuidString: "AA000000-0000-0000-0000-000000000001")!, mode: .chat), preferences: .init(), onPrepared: { _ in }) { _ in throw NSError(domain: "GeminiBindingStorage", code: 1) }
            XCTFail("Storage failure must propagate")
        } catch { XCTAssertEqual((error as NSError).domain, "GeminiBindingStorage") }
        XCTAssertEqual(try String(contentsOf: f.stage, encoding: .utf8), "6", "Failed persistence must prevent optional Rename")
    }
    func testCancellationDuringOptionalRenameStillPropagates() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let saved = BindingRecorder()
        do {
            _ = try await adapter(f, cancelDuringRename: true).reply("Echo check", binding: .init(comparisonID: UUID(uuidString: "AA000000-0000-0000-0000-000000000001")!, mode: .chat), preferences: .init(), onPrepared: { _ in }) { await saved.record($0) }
            XCTFail("Cancellation must propagate")
        } catch { XCTAssertTrue(error is CancellationError) }
        let binding = await saved.value
        XCTAssertEqual(binding?.fallbackTitle, "Automatic title")
        XCTAssertEqual(f.calls().filter { $0["tool"] as? String == "type_text" }.count, 1)
    }
    private func thinkingScenario(unavailable: Bool = false) throws -> Fixture {
        let base = try fixture()
        let low = "Low, Quick and efficient", high = "High, Extra thorough"
        func option(_ label: String, x: Double, selected: Bool = false) -> GeminiAXNode {
            .init(role: "AXButton", label: label, selected: selected, frame: .init(x: x, y: 10, w: 30, h: 20))
        }
        var roots: [GeminiAXNode] = []
        for stage in 0...6 {
            var root = base.observations[0].root
            root.children[0].children[1].children[1].label = "Argon, Choose model"
            if [1, 2, 4, 5].contains(stage) {
                var thinking = option("Thinking level", x: 200)
                if [2, 5].contains(stage) {
                    thinking.children = [.init(role: "AXPopover", children: [option(low, x: 230, selected: stage == 2), option(high, x: 260, selected: stage == 5)])]
                }
                root.children[0].children[1].children.append(.init(role: "AXPopover", children: [option("4 Argon, Complex tasks", x: 80, selected: true), thinking]))
            }
            roots.append(root)
        }
        return try scenario(roots, actions: [
            ["tool": "click", "role": "AXButton", "label": "Argon, Choose model"],
            ["tool": "click", "role": "AXButton", "label": "Thinking level"],
            ["tool": "click", "role": "AXButton", "label": unavailable ? low : high],
            ["tool": "click", "role": "AXButton", "label": "Argon, Choose model"],
            ["tool": "click", "role": "AXButton", "label": "Thinking level"],
            ["tool": "click", "role": "AXButton", "label": high]
        ], in: base)
    }
    func testThinkingSelectionIsAppliedReopenedAndVerifiedWithoutSending() async throws {
        let f = try thinkingScenario(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let (selected, options) = try await adapter(f).prepare(binding: nil, preferences: .init(model: "4 Argon, Complex tasks", thinking: "High, Extra thorough"))
        XCTAssertEqual(selected.thinking, "High, Extra thorough")
        XCTAssertEqual(options.thinkingLevels, ["Low, Quick and efficient", "High, Extra thorough"])
        XCTAssertFalse(f.calls().contains { $0["tool"] as? String == "type_text" })
    }
    func testUnavailableThinkingPublishesChoicesAndClosesItsPicker() async throws {
        let f = try thinkingScenario(unavailable: true); defer { try? FileManager.default.removeItem(at: f.directory) }
        do {
            _ = try await adapter(f).prepare(binding: nil, preferences: .init(model: "4 Argon, Complex tasks", thinking: "Retired choice"))
            XCTFail("Expected explicit replacement selection")
        } catch let problem as GeminiSelectionError {
            XCTAssertEqual(problem.options.thinkingLevels, ["Low, Quick and efficient", "High, Extra thorough"])
            XCTAssertEqual(try String(contentsOf: f.stage, encoding: .utf8), "3", "The selected current thinking option closes both popovers")
        }
        XCTAssertFalse(f.calls().contains { $0["tool"] as? String == "type_text" })
    }
    @MainActor
    func testReloadedPendingSessionRequiresOriginReviewAndNeverReplays() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let id = UUID(), file = f.directory.appendingPathComponent("saved-session.json")
        var state = WebWorkspaceState()
        state.enabled = true; state.desktopConversation = .init(name: "Gemini"); state.comparisonID = id
        state.draft = "Keep the interrupted draft"
        var pending = GeminiConversationBinding(comparisonID: id, mode: .task)
        pending.firstPrompt = pending.firstMessage("Original request")
        try state.recordGeminiBinding(pending)
        var attempt = WebSendAttempt(text: "Original request", status: .attempting)
        attempt.comparisonID = id; state.attempts = [attempt]
        try JSONEncoder().encode(state).write(to: file)
        let session = WebAgentSession(provider: .geminiApp, storageURL: file, fixture: false, museApp: .shared, desktopApps: .demo, desktopDriver: DesktopAppConversation(executable: f.executable), geminiApp: adapter(f))
        XCTAssertEqual(session.state.attempts.first?.status, .uncertain)
        _ = await session.openComparison(UUID())
        session.acknowledgeIncompleteRequest()
        XCTAssertEqual(session.state.attempts.first?.status, .uncertain, "Another comparison cannot dismiss the originating request")
        let blocked = await session.send("Another request")
        XCTAssertNil(blocked)
        _ = await session.openComparison(id)
        session.acknowledgeIncompleteRequest()
        let ready = await session.openComparison(id)
        XCTAssertFalse(ready)
        XCTAssertEqual(try session.state.geminiBinding(for: id), pending)
        XCTAssertEqual(session.state.draft, "Keep the interrupted draft")
        XCTAssertFalse(f.calls().contains { ["click", "type_text"].contains($0["tool"] as? String ?? "") })
        session.beginShutdown()
    }
    func testWrongDriverWindowRefusesBeforeAnyInput() async throws {
        let f = try fixture(driverPID: 99); defer { try? FileManager.default.removeItem(at: f.directory) }
        do { _ = try await adapter(f).prepare(binding: nil, preferences: .init()); XCTFail("Expected exact window refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        XCTAssertFalse(f.calls().contains { ["click", "type_text"].contains($0["tool"] as? String ?? "") })
    }
    func testPendingFirstSendNeverCreatesReplacementAfterRestart() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        var pending = GeminiConversationBinding(comparisonID: UUID(), mode: .chat)
        pending.firstPrompt = "Already attempted"
        do { _ = try await adapter(f).prepare(binding: pending, preferences: .init()); XCTFail("Expected pending refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("interrupted")) }
        XCTAssertFalse(f.calls().contains { ["click", "type_text"].contains($0["tool"] as? String ?? "") })
    }
    private actor BindingRecorder {
        var value: GeminiConversationBinding?
        func record(_ binding: GeminiConversationBinding) { value = binding }
    }
}
