import XCTest
@testable import msgblastCore

final class DesktopAppConversationTests: XCTestCase {
    func testNativeWindowLookupFindsExactWindowWhenAXWindowsOmitsAnotherDesktop() throws {
        struct Window { let role: String; let id: UInt32 }
        let expectedToken = Data([42, 0, 0, 0, 0, 0, 0, 0, 0x6f, 0x63, 0x6f, 0x63, 46, 0, 0, 0, 0, 0, 0, 0])
        var probes = [Data]()
        let found: Window? = DesktopNativeWindowLookup.find(pid: 42, windowID: 2872, listed: [],
            ownerPID: { 42 }, number: { $0.id }, isWindow: { $0.role == "AXWindow" }, remote: { token in
                probes.append(token)
                if token == expectedToken { return Window(role: "AXWindow", id: 2872) }
                return Window(role: probes.count == 1 ? "AXButton" : "AXWindow", id: probes.count == 1 ? 2872 : 2866)
            })
        XCTAssertEqual(try XCTUnwrap(found).id, 2872, "A window on another desktop must not require activation or an AXWindows entry")
        XCTAssertEqual(probes.last, expectedToken, "Only the exact AXWindow may be used; controls and other windows are not substitutes")
    }

    func testNativeWindowLookupRejectsDifferentOrMissingWindowServerOwner() {
        for owner in [43, nil] as [Int?] {
            var probes = 0
            let found: UInt32? = DesktopNativeWindowLookup.find(pid: 42, windowID: 31, listed: [],
                ownerPID: { owner }, number: { $0 }, isWindow: { _ in true }, remote: { _ in probes += 1; return 31 })
            XCTAssertNil(found)
            XCTAssertEqual(probes, 0, "Never probe another process or a window that disappeared")
        }
    }

    func testNativeWindowLookupUsesListedWindowAndRejectsAmbiguousIdentityWithoutProbing() {
        for listed: [UInt32] in [[31], [31, 31]] {
            var probes = 0
            let found = DesktopNativeWindowLookup.find(pid: 42, windowID: 31, listed: listed,
                ownerPID: { 42 }, number: { $0 }, isWindow: { _ in true }, remote: { _ in probes += 1; return 31 })
            XCTAssertEqual(found, listed.count == 1 ? 31 : nil)
            XCTAssertEqual(probes, 0)
        }
    }

    func testNativeWindowLookupStopsWhenDeadlineExpiresOrCandidateLimitIsReached() {
        for timed in [true, false] {
            var probes = 0, tick: TimeInterval = 0
            let found: UInt32? = DesktopNativeWindowLookup.find(pid: 42, windowID: 31, listed: [],
                ownerPID: { 42 }, number: { $0 }, isWindow: { _ in true }, remote: { _ in probes += 1; return nil },
                now: { if timed { tick += 0.1 }; return tick })
            XCTAssertNil(found)
            if timed { XCTAssertGreaterThan(probes, 0); XCTAssertLessThanOrEqual(probes, 3) }
            else { XCTAssertEqual(probes, 2_000) }
        }
    }

    func testNativeWindowLookupFailsClosedWhenRemoteLookupIsUnavailable() {
        let found: UInt32? = DesktopNativeWindowLookup.find(pid: 42, windowID: 31, listed: [],
            ownerPID: { 42 }, number: { $0 }, isWindow: { _ in true }, remote: nil)
        XCTAssertNil(found)
    }

    func testInactiveMsgblastUsesOnlyVisibleMainWindowAndRejectsAmbiguity() throws {
        let first = DesktopAppConversation.Target(pid: 42, window: 101)
        let second = DesktopAppConversation.Target(pid: 42, window: 102)
        XCTAssertEqual(try DesktopAppConversation.hostWindow(key: nil, main: nil, visible: [first]), first)
        XCTAssertEqual(try DesktopAppConversation.hostWindow(key: second, main: first, visible: [first, second]), second)
        XCTAssertEqual(try DesktopAppConversation.hostWindow(key: nil, main: first, visible: [first, second]), first)
        XCTAssertThrowsError(try DesktopAppConversation.hostWindow(key: nil, main: nil, visible: []))
        XCTAssertThrowsError(try DesktopAppConversation.hostWindow(key: nil, main: nil, visible: [first, second]))
    }

    func testNativeHostFocusRequiresThisProcessAndExactUnblockedKeyWindow() {
        let host = DesktopAppConversation.Target(pid: 42, window: 101)
        XCTAssertTrue(DesktopAppConversation.hostHasFocus(host, processID: 42, keyWindow: 101, active: true, blocked: false))
        for (pid, window, active, blocked): (Int, Int?, Bool, Bool) in [
            (43, 101, true, false), (42, 102, true, false), (42, nil, true, false),
            (42, 101, false, false), (42, 101, true, true)
        ] {
            XCTAssertFalse(DesktopAppConversation.hostHasFocus(host, processID: pid, keyWindow: window, active: active, blocked: blocked))
        }
    }

    func testHostSetupSheetRestorationRequiresTheOriginalAttachedSheet() {
        let host = DesktopAppConversation.Target(pid: 42, window: 101, expectedSheet: 102)
        XCTAssertTrue(DesktopAppConversation.hostHasFocus(host, processID: 42, keyWindow: 102, active: true, blocked: false))
        for (pid, window, active, blocked): (Int, Int?, Bool, Bool) in [
            (42, 101, true, false), (42, 103, true, false), (42, nil, true, false),
            (43, 102, true, false), (42, 102, false, false), (42, 102, true, true)
        ] {
            XCTAssertFalse(DesktopAppConversation.hostHasFocus(host, processID: pid, keyWindow: window, active: active, blocked: blocked))
        }
    }

    func testDesktopAgentsRemainSeparateFromExistingAccounts() {
        XCTAssertTrue(WebProvider.museApp.usesNativeConversation)
        XCTAssertTrue(WebProvider.grokBotApp.usesNativeConversation)
        XCTAssertTrue(WebProvider.wabi.usesNativeConversation)
        XCTAssertFalse(WebProvider.muse.usesNativeConversation)
        XCTAssertNil(WebProvider.grokbot.desktopApp)
        XCTAssertNotEqual(WebProvider.museApp.storageFilename, WebProvider.muse.storageFilename)
        XCTAssertNotEqual(WebProvider.grokBotApp.storageFilename, WebProvider.grokbot.storageFilename)
    }

    func testReplyAttributionExcludesSidebarAndComposerText() throws {
        let snapshot = try decode([
            element("AXLink", "Wabi Old sidebar preview"),
            element("AXStaticText", "Old sidebar preview"),
            element("AXStaticText", "Background test"),
            element("AXPopUpButton", "Add reaction"),
            element("AXStaticText", "12:12 PM"),
            element("AXStaticText", "Read"),
            element("AXStaticText", "WABI-OK"),
            element("AXPopUpButton", "Add reaction"),
            element("AXStaticText", "12:12 PM"),
            element("AXTextArea", "Message", value: "Say something…"),
            element("AXHeading", "Wabi")
        ])
        XCTAssertEqual(try snapshot.reply(after: "Background test", app: .wabi), "WABI-OK")
        XCTAssertEqual(try snapshot.conversation(app: .wabi), "Wabi")
        XCTAssertEqual(try snapshot.composer(app: .wabi).draft, "")
    }

    func testGrokReplyUsesSpeakerAndRejectsAnotherOutgoingMessage() throws {
        let snapshot = try decode([
            element("AXHeading", "Test Bot"),
            element("AXStaticText", "You"), element("AXStaticText", "Background test"),
            element("AXStaticText", "12:12 PM"), element("AXStaticText", "Test Bot"),
            element("AXStaticText", "GROK-OK"), element("AXStaticText", "12:12 PM"),
            element("AXTextArea", "Prompt", value: "Message Test Bot")
        ])
        XCTAssertEqual(try snapshot.reply(after: "Background test", app: .grokBot), "GROK-OK")
        let interrupted = try decode([
            element("AXHeading", "Test Bot"), element("AXStaticText", "You"), element("AXStaticText", "Background test"),
            element("AXStaticText", "You"), element("AXStaticText", "Unrelated user message"),
            element("AXTextArea", "Prompt", value: "Message Test Bot")
        ])
        XCTAssertThrowsError(try interrupted.reply(after: "Background test", app: .grokBot))
    }

    func testGrokWorkingStatusBelongsToSelectedBotAndCannotComeFromMessageText() throws {
        let chat = [element("AXHeading", "Test Bot"), element("AXStaticText", "You"),
                    element("AXStaticText", "Test Bot is working"),
                    element("AXTextArea", "Prompt", value: "Message Test Bot")]
        XCTAssertFalse(try decode(chat).grokIsWorking)
        XCTAssertFalse(try decode(chat + [element("AXStaticText", "Other Bot is working")]).grokIsWorking)
        XCTAssertTrue(try decode(chat + [element("AXStaticText", "Test Bot is working")]).grokIsWorking)
    }

    func testGrokTimeDividerBeforeNewOutgoingDoesNotCountAsForeignMessage() throws {
        let old = ["You", "Earlier question", "Test Bot", "Earlier answer", "7:10 PM"]
        func view(_ text: [String]) throws -> DesktopAppSnapshot {
            try decode([element("AXHeading", "Test Bot")] + text.map { element("AXStaticText", $0) } +
                       [element("AXTextArea", "Prompt", value: "Message Test Bot")])
        }
        let anchor = try view(old).grokHistoryAnchor()
        let result = try view(old + ["Today 10:35 PM", "You", "Requested prompt", "10:35 PM", "Test Bot", "Observed answer", "10:35 PM"])
        XCTAssertEqual(try result.grokReply(after: "Requested prompt", anchor: anchor), "Observed answer")
        let interrupted = try view(old + ["Today 10:35 PM", "Test Bot", "Unsolicited update", "You", "Requested prompt", "Test Bot", "Observed answer"])
        XCTAssertThrowsError(try interrupted.grokReply(after: "Requested prompt", anchor: anchor))
    }

    func testGrokEmptyAnchorCannotAttributeRestoredOldReply() throws {
        let restored = try decode([element("AXHeading", "Test Bot"), element("AXStaticText", "You"),
                                   element("AXStaticText", "Repeated prompt"), element("AXStaticText", "Test Bot"),
                                   element("AXStaticText", "Old answer"), element("AXTextArea", "Prompt", value: "Message Test Bot")])
        let empty = DesktopAppSnapshot.GrokHistoryAnchor(history: [], bot: "Test Bot")
        XCTAssertThrowsError(try restored.grokReply(after: "Repeated prompt", anchor: empty))
    }

    func testGrokRecentAnchorRejectsMissingDuplicateAndForeignHistory() throws {
        func view(_ text: [String]) throws -> DesktopAppSnapshot {
            try decode([element("AXHeading", "Test Bot")] + text.map { element("AXStaticText", $0) } +
                       [element("AXTextArea", "Prompt", value: "Message Test Bot")])
        }
        let baseline = ["You", "Earlier question", "Test Bot", "Earlier answer", "12:00 PM"]
        let fresh = ["You", "Requested prompt", "Test Bot", "Fresh answer", "12:01 PM"]
        let anchor = try view(baseline).grokHistoryAnchor()
        XCTAssertNil(try view(baseline).grokReply(after: "Requested prompt", anchor: anchor))
        XCTAssertEqual(try view(baseline + fresh).grokReply(after: "Requested prompt", anchor: anchor), "Fresh answer")
        for changed in [
            ["You", "Earlier question", "Test Bot", "Edited answer", "12:00 PM"] + fresh,
            baseline + baseline + fresh,
            baseline + ["You", "Foreign prompt", "Test Bot", "Foreign answer"] + fresh,
            baseline + ["Test Bot", "Unsolicited update"] + fresh
        ] {
            XCTAssertThrowsError(try view(changed).grokReply(after: "Requested prompt", anchor: anchor))
        }
    }

    func testGrokConversationHeaderIgnoresHeadingsInsideReplies() throws {
        var header = element("AXHeading", "Test Bot")
        header["element_index"] = 2
        var details = element("AXButton", "View conversation details")
        details["parent_index"] = 2
        let snapshot = try decode([header, details,
                                   element("AXHeading", "A heading in the bot's answer"),
                                   element("AXTextArea", "Prompt", value: "")])
        XCTAssertEqual(try snapshot.conversation(app: .grokBot), "Test Bot")
    }

    func testGrokEmptyParagraphRequiresNativeEmptyEditorEvidence() {
        XCTAssertEqual(GrokBotAppProfile.draftValue("\n", emptyEditor: true), "")
        XCTAssertEqual(GrokBotAppProfile.draftValue("\n", emptyEditor: false), "\n")
        for text in ["Message Test Bot", "Type your answer, or talk about something else", "Keep this draft"] {
            XCTAssertEqual(GrokBotAppProfile.draftValue(text, emptyEditor: true), text)
        }
    }

    func testGrokTrailingHardBreakReadbackRemovesOnlyTheNativePaddingCharacter() {
        for (raw, expected) in [
            ("\n\n", "\n"),
            ("First\n\n", "First\n"),
            ("First\n\n\n", "First\n\n"),
            ("\nFirst\n\n\n", "\nFirst\n\n"),
            ("First\nSecond", "First\nSecond"),
            ("First\n\nSecond", "First\n\nSecond")
        ] {
            XCTAssertEqual(GrokBotAppProfile.draftValue(raw, emptyEditor: false), expected)
        }
    }

    func testGrokBotListSeparatesExistingBotsFromActionsAndUnreadLabels() throws {
        let elements: [[String: Any]] = [
            ["role": "AXButton", "label": "Main, Main Bot, Unread activity", "element_index": 1, "element_token": "s00000001:main"],
            ["role": "AXImage", "label": "Main Bot", "parent_index": 1],
            ["role": "AXList", "element_index": 3],
            ["role": "AXButton", "label": "Research, Unread activity", "element_index": 4, "parent_index": 3, "element_token": "s00000001:research"],
            ["role": "AXButton", "label": "New Bot", "element_index": 5, "element_token": "s00000001:new"],
            ["role": "AXSplitter", "label": "Resize sidebar"]
        ]
        let snapshot = try JSONDecoder().decode(DesktopAppSnapshot.self, from: JSONSerialization.data(withJSONObject: ["elements": elements]))
        XCTAssertEqual(try snapshot.grokBots().map(\.name), ["Main", "Research"])
    }

    func testGrokUnreadMainBotDoesNotRequireItsReplacedIcon() throws {
        let snapshot = try JSONDecoder().decode(DesktopAppSnapshot.self, from: JSONSerialization.data(withJSONObject: ["elements": [
            ["role": "AXButton", "label": "chief, Main Bot, Unread activity", "element_index": 1, "element_token": "main"],
            ["role": "AXGroup", "label": "Unread activity", "parent_index": 1],
            ["role": "AXList", "element_index": 3],
            ["role": "AXButton", "label": "Research, Main Bot", "element_index": 4, "parent_index": 3, "element_token": "research"],
            ["role": "AXButton", "label": "New Bot", "element_index": 5, "element_token": "new"],
            ["role": "AXSplitter", "label": "Resize sidebar"]
        ]]))
        XCTAssertEqual(try snapshot.grokBots().map(\.name), ["chief", "Research, Main Bot"])
    }

    func testGrokRenderedMultilinePromptTracksFreshOccurrenceWithoutAcceptingChangedWords() throws {
        let text = "First line\nSecond line"
        let snapshot = try decode([
            element("AXHeading", "Test Bot"), element("AXStaticText", "You"), element("AXStaticText", "First line Second line"),
            element("AXStaticText", "Test Bot"), element("AXStaticText", "Old answer"),
            element("AXStaticText", "You"), element("AXStaticText", "First line Second line"),
            element("AXStaticText", "Test Bot"), element("AXStaticText", "Fresh answer"), element("AXTextArea", "Prompt", value: "Message Test Bot")
        ])
        XCTAssertEqual(try snapshot.outgoingCount(text, app: .grokBot), 2)
        XCTAssertEqual(try snapshot.reply(after: text, app: .grokBot, outgoingOccurrence: 2), "Fresh answer")
        XCTAssertNil(try snapshot.reply(after: "First line\nChanged line", app: .grokBot))
    }

    func testGrokSplitPromptFragmentsTrackOnlyTheFreshUserMessage() throws {
        let prompt = "First line\nSecond line"
        let snapshot = try decode([
            element("AXHeading", "Test Bot"),
            element("AXStaticText", "You"), element("AXStaticText", "First line"), element("AXStaticText", "Second line"),
            element("AXStaticText", "12:10 PM"), element("AXStaticText", "Test Bot"), element("AXStaticText", "Old answer"), element("AXStaticText", "12:11 PM"),
            element("AXStaticText", "You"), element("AXStaticText", "First line"), element("AXStaticText", "Second line"),
            element("AXStaticText", "12:12 PM"), element("AXStaticText", "Test Bot"), element("AXStaticText", "Fresh answer"), element("AXStaticText", "12:13 PM"),
            element("AXTextArea", "Prompt", value: "Message Test Bot")
        ])
        XCTAssertEqual(try snapshot.outgoingCount(prompt, app: .grokBot), 2)
        XCTAssertEqual(try snapshot.reply(after: prompt, app: .grokBot, outgoingOccurrence: 2), "Fresh answer")
        for changed in ["First line\nChanged line", "First line", "Second line"] {
            XCTAssertEqual(try snapshot.outgoingCount(changed, app: .grokBot), 0)
        }
    }

    func testGrokFragmentMatchingCannotJoinAcrossSpeakersOrAcceptAnEcho() throws {
        let snapshot = try decode([
            element("AXHeading", "Test Bot"),
            element("AXStaticText", "You"), element("AXStaticText", "First line"), element("AXStaticText", "12:12 PM"),
            element("AXStaticText", "Test Bot"), element("AXStaticText", "Second line"), element("AXStaticText", "12:13 PM"),
            element("AXStaticText", "Test Bot"), element("AXStaticText", "First line Second line"), element("AXStaticText", "12:14 PM"),
            element("AXTextArea", "Prompt", value: "Message Test Bot")
        ])
        XCTAssertEqual(try snapshot.outgoingCount("First line\nSecond line", app: .grokBot), 0)
        XCTAssertNil(try snapshot.reply(after: "First line\nSecond line", app: .grokBot))
        XCTAssertEqual(try snapshot.outgoingCount("Second line", app: .grokBot), 0)
    }

    func testSidebarPromptPreviewCannotBeUsedAsOutgoingMessage() throws {
        let snapshot = try decode([
            element("AXStaticText", "Background test"),
            element("AXSplitter", "Resize sidebar"),
            element("AXStaticText", "Old response"),
            element("AXTextArea", "Message", value: "Say something…"),
            element("AXHeading", "Wabi")
        ])
        XCTAssertNil(try snapshot.reply(after: "Background test", app: .wabi))
    }

    func testEchoedPromptIsReturnedAsReply() throws {
        let wabi = try decode([
            element("AXStaticText", "Echo this"), element("AXPopUpButton", "Add reaction"),
            element("AXStaticText", "Echo this"), element("AXPopUpButton", "Add reaction"),
            element("AXTextArea", "Message", value: "Say something…"), element("AXHeading", "Wabi")
        ])
        XCTAssertEqual(try wabi.reply(after: "Echo this", app: .wabi), "Echo this")
        let grok = try decode([
            element("AXHeading", "Test Bot"), element("AXStaticText", "You"),
            element("AXStaticText", "Echo this"), element("AXStaticText", "Test Bot"),
            element("AXStaticText", "Echo this"), element("AXTextArea", "Prompt", value: "Message Test Bot")
        ])
        XCTAssertEqual(try grok.reply(after: "Echo this", app: .grokBot), "Echo this")
    }

    func testShortRepliesThatResembleMetadataRemainMessageText() throws {
        for reply in ["Read", "Delivered", "Today", "12:12 PM", "Test Bot", "Wabi"] {
            let grok = try decode([
                element("AXHeading", "Test Bot"), element("AXStaticText", "You"),
                element("AXStaticText", "Question"), element("AXStaticText", "12:12 PM"),
                element("AXStaticText", "Test Bot"), element("AXStaticText", reply),
                element("AXStaticText", "12:12 PM"), element("AXTextArea", "Prompt", value: "Message Test Bot")
            ])
            XCTAssertEqual(try grok.reply(after: "Question", app: .grokBot), reply)
            let wabi = try decode([
                element("AXStaticText", "Question"), element("AXPopUpButton", "Add reaction"),
                element("AXButton", "Reply"), element("AXStaticText", "12:12 PM"),
                element("AXStaticText", "Read"), element("AXStaticText", reply),
                element("AXPopUpButton", "Add reaction"), element("AXButton", "Reply"),
                element("AXStaticText", "12:12 PM"), element("AXTextArea", "Message", value: "Say something…"),
                element("AXHeading", "Wabi")
            ])
            XCTAssertEqual(try wabi.reply(after: "Question", app: .wabi), reply)
        }
    }

    func testDraftAndHumanConversationAreNotAcceptedAsWabiAI() throws {
        let snapshot = try decode([
            element("AXTextArea", "Message", value: "Keep my draft"),
            element("AXHeading", "Someone else")
        ])
        XCTAssertEqual(try snapshot.composer(app: .wabi).draft, "Keep my draft")
        XCTAssertThrowsError(try snapshot.conversation(app: .wabi))
    }

    func testTruncatedSnapshotsCannotAuthorizeSendOrReply() throws {
        let data = try JSONSerialization.data(withJSONObject: ["elements_complete": false, "total_element_count": 200, "returned_element_count": 2,
            "elements": [element("AXTextArea", "Prompt"), element("AXHeading", "Test Bot")]])
        let snapshot = try JSONDecoder().decode(DesktopAppSnapshot.self, from: data)
        XCTAssertThrowsError(try snapshot.conversation(app: .grokBot))
    }

    func testMenuFirstSnapshotKeepsWindowComposerAndExcludesMenuControls() throws {
        let menu: [[String: Any]] = [
            ["role": "AXMenuBar", "element_index": 0],
            ["role": "AXTextArea", "label": "Prompt", "element_index": 1, "parent_index": 0],
            ["role": "AXHeading", "label": "Wrong bot", "element_index": 2, "parent_index": 0]
        ]
        let window: [[String: Any]] = [
            ["role": "AXWindow", "element_index": 11],
            ["role": "AXHeading", "label": "Test Bot", "element_index": 12, "parent_index": 11],
            ["role": "AXTextArea", "label": "Prompt", "element_token": "snapshot:13", "element_index": 13, "parent_index": 11]
        ]
        for elements in [menu + window, window + menu] {
            let snapshot = try JSONDecoder().decode(DesktopAppSnapshot.self, from: JSONSerialization.data(withJSONObject: [
                "elements": elements, "total_element_count": elements.count, "returned_element_count": elements.count
            ]))
            XCTAssertEqual(try snapshot.conversation(app: .grokBot), "Test Bot")
            XCTAssertEqual(try snapshot.composer(app: .grokBot).element.element_token, "snapshot:13")
            XCTAssertEqual(snapshot.body.first?.role, "AXWindow")
        }
        let menuOnly = try JSONDecoder().decode(DesktopAppSnapshot.self, from: JSONSerialization.data(withJSONObject: ["elements": menu]))
        XCTAssertThrowsError(try menuOnly.checkReadable())
    }

    func testWabiThreadOwnershipIsImmutableUniqueAndCompatibleWithOlderState() throws {
        let first = UUID(), second = UUID()
        let url = URL(string: "wabi://app/threads/aaaaaaaaaaaaaaaaaaaaaaaa")!
        var state = try JSONDecoder().decode(WebWorkspaceState.self, from: Data("{\"sessionID\":\"\(UUID())\"}".utf8))
        XCTAssertNil(try state.wabiConversation(for: first))
        try state.recordWabiConversation(url, for: first)
        XCTAssertThrowsError(try state.recordWabiConversation(url, for: second))
        XCTAssertThrowsError(try state.recordWabiConversation(URL(string: "wabi://app/threads/bbbbbbbbbbbbbbbbbbbbbbbb")!, for: first))
        for invalid in ["https://app/threads/aaaaaaaaaaaaaaaaaaaaaaaa", "wabi://app/threads/aaaaaaaaaaaaaaaaaaaaaaaa?x=1", "wabi://app/threads/new", "wabi://other/threads/aaaaaaaaaaaaaaaaaaaaaaaa", "wabi://app/threads/aaaaaaaaaaaaaaaaaaaaaaaa/"] {
            XCTAssertThrowsError(try state.recordWabiConversation(URL(string: invalid)!, for: second))
        }
        let reopened = try JSONDecoder().decode(WebWorkspaceState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(try reopened.wabiConversation(for: first), url)
        XCTAssertNil(try reopened.wabiConversation(for: second))
    }

    func testWabiReceiptAcceptsRenderedWhitespaceButRejectsChangedWordsAndSender() throws {
        let old: [WabiAppMessage] = [.init(role: .assistant, text: "What can I do for you?")]
        let receipt = WabiAppReceipt(baseline: old, prompt: "Integration check.\nReply only WABI-OK\nDo not use tools.")
        let rendered = WabiAppMessage(role: .user, text: "Integration check. Reply only WABI-OK Do not use tools.")
        let answer = WabiAppMessage(role: .assistant, text: "WABI-OK")
        XCTAssertNil(try receipt.reply(in: old + [rendered]))
        XCTAssertEqual(try receipt.reply(in: old + [rendered, answer]), "WABI-OK")
        XCTAssertEqual(try receipt.reply(in: (old + [rendered, answer]).reversed()), "WABI-OK")
        for changed in [
            WabiAppMessage(role: .user, text: "Integration check. Reply only WABI-OTHER Do not use tools."),
            WabiAppMessage(role: .assistant, text: rendered.text),
            WabiAppMessage(role: .user, text: "Integration check. Reply only WABI-OK Do use tools.")
        ] { XCTAssertThrowsError(try receipt.reply(in: old + [changed, answer])) }
        XCTAssertThrowsError(try receipt.reply(in: [.init(role: .assistant, text: "Changed history"), rendered, answer]))
    }

    func testWabiMatchesReplyWhenOneInteriorOldMessageIsVirtualized() throws {
        let old: [WabiAppMessage] = [.init(role: .assistant, text: "What can I do for you?"),
            .init(role: .user, text: "Earlier question"), .init(role: .assistant, text: "Earlier reply")]
        let outgoing = WabiAppMessage(role: .user, text: "Next question")
        let answer = WabiAppMessage(role: .assistant, text: "New answer")
        let live = WabiAppReceipt(baseline: old, prompt: outgoing.text)
        let saved = try WabiReplyReceipt(comparisonID: UUID(), url: URL(string: "wabi://app/threads/aaaaaaaaaaaaaaaaaaaaaaaa")!, prompt: outgoing.text, baseline: old)
        let observed = [old[0], old[2], outgoing, answer]
        XCTAssertEqual(try live.reply(in: observed), "New answer")
        XCTAssertEqual(try saved.reply(in: observed), "New answer")
        for unsafe in [[old[0], old[1], outgoing, answer],
                       [old[0], old[2], .init(role: .user, text: "Another question"), answer]] {
            XCTAssertThrowsError(try live.reply(in: unsafe))
            XCTAssertThrowsError(try saved.reply(in: unsafe))
        }
        let repeated = [old[0], old[1], old[1], old[2]]
        let ambiguous = [old[0], old[1], old[2], outgoing, answer]
        XCTAssertThrowsError(try WabiAppReceipt(baseline: repeated, prompt: outgoing.text).reply(in: ambiguous))
        let repeatedReceipt = try WabiReplyReceipt(comparisonID: UUID(), url: URL(string: "wabi://app/threads/aaaaaaaaaaaaaaaaaaaaaaaa")!, prompt: outgoing.text, baseline: repeated)
        XCTAssertThrowsError(try repeatedReceipt.reply(in: ambiguous), "Do not guess which repeated row disappeared")
    }

    func testWabiVirtualizedReplyMatchesWhitespaceChangesAndOldReceipts() throws {
        let old: [WabiAppMessage] = [.init(role: .assistant, text: "What can I do for you?"),
            .init(role: .user, text: "Earlier question"), .init(role: .assistant, text: "A \n\n garden.\n\nA \n\n pond.")]
        let visible = [old[0], WabiAppMessage(role: .assistant, text: "A\n\ngarden.\n\nA\n\npond."),
                       .init(role: .user, text: "Next question"), .init(role: .assistant, text: "New answer")]
        let live = WabiAppReceipt(baseline: old, prompt: "Next question")
        let saved = try WabiReplyReceipt(comparisonID: UUID(), url: URL(string: "wabi://app/threads/aaaaaaaaaaaaaaaaaaaaaaaa")!, prompt: "Next question", baseline: old)
        XCTAssertEqual(try live.reply(in: visible), "New answer")
        XCTAssertEqual(try saved.reply(in: visible), "New answer")
        var legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        for key in ["canonicalBaselineDigest", "canonicalReversedBaselineDigest", "canonicalOverlapDigests", "canonicalMessageDigests"] { legacyJSON.removeValue(forKey: key) }
        let legacy = try JSONDecoder().decode(WabiReplyReceipt.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        XCTAssertEqual(try legacy.reply(in: visible, knownHistory: Array(old.dropFirst())), "New answer")
        var altered = visible
        altered[1] = .init(role: .assistant, text: "A garden. A lake.")
        XCTAssertThrowsError(try saved.reply(in: altered))
        XCTAssertThrowsError(try legacy.reply(in: altered, knownHistory: Array(old.dropFirst())))
    }

    func testWabiReceiptRejectsChangedHistoryAndForeignOutgoingMessages() throws {
        let old: [WabiAppMessage] = [.init(role: .user, text: "Earlier question"), .init(role: .assistant, text: "Earlier answer")]
        let prompt = WabiAppMessage(role: .user, text: "New question")
        let answer = WabiAppMessage(role: .assistant, text: "New answer")
        let foreign = WabiAppMessage(role: .user, text: "Another outgoing question")
        let receipt = WabiAppReceipt(baseline: old, prompt: prompt.text)
        XCTAssertNil(try receipt.reply(in: old.reversed()))
        XCTAssertNil(try receipt.reply(in: [prompt] + old.reversed()))
        XCTAssertEqual(try receipt.reply(in: [answer, prompt] + old.reversed()), "New answer")
        XCTAssertThrowsError(try receipt.reply(in: [old[1], prompt, answer]))
        XCTAssertThrowsError(try receipt.reply(in: old + [foreign, answer]))
        XCTAssertThrowsError(try receipt.reply(in: old + [prompt, foreign]))
        XCTAssertThrowsError(try receipt.reply(in: old + [prompt, foreign, answer]))
    }

    func testSavedWabiReceiptMatchesOnlyItsOriginalConversationHistory() throws {
        let url = URL(string: "wabi://app/threads/aaaaaaaaaaaaaaaaaaaaaaaa")!
        let previous: [WabiAppMessage] = [.init(role: .user, text: "Private earlier question"), .init(role: .assistant, text: "Private earlier answer")]
        let receipt = try WabiReplyReceipt(comparisonID: UUID(), url: url, prompt: "Next question\nplease", baseline: previous)
        let outgoing = WabiAppMessage(role: .user, text: "Next question please")
        let response = WabiAppMessage(role: .assistant, text: "A later answer")
        let persisted = try JSONEncoder().encode(receipt)
        XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains("Private earlier"))
        let restored = try JSONDecoder().decode(WabiReplyReceipt.self, from: persisted)
        XCTAssertNil(try restored.reply(in: previous + [outgoing]))
        XCTAssertEqual(try restored.reply(in: previous + [outgoing, response]), "A later answer")
        XCTAssertEqual(try restored.reply(in: Array((previous + [outgoing, response]).reversed())), "A later answer")
        XCTAssertThrowsError(try restored.reply(in: [.init(role: .assistant, text: "Other history"), previous[1], outgoing, response]))
        XCTAssertThrowsError(try restored.reply(in: previous + [.init(role: .user, text: "Someone else's question"), response]))
        XCTAssertThrowsError(try restored.reply(in: previous + [outgoing, .init(role: .user, text: "Another question")]))
        XCTAssertThrowsError(try restored.reply(in: previous + [outgoing, response, response]))
    }

    func testWabiReceiptAcceptsOnlyTheDisappearingInitialGreeting() throws {
        let url = URL(string: "wabi://app/threads/aaaaaaaaaaaaaaaaaaaaaaaa")!
        let greeting = WabiAppMessage(role: .assistant, text: "What can I do for you?")
        let earlier: [WabiAppMessage] = [.init(role: .user, text: "Earlier question"), .init(role: .assistant, text: "Earlier reply")]
        let outgoing = WabiAppMessage(role: .user, text: "New question")
        let answer = WabiAppMessage(role: .assistant, text: "New reply")
        let baseline = [greeting] + earlier
        let live = WabiAppReceipt(baseline: baseline, prompt: outgoing.text)
        let saved = try WabiReplyReceipt(comparisonID: UUID(), url: url, prompt: outgoing.text, baseline: baseline)
        XCTAssertTrue(live.unchanged(earlier), "A disappearing greeting alone does not prove that Send occurred")
        XCTAssertNil(try live.reply(in: earlier))
        XCTAssertNil(try saved.reply(in: earlier))
        for messages in [earlier + [outgoing, answer], Array((earlier + [outgoing, answer]).reversed())] {
            XCTAssertEqual(try live.reply(in: messages), answer.text)
            XCTAssertEqual(try saved.reply(in: messages), answer.text)
        }
        XCTAssertNil(try live.reply(in: earlier + [outgoing]))
        XCTAssertNil(try saved.reply(in: earlier + [outgoing]))
        let edited = [WabiAppMessage(role: .user, text: "Edited earlier question"), earlier[1], outgoing, answer]
        XCTAssertThrowsError(try live.reply(in: edited))
        XCTAssertThrowsError(try saved.reply(in: edited))
        let differentGreeting = [WabiAppMessage(role: .assistant, text: "A different greeting")] + earlier
        XCTAssertThrowsError(try WabiAppReceipt(baseline: differentGreeting, prompt: outgoing.text).reply(in: earlier + [outgoing, answer]))
        XCTAssertThrowsError(try WabiReplyReceipt(comparisonID: UUID(), url: url, prompt: outgoing.text, baseline: differentGreeting).reply(in: earlier + [outgoing, answer]))
        XCTAssertThrowsError(try saved.reply(in: earlier + [.init(role: .user, text: "Someone else's question"), answer]))
    }

    func testWabiReceiptRecoversWhenAnOlderMiddleMessageDisappears() throws {
        let baseline = (0..<13).map { WabiAppMessage(role: $0.isMultiple(of: 2) ? .assistant : .user, text: "Message \($0)") }
        let prompt = WabiAppMessage(role: .user, text: "Question")
        let answer = WabiAppMessage(role: .assistant, text: "Answer")
        let current = Array(baseline.prefix(2)) + Array(baseline.dropFirst(3)) + [prompt, answer]
        let live = WabiAppReceipt(baseline: baseline, prompt: prompt.text)
        let saved = try WabiReplyReceipt(comparisonID: UUID(), url: URL(string: "wabi://app/threads/aaaaaaaaaaaaaaaaaaaaaaaa")!, prompt: prompt.text, baseline: baseline)
        let beforeOutgoing = Array(current.dropLast(2))
        XCTAssertTrue(live.unchanged(beforeOutgoing))
        XCTAssertNil(try live.reply(in: beforeOutgoing))
        XCTAssertNil(try saved.reply(in: beforeOutgoing))
        XCTAssertEqual(try live.reply(in: current), answer.text)
        XCTAssertEqual(try saved.reply(in: current), answer.text)
        let localHistory = [WabiAppMessage(role: .user, text: "Older local message")] + baseline
        var legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        legacyJSON.removeValue(forKey: "messageDigests")
        for key in ["canonicalBaselineDigest", "canonicalReversedBaselineDigest", "canonicalOverlapDigests", "canonicalMessageDigests"] { legacyJSON.removeValue(forKey: key) }
        let legacy = try JSONDecoder().decode(WabiReplyReceipt.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        XCTAssertEqual(try legacy.reply(in: current, knownHistory: localHistory), answer.text)
        var changed = current; changed[0] = .init(role: .user, text: "Changed")
        XCTAssertThrowsError(try live.reply(in: changed))
        XCTAssertThrowsError(try saved.reply(in: changed))
        let recentMissing = Array(baseline.dropLast()) + [prompt, answer]
        XCTAssertThrowsError(try live.reply(in: recentMissing))
        XCTAssertThrowsError(try saved.reply(in: recentMissing))
        let penultimateMissing = Array(baseline.dropLast(2)) + [baseline.last!, prompt, answer]
        XCTAssertThrowsError(try live.reply(in: penultimateMissing), "A long history must retain its recent tail")
        XCTAssertThrowsError(try saved.reply(in: penultimateMissing), "A long history must retain its recent tail")
        XCTAssertThrowsError(try saved.reply(in: Array(baseline.dropFirst(8)) + [prompt, answer]))
        XCTAssertThrowsError(try saved.reply(in: Array(current.dropLast(2)) + [.init(role: .user, text: "Other question"), answer]))
    }

    func testWabiReceiptMatchesAnOverlappingHistoryWindow() throws {
        let url = URL(string: "wabi://app/threads/aaaaaaaaaaaaaaaaaaaaaaaa")!
        let baseline = (0..<10).map { WabiAppMessage(role: $0.isMultiple(of: 2) ? .user : .assistant, text: "Earlier message \($0)") }
        let outgoing = WabiAppMessage(role: .user, text: "New question")
        let answer = WabiAppMessage(role: .assistant, text: "New reply")
        let live = WabiAppReceipt(baseline: baseline, prompt: outgoing.text)
        let saved = try WabiReplyReceipt(comparisonID: UUID(), url: url, prompt: outgoing.text, baseline: baseline)
        let window = Array(baseline.dropFirst())
        XCTAssertTrue(live.unchanged(window), "A shifted history window alone is not a submission")
        XCTAssertNil(try live.reply(in: window + [outgoing]))
        XCTAssertNil(try saved.reply(in: window + [outgoing]))
        for messages in [window + [outgoing, answer], Array((window + [outgoing, answer]).reversed())] {
            XCTAssertEqual(try live.reply(in: messages), answer.text)
            XCTAssertEqual(try saved.reply(in: messages), answer.text)
        }
        let changed = [WabiAppMessage(role: .user, text: "Changed history")] + Array(window.dropFirst()) + [outgoing, answer]
        XCTAssertThrowsError(try live.reply(in: changed))
        XCTAssertThrowsError(try saved.reply(in: changed))
        XCTAssertThrowsError(try saved.reply(in: window + [.init(role: .user, text: "Foreign question"), answer]))
        let tooLittleHistory = Array(baseline.suffix(2)) + [outgoing, answer]
        XCTAssertThrowsError(try live.reply(in: tooLittleHistory))
        XCTAssertThrowsError(try saved.reply(in: tooLittleHistory))
        let encoded = try JSONEncoder().encode(saved)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("Earlier message"))
        var legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacyJSON.removeValue(forKey: "overlapDigests")
        legacyJSON.removeValue(forKey: "messageDigests")
        for key in ["canonicalBaselineDigest", "canonicalReversedBaselineDigest", "canonicalOverlapDigests", "canonicalMessageDigests"] { legacyJSON.removeValue(forKey: key) }
        let legacy = try JSONDecoder().decode(WabiReplyReceipt.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        XCTAssertThrowsError(try legacy.reply(in: window + [outgoing, answer]), "An old receipt alone cannot prove a shifted window")
        XCTAssertEqual(try legacy.reply(in: window + [outgoing, answer], knownHistory: baseline), answer.text)
        let wrongHistory = [.init(role: WabiAppMessage.Role.user, text: "Changed")] + Array(baseline.dropFirst())
        XCTAssertThrowsError(try legacy.reply(in: window + [outgoing, answer], knownHistory: wrongHistory))
        var invalidJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        invalidJSON["overlapDigests"] = [["retained": 1, "digest": Data(repeating: 0, count: 32).base64EncodedString()]]
        let invalid = try JSONDecoder().decode(WabiReplyReceipt.self, from: JSONSerialization.data(withJSONObject: invalidJSON))
        XCTAssertThrowsError(try invalid.reply(in: baseline + [outgoing, answer]), "Malformed overlap receipts must not be used")
        let longBaseline = (0..<40).map { WabiAppMessage(role: $0.isMultiple(of: 2) ? .user : .assistant, text: "Earlier \($0)") }
        let longLive = WabiAppReceipt(baseline: longBaseline, prompt: outgoing.text)
        let longSaved = try WabiReplyReceipt(comparisonID: UUID(), url: url, prompt: outgoing.text, baseline: longBaseline)
        XCTAssertEqual(try longLive.reply(in: Array(longBaseline.dropFirst(16)) + [outgoing, answer]), answer.text)
        XCTAssertEqual(try longSaved.reply(in: Array(longBaseline.dropFirst(16)) + [outgoing, answer]), answer.text)
        XCTAssertThrowsError(try longLive.reply(in: Array(longBaseline.dropFirst(17)) + [outgoing, answer]))
        XCTAssertThrowsError(try longSaved.reply(in: Array(longBaseline.dropFirst(17)) + [outgoing, answer]))
    }

    func testSavedMuseReceiptChecksBaselineAndRejectsAnotherRequest() throws {
        let previous: [MuseAppMessage] = [.init(role: .user, text: "Private earlier question"), .init(role: .assistant, text: "Private earlier answer")]
        let receipt = try MuseReplyReceipt(comparisonID: UUID(), requestID: UUID(), initialThreadID: UUID(), prompt: "Next question", baseline: previous)
        let outgoing = MuseAppMessage(role: .user, text: "Next question")
        let first = MuseAppMessage(role: .assistant, text: "First part")
        let second = MuseAppMessage(role: .assistant, text: "Second part")
        let data = try JSONEncoder().encode(receipt)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Private earlier"))
        let restored = try JSONDecoder().decode(MuseReplyReceipt.self, from: data)
        XCTAssertNil(try restored.reply(in: previous + [outgoing]))
        XCTAssertEqual(try restored.reply(in: previous + [outgoing, first, second]), "First part\n\nSecond part")
        XCTAssertThrowsError(try restored.reply(in: [.init(role: .user, text: "Different history"), previous[1], outgoing, first]))
        XCTAssertThrowsError(try restored.reply(in: previous + [.init(role: .user, text: "Someone else's question"), first]))
        XCTAssertThrowsError(try restored.reply(in: previous + [outgoing, first, .init(role: .user, text: "Another request")]))
    }



    func testWabiNativeMessageFramesProveSendersAndKeepLiteralMetadataText() throws {
        func frame(_ sender: String, _ text: String) -> WabiAXNode {
            .init(role: "AXGroup", classes: ["x1n2onr6", "x193iq5w", "x67m8t7", "xc90arz", "xza2g2e", sender], children: [
                .init(role: "AXStaticText", value: text), .init(role: "AXPopUpButton", label: "Add reaction"), .init(role: "AXStaticText", value: "5:13 PM")])
        }
        let root = WabiAXNode(role: "AXWebArea", children: [frame("xpvyfi4", "Read"), frame("xqcrz7y", "5:13 PM")])
        XCTAssertEqual(try WabiNativeMessages.read(root), [.init(role: .user, text: "Read"), .init(role: .assistant, text: "5:13 PM")])
        XCTAssertThrowsError(try WabiNativeMessages.read(frame("unknown", "A message")))
        XCTAssertThrowsError(try WabiNativeMessages.read(.init(role: "AXWebArea", children: [.init(role: "AXPopUpButton", label: "Add reaction")])))
    }

    func testWabiNumberedReplyKeepsItemsReadableWithoutChangingReceiptDigests() throws {
        // Wabi exposes a numbered list as one AXList with marker and individual
        // word nodes; the enclosing message still has one sender and timestamp.
        let list = WabiAXNode(role: "AXList", children: [
            .init(role: "AXListMarker", value: "1."), .init(role: "AXStaticText", value: "A"),
            .init(role: "AXStaticText", value: "garden"), .init(role: "AXStaticText", value: "."),
            .init(role: "AXListMarker", value: "2."), .init(role: "AXStaticText", value: "A"),
            .init(role: "AXStaticText", value: "pond.")
        ])
        func frame(_ sender: String, _ body: [WabiAXNode]) -> WabiAXNode {
            .init(role: "AXGroup", classes: ["x1n2onr6", "x193iq5w", "x67m8t7", "xc90arz", "xza2g2e", sender],
                  children: body + [.init(role: "AXPopUpButton", label: "Add reaction"), .init(role: "AXStaticText", value: "5:13 PM")])
        }
        let root = WabiAXNode(role: "AXWebArea", children: [frame("xpvyfi4", [.init(role: "AXStaticText", value: "Question")]),
            frame("xqcrz7y", [.init(role: "AXStaticText", value: "Here are two:"), list, .init(role: "AXStaticText", value: "Done.")])])
        let messages = try WabiNativeMessages.read(root)
        let raw = "Here are two:\n\nA\n\ngarden\n\n.\n\nA\n\npond.\n\nDone."
        XCTAssertEqual(messages[1].text, raw, "Existing receipt digests use this exact AX text")
        XCTAssertEqual(messages[1].presentation, "Here are two:\n\n1. A garden.\n2. A pond.\n\nDone.")
        let oldMessage = WabiAppMessage(role: .assistant, text: raw)
        XCTAssertEqual(messages[1], oldMessage)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(messages[1]), try encoder.encode(oldMessage))
        let answer = "Here are two:\n\n1. A garden.\n2. A pond.\n\nDone."
        XCTAssertEqual(try WabiAppReceipt(baseline: [], prompt: "Question").reply(in: messages), answer)
        let receipt = try WabiReplyReceipt(comparisonID: UUID(), url: URL(string: "wabi://app/threads/aaaaaaaaaaaaaaaaaaaaaaaa")!, prompt: "Question", baseline: [])
        XCTAssertEqual(try receipt.reply(in: messages), answer)
        let oldReceipt = try WabiReplyReceipt(comparisonID: UUID(), url: URL(string: "wabi://app/threads/aaaaaaaaaaaaaaaaaaaaaaaa")!, prompt: "Next", baseline: [oldMessage])
        let later = [messages[1], WabiAppMessage(role: .user, text: "Next"), WabiAppMessage(role: .assistant, text: "Later reply")]
        XCTAssertEqual(try oldReceipt.reply(in: later), "Later reply", "Receipts saved before presentation formatting must still match")
    }

    func testWabi015ReadinessIgnoresIncompleteHistoryWithoutAttributingIt() throws {
        // Sanitized shape from Wabi 0.1.15: ten sender-marked frames, nine
        // reaction controls. No user's conversation text is part of the fixture.
        func frame(complete: Bool) -> WabiAXNode {
            var children: [WabiAXNode] = [.init(role: "AXGroup", children: [.init(role: "AXStaticText", value: "Example message")])]
            if complete {
                children += [.init(role: "AXGroup", children: [.init(role: "AXPopUpButton", label: "Add reaction")]),
                             .init(role: "AXStaticText", value: "5:13 PM")]
            }
            return .init(role: "AXGroup", classes: ["x1n2onr6", "x193iq5w", "x67m8t7", "xc90arz", "xza2g2e", "xqcrz7y"], children: children)
        }
        let history = WabiAXNode(role: "AXWebArea", children: (0..<10).map { frame(complete: $0 != 7) })
        XCTAssertEqual(try WabiNativeMessages.read(history, purpose: .readiness), [])
        XCTAssertThrowsError(try WabiNativeMessages.read(history)) { error in
            guard case WabiObservationError.transient = error else { return XCTFail("Incomplete history must never be attributed: \(error)") }
        }
        XCTAssertEqual(try WabiNativeMessages.read(.init(role: "AXWebArea", children: [frame(complete: true)])),
                       [.init(role: .assistant, text: "Example message")])
    }

    func testWabiIncompleteIncomingFrameHasNoAttributedBodyUntilLayoutSettles() throws {
        func frame(_ sender: String, _ text: String, timestamp: Bool = true) -> WabiAXNode {
            var children: [WabiAXNode] = [.init(role: "AXStaticText", value: text), .init(role: "AXPopUpButton", label: "Add reaction")]
            if timestamp { children.append(.init(role: "AXStaticText", value: "5:13 PM")) }
            return .init(role: "AXGroup", classes: ["x1n2onr6", "x193iq5w", "x67m8t7", "xc90arz", "xza2g2e", sender], children: children)
        }
        let greeting = frame("xqcrz7y", "What can I do for you?")
        let question = frame("xpvyfi4", "Question")
        for incomplete in [WabiAXNode(role: "AXPopUpButton", label: "Add reaction"), frame("xqcrz7y", "Answer", timestamp: false)] {
            XCTAssertThrowsError(try WabiNativeMessages.read(.init(role: "AXWebArea", children: [greeting, question, incomplete]))) { error in
                guard case WabiObservationError.transient = error else { return XCTFail("Incomplete rendering must be observable as a transient read, got \(error)") }
            }
        }
        let complete = WabiAXNode(role: "AXWebArea", children: [greeting, question, frame("xqcrz7y", "Answer")])
        XCTAssertEqual(try WabiNativeMessages.read(complete), [.init(role: .assistant, text: "What can I do for you?"), .init(role: .user, text: "Question"), .init(role: .assistant, text: "Answer")])
    }

    @MainActor
    func testLegacyWabiTranscriptIsPreservedWithoutAdoptingAnExistingChat() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wabi-legacy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = WebAgentSession(provider: .wabi, storageURL: directory.appendingPathComponent("state.json"), fixture: true)
        defer { session.beginShutdown() }
        session.setEnabled(true)
        await session.connectDesktopConversation()
        let comparison = UUID()
        session.updateState { $0.localConversations[comparison.uuidString] = [WebPageMessage(role: "assistant", text: "Earlier shared chat")] }
        let attempt = await session.send("Continue", comparisonID: comparison)
        XCTAssertEqual(attempt?.status, .notSent)
        XCTAssertNil(session.state.conversationURLs[comparison.uuidString])
        XCTAssertEqual(session.state.localConversations[comparison.uuidString]?.map(\.text), ["Earlier shared chat"])
        XCTAssertTrue(attempt?.detail?.contains("without a tracked dedicated chat") == true)
    }

    @MainActor
    func testNativeDesktopConversationSavesHistoryAndKeepsCLISessionsEmpty() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = WebAgentSession(provider: .wabi, storageURL: directory.appendingPathComponent("wabi.json"), fixture: true)
        session.setEnabled(true)
        await session.connectDesktopConversation()
        let comparison = UUID()
        let attempt = await session.send("Fixture prompt", comparisonID: comparison)
        XCTAssertEqual(attempt?.status, .observed)
        XCTAssertEqual(session.snapshot.messages.map(\.role), ["user", "assistant"])
        XCTAssertEqual(session.snapshot.messages.first?.text, "Fixture prompt")
        XCTAssertTrue(session.state.localSessionIDs.isEmpty, "Desktop bindings are not CLI session IDs")
        let firstThread = try XCTUnwrap(session.state.conversationURLs[comparison.uuidString])
        let followup = await session.send("Follow up", comparisonID: comparison)
        XCTAssertEqual(followup?.status, .observed)
        XCTAssertEqual(session.state.conversationURLs[comparison.uuidString], firstThread)
        let other = UUID()
        let separate = await session.send("Separate comparison", comparisonID: other)
        XCTAssertEqual(separate?.status, .observed)
        XCTAssertNotEqual(session.state.conversationURLs[other.uuidString], firstThread)
        let reopened = WebAgentSession(provider: .wabi, storageURL: directory.appendingPathComponent("wabi.json"), fixture: true)
        XCTAssertEqual(reopened.state.desktopConversation?.name, "Wabi")
        XCTAssertEqual(reopened.state.conversationURLs, session.state.conversationURLs)
        XCTAssertEqual(reopened.state.localConversations[comparison.uuidString]?.last?.text, "Wabi fixture reply: Follow up")
        session.beginShutdown(); reopened.beginShutdown()
    }

    @MainActor
    func testUncertainDesktopSendBlocksAnotherComparison() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = WebAgentSession(provider: .wabi, storageURL: directory.appendingPathComponent("wabi.json"), fixture: true)
        session.setEnabled(true)
        await session.connectDesktopConversation()
        var earlier = WebSendAttempt(text: "Earlier prompt", status: .uncertain)
        earlier.comparisonID = UUID()
        session.updateState { $0.attempts = [earlier] }
        let attempt = await session.send("Different prompt", comparisonID: UUID())
        XCTAssertNil(attempt, "An unresolved request owns the shared app conversation across comparisons")
        XCTAssertEqual(session.state.attempts.count, 1)
        XCTAssertEqual(session.incompleteDesktopAttempt?.id, earlier.id)
        session.acknowledgeIncompleteRequest()
        XCTAssertEqual(session.incompleteDesktopAttempt?.id, earlier.id, "Default recovery stays scoped to this comparison")
        session.acknowledgeIncompleteRequest(attemptID: UUID())
        XCTAssertEqual(session.incompleteDesktopAttempt?.id, earlier.id, "A stale control cannot clear a different attempt")
        session.acknowledgeIncompleteRequest(attemptID: earlier.id)
        XCTAssertNil(session.incompleteDesktopAttempt)
        XCTAssertEqual(session.state.attempts.first?.status, .dismissed)
        XCTAssertTrue(session.state.localConversations.isEmpty, "Acknowledgment never replays the prompt")
        session.beginShutdown()
    }

    @MainActor
    func testInterruptedDesktopRequestRetainsOwnerAndDraftAcrossRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-owner-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("wabi.json")
        let owner = UUID(), other = UUID()
        let original = WebAgentSession(provider: .wabi, storageURL: file, fixture: true)
        original.setEnabled(true)
        await original.connectDesktopConversation()
        original.updateState { $0.comparisonID = owner }
        original.updateState {
            $0.draft = "Uncertain outgoing draft"
            var interrupted = WebSendAttempt(text: "Uncertain outgoing draft", status: .attempting)
            interrupted.comparisonID = owner
            $0.attempts = [interrupted]
            $0.localConversations[owner.uuidString] = [WebPageMessage(role: "assistant", text: "Earlier answer")]
        }
        original.beginShutdown()
        let reopened = WebAgentSession(provider: .wabi, storageURL: file, fixture: true)
        defer { reopened.beginShutdown() }
        XCTAssertEqual(reopened.state.attempts.first?.status, .uncertain)
        XCTAssertEqual(reopened.state.attempts.first?.comparisonID, owner)
        XCTAssertEqual(reopened.state.draft, "Uncertain outgoing draft")
        XCTAssertEqual(reopened.state.desktopConversation?.name, "Wabi")
        reopened.updateState { $0.comparisonID = other }
        reopened.updateState { $0.draft = "Other comparison draft" }
        reopened.acknowledgeIncompleteRequest()
        let blocked = await reopened.send("New prompt", comparisonID: other)
        XCTAssertNil(blocked, "Another comparison cannot acknowledge the original request")
        XCTAssertEqual(reopened.state.attempts.count, 1)
        XCTAssertNil(reopened.state.localConversations[other.uuidString])
        reopened.updateState { $0.comparisonID = owner }
        XCTAssertEqual(reopened.state.draft, "Uncertain outgoing draft")
        reopened.acknowledgeIncompleteRequest()
        XCTAssertEqual(reopened.state.attempts.first?.status, .dismissed)
        reopened.updateState { $0.comparisonID = other }
        XCTAssertEqual(reopened.state.draft, "Other comparison draft")
        reopened.updateState { $0.draft = "New prompt" }
        let allowed = await reopened.send("New prompt", comparisonID: other)
        XCTAssertEqual(allowed?.status, .observed)
        XCTAssertEqual(reopened.state.localConversations[owner.uuidString]?.map(\.text), ["Earlier answer"])
        XCTAssertEqual(reopened.state.localConversations[other.uuidString]?.first?.text, "New prompt")
        XCTAssertTrue(reopened.state.localSessionIDs.isEmpty)
    }

    private func element(_ role: String, _ label: String, value: String? = nil) -> [String: Any] {
        var result: [String: Any] = ["role": role, "label": label, "element_token": "s00000001:\(UUID().uuidString)", "in_web_content": true]
        if role == "AXHeading" { result["value"] = "2" }
        if let value { result["value"] = value }
        return result
    }
    private func decode(_ elements: [[String: Any]]) throws -> DesktopAppSnapshot {
        try JSONDecoder().decode(DesktopAppSnapshot.self, from: JSONSerialization.data(withJSONObject: ["elements": [element("AXSplitter", "Resize sidebar")] + elements, "elements_complete": true]))
    }
}

/// Runs the real adapter/process boundary. The executable below only consumes a
/// local JSON plan; it cannot discover or contact the installed Cua service.
@MainActor
final class DesktopAppDriverTests: XCTestCase {
    func testGrokLateReplyIsRecoveredWithoutSendingAndSurvivesReload() async throws {
        let comparison = UUID()
        let anchor = DesktopAppSnapshot.GrokHistoryAnchor(history: ["You", "Earlier unrelated question", "Fixture Bot", "Earlier unrelated answer"], bot: "Fixture Bot")
        let receipt = GrokReplyReceipt(comparisonID: comparison, bot: "Fixture Bot", prompt: prompt, anchor: anchor)
        let fixture = try driver([apps(), windows(), snapshot(grok(reply: "Late answer"), repeating: true)])
        defer { fixture.remove() }
        let client = DesktopAppInstallationClient(inspect: { _ in .init(url: URL(fileURLWithPath: "/Fixture/Grok Bot.app"), processID: 4242) },
                                                   open: { _ in XCTFail("Recovery must not open Grok Bot") })
        var workspace = WebWorkspaceState()
        workspace.enabled = true; workspace.comparisonID = comparison; workspace.draft = "Keep my next draft"
        workspace.desktopConversation = .init(name: "Fixture Bot")
        var attempt = WebSendAttempt(text: prompt, status: .uncertain)
        attempt.comparisonID = comparison; attempt.messageID = attempt.id.uuidString; attempt.grokReplyReceipt = receipt
        workspace.attempts = [attempt]
        workspace.localConversations[comparison.uuidString] = [.init(id: attempt.id.uuidString, role: "user", text: prompt)]
        let storage = fixture.directory.appendingPathComponent("workspace.json")
        try JSONEncoder().encode(workspace).write(to: storage)
        let session = WebAgentSession(provider: .grokBotApp, storageURL: storage, fixture: false, museApp: .shared, desktopApps: client, desktopDriver: adapter(fixture))
        session.connect(automaticallyRefresh: false)
        XCTAssertTrue(session.isAutomaticallyWaitingForNativeReply)
        let remaining = await session.reconcileGrokReplyOnce()
        XCTAssertFalse(session.isAutomaticallyWaitingForNativeReply)
        session.beginShutdown()
        XCTAssertFalse(remaining)
        let savedData = try Data(contentsOf: storage)
        let saved = try JSONDecoder().decode(WebWorkspaceState.self, from: savedData)
        XCTAssertEqual(saved.attempts.first?.status, .observed)
        XCTAssertEqual(saved.localConversations[comparison.uuidString]?.map(\.text), [prompt, "Late answer"])
        XCTAssertEqual(saved.draft, "Keep my next draft")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self).contains("Earlier unrelated"))
        let calls = try await finishedCalls(fixture)
        XCTAssertFalse(calls.contains { ["type_text", "press_key", "click", "launch_app", "bring_to_front"].contains($0.tool) })
    }

    func testGrokRecoveryRejectsUnconfirmedCancelledAndAmbiguousRequests() async throws {
        let fixture = try driver([])
        defer { fixture.remove() }
        let comparison = UUID()
        let anchor = DesktopAppSnapshot.GrokHistoryAnchor(history: ["You", "Earlier question", "Fixture Bot", "Earlier answer"], bot: "Fixture Bot")
        let receipt = GrokReplyReceipt(comparisonID: comparison, bot: "Fixture Bot", prompt: prompt, anchor: anchor)
        let client = DesktopAppInstallationClient(inspect: { _ in .init(url: URL(fileURLWithPath: "/Fixture/Grok Bot.app"), processID: 4242) }, open: { _ in XCTFail("Recovery must not open Grok Bot") })
        for scenario in ["unconfirmed", "cancelled", "wrong bot", "multiple requests", "missing outgoing", "interleaved", "wrong comparison", "unsupported version"] {
            var workspace = WebWorkspaceState()
            workspace.enabled = true; workspace.comparisonID = comparison
            workspace.desktopConversation = .init(name: scenario == "wrong bot" ? "Other Bot" : "Fixture Bot")
            var attempt = WebSendAttempt(text: prompt, status: .uncertain)
            attempt.comparisonID = comparison; attempt.messageID = attempt.id.uuidString; attempt.grokReplyReceipt = receipt
            if scenario == "unconfirmed" { attempt.messageID = nil }
            if scenario == "cancelled" { attempt.grokReplyReceipt?.automaticRecovery = false }
            if scenario == "wrong comparison" { attempt.grokReplyReceipt = .init(comparisonID: UUID(), bot: "Fixture Bot", prompt: prompt, anchor: anchor) }
            if scenario == "unsupported version" { attempt.grokReplyReceipt?.version = 2 }
            workspace.attempts = [attempt]
            workspace.localConversations[comparison.uuidString] = [.init(id: attempt.id.uuidString, role: "user", text: attempt.text)]
            if scenario == "missing outgoing" { workspace.localConversations[comparison.uuidString] = [] }
            if scenario == "interleaved" { workspace.localConversations[comparison.uuidString]?.append(.init(role: "user", text: "Another request")) }
            if scenario == "multiple requests" {
                var second = WebSendAttempt(text: "Another request", status: .uncertain)
                second.comparisonID = comparison; workspace.attempts.append(second)
            }
            let storage = fixture.directory.appendingPathComponent("grok-\(scenario).json")
            try JSONEncoder().encode(workspace).write(to: storage)
            let session = WebAgentSession(provider: .grokBotApp, storageURL: storage, fixture: false, museApp: .shared, desktopApps: client)
            session.connect(automaticallyRefresh: false)
            XCTAssertFalse(session.isAutomaticallyWaitingForNativeReply, scenario)
            let remaining = await session.reconcileGrokReplyOnce()
            XCTAssertFalse(remaining, scenario)
            XCTAssertEqual(session.state.attempts.first?.status, .uncertain, scenario)
            session.beginShutdown()
        }
        XCTAssertTrue(try fixture.calls().isEmpty, "Unsafe recovery must not inspect or interact with any app")
    }

    func testGrokRecoveryNeverAttributesAnotherBotOrUnrelatedMessage() async throws {
        let anchor = DesktopAppSnapshot.GrokHistoryAnchor(history: ["You", "Earlier unrelated question", "Fixture Bot", "Earlier unrelated answer"], bot: "Fixture Bot")
        let receipt = GrokReplyReceipt(comparisonID: UUID(), bot: "Fixture Bot", prompt: prompt, anchor: anchor)
        for state in [grok(reply: "Wrong bot answer", name: "Other Bot"),
                      grok(reply: "Ambiguous bot answer", bots: ["Fixture Bot", "Fixture Bot"]),
                      grok(reply: "Other request answer", outgoingPrompt: "Different request")] {
            let fixture = try driver([apps(), windows(), snapshot(state, repeating: true)])
            defer { fixture.remove() }
            do {
                let answer = try await adapter(fixture).recoverGrokReply(receipt)
                XCTAssertNil(answer, "A foreign reply must never be attributed")
            } catch { /* Refusing the changed conversation is also correct. */ }
            let calls = try await finishedCalls(fixture)
            assertNoInput(calls)
        }
    }

    func testGrokRecoveryRevealsLatestReplyWithoutResendingOrChangingBots() async throws {
        let anchor = DesktopAppSnapshot.GrokHistoryAnchor(history: ["You", "Earlier unrelated question", "Fixture Bot", "Earlier unrelated answer"], bot: "Fixture Bot")
        let receipt = GrokReplyReceipt(comparisonID: UUID(), bot: "Fixture Bot", prompt: prompt, anchor: anchor)
        var stale = grok(reply: "", token: "s00000004")
        var elements = try XCTUnwrap(stale["elements"] as? [[String: Any]])
        let composer = try XCTUnwrap(elements.firstIndex { $0["role"] as? String == "AXTextArea" })
        elements.insert(element("AXButton", "1 new message", token: "s00000004:latest"), at: composer)
        stale["elements"] = elements; stale["returned_element_count"] = elements.count; stale["total_element_count"] = elements.count
        let reveal = step("click", [:], arguments: ["element_token": "s00000004:latest"])
        let fixture = try driver([apps(), windows(), snapshot(stale), reveal, snapshot(grok(reply: "Late answer"), repeating: true)])
        defer { fixture.remove() }
        let answer = try await adapter(fixture).recoverGrokReply(receipt)
        XCTAssertEqual(answer, "Late answer")
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1)
        XCTAssertFalse(calls.contains { ["type_text", "press_key", "launch_app", "bring_to_front"].contains($0.tool) })
        XCTAssertEqual(calls.first { $0.tool == "click" }?.arguments["element_token"] as? String, "s00000004:latest")
    }

    func testGrokRecoveryDoesNotRevealMessagesForAnotherBotOrRequest() async throws {
        let anchor = DesktopAppSnapshot.GrokHistoryAnchor(history: ["You", "Earlier unrelated question", "Fixture Bot", "Earlier unrelated answer"], bot: "Fixture Bot")
        let receipt = GrokReplyReceipt(comparisonID: UUID(), bot: "Fixture Bot", prompt: prompt, anchor: anchor)
        for state in [grok(reply: "", name: "Other Bot"), grok(reply: "", outgoingPrompt: "Other request")] {
            var stale = state
            var elements = try XCTUnwrap(stale["elements"] as? [[String: Any]])
            let composer = try XCTUnwrap(elements.firstIndex { $0["role"] as? String == "AXTextArea" })
            elements.insert(element("AXButton", "1 new message", token: "s00000001:latest"), at: composer)
            stale["elements"] = elements; stale["returned_element_count"] = elements.count; stale["total_element_count"] = elements.count
            let fixture = try driver([apps(), windows(), snapshot(stale, repeating: true)])
            defer { fixture.remove() }
            do {
                let result = try await adapter(fixture).recoverGrokReply(receipt)
                XCTAssertNil(result)
            } catch { }
            assertNoInput(try await finishedCalls(fixture))
        }
    }

    func testStoppingGrokRecoveryKeepsTheSentMessageAndPreventsLaterAttribution() async throws {
        let fixture = try driver([])
        defer { fixture.remove() }
        let comparison = UUID()
        let anchor = DesktopAppSnapshot.GrokHistoryAnchor(history: ["You", "Earlier", "Fixture Bot", "Earlier answer"], bot: "Fixture Bot")
        var workspace = WebWorkspaceState()
        workspace.enabled = true; workspace.comparisonID = comparison; workspace.draft = "Keep this draft"
        workspace.desktopConversation = .init(name: "Fixture Bot")
        var attempt = WebSendAttempt(text: prompt, status: .uncertain)
        attempt.comparisonID = comparison; attempt.messageID = attempt.id.uuidString
        attempt.grokReplyReceipt = .init(comparisonID: comparison, bot: "Fixture Bot", prompt: prompt, anchor: anchor)
        workspace.attempts = [attempt]
        workspace.localConversations[comparison.uuidString] = [.init(id: attempt.id.uuidString, role: "user", text: prompt)]
        let storage = fixture.directory.appendingPathComponent("stop-waiting.json")
        try JSONEncoder().encode(workspace).write(to: storage)
        let client = DesktopAppInstallationClient(inspect: { _ in .init(url: URL(fileURLWithPath: "/Fixture/Grok Bot.app"), processID: 4242) }, open: { _ in XCTFail("Recovery must not open Grok Bot") })
        let session = WebAgentSession(provider: .grokBotApp, storageURL: storage, fixture: false, museApp: .shared, desktopApps: client, desktopDriver: adapter(fixture))
        session.connect(automaticallyRefresh: false)
        XCTAssertTrue(session.isAutomaticallyWaitingForNativeReply)
        session.acknowledgeIncompleteRequest()
        XCTAssertFalse(session.isAutomaticallyWaitingForNativeReply)
        let remaining = await session.reconcileGrokReplyOnce()
        session.beginShutdown()
        XCTAssertFalse(remaining)
        let saved = try JSONDecoder().decode(WebWorkspaceState.self, from: Data(contentsOf: storage))
        XCTAssertEqual(saved.attempts.first?.status, .dismissed)
        XCTAssertEqual(saved.localConversations[comparison.uuidString]?.map(\.text), [prompt])
        XCTAssertEqual(saved.draft, "Keep this draft")
        XCTAssertTrue(try fixture.calls().isEmpty)
    }

    func testGrokRecoveryReceiptComesFromActualTimedOutSubmission() async throws {
        actor Receipts {
            var anchor: DesktopAppSnapshot.GrokHistoryAnchor?
            var submissions = 0
            func save(_ value: DesktopAppSnapshot.GrokHistoryAnchor) { anchor = value }
            func submitted() { submissions += 1 }
        }
        let receipts = Receipts(), comparison = UUID()
        let fixture = try driver(sendSteps() + [snapshot(grok(reply: ""), repeating: true)])
        defer { fixture.remove() }
        let conversation = adapter(fixture, replyTimeout: .milliseconds(180))
        do {
            _ = try await conversation.reply(prompt, app: .grokBot, binding: binding,
                                             onReceipt: { await receipts.save($0) },
                                             onSubmitted: { await receipts.submitted() })
            XCTFail("The first request should time out before the reply arrives")
        } catch { XCTAssertTrue(error.localizedDescription.contains("nothing will be resent automatically"), error.localizedDescription) }
        let capturedAnchor = await receipts.anchor
        let anchor = try XCTUnwrap(capturedAnchor)
        let count = await receipts.submissions
        XCTAssertEqual(count, 1)
        let receipt = GrokReplyReceipt(comparisonID: comparison, bot: binding.name, prompt: prompt, anchor: anchor)
        let persisted = try JSONDecoder().decode(GrokReplyReceipt.self, from: JSONEncoder().encode(receipt))
        try fixture.replacePlan([apps(), windows(), snapshot(grok(reply: "Late answer"), repeating: true)])
        let answer = try await conversation.recoverGrokReply(persisted)
        XCTAssertEqual(answer, "Late answer")
        let calls = try await finishedCalls(fixture, cleanupCount: 2)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1)
    }

    func testGrokWorkingPastDeadlineDoesNotHoldTheBroadcastOpen() async throws {
        actor Submission { var count = 0; func record() { count += 1 } }
        let submission = Submission()
        var working = grok(reply: "")
        var elements = try XCTUnwrap(working["elements"] as? [[String: Any]])
        elements.append(element("AXStaticText", "Fixture Bot is working"))
        working["elements"] = elements
        working["returned_element_count"] = elements.count; working["total_element_count"] = elements.count
        let fixture = try driver(sendSteps() + [snapshot(working), snapshot(working), snapshot(working), snapshot(grok(reply: "Eventually finished"), repeating: true)])
        defer { fixture.remove() }
        let error = await failure {
            try await self.adapter(fixture, replyTimeout: .milliseconds(15), replyClock: .init(AdvancingClock()))
                .reply(self.prompt, app: .grokBot, binding: self.binding, onSubmitted: { await submission.record() })
        }
        XCTAssertTrue(error.contains("has not completed a verified reply"), error)
        let submissions = await submission.count
        XCTAssertEqual(submissions, 1, "The test must reach a confirmed outgoing message")
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1, "Never resend while the bot is still working")
        XCTAssertEqual(calls.filter { $0.tool == "get_window_state" }.count, 5, "Three deadline ticks should end the foreground wait")
    }

    func testWabiLateReplyIsRecoveredWithoutSendingAndSurvivesReload() async throws {
        let comparison = UUID(), url = wabiURL
        let baseline: [WabiAppMessage] = [.init(role: .assistant, text: "Welcome")]
        let receipt = try WabiReplyReceipt(comparisonID: comparison, url: url, prompt: "Question", baseline: baseline)
        let fixture = try driver([apps(.wabi), windows(), snapshot(wabi(), repeating: true)])
        defer { fixture.remove() }
        let adapter = WabiAppConversation(executable: fixture.executable, timing: .init(stableDuration: .milliseconds(1))) { _, _ in
            .init(url: url, draft: "An unrelated native draft", links: [], messages: baseline + [
                .init(role: .user, text: "Question"), .init(role: .assistant, text: "Late answer")])
        }
        let client = DesktopAppInstallationClient(inspect: { _ in .init(url: URL(fileURLWithPath: "/Fixture/Wabi.app"), processID: 4242) },
                                                   open: { _ in XCTFail("Recovery must not open Wabi") })
        var workspace = WebWorkspaceState()
        workspace.enabled = true; workspace.comparisonID = comparison; workspace.draft = "Keep my next draft"
        try workspace.recordWabiConversation(url, for: comparison)
        var attempt = WebSendAttempt(text: "Question", status: .uncertain)
        attempt.comparisonID = comparison; attempt.messageID = attempt.id.uuidString; attempt.wabiReplyReceipt = receipt
        workspace.attempts = [attempt]
        workspace.localConversations[comparison.uuidString] = [.init(id: attempt.id.uuidString, role: "user", text: attempt.text)]
        let storage = fixture.directory.appendingPathComponent("workspace.json")
        try JSONEncoder().encode(workspace).write(to: storage)
        let session = WebAgentSession(provider: .wabi, storageURL: storage, fixture: false, museApp: .shared, desktopApps: client, wabiApp: adapter)
        session.connect(automaticallyRefresh: false)
        let remaining = await session.reconcileWabiReplyOnce()
        session.beginShutdown()
        XCTAssertFalse(remaining)
        let saved = try JSONDecoder().decode(WebWorkspaceState.self, from: Data(contentsOf: storage))
        XCTAssertEqual(saved.attempts.first?.status, .observed)
        XCTAssertEqual(saved.localConversations[comparison.uuidString]?.map(\.text), ["Question", "Late answer"])
        XCTAssertEqual(saved.draft, "Keep my next draft")
        let calls = try await finishedCalls(fixture)
        XCTAssertFalse(calls.contains { ["type_text", "press_key", "click", "launch_app"].contains($0.tool) })
    }

    func testRecoveredNativeReplyClearsOnlyItsUnchangedSubmittedDraft() async throws {
        let comparison = UUID(), url = wabiURL
        let baseline: [WabiAppMessage] = [.init(role: .assistant, text: "Welcome")]
        let receipt = try WabiReplyReceipt(comparisonID: comparison, url: url, prompt: "Question", baseline: baseline)
        let client = DesktopAppInstallationClient(inspect: { _ in .init(url: URL(fileURLWithPath: "/Fixture/Wabi.app"), processID: 4242) }, open: { _ in XCTFail("Recovery must not launch Wabi") })
        for scenario in ["unchanged", "edited", "retyped", "legacy", "other comparison"] {
            let fixture = try driver([apps(.wabi), windows(), snapshot(wabi(), repeating: true)])
            defer { fixture.remove() }
            let adapter = WabiAppConversation(executable: fixture.executable, timing: .init(stableDuration: .zero)) { _, _ in
                .init(url: url, draft: "", links: [], messages: baseline + [.init(role: .user, text: "Question"), .init(role: .assistant, text: "Late answer")])
            }
            let revision = UUID(), other = UUID()
            var workspace = WebWorkspaceState()
            workspace.enabled = true; workspace.comparisonID = scenario == "other comparison" ? other : comparison
            workspace.draft = scenario == "other comparison" ? "Other conversation draft" : "Question"
            workspace.localDrafts[comparison.uuidString] = "Question"
            workspace.localDraftRevisions[comparison.uuidString] = revision
            if scenario == "other comparison" { workspace.localDrafts[other.uuidString] = workspace.draft }
            try workspace.recordWabiConversation(url, for: comparison)
            var attempt = WebSendAttempt(text: "Question", status: .uncertain)
            attempt.comparisonID = comparison; attempt.messageID = attempt.id.uuidString; attempt.wabiReplyReceipt = receipt
            attempt.nativeDraftRevision = scenario == "legacy" ? nil : revision
            workspace.attempts = [attempt]
            workspace.localConversations[comparison.uuidString] = [.init(id: attempt.id.uuidString, role: "user", text: attempt.text)]
            let storage = fixture.directory.appendingPathComponent("workspace.json")
            try JSONEncoder().encode(workspace).write(to: storage)
            let session = WebAgentSession(provider: .wabi, storageURL: storage, fixture: false, museApp: .shared, desktopApps: client, wabiApp: adapter)
            session.connect(automaticallyRefresh: false)
            if scenario == "edited" || scenario == "retyped" { session.updateState { $0.draft = "Next draft" } }
            if scenario == "retyped" { session.updateState { $0.draft = "Question" } }
            _ = await session.reconcileWabiReplyOnce()
            session.beginShutdown()
            let saved = try JSONDecoder().decode(WebWorkspaceState.self, from: Data(contentsOf: storage))
            XCTAssertEqual(saved.attempts.first?.status, .observed, scenario)
            XCTAssertEqual(saved.localConversations[comparison.uuidString]?.map(\.text), ["Question", "Late answer"], scenario)
            let expected = scenario == "unchanged" ? "" : scenario == "edited" ? "Next draft" : scenario == "other comparison" ? "Other conversation draft" : "Question"
            XCTAssertEqual(saved.draft, expected, scenario)
            XCTAssertEqual(saved.localDrafts[comparison.uuidString], scenario == "other comparison" ? "" : expected, scenario)
            let calls = try await finishedCalls(fixture)
            XCTAssertFalse(calls.contains { ["type_text", "press_key", "click", "launch_app"].contains($0.tool) }, scenario)
        }
    }

    func testWabiUnconfirmedSendRecoversOnlyAfterTheExactOutgoingAndReplyAppear() async throws {
        let comparison = UUID(), url = wabiURL
        let earlier: [WabiAppMessage] = [.init(role: .user, text: "Earlier question"), .init(role: .assistant, text: "Earlier reply")]
        let baseline = [WabiAppMessage(role: .assistant, text: "What can I do for you?")] + earlier
        let receipt = try WabiReplyReceipt(comparisonID: comparison, url: url, prompt: "Question", baseline: baseline)
        let client = DesktopAppInstallationClient(inspect: { _ in .init(url: URL(fileURLWithPath: "/Fixture/Wabi.app"), processID: 4242) }, open: { _ in XCTFail("Recovery must not launch Wabi") })
        for exact in [true, false] {
            let fixture = try driver([apps(.wabi), windows(), snapshot(wabi(), repeating: true)])
            defer { fixture.remove() }
            let adapter = WabiAppConversation(executable: fixture.executable, timing: .init(stableDuration: .zero)) { _, _ in
                .init(url: url, draft: "", links: [], messages: earlier + [
                    .init(role: .user, text: exact ? "Question" : "Another question"), .init(role: .assistant, text: "Answer")])
            }
            var workspace = WebWorkspaceState()
            workspace.enabled = true; workspace.comparisonID = comparison
            try workspace.recordWabiConversation(url, for: comparison)
            var attempt = WebSendAttempt(text: "Question", status: .uncertain)
            attempt.comparisonID = comparison; attempt.messageID = nil; attempt.wabiReplyReceipt = receipt
            workspace.attempts = [attempt]
            workspace.localConversations[comparison.uuidString] = [.init(role: "user", text: "Earlier question"), .init(role: "assistant", text: "Earlier reply")]
            let storage = fixture.directory.appendingPathComponent("workspace.json")
            try JSONEncoder().encode(workspace).write(to: storage)
            let session = WebAgentSession(provider: .wabi, storageURL: storage, fixture: false, museApp: .shared, desktopApps: client, wabiApp: adapter)
            session.connect(automaticallyRefresh: false)
            _ = await session.reconcileWabiReplyOnce()
            session.beginShutdown()
            let saved = try JSONDecoder().decode(WebWorkspaceState.self, from: Data(contentsOf: storage))
            if exact {
                XCTAssertEqual(saved.attempts.first?.status, .observed)
                XCTAssertEqual(saved.attempts.first?.messageID, attempt.id.uuidString)
                XCTAssertEqual(saved.localConversations[comparison.uuidString]?.map(\.text), ["Earlier question", "Earlier reply", "Question", "Answer"])
            } else {
                XCTAssertEqual(saved.attempts.first?.status, .uncertain)
                XCTAssertNil(saved.attempts.first?.messageID)
                XCTAssertEqual(saved.localConversations[comparison.uuidString]?.map(\.text), ["Earlier question", "Earlier reply"])
            }
            let calls = try await finishedCalls(fixture)
            XCTAssertFalse(calls.contains { ["type_text", "press_key", "click", "launch_app"].contains($0.tool) })
        }
    }

    func testWabiRecoversLegacyReceiptAfterAnOldRowDisappearsWithoutResending() async throws {
        let comparison = UUID(), url = wabiURL
        let baseline: [WabiAppMessage] = [.init(role: .assistant, text: "What can I do for you?"),
            .init(role: .user, text: "Earlier question"), .init(role: .assistant, text: "A \n\n garden.\n\nA \n\n pond.")]
        let created = try WabiReplyReceipt(comparisonID: comparison, url: url, prompt: "Next question", baseline: baseline)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(created)) as? [String: Any])
        for key in ["canonicalBaselineDigest", "canonicalReversedBaselineDigest", "canonicalOverlapDigests", "canonicalMessageDigests"] { json.removeValue(forKey: key) }
        let receipt = try JSONDecoder().decode(WabiReplyReceipt.self, from: JSONSerialization.data(withJSONObject: json))
        let fixture = try driver([apps(.wabi), windows(), snapshot(wabi(), repeating: true)])
        defer { fixture.remove() }
        let visible: [WabiAppMessage] = [baseline[0], .init(role: .assistant, text: "A\n\ngarden.\n\nA\n\npond."),
                                         .init(role: .user, text: "Next question"), .init(role: .assistant, text: "New answer")]
        let adapter = WabiAppConversation(executable: fixture.executable, timing: .init(stableDuration: .zero)) { _, _ in
            .init(url: url, draft: "", links: [], messages: visible)
        }
        let client = DesktopAppInstallationClient(inspect: { _ in .init(url: URL(fileURLWithPath: "/Fixture/Wabi.app"), processID: 4242) },
                                                   open: { _ in XCTFail("Recovery must not launch Wabi") })
        var state = WebWorkspaceState()
        state.enabled = true; state.comparisonID = comparison
        try state.recordWabiConversation(url, for: comparison)
        var attempt = WebSendAttempt(text: "Next question", status: .uncertain)
        attempt.comparisonID = comparison; attempt.wabiReplyReceipt = receipt
        state.attempts = [attempt]
        state.localConversations[comparison.uuidString] = Array(baseline.dropFirst()).map { .init(role: $0.role.rawValue, text: $0.text) }
        let storage = fixture.directory.appendingPathComponent("legacy-window.json")
        try JSONEncoder().encode(state).write(to: storage)
        let session = WebAgentSession(provider: .wabi, storageURL: storage, fixture: false, museApp: .shared, desktopApps: client, wabiApp: adapter)
        session.connect(automaticallyRefresh: false)
        _ = await session.reconcileWabiReplyOnce()
        session.beginShutdown()
        let saved = try JSONDecoder().decode(WebWorkspaceState.self, from: Data(contentsOf: storage))
        XCTAssertEqual(saved.attempts.first?.status, .observed)
        XCTAssertEqual(saved.localConversations[comparison.uuidString]?.map(\.text), ["Earlier question", baseline[2].text, "Next question", "New answer"])
        let calls = try await finishedCalls(fixture)
        XCTAssertFalse(calls.contains { ["type_text", "press_key", "click", "launch_app"].contains($0.tool) })
    }

    func testUnsentLaterRequestDoesNotBlockEarlierWabiRecovery() async throws {
        let comparison = UUID(), url = wabiURL
        let baseline: [WabiAppMessage] = [.init(role: .assistant, text: "Welcome")]
        let receipt = try WabiReplyReceipt(comparisonID: comparison, url: url, prompt: "Question", baseline: baseline)
        let client = DesktopAppInstallationClient(inspect: { _ in .init(url: URL(fileURLWithPath: "/Fixture/Wabi.app"), processID: 4242) }, open: { _ in XCTFail("Recovery must not launch Wabi") })
        for laterStatus in [WebSendStatus.preparing, .notSent, .observed, .dismissed] {
            let fixture = try driver([apps(.wabi), windows(), snapshot(wabi(), repeating: true)])
            defer { fixture.remove() }
            let adapter = WabiAppConversation(executable: fixture.executable, timing: .init(stableDuration: .zero)) { _, _ in
                .init(url: url, draft: "", links: [], messages: baseline + [.init(role: .user, text: "Question"), .init(role: .assistant, text: "Late answer")])
            }
            var workspace = WebWorkspaceState()
            workspace.enabled = true; workspace.comparisonID = comparison
            try workspace.recordWabiConversation(url, for: comparison)
            var earlier = WebSendAttempt(text: "Question", status: .uncertain)
            earlier.comparisonID = comparison; earlier.wabiReplyReceipt = receipt
            var later = WebSendAttempt(text: "Later question", status: laterStatus)
            later.comparisonID = comparison
            workspace.attempts = [later, earlier]
            let storage = fixture.directory.appendingPathComponent("\(laterStatus.rawValue).json")
            try JSONEncoder().encode(workspace).write(to: storage)
            let session = WebAgentSession(provider: .wabi, storageURL: storage, fixture: false, museApp: .shared, desktopApps: client, wabiApp: adapter)
            session.connect(automaticallyRefresh: false)
            _ = await session.reconcileWabiReplyOnce()
            session.beginShutdown()
            let saved = try JSONDecoder().decode(WebWorkspaceState.self, from: Data(contentsOf: storage))
            let safeToRecover = laterStatus == .preparing || laterStatus == .notSent
            XCTAssertEqual(saved.attempts.first(where: { $0.id == earlier.id })?.status, safeToRecover ? .observed : .uncertain)
            XCTAssertEqual(saved.attempts.first(where: { $0.id == later.id })?.status, laterStatus == .preparing ? .notSent : laterStatus)
            XCTAssertEqual(saved.localConversations[comparison.uuidString]?.map(\.text) ?? [], safeToRecover ? ["Question", "Late answer"] : [])
            let calls = safeToRecover ? try await finishedCalls(fixture) : try fixture.calls()
            XCTAssertFalse(calls.contains { ["type_text", "press_key", "click", "launch_app"].contains($0.tool) })
        }
    }

    func testLegacyWabiRecoveryHandlesADeletedMiddleRowWithoutResending() async throws {
        let comparison = UUID(), url = wabiURL
        let baseline = (0..<13).map { WabiAppMessage(role: $0.isMultiple(of: 2) ? .assistant : .user, text: "Earlier \($0)") }
        let generated = try WabiReplyReceipt(comparisonID: comparison, url: url, prompt: "Question", baseline: baseline)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(generated)) as? [String: Any])
        json.removeValue(forKey: "messageDigests")
        for key in ["canonicalBaselineDigest", "canonicalReversedBaselineDigest", "canonicalOverlapDigests", "canonicalMessageDigests"] { json.removeValue(forKey: key) }
        let receipt = try JSONDecoder().decode(WabiReplyReceipt.self, from: JSONSerialization.data(withJSONObject: json))
        let fixture = try driver([apps(.wabi), windows(), snapshot(wabi(), repeating: true)])
        defer { fixture.remove() }
        let adapter = WabiAppConversation(executable: fixture.executable, timing: .init(stableDuration: .zero)) { _, _ in
            .init(url: url, draft: "", links: [], messages: Array(baseline.prefix(2)) + Array(baseline.dropFirst(3)) + [.init(role: .user, text: "Question"), .init(role: .assistant, text: "Answer")])
        }
        let client = DesktopAppInstallationClient(inspect: { _ in .init(url: URL(fileURLWithPath: "/Fixture/Wabi.app"), processID: 4242) }, open: { _ in XCTFail("Recovery must not launch Wabi") })
        var workspace = WebWorkspaceState()
        workspace.enabled = true; workspace.comparisonID = comparison; workspace.draft = "Keep next draft"
        try workspace.recordWabiConversation(url, for: comparison)
        var attempt = WebSendAttempt(text: "Question", status: .uncertain)
        attempt.comparisonID = comparison; attempt.wabiReplyReceipt = receipt
        workspace.attempts = [attempt]
        workspace.localConversations[comparison.uuidString] = [WebPageMessage(role: "user", text: "Older local message")] + baseline.map { WebPageMessage(role: $0.role.rawValue, text: $0.text) }
        let storage = fixture.directory.appendingPathComponent("legacy-middle.json")
        try JSONEncoder().encode(workspace).write(to: storage)
        let session = WebAgentSession(provider: .wabi, storageURL: storage, fixture: false, museApp: .shared, desktopApps: client, wabiApp: adapter)
        session.connect(automaticallyRefresh: false)
        let remaining = await session.reconcileWabiReplyOnce()
        session.beginShutdown()
        XCTAssertFalse(remaining)
        let saved = try JSONDecoder().decode(WebWorkspaceState.self, from: Data(contentsOf: storage))
        XCTAssertEqual(saved.attempts.first?.status, .observed)
        XCTAssertEqual(saved.localConversations[comparison.uuidString]?.suffix(2).map(\.text), ["Question", "Answer"])
        XCTAssertEqual(saved.draft, "Keep next draft")
        let calls = try await finishedCalls(fixture)
        XCTAssertFalse(calls.contains { ["type_text", "press_key", "click", "launch_app"].contains($0.tool) })
    }

    func testLegacyWabiRecoveryVerifiesSavedLocalHistoryBeforeUsingIt() async throws {
        let comparison = UUID(), url = wabiURL
        let baseline = (0..<6).map { WabiAppMessage(role: $0.isMultiple(of: 2) ? .user : .assistant, text: "Earlier message \($0)") }
        let generated = try WabiReplyReceipt(comparisonID: comparison, url: url, prompt: "Question", baseline: baseline)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(generated)) as? [String: Any])
        json.removeValue(forKey: "overlapDigests")
        json.removeValue(forKey: "messageDigests")
        for key in ["canonicalBaselineDigest", "canonicalReversedBaselineDigest", "canonicalOverlapDigests", "canonicalMessageDigests"] { json.removeValue(forKey: key) }
        let legacy = try JSONDecoder().decode(WabiReplyReceipt.self, from: JSONSerialization.data(withJSONObject: json))
        let client = DesktopAppInstallationClient(inspect: { _ in .init(url: URL(fileURLWithPath: "/Fixture/Wabi.app"), processID: 4242) }, open: { _ in XCTFail("Recovery must not launch Wabi") })
        for historyMatches in [true, false] {
            let fixture = try driver([apps(.wabi), windows(), snapshot(wabi(), repeating: true)])
            defer { fixture.remove() }
            let adapter = WabiAppConversation(executable: fixture.executable, timing: .init(stableDuration: .zero)) { _, _ in
                .init(url: url, draft: "", links: [], messages: Array(baseline.dropFirst()) + [.init(role: .user, text: "Question"), .init(role: .assistant, text: "Answer")])
            }
            var workspace = WebWorkspaceState()
            workspace.enabled = true; workspace.comparisonID = comparison
            try workspace.recordWabiConversation(url, for: comparison)
            var attempt = WebSendAttempt(text: "Question", status: .uncertain)
            attempt.comparisonID = comparison; attempt.wabiReplyReceipt = legacy
            workspace.attempts = [attempt]
            var local = baseline.map { WebPageMessage(role: $0.role.rawValue, text: $0.text) }
            if !historyMatches { local[0] = .init(role: "user", text: "Different message") }
            workspace.localConversations[comparison.uuidString] = local
            let storage = fixture.directory.appendingPathComponent("legacy.json")
            try JSONEncoder().encode(workspace).write(to: storage)
            let session = WebAgentSession(provider: .wabi, storageURL: storage, fixture: false, museApp: .shared, desktopApps: client, wabiApp: adapter)
            session.connect(automaticallyRefresh: false)
            _ = await session.reconcileWabiReplyOnce()
            session.beginShutdown()
            let saved = try JSONDecoder().decode(WebWorkspaceState.self, from: Data(contentsOf: storage))
            XCTAssertEqual(saved.attempts.first?.status, historyMatches ? .observed : .uncertain)
            XCTAssertEqual(saved.localConversations[comparison.uuidString]?.count, historyMatches ? 8 : 6)
            let calls = try await finishedCalls(fixture)
            XCTAssertFalse(calls.contains { ["type_text", "press_key", "click", "launch_app"].contains($0.tool) })
        }
    }

    func testWabiRecoveryRejectsCancelledAndAmbiguousRequests() async throws {
        let fixture = try driver([])
        defer { fixture.remove() }
        let comparison = UUID(), url = wabiURL
        let receipt = try WabiReplyReceipt(comparisonID: comparison, url: url, prompt: "Question", baseline: [.init(role: .assistant, text: "Welcome")])
        let client = DesktopAppInstallationClient(inspect: { _ in .init(url: URL(fileURLWithPath: "/Fixture/Wabi.app"), processID: 4242) }, open: { _ in XCTFail("Recovery must not launch Wabi") })
        for scenario in ["cancelled", "wrong binding", "multiple requests", "missing outgoing", "interleaved", "wrong comparison", "unsupported version"] {
            var workspace = WebWorkspaceState()
            workspace.enabled = true; workspace.comparisonID = comparison
            try workspace.recordWabiConversation(scenario == "wrong binding" ? otherWabiURL : url, for: comparison)
            var attempt = WebSendAttempt(text: "Question", status: .uncertain)
            attempt.comparisonID = comparison; attempt.messageID = attempt.id.uuidString; attempt.wabiReplyReceipt = receipt
            if scenario == "cancelled" { attempt.wabiReplyReceipt?.automaticRecovery = false }
            if scenario == "wrong comparison" { attempt.wabiReplyReceipt = try .init(comparisonID: UUID(), url: url, prompt: "Question", baseline: []) }
            if scenario == "unsupported version" { attempt.wabiReplyReceipt?.version = 2 }
            workspace.attempts = [attempt]
            workspace.localConversations[comparison.uuidString] = [.init(id: attempt.id.uuidString, role: "user", text: attempt.text)]
            if scenario == "missing outgoing" { workspace.localConversations[comparison.uuidString] = [] }
            if scenario == "interleaved" { workspace.localConversations[comparison.uuidString]?.append(.init(role: "user", text: "Another request")) }
            if scenario == "multiple requests" {
                var second = WebSendAttempt(text: "Another request", status: .uncertain)
                second.comparisonID = comparison; workspace.attempts.append(second)
            }
            let storage = fixture.directory.appendingPathComponent("wabi-\(scenario).json")
            try JSONEncoder().encode(workspace).write(to: storage)
            let session = WebAgentSession(provider: .wabi, storageURL: storage, fixture: false, museApp: .shared, desktopApps: client)
            session.connect(automaticallyRefresh: false)
            let remaining = await session.reconcileWabiReplyOnce()
            XCTAssertFalse(remaining, scenario)
            XCTAssertEqual(session.state.attempts.first?.status, .uncertain, scenario)
            session.beginShutdown()
        }
        XCTAssertTrue(try fixture.calls().isEmpty, "Unsafe recovery must not inspect or interact with any app")
    }

    func testWabiRecoveryDoesNotAttributeReplyFromAnotherOpenThread() async throws {
        let fixture = try driver([apps(.wabi), windows(), snapshot(wabi())])
        defer { fixture.remove() }
        let receipt = try WabiReplyReceipt(comparisonID: UUID(), url: wabiURL, prompt: "Question", baseline: [])
        let wrongURL = otherWabiURL
        let adapter = WabiAppConversation(executable: fixture.executable, timing: .init(stableDuration: .zero)) { _, _ in
            .init(url: wrongURL, draft: "", links: [], messages: [.init(role: .user, text: "Question"), .init(role: .assistant, text: "Wrong chat")])
        }
        do {
            _ = try await adapter.recoverReply(receipt)
            XCTFail("A reply from a different thread must not be attributed")
        } catch { XCTAssertTrue(error.localizedDescription.contains("selected chat changed")) }
        let calls = try await finishedCalls(fixture)
        XCTAssertFalse(calls.contains { ["type_text", "press_key", "click", "launch_app"].contains($0.tool) })
    }

    func testWabiRecoveryRechecksRequestAfterAnInFlightRead() async throws {
        let comparison = UUID(), url = wabiURL
        let baseline: [WabiAppMessage] = [.init(role: .assistant, text: "Welcome")]
        let receipt = try WabiReplyReceipt(comparisonID: comparison, url: url, prompt: "Question", baseline: baseline)
        let fixture = try driver([apps(.wabi), windows(), snapshot(wabi(), repeating: true)])
        defer { fixture.remove() }
        let started = expectation(description: "Native read started")
        let resume = DispatchSemaphore(value: 0)
        let marker = fixture.directory.appendingPathComponent("read-started")
        let adapter = WabiAppConversation(executable: fixture.executable, timing: .init(stableDuration: .zero)) { _, _ in
            if !FileManager.default.fileExists(atPath: marker.path) {
                try Data().write(to: marker)
                started.fulfill()
                guard resume.wait(timeout: .now() + 5) == .success else { throw CocoaError(.userCancelled) }
            }
            return .init(url: url, draft: "", links: [], messages: baseline + [.init(role: .user, text: "Question"), .init(role: .assistant, text: "Late answer")])
        }
        let client = DesktopAppInstallationClient(inspect: { _ in .init(url: URL(fileURLWithPath: "/Fixture/Wabi.app"), processID: 4242) }, open: { _ in XCTFail("Recovery must not launch Wabi") })
        var workspace = WebWorkspaceState()
        workspace.enabled = true; workspace.comparisonID = comparison
        try workspace.recordWabiConversation(url, for: comparison)
        var attempt = WebSendAttempt(text: "Question", status: .uncertain)
        attempt.comparisonID = comparison; attempt.messageID = attempt.id.uuidString; attempt.wabiReplyReceipt = receipt
        workspace.attempts = [attempt]
        workspace.localConversations[comparison.uuidString] = [.init(id: attempt.id.uuidString, role: "user", text: attempt.text)]
        let storage = fixture.directory.appendingPathComponent("in-flight.json")
        try JSONEncoder().encode(workspace).write(to: storage)
        let session = WebAgentSession(provider: .wabi, storageURL: storage, fixture: false, museApp: .shared, desktopApps: client, wabiApp: adapter)
        session.connect(automaticallyRefresh: false)
        let recovery = Task { await session.reconcileWabiReplyOnce() }
        await fulfillment(of: [started], timeout: 3)
        session.updateState { $0.attempts[0].status = .dismissed }
        resume.signal()
        let remaining = await recovery.value
        session.beginShutdown()
        XCTAssertFalse(remaining)
        let saved = try JSONDecoder().decode(WebWorkspaceState.self, from: Data(contentsOf: storage))
        XCTAssertEqual(saved.attempts.first?.status, .dismissed)
        XCTAssertEqual(saved.localConversations[comparison.uuidString]?.map(\.text), ["Question"])
        XCTAssertFalse(try fixture.calls().contains { ["type_text", "press_key", "click", "launch_app"].contains($0.tool) })
    }

    func testWabiUnconfirmedRecoveryDoesNotOverwriteHistoryChangedDuringRead() async throws {
        let comparison = UUID(), url = wabiURL
        let baseline: [WabiAppMessage] = [.init(role: .user, text: "Earlier"), .init(role: .assistant, text: "Earlier reply")]
        let receipt = try WabiReplyReceipt(comparisonID: comparison, url: url, prompt: "Question", baseline: baseline)
        let fixture = try driver([apps(.wabi), windows(), snapshot(wabi(), repeating: true)])
        defer { fixture.remove() }
        let started = expectation(description: "Native read started")
        let resume = DispatchSemaphore(value: 0)
        let marker = fixture.directory.appendingPathComponent("read-started")
        let adapter = WabiAppConversation(executable: fixture.executable, timing: .init(stableDuration: .zero)) { _, _ in
            if !FileManager.default.fileExists(atPath: marker.path) {
                try Data().write(to: marker); started.fulfill()
                guard resume.wait(timeout: .now() + 5) == .success else { throw CocoaError(.userCancelled) }
            }
            return .init(url: url, draft: "", links: [], messages: baseline + [.init(role: .user, text: "Question"), .init(role: .assistant, text: "Answer")])
        }
        let client = DesktopAppInstallationClient(inspect: { _ in .init(url: URL(fileURLWithPath: "/Fixture/Wabi.app"), processID: 4242) }, open: { _ in XCTFail("Recovery must not launch Wabi") })
        var workspace = WebWorkspaceState()
        workspace.enabled = true; workspace.comparisonID = comparison
        try workspace.recordWabiConversation(url, for: comparison)
        var attempt = WebSendAttempt(text: "Question", status: .uncertain)
        attempt.comparisonID = comparison; attempt.wabiReplyReceipt = receipt
        workspace.attempts = [attempt]
        workspace.localConversations[comparison.uuidString] = [.init(role: "user", text: "Earlier"), .init(role: "assistant", text: "Earlier reply")]
        let storage = fixture.directory.appendingPathComponent("in-flight-unconfirmed.json")
        try JSONEncoder().encode(workspace).write(to: storage)
        let session = WebAgentSession(provider: .wabi, storageURL: storage, fixture: false, museApp: .shared, desktopApps: client, wabiApp: adapter)
        session.connect(automaticallyRefresh: false)
        let recovery = Task { await session.reconcileWabiReplyOnce() }
        await fulfillment(of: [started], timeout: 3)
        session.updateState { $0.localConversations[comparison.uuidString]?.append(.init(role: "user", text: "Newer local message")) }
        resume.signal()
        _ = await recovery.value
        session.beginShutdown()
        let saved = try JSONDecoder().decode(WebWorkspaceState.self, from: Data(contentsOf: storage))
        XCTAssertEqual(saved.attempts.first?.status, .uncertain)
        XCTAssertNil(saved.attempts.first?.messageID)
        XCTAssertEqual(saved.localConversations[comparison.uuidString]?.map(\.text), ["Earlier", "Earlier reply", "Newer local message"])
        XCTAssertFalse(try fixture.calls().contains { ["type_text", "press_key", "click", "launch_app"].contains($0.tool) })
    }


    private let prompt = "Fixture prompt"
    private let binding = DesktopConversationBinding(name: "Fixture Bot")

    func testMuseFindsOtherDesktopAndRejectsAmbiguousMainWindows() async throws {
        try await assertOtherDesktopTarget(.muse)
    }

    func testGrokBotFindsOtherDesktopAndRejectsAmbiguousMainWindows() async throws {
        try await assertOtherDesktopTarget(.grokBot)
    }

    func testWabiFindsOtherDesktopAndRejectsAmbiguousMainWindows() async throws {
        try await assertOtherDesktopTarget(.wabi)
    }

    func testGeminiFindsOtherDesktopAndRejectsAmbiguousMainWindows() async throws {
        try await assertOtherDesktopTarget(.gemini)
    }

    func testChatGPTFindsOtherDesktopAndRejectsAmbiguousMainWindows() async throws {
        try await assertOtherDesktopTarget(.chatgpt)
    }

    func testDotsFindsOtherDesktopAndRejectsAmbiguousMainWindows() async throws {
        try await assertOtherDesktopTarget(.dots)
    }

    func testClaudeFindsOtherDesktopAndRejectsAmbiguousMainWindows() async throws {
        try await assertOtherDesktopTarget(.claude)
    }

    private func assertOtherDesktopTarget(_ app: DesktopAppProvider) async throws {
        func window(_ id: Int, onScreen: Bool, title: String = "Fixture chat", width: Int = 800) -> [String: Any] {
            ["window_id": id, "title": title, "is_on_screen": onScreen, "on_current_space": onScreen,
             "space_ids": [onScreen ? 3 : 1], "bounds": ["width": width, "height": 600]]
        }
        // An on-screen helper/login window must not hide the main window on another Space.
        let main = window(101, onScreen: false, title: [.gemini, .chatgpt, .dots, .claude].contains(app) ? "" : "Fixture chat")
        var hidden = window(11, onScreen: false, title: "")
        hidden["space_ids"] = NSNull()
        // Claude retains a full-display layer-1000 helper on every Space.
        // Space membership does not turn overlays into conversation windows.
        var overlay = window(12, onScreen: false, title: "")
        overlay["space_ids"] = [1, 3, 20]
        overlay["layer"] = 1000
        let fixture = try driver([apps(app), step("list_windows", ["windows": [
            window(9, onScreen: true, width: 200), window(10, onScreen: true, title: "Log in"), hidden, overlay, main
        ]])])
        defer { fixture.remove() }
        let target = try await adapter(fixture).target(app)
        XCTAssertEqual(target, .init(pid: 4242, window: 101))
        let calls = try fixture.calls()
        XCTAssertEqual(calls.map(\.tool), ["list_apps", "list_windows"], "Discovery must not activate, move, or send input to an app")
        for extraOnScreen in [true, false] {
            let ambiguous = try driver([apps(app), step("list_windows", ["windows": [main, window(102, onScreen: extraOnScreen)]])])
            defer { ambiguous.remove() }
            let error = await failure { _ = try await self.adapter(ambiguous).target(app) }
            XCTAssertTrue(error.contains("one main"), error)
            let ambiguousCalls = try ambiguous.calls()
            XCTAssertEqual(ambiguousCalls.map(\.tool), ["list_apps", "list_windows"], "Never prefer a visible window over another account/chat")
        }
    }

    func testBotDiscoveryAndSelectionAreReadOnly() async throws {
        let initial = grok(name: "Other Bot", bots: ["Other Bot", "Fixture Bot"])
        let discovery = try driver([apps(), windows(), snapshot(initial)])
        defer { discovery.remove() }
        let names = try await adapter(discovery).availableGrokBots()
        XCTAssertEqual(names, ["Fixture Bot", "Other Bot"])
        assertNoInput(try await finishedCalls(discovery))
        let fixture = try driver([apps(), windows(), snapshot(initial)])
        defer { fixture.remove() }
        let selected = try await adapter(fixture).connectGrokBot(named: "Fixture Bot")
        XCTAssertEqual(selected.name, "Fixture Bot")
        let calls = try await finishedCalls(fixture)
        assertNoInput(calls)
    }

    func testGrokSetupInitializesColdNativeControlsAndRestoresHostWithoutSending() async throws {
        try await assertColdNativeSetup(.grokBotApp)
    }

    func testPassiveGrokDiscoveryDoesNotActivateColdAppBeforeExplicitConnect() async throws {
        try await assertColdNativeSetup(.grokBotApp, checkPassiveDiscovery: true)
    }

    func testWabiSetupInitializesColdNativeControlsAndRestoresHostWithoutSending() async throws {
        try await assertColdNativeSetup(.wabi)
    }

    func testColdNativeSetupPreservesExternalDraftAndRestoresHostAfterRefusal() async throws {
        try await assertColdNativeSetup(.wabi, externalDraft: "Keep the native app draft")
    }

    private func assertColdNativeSetup(_ provider: WebProvider, externalDraft: String = "", checkPassiveDiscovery: Bool = false) async throws {
        let app = try XCTUnwrap(provider.desktopApp)
        let fixture = try driver([])
        defer { fixture.remove() }
        let ready = app == .grokBot ? grok(bots: ["Fixture Bot"]) : wabiWith([element("AXButton", "New chat")], draft: externalDraft)
        try JSONSerialization.data(withJSONObject: ready).write(to: fixture.directory.appendingPathComponent("ready.json"))
        try Data(app.bundleID.utf8).write(to: fixture.directory.appendingPathComponent("bundle"))
        try Data(Self.coldSetupDriverScript.utf8).write(to: fixture.executable)
        let host = fixtureHost
        let control = DesktopAppConversation(executable: fixture.executable, delivery: .foreground, captureHostWindow: { host })
        let warmed = fixture.directory.appendingPathComponent("warmed")
        let wabi = WabiAppConversation(executable: fixture.executable, timing: .init(pollInterval: .milliseconds(5))) { _, _ in
            guard FileManager.default.fileExists(atPath: warmed.path) else { throw WabiObservationError.transient("Native controls are not initialized") }
            return WabiAppObservation(url: URL(string: "wabi://app/threads/aaaaaaaaaaaaaaaaaaaaaaaa")!, draft: externalDraft, links: [], messages: [], composerFocused: false)
        }
        let session = WebAgentSession(provider: provider, storageURL: fixture.directory.appendingPathComponent("state.json"),
                                      fixture: false, museApp: .shared, desktopApps: .demo, wabiApp: wabi, desktopDriver: control)
        defer { session.beginShutdown() }
        session.setEnabled(true)
        session.updateState { $0.draft = "Keep this msgblast draft" }
        if app == .grokBot {
            if checkPassiveDiscovery {
                await session.refreshGrokBots()
                XCTAssertTrue(session.grokBotNames.isEmpty, "Passive discovery must wait for an explicit Connect when native controls are cold")
                XCTAssertFalse(try fixture.calls().contains { $0.tool == "bring_to_front" }, "Opening setup or returning to msgblast must not activate Grok Bot")
                XCTAssertFalse(FileManager.default.fileExists(atPath: warmed.path))
            }
            await session.refreshGrokBots(activateIfNeeded: true)
            XCTAssertEqual(session.grokBotNames, ["Fixture Bot"], session.desktopStatus)
        } else {
            await session.connectDesktopConversation()
            if externalDraft.isEmpty { XCTAssertTrue(session.isReadyForOnboarding, session.desktopStatus) }
            else {
                XCTAssertFalse(session.isReadyForOnboarding)
                XCTAssertTrue(session.desktopStatus.contains("unsent draft"), session.desktopStatus)
            }
        }
        XCTAssertEqual(session.state.draft, "Keep this msgblast draft")
        XCTAssertTrue(session.state.attempts.isEmpty)
        XCTAssertTrue(session.state.localConversations.isEmpty)
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "bring_to_front" }.compactMap { $0.arguments["window_id"] as? Int }, [101, 201])
        XCTAssertFalse(calls.contains { ["click", "type_text", "set_value", "press_key"].contains($0.tool) })
    }

    private static let coldSetupDriverScript = #"""
    #!/usr/bin/env python3
    import json,os,pathlib,sys
    root=pathlib.Path(__file__).parent
    tool=sys.argv[2];args=json.loads(sys.argv[3])
    with (root/'calls.jsonl').open('a') as log:
        log.write(json.dumps({'tool':tool,'arguments':args,'pid':os.getpid()})+'\n')
    if tool=='list_apps':
        result={'apps':[{'bundle_id':(root/'bundle').read_text(),'pid':4242,'running':True}]}
    elif tool=='list_windows':
        assert args['pid']==4242
        result={'windows':[{'window_id':101,'title':'Main','is_on_screen':True,'bounds':{'width':800,'height':600}}]}
    elif tool=='bring_to_front':
        assert (args['pid'],args['window_id']) in [(4242,101),(9001,201)]
        if args['pid']==4242:(root/'warmed').touch()
        result={'activated':True,'pid':args['pid'],'window_id':args['window_id'],'exact_window_effect':{'verified':True}}
    elif tool=='get_window_state':
        assert args['pid']==4242 and args['window_id']==101
        result=json.loads((root/'ready.json').read_text()) if (root/'warmed').exists() else {'elements':[{'role':'AXWindow'}]}
    elif tool=='end_session':result={'active':False}
    else:raise AssertionError('Setup must never send input: '+tool)
    print(json.dumps(result))
    """#

    func testGrokSetupWithDraftOrActiveResponseListsSelectsAndRestoresWithoutInput() async throws {
        for generating in [false, true] {
            let current = grok(draft: "Keep this external draft", name: "Other Bot",
                               generating: generating, bots: ["Other Bot", "Fixture Bot"])
            let read = [apps(), windows(), snapshot(current)]
            let fixture = try driver(read + read + read + read)
            defer { fixture.remove() }
            let file = fixture.directory.appendingPathComponent("state.json")
            let session = WebAgentSession(provider: .grokBotApp, storageURL: file, fixture: false,
                                          museApp: .shared, desktopApps: .demo, desktopDriver: adapter(fixture))
            session.setEnabled(true)
            await session.refreshGrokBots()
            XCTAssertEqual(session.grokBotNames, ["Fixture Bot", "Other Bot"])
            await session.connectDesktopConversation(botName: "Fixture Bot")
            XCTAssertTrue(session.isReadyForOnboarding, session.desktopStatus)
            XCTAssertEqual(session.state.desktopConversation?.name, "Fixture Bot")
            XCTAssertTrue(session.state.attempts.isEmpty)
            session.beginShutdown()
            let reopened = WebAgentSession(provider: .grokBotApp, storageURL: file, fixture: false,
                                           museApp: .shared, desktopApps: .demo, desktopDriver: adapter(fixture))
            await reopened.refreshGrokBots()
            XCTAssertTrue(reopened.isReadyForOnboarding, reopened.desktopStatus)
            XCTAssertEqual(reopened.state.desktopConversation?.name, "Fixture Bot")
            XCTAssertTrue(reopened.state.attempts.isEmpty)
            assertNoInput(try await finishedCalls(fixture, cleanupCount: 4))
            reopened.beginShutdown()
        }
    }

    private let fixtureHost = DesktopAppConversation.Target(pid: 9001, window: 201)
    private func activation(_ target: DesktopAppConversation.Target = .init(pid: 4242, window: 101), verified: Bool = true) -> [String: Any] {
        ["tool": "bring_to_front", "arguments": ["pid": target.pid, "window_id": target.window],
         "result": ["activated": verified, "pid": target.pid, "window_id": target.window,
                    "exact_window_effect": ["verified": verified]]]
    }
    private func focusSteps(_ app: DesktopAppProvider = .grokBot) -> [[String: Any]] {
        [apps(app), windows(), activation()]
    }
    func testClaudePreparationOwnsFocusAndRestoresHostOnSuccessAndFailure() async throws {
        for shouldFail in [false, true] {
            let fixture = try driver(focusSteps(.claude) + [activation(fixtureHost)])
            defer { fixture.remove() }
            let host = fixtureHost
            let control = DesktopAppConversation(executable: fixture.executable, delivery: .foreground, captureHostWindow: { host })
            do {
                let result = try await DesktopAppWorkflow.preparation(.claude, driver: control) {
                    let focus = try fixture.calls().filter { $0.tool == "bring_to_front" }
                    XCTAssertEqual(focus.compactMap { $0.arguments["window_id"] as? Int }, [101])
                    if shouldFail { throw DesktopAppError.unavailable("Preparation failed") }
                    return "prepared"
                }
                XCTAssertFalse(shouldFail)
                XCTAssertEqual(result, "prepared")
            } catch {
                XCTAssertTrue(shouldFail, error.localizedDescription)
            }
            let calls = try await finishedCalls(fixture)
            XCTAssertEqual(calls.filter { $0.tool == "bring_to_front" }.compactMap { $0.arguments["window_id"] as? Int }, [101, 201])
            XCTAssertFalse(calls.contains { ["type_text", "press_key", "click"].contains($0.tool) })
        }
    }
    func testReplyRefreshRestoresTheExactHostOnceWithoutInput() async throws {
        let fixture = try driver([activation(), activation(fixtureHost)])
        defer { fixture.remove() }
        let control = adapter(fixture, delivery: .foreground)
        let lease = try await control.beginReplyRefresh(.init(pid: 4242, window: 101), session: "fixture-unread", host: fixtureHost, hostIsActive: { _ in true })
        let focus = try XCTUnwrap(lease)
        XCTAssertEqual(focus.host, fixtureHost)
        try await focus.restore()
        try await focus.restore()
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "bring_to_front" }.compactMap { $0.arguments["window_id"] as? Int }, [101, 201])
        XCTAssertFalse(calls.contains { ["click", "type_text", "press_key"].contains($0.tool) })
    }
    func testAuxiliaryWindowCannotRejectExactNativeHostRestorationOrReplayActivation() async throws {
        var partial = activation(fixtureHost, verified: false)
        partial["exit_code"] = 1
        partial["result"] = ["activated": false, "code": "bring_to_front_exact_window_unverified",
                             "exact_window_effect": ["focused": true, "verified": false],
                             "observed": ["focused_window_id": fixtureHost.window, "frontmost_ordinary_window_id": 202]]
        let fixture = try driver(focusSteps() + [partial])
        defer { fixture.remove() }
        let expected = fixtureHost, confirmation = FirstCall()
        let control = adapter(fixture, delivery: .foreground, confirmHostFocus: { host in
            XCTAssertEqual(host, expected)
            XCTAssertTrue(confirmation.take(), "Repeated cleanup must share the original native confirmation")
            return DesktopAppConversation.hostHasFocus(host, processID: expected.pid, keyWindow: expected.window, active: true, blocked: false)
        })
        let started = try await control.beginForeground(.grokBot, session: "host-tooltip", host: fixtureHost)
        let lease = try XCTUnwrap(started)
        try await lease.restore()
        try await lease.restore()
        let next = try await DesktopForegroundOwner.shared.acquire()
        await DesktopForegroundOwner.shared.release(next)
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "bring_to_front" }.compactMap { $0.arguments["window_id"] as? Int }, [101, 201])
        XCTAssertFalse(calls.contains { ["click", "type_text", "press_key"].contains($0.tool) })
    }
    func testPartialRestorationWithoutExactNativeHostFocusStillFails() async throws {
        var partial = activation(fixtureHost, verified: false)
        partial["exit_code"] = 1
        let fixture = try driver(focusSteps() + [partial])
        defer { fixture.remove() }
        let expected = fixtureHost
        let control = adapter(fixture, delivery: .foreground, confirmHostFocus: { host in
            XCTAssertEqual(host, expected)
            return DesktopAppConversation.hostHasFocus(host, processID: expected.pid, keyWindow: expected.window + 1, active: true, blocked: false)
        })
        let started = try await control.beginForeground(.grokBot, session: "host-not-focused", host: fixtureHost)
        let lease = try XCTUnwrap(started)
        let error = await failure { try await lease.restore() }
        XCTAssertTrue(error.contains("could not regain focus"), error)
        let next = try await DesktopForegroundOwner.shared.acquire()
        await DesktopForegroundOwner.shared.release(next)
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "bring_to_front" }.count, 2)
    }
    func testReplyRefreshDefersWhileHostIsInactiveOrAnotherAgentOwnsFocus() async throws {
        let fixture = try driver([])
        defer { fixture.remove() }
        let control = adapter(fixture, delivery: .foreground)
        let inactive = try await control.beginReplyRefresh(.init(pid: 4242, window: 101), session: "inactive", host: fixtureHost, hostIsActive: { _ in false })
        XCTAssertNil(inactive)
        let owner = try await DesktopForegroundOwner.shared.acquire()
        let busy = try await control.beginReplyRefresh(.init(pid: 4242, window: 101), session: "busy", host: fixtureHost, hostIsActive: { _ in true })
        await DesktopForegroundOwner.shared.release(owner)
        XCTAssertNil(busy)
        XCTAssertTrue(try fixture.calls().isEmpty)
    }
    func testForegroundGrokRestoresHostBeforeReplyCompletesAndSubmitsOnce() async throws {
        let fixture = try driver(focusSteps() + sendSteps() + [snapshot(grok(reply: "", generating: true)),
            activation(fixtureHost), snapshot(grok(reply: "Foreground answer"), repeating: true)])
        defer { fixture.remove() }
        let driver = adapter(fixture, delivery: .foreground)
        let focusValue = try await driver.beginForeground(.grokBot, session: "fixture-focus", host: fixtureHost)
        let focus = try XCTUnwrap(focusValue)
        let answer = try await driver.reply(prompt, app: .grokBot, binding: binding, releaseFocus: { try await focus.restore() })
        try await focus.restore()
        XCTAssertEqual(answer, "Foreground answer")
        let calls = try await finishedCalls(fixture)
        assertFocusTransaction(calls)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1)
    }
    func testHostRestoreFailureDoesNotPreventOwnedReplyCollectionOrReplayInput() async throws {
        let fixture = try driver(focusSteps() + sendSteps() + [snapshot(grok(reply: "", generating: true)),
            activation(fixtureHost, verified: false), snapshot(grok(reply: "Owned reply"), repeating: true)])
        defer { fixture.remove() }
        let driver = adapter(fixture, delivery: .foreground)
        let started = try await driver.beginForeground(.grokBot, session: "fixture-focus-refusal", host: fixtureHost)
        let focus = try XCTUnwrap(started)
        let answer = try await driver.reply(prompt, app: .grokBot, binding: binding, releaseFocus: { _ = try? await focus.restore() })
        XCTAssertEqual(answer, "Owned reply")
        let issue = await failure { try await focus.restore() }
        XCTAssertTrue(issue.contains("could not regain focus"))
        let next = try await DesktopForegroundOwner.shared.acquire()
        await DesktopForegroundOwner.shared.release(next)
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "bring_to_front" }.count, 2)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1)
    }
    func testGrokReplyReaderPreservesNewDraftWithoutDependingOnIt() async throws {
        let fixture = try driver(sendSteps() + [snapshot(grok(draft: "New external draft", reply: "Owned reply", focused: false), repeating: true)])
        defer { fixture.remove() }
        let answer = try await adapter(fixture).reply(prompt, app: .grokBot, binding: binding)
        XCTAssertEqual(answer, "Owned reply")
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1, "Reading the reply must not alter the new draft")
    }
    func testGrokReplyRevealsNewMessagesOnceWithoutResubmitting() async throws {
        var stale = grok(reply: "", token: "s00000004")
        var elements = stale["elements"] as! [[String: Any]]
        let composer = try XCTUnwrap(elements.firstIndex { $0["role"] as? String == "AXTextArea" })
        elements.insert(element("AXButton", "2 new messages", token: "s00000004:latest"), at: composer)
        stale["elements"] = elements
        stale["returned_element_count"] = elements.count
        stale["total_element_count"] = elements.count
        let reveal: [String: Any] = ["tool": "click", "arguments": ["element_token": "s00000004:latest", "delivery_mode": "background"], "result": [:]]
        let fixture = try driver(sendSteps() + [snapshot(stale), reveal, snapshot(grok(reply: "Newly visible answer"), repeating: true)])
        defer { fixture.remove() }
        let answer = try await adapter(fixture).reply(prompt, app: .grokBot, binding: binding)
        XCTAssertEqual(answer, "Newly visible answer")
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        XCTAssertEqual(calls.filter { $0.tool == "click" && $0.arguments["element_token"] as? String == "s00000004:latest" }.count, 1)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 2, "One submit and one read-only jump to the latest messages")
    }
    func testGrokRevealsLaterReplyWhenNewMessageCountChangesWithoutResubmitting() async throws {
        func unread(_ label: String, token: String) throws -> [String: Any] {
            var value = grok(reply: "", token: token)
            var elements = value["elements"] as! [[String: Any]]
            let composer = try XCTUnwrap(elements.firstIndex { $0["role"] as? String == "AXTextArea" })
            elements.insert(element("AXButton", label, token: token + ":latest"), at: composer)
            value["elements"] = elements; value["returned_element_count"] = elements.count; value["total_element_count"] = elements.count
            return value
        }
        for countResets in [false, true] {
            let first = try unread("1 new message", token: "s00000004")
            let afterFirstClick = countResets ? grok(reply: "") : first
            let later = try unread(countResets ? "1 new message" : "2 new messages", token: "s00000005")
            let fixture = try driver(sendSteps() + [snapshot(first), step("click", [:]), snapshot(afterFirstClick), snapshot(later), step("click", [:]), snapshot(grok(reply: "Later answer"), repeating: true)])
            defer { fixture.remove() }
            let answer = try await adapter(fixture, replyClock: .init(AdvancingClock())).reply(prompt, app: .grokBot, binding: binding)
            XCTAssertEqual(answer, "Later answer")
            let calls = try await finishedCalls(fixture)
            XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
            XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 3, "One submit; reveal each observed new-message transition once")
        }
    }
    func testForegroundWabiRestoresHostBeforeReplyCompletesAndKeepsDedicatedThread() async throws {
        var initial = windows(); initial["native"] = wabiNative()
        var typed = step("type_text", [:]); typed["native"] = wabiNative(draft: prompt)
        var sent = step("click", [:]); sent["native"] = wabiNative(messages: [.init(role: .user, text: prompt)])
        var returned = activation(fixtureHost)
        returned["native"] = wabiNative(messages: [.init(role: .user, text: prompt), .init(role: .assistant, text: "Foreground answer")])
        let fixture = try driver(focusSteps(.wabi) + [apps(.wabi), initial, capturedNavigation(wabi()), typed,
            snapshot(wabi(draft: prompt)), sent, snapshot(wabi()), returned, snapshot(wabi(reply: "Foreground answer"), repeating: true)])
        defer { fixture.remove() }
        let control = adapter(fixture, delivery: .foreground)
        let focusValue = try await control.beginForeground(.wabi, session: "fixture-focus", host: fixtureHost)
        let focus = try XCTUnwrap(focusValue)
        let answer = try await wabiAdapter(fixture).reply(prompt, in: wabiURL, releaseFocus: { try await focus.restore() })
        try await focus.restore()
        XCTAssertEqual(answer, "Foreground answer")
        let calls = try await finishedCalls(fixture)
        assertFocusTransaction(calls)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1)
    }
    func testForegroundMuseKeepsMultilineFocusAndRestoresOnOutgoingBeforeReply() async throws {
        let thread = UUID(), multiline = "First line 😀\nSecond line"
        var initial = windows(); initial["native"] = try object(museObservation(thread: thread))
        var returned = activation(fixtureHost)
        returned["native"] = try object(museObservation(thread: thread, messages: [.init(role: .user, text: multiline), .init(role: .assistant, text: "Foreground answer")]))
        let fixture = try driver(focusSteps(.muse) + [apps(.muse), initial, museComposerCapture(),
            try museStep("type_text", observation: museObservation(thread: thread, draft: "First line 😀")),
            try museStep("press_key", observation: museObservation(thread: thread, draft: "First line 😀\n\n")),
            try museStep("type_text", observation: museObservation(thread: thread, draft: multiline)),
            try museStep("press_key", observation: museObservation(thread: thread, messages: [.init(role: .user, text: multiline)])), returned])
        defer { fixture.remove() }
        let control = adapter(fixture, delivery: .foreground)
        let focusValue = try await control.beginForeground(.muse, session: "fixture-focus", host: fixtureHost)
        let focus = try XCTUnwrap(focusValue)
        let answer = try await museAdapter(fixture).reply(multiline, binding: .init(comparisonID: UUID(), threadID: thread, title: "Side chat"), releaseFocus: { try await focus.restore() }) { _ in }
        try await focus.restore()
        XCTAssertEqual(answer, "Foreground answer")
        let calls = try await finishedCalls(fixture)
        assertFocusTransaction(calls)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 2)
        XCTAssertEqual(calls.filter { $0.tool == "press_key" && $0.arguments["modifiers"] == nil }.count, 1)
    }
    func testForegroundCancellationAndRepeatedCleanupRestoreHostAndReleaseOwnership() async throws {
        for cancelled in [false, true] {
            let fixture = try driver(focusSteps() + [activation(fixtureHost)] + focusSteps(.wabi) + [activation(fixtureHost)])
            defer { fixture.remove() }
            let control = adapter(fixture, delivery: .foreground)
            let focusValue = try await control.beginForeground(.grokBot, session: "fixture-focus", host: fixtureHost)
        let focus = try XCTUnwrap(focusValue)
            let task = Task {
                if cancelled { withUnsafeCurrentTask { $0?.cancel() } }
                try await focus.restore()
            }
            try await task.value
            try await focus.restore()
            let nextValue = try await control.beginForeground(.wabi, session: "fixture-next", host: fixtureHost)
            let next = try XCTUnwrap(nextValue)
            try await next.restore()
            let calls = try fixture.calls()
            XCTAssertEqual(calls.filter { $0.tool == "bring_to_front" }.count, 4)
            XCTAssertFalse(calls.contains { ["click", "press_key", "type_text"].contains($0.tool) })
        }
    }
    func testForegroundRejectsConcurrentOwnerAndRestoresAfterPartialActivation() async throws {
        let fixture = try driver(focusSteps() + [activation(fixtureHost)] +
            [apps(), windows(), activation(verified: false), activation(fixtureHost)])
        defer { fixture.remove() }
        let control = adapter(fixture, delivery: .foreground)
        let focusValue = try await control.beginForeground(.grokBot, session: "fixture-focus", host: fixtureHost)
        let focus = try XCTUnwrap(focusValue)
        let busy = await failure { try await control.beginForeground(.wabi, session: "collision", host: self.fixtureHost) }
        XCTAssertTrue(busy.contains("Another App Agent"), busy)
        try await focus.restore()
        let partial = await failure { try await control.beginForeground(.grokBot, session: "partial", host: self.fixtureHost) }
        XCTAssertTrue(partial.contains("could not be focused"), partial)
        let calls = try fixture.calls()
        XCTAssertEqual(calls.filter { $0.tool == "bring_to_front" }.count, 4)
        XCTAssertFalse(calls.contains { ["click", "press_key", "type_text"].contains($0.tool) })
    }

    func testGrokSetupRejectsMissingAndDuplicateDestinationsWithoutInput() async throws {
        for bots in [["Other Bot"], ["Fixture Bot", "Fixture Bot"]] {
            let fixture = try driver([apps(), windows(), snapshot(grok(bots: bots))])
            defer { fixture.remove() }
            let error = await failure { _ = try await self.adapter(fixture).connectGrokBot(named: "Fixture Bot") }
            XCTAssertTrue(error.contains("missing or has a duplicate name"), error)
            assertNoInput(try await finishedCalls(fixture))
        }
    }

    func testSavedBotIsOpenedBeforeTypingAndDuplicateOrDraftedTargetsStop() async throws {
        let initial = grok(name: "Other Bot", bots: ["Other Bot", "Fixture Bot"])
        let fixture = try driver([apps(), windows(), snapshot(initial),
                                  step("click", [:], arguments: ["element_token": "s00000001:bot1"]),
                                  snapshot(grok(token: "s00000002")),
                                  step("type_text", [:], arguments: ["text": prompt]),
                                  snapshot(grok(draft: prompt, token: "s00000003")),
                                  step("click", [:], arguments: ["element_token": "s00000003:send"]),
                                  snapshot(grok(reply: "Chosen bot answer", token: "s00000004"), repeating: true)])
        defer { fixture.remove() }
        let answer = try await adapter(fixture).reply(prompt, app: .grokBot, binding: binding)
        XCTAssertEqual(answer, "Chosen bot answer")
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 2)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        for state in [grok(bots: ["Fixture Bot", "Fixture Bot"]), grok(draft: "Message Fixture Bot")] {
            let denied = try driver([apps(), windows(), snapshot(state)])
            defer { denied.remove() }
            _ = await failure { try await self.adapter(denied).reply(self.prompt, app: .grokBot, binding: self.binding) }
            assertNoInput(try await finishedCalls(denied))
        }
        let drafted = try driver([apps(), windows(), snapshot(initial), step("click", [:]), snapshot(grok(draft: "Keep this draft"))])
        defer { drafted.remove() }
        _ = await failure { try await self.adapter(drafted).reply(self.prompt, app: .grokBot, binding: self.binding) }
        let draftedCalls = try await finishedCalls(drafted)
        XCTAssertEqual(draftedCalls.filter { $0.tool == "click" }.count, 1, "Only bot navigation is allowed")
        XCTAssertFalse(draftedCalls.contains { $0.tool == "type_text" })
    }

    func testGrokCanSendToChosenBotWhileAnotherBotKeepsItsDraft() async throws {
        let initial = grok(draft: "Keep the other bot's draft", name: "Other Bot", bots: ["Other Bot", "Fixture Bot"])
        let fixture = try driver([apps(), windows(), snapshot(initial),
            step("click", [:], arguments: ["element_token": "s00000001:bot1"]), snapshot(grok()),
            step("type_text", [:], arguments: ["text": prompt]), snapshot(grok(draft: prompt)),
            step("click", [:], arguments: ["element_token": "s00000001:send"]), snapshot(grok(reply: "Chosen bot answer"), repeating: true)])
        defer { fixture.remove() }
        let answer = try await adapter(fixture).reply(prompt, app: .grokBot, binding: binding)
        XCTAssertEqual(answer, "Chosen bot answer")
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.compactMap { $0.arguments["text"] as? String }, [prompt])
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 2, "Navigate once and submit once; never clear the other draft")
        XCTAssertFalse(calls.contains { ["hotkey", "press_key", "set_value"].contains($0.tool) })
        assertBackgroundTargets(calls)
    }

    func testNativeBotOrDraftDisagreementAndReadFailurePreventAllInput() async throws {
        let observations: [[String: String]?] = [
            ["name": "Other Bot", "draft": ""],
            ["name": "Fixture Bot", "draft": "Keep this native draft"],
            nil
        ]
        for native in observations {
            var state = grok()
            state["_grok_native"] = native
            let fixture = try driver([apps(), windows(), snapshot(state)])
            defer { fixture.remove() }
            _ = await failure { try await self.adapter(fixture).reply(self.prompt, app: .grokBot, binding: self.binding) }
            assertNoInput(try await finishedCalls(fixture))
        }
    }

    func testNativeDisagreementAfterTypingNeverClicksSend() async throws {
        let observations: [[String: String]?] = [
            ["name": "Other Bot", "draft": prompt],
            ["name": "Fixture Bot", "draft": "Changed after typing"],
            nil
        ]
        for native in observations {
            var prepared = grok(draft: prompt, token: "s00000002")
            prepared["_grok_native"] = native
            var typed = step("type_text", [:])
            if native == nil { typed["remove_grok_native"] = true }
            let fixture = try driver([apps(), windows(), snapshot(grok()), typed, snapshot(prepared)])
            defer { fixture.remove() }
            _ = await failure { try await self.adapter(fixture).reply(self.prompt, app: .grokBot, binding: self.binding) }
            let calls = try await finishedCalls(fixture)
            XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
            XCTAssertFalse(calls.contains { $0.tool == "click" })
            assertBackgroundTargets(calls)
        }
    }

    func testChoosingABotSavesAndRestoresTheExplicitChoiceWithoutASend() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-bot-choice-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("state.json")
        let session = WebAgentSession(provider: .grokBotApp, storageURL: file, fixture: true)
        session.setEnabled(true)
        await session.refreshGrokBots()
        XCTAssertNil(session.state.desktopConversation)
        XCTAssertFalse(session.desktopReady)
        await session.connectDesktopConversation(botName: "Research Bot")
        XCTAssertTrue(session.desktopReady)
        XCTAssertEqual(session.state.desktopConversation?.name, "Research Bot")
        XCTAssertTrue(session.state.attempts.isEmpty)
        session.beginShutdown()
        let reopened = WebAgentSession(provider: .grokBotApp, storageURL: file, fixture: true)
        defer { reopened.beginShutdown() }
        await reopened.refreshGrokBots()
        XCTAssertEqual(reopened.state.desktopConversation?.name, "Research Bot")
        XCTAssertTrue(reopened.desktopReady)
        XCTAssertTrue(reopened.state.attempts.isEmpty)
        var pending = WebSendAttempt(text: "Earlier request", status: .uncertain)
        pending.comparisonID = UUID()
        reopened.updateState { $0.attempts = [pending] }
        await reopened.connectDesktopConversation(botName: "Writing Bot")
        XCTAssertEqual(reopened.state.desktopConversation?.name, "Research Bot")
        XCTAssertEqual(reopened.state.attempts.first?.status, .uncertain)
        XCTAssertFalse(reopened.desktopReady)
    }

    func testSavedBotAvailabilityChecksDoNotNavigateFromTheCurrentBot() async throws {
        let other = grok(name: "Other Bot", bots: ["Fixture Bot", "Other Bot"])
        let read = [apps(), windows(), snapshot(other)]
        let fixture = try driver(read + read + read)
        defer { fixture.remove() }
        let session = WebAgentSession(provider: .grokBotApp, storageURL: fixture.directory.appendingPathComponent("state.json"), fixture: false,
                                      museApp: .shared, desktopApps: .demo, desktopDriver: adapter(fixture))
        defer { session.beginShutdown() }
        session.setEnabled(true)
        session.updateState { $0.desktopConversation = binding }
        await session.refreshGrokBots()
        XCTAssertEqual(session.grokBotNames, ["Fixture Bot", "Other Bot"])
        XCTAssertEqual(session.state.desktopConversation, binding)
        XCTAssertTrue(session.isReadyForOnboarding, session.desktopStatus)
        await session.refresh()
        XCTAssertTrue(session.snapshot.ready, session.desktopStatus)
        XCTAssertTrue(session.state.attempts.isEmpty)
        assertNoInput(try await finishedCalls(fixture, cleanupCount: 3))
    }

    func testGrokDiscoveryStaysBusyUntilSavedBotReadinessFinishes() async throws {
        let initial = grok(bots: ["Fixture Bot", "Other Bot"])
        let read = [apps(), windows(), snapshot(initial)]
        let fixture = try driver(read + read)
        defer { fixture.remove() }
        let entered = expectation(description: "Saved bot readiness reached window discovery")
        let passiveReturned = expectation(description: "Passive discovery does not join an explicit connection")
        let (releaseGate, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        let firstReadiness = FirstCall()
        let run: DesktopAppConversation.ProcessRunner = { executable, arguments, environment, timeout, cancellation in
            if arguments.dropFirst().first == "list_windows",
               try fixture.calls().filter({ $0.tool == "get_window_state" }).count == 1,
               firstReadiness.take() {
                entered.fulfill()
                for await _ in releaseGate { break }
            }
            try Task.checkCancellation()
            return try await DesktopAppConversation.execute(executable, arguments, environment, timeout, cancellation)
        }
        let session = WebAgentSession(provider: .grokBotApp, storageURL: fixture.directory.appendingPathComponent("state.json"), fixture: false,
                                      museApp: .shared, desktopApps: .demo, desktopDriver: adapter(fixture, runProcess: run))
        defer { session.beginShutdown() }
        session.setEnabled(true)
        session.updateState { $0.desktopConversation = binding; $0.draft = "Keep this msgblast draft" }
        let connection = Task { await session.refreshGrokBots(activateIfNeeded: true) }
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertTrue(session.loading, "Connect must stay busy through its saved bot readiness check")
        let passive = Task {
            await session.refreshGrokBots()
            passiveReturned.fulfill()
        }
        await fulfillment(of: [passiveReturned], timeout: 5)
        release.yield(()); release.finish()
        await connection.value
        await passive.value
        XCTAssertFalse(session.loading)
        XCTAssertTrue(session.isReadyForOnboarding, session.desktopStatus)
        XCTAssertEqual(session.grokBotNames, ["Fixture Bot", "Other Bot"])
        XCTAssertEqual(session.state.desktopConversation, binding)
        XCTAssertEqual(session.state.draft, "Keep this msgblast draft")
        XCTAssertTrue(session.state.attempts.isEmpty)
        assertNoInput(try await finishedCalls(fixture, cleanupCount: 2))
    }

    func testGrokDiscoveryRechecksTheRelaunchedProcessBeforeBecomingReady() async throws {
        try await assertGrokDiscoveryAfterRelaunch(restartAgain: false)
    }

    func testGrokDiscoveryStopsIfTheProcessKeepsChanging() async throws {
        try await assertGrokDiscoveryAfterRelaunch(restartAgain: true)
    }

    private func assertGrokDiscoveryAfterRelaunch(restartAgain: Bool) async throws {
        @MainActor final class InstalledApp {
            var value = DesktopAppInstallation(url: URL(fileURLWithPath: "/Fixture/Grok Bot.app"), processID: 4242)
        }
        func read(pid: Int, window: Int, names: [String]) -> [[String: Any]] {
            var state = grok(bots: names)
            state["pid"] = pid; state["window_id"] = window
            return [step("list_apps", ["apps": [["bundle_id": DesktopAppProvider.grokBot.bundleID, "pid": pid, "running": true]]]),
                    step("list_windows", ["windows": [["window_id": window, "title": "Fixture app", "is_on_screen": true, "bounds": ["width": 800, "height": 600]]]]), snapshot(state)]
        }
        let old = read(pid: 4242, window: 101, names: ["Fixture Bot", "Old Bot"])
        let fresh = read(pid: 4243, window: 102, names: ["Fixture Bot", "New Bot"])
        let last = restartAgain ? read(pid: 4244, window: 103, names: ["Fixture Bot", "Newest Bot"]) : fresh
        let fixture = try driver(old + fresh + fresh + last)
        defer { fixture.remove() }
        let entered = expectation(description: "Saved-bot check has not resolved its process yet")
        let enteredAgain = restartAgain ? expectation(description: "Revalidation has reached its saved-bot check") : nil
        let (gate, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        let firstReadiness = FirstCall()
        let secondReadiness = FirstCall()
        let run: DesktopAppConversation.ProcessRunner = { executable, arguments, environment, timeout, cancellation in
            if arguments.dropFirst().first == "list_apps" {
                let reads = try fixture.calls().filter({ $0.tool == "get_window_state" }).count
                if reads == 1, firstReadiness.take() {
                    entered.fulfill()
                    for await _ in gate { break }
                } else if reads == 3, let enteredAgain, secondReadiness.take() {
                    enteredAgain.fulfill()
                    for await _ in gate { break }
                }
            }
            try Task.checkCancellation()
            return try await DesktopAppConversation.execute(executable, arguments, environment, timeout, cancellation)
        }
        let installed = InstalledApp()
        let client = DesktopAppInstallationClient(inspect: { _ in installed.value }, open: { _ in XCTFail("Discovery must not relaunch an app") })
        let session = WebAgentSession(provider: .grokBotApp, storageURL: fixture.directory.appendingPathComponent("state.json"), fixture: false,
                                      museApp: .shared, desktopApps: client, desktopDriver: adapter(fixture, runProcess: run))
        defer { session.beginShutdown() }
        session.setEnabled(true)
        session.updateState { $0.desktopConversation = binding; $0.draft = "Keep this msgblast draft" }
        let connection = Task { await session.refreshGrokBots(activateIfNeeded: true) }
        await fulfillment(of: [entered], timeout: 5)
        installed.value = .init(url: installed.value.url, processID: 4243)
        session.refreshDesktopInstallation()
        await session.refreshGrokBots()
        release.yield(())
        if let enteredAgain {
            await fulfillment(of: [enteredAgain], timeout: 5)
            installed.value = .init(url: installed.value.url, processID: 4244)
            session.refreshDesktopInstallation()
            await session.refreshGrokBots()
            release.yield(())
        }
        release.finish()
        await connection.value
        XCTAssertFalse(session.loading)
        XCTAssertEqual(session.isReadyForOnboarding, !restartAgain, session.desktopStatus)
        XCTAssertEqual(session.grokBotNames, restartAgain ? [] : ["Fixture Bot", "New Bot"], "Never restore the old process's bot list")
        if restartAgain { XCTAssertTrue(session.desktopStatus.contains("changed while connecting"), session.desktopStatus) }
        XCTAssertEqual(session.state.desktopConversation, binding)
        XCTAssertEqual(session.state.draft, "Keep this msgblast draft")
        XCTAssertTrue(session.state.attempts.isEmpty)
        let calls = try await finishedCalls(fixture, cleanupCount: 4)
        XCTAssertEqual(calls.filter { $0.tool == "get_window_state" }.compactMap { $0.arguments["pid"] as? Int }, [4242, 4243, 4243, restartAgain ? 4244 : 4243])
        assertNoInput(calls)
    }

    func testGrokDiscoveryAndSelectionWaitForReadinessRefresh() async throws {
        for choosing in [false, true] {
            let initial = grok(bots: ["Fixture Bot", "Other Bot"])
            let entered = expectation(description: "Readiness reached window discovery")
            let (releaseGate, release) = AsyncStream<Void>.makeStream()
            defer { release.finish() }
            let firstWindow = FirstCall()
            let run: DesktopAppConversation.ProcessRunner = { executable, arguments, environment, timeout, cancellation in
                if arguments.dropFirst().first == "list_windows", firstWindow.take() {
                    entered.fulfill()
                    for await _ in releaseGate { break }
                }
                try Task.checkCancellation()
                return try await DesktopAppConversation.execute(executable, arguments, environment, timeout, cancellation)
            }
            let afterRefresh = choosing
                ? [apps(), windows(), snapshot(initial)]
                : [apps(), windows(), snapshot(initial), apps(), windows(), snapshot(initial)]
            let fixture = try driver([apps(), windows(), snapshot(initial)] + afterRefresh)
            defer { fixture.remove() }
            let session = WebAgentSession(provider: .grokBotApp, storageURL: fixture.directory.appendingPathComponent("state.json"), fixture: false,
                                          museApp: .shared, desktopApps: .demo, desktopDriver: adapter(fixture, runProcess: run))
            defer { session.beginShutdown() }
            session.setEnabled(true)
            session.updateState { $0.desktopConversation = binding }
            session.connect(automaticallyRefresh: false)
            let readiness = Task { await session.refresh() }
            await fulfillment(of: [entered], timeout: 5)
            let setup = Task {
                if choosing { await session.connectDesktopConversation(botName: "Other Bot") }
                else { await session.refreshGrokBots() }
            }
            let setupDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !session.loading && ContinuousClock.now < setupDeadline { await Task.yield() }
            XCTAssertTrue(session.loading, "Setup must enter its wait before readiness is released")
            XCTAssertEqual(try fixture.calls().map(\.tool), ["list_apps"], "No setup driver call may overtake readiness")
            release.yield(()); release.finish()
            await readiness.value
            await setup.value
            XCTAssertEqual(session.state.desktopConversation?.name, choosing ? "Other Bot" : "Fixture Bot")
            if !choosing { XCTAssertEqual(session.grokBotNames, ["Fixture Bot", "Other Bot"]) }
            XCTAssertTrue(session.desktopReady, session.desktopStatus)
            XCTAssertTrue(session.state.attempts.isEmpty)
            let calls = try await finishedCalls(fixture, cleanupCount: choosing ? 2 : 3)
            XCTAssertFalse(calls.contains { $0.tool == "type_text" })
            if !choosing { assertNoInput(calls) }
        }
    }

    func testSendingWhileBotSelectionIsInProgressCannotUseTheOldBinding() async throws {
        var switching = snapshot(grok(bots: ["Fixture Bot", "Other Bot"]))
        switching["wait_for_release"] = true
        let fixture = try driver([apps(), windows(), snapshot(grok()), apps(), windows(), switching])
        defer { fixture.remove() }
        let session = WebAgentSession(provider: .grokBotApp, storageURL: fixture.directory.appendingPathComponent("state.json"), fixture: false,
                                      museApp: .shared, desktopApps: .demo, desktopDriver: adapter(fixture))
        defer { session.beginShutdown() }
        session.setEnabled(true)
        await session.connectDesktopConversation(botName: "Fixture Bot")
        XCTAssertTrue(session.snapshot.ready)
        let changing = Task { await session.connectDesktopConversation(botName: "Other Bot") }
        try await waitForCall("get_window_state", in: fixture, count: 2)
        XCTAssertTrue(session.loading)
        let sent = await session.send(prompt, comparisonID: UUID())
        XCTAssertNil(sent)
        XCTAssertTrue(session.state.attempts.isEmpty)
        changing.cancel()
        await changing.value
        XCTAssertEqual(session.state.desktopConversation?.name, "Fixture Bot")
        let calls = try await finishedCalls(fixture, cleanupCount: 2)
        XCTAssertFalse(calls.contains { $0.tool == "type_text" })
    }

    func testUnverifiedTypingUsesFreshDraftEvidenceAndSubmitsOnlyOnce() async throws {
        for diagnostic: [String: Any] in [
            ["effect": "unverifiable", "escalation": ["reason": "delivery_failed", "target": "foreground"]],
            ["effect": "partial", "code": "type_text_incomplete", "delivered_chars": 0]
        ] {
            let fixture = try driver([
                apps(), windows(), snapshot(grok()),
                step("type_text", diagnostic, arguments: ["text": prompt]),
                snapshot(grok(draft: prompt, token: "s00000002")),
                step("click", ["effect": "unverifiable"], arguments: ["element_token": "s00000002:send"]),
                snapshot(grok(reply: "Observed answer", token: "s00000003"), repeating: true)
            ])
            defer { fixture.remove() }
            let answer = try await adapter(fixture).reply(prompt, app: .grokBot, binding: binding)
            XCTAssertEqual(answer, "Observed answer")
            let calls = try await finishedCalls(fixture)
            XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1, "A false-negative type result must not replay the prompt")
            XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1)
            assertBackgroundTargets(calls)
        }
    }

    func testDelayedGrokDraftReadbackWaitsWithoutReplayingInput() async throws {
        let fixture = try driver([
            apps(), windows(), snapshot(grok()), step("type_text", ["effect": "unverifiable"], arguments: ["text": prompt]),
            snapshot(grok()), snapshot(grok(draft: prompt, token: "s00000002")),
            step("click", [:], arguments: ["element_token": "s00000002:send"]),
            snapshot(grok(reply: "Delayed draft verified", token: "s00000003"), repeating: true)
        ])
        defer { fixture.remove() }
        let answer = try await adapter(fixture).reply(prompt, app: .grokBot, binding: binding)
        XCTAssertEqual(answer, "Delayed draft verified")
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1)
        assertBackgroundTargets(calls)
    }

    func testWabiUsesCapturedPixelTypingInsteadOfRefusedElectronAXTarget() async throws {
        var initial = windows(); initial["native"] = wabiNative()
        var typed = step("type_text", ["effect": "unverifiable"])
        typed["arguments"] = ["text": prompt, "x": 540, "y": 780]
        typed["native"] = wabiNative(draft: prompt)
        var sent = step("click", [:], arguments: ["element_token": "s00000002:send"])
        sent["native"] = wabiNative(messages: [.init(role: .user, text: prompt), .init(role: .assistant, text: "Pixel input observed")])
        let fixture = try driver([apps(.wabi), initial, capturedNavigation(wabi()), typed,
            snapshot(wabi(draft: prompt, token: "s00000002")), sent, snapshot(wabi(reply: "Pixel input observed"), repeating: true)])
        defer { fixture.remove() }
        let answer = try await wabiAdapter(fixture).reply(prompt, in: wabiURL)
        XCTAssertEqual(answer, "Pixel input observed")
        let calls = try await finishedCalls(fixture)
        let typing = try XCTUnwrap(calls.first { $0.tool == "type_text" })
        XCTAssertNil(typing.arguments["element_token"], "0.38 refuses background Electron typing with an AX target")
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1, "Only the verified Send is clicked separately")
        assertBackgroundTargets(calls)
    }

    func testWabiRefreshesStaleEditorWithoutRetypingBeforeSubmit() async throws {
        var initial = windows(); initial["native"] = wabiNative()
        var typed = step("type_text", ["effect": "unverifiable"], arguments: ["text": prompt])
        typed["native"] = wabiNative()
        var refresh = activation(); refresh["native"] = wabiNative(draft: prompt)
        var sent = step("click", [:], arguments: ["element_token": "s00000002:send"])
        sent["native"] = wabiNative(messages: [.init(role: .user, text: prompt), .init(role: .assistant, text: "Fresh Wabi answer")])
        let fixture = try driver([apps(.wabi), initial, capturedNavigation(wabi()), typed, snapshot(wabi()), refresh,
                                  snapshot(wabi(draft: prompt, token: "s00000002")), sent,
                                  snapshot(wabi(reply: "Fresh Wabi answer"), repeating: true)])
        defer { fixture.remove() }
        let control = DesktopAppConversation(executable: fixture.executable)
        let answer = try await wabiAdapter(fixture).reply(prompt, in: wabiURL, refreshInput: { target, session in
            try await control.activate(target, session: session)
        })
        XCTAssertEqual(answer, "Fresh Wabi answer")
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        XCTAssertEqual(calls.filter { $0.tool == "bring_to_front" }.count, 1)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1)
    }

    func testWabiDoesNotRefreshOrSubmitAnUnexpectedDraft() async throws {
        var initial = windows(); initial["native"] = wabiNative()
        var typed = step("type_text", ["effect": "unverifiable"], arguments: ["text": prompt])
        typed["native"] = wabiNative(draft: "Someone else's draft")
        let fixture = try driver([apps(.wabi), initial, capturedNavigation(wabi()), typed,
                                  snapshot(wabi(draft: "Someone else's draft"))])
        defer { fixture.remove() }
        let error = await failure {
            try await self.wabiAdapter(fixture).reply(self.prompt, in: self.wabiURL, refreshInput: { _, _ in
                XCTFail("Unexpected text must never trigger a focus refresh or submission")
            })
        }
        XCTAssertTrue(error.contains("prepared draft"), error)
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        XCTAssertFalse(calls.contains { ["bring_to_front", "click"].contains($0.tool) })
    }

    func testWabiMultilineUsesVerifiedChunksAndShiftReturnWithoutRefocusingText() async throws {
        try await runWabiMultiline(driverTrimsWhitespace: false)
    }
    func testWabiNativeExactNewlineRemainsValidWhenDriverTrimsItsSnapshot() async throws {
        try await runWabiMultiline(driverTrimsWhitespace: true)
    }
    private func runWabiMultiline(driverTrimsWhitespace: Bool) async throws {
        let newlineDraft = driverTrimsWhitespace ? "One" : "One\n"
        let text = "One\nTwo 👩‍💻"
        var initial = windows(); initial["native"] = wabiNative(focused: false)
        func typing(_ tool: String, _ draft: String, arguments: [String: Any]) -> [String: Any] {
            var call = step(tool, ["effect": "unverifiable"])
            call["arguments"] = arguments
            call["native"] = wabiNative(draft: draft)
            return call
        }
        var send = step("click", [:]); send["native"] = wabiNative(messages: [.init(role: .user, text: text), .init(role: .assistant, text: "Multiline observed")])
        let fixture = try driver([apps(.wabi), initial, capturedNavigation(wabi()),
            typing("type_text", "One", arguments: ["text": "One", "x": 540, "y": 780]), snapshot(wabi(draft: "One")),
            capturedNavigation(wabi(draft: "One")), typing("press_key", "One\n", arguments: ["key": "return", "modifiers": ["shift"]]), snapshot(wabi(draft: newlineDraft)),
            capturedNavigation(wabi(draft: newlineDraft)), typing("type_text", text, arguments: ["text": "Two 👩‍💻"]), snapshot(wabi(draft: text)),
            send, snapshot(wabi(reply: "Multiline observed"), repeating: true)])
        defer { fixture.remove() }
        let result = try await wabiAdapter(fixture).reply(text, in: wabiURL)
        XCTAssertEqual(result, "Multiline observed")
        let calls = try await finishedCalls(fixture)
        let typingCalls = calls.filter { $0.tool == "type_text" }
        XCTAssertEqual(typingCalls.compactMap { $0.arguments["text"] as? String }, ["One", "Two 👩‍💻"])
        XCTAssertNil(typingCalls.last?.arguments["x"], "Refocusing a nonempty draft could move its insertion point")
        XCTAssertEqual(calls.filter { $0.tool == "press_key" }.count, 1)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1, "Only Send is clicked separately")
        for call in calls where call.arguments["screenshot_out_file"] != nil {
            XCTAssertFalse(FileManager.default.fileExists(atPath: call.arguments["screenshot_out_file"] as! String), "Private captures must be removed")
        }
        assertBackgroundTargets(calls)
    }
    func testWabiLiteralComposerLabelIsConfirmedAsTextInsteadOfAnEmptyPlaceholder() async throws {
        let text = "Message"
        var initial = windows(); initial["native"] = wabiNative()
        var typed = step("type_text", [:]); typed["native"] = wabiNative(draft: text)
        var sent = step("click", [:]); sent["native"] = wabiNative(messages: [.init(role: .user, text: text), .init(role: .assistant, text: "Literal text received")])
        let fixture = try driver([apps(.wabi), initial, capturedNavigation(wabi()), typed, snapshot(wabi(draft: text)), sent, snapshot(wabi(reply: "Literal text received"), repeating: true)])
        defer { fixture.remove() }
        let result = try await wabiAdapter(fixture).reply(text, in: wabiURL)
        XCTAssertEqual(result, "Literal text received")
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.first?.arguments["text"] as? String, text)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1)
    }

    func testWabiNativeDraftMustStayExactWhenDriverTrimsUnexpectedWhitespace() async throws {
        var initial = windows(); initial["native"] = wabiNative()
        var typed = step("type_text", [:]); typed["native"] = wabiNative(draft: prompt + " ")
        let fixture = try driver([apps(.wabi), initial, capturedNavigation(wabi()), typed, snapshot(wabi(draft: prompt))])
        defer { fixture.remove() }
        let error = await failure { try await self.wabiAdapter(fixture).reply(self.prompt, in: self.wabiURL) }
        XCTAssertTrue(error.contains("Send was not pressed"), error)
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        XCTAssertFalse(calls.contains { $0.tool == "click" || $0.tool == "press_key" }, "Exact native draft verification must not be replaced with trimming")
    }

    func testWabiLostFocusAfterFirstChunkStopsBeforeNewlineOrSend() async throws {
        var initial = windows(); initial["native"] = wabiNative()
        var typed = step("type_text", [:]); typed["native"] = wabiNative(draft: "One", focused: false)
        let fixture = try driver([apps(.wabi), initial, capturedNavigation(wabi()), typed, snapshot(wabi(draft: "One"))])
        defer { fixture.remove() }
        let error = await failure { try await self.wabiAdapter(fixture).reply("One\nTwo", in: self.wabiURL) }
        XCTAssertTrue(error.contains("focus"), error)
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        XCTAssertFalse(calls.contains { ["press_key", "click"].contains($0.tool) })
    }
    func testWabiInvalidOrChangedCapturePreventsTyping() async throws {
        for changed in [false, true] {
            var initial = windows(); initial["native"] = wabiNative()
            var capture = capturedNavigation(wabi())
            if changed { capture["native"] = wabiNative(url: otherWabiURL) }
            else { capture["capture"] = "missing" }
            let fixture = try driver([apps(.wabi), initial, capture])
            defer { fixture.remove() }
            let error = await failure { try await self.wabiAdapter(fixture).reply(self.prompt, in: self.wabiURL) }
            XCTAssertFalse(error.isEmpty)
            assertNoInput(try await finishedCalls(fixture))
        }
    }
    func testWabiRejectsSubmitAndNavigationControlCharactersBeforeDriverInput() async throws {
        for text in ["One\rTwo", "One\tTwo", "One\u{7f}Two"] {
            let fixture = try driver([])
            defer { fixture.remove() }
            let error = await failure { try await self.wabiAdapter(fixture).reply(text, in: self.wabiURL) }
            XCTAssertTrue(error.contains("control characters"), error)
            XCTAssertTrue(try fixture.calls().isEmpty)
        }
    }

    func testWabiTransientMessageLayoutAfterSendWaitsWithoutResending() async throws {
        var initial = windows(); initial["native"] = wabiNative()
        var typed = step("type_text", [:]); typed["native"] = wabiNative(draft: prompt)
        var sent = step("click", [:]); sent["native"] = wabiNative(messages: [.init(role: .user, text: prompt), .init(role: .assistant, text: "Completed after layout settled")])
        let fixture = try driver([apps(.wabi), initial, capturedNavigation(wabi()), typed, snapshot(wabi(draft: prompt)), sent, snapshot(wabi(reply: "Completed after layout settled"), repeating: true)])
        defer { fixture.remove() }
        let receiptSaved = expectation(description: "Baseline is saved before input")
        let result = try await wabiAdapter(fixture, transientAfterSend: true).reply(prompt, in: wabiURL, onReceipt: { baseline in
            XCTAssertTrue(baseline.isEmpty)
            XCTAssertFalse(try fixture.calls().contains { ["type_text", "click"].contains($0.tool) })
            receiptSaved.fulfill()
        })
        await fulfillment(of: [receiptSaved], timeout: 1)
        XCTAssertEqual(result, "Completed after layout settled")
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1)
    }

    func testWabiDoesNotTypeIfRecoveryReceiptCannotBeSaved() async throws {
        enum StorageFailure: Error { case denied }
        var initial = windows(); initial["native"] = wabiNative()
        let fixture = try driver([apps(.wabi), initial, capturedNavigation(wabi())])
        defer { fixture.remove() }
        do {
            _ = try await wabiAdapter(fixture).reply(prompt, in: wabiURL, onReceipt: { _ in throw StorageFailure.denied })
            XCTFail("A failed recovery receipt must stop before typing")
        } catch StorageFailure.denied { }
        let calls = try await finishedCalls(fixture)
        XCTAssertFalse(calls.contains { ["type_text", "press_key", "click"].contains($0.tool) })
    }

    func testWabiIncompleteLayoutDeadlineNeverResendsOrClaimsAReply() async throws {
        var initial = windows(); initial["native"] = wabiNative()
        var typed = step("type_text", [:]); typed["native"] = wabiNative(draft: prompt)
        var sent = step("click", [:]); sent["native"] = wabiNative(messages: [.init(role: .user, text: prompt), .init(role: .assistant, text: "Unverified reply")])
        let fixture = try driver([apps(.wabi), initial, capturedNavigation(wabi()), typed, snapshot(wabi(draft: prompt)), sent])
        defer { fixture.remove() }
        let error = await failure { try await self.wabiAdapter(fixture, neverSettlesAfterSend: true).reply(self.prompt, in: self.wabiURL) }
        XCTAssertTrue(error.contains("nothing will be resent automatically"), error)
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1)
    }

    func testWabiReplyMayFinishDuringReadbackWithoutReplayingInput() async throws {
        var initial = windows(); initial["native"] = wabiNative()
        var typed = step("type_text", [:]); typed["native"] = wabiNative(draft: prompt)
        let outgoing = WabiAppMessage(role: .user, text: prompt)
        var sent = step("click", [:]); sent["native"] = wabiNative(messages: [outgoing])
        var completed = snapshot(wabi(reply: "Finished during readback"), repeating: true)
        completed["native"] = wabiNative(messages: [outgoing, .init(role: .assistant, text: "Finished during readback")])
        let fixture = try driver([apps(.wabi), initial, capturedNavigation(wabi()), typed, snapshot(wabi(draft: prompt)), sent, completed])
        defer { fixture.remove() }
        let result = try await wabiAdapter(fixture).reply(prompt, in: wabiURL)
        XCTAssertEqual(result, "Finished during readback")
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1)
    }

    func testWabiUsesSavedThreadIdentityAndFreshSendControl() async throws {
        var initial = windows(); initial["native"] = wabiNative()
        var typed = step("type_text", ["effect": "unverifiable"])
        typed["native"] = wabiNative(draft: prompt)
        var sent = step("click", [:], arguments: ["element_token": "s00000002:send"])
        sent["native"] = wabiNative(messages: [.init(role: .user, text: prompt), .init(role: .assistant, text: "Wabi fixture answer")])
        var renamed = wabi(reply: "Wabi fixture answer", token: "s00000003")
        var body = renamed["elements"] as! [[String: Any]]; body[0]["label"] = "Renamed by Wabi"; renamed["elements"] = body
        let fixture = try driver([apps(.wabi), initial, capturedNavigation(wabi()), typed,
                                  snapshot(wabi(draft: prompt, token: "s00000002")), sent, snapshot(renamed, repeating: true)])
        defer { fixture.remove() }
        let answer = try await wabiAdapter(fixture).reply(prompt, in: wabiURL)
        XCTAssertEqual(answer, "Wabi fixture answer")
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        assertBackgroundTargets(calls)

        var wrong = windows(); wrong["native"] = wabiNative(url: otherWabiURL)
        let denied = try driver([apps(.wabi), wrong, snapshot(wabi())])
        defer { denied.remove() }
        let error = await failure { try await self.wabiAdapter(denied).reply(self.prompt, in: self.wabiURL) }
        XCTAssertTrue(error.contains("selected chat changed"), error)
        assertNoInput(try await finishedCalls(denied))
    }

    func testWabiReplyUsesNewMessagesInEitherOrderAndAcceptsAnEcho() async throws {
        let welcome = "What can I do for you?"
        for (messages, expected) in [(["New answer", prompt, welcome], "New answer"),
                                     ([welcome, prompt, prompt], prompt),
                                     (["Read", prompt, welcome], "Read"),
                                     (["Today", prompt, welcome], "Today"),
                                     (["5:13 PM", prompt, welcome], "5:13 PM")] {
            let before: [WabiAppMessage] = [.init(role: .assistant, text: welcome)]
            let outgoing = WabiAppMessage(role: .user, text: prompt)
            let incoming = WabiAppMessage(role: .assistant, text: expected)
            let observed = messages.first == welcome ? before + [outgoing, incoming] : [incoming, outgoing] + before
            var initial = windows(); initial["native"] = wabiNative(messages: before)
            var typed = step("type_text", [:]); typed["native"] = wabiNative(draft: prompt, messages: before)
            var sent = step("click", [:]); sent["native"] = wabiNative(messages: observed)
            let fixture = try driver([apps(.wabi), initial, capturedNavigation(wabiMessages([welcome])), typed,
                                      snapshot(wabiMessages([welcome], draft: prompt)), sent,
                                      snapshot(wabiMessages(messages), repeating: true)])
            defer { fixture.remove() }
            let answer = try await wabiAdapter(fixture).reply(prompt, in: wabiURL)
            XCTAssertEqual(answer, expected)
            let calls = try await finishedCalls(fixture)
            XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1)
            XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        }
    }

    private func wabiMessages(_ messages: [String], draft: String = "") -> [String: Any] {
        var state = wabi(draft: draft)
        var body = state["elements"] as! [[String: Any]]
        let content = messages.flatMap { [element("AXStaticText", $0), element("AXPopUpButton", "Add reaction"), element("AXStaticText", "5:13 PM")] }
        body.insert(contentsOf: content, at: 3)
        state["elements"] = body; state["returned_element_count"] = body.count; state["total_element_count"] = body.count
        return state
    }

    func testWabiCreatesAIThreadThroughChooserAndResumesExactSidebarURL() async throws {
        var creation = wabiCreationSteps()
        var blank = creation[6]["result"] as! [String: Any]
        var elements = blank["elements"] as! [[String: Any]]
        let sidebar = try XCTUnwrap(elements.firstIndex { $0["role"] as? String == "AXSplitter" })
        elements.insert(element("AXStaticText", "A new version of Wabi is ready."), at: sidebar + 1)
        blank["elements"] = elements; blank["returned_element_count"] = elements.count; blank["total_element_count"] = elements.count
        creation[6]["result"] = blank
        let fixture = try driver(creation)
        defer { fixture.remove() }
        let created = try await wabiAdapter(fixture).prepare(savedURL: nil)
        XCTAssertEqual(created, otherWabiURL)
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 2)
        XCTAssertFalse(calls.contains { $0.tool == "type_text" })
        assertBackgroundTargets(calls)

        var resume = windows(); resume["native"] = wabiNative(links: [["url": otherWabiURL.absoluteString, "label": "Same title"]])
        var select = step("click", [:], arguments: ["element_token": "s00000004:saved"]); select["native"] = wabiNative(url: otherWabiURL)
        let saved = try driver([apps(.wabi), resume, snapshot(wabiWith([element("AXLink", "Same title", token: "s00000004:saved")])), select, snapshot(wabi())])
        defer { saved.remove() }
        let resumed = try await wabiAdapter(saved).prepare(savedURL: otherWabiURL)
        XCTAssertEqual(resumed, otherWabiURL)
        let resumeCalls = try await finishedCalls(saved)
        XCTAssertEqual(resumeCalls.filter { $0.tool == "click" }.count, 1)
    }

    func testWabiResumesAnAlreadyOpenEmptyAIChooserWithoutReopeningIt() async throws {
        let creation = wabiCreationSteps()
        var initial = windows(); initial["native"] = wabiNative(draft: nil)
        let fixture = try driver([apps(.wabi), initial] + Array(creation[4...]))
        defer { fixture.remove() }
        let created = try await wabiAdapter(fixture).prepare(savedURL: nil)
        XCTAssertEqual(created, otherWabiURL)
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.compactMap { $0.arguments["element_token"] as? String }, ["s00000002:new"])
        XCTAssertFalse(calls.contains { $0.tool == "type_text" })
    }

    func testWabiReadinessAcceptsAnExistingEmptyAIChooser() async throws {
        let creation = wabiCreationSteps()
        var initial = windows(); initial["native"] = wabiNative(draft: nil)
        let fixture = try driver([apps(.wabi), initial, creation[4]])
        defer { fixture.remove() }
        try await wabiAdapter(fixture).checkAvailable()
        assertNoInput(try await finishedCalls(fixture))
    }

    func testWabiReadinessDoesNotIgnoreADraftBehindTheChooser() async throws {
        let creation = wabiCreationSteps()
        var initial = windows(); initial["native"] = wabiNative(draft: "Keep this draft")
        let fixture = try driver([apps(.wabi), initial, creation[4]])
        defer { fixture.remove() }
        let error = await failure { try await self.wabiAdapter(fixture).checkAvailable() }
        XCTAssertTrue(error.contains("draft"), error)
        assertNoInput(try await finishedCalls(fixture))
    }

    func testWabiRefreshesStaleNavigationWithoutRepeatingEitherClick() async throws {
        let creation = wabiCreationSteps()
        var open = creation[3]; open["native"] = wabiNative()
        var firstRefresh = activation(); firstRefresh["native"] = wabiNative(draft: nil)
        var create = creation[5]; create["native"] = wabiNative(draft: nil)
        var secondRefresh = activation()
        secondRefresh["native"] = wabiNative(url: otherWabiURL, messages: [.init(role: .assistant, text: "What can I do for you?")])
        let oldChat = snapshot(wabiWith([element("AXButton", "New chat", token: "s00000001:new")]))
        let fixture = try driver(Array(creation.prefix(3)) + [open, oldChat, firstRefresh, creation[4],
                                                               create, creation[4], secondRefresh, creation[6]])
        defer { fixture.remove() }
        let control = DesktopAppConversation(executable: fixture.executable)
        let created = try await wabiAdapter(fixture).prepare(savedURL: nil, refreshNavigation: { target, session in
            try await control.activate(target, session: session)
        })
        XCTAssertEqual(created, otherWabiURL)
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.compactMap { $0.arguments["element_token"] as? String }, ["s00000001:new", "s00000002:new"])
        XCTAssertEqual(calls.filter { $0.tool == "bring_to_front" }.count, 2)
        XCTAssertFalse(calls.contains { ["type_text", "press_key"].contains($0.tool) })
    }

    func testWabiChooserTargetsAIOptionWhenToolbarRemainsAccessible() async throws {
        for retainedDraft: String? in [nil, ""] {
            var steps = wabiCreationSteps()
            steps[3]["native"] = wabiNative(draft: retainedDraft)
            var picker = steps[4]["result"] as! [String: Any]
            var elements = picker["elements"] as! [[String: Any]]
            elements.insert(element("AXButton", "New chat", token: "s00000002:toolbar"), at: 0)
            if retainedDraft != nil { elements.insert(element("AXTextArea", "Message", value: "Say something…"), at: 1) }
            picker["elements"] = elements
            steps[4]["result"] = picker
            let fixture = try driver(steps)
            defer { fixture.remove() }
            let created = try await wabiAdapter(fixture).prepare(savedURL: nil)
            XCTAssertEqual(created, otherWabiURL)
            let calls = try await finishedCalls(fixture)
            XCTAssertEqual(calls.filter { $0.tool == "click" }.compactMap { $0.arguments["element_token"] as? String }, ["s00000001:new", "s00000002:new"])
            XCTAssertFalse(calls.contains { $0.tool == "type_text" })
        }
    }

    func testWabiAmbiguousAIChoicesNeverSelectAContactOrCreateAChat() async throws {
        var steps = wabiCreationSteps()
        var picker = steps[4]["result"] as! [String: Any]
        var elements = picker["elements"] as! [[String: Any]]
        var duplicate = element("AXButton", "New chat", token: "s00000002:duplicate")
        duplicate["parent_index"] = 80
        elements.append(duplicate)
        picker["elements"] = elements; steps[4]["result"] = picker
        steps = Array(steps.prefix(5))
        let fixture = try driver(steps)
        defer { fixture.remove() }
        let problem = await failure { try await self.wabiAdapter(fixture).prepare(savedURL: nil).absoluteString }
        XCTAssertTrue(problem.contains("AI chat choice"))
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1, "Only opening the chooser is allowed")
        XCTAssertFalse(calls.contains { $0.tool == "type_text" })
    }

    func testWabiMissingAmbiguousSavedChatAndDraftNeverCreateReplacement() async throws {
        for mode in ["missing", "ambiguous", "draft"] {
            let links = mode == "missing" ? [] : [["url": otherWabiURL.absoluteString, "label": "Same title"]]
            var initial = windows(); initial["native"] = wabiNative(draft: mode == "draft" ? "Keep this" : "", links: links)
            let rows = mode == "ambiguous" ? [element("AXLink", "Same title"), element("AXLink", "Same title")] : []
            let fixture = try driver([apps(.wabi), initial, snapshot(wabiWith(rows, draft: mode == "draft" ? "Keep this" : ""))])
            defer { fixture.remove() }
            let error = await failure { try await self.wabiAdapter(fixture).prepare(savedURL: self.otherWabiURL).absoluteString }
            XCTAssertFalse(error.isEmpty)
            assertNoInput(try await finishedCalls(fixture))
        }
    }

    func testWabiChangedThreadOrHistoryAfterTypingPreservesDraftWithoutSend() async throws {
        for changedHistory in [false, true] {
            var initial = windows(); initial["native"] = wabiNative()
            var typed = step("type_text", [:])
            typed["native"] = wabiNative(url: changedHistory ? wabiURL : otherWabiURL, draft: prompt,
                                         messages: changedHistory ? [.init(role: .user, text: "Another outgoing question")] : [])
            let fixture = try driver([apps(.wabi), initial, capturedNavigation(wabi()), typed, snapshot(wabi(draft: prompt))])
            defer { fixture.remove() }
            let error = await failure { try await self.wabiAdapter(fixture).reply(self.prompt, in: self.wabiURL) }
            XCTAssertTrue(error.contains("Send was not pressed"), error)
            let calls = try await finishedCalls(fixture)
            XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
            XCTAssertFalse(calls.contains { $0.tool == "click" })
        }
    }

    func testWabiCreatesDedicatedChatWithoutReadingUnrelatedHistory() async throws {
        let fixture = try driver(wabiCreationSteps())
        defer { fixture.remove() }
        let created = try await wabiAdapter(fixture, unreadableHistory: true).prepare(savedURL: nil)
        XCTAssertEqual(created, otherWabiURL)
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 2, "Only the New chat chooser and AI chat creation are allowed")
        XCTAssertFalse(calls.contains { ["type_text", "press_key"].contains($0.tool) })
        assertBackgroundTargets(calls)
    }

    func testGrokBotDiscoveryWaitsForColdStartSnapshotWithoutInput() async throws {
        var loading = grok()
        loading["degraded"] = true
        let fixture = try driver([apps(.grokBot), windows(), snapshot(loading), snapshot(grok())])
        defer { fixture.remove() }
        let names = try await adapter(fixture).availableGrokBots()
        XCTAssertFalse(names.isEmpty)
        assertNoInput(try await finishedCalls(fixture))
    }

    func testWabiOnboardingDoesNotRequireReadableHistoricalMessages() async throws {
        var initial = windows(); initial["native"] = wabiNative()
        let fixture = try driver([apps(.wabi), initial, snapshot(wabiWith([element("AXButton", "New chat")]))])
        defer { fixture.remove() }
        try await wabiAdapter(fixture, unreadableHistory: true).checkAvailable()
        assertNoInput(try await finishedCalls(fixture))
    }

    func testWabiOnboardingInitializesColdAccessibilityBeforeReadingAddress() async throws {
        var initial = windows(); initial["native"] = wabiNative()
        let fixture = try driver([apps(.wabi), initial, snapshot(wabiWith([element("AXButton", "New chat")]))])
        defer { fixture.remove() }
        let file = fixture.directory.appendingPathComponent("native.json")
        let adapter = WabiAppConversation(executable: fixture.executable, timing: .init(pollInterval: .milliseconds(5), callTimeout: 3)) { target, purpose in
            guard target.pid == 4242, target.window == 101 else { throw CocoaError(.fileReadUnknown) }
            guard try fixture.calls().contains(where: { $0.tool == "get_window_state" }) else {
                throw WabiObservationError.transient("Wabi's accessibility content has not been initialized")
            }
            return try JSONDecoder().decode(WabiAppObservation.self, from: Data(contentsOf: file))
        }
        try await adapter.checkAvailable()
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "get_window_state" }.count, 1)
        assertNoInput(calls)
    }

    func testWabiOnboardingWaitsForColdStartAddressWithoutInput() async throws {
        var initial = windows(); initial["native"] = wabiNative()
        let fixture = try driver([apps(.wabi), initial, snapshot(wabiWith([element("AXButton", "New chat")]))])
        defer { fixture.remove() }
        let file = fixture.directory.appendingPathComponent("native.json")
        let reads = WabiStartupReads()
        let adapter = WabiAppConversation(executable: fixture.executable, timing: .init(pollInterval: .milliseconds(5), callTimeout: 3)) { target, purpose in
            guard target.pid == 4242, target.window == 101 else { throw CocoaError(.fileReadUnknown) }
            let url = reads.nextURL()
            _ = try WabiThread.verifiedURL(url, currentURL: url, webAreaCount: url == nil ? 0 : 1, composerCount: 0, purpose: purpose)
            return try JSONDecoder().decode(WabiAppObservation.self, from: Data(contentsOf: file))
        }
        try await adapter.checkAvailable()
        XCTAssertGreaterThanOrEqual(reads.count, 5, "The first three incomplete reads must not require another Connect")
        assertNoInput(try await finishedCalls(fixture))
    }

    private final class WabiStartupReads: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        var count: Int { lock.withLock { reads } }
        func nextURL() -> URL? {
            lock.withLock {
                reads += 1
                if reads == 1 { return nil }
                if reads <= 3 { return URL(string: "wabi://app/") }
                return URL(string: "wabi://app/threads/aaaaaaaaaaaaaaaaaaaaaaaa")
            }
        }
    }

    func testWabiLoadingAddressDoesNotRelaxConversationOrAmbiguityGuards() throws {
        let valid = URL(string: "wabi://app/threads/aaaaaaaaaaaaaaaaaaaaaaaa")!
        for purpose in [WabiReadPurpose.readiness, .conversation] {
            XCTAssertThrowsError(try WabiThread.verifiedURL(valid, currentURL: valid, webAreaCount: 2, composerCount: 0, purpose: purpose)) { error in
                XCTAssertFalse(error is WabiObservationError)
            }
            XCTAssertThrowsError(try WabiThread.verifiedURL(valid, currentURL: valid, webAreaCount: 1, composerCount: 2, purpose: purpose))
            XCTAssertThrowsError(try WabiThread.verifiedURL(valid, currentURL: self.otherWabiURL, webAreaCount: 1, composerCount: 0, purpose: purpose))
            XCTAssertThrowsError(try WabiThread.verifiedURL(URL(string: "https://example.com"), currentURL: valid, webAreaCount: 1, composerCount: 0, purpose: purpose))
        }
        XCTAssertThrowsError(try WabiThread.verifiedURL(nil, currentURL: nil, webAreaCount: 0, composerCount: 0, purpose: .conversation)) { error in
            XCTAssertFalse(error is WabiObservationError, "Only read-only readiness may wait for an uninitialized address")
        }
    }

    func testWabiReplyStillRequiresReadableHistoryAndConnectionPreservesDrafts() async throws {
        var initial = windows(); initial["native"] = wabiNative()
        let fixture = try driver([apps(.wabi), initial])
        defer { fixture.remove() }
        let error = await failure { try await self.wabiAdapter(fixture, unreadableHistory: true).reply(self.prompt, in: self.wabiURL) }
        XCTAssertTrue(error.contains("Historical layout unavailable"), error)
        assertNoInput(try await finishedCalls(fixture))

        for draft in ["Keep my draft", "\n"] {
            var initial = windows(); initial["native"] = wabiNative(draft: draft)
            let fixture = try driver([apps(.wabi), initial, snapshot(wabiWith([element("AXButton", "New chat")]))])
            defer { fixture.remove() }
            let error = await failure { try await self.wabiAdapter(fixture, unreadableHistory: true).checkAvailable() }
            XCTAssertTrue(error.contains("unsent draft"), error)
            assertNoInput(try await finishedCalls(fixture))
        }
    }

    func testWabiReadinessStillRejectsMissingOrAmbiguousNewChatControls() async throws {
        for controls in [[], [element("AXButton", "New chat"), element("AXButton", "New chat")]] {
            var initial = windows(); initial["native"] = wabiNative()
            let fixture = try driver([apps(.wabi), initial, snapshot(wabiWith(controls))])
            defer { fixture.remove() }
            let error = await failure { try await self.wabiAdapter(fixture, unreadableHistory: true).checkAvailable() }
            XCTAssertTrue(error.contains("New chat control is unavailable or ambiguous"), error)
            assertNoInput(try await finishedCalls(fixture))
        }
    }

    func testWabiConnectionCheckIsReadOnlyAndGenericSendIsUnavailable() async throws {
        var initial = windows(); initial["native"] = wabiNative()
        let fixture = try driver([apps(.wabi), initial, snapshot(wabiWith([element("AXButton", "New chat")]))])
        defer { fixture.remove() }
        try await wabiAdapter(fixture).checkAvailable()
        assertNoInput(try await finishedCalls(fixture))
        let generic = try driver([])
        defer { generic.remove() }
        let error = await failure { try await self.adapter(generic).reply(self.prompt, app: .wabi, binding: .init(name: "Wabi")) }
        XCTAssertTrue(error.contains("dedicated chat"), error)
        XCTAssertTrue(try generic.calls().isEmpty)
    }

    func testWabiSavesCreatedDestinationBeforeTypingAndKeepsItAfterCancellation() async throws {
        var ready = windows(); ready["native"] = wabiNative(url: otherWabiURL)
        var blocked = step("type_text", [:]); blocked["wait_for_release"] = true
        let fixture = try driver(wabiCreationSteps() + [apps(.wabi), ready, capturedNavigation(wabi()), blocked])
        defer { fixture.remove() }
        let file = fixture.directory.appendingPathComponent("state.json")
        let owner = UUID()
        let session = WebAgentSession(provider: .wabi, storageURL: file, fixture: false, museApp: .shared, desktopApps: .demo, wabiApp: wabiAdapter(fixture), desktopDriver: try readinessDriver(fixture, app: .wabi))
        session.setEnabled(true)
        session.updateState { $0.desktopConversation = .init(name: "Wabi") }
        let sending = Task { await session.send(prompt, comparisonID: owner) }
        try await waitForCall("type_text", in: fixture)
        let saved = try JSONDecoder().decode(WebWorkspaceState.self, from: Data(contentsOf: file))
        XCTAssertEqual(saved.conversationURLs[owner.uuidString], otherWabiURL)
        XCTAssertEqual(saved.attempts.first?.conversationURL, otherWabiURL)
        XCTAssertEqual(saved.attempts.first?.status, .attempting)
        session.cancelNativeRequest()
        let attempt = await sending.value
        XCTAssertEqual(attempt?.status, .uncertain)
        session.beginShutdown()
        let reopened = WebAgentSession(provider: .wabi, storageURL: file, fixture: true)
        defer { reopened.beginShutdown() }
        XCTAssertEqual(reopened.state.conversationURLs[owner.uuidString], otherWabiURL)
        XCTAssertEqual(reopened.state.attempts.first?.conversationURL, otherWabiURL)
        let retry = await reopened.send("Another prompt", comparisonID: owner)
        XCTAssertNil(retry)
        let calls = try await finishedCalls(fixture, cleanupCount: 2)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 2, "Only the two New chat navigation controls were pressed")
        XCTAssertFalse(calls.contains { $0.arguments["element_token"] as? String == "s00000001:send" })
    }

    func testWabiReplyStaysInItsOriginalComparisonAfterBrowsingAway() async throws {
        let owner = UUID(), other = UUID()
        let welcome = WabiAppMessage(role: .assistant, text: "What can I do for you?")
        var ready = windows(); ready["native"] = wabiNative(url: otherWabiURL, messages: [welcome])
        var typed = step("type_text", [:]); typed["native"] = wabiNative(url: otherWabiURL, draft: prompt, messages: [welcome])
        var sent = step("click", [:]); sent["native"] = wabiNative(url: otherWabiURL, messages: [welcome, .init(role: .user, text: prompt)])
        var late = snapshot(wabi(reply: "Late answer"), repeating: true)
        late["native"] = wabiNative(url: otherWabiURL, messages: [welcome, .init(role: .user, text: prompt), .init(role: .assistant, text: "Late answer")])
        late["wait_for_release"] = true
        let fixture = try driver(wabiCreationSteps() + [apps(.wabi), ready, capturedNavigation(wabi()), typed,
            snapshot(wabi(draft: prompt)), sent, snapshot(wabi()), late])
        defer { fixture.remove() }
        let file = fixture.directory.appendingPathComponent("state.json")
        let session = WebAgentSession(provider: .wabi, storageURL: file, fixture: false, museApp: .shared, desktopApps: .demo,
                                      wabiApp: wabiAdapter(fixture), desktopDriver: try readinessDriver(fixture, app: .wabi))
        session.setEnabled(true)
        session.updateState { $0.desktopConversation = .init(name: "Wabi") }
        let confirmed = expectation(description: "The outgoing message was observed")
        let sending = Task { await session.send(prompt, comparisonID: owner, onConfirmedSubmission: { confirmed.fulfill() }) }
        await fulfillment(of: [confirmed], timeout: 5)
        XCTAssertTrue(session.isSending)
        session.updateState { $0.comparisonID = other }
        session.updateState { $0.draft = "Different comparison draft" }
        try Data().write(to: fixture.directory.appendingPathComponent("release"))
        let attempt = await sending.value
        XCTAssertEqual(attempt?.status, .observed)
        XCTAssertEqual(session.state.comparisonID, other)
        XCTAssertEqual(session.state.draft, "Different comparison draft")
        XCTAssertEqual(session.state.localConversations[owner.uuidString]?.map(\.text), [prompt, "Late answer"])
        XCTAssertNil(session.state.localConversations[other.uuidString])
        let persisted = try JSONDecoder().decode(WebWorkspaceState.self, from: Data(contentsOf: file))
        XCTAssertEqual(persisted.localConversations[owner.uuidString]?.map(\.text), [prompt, "Late answer"])
        XCTAssertEqual(persisted.localDrafts[other.uuidString], "Different comparison draft")
        let calls = try await finishedCalls(fixture, cleanupCount: 2)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        XCTAssertEqual(calls.filter { $0.arguments["element_token"] as? String == "s00000001:send" }.count, 1)
        session.beginShutdown()
    }

    private func wabiCreationSteps() -> [[String: Any]] {
        var initial = windows(); initial["native"] = wabiNative()
        let navigation = [element("AXButton", "New chat", token: "s00000001:new")]
        var open = step("click", [:], arguments: ["element_token": "s00000001:new"])
        open["native"] = wabiNative(draft: nil)
        var choices = element("AXList", ""); choices["element_index"] = 80
        var aiChoice = element("AXButton", "New chat", token: "s00000002:new"); aiChoice["parent_index"] = 80
        let chooser = [element("AXHeading", "New chat"), element("AXHeading", "Contacts on Wabi"),
                       element("AXTextField", "Name, username, or phone number"), choices, aiChoice,
                       element("AXButton", "Eugenia Kuyda @eugenia")]
        var create = step("click", [:], arguments: ["element_token": "s00000002:new"])
        create["native"] = wabiNative(url: otherWabiURL, messages: [.init(role: .assistant, text: "What can I do for you?")])
        var blank = wabi(); var elements = blank["elements"] as! [[String: Any]]
        elements[0]["label"] = "New chat"; elements.insert(contentsOf: [element("AXStaticText", "What can I do for you?"), element("AXPopUpButton", "Add reaction"), element("AXStaticText", "5:13 PM")], at: 3)
        blank["elements"] = elements; blank["returned_element_count"] = elements.count; blank["total_element_count"] = elements.count
        return [apps(.wabi), initial, snapshot(wabiWith(navigation)), open, snapshot(["elements": chooser]), create, snapshot(blank)]
    }

    private var wabiURL: URL { URL(string: "wabi://app/threads/aaaaaaaaaaaaaaaaaaaaaaaa")! }
    private var otherWabiURL: URL { URL(string: "wabi://app/threads/bbbbbbbbbbbbbbbbbbbbbbbb")! }
    private func wabiNative(url: URL? = nil, draft: String? = "", links: [[String: String]] = [], messages: [WabiAppMessage] = [], focused: Bool = true) -> [String: Any] {
        var result: [String: Any] = ["url": (url ?? wabiURL).absoluteString, "links": links, "composerFocused": focused, "messages": messages.map { ["role": $0.role.rawValue, "text": $0.text] }]
        if let draft { result["draft"] = draft }
        return result
    }
    private func wabiWith(_ additions: [[String: Any]], draft: String = "") -> [String: Any] {
        var state = wabi(draft: draft)
        let body = additions + (state["elements"] as! [[String: Any]])
        state["elements"] = body; state["returned_element_count"] = body.count; state["total_element_count"] = body.count
        return state
    }
    private func wabiAdapter(_ fixture: DriverFixture, transientAfterSend: Bool = false, neverSettlesAfterSend: Bool = false, unreadableHistory: Bool = false) -> WabiAppConversation {
        let fault = MuseReadFault()
        let file = fixture.directory.appendingPathComponent("native.json")
        return WabiAppConversation(executable: fixture.executable, timing: .init(pollInterval: .milliseconds(5), stableDuration: .milliseconds(60), replyTimeout: .seconds(2), callTimeout: 3)) { target, purpose in
            guard target.pid == 4242, target.window == 101 else { throw CocoaError(.fileReadUnknown) }
            let observation = try JSONDecoder().decode(WabiAppObservation.self, from: Data(contentsOf: file))
            if unreadableHistory, purpose == .conversation, observation.url == URL(string: "wabi://app/threads/aaaaaaaaaaaaaaaaaaaaaaaa") {
                throw WabiObservationError.transient("Historical layout unavailable")
            }
            if purpose == .conversation, observation.messages.contains(where: { $0.role == .user }), neverSettlesAfterSend || (transientAfterSend && fault.shouldFail()) {
                throw WabiObservationError.transient("Wabi's messages are still updating. No sender or reply was inferred.")
            }
            return WabiAppObservation(url: observation.url, draft: observation.draft, links: observation.links,
                                      messages: purpose == .readiness ? [] : observation.messages,
                                      composerFocused: observation.composerFocused)
        }
    }

    func testDuplicateRunningCopiesAreRejectedInEitherEnumerationOrder() async throws {
        for pids in [[4242, 4343], [4343, 4242]] {
            let fixture = try driver([step("list_apps", ["apps": pids.map {
                ["bundle_id": DesktopAppProvider.grokBot.bundleID, "pid": $0, "running": true] as [String: Any]
            }])])
            defer { fixture.remove() }
            let error = await failure { try await self.adapter(fixture).reply(self.prompt, app: .grokBot, binding: self.binding) }
            XCTAssertTrue(error.contains("Quit extra copies"), error)
            let calls = try await finishedCalls(fixture)
            XCTAssertTrue(calls.allSatisfy { ["list_apps", "end_session"].contains($0.tool) }, "Ambiguity must stop before inspecting any account window")
        }
    }

    func testAmbiguousMainWindowsPreventAllInput() async throws {
        let fixture = try driver([apps(), step("list_windows", ["windows": [
            ["window_id": 101, "title": "First chat", "bounds": ["width": 800, "height": 600]],
            ["window_id": 102, "title": "Second chat", "bounds": ["width": 800, "height": 600]]
        ]])])
        defer { fixture.remove() }
        let error = await failure { try await self.adapter(fixture).reply(self.prompt, app: .grokBot, binding: self.binding) }
        XCTAssertTrue(error.contains("one main Grok Bot window"), error)
        assertNoInput(try await finishedCalls(fixture))
    }

    func testGrokUsesCaptureBoundPixelTypingInsteadOfRefusedElectronAXInput() async throws {
        let fixture = try driver(sendSteps() + [snapshot(grok(reply: "Answer", token: "s00000003"), repeating: true)])
        defer { fixture.remove() }
        let answer = try await adapter(fixture).reply(prompt, app: .grokBot, binding: binding)
        XCTAssertEqual(answer, "Answer")
        let calls = try await finishedCalls(fixture)
        let input = try XCTUnwrap(calls.first { $0.tool == "type_text" })
        XCTAssertNil(input.arguments["element_token"])
        XCTAssertEqual(input.arguments["x"] as? Int, 540)
        XCTAssertEqual(input.arguments["y"] as? Int, 780)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1)
        assertBackgroundTargets(calls)
    }

    func testGrokMissingHistoryStopsBeforeTypingInsteadOfCreditingAnOldReply() async throws {
        var empty = grok()
        var elements = try XCTUnwrap(empty["elements"] as? [[String: Any]])
        elements.removeAll { $0["role"] as? String == "AXStaticText" }
        empty["elements"] = elements
        empty["returned_element_count"] = elements.count
        empty["total_element_count"] = elements.count
        let fixture = try driver([apps(), windows(), snapshot(empty), step("type_text", [:]),
                                  snapshot(grok(draft: prompt, token: "s00000002")), step("click", [:]),
                                  snapshot(grok(reply: "Old restored answer", token: "s00000003"), repeating: true)])
        defer { fixture.remove() }
        let error = await failure { try await self.adapter(fixture).reply(self.prompt, app: .grokBot, binding: self.binding) }
        XCTAssertTrue(error.contains("still loading"), error)
        assertNoInput(try await finishedCalls(fixture))
    }

    func testGrokVirtualizedOlderHistoryCannotBlockOrClaimTheNewReply() async throws {
        func withOlderMessages(_ state: [String: Any], prompts: [String]) throws -> [String: Any] {
            var result = state
            var elements = try XCTUnwrap(result["elements"] as? [[String: Any]])
            let firstMessage = try XCTUnwrap(elements.firstIndex { $0["role"] as? String == "AXStaticText" })
            let older = prompts.flatMap { text in [element("AXStaticText", "You"), element("AXStaticText", text),
                                                   element("AXStaticText", "Fixture Bot"), element("AXStaticText", "Older answer")] }
            elements.insert(contentsOf: older, at: firstMessage)
            result["elements"] = elements
            result["returned_element_count"] = elements.count
            result["total_element_count"] = elements.count
            return result
        }
        let initial = try withOlderMessages(grok(reply: "Previous visible answer"), prompts: ["Older question"])
        let typed = grok(draft: prompt, reply: "Previous visible answer", token: "s00000002", focused: false)
        let restoredOlder = try withOlderMessages(grok(reply: "Previous visible answer", token: "s00000003"), prompts: [prompt, prompt])
        let fresh = grok(reply: "Fresh anchored answer", token: "s00000004", previousReply: "Previous visible answer")
        let fixture = try driver([apps(), windows(), snapshot(initial), step("type_text", [:]), snapshot(typed),
                                  step("click", [:]), snapshot(restoredOlder), snapshot(fresh, repeating: true)])
        defer { fixture.remove() }
        let answer = try await adapter(fixture).reply(prompt, app: .grokBot, binding: binding)
        XCTAssertEqual(answer, "Fresh anchored answer", "Loaded older occurrences must never be credited to the new request")
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1)
        assertBackgroundTargets(calls)
    }

    func testGrokFinalConfirmedDraftCanSubmitWithoutKeyboardFocus() async throws {
        let fixture = try driver([
            apps(), windows(), snapshot(grok()), step("type_text", [:]),
            snapshot(grok(draft: prompt, token: "s00000002", focused: false)),
            step("click", [:]), snapshot(grok(reply: "Verified final draft", token: "s00000003"), repeating: true)
        ])
        defer { fixture.remove() }
        let answer = try await adapter(fixture).reply(prompt, app: .grokBot, binding: binding)
        XCTAssertEqual(answer, "Verified final draft")
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1, "Never replay a draft whose input landed")
        let clicks = calls.filter { $0.tool == "click" }
        XCTAssertEqual(clicks.count, 1, "Submit the verified draft once")
        XCTAssertEqual(clicks.first?.arguments["element_token"] as? String, "s00000002:send")
        assertBackgroundTargets(calls)
    }

    func testGrokRefreshesStaleEditorWithoutRetypingBeforeSubmit() async throws {
        let fixture = try driver([
            apps(), windows(), snapshot(grok()), step("type_text", [:], arguments: ["text": prompt]),
            snapshot(grok()), activation(),
            snapshot(grok(draft: prompt, token: "s00000002")), step("click", [:]),
            snapshot(grok(reply: "Fresh answer", token: "s00000003"), repeating: true)
        ])
        defer { fixture.remove() }
        let answer = try await adapter(fixture, delivery: .foreground).reply(prompt, app: .grokBot, binding: binding)
        XCTAssertEqual(answer, "Fresh answer")
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        XCTAssertEqual(calls.filter { $0.tool == "bring_to_front" }.count, 1)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1)
    }

    func testNativeEditorFocusAllowsBackgroundWrapperButRefusesConflictingOrLostFocus() async throws {
        let multiline = prompt + "\nNext chunk"
        for scene in ["background wrapper", "different editor", "lost focus"] {
            var prepared = grok(draft: prompt, token: "s00000002")
            var native = prepared["_grok_native"] as! [String: Any]
            native["applicationFocusMatches"] = false
            native["applicationRole"] = scene == "different editor" ? "AXTextArea" : "AXWebArea"
            native["editorFocused"] = scene != "lost focus"
            native.removeValue(forKey: "composerFocused")
            prepared["_grok_native"] = native
            var plan = [apps(), windows(), snapshot(grok()), step("type_text", [:]), snapshot(prepared)]
            if scene == "background wrapper" {
                plan += [snapshot(prepared), step("press_key", [:]), snapshot(grok(draft: prompt + "\n")),
                         snapshot(grok(draft: prompt + "\n")), step("type_text", [:]), snapshot(grok(draft: multiline, token: "s00000003")),
                         step("click", [:]), snapshot(grok(reply: "Focus confirmed", token: "s00000004", outgoingPrompt: multiline), repeating: true)]
            }
            let fixture = try driver(plan)
            defer { fixture.remove() }
            if scene == "background wrapper" {
                let answer = try await adapter(fixture).reply(multiline, app: .grokBot, binding: binding)
                XCTAssertEqual(answer, "Focus confirmed")
            } else {
                let error = await failure { try await self.adapter(fixture).reply(multiline, app: .grokBot, binding: self.binding) }
                XCTAssertTrue(error.contains("Send was not clicked"), scene)
            }
            let calls = try await finishedCalls(fixture)
            XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, scene == "background wrapper" ? 2 : 1)
            XCTAssertEqual(calls.filter { $0.tool == "press_key" }.count, scene == "background wrapper" ? 1 : 0)
            XCTAssertEqual(calls.filter { $0.tool == "click" }.count, scene == "background wrapper" ? 1 : 0)
        }
    }

    func testGrokMultilineChunksUseShiftReturnWithoutRefocusingAndKeepNativeNewlinesExact() async throws {
        let first = String(repeating: "😀", count: 300)
        let text = first + "\nNext"
        let chunk = String(repeating: "😀", count: 256)
        var observed = grok(reply: "Complete", outgoingPrompt: text)
        var elements = observed["elements"] as! [[String: Any]]
        let outgoing = try XCTUnwrap(elements.firstIndex { $0["label"] as? String == text })
        elements.replaceSubrange(outgoing...outgoing, with: [element("AXStaticText", first), element("AXStaticText", "Next")])
        observed["elements"] = elements
        observed["returned_element_count"] = elements.count
        observed["total_element_count"] = elements.count
        let fixture = try driver([
            apps(), windows(), snapshot(grok()),
            step("type_text", [:], arguments: ["text": chunk]), snapshot(grok(draft: chunk)),
            snapshot(grok(draft: chunk)), step("type_text", [:], arguments: ["text": String(repeating: "😀", count: 44)]), snapshot(grok(draft: first)),
            snapshot(grok(draft: first)), step("press_key", [:], arguments: ["key": "return"]), snapshot(grok(draft: first + "\n")),
            snapshot(grok(draft: first + "\n")), step("type_text", [:], arguments: ["text": "Next"]), snapshot(grok(draft: text)),
            step("click", [:]), snapshot(observed, repeating: true)
        ])
        defer { fixture.remove() }
        let answer = try await adapter(fixture).reply(text, app: .grokBot, binding: binding)
        XCTAssertEqual(answer, "Complete")
        let calls = try await finishedCalls(fixture)
        let typing = calls.filter { $0.tool == "type_text" }
        XCTAssertEqual(typing.compactMap { ($0.arguments["text"] as? String)?.count }, [256, 44, 4])
        XCTAssertTrue(typing.allSatisfy { $0.arguments["element_token"] == nil })
        XCTAssertNotNil(typing.first?.arguments["x"])
        XCTAssertTrue(typing.dropFirst().allSatisfy { $0.arguments["x"] == nil })
        let newline = try XCTUnwrap(calls.first { $0.tool == "press_key" })
        XCTAssertEqual(newline.arguments["modifiers"] as? [String], ["shift"])
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1, "Only the final Send may be clicked")
        for path in calls.compactMap({ $0.arguments["screenshot_out_file"] as? String }) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path))
        }
    }

    func testGrokInvalidCaptureOrLostFocusPreservesTextWithoutSubmitting() async throws {
        var invalid = snapshot(grok()); invalid["capture"] = "missing"
        let noCapture = try driver([apps(), windows(), invalid])
        defer { noCapture.remove() }
        _ = await failure { try await self.adapter(noCapture).reply(self.prompt, app: .grokBot, binding: self.binding) }
        assertNoInput(try await finishedCalls(noCapture))
        let lostFocus = try driver([apps(), windows(), snapshot(grok()), step("type_text", [:]), snapshot(grok(draft: "First", focused: false))])
        defer { lostFocus.remove() }
        _ = await failure { try await self.adapter(lostFocus).reply("First\nSecond", app: .grokBot, binding: self.binding) }
        let calls = try await finishedCalls(lostFocus)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        XCTAssertFalse(calls.contains { ["press_key", "click"].contains($0.tool) })
    }

    func testGrokBotListOrHistoryChangeAfterTypingNeverSubmits() async throws {
        for changed in [grok(draft: prompt, bots: ["Fixture Bot", "Fixture Bot"], focused: false),
                        grok(draft: prompt, reply: "An unrelated message arrived", focused: false)] {
            let fixture = try driver([apps(), windows(), snapshot(grok()), step("type_text", [:]), snapshot(changed)])
            defer { fixture.remove() }
            _ = await failure { try await self.adapter(fixture).reply(self.prompt, app: .grokBot, binding: self.binding) }
            let calls = try await finishedCalls(fixture)
            XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
            XCTAssertFalse(calls.contains { $0.tool == "click" || $0.tool == "press_key" })
        }
    }

    func testGrokEmptyEditorNewlineIsRecognizedButUnknownPlaceholderIsRefused() async throws {
        for value in ["", "\n", "Unknown composer value"] {
            var initial = grok()
            var elements = initial["elements"] as! [[String: Any]]
            let index = try XCTUnwrap(elements.firstIndex { $0["role"] as? String == "AXTextArea" })
            elements[index]["value"] = value; initial["elements"] = elements
            let plan = [apps(), windows(), snapshot(initial)] + (value == "Unknown composer value" ? [] : Array(sendSteps().dropFirst(3)) + [snapshot(grok(reply: "Answer"), repeating: true)])
            let fixture = try driver(plan)
            defer { fixture.remove() }
            if value == "Unknown composer value" {
                _ = await failure { try await self.adapter(fixture).reply(self.prompt, app: .grokBot, binding: self.binding) }
                assertNoInput(try await finishedCalls(fixture))
            } else {
                let answer = try await adapter(fixture).reply(prompt, app: .grokBot, binding: binding)
                XCTAssertEqual(answer, "Answer")
                let calls = try await finishedCalls(fixture)
                XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
                XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1)
            }
        }
    }

    func testGrokLiteralPlaceholderIsVerifiedAsTextWithExactNativeDraft() async throws {
        let text = "Message Fixture Bot"
        let fixture = try driver([apps(), windows(), snapshot(grok()), step("type_text", [:], arguments: ["text": text]),
                                  snapshot(grok(draft: text)), step("click", [:]),
                                  snapshot(grok(reply: "Literal label accepted", outgoingPrompt: text), repeating: true)])
        defer { fixture.remove() }
        let answer = try await adapter(fixture).reply(text, app: .grokBot, binding: binding)
        XCTAssertEqual(answer, "Literal label accepted")
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1)
    }

    func testGrokUnreadBadgeAfterSendKeepsTheChosenBotAndNeverResends() async throws {
        var replied = grok(reply: "Answer")
        var elements = replied["elements"] as! [[String: Any]]
        let index = try XCTUnwrap(elements.firstIndex { $0["element_token"] as? String == "s00000001:bot0" })
        elements[index]["label"] = "Fixture Bot, Main Bot, Unread activity"
        elements[index].removeValue(forKey: "parent_index")
        replied["elements"] = elements
        let fixture = try driver(sendSteps() + [snapshot(replied, repeating: true)])
        defer { fixture.remove() }
        let answer = try await adapter(fixture).reply(prompt, app: .grokBot, binding: binding)
        XCTAssertEqual(answer, "Answer")
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1)
    }

    func testGrokTransientBotListWhileReplyingWaitsForStableIdentityWithoutResending() async throws {
        var busy = grok(generating: true)
        var elements = busy["elements"] as! [[String: Any]]
        let bot = try XCTUnwrap(elements.firstIndex { $0["element_token"] as? String == "s00000001:bot0" })
        elements[bot]["enabled"] = false; busy["elements"] = elements
        let ambiguous = grok(reply: "Unverified early answer", bots: ["Fixture Bot", "Fixture Bot"])
        let fixture = try driver(sendSteps() + [snapshot(busy), snapshot(ambiguous), snapshot(grok(reply: "Verified final answer"), repeating: true)])
        defer { fixture.remove() }
        let answer = try await adapter(fixture).reply(prompt, app: .grokBot, binding: binding)
        XCTAssertEqual(answer, "Verified final answer")
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1)
    }

    func testGrokPersistentlyAmbiguousBotAfterSendCannotClaimAReplyOrResend() async throws {
        let fixture = try driver(sendSteps() + [snapshot(grok(reply: "Unverified answer", bots: ["Fixture Bot", "Fixture Bot"]), repeating: true)])
        defer { fixture.remove() }
        let error = await failure { try await self.adapter(fixture, replyTimeout: .milliseconds(200)).reply(self.prompt, app: .grokBot, binding: self.binding) }
        XCTAssertTrue(error.contains("nothing will be resent automatically"), error)
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1)
    }

    func testGrokNavigationAndSubmitControlCharactersAreRejectedBeforeAnyDriverCall() async throws {
        for text in ["A\rB", "A\tB", "A\u{1b}B", "A\u{7f}B", "\n"] {
            let fixture = try driver([])
            defer { fixture.remove() }
            _ = await failure { try await self.adapter(fixture).reply(text, app: .grokBot, binding: self.binding) }
            XCTAssertTrue(try fixture.calls().isEmpty)
        }
    }

    func testPartialOrChangedDraftNeverClicksSendOrRetriesTyping() async throws {
        for draft in ["Fixture", "Fixture prompt plus someone else's edit", "", prompt + "\n"] {
            let fixture = try driver([
                apps(), windows(), snapshot(grok()),
                step("type_text", ["effect": "partial", "delivered_chars": 7]),
                snapshot(grok(draft: draft, token: "s00000002"), repeating: draft.isEmpty)
            ])
            defer { fixture.remove() }
            let error = await failure { try await self.adapter(fixture).reply(self.prompt, app: .grokBot, binding: self.binding) }
            XCTAssertTrue(error.contains("prepared draft"), error)
            let calls = try await finishedCalls(fixture)
            XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
            XCTAssertFalse(calls.contains { $0.tool == "click" })
            assertBackgroundTargets(calls)
        }
    }

    func testExternalDraftAndMissingBotPreventAllInput() async throws {
        for (state, reason) in [(grok(draft: "Keep this external draft"), "unsent draft"),
                                (grok(name: "Other Bot"), "missing")] {
            let fixture = try driver([apps(), windows(), snapshot(state)])
            defer { fixture.remove() }
            let error = await failure { try await self.adapter(fixture).reply(self.prompt, app: .grokBot, binding: self.binding) }
            XCTAssertTrue(error.contains(reason), error)
            assertNoInput(try await finishedCalls(fixture))
        }
    }

    func testConversationSwitchAfterTypingPreservesDraftAndNeverSubmits() async throws {
        let fixture = try driver([
            apps(), windows(), snapshot(grok()), step("type_text", ["effect": "unverifiable"]),
            snapshot(grok(draft: prompt, name: "Other Bot", token: "s00000002"))
        ])
        defer { fixture.remove() }
        let error = await failure { try await self.adapter(fixture).reply(self.prompt, app: .grokBot, binding: self.binding) }
        XCTAssertTrue(error.contains("conversation changed"), error)
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        XCTAssertFalse(calls.contains { $0.tool == "click" })
    }

    func testChangedConversationWhileWaitingCannotReturnItsReply() async throws {
        let fixture = try driver(sendSteps() + [snapshot(grok(reply: "Wrong conversation's answer", name: "Other Bot", token: "s00000003"))])
        defer { fixture.remove() }
        let error = await failure { try await self.adapter(fixture).reply(self.prompt, app: .grokBot, binding: self.binding) }
        XCTAssertTrue(error.contains("conversation changed"), error)
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1)
    }

    func testDegradedAndTruncatedSnapshotsPreventAllInput() async throws {
        var partial = grok()
        partial["truncated"] = true
        partial["truncation_reason"] = "timeout"
        let invalid: [[String: Any]] = [
            ["elements": [], "degraded": true, "degraded_reason": "ax_window_unresolved"],
            ["elements": grok()["elements"]!, "total_element_count": 200, "returned_element_count": 3],
            // 0.38's equal counts describe only the nodes it visited. They do
            // not override an explicit timeout or depth/node-budget cutoff.
            partial
        ]
        for state in invalid {
            let fixture = try driver([apps(), windows(), snapshot(state)])
            defer { fixture.remove() }
            let error = await failure { try await self.adapter(fixture).reply(self.prompt, app: .grokBot, binding: self.binding) }
            XCTAssertTrue(error.contains("snapshot is incomplete"), error)
            assertNoInput(try await finishedCalls(fixture))
        }
    }

    func testMissingDisabledOrAmbiguousSendControlCannotSubmit() async throws {
        let base = grok(draft: prompt, token: "s00000002")
        let elements = try XCTUnwrap(base["elements"] as? [[String: Any]])
        let button = try XCTUnwrap(elements.last)
        var disabled = button; disabled["enabled"] = false
        let variants = [Array(elements.dropLast()), Array(elements.dropLast()) + [disabled], elements + [button]]
        for variant in variants {
            let fixture = try driver([apps(), windows(), snapshot(grok()), step("type_text", [:]), snapshot(["elements": variant, "_grok_native": ["name": "Fixture Bot", "draft": prompt, "composerFocused": true]])])
            defer { fixture.remove() }
            let error = await failure { try await self.adapter(fixture).reply(self.prompt, app: .grokBot, binding: self.binding) }
            XCTAssertTrue(error.contains("Send control"), error)
            let calls = try await finishedCalls(fixture)
            XCTAssertFalse(calls.contains { $0.tool == "click" })
        }
    }

    func testDriverRefusalNeverFallsBackToForegroundOrResends() async throws {
        for refusal: [String: Any] in [
            ["status": "refused", "refusal": ["code": "background_unavailable"]],
            ["isError": true, "message": "Permission denied"]
        ] {
            let fixture = try driver([apps(), windows(), snapshot(grok()), step("type_text", refusal)])
            defer { fixture.remove() }
            let error = await failure { try await self.adapter(fixture).reply(self.prompt, app: .grokBot, binding: self.binding) }
            XCTAssertTrue(error.contains("App control refused this request"), error)
            let calls = try await finishedCalls(fixture)
            XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
            XCTAssertFalse(calls.contains { $0.tool == "click" })
            assertBackgroundTargets(calls)
        }
    }

    func testRepeatedPromptCannotReturnOldAnswer() async throws {
        let old = grok(reply: "Old answer")
        let prepared = grok(draft: prompt, reply: "Old answer", token: "s00000002")
        let new = grok(reply: "New answer", token: "s00000004", previousReply: "Old answer")
        let fixture = try driver([
            apps(), windows(), snapshot(old), step("type_text", [:]), snapshot(prepared), step("click", [:]),
            snapshot(grok(reply: "Old answer", token: "s00000003")), snapshot(new, repeating: true)
        ])
        defer { fixture.remove() }
        let answer = try await adapter(fixture).reply(prompt, app: .grokBot, binding: binding)
        XCTAssertEqual(answer, "New answer")
        _ = try await finishedCalls(fixture)
    }

    func testGenerationAndUnclearedComposerCannotFinishTheReply() async throws {
        let fixture = try driver(sendSteps() + [
            snapshot(grok(draft: prompt, reply: "Still a draft", token: "s00000003")),
            snapshot(grok(reply: "Partial answer", token: "s00000004", generating: true)),
            snapshot(grok(reply: "Final answer", token: "s00000005"), repeating: true)
        ])
        defer { fixture.remove() }
        let answer = try await adapter(fixture).reply(prompt, app: .grokBot, binding: binding)
        XCTAssertEqual(answer, "Final answer")
        let calls = try await finishedCalls(fixture)
        XCTAssertGreaterThanOrEqual(calls.filter { $0.tool == "get_window_state" }.count, 6)
    }

    func testTimeoutAfterSubmissionDoesNotClickSendAgain() async throws {
        let fixture = try driver(sendSteps() + [snapshot(grok(token: "s00000003"), repeating: true)])
        defer { fixture.remove() }
        let error = await failure { try await self.adapter(fixture, replyTimeout: .milliseconds(180)).reply(self.prompt, app: .grokBot, binding: self.binding) }
        XCTAssertTrue(error.contains("nothing will be resent automatically"), error)
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1)
        assertBackgroundTargets(calls)
    }

    func testCancellationStopsDriverProcessAndReleasesAppForAnotherRequest() async throws {
        var blocked = step("type_text", ["effect": "unverifiable"])
        blocked["wait_for_release"] = true
        let fixture = try driver([apps(), windows(), snapshot(grok()), blocked])
        defer { fixture.remove() }
        let conversation = adapter(fixture)
        let sending = Task { try await conversation.reply(prompt, app: .grokBot, binding: binding) }
        try await waitForCall("type_text", in: fixture)
        let collision = await failure { try await conversation.reply("Another request", app: .grokBot, binding: self.binding) }
        XCTAssertTrue(collision.contains("already handling"), collision)
        sending.cancel()
        do { _ = try await sending.value; XCTFail("Canceled driver request must not complete") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        let calls = try await finishedCalls(fixture)
        let call = try XCTUnwrap(calls.first { $0.tool == "type_text" })
        XCTAssertEqual(kill(Int32(call.pid), 0), -1, "The fake driver process must not survive cancellation")
        XCTAssertFalse(calls.contains { $0.tool == "click" })
        try fixture.replacePlan([apps(), windows(), snapshot(grok())])
        let inspected = try await conversation.connectGrokBot(named: binding.name)
        XCTAssertEqual(inspected, binding)
        _ = try await finishedCalls(fixture, cleanupCount: 2)
    }

    func testDriverTimeoutStopsProcessBeforeAnySend() async throws {
        var blocked = step("type_text", [:]); blocked["wait_for_release"] = true
        let fixture = try driver([apps(), windows(), snapshot(grok()), blocked])
        defer { fixture.remove() }
        let conversation = adapter(fixture, callTimeout: 1)
        do { _ = try await conversation.reply(prompt, app: .grokBot, binding: binding); XCTFail("Expected the driver call to time out") }
        catch {
            guard case PersonalAgentError.timedOut = error else { return XCTFail("Expected timeout, got \(error)") }
        }
        let calls = try await finishedCalls(fixture)
        let call = try XCTUnwrap(calls.first { $0.tool == "type_text" })
        XCTAssertEqual(kill(Int32(call.pid), 0), -1)
        XCTAssertFalse(calls.contains { $0.tool == "click" })
    }

    func testMuseMainChatAndUntrackedSideChatCannotAuthorizeAutomaticSend() async throws {
        for title in ["Main chat", "Side chat A", "Side chat B"] {
            // Even if Muse exposes a standard editable field in a later app
            // version, a generic "Muse" heading cannot identify a side chat.
            let state: [String: Any] = ["elements": [
                element("AXButton", "Muse"), element("AXStaticText", title),
                element("AXTextArea", "Message", value: ""), element("AXButton", "Send")
            ]]
            let fixture = try driver([apps(.muse), windows(), snapshot(state)])
            defer { fixture.remove() }
            let error = await failure { try await self.adapter(fixture).reply(self.prompt, app: .muse, binding: .init(name: "Muse")) }
            XCTAssertTrue(error.contains("side-chat"), "An untracked \(title) must remain gated: \(error)")
            assertNoInput(try await finishedCalls(fixture))
        }
    }

    func testMuseCompoundComposerAndOffSpaceSnapshotRemainReadOnly() async throws {
        for state: [String: Any] in [
            ["elements": [element("AXButton", "Back to main chat"), element("AXStaticText", "New side chat"),
                          element("AXButton", "Message Attach file Dictate a message Send"), element("AXButton", "Muse")]],
            ["elements": [], "degraded": true, "degraded_reason": "ax_window_unresolved"]
        ] {
            let fixture = try driver([apps(.muse), windows(), snapshot(state)])
            defer { fixture.remove() }
            _ = await failure { try await self.adapter(fixture).reply(self.prompt, app: .muse, binding: .init(name: "Muse")) }
            assertNoInput(try await finishedCalls(fixture))
        }
    }

    func testMuseOnboardingWaitsForConsistentColdStartReadWithoutInputAndPreservesDraftFailure() async throws {
        for draft in ["", "Unsent Muse draft"] {
            var window = windows()
            var result = window["result"] as! [String: Any]
            var records = result["windows"] as! [[String: Any]]
            records[0]["is_on_screen"] = false
            records[0]["on_current_space"] = false
            records[0]["space_ids"] = [1]
            result["windows"] = records
            window["result"] = result
            window["native"] = try object(museObservation(draft: draft))
            let fixture = try driver([apps(.muse), window, snapshot(["elements": [element("AXButton", "Message Attach file Dictate a message Send")]])])
            defer { fixture.remove() }
            let session = WebAgentSession(provider: .museApp, storageURL: fixture.directory.appendingPathComponent("state.json"),
                                          fixture: false, museApp: museAdapter(fixture, transientReadFailures: 2, requiresDriverSnapshot: true), desktopApps: .demo, desktopDriver: try readinessDriver(fixture, app: .muse))
            session.setEnabled(true)
            await session.connectDesktopConversation()
            XCTAssertEqual(session.desktopReady, draft.isEmpty)
            XCTAssertEqual(session.desktopConnectionConfirmation != nil, draft.isEmpty)
            if !draft.isEmpty {
                let failure = session.desktopStatus
                XCTAssertTrue(failure.contains("draft"))
                session.refreshDesktopInstallation()
                XCTAssertEqual(session.desktopStatus, failure, "Reactivation must preserve the reason a check failed")
            }
            XCTAssertTrue(session.state.attempts.isEmpty)
            XCTAssertTrue(session.state.museAppConversations.isEmpty)
            let calls = try fixture.calls()
            XCTAssertEqual(calls.map(\.tool).filter { $0 != "end_session" }, ["list_apps", "list_windows", "get_window_state"])
            assertNoInput(calls)
            session.beginShutdown()
        }
    }

    func testMuseCheckCannotClaimReadyAfterRemovalDisableOrShutdownDuringTheRead() async throws {
        @MainActor final class InstalledApp {
            var installation = DesktopAppInstallation(url: URL(fileURLWithPath: "/Fixture/Muse.app"), processID: 4242)
        }
        for change in ["removal", "disable", "shutdown"] {
            var window = windows()
            window["native"] = try object(museObservation())
            window["wait_for_release"] = true
            let fixture = try driver([apps(.muse), window])
            defer { fixture.remove() }
            let installed = InstalledApp()
            let client = DesktopAppInstallationClient(inspect: { _ in installed.installation }, open: { _ in XCTFail("A check must not launch the app") })
            let session = WebAgentSession(provider: .museApp, storageURL: fixture.directory.appendingPathComponent("state.json"),
                                          fixture: false, museApp: museAdapter(fixture), desktopApps: client, desktopDriver: try readinessDriver(fixture, app: .muse))
            session.setEnabled(true)
            let check = Task { await session.connectDesktopConversation() }
            try await waitForCall("list_windows", in: fixture)
            if change == "removal" { installed.installation = .init(url: nil, processID: nil) }
            else if change == "disable" { session.setEnabled(false) }
            else { session.beginShutdown() }
            try Data().write(to: fixture.directory.appendingPathComponent("release"))
            await check.value
            XCTAssertFalse(session.desktopReady)
            XCTAssertFalse(session.snapshot.ready)
            XCTAssertNil(session.desktopConnectionConfirmation)
            XCTAssertNil(session.state.desktopConversation)
            XCTAssertTrue(session.state.attempts.isEmpty)
            assertNoInput(try fixture.calls())
            session.beginShutdown()
        }
    }

    func testMuseCreatesSideChatVerifiesDraftAndPersistsUUIDBeforeReply() async throws {
        let owner = UUID(), thread = UUID()
        let fixture = try driver(try museCreationSteps(owner: owner, thread: thread, answer: nil))
        defer { fixture.remove() }
        let stateURL = fixture.directory.appendingPathComponent("state.json")
        var saved = WebWorkspaceState()
        saved.enabled = true; saved.desktopConversation = .init(name: "Muse"); saved.comparisonID = owner; saved.draft = prompt
        try JSONEncoder().encode(saved).write(to: stateURL)
        let session = WebAgentSession(provider: .museApp, storageURL: stateURL, fixture: false, museApp: museAdapter(fixture, transientWindowFailure: true), desktopApps: .demo, desktopDriver: try readinessDriver(fixture, app: .muse))
        let sending = Task { await session.send(prompt, comparisonID: owner) }
        try await waitForCall("press_key", in: fixture)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while session.state.museAppConversations[owner.uuidString]?.threadID == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let waiting = try JSONDecoder().decode(WebWorkspaceState.self, from: Data(contentsOf: stateURL))
        XCTAssertEqual(waiting.museAppConversations[owner.uuidString]?.threadID, thread)
        XCTAssertEqual(waiting.attempts.first?.conversationURL, waiting.museAppConversations[owner.uuidString]?.url)
        XCTAssertTrue(session.isSending, "Identity must be durable while the response is still pending")
        let requestID = try XCTUnwrap(waiting.attempts.first?.id)
        let wire = "[msgblast request \(requestID.uuidString.lowercased())]\n\n" + prompt
        try setNative(museObservation(thread: thread, messages: [.init(role: .user, text: wire), .init(role: .assistant, text: "Muse answer")], title: "Renamed by Muse"), in: fixture)
        let sent = await sending.value
        let attempt = try XCTUnwrap(sent)
        XCTAssertEqual(attempt.status, .observed)
        XCTAssertEqual(attempt.conversationURL, waiting.museAppConversations[owner.uuidString]?.url)
        XCTAssertEqual(session.state.localConversations[owner.uuidString]?.map(\.text), [prompt, "Muse answer"])
        XCTAssertEqual(session.state.museAppConversations[owner.uuidString]?.title, "Renamed by Muse")
        XCTAssertTrue(session.state.localSessionIDs.isEmpty)
        let calls = try await finishedCalls(fixture, cleanupCount: 2)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.compactMap { $0.arguments["text"] as? String }, ["[msgblast request \(requestID.uuidString.lowercased())]", prompt])
        XCTAssertEqual(calls.filter { $0.tool == "press_key" && $0.arguments["modifiers"] == nil }.count, 1)
        let typed = calls.filter { $0.tool == "type_text" }
        XCTAssertEqual(typed.first?.arguments["x"] as? Int, 510)
        XCTAssertEqual(typed.first?.arguments["y"] as? Int, 750)
        XCTAssertTrue(typed.dropFirst().allSatisfy { $0.arguments["x"] == nil && $0.arguments["y"] == nil })
        XCTAssertTrue(typed.allSatisfy { $0.arguments["element_token"] == nil && $0.arguments["capture_id"] == nil })
        assertMuseBackground(calls)
        session.beginShutdown()
    }

    func testMuseResumeUsesUUIDWhenTitlesDuplicateAndNeverCreatesReplacement() async throws {
        let owner = UUID(), intended = UUID(), other = UUID()
        var first = windows(); first["native"] = try object(museObservation(thread: other))
        let navigation: [String: Any] = ["elements": [
            element("AXHeading", "Side chats"), element("AXButton", "New side chat", token: "s00000001:new"),
            element("AXButton", "Same generated title", token: "s00000001:wrong"),
            element("AXButton", "Same generated title", token: "s00000001:right"), element("AXSplitter", "Resize panel")
        ]]
        let fixture = try driver([
            apps(.muse), first, snapshot(navigation),
            capturedNavigation(navigation), try museStep("click", observation: museObservation(thread: other)),
            snapshot(navigation), capturedNavigation(navigation), try museStep("click", observation: museObservation(thread: intended, title: "Changed title"))
        ])
        defer { fixture.remove() }
        let result = try await museAdapter(fixture).prepare(comparisonID: owner, binding: .init(comparisonID: owner, threadID: intended, title: "Same generated title"))
        XCTAssertEqual(result.threadID, intended)
        XCTAssertEqual(result.title, "Changed title")
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.compactMap { $0.arguments["y"] as? Int }, [105, 165])
        XCTAssertTrue(calls.filter { $0.tool == "click" }.allSatisfy { $0.arguments["element_token"] == nil })
        assertMuseBackground(calls)
    }

    func testMuseWaitsForUnchangedDraftReadbackWithoutReplayingInput() async throws {
        let owner = UUID(), thread = UUID()
        var initial = windows(); initial["native"] = try object(museObservation(thread: thread))
        let typed = museObservation(thread: thread, draft: prompt)
        let messages = [MuseAppMessage(role: .user, text: prompt), .init(role: .assistant, text: "Observed reply")]
        let fixture = try driver([apps(.muse), initial, museComposerCapture(),
            try museStep("type_text", observation: typed),
            try museStep("press_key", observation: museObservation(thread: thread, messages: messages))])
        defer { fixture.remove() }
        let staleReads = MuseReadFault(failures: 2)
        let expectedDraft = prompt
        let adapter = MuseAppConversation(executable: fixture.executable,
            timing: .init(pollInterval: .milliseconds(5), stableDuration: .zero, replyTimeout: .seconds(3), callTimeout: 3)) { _ in
                let actual = try JSONDecoder().decode(MuseAppObservation.self,
                    from: Data(contentsOf: fixture.directory.appendingPathComponent("native.json")))
                // CGEvent completion can precede WebKit publishing its exact
                // parameterized text range. Only delay the post-input readback.
                if actual.draft == expectedDraft, staleReads.shouldFail() {
                    var stale = actual; stale.draft = ""; return stale
                }
                return actual
            }
        let result = try await adapter.reply(prompt, binding: .init(comparisonID: owner, threadID: thread, title: "Title")) { _ in }
        XCTAssertEqual(result, "Observed reply")
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1, "Readback recovery must not retype")
        XCTAssertEqual(calls.filter { $0.tool == "press_key" }.count, 1, "Submit once, after the exact draft appears")
        XCTAssertFalse(staleReads.shouldFail(), "Both stale reads must be consumed before submission")
        assertMuseBackground(calls)
    }

    func testMuseDoesNotTypeIfRecoveryReceiptCannotBeSaved() async throws {
        enum StorageFailure: Error { case denied }
        let owner = UUID(), thread = UUID()
        var initial = windows(); initial["native"] = try object(museObservation(thread: thread))
        let fixture = try driver([apps(.muse), initial])
        defer { fixture.remove() }
        do {
            _ = try await museAdapter(fixture).reply(prompt, binding: .init(comparisonID: owner, threadID: thread, title: "Side chat"), onReceipt: { _, _ in throw StorageFailure.denied }, onBinding: { _ in })
            XCTFail("A failed recovery receipt must stop before typing")
        } catch StorageFailure.denied { }
        assertNoInput(try await finishedCalls(fixture))
    }

    func testMusePartialDraftFocusLossAndChatSwitchPreventReturnWithoutReplay() async throws {
        let owner = UUID(), thread = UUID()
        for fault in ["unchanged", "partial", "focus", "chat", "history", "generating"] {
            var initial = windows(); initial["native"] = try object(museObservation(thread: thread))
            var typed = museObservation(thread: fault == "chat" ? UUID() : thread, draft: fault == "unchanged" ? "" : fault == "partial" ? "Partial" : prompt)
            typed.composerFocused = fault != "focus"
            if fault == "history" { typed.messages = [.init(role: .assistant, text: "Unrelated incoming message")] }
            typed.generating = fault == "generating"
            let fixture = try driver([apps(.muse), initial, museComposerCapture(), try museStep("type_text", observation: typed)])
            defer { fixture.remove() }
            _ = await failure { try await self.museAdapter(fixture).reply(self.prompt, binding: .init(comparisonID: owner, threadID: thread, title: "Title")) { _ in XCTFail("Must not record an unsubmitted draft") } }
            let calls = try await finishedCalls(fixture)
            XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
            XCTAssertFalse(calls.contains { $0.tool == "press_key" })
            assertMuseBackground(calls)
        }
    }

    func testMuseRejectsExternalDraftAndUntrackedNewChatAfterRestart() async throws {
        for draft in ["", "External unsent draft"] {
            var initial = windows(); initial["native"] = try object(museObservation(draft: draft))
            let fixture = try driver([apps(.muse), initial])
            defer { fixture.remove() }
            _ = await failure { try await self.museAdapter(fixture).reply(self.prompt, binding: .init(comparisonID: UUID(), threadID: nil, title: "New side chat")) { _ in XCTFail("No submission") } }
            assertNoInput(try await finishedCalls(fixture))
        }
    }

    func testMuseTimeoutRetainsUUIDAndBlocksOtherComparisonsAcrossRestart() async throws {
        let owner = UUID(), thread = UUID(), other = UUID()
        let fixture = try driver(try museCreationSteps(owner: owner, thread: thread, answer: nil))
        defer { fixture.remove() }
        let stateURL = fixture.directory.appendingPathComponent("state.json")
        var saved = WebWorkspaceState()
        saved.enabled = true; saved.desktopConversation = .init(name: "Muse"); saved.comparisonID = owner; saved.draft = prompt
        try JSONEncoder().encode(saved).write(to: stateURL)
        let session = WebAgentSession(provider: .museApp, storageURL: stateURL, fixture: false, museApp: museAdapter(fixture, timeout: .milliseconds(150)), desktopApps: .demo, desktopDriver: try readinessDriver(fixture, app: .muse))
        let result = await session.send(prompt, comparisonID: owner)
        XCTAssertEqual(result?.status, .uncertain)
        XCTAssertEqual(result?.messageID, result?.id.uuidString, "A missing reply must retain the verified outgoing receipt")
        XCTAssertNil(session.pendingNativeAttempt, "A confirmed outgoing prompt is now in the transcript")
        XCTAssertEqual(session.snapshot.messages.first?.id, result?.id.uuidString)
        XCTAssertEqual(session.state.museAppConversations[owner.uuidString]?.threadID, thread)
        session.beginShutdown()
        let reopened = WebAgentSession(provider: .museApp, storageURL: stateURL, fixture: false, museApp: museAdapter(fixture), desktopApps: .demo, desktopDriver: try readinessDriver(fixture, app: .muse))
        reopened.updateState { $0.comparisonID = other }
        let blocked = await reopened.send("Other comparison", comparisonID: other)
        XCTAssertNil(blocked)
        reopened.acknowledgeIncompleteRequest()
        XCTAssertTrue(reopened.hasUnresolvedSend(prompt))
        reopened.updateState { $0.comparisonID = owner }
        reopened.acknowledgeIncompleteRequest()
        XCTAssertFalse(reopened.hasUnresolvedSend(prompt))
        XCTAssertEqual(reopened.state.draft, prompt)
        XCTAssertEqual(reopened.state.museAppConversations[owner.uuidString]?.threadID, thread)
        let calls = try await finishedCalls(fixture, cleanupCount: 2)
        XCTAssertEqual(calls.filter { $0.tool == "press_key" && $0.arguments["modifiers"] == nil }.count, 1)
        assertMuseBackground(calls)
        reopened.beginShutdown()
    }

    func testMuseLateReplyRecoversAfterRealSessionTimeoutAndReloadWithoutResending() async throws {
        let owner = UUID(), thread = UUID()
        let fixture = try driver(try museCreationSteps(owner: owner, thread: thread, answer: nil))
        defer { fixture.remove() }
        let storage = fixture.directory.appendingPathComponent("state.json")
        var saved = WebWorkspaceState()
        saved.enabled = true; saved.desktopConversation = .init(name: "Muse"); saved.comparisonID = owner; saved.draft = prompt
        try JSONEncoder().encode(saved).write(to: storage)
        let session = WebAgentSession(provider: .museApp, storageURL: storage, fixture: false, museApp: museAdapter(fixture, timeout: .milliseconds(150)), desktopApps: .demo, desktopDriver: try readinessDriver(fixture, app: .muse))
        let sent = await session.send(prompt, comparisonID: owner)
        let result = try XCTUnwrap(sent)
        XCTAssertEqual(result.status, .uncertain)
        XCTAssertEqual(result.messageID, result.id.uuidString)
        let receipt = try XCTUnwrap(result.museReplyReceipt)
        XCTAssertNil(receipt.initialThreadID)
        XCTAssertEqual(receipt.requestID, result.id)
        XCTAssertEqual(result.conversationURL, MuseSideChatBinding(comparisonID: owner, threadID: thread, title: "").url)
        session.beginShutdown()
        let wire = MuseAppConversation.firstPrompt(prompt, requestID: result.id)
        try setNative(museObservation(thread: thread, messages: [.init(role: .user, text: wire), .init(role: .assistant, text: "A late answer")]), in: fixture)
        try fixture.replacePlan([apps(.muse), windows()])
        let reopened = WebAgentSession(provider: .museApp, storageURL: storage, fixture: false, museApp: museAdapter(fixture), desktopApps: .demo, desktopDriver: try readinessDriver(fixture, app: .muse))
        reopened.connect(automaticallyRefresh: false)
        let remaining = await reopened.reconcileMuseReplyOnce()
        reopened.beginShutdown()
        XCTAssertFalse(remaining)
        let recovered = try JSONDecoder().decode(WebWorkspaceState.self, from: Data(contentsOf: storage))
        XCTAssertEqual(recovered.attempts.first?.status, .observed)
        XCTAssertEqual(recovered.localConversations[owner.uuidString]?.map(\.text), [prompt, "A late answer"])
        XCTAssertEqual(recovered.draft, "", "The recovered reply clears the unchanged submitted draft")
        XCTAssertEqual(recovered.localDrafts[owner.uuidString], "")
        let calls = try await finishedCalls(fixture, cleanupCount: 3)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 2)
        XCTAssertEqual(calls.filter { $0.tool == "press_key" && $0.arguments["modifiers"] == nil }.count, 1)
    }

    func testMuseWorkingPastDeadlineDoesNotHoldTheBroadcastOpen() async throws {
        final class Reads: @unchecked Sendable {
            private let lock = NSLock()
            private var reads = 0
            var count: Int { lock.withLock { reads } }
            func next(_ value: MuseAppObservation) -> MuseAppObservation {
                guard !value.messages.isEmpty else { return value }
                return lock.withLock {
                    reads += 1
                    var result = value
                    result.generating = reads <= 3
                    if reads > 3 { result.messages.append(.init(role: .assistant, text: "Eventually finished")) }
                    return result
                }
            }
        }
        let owner = UUID(), thread = UUID(), reads = Reads()
        let fixture = try driver(try museCreationSteps(owner: owner, thread: thread, answer: nil))
        defer { fixture.remove() }
        let storage = fixture.directory.appendingPathComponent("state.json")
        var saved = WebWorkspaceState()
        saved.enabled = true; saved.desktopConversation = .init(name: "Muse"); saved.comparisonID = owner; saved.draft = prompt
        try JSONEncoder().encode(saved).write(to: storage)
        let muse = museAdapter(fixture, timeout: .milliseconds(15), replyClock: .init(AdvancingClock()), transformNative: { reads.next($0) })
        let session = WebAgentSession(provider: .museApp, storageURL: storage, fixture: false, museApp: muse, desktopApps: .demo, desktopDriver: try readinessDriver(fixture, app: .muse))
        let sent = await session.send(prompt, comparisonID: owner)
        session.beginShutdown()
        let attempt = try XCTUnwrap(sent)
        XCTAssertEqual(attempt.status, .uncertain)
        XCTAssertEqual(attempt.messageID, attempt.id.uuidString, "The outgoing message must be confirmed")
        XCTAssertNotNil(attempt.museReplyReceipt)
        XCTAssertEqual(reads.count, 3, "The foreground wait should stop after three deadline ticks")
        let calls = try await finishedCalls(fixture, cleanupCount: 2)
        XCTAssertEqual(calls.filter { $0.tool == "press_key" && $0.arguments["modifiers"] == nil }.count, 1)
    }

    func testMuseRecoveryRejectsUnconfirmedCancelledAndWrongOwnership() async throws {
        let fixture = try driver([])
        defer { fixture.remove() }
        let owner = UUID(), thread = UUID(), other = UUID()
        let client = DesktopAppInstallationClient(inspect: { _ in .init(url: URL(fileURLWithPath: "/Fixture/Muse.app"), processID: 4242) }, open: { _ in XCTFail("Recovery must not launch Muse") })
        for scenario in ["unconfirmed", "cancelled", "wrong thread", "wrong comparison", "wrong request", "missing outgoing", "interleaved", "multiple requests", "unsupported version"] {
            var workspace = WebWorkspaceState()
            workspace.enabled = true; workspace.comparisonID = owner
            let binding = MuseSideChatBinding(comparisonID: owner, threadID: scenario == "wrong thread" ? other : thread, title: "Side chat")
            try workspace.recordMuseAppBinding(binding)
            var attempt = WebSendAttempt(text: "Question", status: .uncertain)
            attempt.comparisonID = owner; attempt.messageID = attempt.id.uuidString
            attempt.conversationURL = MuseSideChatBinding(comparisonID: owner, threadID: thread, title: "Side chat").url
            attempt.museReplyReceipt = try .init(comparisonID: scenario == "wrong comparison" ? UUID() : owner,
                                                  requestID: scenario == "wrong request" ? UUID() : attempt.id,
                                                  initialThreadID: thread, prompt: "Question", baseline: [])
            if scenario == "unconfirmed" { attempt.messageID = nil }
            if scenario == "cancelled" { attempt.museReplyReceipt?.automaticRecovery = false }
            if scenario == "unsupported version" { attempt.museReplyReceipt?.version = 2 }
            workspace.attempts = [attempt]
            workspace.localConversations[owner.uuidString] = [.init(id: attempt.id.uuidString, role: "user", text: attempt.text)]
            if scenario == "missing outgoing" { workspace.localConversations[owner.uuidString] = [] }
            if scenario == "interleaved" { workspace.localConversations[owner.uuidString]?.append(.init(role: "user", text: "Another request")) }
            if scenario == "multiple requests" { workspace.attempts.append(WebSendAttempt(text: "Another request", status: .uncertain)) }
            let storage = fixture.directory.appendingPathComponent("muse-\(scenario).json")
            try JSONEncoder().encode(workspace).write(to: storage)
            let session = WebAgentSession(provider: .museApp, storageURL: storage, fixture: false, museApp: .shared, desktopApps: client)
            session.connect(automaticallyRefresh: false)
            let remaining = await session.reconcileMuseReplyOnce()
            XCTAssertFalse(remaining, scenario)
            XCTAssertEqual(session.state.attempts.first?.status, .uncertain, scenario)
            session.beginShutdown()
        }
        XCTAssertTrue(try fixture.calls().isEmpty, "Unsafe recovery must not inspect or interact with any app")
    }

    func testMuseRecoveryNeverAttributesAnotherOpenSideChat() async throws {
        let owner = UUID(), thread = UUID(), other = UUID()
        let fixture = try driver([apps(.muse), windows()])
        defer { fixture.remove() }
        let receipt = try MuseReplyReceipt(comparisonID: owner, requestID: UUID(), initialThreadID: thread, prompt: "Question", baseline: [])
        let observation = museObservation(thread: other, messages: [.init(role: .user, text: "Question"), .init(role: .assistant, text: "Wrong chat")])
        let adapter = MuseAppConversation(executable: fixture.executable, timing: .init(stableDuration: .zero)) { _ in observation }
        do {
            _ = try await adapter.recoverReply(receipt, binding: .init(comparisonID: owner, threadID: thread, title: "Side chat"))
            XCTFail("A reply from a different side chat must not be attributed")
        } catch { XCTAssertTrue(error.localizedDescription.contains("side chat changed")) }
        let calls = try await finishedCalls(fixture)
        assertNoInput(calls)
    }

    func testMuseRecoveryRechecksTheRequestAfterAnInFlightRead() async throws {
        let owner = UUID(), thread = UUID()
        let fixture = try driver([apps(.muse), windows()])
        defer { fixture.remove() }
        let started = expectation(description: "Muse read started")
        let resume = DispatchSemaphore(value: 0)
        let marker = fixture.directory.appendingPathComponent("muse-read-started")
        let observation = museObservation(thread: thread, messages: [.init(role: .user, text: "Question"), .init(role: .assistant, text: "Late answer")])
        let adapter = MuseAppConversation(executable: fixture.executable, timing: .init(stableDuration: .zero)) { _ in
            if !FileManager.default.fileExists(atPath: marker.path) {
                try Data().write(to: marker); started.fulfill()
                guard resume.wait(timeout: .now() + 5) == .success else { throw CocoaError(.userCancelled) }
            }
            return observation
        }
        let binding = MuseSideChatBinding(comparisonID: owner, threadID: thread, title: "Side chat")
        var workspace = WebWorkspaceState()
        workspace.enabled = true; workspace.comparisonID = owner
        try workspace.recordMuseAppBinding(binding)
        var attempt = WebSendAttempt(text: "Question", status: .uncertain)
        attempt.comparisonID = owner; attempt.messageID = attempt.id.uuidString; attempt.conversationURL = binding.url
        attempt.museReplyReceipt = try .init(comparisonID: owner, requestID: attempt.id, initialThreadID: thread, prompt: "Question", baseline: [])
        workspace.attempts = [attempt]
        workspace.localConversations[owner.uuidString] = [.init(id: attempt.id.uuidString, role: "user", text: attempt.text)]
        let storage = fixture.directory.appendingPathComponent("muse-in-flight.json")
        try JSONEncoder().encode(workspace).write(to: storage)
        let client = DesktopAppInstallationClient(inspect: { _ in .init(url: URL(fileURLWithPath: "/Fixture/Muse.app"), processID: 4242) }, open: { _ in XCTFail("Recovery must not launch Muse") })
        let session = WebAgentSession(provider: .museApp, storageURL: storage, fixture: false, museApp: adapter, desktopApps: client)
        session.connect(automaticallyRefresh: false)
        let recovery = Task { await session.reconcileMuseReplyOnce() }
        await fulfillment(of: [started], timeout: 3)
        session.updateState { $0.attempts[0].status = .dismissed }
        resume.signal()
        let remaining = await recovery.value
        session.beginShutdown()
        XCTAssertFalse(remaining)
        let saved = try JSONDecoder().decode(WebWorkspaceState.self, from: Data(contentsOf: storage))
        XCTAssertEqual(saved.attempts.first?.status, .dismissed)
        XCTAssertEqual(saved.localConversations[owner.uuidString]?.map(\.text), ["Question"])
        XCTAssertFalse(try fixture.calls().contains { ["type_text", "press_key", "click", "launch_app"].contains($0.tool) })
    }

    func testMuseConfirmedPromptSurvivesMissingReplyAcknowledgementAndRestart() async throws {
        let owner = UUID(), thread = UUID()
        let fixture = try driver(try museCreationSteps(owner: owner, thread: thread, answer: nil))
        defer { fixture.remove() }
        let file = fixture.directory.appendingPathComponent("state.json")
        var saved = WebWorkspaceState()
        saved.enabled = true; saved.desktopConversation = .init(name: "Muse"); saved.comparisonID = owner
        try JSONEncoder().encode(saved).write(to: file)
        let session = WebAgentSession(provider: .museApp, storageURL: file, fixture: false, museApp: museAdapter(fixture, timeout: .milliseconds(150)), desktopApps: .demo, desktopDriver: try readinessDriver(fixture, app: .muse))
        var confirmations = 0
        let sent = await session.send(prompt, comparisonID: owner, onConfirmedSubmission: {
            confirmations += 1
            let persisted = try? JSONDecoder().decode(WebWorkspaceState.self, from: Data(contentsOf: file))
            XCTAssertEqual(persisted?.attempts.first?.status, .waiting, "Notify only after the outgoing receipt is durable")
            XCTAssertEqual(persisted?.localConversations[owner.uuidString]?.map(\.text), [self.prompt])
        })
        XCTAssertEqual(confirmations, 1)
        let result = try XCTUnwrap(sent)
        XCTAssertEqual(result.status, .uncertain)
        XCTAssertEqual(result.messageID, result.id.uuidString)
        XCTAssertEqual(session.snapshot.messages, [.init(id: result.id.uuidString, role: "user", text: prompt)])
        session.acknowledgeIncompleteRequest()
        XCTAssertNil(session.pendingNativeAttempt)
        XCTAssertEqual(session.snapshot.messages.map(\.text), [prompt])
        session.beginShutdown()
        let reopened = WebAgentSession(provider: .museApp, storageURL: file, fixture: false, museApp: museAdapter(fixture), desktopApps: .demo, desktopDriver: try readinessDriver(fixture, app: .muse))
        XCTAssertEqual(reopened.state.localConversations[owner.uuidString]?.map(\.id), [result.id.uuidString])
        XCTAssertEqual(reopened.state.localConversations[owner.uuidString]?.map(\.text), [prompt])
        let calls = try await finishedCalls(fixture, cleanupCount: 2)
        XCTAssertEqual(calls.filter { $0.tool == "press_key" && $0.arguments["modifiers"] == nil }.count, 1)
        reopened.beginShutdown()
    }

    func testMuseURLBeforeOutgoingSurvivesTimeoutAcknowledgementAndVerifiedRecovery() async throws {
        let owner = UUID(), thread = UUID()
        var plan = try museCreationSteps(owner: owner, thread: thread, answer: nil)
        plan[plan.count - 1]["native"] = try object(museObservation(thread: thread))
        let fixture = try driver(plan)
        defer { fixture.remove() }
        let file = fixture.directory.appendingPathComponent("state.json")
        var saved = WebWorkspaceState()
        saved.enabled = true; saved.desktopConversation = .init(name: "Muse"); saved.comparisonID = owner
        try JSONEncoder().encode(saved).write(to: file)
        let session = WebAgentSession(provider: .museApp, storageURL: file, fixture: false, museApp: museAdapter(fixture, timeout: .milliseconds(150)), desktopApps: .demo, desktopDriver: try readinessDriver(fixture, app: .muse))
        var confirmations = 0
        let sent = await session.send(prompt, comparisonID: owner, onConfirmedSubmission: { confirmations += 1 })
        XCTAssertEqual(confirmations, 0, "An unconfirmed outgoing message must not clear the shared draft early")
        let result = try XCTUnwrap(sent)
        XCTAssertEqual(result.status, .uncertain)
        let candidate = URL(string: "https://muse.ai/thread/\(thread.uuidString)")!
        XCTAssertEqual(result.recoveryConversationURL, candidate)
        XCTAssertNil(result.conversationURL)
        XCTAssertNil(session.state.museAppConversations[owner.uuidString]?.threadID)
        session.beginShutdown()
        let reopened = WebAgentSession(provider: .museApp, storageURL: file, fixture: false, museApp: museAdapter(fixture), desktopApps: .demo, desktopDriver: try readinessDriver(fixture, app: .muse))
        reopened.acknowledgeIncompleteRequest()
        reopened.connect(automaticallyRefresh: false)
        try fixture.replacePlan([apps(.muse), windows()])
        await reopened.refresh()
        XCTAssertFalse(reopened.snapshot.ready, "An address alone cannot establish ownership")
        XCTAssertNil(reopened.state.museAppConversations[owner.uuidString]?.threadID)
        let wire = "[msgblast request \(result.id.uuidString.lowercased())]\n\n" + prompt
        try setNative(museObservation(thread: thread, messages: [.init(role: .user, text: wire), .init(role: .assistant, text: "Late answer")]), in: fixture)
        try fixture.replacePlan([apps(.muse), windows()])
        await reopened.refresh()
        XCTAssertTrue(reopened.snapshot.ready)
        let disk = try JSONDecoder().decode(WebWorkspaceState.self, from: Data(contentsOf: file))
        XCTAssertEqual(disk.museAppConversations[owner.uuidString]?.threadID, thread)
        XCTAssertEqual(disk.attempts.first?.conversationURL, URL(string: "https://muse.ai/thread/\(thread.uuidString.lowercased())"))
        XCTAssertNil(disk.attempts.first?.recoveryConversationURL)
        XCTAssertEqual(disk.attempts.first?.status, .dismissed, "Recovery must not invent a completed reply")
        let calls = try await finishedCalls(fixture, cleanupCount: 4)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1, "Recovery cannot create a replacement")
        XCTAssertEqual(calls.filter { $0.tool == "press_key" && $0.arguments["modifiers"] == nil }.count, 1, "Recovery cannot resend")
        assertMuseBackground(calls)
        reopened.beginShutdown()
    }

    func testMuseOldChatWithSamePromptCannotClaimFirstSubmissionOrRecoverWithoutReference() async throws {
        let owner = UUID(), foreign = UUID()
        var plan = try museCreationSteps(owner: owner, thread: foreign, answer: nil)
        plan[plan.count - 1]["native"] = try object(museObservation(thread: foreign, messages: [
            .init(role: .user, text: prompt), .init(role: .assistant, text: "Old answer")]))
        let fixture = try driver(plan)
        defer { fixture.remove() }
        let file = fixture.directory.appendingPathComponent("state.json")
        var saved = WebWorkspaceState()
        saved.enabled = true; saved.desktopConversation = .init(name: "Muse"); saved.comparisonID = owner
        try JSONEncoder().encode(saved).write(to: file)
        let session = WebAgentSession(provider: .museApp, storageURL: file, fixture: false, museApp: museAdapter(fixture), desktopApps: .demo, desktopDriver: try readinessDriver(fixture, app: .muse))
        let sent = await session.send(prompt, comparisonID: owner)
        let result = try XCTUnwrap(sent)
        XCTAssertEqual(result.status, .uncertain)
        XCTAssertNotNil(result.recoveryConversationURL, "Keep the observed locator even when attribution fails")
        XCTAssertNil(result.conversationURL)
        XCTAssertNil(session.state.museAppConversations[owner.uuidString]?.threadID)
        XCTAssertTrue(session.state.localConversations.isEmpty)
        session.acknowledgeIncompleteRequest()
        try fixture.replacePlan([apps(.muse), windows()])
        await session.refresh()
        XCTAssertFalse(session.snapshot.ready)
        XCTAssertNil(session.state.museAppConversations[owner.uuidString]?.threadID)
        let calls = try await finishedCalls(fixture, cleanupCount: 3)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1)
        XCTAssertEqual(calls.filter { $0.tool == "press_key" && $0.arguments["modifiers"] == nil }.count, 1)
        assertMuseBackground(calls)
        session.beginShutdown()
    }

    func testMuseCancellationStopsInputAndReleasesActorWithoutSendingReturn() async throws {
        let owner = UUID(), thread = UUID()
        var initial = windows(); initial["native"] = try object(museObservation(thread: thread))
        var blocked = try museStep("type_text", observation: museObservation(thread: thread, draft: prompt))
        blocked["wait_for_release"] = true
        let fixture = try driver([apps(.muse), initial, museComposerCapture(), blocked])
        defer { fixture.remove() }
        let adapter = museAdapter(fixture)
        let sending = Task { try await adapter.reply(prompt, binding: .init(comparisonID: owner, threadID: thread, title: "Saved")) { _ in XCTFail("No submission") } }
        try await waitForCall("type_text", in: fixture)
        let collision = await failure { try await adapter.prepare(comparisonID: owner, binding: nil) }
        XCTAssertTrue(collision.contains("already handling"))
        sending.cancel()
        do { _ = try await sending.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        let calls = try await finishedCalls(fixture)
        XCTAssertFalse(calls.contains { $0.tool == "press_key" })
        let call = try XCTUnwrap(calls.first { $0.tool == "type_text" })
        XCTAssertEqual(kill(Int32(call.pid), 0), -1)
        try setNative(museObservation(thread: thread), in: fixture)
        try fixture.replacePlan([apps(.muse), windows()])
        let reopened = try await adapter.prepare(comparisonID: owner, binding: .init(comparisonID: owner, threadID: thread, title: "Saved"))
        XCTAssertEqual(reopened.threadID, thread)
        _ = try await finishedCalls(fixture, cleanupCount: 2)
    }

    func testMuseMissingSavedChatCannotCreateReplacement() async throws {
        let owner = UUID(), other = UUID()
        var initial = windows(); initial["native"] = try object(museObservation(thread: other))
        let list = snapshot(["elements": [element("AXButton", "New side chat", token: "s00000001:new"), element("AXButton", "Another chat", token: "s00000001:other"), element("AXSplitter", "Resize panel")]])
        let capture = capturedNavigation(list["result"] as! [String: Any])
        let click = try museStep("click", observation: museObservation(thread: other))
        let fixture = try driver([apps(.muse), initial, list, capture, click, list, capture, list, capture, click, list, capture])
        defer { fixture.remove() }
        let message = await failure { try await self.museAdapter(fixture).prepare(comparisonID: owner, binding: .init(comparisonID: owner, threadID: UUID(), title: "Missing")) }
        XCTAssertTrue(message.contains("not found"), message)
        let calls = try await finishedCalls(fixture)
        XCTAssertFalse(calls.contains { $0.tool == "type_text" || $0.tool == "press_key" || $0.arguments["element_token"] as? String == "s00000001:new" })
        assertMuseBackground(calls)
    }

    func testMuseChangedChatWhileWaitingCannotReturnForeignAnswer() async throws {
        let owner = UUID(), thread = UUID()
        var initial = windows(); initial["native"] = try object(museObservation(thread: thread))
        let fixture = try driver([apps(.muse), initial, museComposerCapture(),
            try museStep("type_text", observation: museObservation(thread: thread, draft: prompt)),
            try museStep("press_key", observation: museObservation(thread: UUID(), messages: [.init(role: .user, text: prompt), .init(role: .assistant, text: "Foreign reply")]))])
        defer { fixture.remove() }
        let error = await failure { try await self.museAdapter(fixture).reply(self.prompt, binding: .init(comparisonID: owner, threadID: thread, title: "Saved")) { _ in XCTFail("Foreign UUID cannot replace a saved binding") } }
        XCTAssertTrue(error.contains("switched side chats"), error)
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "press_key" }.count, 1)
    }

    func testMuseMultilineDraftUsesShiftReturnAndSubmitsOnlyAfterExactFinalReadback() async throws {
        let owner = UUID(), thread = UUID()
        let multiline = "First line 😀\n\nReply only: MULTILINE"
        var initial = windows(); initial["native"] = try object(museObservation(thread: thread))
        let fixture = try driver([
            apps(.muse), initial, museComposerCapture(),
            try museStep("type_text", observation: museObservation(thread: thread, draft: "First line 😀")),
            try museStep("press_key", observation: museObservation(thread: thread, draft: "First line 😀\n\n")),
            try museStep("press_key", observation: museObservation(thread: thread, draft: "First line 😀\n\n\n")),
            try museStep("type_text", observation: museObservation(thread: thread, draft: multiline)),
            try museStep("press_key", observation: museObservation(thread: thread, messages: [.init(role: .user, text: multiline), .init(role: .assistant, text: "MULTILINE")]))
        ])
        defer { fixture.remove() }
        let answer = try await museAdapter(fixture).reply(multiline, binding: .init(comparisonID: owner, threadID: thread, title: "Saved")) { _ in }
        XCTAssertEqual(answer, "MULTILINE")
        let calls = try await finishedCalls(fixture)
        let keys = calls.filter { $0.tool == "press_key" }
        XCTAssertEqual(keys.count, 3)
        XCTAssertEqual(keys[0].arguments["modifiers"] as? [String], ["shift"])
        XCTAssertEqual(keys[1].arguments["modifiers"] as? [String], ["shift"])
        XCTAssertNil(keys[2].arguments["modifiers"])
        XCTAssertTrue(calls.filter { $0.tool == "type_text" }.allSatisfy { !($0.arguments["text"] as? String ?? "").contains("\n") })
        assertMuseBackground(calls)
    }

    func testMuseFixtureComparisonsKeepIndependentSideChatsAndResumeSavedID() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-muse-demo-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("state.json"), a = UUID(), b = UUID()
        let session = WebAgentSession(provider: .museApp, storageURL: file, fixture: true)
        session.setEnabled(true)
        await session.connectDesktopConversation()
        let first = await session.send("First comparison", comparisonID: a)
        let second = await session.send("Second comparison", comparisonID: b)
        let aid = try XCTUnwrap(session.state.museAppConversations[a.uuidString]?.threadID)
        let bid = try XCTUnwrap(session.state.museAppConversations[b.uuidString]?.threadID)
        XCTAssertNotEqual(aid, bid)
        XCTAssertNotEqual(first?.conversationURL, second?.conversationURL)
        session.beginShutdown()
        let reopened = WebAgentSession(provider: .museApp, storageURL: file, fixture: true)
        let ready = await reopened.openComparison(a)
        XCTAssertTrue(ready)
        let resumed = await reopened.send("Continue first", comparisonID: a)
        XCTAssertEqual(resumed?.conversationURL, first?.conversationURL)
        XCTAssertEqual(reopened.state.museAppConversations[a.uuidString]?.threadID, aid)
        XCTAssertEqual(reopened.state.localConversations[a.uuidString]?.count, 4)
        XCTAssertEqual(reopened.state.localConversations[b.uuidString]?.count, 2)
        XCTAssertTrue(reopened.state.localSessionIDs.isEmpty)
        XCTAssertFalse(WebProvider.museApp.sharesOneConversation)
        reopened.beginShutdown()
    }

    func testMuseRejectsCarriageReturnBeforeAnyDriverInputCanSubmitEarly() async throws {
        let fixture = try driver([])
        defer { fixture.remove() }
        let error = await failure { try await self.museAdapter(fixture).reply("First\rSecond", binding: .init(comparisonID: UUID(), threadID: UUID(), title: "Saved")) { _ in XCTFail("No submission") } }
        XCTAssertTrue(error.contains("control characters"), error)
        XCTAssertTrue(try fixture.calls().isEmpty)
    }

    func testMusePreservesEmojiJoinersAndCombiningMarksInPreparedText() async throws {
        let owner = UUID(), thread = UUID(), text = "Emoji 👩‍💻 and e\u{301}"
        var initial = windows(); initial["native"] = try object(museObservation(thread: thread))
        var typing = try museStep("type_text", observation: museObservation(thread: thread, draft: text))
        typing["arguments"] = ["text": text]
        let fixture = try driver([apps(.muse), initial, museComposerCapture(), typing,
            try museStep("press_key", observation: museObservation(thread: thread, messages: [.init(role: .user, text: text), .init(role: .assistant, text: "Unicode preserved")]))])
        defer { fixture.remove() }
        let answer = try await museAdapter(fixture).reply(text, binding: .init(comparisonID: owner, threadID: thread, title: "Saved")) { _ in }
        XCTAssertEqual(answer, "Unicode preserved")
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "type_text" }.count, 1)
        XCTAssertEqual(calls.filter { $0.tool == "press_key" }.count, 1)
        assertMuseBackground(calls)
    }

    func testMuseUnfocusedWrapperPreparesWithoutInputAndTargetsFirstTextExplicitly() async throws {
        let owner = UUID(), thread = UUID()
        var initial = windows(), unfocused = museObservation(thread: thread)
        unfocused.composerFocused = false
        initial["native"] = try object(unfocused)
        let typing = try museStep("type_text", observation: museObservation(thread: thread, draft: prompt))
        let fixture = try driver([apps(.muse), initial, apps(.muse), initial,
            museComposerCapture(), typing,
            try museStep("press_key", observation: museObservation(thread: thread, messages: [.init(role: .user, text: prompt), .init(role: .assistant, text: "Targeted reply")]))])
        defer { fixture.remove() }
        let adapter = museAdapter(fixture)
        let binding = try await adapter.prepare(comparisonID: owner, binding: .init(comparisonID: owner, threadID: thread, title: "Saved"))
        assertNoInput(try fixture.calls())
        let answer = try await adapter.reply(prompt, binding: binding) { _ in }
        XCTAssertEqual(answer, "Targeted reply")
        let calls = try await finishedCalls(fixture)
        let typed = try XCTUnwrap(calls.first { $0.tool == "type_text" })
        XCTAssertNil(typed.arguments["element_token"])
        XCTAssertNil(typed.arguments["capture_id"], "type_text does not accept capture_id in driver 0.38")
        XCTAssertEqual(typed.arguments["x"] as? Int, 510)
        XCTAssertEqual(typed.arguments["y"] as? Int, 750)
        XCTAssertFalse(calls.contains { $0.tool == "click" }, "The compound button must never be pressed to focus it")
        XCTAssertEqual(calls.filter { $0.tool == "press_key" }.count, 1)
        assertMuseBackground(calls)
    }

    func testMuseInputCaptureRejectsMissingImageMovedWindowAndChangedChatBeforeTyping() async throws {
        for fault in ["missing_image", "window_moved", "chat_changed"] {
            let thread = UUID()
            var initial = windows(); initial["native"] = try object(museObservation(thread: thread))
            var capture = museComposerCapture()
            if fault == "missing_image" { capture["capture"] = "missing" }
            else {
                var changed = museObservation(thread: fault == "chat_changed" ? UUID() : thread)
                if fault == "window_moved" { changed.windowBounds = .init(x: 300, y: 100, width: 800, height: 600) }
                capture["native"] = try object(changed)
            }
            let fixture = try driver([apps(.muse), initial, capture])
            defer { fixture.remove() }
            _ = await failure {
                try await self.museAdapter(fixture).reply(self.prompt, binding: .init(comparisonID: UUID(), threadID: thread, title: "Saved")) { _ in
                    XCTFail("An untyped draft cannot own a thread")
                }
            }
            let calls = try await finishedCalls(fixture)
            assertNoInput(calls)
            let path = try XCTUnwrap(calls.last { $0.tool == "get_window_state" }?.arguments["screenshot_out_file"] as? String)
            XCTAssertFalse(FileManager.default.fileExists(atPath: path), "Private capture must be cleaned up for \(fault)")
        }
    }

    func testMuseInvalidMissingOrMismatchedCaptureCannotClickSavedChat() async throws {
        let thread = UUID(), owner = UUID()
        let list: [String: Any] = ["elements": [element("AXButton", "New side chat"), element("AXButton", "Saved"), element("AXSplitter", "Resize panel")]]
        for fault in ["invalid", "missing", "missing_capture_id", "wrong_window", "wrong_dimensions", "wrong_path", "outside", "window_moved", "overflow"] {
            let other = UUID()
            var initial = windows(); initial["native"] = try object(museObservation(thread: other))
            var capture = capturedNavigation(list)
            var result = capture["result"] as! [String: Any]
            if fault == "invalid" { result["screenshot_frame_valid"] = false }
            if fault == "missing_capture_id" { result.removeValue(forKey: "capture_id") }
            if fault == "wrong_window" { result["window_id"] = 999 }
            if fault == "wrong_dimensions" { result["screenshot_width"] = 1500 }
            if fault == "outside" {
                var elements = result["elements"] as! [[String: Any]]
                elements[1]["frame"] = ["x": 0, "y": 0, "w": 20, "h": 20]
                result["elements"] = elements
            }
            if fault == "overflow" {
                result["window_bounds"] = ["x": 1e308, "y": 0.0, "width": 1e308, "height": 600.0]
                var elements = result["elements"] as! [[String: Any]]
                elements[1]["frame"] = ["x": 1e308, "y": 10.0, "w": 1e308, "h": 40.0]
                result["elements"] = elements
            }
            capture["result"] = result
            if fault == "missing" { capture["capture"] = "missing" }
            if fault == "wrong_path" { capture["capture"] = "wrong_path" }
            if fault == "window_moved" {
                var moved = museObservation(thread: other); moved.windowBounds = .init(x: 300, y: 100, width: 800, height: 600)
                capture["native"] = try object(moved)
            }
            let fixture = try driver([apps(.muse), initial, snapshot(list), capture])
            defer { fixture.remove() }
            let error = await failure { try await self.museAdapter(fixture).prepare(comparisonID: owner, binding: .init(comparisonID: owner, threadID: thread, title: "Saved")) }
            XCTAssertTrue(error.contains("geometry"), "\(fault): \(error)")
            let calls = try await finishedCalls(fixture)
            XCTAssertFalse(calls.contains { ["click", "type_text", "press_key"].contains($0.tool) })
            let path = try XCTUnwrap(calls.last { $0.tool == "get_window_state" }?.arguments["screenshot_out_file"] as? String)
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
    }

    func testMuseNewSideChatCanPrepareBeforeWebKitReportsEditorFocus() async throws {
        var initial = windows()
        var main = museObservation(); main.url = URL(string: "https://muse.ai/")!
        initial["native"] = try object(main)
        let button = element("AXButton", "New side chat", token: "s00000001:new")
        var blank = museObservation(); blank.composerFocused = false
        let fixture = try driver([apps(.muse), initial, snapshot(["elements": [button]]),
                                  try museStep("click", observation: blank, token: "s00000001:new")])
        defer { fixture.remove() }
        let prepared = try await museAdapter(fixture).prepare(comparisonID: UUID(), binding: nil)
        XCTAssertNil(prepared.threadID)
        let calls = try await finishedCalls(fixture)
        XCTAssertEqual(calls.filter { $0.tool == "click" }.count, 1, "Only create the chat; do not press its compound composer")
        XCTAssertFalse(calls.contains { $0.tool == "type_text" || $0.tool == "press_key" })
        assertMuseBackground(calls)
    }

    private func museComposerCapture() -> [String: Any] {
        var field = element("AXButton", "Message Attach file Dictate a message Send", token: "s00000001:composer")
        field["frame"] = ["x": 240, "y": 580, "w": 600, "h": 40]
        return capturedNavigation(["elements": [field]])
    }

    private func capturedNavigation(_ state: [String: Any]) -> [String: Any] {
        var result = state
        var index = 0
        result["elements"] = (state["elements"] as! [[String: Any]]).map { element in
            var element = element
            if element["role"] as? String == "AXButton", element["label"] as? String != "New side chat", element["frame"] == nil {
                element["frame"] = ["x": 240, "y": 150 + index * 40, "w": 200, "h": 40]
                index += 1
            }
            return element
        }
        result["pid"] = 4242; result["window_id"] = 101
        result["window_bounds"] = ["x": 200, "y": 100, "width": 800, "height": 600]
        result["screenshot_frame_valid"] = true
        result["capture_id"] = "muse-resized-capture"
        result["screenshot_width"] = 1200; result["screenshot_height"] = 900
        result["screenshot_scale"] = 2 // The returned PNG was resized; do not multiply by this.
        var step = snapshot(result)
        step["capture"] = "valid"
        return step
    }

    private func museObservation(thread: UUID? = nil, draft: String = "", messages: [MuseAppMessage] = [], title: String = "Muse side chat") -> MuseAppObservation {
        .init(url: thread.map { URL(string: "https://muse.ai/thread/\($0.uuidString)")! } ?? MuseSideChatBinding.newURL,
              draft: draft, composerFocused: true, messages: messages, windowBounds: .init(x: 200, y: 100, width: 800, height: 600), title: title)
    }
    private func object(_ observation: MuseAppObservation) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(observation)) as! [String: Any]
    }
    private func setNative(_ observation: MuseAppObservation, in fixture: DriverFixture) throws {
        try JSONEncoder().encode(observation).write(to: fixture.directory.appendingPathComponent("native.json"), options: .atomic)
    }
    private func museStep(_ tool: String, observation: MuseAppObservation, token: String? = nil) throws -> [String: Any] {
        var result = step(tool, ["effect": "unverifiable", "delivered_chars": 0], arguments: token.map { ["element_token": $0] } ?? [:])
        result["native"] = try object(observation)
        return result
    }
    private func museCreationSteps(owner: UUID, thread: UUID, answer: String?) throws -> [[String: Any]] {
        var initial = windows()
        var main = museObservation(); main.url = URL(string: "https://muse.ai/")!; main.composerFocused = false
        initial["native"] = try object(main)
        let reference = "[msgblast request <attempt-id>]"
        let wire = reference + "\n\n" + prompt
        var messages = [MuseAppMessage(role: .user, text: wire)]
        if let answer { messages.append(.init(role: .assistant, text: answer)) }
        func input(_ tool: String, draft: String, arguments: [String: Any]) throws -> [String: Any] {
            var step = try museStep(tool, observation: museObservation(draft: draft))
            step["arguments"] = arguments
            return step
        }
        return [apps(.muse), initial,
                snapshot(["elements": [element("AXButton", "New side chat", token: "s00000001:new")]]),
                try museStep("click", observation: museObservation(), token: "s00000001:new"),
                apps(.muse), windows(), museComposerCapture(),
                try input("type_text", draft: reference, arguments: ["text": reference]),
                try input("press_key", draft: reference + "\n\n", arguments: ["key": "return", "modifiers": ["shift"]]),
                try input("press_key", draft: reference + "\n\n\n", arguments: ["key": "return", "modifiers": ["shift"]]),
                try input("type_text", draft: wire, arguments: ["text": prompt]),
                try museStep("press_key", observation: museObservation(thread: thread, messages: messages))]
    }
    private final class MuseReadFault: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int
        init(failures: Int = 1) { remaining = failures }
        func shouldFail() -> Bool { lock.withLock { guard remaining > 0 else { return false }; remaining -= 1; return true } }
    }
    private func museAdapter(_ fixture: DriverFixture, timeout: Duration = .seconds(3), transientWindowFailure: Bool = false, transientReadFailures: Int = 0, requiresDriverSnapshot: Bool = false,
                             replyClock: DesktopAppWorkflow.ReplyClock = .init(ContinuousClock()), transformNative: @escaping @Sendable (MuseAppObservation) -> MuseAppObservation = { $0 }) -> MuseAppConversation {
        let fault = MuseReadFault(failures: transientWindowFailure ? 1 : transientReadFailures)
        let url = fixture.directory.appendingPathComponent("native.json")
        return MuseAppConversation(executable: fixture.executable, timing: .init(pollInterval: .milliseconds(5), stableDuration: .milliseconds(60), replyTimeout: timeout, callTimeout: 3, replyClock: replyClock)) { target in
            guard target.pid == 4242, target.window == 101 else { throw CocoaError(.fileReadUnknown) }
            if requiresDriverSnapshot, !(try fixture.calls()).contains(where: { $0.tool == "get_window_state" }) {
                throw DesktopAppError.unavailable("Muse's accessibility window has not been initialized")
            }
            let observation = try JSONDecoder().decode(MuseAppObservation.self, from: Data(contentsOf: url))
            if observation.url == MuseSideChatBinding.newURL, fault.shouldFail() {
                throw DesktopAppError.unavailable("Muse's empty composer could not be confirmed.")
            }
            return transformNative(observation)
        }
    }
    private func assertMuseBackground(_ calls: [DriverCall], file: StaticString = #filePath, line: UInt = #line) {
        for call in calls where ["click", "type_text", "press_key"].contains(call.tool) {
            XCTAssertEqual(call.arguments["delivery_mode"] as? String, "background", file: file, line: line)
            XCTAssertEqual(call.arguments["pid"] as? Int, 4242, file: file, line: line)
            XCTAssertEqual(call.arguments["window_id"] as? Int, 101, file: file, line: line)
        }
    }

    private final class FirstCall: @unchecked Sendable {
        private let lock = NSLock()
        private var available = true
        func take() -> Bool { lock.withLock { defer { available = false }; return available } }
    }
    private func adapter(_ fixture: DriverFixture, replyTimeout: Duration = .seconds(3), callTimeout: TimeInterval = 3, delivery: DesktopAppConversation.Delivery = .background,
                         replyClock: DesktopAppWorkflow.ReplyClock = .init(ContinuousClock()),
                         confirmHostFocus: @escaping @Sendable (DesktopAppConversation.Target) async -> Bool = { _ in false },
                         runProcess: @escaping DesktopAppConversation.ProcessRunner = DesktopAppConversation.execute) -> DesktopAppConversation {
        let file = fixture.directory.appendingPathComponent("grok-native.json")
        return DesktopAppConversation(executable: fixture.executable, timing: .init(pollInterval: .milliseconds(5), stableDuration: .milliseconds(60), replyTimeout: replyTimeout, callTimeout: callTimeout, replyClock: replyClock), delivery: delivery, runProcess: runProcess, confirmHostFocus: confirmHostFocus, readGrok: { target in
            guard target.pid == 4242, target.window == 101 else { throw CocoaError(.fileReadUnknown) }
            let data = try Data(contentsOf: file)
            let raw = try JSONDecoder().decode(GrokBotNativeState.self, from: data)
            let attributes = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let draft = (attributes["emptyEditor"] as? Bool).map { GrokBotAppProfile.draftValue(raw.draft, emptyEditor: $0) } ?? raw.draft
            let focus = (attributes["applicationRole"] as? String).map { role in
                DesktopNativeFocus.observed(applicationMatches: attributes["applicationFocusMatches"] as? Bool, applicationRole: role,
                                            elementFocused: attributes["editorFocused"] as? Bool)
            } ?? raw.composerFocused
            return .init(name: raw.name, draft: draft, composerFocused: focus)
        })
    }
    private func sendSteps() -> [[String: Any]] {
        [apps(), windows(), snapshot(grok()), step("type_text", [:]), snapshot(grok(draft: prompt, token: "s00000002")), step("click", [:])]
    }
    private func step(_ tool: String, _ result: [String: Any], arguments: [String: String] = [:]) -> [String: Any] {
        ["tool": tool, "result": result, "arguments": arguments]
    }
    private func apps(_ app: DesktopAppProvider = .grokBot) -> [String: Any] {
        step("list_apps", ["apps": [["bundle_id": app.bundleID, "pid": 4242, "running": true]]])
    }
    private func windows() -> [String: Any] {
        step("list_windows", ["windows": [["window_id": 101, "title": "Fixture app", "is_on_screen": false, "on_current_space": false, "space_ids": [1], "bounds": ["width": 800, "height": 600]]]])
    }
    private func snapshot(_ result: [String: Any], repeating: Bool = false) -> [String: Any] {
        var step = step("get_window_state", result)
        step["repeat"] = repeating
        if let native = result["_grok_native"] { step["grok_native"] = native; step["capture"] = "valid" }
        return step
    }
    private func element(_ role: String, _ label: String, value: String? = nil, token: String = "s00000001:item") -> [String: Any] {
        var result: [String: Any] = ["role": role, "label": label, "element_token": token, "enabled": true]
        if let value { result["value"] = value }
        return result
    }
    private func wabi(draft: String = "", reply: String? = nil, token: String = "s00000001") -> [String: Any] {
        var body = [element("AXHeading", "Wabi", value: "2"), element("AXStaticText", "Sidebar preview"), element("AXSplitter", "Resize sidebar")]
        if let reply {
            body += [element("AXStaticText", prompt), element("AXPopUpButton", "Add reaction"),
                     element("AXStaticText", "1:41 PM"), element("AXStaticText", "Read"),
                     element("AXStaticText", reply), element("AXPopUpButton", "Add reaction")]
        }
        var composer = element("AXTextArea", "Message", value: draft.isEmpty ? "Say something…" : draft, token: "\(token):composer")
        composer["frame"] = ["x": 240, "y": 600, "w": 640, "h": 40]
        body += [composer, element("AXButton", "Send", token: "\(token):send")]
        return ["elements": body, "returned_element_count": body.count, "total_element_count": body.count]
    }
    private func grok(draft: String = "", reply: String? = nil, name: String = "Fixture Bot", token: String = "s00000001", previousReply: String? = nil, generating: Bool = false, bots: [String]? = nil, focused: Bool = true, outgoingPrompt: String? = nil) -> [String: Any] {
        var list = element("AXList", ""); list["element_index"] = 1
        var body = [list]
        for (index, bot) in (bots ?? [name]).enumerated() {
            var item = element("AXButton", bot, token: "\(token):bot\(index)")
            item["element_index"] = index + 2; item["parent_index"] = 1
            body.append(item)
        }
        var heading = element("AXHeading", name, value: "2"); heading["element_index"] = 100
        var details = element("AXButton", "View conversation details"); details["parent_index"] = 100
        body += [element("AXSplitter", "Resize sidebar"), heading, details,
                 element("AXStaticText", "You"), element("AXStaticText", "Earlier unrelated question"),
                 element("AXStaticText", name), element("AXStaticText", "Earlier unrelated answer")]
        if let previousReply {
            body += [element("AXStaticText", "You"), element("AXStaticText", outgoingPrompt ?? prompt), element("AXStaticText", name), element("AXStaticText", previousReply)]
        }
        if let reply {
            body += [element("AXStaticText", "You"), element("AXStaticText", outgoingPrompt ?? prompt), element("AXStaticText", name), element("AXStaticText", reply)]
        }
        var composer = element("AXTextArea", "Prompt", value: draft.isEmpty ? "Message \(name)" : draft.trimmingCharacters(in: .whitespacesAndNewlines), token: "\(token):composer")
        composer["frame"] = ["x": 240, "y": 600, "w": 640, "h": 40]
        body += [composer, element("AXButton", "Send message", token: "\(token):send")]
        if generating { body.append(element("AXButton", "Stop generating")) }
        return ["elements": body, "returned_element_count": body.count, "total_element_count": body.count,
                "_grok_native": ["name": name, "draft": draft.isEmpty ? "\n" : draft.hasSuffix("\n") ? draft + "\n" : draft, "emptyEditor": draft.isEmpty, "composerFocused": focused],
                "pid": 4242, "window_id": 101,
                "window_bounds": ["x": 200, "y": 100, "width": 800, "height": 600],
                "screenshot_frame_valid": true, "screenshot_width": 1200, "screenshot_height": 900]
    }
    private func failure<T>(_ operation: () async throws -> T) async -> String {
        do { _ = try await operation(); XCTFail("Expected the adapter to refuse this workflow"); return "" }
        catch { return error.localizedDescription }
    }
    private func assertNoInput(_ calls: [DriverCall], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(calls.allSatisfy { ["list_apps", "list_windows", "get_window_state", "end_session"].contains($0.tool) }, "Unexpected driver mutation: \(calls.map(\.tool))", file: file, line: line)
    }
    private func assertFocusTransaction(_ calls: [DriverCall], file: StaticString = #filePath, line: UInt = #line) {
        let focus = calls.filter { $0.tool == "bring_to_front" }
        XCTAssertEqual(focus.count, 2, "Return exactly once, including final cleanup", file: file, line: line)
        XCTAssertEqual(focus.first?.arguments["pid"] as? Int, 4242, file: file, line: line)
        XCTAssertEqual(focus.first?.arguments["window_id"] as? Int, 101, file: file, line: line)
        XCTAssertEqual(focus.last?.arguments["pid"] as? Int, fixtureHost.pid, file: file, line: line)
        XCTAssertEqual(focus.last?.arguments["window_id"] as? Int, fixtureHost.window, file: file, line: line)
        let mutations = calls.enumerated().filter { ["type_text", "click", "press_key"].contains($0.element.tool) }
        let activated = calls.firstIndex { $0.tool == "bring_to_front" }!
        let restored = calls.lastIndex { $0.tool == "bring_to_front" }!
        for (index, call) in mutations {
            XCTAssertGreaterThan(index, activated, file: file, line: line)
            XCTAssertLessThan(index, restored, file: file, line: line)
            XCTAssertEqual(call.arguments["pid"] as? Int, 4242, file: file, line: line)
            XCTAssertEqual(call.arguments["window_id"] as? Int, 101, file: file, line: line)
            XCTAssertEqual(call.arguments["delivery_mode"] as? String, "background", "Keep foreground ownership across calls instead of restoring between chunks", file: file, line: line)
        }
    }
    private func assertBackgroundTargets(_ calls: [DriverCall], file: StaticString = #filePath, line: UInt = #line) {
        for call in calls where ["type_text", "click", "press_key"].contains(call.tool) {
            XCTAssertEqual(call.arguments["pid"] as? Int, 4242, file: file, line: line)
            XCTAssertEqual(call.arguments["window_id"] as? Int, 101, file: file, line: line)
            XCTAssertEqual(call.arguments["delivery_mode"] as? String, "background", file: file, line: line)
        }
        XCTAssertEqual(Set(calls.compactMap { $0.arguments["session"] as? String }).count, 1, file: file, line: line)
    }
    private func waitForCall(_ tool: String, in fixture: DriverFixture, count: Int = 1) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if try fixture.calls().filter({ $0.tool == tool }).count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Fake driver did not reach \(tool)")
        throw CocoaError(.fileReadUnknown)
    }
    private func finishedCalls(_ fixture: DriverFixture, cleanupCount: Int = 1) async throws -> [DriverCall] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            let calls = try fixture.calls()
            if calls.filter({ $0.tool == "end_session" }).count >= cleanupCount { return calls }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Driver lifecycle session was not cleaned up")
        return try fixture.calls()
    }
    private struct DriverCall {
        let tool: String
        let arguments: [String: Any]
        let pid: Int
    }
    private struct DriverFixture: Sendable {
        let directory: URL
        var executable: URL { directory.appendingPathComponent("cua-driver") }
        func remove() { try? FileManager.default.removeItem(at: directory) }
        func replacePlan(_ steps: [[String: Any]]) throws {
            try JSONSerialization.data(withJSONObject: steps).write(to: directory.appendingPathComponent("plan.json"), options: .atomic)
            try Data("0".utf8).write(to: directory.appendingPathComponent("index"), options: .atomic)
        }
        func calls() throws -> [DriverCall] {
            let url = directory.appendingPathComponent("calls.jsonl")
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
                let value = try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
                return DriverCall(tool: value["tool"] as! String, arguments: value["arguments"] as! [String: Any], pid: value["pid"] as! Int)
            }
        }
    }
    private func readinessDriver(_ fixture: DriverFixture, app: DesktopAppProvider) throws -> DesktopAppConversation {
        // Session window readiness is separate from the adapter's ordered action plan.
        let executable = fixture.directory.appendingPathComponent("readiness-driver")
        try Data("""
        #!/usr/bin/env python3
        import json,sys,time
        assert len(sys.argv)==4 and sys.argv[1]=='call'
        tool=sys.argv[2];args=json.loads(sys.argv[3])
        if tool=='list_apps':
            assert args=={}
            print(json.dumps({'apps':[{'bundle_id':'\(app.bundleID)','pid':42,'running':True}]}))
        elif tool=='list_windows':
            assert args=={'pid':42}
            print(json.dumps({'windows':[{'window_id':101,'title':'Fixture app','is_on_screen':True,'bounds':{'width':800,'height':600}}]}))
        else: raise AssertionError('Unexpected readiness action: '+tool)
        sys.stdout.flush();time.sleep(.02)
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return DesktopAppConversation(executable: executable)
    }
    private func driver(_ steps: [[String: Any]]) throws -> DriverFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-driver-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let fixture = DriverFixture(directory: directory)
        try fixture.replacePlan(steps)
        try Data(Self.driverScript.utf8).write(to: fixture.executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.executable.path)
        return fixture
    }
    private static let driverScript = #"""
    #!/usr/bin/env python3
    import fcntl, json, os, pathlib, struct, sys, time, zlib
    root = pathlib.Path(__file__).parent
    if len(sys.argv) != 4 or sys.argv[1] != "call":
        raise SystemExit(90)
    tool, arguments = sys.argv[2], json.loads(sys.argv[3])
    if tool == "type_text":
        allowed = {"session", "pid", "window_id", "text", "element_token", "x", "y", "delay_ms", "scope", "target", "delivery_mode"}
        if set(arguments) - allowed:
            print(json.dumps({"refusal": {"code": "invalid_arguments"}, "status": "refused"}))
            raise SystemExit(92)
    with (root / "lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with (root / "calls.jsonl").open("a") as log:
            log.write(json.dumps({"tool": tool, "arguments": arguments, "pid": os.getpid()}) + "\n")
        if tool == "end_session":
            print(json.dumps({"active": False}))
            raise SystemExit(0)
        index = int((root / "index").read_text())
        plan = json.loads((root / "plan.json").read_text())
        expected = plan[index] if index < len(plan) else {}
        if "<attempt-id>" in json.dumps(expected):
            # The real session durably creates the request ID before driver input.
            request_id = json.loads((root / "state.json").read_text())["attempts"][0]["id"].lower()
            expected = json.loads(json.dumps(expected).replace("<attempt-id>", request_id))
        if expected.get("tool") != tool or any(arguments.get(k) != v for k, v in expected.get("arguments", {}).items()):
            print(json.dumps({"isError": True, "message": "Unexpected fake-driver call"}))
            raise SystemExit(91)
        if "native" in expected:
            (root / "native.json").write_text(json.dumps(expected["native"]))
        if "grok_native" in expected:
            (root / "grok-native.json").write_text(json.dumps(expected["grok_native"]))
        if expected.get("remove_grok_native"):
            (root / "grok-native.json").unlink(missing_ok=True)
        if not expected.get("repeat"):
            (root / "index").write_text(str(index + 1))
    if expected.get("wait_for_release"):
        deadline = time.monotonic() + 30
        while not (root / "release").exists() and time.monotonic() < deadline:
            time.sleep(0.01)
    result = expected["result"]
    if "capture" in expected and "screenshot_out_file" in arguments:
        capture_path = pathlib.Path(arguments["screenshot_out_file"])
        result["screenshot_file_path"] = str(capture_path.resolve() if expected["capture"] != "wrong_path" else capture_path.parent / "other.png")
        if expected["capture"] != "missing":
            width, height = 1200, 900
            def chunk(kind, data):
                body = kind + data
                return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xffffffff)
            pixels = (b"\x00" + b"\xff\xff\xff" * width) * height
            png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b"")
            capture_path.write_bytes(png)
    print(json.dumps(result))
    raise SystemExit(expected.get("exit_code", 0))
    """#
}
