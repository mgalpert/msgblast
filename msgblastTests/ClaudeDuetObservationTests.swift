import XCTest
@testable import msgblastCore

final class ClaudeDuetObservationTests: XCTestCase {
    private let composer = DesktopAppSnapshot.Element.Frame(x: 805, y: 760, w: 692, h: 48)
    private let prompt = "msgblast Duet test 1. Reply with exactly: ACK 1"

    private func frame(_ x: Double, _ y: Double, _ w: Double = 220, _ h: Double = 22) -> DesktopAppSnapshot.Element.Frame {
        .init(x: x, y: y, w: w, h: h)
    }
    private func text(_ value: String, x: Double, y: Double, h: Double = 22) -> ClaudeAXNode {
        .init(role: "AXStaticText", value: value, frame: frame(x, y, 220, h))
    }
    private func transcript(draft: String = "Message Claude Duet") -> ClaudeAXNode {
        let pageChildren: [ClaudeAXNode] = [
            .init(role: "AXToolbar", label: "Page tools", children: [.init(role: "AXButton", label: "Back to Claude")]),
            .init(role: "AXButton", label: "Show sidebar"),
            .init(role: "AXButton", label: "Tasks"),
            .init(role: "AXButton", label: "Make"),
            .init(role: "AXButton", label: "Sessions"),
            text("Sidebar notes", x: 40, y: 140),
            .init(role: "AXStaticText", value: "First question", frame: frame(1019, 500, 480, 40)),
            text("Off screen reply", x: 805, y: 0, h: 1),
            text("Today 2:35 PM", x: 805, y: 80),
            text("Yesterday 8:10 AM", x: 805, y: 100),
            .init(role: "AXHeading", label: "Tuesday 8:11 AM", value: "2"),
            text("Good morning", x: 845, y: 180),
            .init(role: "AXList", frame: frame(805, 210, 360, 48), children: [
                .init(role: "AXListMarker", value: "•"),
                text("Bring a jacket", x: 820, y: 214),
                .init(role: "AXLink", label: "task link", frame: frame(820, 236, 80, 18))
            ]),
            .init(role: "AXButton", label: "Replying to: Good morning"),
            text(prompt, x: 1320, y: 420),
            text("ACK 1", x: 805, y: 520),
            .init(role: "AXHeading", label: "Tuesday 8:11 AM"),
            text("Still here", x: 805, y: 560),
            .init(role: "AXLink", label: "Claude Duet is AI and can make mistakes."),
            .init(role: "AXPopUpButton", label: "Add context"),
            .init(role: "AXCheckBox", label: "Press and hold to record"),
            .init(role: "AXPopUpButton", label: "Microphone"),
            .init(role: "AXTextArea", label: "Message Claude Duet", value: draft, frame: composer)
        ]
        return .init(role: "AXWindow", children: [
            .init(role: "AXWebArea", url: URL(string: "file:///Applications/Claude.app/Contents/Resources/app.asar/index.html")),
            .init(role: "AXWebArea", label: "Claude Duet - Claude", url: URL(string: "https://claude.ai/messages")!, children: pageChildren)
        ])
    }
    private func previewButton() -> ClaudeAXNode {
        .init(role: "AXButton", label: "Claude Duet, Preview", frame: frame(24, 90, 180, 32), children: [
            .init(role: "AXStaticText", value: "Claude Duet"),
            .init(role: "AXStaticText", value: "Preview")
        ])
    }

    func testDuetURLIsSeparateFromClaudeChats() throws {
        let messages = URL(string: "https://claude.ai/messages")!
        XCTAssertTrue(ClaudeDuetURL.isDuet(messages))
        XCTAssertEqual(WebProvider.claudeDuetApp.homeURL, messages)
        XCTAssertEqual(WebProvider.claudeDuetApp.name, "Claude Duet")
        XCTAssertEqual(WebProvider.claudeDuetApp.desktopApp, .claudeDuet)
        XCTAssertEqual(DesktopAppProvider.claudeDuet.name, "Claude Duet")
        XCTAssertEqual(DesktopAppProvider.claudeDuet.bundleIDs, DesktopAppProvider.claude.bundleIDs)
        XCTAssertEqual(DesktopAppProvider.claudeDuet.bundleIDs, ["com.anthropic.claudefordesktop"])
        XCTAssertTrue(WebProvider.claudeDuetApp.sharesOneConversation)
        XCTAssertFalse(WebProvider.claudeDuetApp.supportsCopies)
        XCTAssertFalse(ClaudeChatURL.isChat(messages))
        XCTAssertFalse(WebProvider.claudeApp.isChatURL(messages))
        XCTAssertFalse(WebProvider.claudeApp.isSavedConversation(messages))
        XCTAssertNil(WebProvider.claudeApp.canonicalConversationURL(messages))
        for value in ["https://claude.ai/messages?x=1", "https://claude.ai/messages/", "https://claude.ai/new",
                      "https://claude.ai/chat/00000000-0000-0000-0000-000000000001", "https://example.com/messages", "http://claude.ai/messages"] {
            XCTAssertFalse(ClaudeDuetURL.isDuet(URL(string: value)!), value)
        }
        XCTAssertThrowsError(try ClaudeAppObservation(root: transcript())) { error in
            XCTAssertTrue(error is ClaudeObservationError)
        }
    }

    func testComposerDraftAndAuthorOrderIgnoreChrome() throws {
        let empty = try ClaudeDuetObservation(root: transcript())
        XCTAssertEqual(empty.url.absoluteString, "https://claude.ai/messages")
        XCTAssertEqual(empty.draft, "")
        XCTAssertEqual(empty.messages, [
            .init(author: .user, text: "First question"),
            .init(author: .agent, text: "Off screen reply"),
            .init(author: .agent, text: "Good morning\n•\nBring a jacket\ntask link"),
            .init(author: .user, text: prompt),
            .init(author: .agent, text: "ACK 1"),
            .init(author: .agent, text: "Still here")
        ])
        let drafted = try ClaudeDuetObservation(root: transcript(draft: "See you there"))
        XCTAssertEqual(drafted.draft, "See you there")
        XCTAssertEqual(drafted.messages, empty.messages)
        XCTAssertThrowsError(try ClaudeDuetObservation(root: .init(role: "AXWindow", children: [
            .init(role: "AXWebArea", url: URL(string: "https://claude.ai/messages"), children: [text("ACK 1", x: 805, y: 20)])
        ]))) { error in XCTAssertTrue(error is ClaudeObservationError) }
    }

    func testReplyAfterPromptIgnoresEarlierAgentMessages() throws {
        let messages = try ClaudeDuetObservation(root: transcript()).messages
        XCTAssertEqual(ClaudeDuetObservation.agentReplies(after: "  \(prompt)  ", in: messages), ["ACK 1", "Still here"])
        XCTAssertEqual(ClaudeDuetObservation.agentReplies(after: "First question", in: messages), ["Off screen reply", "Good morning\n•\nBring a jacket\ntask link"])
        XCTAssertEqual(ClaudeDuetObservation.agentReplies(after: "Good morning", in: messages), [])
        XCTAssertEqual(ClaudeDuetObservation.agentReplies(after: "   ", in: messages), [])
    }

    func testOpenPressesPreviewUntilTheDuetURLIsShowing() throws {
        let button = previewButton()
        let closed = ClaudeAXNode(role: "AXWindow", children: [
            .init(role: "AXWebArea", url: URL(string: "file:///Applications/Claude.app/Contents/Resources/app.asar/index.html"), children: [button]),
            .init(role: "AXWebArea", label: "msgblast - Claude Code", url: URL(string: "https://claude.ai/new"))
        ])
        guard case .press(let pressed) = try ClaudeDuetOpen.decide(closed) else { return XCTFail("Expected the Duet preview button") }
        XCTAssertEqual(pressed.role, "AXButton")
        XCTAssertEqual(pressed.label, "Claude Duet, Preview")
        XCTAssertEqual(pressed.frame, button.frame)
        let open = ClaudeAXNode(role: "AXWindow", children: closed.children + [
            .init(role: "AXWebArea", url: URL(string: "https://claude.ai/messages"))
        ])
        guard case .alreadyOpen = try ClaudeDuetOpen.decide(open) else { return XCTFail("An open Duet URL needs no press") }
        XCTAssertThrowsError(try ClaudeDuetOpen.decide(.init(role: "AXWindow", children: [
            .init(role: "AXWebArea", url: URL(string: "https://claude.ai/new"))
        ]))) { error in XCTAssertTrue(error is ClaudeObservationError) }
    }

    func testSendingUsesTheDedicatedAdapter() async {
        do {
            _ = try await DesktopAppConversation.shared.reply("Hello", app: .claudeDuet, binding: .init(name: "Claude Duet"))
            XCTFail("Sending must fail closed")
        } catch {
            XCTAssertEqual(error.localizedDescription, "This app requires its dedicated chat adapter.")
        }
    }

    func testRepeatedPromptNeedsANewCopyBeforeItsReplyCounts() {
        let old: [ClaudeDuetMessage] = [.init(author: .user, text: prompt), .init(author: .agent, text: "ACK 1")]
        XCTAssertEqual(ClaudeDuetObservation.agentReplies(after: prompt, in: old, sentAfter: 1), [])
        let sent = old + [.init(author: .agent, text: "Unrelated update"), .init(author: .user, text: prompt), .init(author: .agent, text: "ACK 1 again")]
        XCTAssertEqual(ClaudeDuetObservation.agentReplies(after: prompt, in: sent, sentAfter: 1), ["ACK 1 again"])
    }
}
