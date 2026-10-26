import XCTest
@testable import msgblastCore

final class ChatGPTAppConversationTests: XCTestCase {
    private func field(_ label: String = "Ask ChatGPT", value: String = "Ask ChatGPT\n", placeholder: Bool = true) -> ChatGPTAXNode {
        .init(role: "AXTextArea", label: label, value: value, children: placeholder ? [.init(role: "AXGroup", classes: ["placeholder"])] : [])
    }
    private func window(_ content: [ChatGPTAXNode] = [], composer: ChatGPTAXNode? = nil, title: String = "ChatGPT", extra: [ChatGPTAXNode] = []) -> ChatGPTAXNode {
        .init(role: "AXWindow", label: title, children: [.init(role: "AXWebArea", url: "app://-/index.html", children: extra + [.init(role: "AXGroup", id: "test-chat-panel", children: content + [composer ?? field()])])])
    }
    private func turn(_ user: String, answer: String) -> ChatGPTAXNode {
        .init(role: "AXGroup", children: [
            .init(role: "AXHeading", label: "You said:", classes: ["sr-only"]),
            .init(role: "AXGroup", children: [.init(role: "AXStaticText", value: user)]),
            .init(role: "AXButton", label: "Copy message", children: [.init(role: "AXStaticText", value: "Exclude this control")]),
            .init(role: "AXHeading", label: "ChatGPT said:", classes: ["sr-only"]),
            .init(role: "AXGroup", children: [.init(role: "AXStaticText", value: answer)]),
            .init(role: "AXButton", label: "Copy")
        ])
    }
    func testAssistantSemanticHeadingsRemainPartOfTheReply() throws {
        for hasDetails in [false, true] {
            let heading = ChatGPTAXNode(role: "AXHeading", label: "Overview", children: hasDetails ? [.init(role: "AXStaticText", value: "Overview")] : [])
            let body: [ChatGPTAXNode] = [heading] + (hasDetails ? [.init(role: "AXStaticText", value: "Details")] : [])
            let transcript = ChatGPTAXNode(role: "AXGroup", classes: ["_transcriptContent_native_2"], children: [
                .init(role: "AXGroup", children: [
                    .init(role: "AXHeading", label: "ChatGPT said:", classes: ["sr-only"]),
                    .init(role: "AXGroup", children: body),
                    .init(role: "AXButton", label: "Copy")
                ])
            ])
            let native = try ChatGPTAppObservation(root: window([transcript]))
            XCTAssertEqual(native.messages, [.init(role: .assistant, text: hasDetails ? "Overview\nDetails" : "Overview")])
        }
    }
    func testRoleHeadingsWithinOneTurnDefineTwoMessages() throws {
        let transcript = ChatGPTAXNode(role: "AXGroup", classes: ["_transcriptContent_native_2"], children: [turn("One prompt", answer: "One answer"), turn("Second prompt", answer: "Second answer")])
        let native = try ChatGPTAppObservation(root: window([transcript], extra: [.init(role: "AXStaticText", value: "Private sidebar title")]))
        XCTAssertEqual(native.messages, [.init(role: .user, text: "One prompt"), .init(role: .assistant, text: "One answer"), .init(role: .user, text: "Second prompt"), .init(role: .assistant, text: "Second answer")])
    }
    func testEmbeddedBrowserAndHumanMessengerAreExcluded() throws {
        let foreign = ChatGPTAXNode(role: "AXWebArea", url: "https://human-messenger.invalid", children: [.init(role: "AXGroup", id: "foreign-chat-panel", children: [field(value: "Private unsent text", placeholder: false), .init(role: "AXGroup", classes: ["_transcriptContent_foreign"], children: [turn("Human message", answer: "Human reply")])])])
        let native = try ChatGPTAppObservation(root: window(extra: [foreign]))
        XCTAssertTrue(native.messages.isEmpty)
        XCTAssertTrue(native.draft.isEmpty)
        XCTAssertFalse(native.nodes.contains { $0.value == "Private unsent text" })
    }
    func testDotNavigationRequiresUniqueFirstPartySidebarAndExcludesEmbeddedApps() throws {
        let newChat = ChatGPTAXNode(role: "AXButton", label: "New chat", classes: ["sidebar-item"])
        let dot = ChatGPTAXNode(role: "AXButton", label: "Your dot", classes: ["sidebar-item"], frame: .init(x: 10, y: 20, w: 100, h: 30))
        let sidebar = ChatGPTAXNode(role: "AXGroup", children: [newChat, dot])
        let foreign = ChatGPTAXNode(role: "AXWebArea", url: "https://embedded.invalid", children: [sidebar])
        let root = window(extra: [sidebar, foreign])
        XCTAssertEqual(try ChatGPTAppNavigation(root: root).dotButton().label, "Your dot")
        XCTAssertThrowsError(try ChatGPTAppNavigation(root: window(extra: [foreign])).dotButton())
        XCTAssertThrowsError(try ChatGPTAppNavigation(root: window(extra: [sidebar, sidebar])).dotButton())
        XCTAssertThrowsError(try ChatGPTAppNavigation(root: window(extra: [sidebar, .init(role: "AXDialog")])).dotButton())
        var wrongApp = root; wrongApp.children[0].url = "https://chatgpt.com"
        XCTAssertThrowsError(try ChatGPTAppNavigation(root: wrongApp).dotButton())
    }
    func testActualPlaceholderRequiresNativePlaceholderChild() throws {
        XCTAssertEqual(try ChatGPTAppObservation(root: window()).draft, "")
        for value in ["Ask ChatGPT", "Ask ChatGPT\n", "Keep my draft"] {
            XCTAssertEqual(try ChatGPTAppObservation(root: window(composer: field(value: value, placeholder: false))).draft, value)
        }
    }
    func testEmptyWorkComposerAcceptsPlaceholderWithoutTrailingNewlineButPreservesLiteralDraft() throws {
        let mode = ChatGPTAXNode(role: "AXPopUpButton", label: "Switch mode, current mode: ChatGPT")
        for hasPlaceholder in [true, false] {
            let native = try ChatGPTAppObservation(root: window(composer: field("Work with ChatGPT", value: "Work with ChatGPT", placeholder: hasPlaceholder), extra: [mode]))
            XCTAssertEqual(native.draft, hasPlaceholder ? "" : "Work with ChatGPT")
            XCTAssertTrue(native.codexBootstrap)
            XCTAssertFalse(native.isNew)
        }
    }
    func testEmptyChatComposerAcceptsPlaceholderWithoutTrailingNewline() throws {
        XCTAssertEqual(try ChatGPTAppObservation(root: window(composer: field(value: "Ask ChatGPT"))).draft, "")
        XCTAssertEqual(try ChatGPTAppObservation(root: window(composer: field(value: "Ask ChatGPT", placeholder: false))).draft, "Ask ChatGPT")
    }
    func testFirstPartyContentTitleOverridesGenericNativeWindowTitle() throws {
        var chat = window(title: "ChatGPT")
        chat.children[0].label = "Reply exact string"
        XCTAssertEqual(try ChatGPTAppObservation(root: chat).title, "Reply exact string")
        var dot = window(composer: field("Message", value: "Send a message"), title: "ChatGPT", extra: [
            .init(role: "AXPopUpButton", label: "Open Pal’s profile")
        ])
        dot.children[0].label = "Pal"
        dot.children[0].children[1].children.insert(.init(role: "AXGroup", classes: ["message-list"]), at: 0)
        XCTAssertEqual(try ChatGPTAppObservation(root: dot).title, "Pal")
    }
    func testDotComputerSetupIsNotReportedAsMissingConversationPanel() throws {
        let setup = ChatGPTAXNode(role: "AXWindow", label: "ChatGPT", children: [
            .init(role: "AXWebArea", url: "app://-/index.html", children: [
                .init(role: "AXButton", label: "New chat", classes: ["sidebar-item"]),
                .init(role: "AXHeading", label: "Choose where your dot can work"),
                .init(role: "AXCheckBox", label: "Your local computer", value: "1"),
                .init(role: "AXButton", label: "Continue")
            ])
        ])
        let native = try ChatGPTAppObservation(root: setup)
        XCTAssertTrue(native.dotSetup)
        XCTAssertFalse(native.isNew)
        XCTAssertTrue(native.messages.isEmpty)
        XCTAssertThrowsError(try native.requiredComposer()) { error in
            XCTAssertTrue(error.localizedDescription.contains("Create your Dot in ChatGPT"))
        }
    }
    func testNativeParagraphDraftPreservesBlankLinesAndRejectsDisagreement() throws {
        let paragraphs: [ChatGPTAXNode] = [
            .init(role: "AXGroup", children: [.init(role: "AXStaticText", value: "First")]),
            .init(role: "AXGroup", subrole: "AXEmptyGroup"),
            .init(role: "AXGroup", children: [.init(role: "AXStaticText", value: "Last")])
        ]
        var composer = field(value: "First\nLast", placeholder: false)
        composer.children = paragraphs
        XCTAssertEqual(try ChatGPTAppObservation(root: window(composer: composer)).draft, "First\n\nLast")
        composer.value = "Different\nLast"
        XCTAssertThrowsError(try ChatGPTAppObservation(root: window(composer: composer)))
        composer.value = "First\nLast"
        composer.children[0].children.append(.init(role: "AXImage", label: "Attachment"))
        XCTAssertThrowsError(try ChatGPTAppObservation(root: window(composer: composer)))
    }
    func testUnknownVersionAndAmbiguousNativePanelFailClosed() {
        XCTAssertThrowsError(try ChatGPTAppObservation(root: .init(role: "AXWindow", children: [.init(role: "AXWebArea", url: "https://chatgpt.com", children: [field()])])))
        XCTAssertThrowsError(try ChatGPTAppObservation(root: window(extra: [.init(role: "AXGroup", id: "duplicate-chat-panel", children: [field()])])))
    }
    func testDotNativeParagraphsPreserveOutgoingComparisonReferenceSpacing() throws {
        let prompt = "[msgblast comparison 123]\n\nExact prompt"
        let paragraphs = prompt.components(separatedBy: "\n\n").map { text in
            ChatGPTAXNode(role: "AXGroup", classes: ["_Paragraph_native_2"], children: [.init(role: "AXStaticText", value: text)])
        }
        let row = ChatGPTAXNode(role: "AXGroup", classes: ["message-row", "self"], children: [.init(role: "AXGroup", classes: ["message-bubble"], children: paragraphs)])
        let root = window([.init(role: "AXGroup", classes: ["message-list"], children: [row])], composer: field("Message", value: "Send a message\n"), title: "Example Dot", extra: [.init(role: "AXPopUpButton", label: "Open Example Dot’s profile")])
        XCTAssertEqual(try ChatGPTAppObservation(root: root).messages, [.init(role: .user, text: prompt)])
    }
    func testDotHistoryKeepsExactBaselineAndRefusesInterleavedOrAdditionalMessages() throws {
        let baseline: [ChatGPTMessage] = [.init(role: .user, text: "Reference"), .init(role: .assistant, text: "Previous reply")]
        func observation(_ messages: [ChatGPTMessage]) throws -> ChatGPTAppObservation {
            let rows = messages.map { message in
                ChatGPTAXNode(role: "AXGroup", classes: message.role == .user ? ["message-row", "self"] : ["message-row"], children: [.init(role: "AXGroup", classes: ["message-bubble"], children: [.init(role: "AXStaticText", value: message.text)])])
            }
            return try ChatGPTAppObservation(root: window([.init(role: "AXGroup", classes: ["message-list"], children: rows)], composer: field("Message", value: "Send a message\n"), title: "Example Dot", extra: [.init(role: "AXPopUpButton", label: "Open Example Dot’s profile")]))
        }
        let outgoing = ChatGPTMessage(role: .user, text: "Current prompt")
        let answer = ChatGPTMessage(role: .assistant, text: "Current reply")
        let older = ChatGPTMessage(role: .assistant, text: "Older history")
        XCTAssertEqual(try observation([older] + baseline + [outgoing, answer]).appendedMessages(after: baseline), [outgoing, answer])
        XCTAssertThrowsError(try observation([baseline[0], older, baseline[1], outgoing, answer]).appendedMessages(after: baseline))
        XCTAssertThrowsError(try observation(baseline + [outgoing, answer, .init(role: .user, text: "Another request")]).appendedMessages(after: baseline))
        XCTAssertThrowsError(try observation([older, outgoing, answer]).appendedMessages(after: baseline))
    }
    func testDotGroupedBubblesRetainMessageBoundariesWithoutDuplicateNestedWrappers() throws {
        func bubble(_ text: String, nested: Bool = false) -> ChatGPTAXNode {
            let body = ChatGPTAXNode(role: "AXStaticText", value: text)
            return .init(role: "AXGroup", classes: ["message-bubble"], children: nested ? [.init(role: "AXGroup", classes: ["message-bubble"], children: [body])] : [body])
        }
        let rows: [ChatGPTAXNode] = [
            .init(role: "AXGroup", classes: ["message-row"], children: [bubble("Hello"), bubble("Anything top of mind?", nested: true), .init(role: "AXButton", label: "Reply")]),
            .init(role: "AXGroup", classes: ["message-row", "self"], children: [bubble("One"), bubble("Two"), .init(role: "AXStaticText", value: "10:08 PM")])
        ]
        let root = window([.init(role: "AXGroup", classes: ["message-list"], children: rows)], composer: field("Message", value: "Send a message"), title: "paldot", extra: [.init(role: "AXPopUpButton", label: "Open paldot’s profile")])
        let native = try ChatGPTAppObservation(root: root)
        XCTAssertTrue(native.draft.isEmpty)
        XCTAssertEqual(native.messages, [.init(role: .assistant, text: "Hello"), .init(role: .assistant, text: "Anything top of mind?"), .init(role: .user, text: "One"), .init(role: .user, text: "Two")])
    }
    func testDotBodyExcludesPermissionCardsAndTimestamps() throws {
        let rows: [ChatGPTAXNode] = [
            .init(role: "AXGroup", classes: ["message-row", "self"], children: [.init(role: "AXGroup", classes: ["message-bubble"], children: [.init(role: "AXStaticText", value: "My own prompt")]), .init(role: "AXStaticText", value: "11:03 AM")]),
            .init(role: "AXGroup", classes: ["message-row"], children: [.init(role: "AXGroup", classes: ["approval-card"], children: [.init(role: "AXStaticText", value: "Approve old unrelated work"), .init(role: "AXButton", label: "Allow")])]),
            .init(role: "AXGroup", classes: ["message-row"], children: [.init(role: "AXGroup", classes: ["message-bubble"], children: [.init(role: "AXStaticText", value: "My Dot reply")])])
        ]
        let root = window([.init(role: "AXGroup", classes: ["message-list"], children: rows)], composer: field("Message", value: "Send a message\n"), title: "Example Dot", extra: [.init(role: "AXPopUpButton", label: "Open Example Dot’s profile")])
        let native = try ChatGPTAppObservation(root: root)
        XCTAssertEqual(native.kind, .dots)
        XCTAssertEqual(native.messages, [.init(role: .user, text: "My own prompt"), .init(role: .assistant, text: "My Dot reply")])
        var wrong = root; wrong.label = "Another Dot"
        XCTAssertThrowsError(try ChatGPTAppObservation(root: wrong))
    }
    func testCodexBootstrapCannotBecomeNewChatOrSupplyMessages() throws {
        let root = window(composer: field("Work with ChatGPT", value: "Work with ChatGPT\n"), extra: [.init(role: "AXPopUpButton", label: "Switch mode, current mode: Codex")])
        let native = try ChatGPTAppObservation(root: root)
        XCTAssertTrue(native.codexBootstrap)
        XCTAssertFalse(native.isNew)
        XCTAssertTrue(native.draft.isEmpty)
        XCTAssertTrue(native.messages.isEmpty)
    }
    func testExistingWorkTaskInChatGPTGlobalModeIsNavigationOnly() throws {
        let mode = ChatGPTAXNode(role: "AXPopUpButton", label: "Switch mode, current mode: ChatGPT")
        let native = try ChatGPTAppObservation(root: window(composer: field("Work with ChatGPT", value: "\n"), title: "Existing task", extra: [mode]))
        XCTAssertTrue(native.codexBootstrap)
        XCTAssertFalse(native.isNew)
        XCTAssertTrue(native.draft.isEmpty)
        XCTAssertTrue(native.messages.isEmpty)
        let literal = try ChatGPTAppObservation(root: window(composer: field("Work with ChatGPT", value: "\n", placeholder: false), extra: [mode]))
        XCTAssertEqual(literal.draft, "\n")
        XCTAssertFalse(literal.isNew)
    }
    func testPendingFirstPromptPersistsThroughCodableReload() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        var binding = ChatGPTConversationBinding(comparisonID: id, kind: .chatgpt)
        binding.firstPrompt = binding.firstMessage("A single prompt")
        let restored = try JSONDecoder().decode(ChatGPTConversationBinding.self, from: JSONEncoder().encode(binding))
        XCTAssertEqual(restored.firstPrompt, "[msgblast comparison 00000000-0000-0000-0000-000000000123]\n\nA single prompt")
        XCTAssertNil(restored.title)
        XCTAssertEqual(restored.dedicatedTitle, "msgblast 00000000-0000-0000-0000-000000000123")
    }
}

final class ChatGPTAppDriverTests: XCTestCase {
    private func fixture() throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chatgpt-driver-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("driver")
        try Data("""
        #!/usr/bin/env python3
        import sys,json,pathlib,time
        p=pathlib.Path(__file__).parent
        tool=sys.argv[2];args=json.loads(sys.argv[3])
        with (p/'calls.jsonl').open('a') as f:f.write(json.dumps({'tool':tool,'arguments':args})+'\\n')
        if tool=='list_apps':print(json.dumps({'apps':[{'bundle_id':'com.openai.codex','pid':42,'running':True}]}))
        elif tool=='list_windows':print(json.dumps({'windows':[{'window_id':21,'title':'Synthetic native chat','is_on_screen':False,'on_current_space':False,'space_ids':[1],'bounds':{'width':1000,'height':900}}]}))
        elif tool=='end_session':print('{}')
        else:raise AssertionError('Unexpected driver mutation or snapshot: '+tool)
        sys.stdout.flush();time.sleep(0.02)
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (directory, executable)
    }
    private func observation(title: String = "ChatGPT", outgoing: String? = nil, codex: Bool = false) throws -> ChatGPTAppObservation {
        var rows: [ChatGPTAXNode] = []
        if let outgoing { rows = [.init(role: "AXGroup", children: [.init(role: "AXHeading", label: "You said:"), .init(role: "AXStaticText", value: outgoing)])] }
        let field = ChatGPTAXNode(role: "AXTextArea", label: codex ? "Work with ChatGPT" : "Ask ChatGPT", value: codex ? "Work with ChatGPT\n" : "Ask ChatGPT\n", children: [.init(role: "AXGroup", classes: ["placeholder"])])
        var controls: [ChatGPTAXNode] = [.init(role: "AXGroup", id: "test-chat-panel", children: [field, .init(role: "AXGroup", classes: ["_transcriptContent_test"], children: rows)])]
        if codex { controls.append(.init(role: "AXPopUpButton", label: "Switch mode, current mode: Codex")) }
        return try .init(root: .init(role: "AXWindow", label: title, children: [.init(role: "AXWebArea", url: "app://-/index.html", children: controls)]))
    }
    private func calls(_ directory: URL) throws -> [String] {
        guard let value = try? String(contentsOf: directory.appendingPathComponent("calls.jsonl"), encoding: .utf8) else { return [] }
        return try value.split(separator: "\n").map { line in
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return try XCTUnwrap(object["tool"] as? String)
        }
    }
    func testInterruptedFirstSubmissionDoesNotCreateOrTypeReplacement() async throws {
        let (directory, executable) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let native = try observation()
        let adapter = ChatGPTAppConversation(executable: executable, readNative: { target in
            guard target == .init(pid: 42, window: 21) else { throw DesktopAppError.unavailable("Wrong target") }
            return native
        })
        var binding = ChatGPTConversationBinding(comparisonID: UUID(), kind: .chatgpt)
        binding.firstPrompt = binding.firstMessage("Uncertain submission")
        do { _ = try await adapter.prepare(comparisonID: binding.comparisonID, kind: .chatgpt, binding: binding); XCTFail("Pending send must block replacement") }
        catch { XCTAssertTrue(error.localizedDescription.contains("interrupted")) }
        XCTAssertTrue(try calls(directory).allSatisfy { ["list_apps", "list_windows", "end_session"].contains($0) })
    }
    func testSavedTitleWithoutExactFirstOutgoingCannotReceiveInput() async throws {
        let (directory, executable) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        var binding = ChatGPTConversationBinding(comparisonID: UUID(), kind: .chatgpt)
        binding.title = binding.dedicatedTitle; binding.firstPrompt = binding.firstMessage("Original")
        let native = try observation(title: binding.dedicatedTitle, outgoing: "A different prompt")
        let adapter = ChatGPTAppConversation(executable: executable, readNative: { _ in native })
        do { _ = try await adapter.reply("Follow up", binding: binding, onPrepared: { _ in XCTFail("Must not reserve input") }, onBinding: { _ in XCTFail("Must not bind foreign history") }); XCTFail("Wrong first outgoing must block") }
        catch { XCTAssertTrue(error.localizedDescription.contains("dedicated")) }
        XCTAssertTrue(try calls(directory).allSatisfy { ["list_apps", "list_windows", "end_session"].contains($0) })
    }
    func testConnectionCheckReadsCodexBootstrapWithoutSwitchingMode() async throws {
        let (directory, executable) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let native = try observation(codex: true)
        let adapter = ChatGPTAppConversation(executable: executable, readNative: { _ in native })
        try await adapter.checkAvailable(kind: .chatgpt)
        XCTAssertEqual(try calls(directory), ["list_apps", "list_windows"])
    }
}

private actor ChatGPTRecordedBindings {
    var prepared: [ChatGPTConversationBinding] = []
    var bound: [ChatGPTConversationBinding] = []
    var events: [String] = []
    func prepare(_ value: ChatGPTConversationBinding) { prepared.append(value); events.append("prepared") }
    func submit() { events.append("submit") }
    func bind(_ value: ChatGPTConversationBinding) { bound.append(value); events.append("bound") }
}

final class ChatGPTAppSubmissionTests: XCTestCase {
    private enum Preparation: String, Sendable {
        case ready, unfocused, movingComposer, focusNoOp, draftDuringFocus, chatDuringFocus, historyDuringFocus, generationDuringFocus, focusLostAfterTyping
        var needsFocus: Bool { [.unfocused, .focusNoOp, .draftDuringFocus, .chatDuringFocus, .historyDuringFocus, .generationDuringFocus].contains(self) }
    }
    private struct Fixture: Sendable {
        let directory: URL
        let executable: URL
        let binding: ChatGPTConversationBinding
        let roots: [ChatGPTAXNode]
        let nativeParagraphs: Bool
        let preparation: Preparation
        var stage: URL { directory.appendingPathComponent("stage") }
        func adapter(transientAfterTyping: Bool = false, partialOutgoingOnce: Bool = false, thinkingStatusOnce: Bool = false, renameReadFailure: Bool = false, renameReadCancellation: Bool = false, prependHistoryAfterSend: Bool = false, dotTransitionOnce: Bool = false) -> ChatGPTAppConversation {
            ChatGPTAppConversation(executable: executable, timing: .init(pollInterval: .milliseconds(1), stableDuration: .zero, replyTimeout: .seconds(3), callTimeout: 3), readNavigation: { target in
                guard target == .init(pid: 42, window: 21) else { throw DesktopAppError.unavailable("Wrong exact window") }
                let index = Int((try? String(contentsOf: stage, encoding: .utf8)) ?? "0") ?? 0
                return try ChatGPTAppNavigation(root: roots[index])
            }, readNative: { target in
                guard target == .init(pid: 42, window: 21) else { throw DesktopAppError.unavailable("Wrong exact window") }
                let index = Int((try? String(contentsOf: stage, encoding: .utf8)) ?? "0") ?? 0
                let transientMarker = directory.appendingPathComponent("transient-read")
                if transientAfterTyping,
                   let draft = try? String(contentsOf: directory.appendingPathComponent("native-draft"), encoding: .utf8), !draft.isEmpty,
                   !FileManager.default.fileExists(atPath: transientMarker.path) {
                    try Data().write(to: transientMarker)
                    throw ChatGPTObservationError.transient
                }
                var root = roots[index]
                let dotTransition = directory.appendingPathComponent("dot-transition-read")
                if dotTransitionOnce, index == 1, !FileManager.default.fileExists(atPath: dotTransition.path) {
                    root.children[0].children.removeAll { $0.role == "AXHeading" }
                    try Data().write(to: dotTransition)
                }
                if root.label == binding.dedicatedTitle, index == roots.count - 1 {
                    if renameReadFailure { throw DesktopAppError.unavailable("Rename completion could not be read") }
                    if renameReadCancellation { throw CancellationError() }
                }
                if let actualDraft = try? String(contentsOf: directory.appendingPathComponent("native-draft"), encoding: .utf8) {
                    func update(_ node: inout ChatGPTAXNode) {
                        if node.role == "AXTextArea" {
                            let placeholder = node.label == "Message" ? "Send a message" : "Ask ChatGPT"
                            node.value = actualDraft.isEmpty ? placeholder + "\n" : actualDraft
                            node.children = actualDraft.isEmpty ? [.init(role: "AXGroup", classes: ["placeholder"])] : []
                            if nativeParagraphs && !actualDraft.isEmpty {
                                let paragraphs = actualDraft.components(separatedBy: "\n")
                                node.value = paragraphs.filter { !$0.isEmpty }.joined(separator: "\n")
                                node.children = paragraphs.map { paragraph in
                                    .init(role: "AXGroup", children: paragraph.isEmpty ? [] : [.init(role: "AXStaticText", value: paragraph)])
                                }
                            }
                            node.focused = true
                        }
                        for child in node.children.indices { update(&node.children[child]) }
                    }
                    update(&root)
                }
                func preparationState(_ node: inout ChatGPTAXNode) {
                    if node.role == "AXTextArea" {
                        if preparation.needsFocus && index == 0 { node.focused = false }
                        if preparation == .movingComposer, FileManager.default.fileExists(atPath: directory.appendingPathComponent("composer-moved").path) {
                            node.frame = .init(x: 0, y: 20, w: 10, h: 10)
                        }
                        if preparation == .draftDuringFocus, index == 1 {
                            node.value = "A draft typed elsewhere"; node.children = []
                        }
                        if preparation == .focusLostAfterTyping, !((try? String(contentsOf: directory.appendingPathComponent("native-draft"), encoding: .utf8)) ?? "").isEmpty {
                            node.focused = false
                        }
                    }
                    for child in node.children.indices { preparationState(&node.children[child]) }
                }
                preparationState(&root)
                if preparation == .chatDuringFocus, index == 1 { root.label = "Another conversation" }
                if index == 1, preparation == .historyDuringFocus {
                    func appendHistory(_ node: inout ChatGPTAXNode) {
                        if node.classes.contains(where: { $0.hasPrefix("_transcriptContent_") }) {
                            node.children.append(.init(role: "AXGroup", children: [.init(role: "AXHeading", label: "You said:"), .init(role: "AXStaticText", value: "An unrelated message")]))
                        } else { for child in node.children.indices { appendHistory(&node.children[child]) } }
                    }
                    appendHistory(&root)
                }
                if index == 1, preparation == .generationDuringFocus {
                    root.children[0].children[0].children.append(.init(role: "AXButton", label: "Stop generating"))
                }
                if partialOutgoingOnce || thinkingStatusOnce,
                   let submitted = try? String(contentsOf: directory.appendingPathComponent("submitted-draft"), encoding: .utf8), !submitted.isEmpty {
                    let partialMarker = directory.appendingPathComponent("partial-outgoing-read")
                    if !FileManager.default.fileExists(atPath: partialMarker.path) {
                        func partial(_ node: inout ChatGPTAXNode) {
                            if node.role == "AXStaticText", node.value == submitted { node.value = thinkingStatusOnce ? submitted + "\n\nThinking" : String(submitted.prefix(12)) }
                            for child in node.children.indices { partial(&node.children[child]) }
                        }
                        partial(&root)
                        try Data().write(to: partialMarker)
                    } else { try Data().write(to: directory.appendingPathComponent("full-outgoing-read")) }
                }
                if prependHistoryAfterSend, FileManager.default.fileExists(atPath: directory.appendingPathComponent("submitted-draft").path) {
                    func prepend(_ node: inout ChatGPTAXNode) {
                        if node.classes.contains("message-list") {
                            node.children.insert(.init(role: "AXGroup", classes: ["message-row"], children: [.init(role: "AXGroup", classes: ["message-bubble"], children: [.init(role: "AXStaticText", value: "Older history loaded after submission")])]), at: 0)
                        }
                        for child in node.children.indices { prepend(&node.children[child]) }
                    }
                    prepend(&root)
                }
                return try ChatGPTAppObservation(root: root)
            })
        }
        func calls() -> [[String: Any]] {
            (try? String(contentsOf: directory.appendingPathComponent("calls.jsonl"), encoding: .utf8))?.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? []
        }
    }
    private func fixture(kind: ChatGPTAppKind = .chatgpt, followup: Bool = false, wrongOutgoing: Bool = false, unknownSend: Bool = false, wrongPID: Bool = false, reopen: Bool = false, duplicateTitle: Bool = false, question: String = "First question", dropNewline: Bool = false, existingWork: Bool = false, dotSetup: Bool = false, newChatWork: Bool = false, dotSetupDestination: Bool = false, nativeParagraphs: Bool = false, renameFailure: Bool = false, fallbackResume: Bool = false, renamedResume: Bool = false, zeroHeightSidebar: Bool = false, unreadableStart: Bool = false, preparation: Preparation = .ready) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chatgpt-submit-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var binding = ChatGPTConversationBinding(comparisonID: UUID(uuidString: "AA000000-0000-0000-0000-000000000001")!, kind: kind)
        let first = binding.firstMessage(question)
        if kind == .dots { binding.title = "Example Dot" }
        if followup { binding.firstPrompt = first; if kind == .chatgpt { binding.title = binding.dedicatedTitle } }
        if fallbackResume { binding.fallbackTitle = "Automatic title" }
        let prompt = followup ? "Follow-up" : first
        func control(_ role: String, _ label: String, value: String? = nil, x: Double, selected: String? = nil, children: [ChatGPTAXNode] = []) -> ChatGPTAXNode {
            .init(role: role, label: label, value: value, selectedText: selected, focused: role == "AXTextArea", frame: .init(x: x, y: 0, w: 10, h: 10), children: children)
        }
        func message(_ role: ChatGPTMessage.Role, _ text: String) -> ChatGPTAXNode {
            if kind == .dots { return .init(role: "AXGroup", classes: role == .user ? ["message-row", "self"] : ["message-row"], children: [.init(role: "AXGroup", classes: ["message-bubble"], children: [.init(role: "AXStaticText", value: text)])]) }
            return .init(role: "AXGroup", children: [.init(role: "AXHeading", label: role == .user ? "You said:" : "ChatGPT said:"), .init(role: "AXGroup", children: [.init(role: "AXStaticText", value: text)]), .init(role: "AXButton", label: role == .user ? "Copy message" : "Copy")])
        }
        func root(draft: String = "", sent: Bool = false, titleField: String? = nil, saved: Bool = false) -> ChatGPTAXNode {
            let title = kind == .dots ? "Example Dot" : followup ? (renamedResume ? binding.dedicatedTitle : binding.fallbackTitle ?? binding.dedicatedTitle) : saved ? binding.dedicatedTitle : sent ? "Automatic title" : "ChatGPT"
            var rows: [ChatGPTAXNode] = followup ? [message(.user, first), message(.assistant, "Previous answer")] : []
            if sent { rows += [message(.user, wrongOutgoing ? "Foreign outgoing" : prompt), message(.assistant, "ANSWER")] }
            let placeholder = kind == .dots ? "Send a message" : "Ask ChatGPT"
            var controls: [ChatGPTAXNode] = [control("AXTextArea", kind == .dots ? "Message" : "Ask ChatGPT", value: draft.isEmpty ? placeholder + "\n" : draft, x: 0, children: draft.isEmpty ? [.init(role: "AXGroup", classes: ["placeholder"])] : [])]
            if kind == .chatgpt { controls.append(control("AXCheckBox", "Chat", value: "1", x: 30)) }
            if !draft.isEmpty { controls.append(control("AXButton", "Send", x: 20)) }
            controls.append(.init(role: "AXGroup", classes: kind == .dots ? ["message-list"] : ["_transcriptContent_test"], children: rows))
            var extra: [ChatGPTAXNode] = []
            if kind == .dots { extra.append(.init(role: "AXPopUpButton", label: "Open Example Dot’s profile")) }
            if kind == .chatgpt && sent {
                let header: ChatGPTAXNode
                if let titleField { header = control("AXTextField", "Chat title", value: titleField, x: 50, selected: titleField == "Automatic title" ? titleField : "") }
                else { header = control("AXButton", title, x: 50) }
                extra.append(.init(role: "AXGroup", subrole: "AXLandmarkBanner", children: [header]))
            }
            return .init(role: "AXWindow", label: title, children: [.init(role: "AXWebArea", url: "app://-/index.html", children: extra + [.init(role: "AXGroup", id: "test-chat-panel", children: controls)])])
        }
        let composerLabel = kind == .dots ? "Message" : "Ask ChatGPT"
        var roots = [root()]
        var actions: [[String: String]] = []
        var accumulated = ""
        for (index, chunk) in prompt.components(separatedBy: "\n").enumerated() {
            if index > 0 {
                actions.append(["tool": "press_key", "label": composerLabel, "role": "AXTextArea", "key": "return", "modifiers": "shift", "focused": "yes"])
                accumulated += "\n"; roots.append(root(draft: accumulated))
            }
            var remaining = chunk[...]
            while !remaining.isEmpty {
                let end = remaining.index(remaining.startIndex, offsetBy: 256, limitedBy: remaining.endIndex) ?? remaining.endIndex
                let batch = String(remaining[..<end]); remaining = remaining[end...]
                var action = ["tool": "type_text", "label": composerLabel, "role": "AXTextArea", "text": batch]
                action[accumulated.isEmpty ? "pixel" : "focused"] = "yes"
                actions.append(action)
                accumulated += batch; roots.append(root(draft: accumulated))
            }
        }
        actions.append(["tool": "click", "label": "Send", "role": "AXButton"])
        roots.append(root(sent: true))
        if kind == .chatgpt && !followup {
            actions.append(["tool": "click", "label": "Automatic title", "role": "AXButton"]); roots.append(root(sent: true, titleField: "Automatic title"))
            actions.append(["tool": "type_text", "label": "Chat title", "role": "AXTextField", "text": binding.dedicatedTitle]); roots.append(root(sent: true, titleField: binding.dedicatedTitle))
            actions.append(["tool": "press_key", "label": "Chat title", "role": "AXTextField", "key": "return"]); roots.append(root(sent: true, saved: true))
        }
        if reopen {
            let sidebar = ChatGPTAXNode(role: "AXButton", label: binding.fallbackTitle ?? binding.dedicatedTitle, classes: ["sidebar-item"], frame: zeroHeightSidebar ? .init(x: 173, y: 929, w: 391, h: 0) : nil)
            for index in roots.indices { roots[index].children[0].children.insert(sidebar, at: 0) }
            let dotComposer = control("AXTextArea", "Message", value: "Send a message\n", x: 0, children: [.init(role: "AXGroup", classes: ["placeholder"])])
            let dotPanel = ChatGPTAXNode(role: "AXGroup", id: "test-chat-panel", children: [dotComposer, .init(role: "AXGroup", classes: ["message-list"])])
            var chrome = [sidebar, ChatGPTAXNode(role: "AXPopUpButton", label: "Open Example Dot’s profile"), dotPanel]
            if duplicateTitle { chrome.insert(sidebar, at: 0) }
            roots.insert(.init(role: "AXWindow", label: "Example Dot", children: [.init(role: "AXWebArea", url: "app://-/index.html", children: chrome)]), at: 0)
            actions.insert(["tool": "click", "label": binding.fallbackTitle ?? binding.dedicatedTitle, "role": "AXButton"], at: 0)
        }
        if dotSetup {
            var newChat = control("AXButton", "New chat", x: 70)
            newChat.classes = ["sidebar-item"]
            roots.insert(.init(role: "AXWindow", label: "ChatGPT", children: [.init(role: "AXWebArea", url: "app://-/index.html", children: [newChat, .init(role: "AXButton", label: "Your dot", classes: ["sidebar-item"]), .init(role: "AXHeading", label: "Create your dot")])]), at: 0)
            actions.insert(["tool": "click", "label": "New chat", "role": "AXButton"], at: 0)
        }
        if newChatWork {
            let workField = control("AXTextArea", "Work with ChatGPT", value: "Work with ChatGPT", x: 0, children: [.init(role: "AXGroup", classes: ["placeholder"])])
            let work = ChatGPTAXNode(role: "AXWindow", label: "ChatGPT", children: [.init(role: "AXWebArea", url: "app://-/index.html", children: [.init(role: "AXPopUpButton", label: "Switch mode, current mode: ChatGPT"), control("AXCheckBox", "Chat", value: "0", x: 30), workField])])
            roots.insert(work, at: dotSetup ? 1 : 0)
            actions.insert(["tool": "click", "label": "Chat", "role": "AXCheckBox"], at: dotSetup ? 1 : 0)
        }
        if dotSetupDestination {
            var home = root()
            var newChat = control("AXButton", "New chat", x: 70)
            newChat.classes = ["sidebar-item"]
            var dot = control("AXButton", "Your dot", x: 80)
            dot.classes = ["sidebar-item"]
            home.children[0].children.insert(.init(role: "AXGroup", children: [newChat, dot]), at: 0)
            roots.insert(home, at: 0)
            actions.insert(["tool": "click", "label": "Your dot", "role": "AXButton"], at: 0)
        }
        if unreadableStart {
            var newChat = control("AXButton", "New chat", x: 70); newChat.classes = ["sidebar-item"]
            var dot = control("AXButton", "Your dot", x: 80); dot.classes = ["sidebar-item"]
            let unrelated = ChatGPTAXNode(role: "AXWindow", label: "Existing task", children: [
                .init(role: "AXWebArea", url: "app://-/index.html", children: [
                    .init(role: "AXGroup", children: [newChat, dot]),
                    .init(role: "AXGroup", id: "task-chat-panel", children: [control("AXTextArea", "Task editor", value: "Keep this unrelated draft", x: 0)])
                ])
            ])
            roots.insert(unrelated, at: 0)
            actions.insert(["tool": "click", "label": "Your dot", "role": "AXButton"], at: 0)
        }
        if existingWork {
            var newChat = control("AXButton", "New chat", x: 70)
            newChat.classes = ["sidebar-item"]
            let workField = control("AXTextArea", "Work with ChatGPT", value: "\n", x: 0, children: [.init(role: "AXGroup", subrole: "AXEmptyGroup", classes: ["placeholder"])])
            roots.insert(.init(role: "AXWindow", label: "Existing task", children: [.init(role: "AXWebArea", url: "app://-/index.html", children: [newChat, .init(role: "AXPopUpButton", label: "Switch mode, current mode: ChatGPT"), .init(role: "AXGroup", id: "task-chat-panel", children: [workField])])]), at: 0)
            actions.insert(["tool": "click", "label": "New chat", "role": "AXButton"], at: 0)
        }
        if preparation.needsFocus {
            var unfocused = roots[0]
            func blur(_ node: inout ChatGPTAXNode) {
                if node.role == "AXTextArea" { node.focused = false }
                for child in node.children.indices { blur(&node.children[child]) }
            }
            blur(&unfocused)
            roots.insert(unfocused, at: 0)
            actions.insert(["tool": "click", "label": composerLabel, "role": "AXTextArea"], at: 0)
        }
        let snapshots: [[String: Any]] = roots.enumerated().map { stage, root in
            let elements: [[String: Any]] = root.descendants.enumerated().compactMap { index, node in
                guard node.frame != nil || (node.role == "AXButton" && node.classes.contains("sidebar-item")) else { return nil }
                var element: [String: Any] = ["role": node.role, "label": node.label, "value": node.value ?? "", "enabled": true, "element_token": "\(stage):\(index)"]
                if let f = node.frame, node.visible { element["frame"] = ["x": f.x, "y": f.y, "w": f.w, "h": f.h] }
                return element
            }
            return ["pid": wrongPID ? 99 : 42, "window_id": 21, "elements": elements, "window_bounds": ["x": 0, "y": 0, "width": 100, "height": 100]]
        }
        try JSONSerialization.data(withJSONObject: snapshots).write(to: directory.appendingPathComponent("snapshots.json"))
        try JSONSerialization.data(withJSONObject: actions).write(to: directory.appendingPathComponent("actions.json"))
        try Data(preparation.rawValue.utf8).write(to: directory.appendingPathComponent("preparation"))
        if unknownSend { try Data().write(to: directory.appendingPathComponent("unknown-send")) }
        if dropNewline { try Data().write(to: directory.appendingPathComponent("drop-newline")) }
        if renameFailure { try Data().write(to: directory.appendingPathComponent("rename-failure")) }
        let executable = directory.appendingPathComponent("driver")
        try Data("""
        #!/usr/bin/env python3
        import sys,json,pathlib,time,struct,zlib
        p=pathlib.Path(__file__).parent
        tool=sys.argv[2];a=json.loads(sys.argv[3])
        with (p/'calls.jsonl').open('a') as f:f.write(json.dumps({'tool':tool,'arguments':a})+'\\n')
        s=int((p/'stage').read_text()) if (p/'stage').exists() else 0
        states=json.loads((p/'snapshots.json').read_text())
        if (p/'composer-moved').exists():
            for state in states:
                for field in state['elements']:
                    if field['role']=='AXTextArea':field['frame']['y']=20
        if tool=='list_apps':print(json.dumps({'apps':[{'bundle_id':'com.openai.codex','pid':42,'running':True}]}))
        elif tool=='list_windows':
            assert a['pid']==42
            print(json.dumps({'windows':[{'window_id':21,'title':'Synthetic native chat','is_on_screen':False,'on_current_space':False,'space_ids':[1],'bounds':{'width':1000,'height':900}}]}))
        elif tool=='get_window_state':
            assert a['pid']==42 and a['window_id']==21
            state=states[s]
            if (p/'preparation').read_text()=='movingComposer':
                (p/'composer-moved').touch()
                for element in state['elements']:
                    if element['role']=='AXTextArea':element['frame']['y']=20
            if a['include_screenshot']:
                image=pathlib.Path(a['screenshot_out_file'])
                def chunk(kind,data):return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
                image.write_bytes(bytes([137,80,78,71,13,10,26,10])+chunk(b'IHDR',struct.pack('>IIBBBBB',100,100,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(bytes(301)*100))+chunk(b'IEND',b''))
                state.update(screenshot_frame_valid=True,screenshot_width=100,screenshot_height=100,screenshot_file_path=str(image))
            print(json.dumps(state))
        elif tool in ['type_text','click','press_key']:
            e=json.loads((p/'actions.json').read_text())[s]
            assert tool==e['tool'] and a['pid']==42 and a['window_id']==21 and a['delivery_mode']=='background'
            matches=[x for x in states[s]['elements'] if x['role']==e['role'] and x['label']==e['label']]
            assert len(matches)==1
            if e.get('pixel')=='yes':
                field=matches[0]['frame']
                assert 'element_token' not in a and field['x']<=a['x']<field['x']+field['w'] and field['y']<=a['y']<field['y']+field['h'], 'Input missed the current composer'
            elif e.get('focused')=='yes':assert 'x' not in a and 'y' not in a and 'element_token' not in a
            else:assert a['element_token']==matches[0]['element_token']
            if 'text' in e:assert a['text']==e['text']
            if 'key' in e:assert a['key']==e['key']
            if 'modifiers' in e:assert a['modifiers']==[e['modifiers']]
            draft=(p/'native-draft').read_text() if (p/'native-draft').exists() else ''
            if e['role']=='AXTextArea':
                if tool=='type_text':draft+=a['text'].replace('\\n','')
                elif tool=='press_key' and not (p/'drop-newline').exists():draft+='\\n'
                (p/'native-draft').write_text(draft)
            if e['label']=='Send':
                (p/'submitted-draft').write_text(draft)
                (p/'native-draft').write_text('')
            no_focus=(p/'preparation').read_text()=='focusNoOp' and tool=='click' and e['role']=='AXTextArea'
            if not(no_focus or (e['label']=='Automatic title' and tool=='click' and (p/'rename-failure').exists())):(p/'stage').write_text(str(s+1))
            if not(e['label']=='Send' and (p/'unknown-send').exists()):print(json.dumps({'effect':'unverifiable'}))
        elif tool=='end_session':print('{}')
        else:raise AssertionError('Unexpected tool '+tool)
        sys.stdout.flush();time.sleep(0.02)
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return .init(directory: directory, executable: executable, binding: binding, roots: roots, nativeParagraphs: nativeParagraphs, preparation: preparation)
    }
    func testUnfocusedComposerIsFocusedBeforeFirstPromptAndFollowupInput() async throws {
        for followup in [false, true] {
            let f = try fixture(followup: followup, preparation: .unfocused)
            defer { try? FileManager.default.removeItem(at: f.directory) }
            let answer = try await f.adapter().reply(followup ? "Follow-up" : "First question", binding: f.binding, onPrepared: { _ in }, onBinding: { _ in })
            XCTAssertEqual(answer, "ANSWER")
            let mutations = f.calls().filter { ["click", "type_text", "press_key"].contains($0["tool"] as? String ?? "") }
            XCTAssertEqual(mutations.first?["tool"] as? String, "click", "Focus must be established before any characters are delivered")
            XCTAssertEqual(try String(contentsOf: f.directory.appendingPathComponent("submitted-draft"), encoding: .utf8), followup ? "Follow-up" : f.binding.firstMessage("First question"))
        }
    }
    func testComposerMovingDuringSnapshotIsReobservedWithoutReplayingInput() async throws {
        let f = try fixture(preparation: .movingComposer)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let answer = try await f.adapter().reply("First question", binding: f.binding, onPrepared: { _ in }, onBinding: { _ in })
        XCTAssertEqual(answer, "ANSWER")
        let inputs = f.calls().filter { $0["tool"] as? String == "type_text" }.compactMap { $0["arguments"] as? [String: Any] }
        XCTAssertEqual(inputs.filter { $0["text"] as? String == f.binding.firstMessage("").trimmingCharacters(in: .newlines) }.count, 1)
        let point = try XCTUnwrap(inputs.first)
        XCTAssertTrue((0..<10).contains(try XCTUnwrap(point["x"] as? Int)))
        XCTAssertTrue((20..<30).contains(try XCTUnwrap(point["y"] as? Int)), "Typing must hit the settled composer rather than its previous location")
        XCTAssertEqual(try String(contentsOf: f.directory.appendingPathComponent("submitted-draft"), encoding: .utf8), f.binding.firstMessage("First question"))
    }
    func testFailedFocusOrChangedContextNeverReservesOrTypesInput() async throws {
        for preparation in [Preparation.focusNoOp, .draftDuringFocus, .chatDuringFocus, .historyDuringFocus, .generationDuringFocus] {
            let f = try fixture(preparation: preparation)
            defer { try? FileManager.default.removeItem(at: f.directory) }
            do {
                _ = try await f.adapter().reply("First question", binding: f.binding, onPrepared: { _ in XCTFail("Focus and context must be verified before reserving input") }, onBinding: { _ in XCTFail("No conversation can be bound") })
                XCTFail("Unverified focus or changed context must block input")
            } catch {
                XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains(preparation == .focusNoOp ? "focus" : "changed"), error.localizedDescription)
            }
            XCTAssertEqual(f.calls().filter { $0["tool"] as? String == "click" }.count, 1, "The case must reach the focus action")
            XCTAssertFalse(f.calls().contains { ["type_text", "press_key"].contains($0["tool"] as? String ?? "") })
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("submitted-draft").path))
        }
    }
    func testFocusLostAfterSingleChunkNeverPressesSend() async throws {
        let f = try fixture(followup: true, preparation: .focusLostAfterTyping)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        do {
            _ = try await f.adapter().reply("Follow-up", binding: f.binding, onPrepared: { _ in }, onBinding: { _ in XCTFail("Focus loss must not bind a reply") })
            XCTFail("Focus loss must block Send even for a one-chunk prompt")
        } catch { XCTAssertTrue(error.localizedDescription.contains("exact prepared draft"), error.localizedDescription) }
        XCTAssertEqual(f.calls().filter { $0["tool"] as? String == "type_text" }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("submitted-draft").path))
        XCTAssertEqual(try String(contentsOf: f.directory.appendingPathComponent("native-draft"), encoding: .utf8), "Follow-up")
    }
    func testRawNativeValueMayCollapseEmptyParagraphsWithoutChangingSubmittedPrompt() async throws {
        for kind in [ChatGPTAppKind.chatgpt, .dots] {
            let f = try fixture(kind: kind, question: "First line\n\nLast line", nativeParagraphs: true)
            defer { try? FileManager.default.removeItem(at: f.directory) }
            let answer = try await f.adapter().reply("First line\n\nLast line", binding: f.binding, onPrepared: { _ in }, onBinding: { _ in })
            XCTAssertEqual(answer, "ANSWER")
            let submitted = try String(contentsOf: f.directory.appendingPathComponent("submitted-draft"), encoding: .utf8)
            XCTAssertEqual(submitted, f.binding.firstMessage("First line\n\nLast line"))
            XCTAssertEqual(f.calls().filter { $0["tool"] as? String == "click" }.count, kind == .chatgpt ? 2 : 1)
        }
    }
    func testTransientNativeReadAfterTypingDoesNotReplayInput() async throws {
        let f = try fixture(nativeParagraphs: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let answer = try await f.adapter(transientAfterTyping: true).reply("First question", binding: f.binding, onPrepared: { _ in }, onBinding: { _ in })
        XCTAssertEqual(answer, "ANSWER")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("transient-read").path))
        XCTAssertEqual(try String(contentsOf: f.directory.appendingPathComponent("submitted-draft"), encoding: .utf8), f.binding.firstMessage("First question"))
        XCTAssertEqual(f.calls().filter { $0["tool"] as? String == "click" }.count, 2)
    }
    func testNativeChatGPTSingleSendRenamesAndPersistsOwnedThread() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let recorded = ChatGPTRecordedBindings()
        let answer = try await fixture.adapter().reply("First question", binding: fixture.binding, onSubmitAction: {
            XCTAssertEqual(try? String(contentsOf: fixture.directory.appendingPathComponent("native-draft"), encoding: .utf8), fixture.binding.firstMessage("First question"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("submitted-draft").path))
            await recorded.submit()
        }, onPrepared: { await recorded.prepare($0) }, onBinding: { await recorded.bind($0) })
        XCTAssertEqual(answer, "ANSWER")
        let prepared = await recorded.prepared, bound = await recorded.bound
        XCTAssertEqual(prepared.count, 1); XCTAssertNil(prepared[0].title)
        XCTAssertEqual(prepared[0].firstPrompt, fixture.binding.firstMessage("First question"))
        XCTAssertEqual(bound.count, 1); XCTAssertEqual(bound[0].title, fixture.binding.dedicatedTitle)
        let events = await recorded.events
        XCTAssertEqual(events, ["prepared", "submit", "bound"])
        XCTAssertEqual(fixture.calls().filter { $0["tool"] as? String == "click" }.count, 2)
        XCTAssertEqual(fixture.calls().filter { $0["tool"] as? String == "press_key" }.count, 3)
        XCTAssertEqual(try String(contentsOf: fixture.stage, encoding: .utf8), "8")
    }
    func testSavedChatGPTFollowupUsesUnprefixedPrompt() async throws {
        let fixture = try fixture(followup: true); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let answer = try await fixture.adapter().reply("Follow-up", binding: fixture.binding, onPrepared: { _ in }, onBinding: { _ in })
        XCTAssertEqual(answer, "ANSWER")
        let inputs = fixture.calls().filter { $0["tool"] as? String == "type_text" }
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual((inputs[0]["arguments"] as? [String: Any])?["text"] as? String, "Follow-up")
    }
    func testDotFirstPromptAndFollowupPreserveOngoingIdentity() async throws {
        for followup in [false, true] {
            let fixture = try fixture(kind: .dots, followup: followup); defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let recorded = ChatGPTRecordedBindings()
            let answer = try await fixture.adapter().reply(followup ? "Follow-up" : "First question", binding: fixture.binding, onSubmitAction: {
                XCTAssertEqual(try? String(contentsOf: fixture.directory.appendingPathComponent("native-draft"), encoding: .utf8), followup ? "Follow-up" : fixture.binding.firstMessage("First question"))
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("submitted-draft").path))
                await recorded.submit()
            }, onPrepared: { await recorded.prepare($0) }, onBinding: { await recorded.bind($0) })
            XCTAssertEqual(answer, "ANSWER")
            let bound = await recorded.bound
            XCTAssertEqual(bound.first?.title, "Example Dot")
            XCTAssertEqual(bound.first?.firstPrompt, fixture.binding.firstMessage("First question"))
            let events = await recorded.events
            XCTAssertEqual(events, ["prepared", "submit", "bound"])
            XCTAssertEqual(fixture.calls().filter { $0["tool"] as? String == "click" }.count, 1)
            XCTAssertEqual(fixture.calls().filter { $0["tool"] as? String == "type_text" }.count, followup ? 1 : 2)
        }
    }
    func testUnknownSendResultIsObservedWithoutSecondSubmission() async throws {
        let fixture = try fixture(kind: .dots, unknownSend: true); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let answer = try await fixture.adapter().reply("First question", binding: fixture.binding, onPrepared: { _ in }, onBinding: { _ in })
        XCTAssertEqual(answer, "ANSWER")
        XCTAssertEqual(fixture.calls().filter { $0["tool"] as? String == "click" }.count, 1)
        XCTAssertEqual(fixture.calls().filter { $0["tool"] as? String == "type_text" }.count, 2)
    }
    func testWrongDriverWindowDoesNotReserveOrTypePrompt() async throws {
        let fixture = try fixture(wrongPID: true); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        do {
            _ = try await fixture.adapter().reply("First question", binding: fixture.binding, onPrepared: { _ in XCTFail("Invalid driver window must not reserve a pending send") }, onBinding: { _ in XCTFail("Wrong window cannot bind") })
            XCTFail("Wrong window must block input")
        } catch { XCTAssertTrue(error.localizedDescription.contains("input check")) }
        XCTAssertTrue(fixture.calls().allSatisfy { !["click", "type_text", "press_key"].contains($0["tool"] as? String ?? "") })
    }

    func testSavedChatGPTReopensFramelessSidebarRowFromDotBeforeFollowup() async throws {
        let fixture = try fixture(followup: true, reopen: true); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let answer = try await fixture.adapter().reply("Follow-up", binding: fixture.binding, onPrepared: { _ in }, onBinding: { _ in })
        XCTAssertEqual(answer, "ANSWER")
        let mutations = fixture.calls().filter { ["click", "type_text"].contains($0["tool"] as? String ?? "") }
        XCTAssertEqual(mutations.map { $0["tool"] as? String }, ["click", "type_text", "click"])
        XCTAssertEqual((mutations[1]["arguments"] as? [String: Any])?["text"] as? String, "Follow-up")
        XCTAssertEqual(try String(contentsOf: fixture.stage, encoding: .utf8), "3")
    }
    func testSavedChatGPTReopensZeroHeightSidebarRowUsingUniqueSemanticIdentity() async throws {
        let f = try fixture(followup: true, reopen: true, zeroHeightSidebar: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let answer = try await f.adapter().reply("Follow-up", binding: f.binding, onPrepared: { _ in }, onBinding: { _ in })
        XCTAssertEqual(answer, "ANSWER")
        let navigation = try XCTUnwrap(f.calls().first { $0["tool"] as? String == "click" })
        let args = try XCTUnwrap(navigation["arguments"] as? [String: Any])
        XCTAssertNotNil(args["element_token"])
        XCTAssertNil(args["x"])
        XCTAssertEqual(try String(contentsOf: f.directory.appendingPathComponent("submitted-draft"), encoding: .utf8), "Follow-up")
    }
    func testLegacyGenericFallbackRecoversOnlyTheAlreadyOpenExactComparison() async throws {
        let fixture = try fixture(followup: true, fallbackResume: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var legacy = fixture.binding
        legacy.fallbackTitle = "ChatGPT"
        let recovered = try await fixture.adapter().prepare(comparisonID: legacy.comparisonID, kind: .chatgpt, binding: legacy)
        XCTAssertEqual(recovered.fallbackTitle, "Automatic title")
        XCTAssertFalse(fixture.calls().contains { ["click", "type_text", "press_key"].contains($0["tool"] as? String ?? "") })
        legacy.firstPrompt = "Another conversation"
        do {
            _ = try await fixture.adapter().prepare(comparisonID: legacy.comparisonID, kind: .chatgpt, binding: legacy)
            XCTFail("A generic title cannot identify another conversation")
        } catch { }
        XCTAssertFalse(fixture.calls().contains { ["click", "type_text", "press_key"].contains($0["tool"] as? String ?? "") })
    }
    func testDuplicateSavedSidebarTitleNeverNavigatesOrTypes() async throws {
        let fixture = try fixture(followup: true, reopen: true, duplicateTitle: true); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        do {
            _ = try await fixture.adapter().reply("Follow-up", binding: fixture.binding, onPrepared: { _ in XCTFail("Duplicate title must not reserve input") }, onBinding: { _ in XCTFail("Duplicate title cannot bind") })
            XCTFail("Duplicate saved title must block navigation")
        } catch { XCTAssertTrue(error.localizedDescription.contains("ambiguous")) }
        XCTAssertTrue(fixture.calls().allSatisfy { !["click", "type_text", "press_key"].contains($0["tool"] as? String ?? "") })
    }

    func testMultilinePromptIsConstructedByActualChunkAndShiftReturnEvents() async throws {
        let question = "Line one\n\nLine three\n"
        for kind in [ChatGPTAppKind.chatgpt, .dots] {
            let fixture = try fixture(kind: kind, question: question); defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let answer = try await fixture.adapter().reply(question, binding: fixture.binding, onPrepared: { _ in }, onBinding: { _ in })
            XCTAssertEqual(answer, "ANSWER")
            XCTAssertEqual(try String(contentsOf: fixture.directory.appendingPathComponent("submitted-draft"), encoding: .utf8), fixture.binding.firstMessage(question))
            let inputs = fixture.calls().filter { $0["tool"] as? String == "type_text" }.compactMap { $0["arguments"] as? [String: Any] }
            XCTAssertTrue(inputs.allSatisfy { !(($0["text"] as? String) ?? "").contains("\n") })
            let newlines = fixture.calls().filter { $0["tool"] as? String == "press_key" && ($0["arguments"] as? [String: Any])?["modifiers"] as? [String] == ["shift"] }
            XCTAssertEqual(newlines.count, 5)
        }
    }
    func testMissingNewlineEffectPreservesPartialDraftAndNeverSubmitsOrReplays() async throws {
        let fixture = try fixture(kind: .dots, dropNewline: true); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let recorded = ChatGPTRecordedBindings()
        do {
            _ = try await fixture.adapter().reply("First question", binding: fixture.binding, onPrepared: { await recorded.prepare($0) }, onBinding: { _ in XCTFail("Incomplete draft must not bind") })
            XCTFail("Missing Shift-Return effect must stop input")
        } catch { XCTAssertTrue(error.localizedDescription.contains("exact prepared draft")) }
        XCTAssertEqual(fixture.calls().filter { $0["tool"] as? String == "type_text" }.count, 1)
        XCTAssertEqual(fixture.calls().filter { $0["tool"] as? String == "press_key" }.count, 1)
        XCTAssertFalse(fixture.calls().contains { $0["tool"] as? String == "click" })
        XCTAssertEqual(try String(contentsOf: fixture.directory.appendingPathComponent("native-draft"), encoding: .utf8), "[msgblast comparison AA000000-0000-0000-0000-000000000001]")
        let prepared = await recorded.prepared
        XCTAssertEqual(prepared.count, 1)
    }

    func testLongLineUsesBoundedFocusedChunksWithoutMovingCaret() async throws {
        let question = String(repeating: "abcdefghij", count: 80)
        let fixture = try fixture(kind: .dots, question: question); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let answer = try await fixture.adapter().reply(question, binding: fixture.binding, onPrepared: { _ in }, onBinding: { _ in })
        XCTAssertEqual(answer, "ANSWER")
        XCTAssertEqual(try String(contentsOf: fixture.directory.appendingPathComponent("submitted-draft"), encoding: .utf8), fixture.binding.firstMessage(question))
        let inputs = fixture.calls().filter { $0["tool"] as? String == "type_text" }.compactMap { $0["arguments"] as? [String: Any] }
        XCTAssertEqual(inputs.count, 5)
        XCTAssertTrue(inputs.allSatisfy { (($0["text"] as? String) ?? "").count <= 256 })
        XCTAssertNotNil(inputs.first?["x"])
        XCTAssertTrue(inputs.dropFirst().allSatisfy { $0["x"] == nil && $0["y"] == nil && $0["element_token"] == nil })
    }

    func testChatGPTConnectionFromDotSetupOpensChatWithoutTypingOrSending() async throws {
        let fixture = try fixture(dotSetup: true); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.adapter().checkAvailable(kind: .chatgpt)
        let mutations = fixture.calls().filter { ["click", "type_text", "press_key"].contains($0["tool"] as? String ?? "") }
        XCTAssertEqual(mutations.count, 1)
        XCTAssertEqual(mutations.first?["tool"] as? String, "click")
        XCTAssertEqual(try String(contentsOf: fixture.stage, encoding: .utf8), "1")
    }
    func testChatGPTConnectionFromDotSetupHandlesNewChatDefaultingToWork() async throws {
        let fixture = try fixture(dotSetup: true, newChatWork: true); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.adapter().checkAvailable(kind: .chatgpt)
        let mutations = fixture.calls().filter { ["click", "type_text", "press_key"].contains($0["tool"] as? String ?? "") }
        XCTAssertEqual(mutations.count, 2)
        XCTAssertTrue(mutations.allSatisfy { $0["tool"] as? String == "click" })
        XCTAssertEqual(try String(contentsOf: fixture.stage, encoding: .utf8), "2")
    }
    func testDotsConnectionFromSetupExplainsRequiredSetupWithoutCreatingDot() async throws {
        let fixture = try fixture(dotSetup: true); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        do { try await fixture.adapter().checkAvailable(kind: .dots); XCTFail("A missing Dot cannot be ready") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Create your Dot in ChatGPT")) }
        XCTAssertFalse(fixture.calls().contains { ["click", "type_text", "press_key"].contains($0["tool"] as? String ?? "") })
    }
    func testDotsConnectionChecksDotDestinationInsteadOfAcceptingIdleChatGPT() async throws {
        let fixture = try fixture(dotSetup: true, dotSetupDestination: true); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        do { try await fixture.adapter().checkAvailable(kind: .dots); XCTFail("Idle ChatGPT does not prove a Dot exists") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Create your Dot in ChatGPT")) }
        let mutations = fixture.calls().filter { ["click", "type_text", "press_key"].contains($0["tool"] as? String ?? "") }
        XCTAssertEqual(mutations.count, 1)
        XCTAssertEqual(mutations.first?["tool"] as? String, "click")
        XCTAssertEqual(try String(contentsOf: fixture.stage, encoding: .utf8), "1")
    }
    func testDotsConnectionWaitsForNavigationWithoutRepeatingClick() async throws {
        let fixture = try fixture(dotSetup: true, dotSetupDestination: true); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        do { try await fixture.adapter(dotTransitionOnce: true).checkAvailable(kind: .dots); XCTFail("A Dot requiring setup cannot be ready") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Create your Dot in ChatGPT")) }
        let mutations = fixture.calls().filter { ["click", "type_text", "press_key"].contains($0["tool"] as? String ?? "") }
        XCTAssertEqual(mutations.count, 1)
        XCTAssertEqual(mutations.first?["tool"] as? String, "click")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("dot-transition-read").path))
    }
    func testDotsConnectsFromPageWithoutSupportedComposerWithoutTypingOrSending() async throws {
        let fixture = try fixture(kind: .dots, unreadableStart: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        XCTAssertThrowsError(try ChatGPTAppObservation(root: fixture.roots[0])) { error in
            guard case ChatGPTObservationError.composerUnavailable = error else { return XCTFail("Must reproduce the unavailable composer failure") }
        }
        try await fixture.adapter().checkAvailable(kind: .dots)
        let mutations = fixture.calls().filter { ["click", "type_text", "press_key"].contains($0["tool"] as? String ?? "") }
        XCTAssertEqual(mutations.count, 1)
        XCTAssertEqual(mutations.first?["tool"] as? String, "click")
        XCTAssertEqual(try String(contentsOf: fixture.stage, encoding: .utf8), "1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("native-draft").path))
    }
    func testDotFirstPromptCanNavigatePastUnrelatedUnsupportedComposer() async throws {
        let fixture = try fixture(kind: .dots, unreadableStart: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let answer = try await fixture.adapter().reply("First question", binding: fixture.binding, onPrepared: { _ in }, onBinding: { _ in })
        XCTAssertEqual(answer, "ANSWER")
        XCTAssertEqual(try String(contentsOf: fixture.directory.appendingPathComponent("submitted-draft"), encoding: .utf8), fixture.binding.firstMessage("First question"))
        let clicks = fixture.calls().filter { $0["tool"] as? String == "click" }
        XCTAssertEqual(clicks.count, 2, "One Dot navigation and exactly one submission")
    }
    func testNewChatGPTPromptFromDotSetupUsesDedicatedChat() async throws {
        let fixture = try fixture(dotSetup: true); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let answer = try await fixture.adapter().reply("First question", binding: fixture.binding, onPrepared: { _ in }, onBinding: { _ in })
        XCTAssertEqual(answer, "ANSWER")
        XCTAssertEqual(try String(contentsOf: fixture.directory.appendingPathComponent("submitted-draft"), encoding: .utf8), fixture.binding.firstMessage("First question"))
    }

    func testExistingWorkTaskOpensNewChatWithoutChangingGlobalModeOrTypingIntoTask() async throws {
        let fixture = try fixture(existingWork: true); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let answer = try await fixture.adapter().reply("First question", binding: fixture.binding, onPrepared: { _ in }, onBinding: { _ in })
        XCTAssertEqual(answer, "ANSWER")
        let mutations = fixture.calls().filter { ["click", "type_text", "press_key"].contains($0["tool"] as? String ?? "") }
        XCTAssertEqual(mutations.first?["tool"] as? String, "click")
        XCTAssertTrue(((mutations.first?["arguments"] as? [String: Any])?["element_token"] as? String)?.hasPrefix("0:") == true)
        XCTAssertEqual(try String(contentsOf: fixture.directory.appendingPathComponent("submitted-draft"), encoding: .utf8), fixture.binding.firstMessage("First question"))
    }

    func testOwnPartialOutgoingBubbleSettlesWithoutSecondSendOrPrematureBinding() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let recorded = ChatGPTRecordedBindings()
        let answer = try await fixture.adapter(partialOutgoingOnce: true).reply("First question", binding: fixture.binding, onPrepared: { await recorded.prepare($0) }, onBinding: { binding in
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("full-outgoing-read").path))
            await recorded.bind(binding)
        })
        XCTAssertEqual(answer, "ANSWER")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("partial-outgoing-read").path))
        let prepared = await recorded.prepared, bound = await recorded.bound
        XCTAssertEqual(prepared.count, 1)
        XCTAssertEqual(bound.first?.title, fixture.binding.dedicatedTitle)
        XCTAssertEqual(fixture.calls().filter { $0["tool"] as? String == "click" }.count, 2)
        XCTAssertEqual(try String(contentsOf: fixture.stage, encoding: .utf8), "8")
    }
    func testThinkingStatusCannotBecomeOutgoingTextOrBeAttributedBeforeItSettles() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let answer = try await f.adapter(thinkingStatusOnce: true).reply("First question", binding: f.binding, onPrepared: { _ in }, onBinding: { _ in
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("full-outgoing-read").path))
        })
        XCTAssertEqual(answer, "ANSWER")
        XCTAssertEqual(f.calls().filter { $0["tool"] as? String == "click" }.count, 2)
        XCTAssertEqual(try String(contentsOf: f.directory.appendingPathComponent("submitted-draft"), encoding: .utf8), f.binding.firstMessage("First question"))
    }
    func testDotOlderHistoryCanLoadAfterSendWithoutChangingTheVerifiedBaseline() async throws {
        let f = try fixture(kind: .dots, followup: true)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let answer = try await f.adapter(prependHistoryAfterSend: true).reply("Follow-up", binding: f.binding, onPrepared: { _ in }, onBinding: { _ in })
        XCTAssertEqual(answer, "ANSWER")
        XCTAssertEqual(f.calls().filter { $0["tool"] as? String == "click" }.count, 1)
        XCTAssertEqual(try String(contentsOf: f.directory.appendingPathComponent("submitted-draft"), encoding: .utf8), "Follow-up")
    }
    func testForeignOutgoingStillStopsInsteadOfWaitingOrAttributing() async throws {
        let fixture = try fixture(kind: .dots, wrongOutgoing: true); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        do {
            _ = try await fixture.adapter().reply("First question", binding: fixture.binding, onPrepared: { _ in }, onBinding: { _ in XCTFail("Foreign outgoing must never bind") })
            XCTFail("Foreign outgoing must block attribution")
        } catch { XCTAssertTrue(error.localizedDescription.contains("outgoing message did not match")) }
        XCTAssertEqual(fixture.calls().filter { $0["tool"] as? String == "click" }.count, 1)
    }

    func testConfirmedAnswerSurvivesRenameFailureAndFallbackResumesWithoutReplay() async throws {
        let fixture = try fixture(renameFailure: true); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let recorded = ChatGPTRecordedBindings()
        let answer = try await fixture.adapter().reply("First question", binding: fixture.binding, onPrepared: { await recorded.prepare($0) }, onBinding: { binding in
            XCTAssertEqual(try String(contentsOf: fixture.stage, encoding: .utf8), "5")
            await recorded.bind(binding)
        })
        XCTAssertEqual(answer, "ANSWER")
        let bound = await recorded.bound
        let saved = try XCTUnwrap(bound.first)
        XCTAssertEqual(bound.count, 1)
        XCTAssertEqual(saved.title, saved.dedicatedTitle)
        XCTAssertEqual(saved.fallbackTitle, "Automatic title")
        XCTAssertEqual(saved.firstPrompt, fixture.binding.firstMessage("First question"))
        XCTAssertEqual(try String(contentsOf: fixture.stage, encoding: .utf8), "5")
        let resume = try self.fixture(followup: true, fallbackResume: true); defer { try? FileManager.default.removeItem(at: resume.directory) }
        XCTAssertEqual(resume.binding, saved)
        let followup = try await resume.adapter().reply("Follow-up", binding: saved, onPrepared: { _ in }, onBinding: { _ in })
        XCTAssertEqual(followup, "ANSWER")
        let input = resume.calls().filter { $0["tool"] as? String == "type_text" }
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual((input.first?["arguments"] as? [String: Any])?["text"] as? String, "Follow-up")
        XCTAssertEqual(resume.calls().filter { $0["tool"] as? String == "click" }.count, 1)
    }
    func testConfirmedBindingStoreFailurePropagatesBeforeRename() async throws {
        enum StoreFailure: Error { case denied }
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        do {
            _ = try await fixture.adapter().reply("First question", binding: fixture.binding, onPrepared: { _ in }, onBinding: { _ in throw StoreFailure.denied })
            XCTFail("Storage failure must remain visible to the caller")
        } catch StoreFailure.denied { }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try String(contentsOf: fixture.stage, encoding: .utf8), "5")
        XCTAssertEqual(fixture.calls().filter { $0["tool"] as? String == "click" }.count, 1)
    }

    func testFallbackBindingAcceptsSuccessfulRenameWhoseCompletionReadFailed() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let recorded = ChatGPTRecordedBindings()
        let answer = try await fixture.adapter(renameReadFailure: true).reply("First question", binding: fixture.binding, onPrepared: { _ in }, onBinding: { await recorded.bind($0) })
        XCTAssertEqual(answer, "ANSWER")
        XCTAssertEqual(try String(contentsOf: fixture.stage, encoding: .utf8), "8")
        let bindings = await recorded.bound
        let saved = try XCTUnwrap(bindings.first)
        let resume = try self.fixture(followup: true, fallbackResume: true, renamedResume: true); defer { try? FileManager.default.removeItem(at: resume.directory) }
        let followup = try await resume.adapter().reply("Follow-up", binding: saved, onPrepared: { _ in }, onBinding: { _ in })
        XCTAssertEqual(followup, "ANSWER")
        XCTAssertEqual(resume.calls().filter { $0["tool"] as? String == "click" }.count, 1)
    }
    func testFallbackSidebarReopenRequiresUniqueTitleAndExactFirstPrompt() async throws {
        let fixture = try fixture(followup: true, reopen: true, fallbackResume: true); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let answer = try await fixture.adapter().reply("Follow-up", binding: fixture.binding, onPrepared: { _ in }, onBinding: { _ in })
        XCTAssertEqual(answer, "ANSWER")
        XCTAssertEqual(fixture.calls().filter { $0["tool"] as? String == "click" }.count, 2)
        let ambiguous = try self.fixture(followup: true, reopen: true, duplicateTitle: true, fallbackResume: true); defer { try? FileManager.default.removeItem(at: ambiguous.directory) }
        do {
            _ = try await ambiguous.adapter().reply("Follow-up", binding: ambiguous.binding, onPrepared: { _ in XCTFail("Ambiguous fallback cannot reserve") }, onBinding: { _ in XCTFail("Ambiguous fallback cannot bind") })
            XCTFail("Duplicate fallback sidebar rows must block navigation")
        } catch { XCTAssertTrue(error.localizedDescription.contains("ambiguous")) }
        XCTAssertFalse(ambiguous.calls().contains { ["click", "type_text"].contains($0["tool"] as? String ?? "") })
    }

    func testCancellationDuringRenamePropagatesAfterConfirmedBindingIsStored() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let recorded = ChatGPTRecordedBindings()
        do {
            _ = try await fixture.adapter(renameReadCancellation: true).reply("First question", binding: fixture.binding, onPrepared: { _ in }, onBinding: { await recorded.bind($0) })
            XCTFail("Cancellation must not be swallowed as title cleanup failure")
        } catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
        let bound = await recorded.bound
        XCTAssertEqual(bound.first?.fallbackTitle, "Automatic title")
        XCTAssertEqual(fixture.calls().filter { $0["tool"] as? String == "click" }.count, 2)
    }

}
