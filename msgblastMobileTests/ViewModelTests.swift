import CryptoKit
import XCTest
import msgblastRemoteProtocol
@testable import msgblastMobileKit

/// A fixed instant, so no test depends on when it runs (Friday 15 January 2027, 08:00 UTC).
private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

final class PresenterTests: XCTestCase {
    func testInboxChipsAndThreadsFromRecordedEvents() throws {
        let state = try RecordedFixtures.reduce(["send", "resume"])
        let presenter = ProjectionPresenter(state: state)
        let rows = presenter.inbox
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.title, "Second fixture question", "Newest activity first")
        XCTAssertTrue(rows.allSatisfy(\.isDirect), "One-agent conversations are direct rows")
        let first = try XCTUnwrap(rows.first { $0.title == "Fixture question from the phone" })
        XCTAssertFalse(first.preview.hasPrefix(presenter.shortName(first.agentIDs[0]) + ":"), "A direct row shows the reply without repeating the agent")
        XCTAssertNotEqual(first.preview, first.title, "Preview shows the last reply, not the prompt")

        let prompt = try XCTUnwrap(presenter.turns(in: first.id, agentID: nil).first { $0.origin == .sharedPrompt })
        let chips = presenter.chips(for: prompt)
        XCTAssertEqual(chips.count, 1)
        XCTAssertEqual(chips.first?.state, .replied, "A submitted Messages send with a later reply reads Replied")
        let agent = try XCTUnwrap(first.agentIDs.first)
        XCTAssertEqual(presenter.chips(for: prompt, agentID: agent).map(\.agentID), [agent], "A one-agent filter shows only that agent's chip")
        XCTAssertTrue(presenter.chips(for: prompt, agentID: "someone-else").isEmpty)
        XCTAssertTrue(presenter.turns(in: first.id, agentID: agent).contains { $0.role == .assistant })
    }

    func testSharedPromptChipsFollowTheAgentFilter() {
        var state = ProjectionState()
        let conversation = UUID()
        let prompt = RemoteTurn(id: "p", conversationID: conversation, agentID: nil, role: .user, origin: .sharedPrompt, text: "Hi", created: fixedNow, ordinal: 0, contentHash: "h")
        state.turns[prompt.id] = prompt
        for (agent, status) in [("claude", RemoteAttemptStatus.observed), ("codexCLI", .uncertain)] {
            state.attempts[agent] = RemoteAttempt(id: agent, conversationID: conversation, agentID: agent, text: "Hi", status: status, detail: nil, created: fixedNow)
        }
        let presenter = ProjectionPresenter(state: state)
        XCTAssertEqual(presenter.chips(for: prompt).map(\.agentID), ["claude", "codexCLI"], "All shows every agent")
        XCTAssertEqual(presenter.chips(for: prompt, agentID: "codexCLI").map(\.state), [.unconfirmed], "One agent's view shows only its chip")
    }

    func testDisabledReasonsLaunchNotesAndNewConversationList() throws {
        var state = try RecordedFixtures.reduce(["snapshot"])
        let presenter = ProjectionPresenter(state: state)
        let messages = try XCTUnwrap(state.orderedAgents.first { $0.form == .messages })
        XCTAssertNil(presenter.disabledReason(agentIDs: [messages.agentID], conversation: nil))
        XCTAssertEqual(presenter.disabledLine(agentIDs: ["geminiApp"], conversation: nil), StatusLine("Gemini isn't in this version", detail: "Gemini is not offered in this version of msgblast."))
        XCTAssertEqual(presenter.disabledReason(agentIDs: [], conversation: nil), "Choose who to send to")

        var app = try XCTUnwrap(state.agents["chatgptApp"])
        app.readiness = .readyWillLaunch
        state.agents["chatgptApp"] = app
        XCTAssertEqual(ProjectionPresenter(state: state).launchNotes(agentIDs: ["chatgptApp"]), ["Opens ChatGPT on your Mac"])
        XCTAssertEqual(ProjectionPresenter.agentStatus(app), "Opens on your Mac", "The row already names the agent")

        let conversation = UUID()
        state.conversations[conversation] = RemoteConversation(id: conversation, title: "T", prompt: "P", created: fixedNow, endedAt: nil, agentIDs: ["chatgptApp"], canEnd: true,
            unresolvedAttemptCount: 1, lastActivity: fixedNow, incompleteAttempts: [RemoteIncompleteAttempt(agentID: "chatgptApp", attemptID: "wa:1", reasonCode: .incompleteRequestBlocking)])
        XCTAssertEqual(ProjectionPresenter(state: state).disabledReason(agentIDs: ["chatgptApp"], conversation: conversation), "Finish the ChatGPT request first", "Blocked inside that conversation")
        XCTAssertNil(ProjectionPresenter(state: state).disabledReason(agentIDs: ["chatgptApp"], conversation: nil), "Ready elsewhere")
        state.macLocked = true
        XCTAssertEqual(ProjectionPresenter(state: state).disabledReason(agentIDs: [messages.agentID], conversation: nil), "Mac locked")

        let list = presenter.newConversationAgents
        XCTAssertFalse(list.agents.isEmpty)
        XCTAssertTrue(list.agents.allSatisfy { $0.form != .messages }); XCTAssertTrue(list.messages.allSatisfy { $0.form == .messages })
        XCTAssertFalse(list.messages.isEmpty, "Messages contacts have their own section")
        let gridOrder = state.grid.filter { id in list.agents.contains { $0.agentID == id } }
        XCTAssertEqual(Array(list.agents.map(\.agentID).prefix(gridOrder.count)), gridOrder, "The Mac's grid order")
        XCTAssertEqual(Set(list.agents.map(\.agentID)).count, list.agents.count, "Each form is its own row; histories stay separate")
        XCTAssertEqual(ProjectionPresenter.formLabel(.webhookBot), "Bot")
        XCTAssertEqual(ChipState(.uncertain), .unconfirmed)
        XCTAssertEqual(ChipState(.observed), .replied)
    }
    func testARefusedPrepareKeepsSendEnabledAndRetriesOnceTheAgentIsReady() throws {
        var state = try RecordedFixtures.reduce(["snapshot"])
        var app = try XCTUnwrap(state.agents["chatgptApp"])
        app.readiness = .ready
        state.agents["chatgptApp"] = app
        let name = app.displayName
        let refused = ["chatgptApp": "Check msgblast permissions on your Mac"]
        let ready = ProjectionPresenter(state: state)

        // Only the refused prepare is in the way: its reason shows, Send stays enabled.
        let failed = try XCTUnwrap(ready.composeBlock(canSend: true, connectionText: "Connected", agentIDs: ["chatgptApp"], conversation: nil, prepareReasons: refused))
        XCTAssertEqual(failed, .prepareFailed("\(name): Check msgblast permissions on your Mac"))
        XCTAssertEqual(ready.composeBlock(canSend: true, connectionText: "", agentIDs: ["chatgptApp"], conversation: nil, prepareReasons: ["chatgptApp": "\(name) is still loading"]),
                       .prepareFailed("\(name) is still loading"), "A line that names the agent is not prefixed again")
        XCTAssertTrue(failed.allowsSend)
        XCTAssertNil(ready.composeBlock(canSend: true, connectionText: "Connected", agentIDs: ["chatgptApp"], conversation: nil, prepareReasons: [:]))
        XCTAssertEqual(ready.composeBlock(canSend: true, connectionText: "", agentIDs: ["chatgptApp"], conversation: nil, prepareReasons: ["": "Not ready"]), .prepareFailed("Not ready"))

        // Disconnection and the projection's own reasons still disable Send.
        let offline = try XCTUnwrap(ready.composeBlock(canSend: false, connectionText: MacConnectionState.reconnecting(attempt: 1, retryAt: fixedNow).statusText, agentIDs: ["chatgptApp"], conversation: nil, prepareReasons: refused))
        XCTAssertEqual(offline, .blocked("Reconnecting…")); XCTAssertFalse(offline.allowsSend)
        var busyState = state
        app.readiness = .busy(detail: "Sending")
        busyState.agents["chatgptApp"] = app
        let busy = ProjectionPresenter(state: busyState)
        XCTAssertFalse(try XCTUnwrap(busy.composeBlock(canSend: true, connectionText: "", agentIDs: ["chatgptApp"], conversation: nil, prepareReasons: refused)).allowsSend)

        // The prepare runs again by itself only when the refused agents can accept a send.
        XCTAssertFalse(busy.shouldRetryPrepare(prepareReasons: refused, agentIDs: ["chatgptApp"]))
        XCTAssertTrue(ready.shouldRetryPrepare(prepareReasons: refused, agentIDs: ["chatgptApp"]))
        XCTAssertFalse(ready.shouldRetryPrepare(prepareReasons: [:], agentIDs: ["chatgptApp"]), "Nothing to retry")
        XCTAssertNotEqual(busy.readiness(agentIDs: ["chatgptApp"]), ready.readiness(agentIDs: ["chatgptApp"]), "The view notices the change")
    }

    func testChipsShowOnlyWhereTheyMatterAndTypingFollowsSubmittedRequests() {
        var state = ProjectionState()
        let conversation = UUID(), start = Date(timeIntervalSince1970: 1_800_000_000)
        let old = RemoteTurn(id: "old", conversationID: conversation, agentID: nil, role: .user, origin: .sharedPrompt, text: "First", created: start, ordinal: 0, contentHash: "a")
        let latest = RemoteTurn(id: "new", conversationID: conversation, agentID: nil, role: .user, origin: .followUp, text: "Second", created: start.addingTimeInterval(60), ordinal: 1, contentHash: "b")
        state.turns = [old.id: old, latest.id: latest]
        for (id, agent, text, status, offset) in [("1", "claude", "First", RemoteAttemptStatus.observed, 0.0), ("2", "museApp", "First", .notSent, 0), ("3", "codexCLI", "First", .uncertain, 0),
                                                  ("4", "claude", "Second", .submitted, 60), ("5", "museApp", "Second", .waiting, 60), ("6", "codexCLI", "Second", .observed, 60)] {
            state.attempts[id] = RemoteAttempt(id: id, conversationID: conversation, agentID: agent, text: text, status: status, detail: nil, created: start.addingTimeInterval(offset))
        }
        state.turns["r"] = RemoteTurn(id: "r", conversationID: conversation, agentID: "museApp", role: .assistant, origin: .agentTranscript, text: "Hi", created: start.addingTimeInterval(90), ordinal: 2, contentHash: "c")
        let presenter = ProjectionPresenter(state: state)
        XCTAssertEqual(presenter.visibleChips(for: old, isLatest: false, expanded: false).map(\.state), [.unconfirmed, .notSent], "An older message shows only its exceptions")
        XCTAssertEqual(presenter.visibleChips(for: old, isLatest: false, expanded: true).count, 3, "Tapping reveals every chip")
        XCTAssertEqual(presenter.visibleChips(for: latest, isLatest: true, expanded: false).count, 3, "The latest message shows every chip")
        XCTAssertEqual(presenter.typingAgents(in: conversation), ["claude"], "Muse replied after its request; Codex finished")
        XCTAssertEqual(presenter.typingAgents(in: conversation, agentID: "museApp"), [])
    }

    func testTimeHeadersAndUnread() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US")
        let now = Date(timeIntervalSince1970: 1_800_000_000)  // Friday 15 January 2027, 08:00 UTC
        func header(_ date: Date, _ previous: Date?) -> String? {
            ProjectionPresenter.timeHeader(date, previous: previous, now: now, calendar: calendar, locale: locale)?.replacingOccurrences(of: "\u{202F}", with: " ")
        }
        XCTAssertEqual(header(now.addingTimeInterval(-600), nil), "Today 7:50 AM", "The first turn always has a header")
        XCTAssertNil(header(now, now.addingTimeInterval(-3600)), "An hour or less apart: no header")
        XCTAssertEqual(header(now.addingTimeInterval(-86_400 + 600), now.addingTimeInterval(-3 * 86_400)), "Yesterday 8:10 AM")
        XCTAssertEqual(header(now.addingTimeInterval(-4 * 86_400), nil), "Mon, Jan 11 at 8:00 AM")
        XCTAssertEqual(header(now.addingTimeInterval(-84 * 86_400 - 3600 * 12 - 26 * 60), nil), "Thu, Oct 22, 2026 at 7:34 PM", "Another year shows the year")
        XCTAssertEqual(header(now.addingTimeInterval(-2 * 86_400 + 3 * 3600), nil), "Wed, Jan 13 at 11:00 AM", "Older than yesterday: weekday, month, day, then at")
        XCTAssertEqual(header(now.addingTimeInterval(2 * 3600 + 54 * 60), nil), "Today 10:54 AM")

        var state = ProjectionState()
        let read = UUID(), unread = UUID(), old = UUID()
        for (id, replyAt) in [(read, now), (unread, now), (old, now.addingTimeInterval(-7200))] {
            state.conversations[id] = RemoteConversation(id: id, title: "T", prompt: "P", created: replyAt, endedAt: nil, agentIDs: ["claude"], canEnd: true, unresolvedAttemptCount: 0, lastActivity: replyAt)
            state.turns["\(id)"] = RemoteTurn(id: "\(id)", conversationID: id, agentID: "claude", role: .assistant, origin: .agentTranscript, text: "R", created: replyAt, ordinal: 0, contentHash: "h")
        }
        let presenter = ProjectionPresenter(state: state, lastOpened: [read: now.addingTimeInterval(1)], unreadSince: now.addingTimeInterval(-3600))
        let rows = Dictionary(uniqueKeysWithValues: presenter.inbox.map { ($0.id, $0.unread) })
        XCTAssertEqual(rows[read], false, "Opened after the reply")
        XCTAssertEqual(rows[unread], true, "A reply newer than the last opening")
        XCTAssertEqual(rows[old], false, "Replies from before this phone started tracking are not unread")
    }

    func testInboxIsOneListByRecencyAndAReplyOrSendMovesARowToTheTop() {
        var state = ProjectionState()
        let group = UUID(), direct = UUID(), contact = UUID()
        for (id, agents, minutes) in [(group, ["claude", "museApp"], 30.0), (direct, ["claude"], 20.0), (contact, ["messages:cedar"], 10.0)] {
            state.conversations[id] = RemoteConversation(id: id, title: "T", prompt: "P", created: fixedNow, endedAt: nil, agentIDs: agents, canEnd: true,
                                                         unresolvedAttemptCount: 0, lastActivity: fixedNow.addingTimeInterval(-minutes * 60))
        }
        XCTAssertEqual(ProjectionPresenter(state: state).inbox.map(\.id), [contact, direct, group], "Groups, direct agents and Messages contacts share one list, newest first")

        // A reply the phone has seen moves its row up before the Mac's activity time catches up.
        state.turns["r"] = RemoteTurn(id: "r", conversationID: group, agentID: "claude", role: .assistant, origin: .agentTranscript, text: "R",
                                      created: fixedNow, ordinal: 1, contentHash: "h")
        let replied = ProjectionPresenter(state: state).inbox
        XCTAssertEqual(replied.map(\.id), [group, contact, direct])
        XCTAssertEqual(replied.first?.lastActivity, fixedNow, "The row's time is the reply's")

        // So does the phone's own send.
        let send = CommandRecord(id: UUID(), kind: "sendShared", conversationID: direct, agentIDs: ["claude"], text: "Hi", sentAt: fixedNow.addingTimeInterval(60), status: .sending)
        XCTAssertEqual(ProjectionPresenter(state: state, commands: [send.id: send]).inbox.map(\.id), [direct, group, contact])
    }

    func testATransparentMarkGetsABackingOnlyWhereItWouldVanish() throws {
        /// A transparent 64 pt square with an opaque disc of one gray level in the middle.
        func mark(gray: CGFloat) throws -> CGImage {
            let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
            context.fillEllipse(in: CGRect(x: 8, y: 8, width: 48, height: 48))
            return try XCTUnwrap(context.makeImage())
        }
        let black = try XCTUnwrap(ArtworkTone.luminance(of: mark(gray: 0)))
        let white = try XCTUnwrap(ArtworkTone.luminance(of: mark(gray: 1)))
        let middle = try XCTUnwrap(ArtworkTone.luminance(of: mark(gray: 0.55)))
        XCTAssertEqual(black, 0, accuracy: 0.01, "Transparent pixels do not count")
        XCTAssertEqual(white, 1, accuracy: 0.01)
        XCTAssertTrue((ArtworkTone.darkMark...ArtworkTone.lightMark).contains(middle), "A mid gray (\(middle)) sits between the thresholds")

        XCTAssertTrue(ArtworkTone.needsBacking(luminance: black, darkBackground: true), "A black mark in dark mode")
        XCTAssertFalse(ArtworkTone.needsBacking(luminance: black, darkBackground: false))
        XCTAssertTrue(ArtworkTone.needsBacking(luminance: white, darkBackground: false), "A white mark in light mode")
        XCTAssertFalse(ArtworkTone.needsBacking(luminance: white, darkBackground: true))
        XCTAssertFalse(ArtworkTone.needsBacking(luminance: middle, darkBackground: true))
        XCTAssertFalse(ArtworkTone.needsBacking(luminance: middle, darkBackground: false))
        XCTAssertTrue(ArtworkTone.needsBacking(luminance: 0.34, darkBackground: true))
        XCTAssertFalse(ArtworkTone.needsBacking(luminance: 0.35, darkBackground: true))
        XCTAssertTrue(ArtworkTone.needsBacking(luminance: 0.81, darkBackground: false))
        XCTAssertFalse(ArtworkTone.needsBacking(luminance: 0.8, darkBackground: false))
        XCTAssertFalse(ArtworkTone.needsBacking(luminance: nil, darkBackground: true), "Nothing opaque, nothing to back")

        let empty = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        XCTAssertNil(ArtworkTone.luminance(of: empty))
    }

    func testNewConversationChecksStartEmptyAndMeanNoOne() {
        let agents = ["museApp", "hark", "instinct", "fo"]
        // The thread's rule: from All (empty), a tap leaves everyone else. Not for a new conversation.
        XCTAssertEqual(ProjectionPresenter.toggling("museApp", selection: [], members: agents), ["hark", "instinct", "fo"])
        var chosen: [String] = []
        chosen = ProjectionPresenter.togglingNew("museApp", chosen: chosen)
        XCTAssertEqual(chosen, ["museApp"], "One tap on a new conversation checks exactly that agent")
        chosen = ProjectionPresenter.togglingNew("fo", chosen: chosen)
        XCTAssertEqual(chosen, ["museApp", "fo"], "In the order checked")
        chosen = ProjectionPresenter.togglingNew("museApp", chosen: chosen)
        XCTAssertEqual(chosen, ["fo"], "A second tap removes")
        chosen = ProjectionPresenter.togglingNew("fo", chosen: chosen)
        XCTAssertEqual(chosen, [], "Removing the last leaves no one, not everyone")

        // The created conversation's agents are exactly the checked ones.
        let checked = ["hark", "instinct", "fo"]
        guard case .createConversation(_, let created, _) = ProjectionPresenter.sendAction(conversationID: nil, members: checked, recipients: checked, text: "Hi", attachmentIDs: []) else {
            return XCTFail("Several checked agents create a group")
        }
        XCTAssertEqual(created, checked)
        guard case .sendPrivate(nil, "museApp", _, _) = ProjectionPresenter.sendAction(conversationID: nil, members: ["museApp"], recipients: ["museApp"], text: "Hi", attachmentIDs: []) else {
            return XCTFail("One checked agent starts a direct conversation with it")
        }
    }

    func testStatusBadgesUseOneCheckmarkAndDifferByFill() {
        XCTAssertEqual(ChipState.sent.badge.symbol, "checkmark")
        XCTAssertEqual(ChipState.sent.badge.fill, .plain)
        XCTAssertEqual(ChipState.replied.badge.symbol, "checkmark", "No speech bubble")
        XCTAssertEqual(ChipState.replied.badge.fill, .tint, "Replied differs from Sent by its fill")
        XCTAssertEqual(ChipState.sending.badge.symbol, "clock")
        XCTAssertEqual(ChipState.notSent.badge.symbol, "xmark")
        XCTAssertEqual(ChipState.notSent.badge.fill, .red)
        XCTAssertEqual(ChipState.unconfirmed.badge.symbol, "questionmark")
        XCTAssertEqual(ChipState.unconfirmed.badge.fill, .orange)
        XCTAssertFalse([ChipState.sending, .sent, .replied, .notSent, .unconfirmed].contains { $0.badge.symbol.contains("bubble") || $0.symbol.contains("bubble") })
        XCTAssertEqual(ChipState.sent.spoken, "sent")
        XCTAssertEqual(ChipState.replied.spoken, "replied")
    }

    func testPassingMacStatesAreQuietAndOnlyFixesWarn() {
        var state = ProjectionState()
        func agent(_ id: String, _ readiness: AgentReadiness, _ reason: AvailabilityReason?) {
            state.agents[id] = AgentAvailability(agentID: id, product: AgentProduct(rawValue: id), form: .macApp, displayName: id.capitalized, visibleInGrid: true, selectedForSharedSend: true,
                capabilities: AgentCapabilities(sharedSend: true, privateSend: true, attachments: false, namedCopies: false, endConversation: true, sharesOneConversation: false),
                readiness: readiness, reasons: reason.map { [$0] } ?? [], observedAt: fixedNow, source: .live)
        }
        agent("muse", .busy(detail: "Checking Muse…"), AvailabilityReason(code: .sendInFlight, userText: "Checking Muse on your Mac", fixOn: .none))
        agent("dots", .blocked, AvailabilityReason(code: .permissionMissing, userText: "Allow Accessibility on your Mac", fixOn: .mac))
        agent("claude", .busy(detail: "Claude is working…"), nil)
        let presenter = ProjectionPresenter(state: state)
        func block(_ id: String) -> ComposeBlock? { presenter.composeBlock(canSend: true, connectionText: "", agentIDs: [id], conversation: nil, prepareReasons: [:]) }
        XCTAssertEqual(block("muse"), .waiting("Checking Muse on your Mac"))
        XCTAssertEqual(block("muse")?.warns, false, "A readiness re-check is informational")
        XCTAssertEqual(block("muse")?.allowsSend, false, "Send still waits for it")
        XCTAssertEqual(block("claude")?.warns, false)
        XCTAssertEqual(block("dots"), .blocked("Allow Accessibility on your Mac"))
        XCTAssertEqual(block("dots")?.warns, true, "Something to fix on the Mac warns")
        XCTAssertEqual(presenter.composeBlock(canSend: false, connectionText: "Reconnecting…", agentIDs: ["muse"], conversation: nil, prepareReasons: [:])?.warns, true)
    }

    func testDirectThreadsAreTitledByTheirPromptOrName() {
        var state = ProjectionState()
        let sunday = UUID(), gift = UUID()
        state.conversations[sunday] = RemoteConversation(id: sunday, title: "Plan a quiet Sunday in Lisbon.", prompt: "Plan a quiet Sunday in Lisbon.", created: fixedNow, endedAt: nil,
                                                         agentIDs: ["museApp"], canEnd: true, unresolvedAttemptCount: 0, lastActivity: fixedNow.addingTimeInterval(-60))
        // Renamed on the Mac or the phone: the name, not the prompt.
        state.conversations[gift] = RemoteConversation(id: gift, title: "Ana's birthday", prompt: "Gift ideas for Ana?", created: fixedNow, endedAt: nil,
                                                       agentIDs: ["museApp"], canEnd: true, unresolvedAttemptCount: 0, lastActivity: fixedNow)
        state.turns["p"] = RemoteTurn(id: "p", conversationID: sunday, agentID: "museApp", role: .user, origin: .followUp, text: "Plan a quiet Sunday in Lisbon.", created: fixedNow, ordinal: 0, contentHash: "h")
        let presenter = ProjectionPresenter(state: state)
        let rows = presenter.inbox
        XCTAssertEqual(rows.map(\.title), ["Ana's birthday", "Plan a quiet Sunday in Lisbon."], "Two threads with one agent: newest first, each with its own title")
        XCTAssertTrue(rows.allSatisfy(\.isDirect))
        XCTAssertEqual(presenter.pinnedPrompt(for: sunday, selection: [])?.id, "p", "A direct thread pins its prompt too")
        state.turns["p"]?.origin = .messagesHistory
        XCTAssertNil(ProjectionPresenter(state: state).pinnedPrompt(for: sunday, selection: []), "An older Messages chat has no prompt to pin")
    }

    func testTheHeaderSelectionDrivesSendsPlaceholderAndTitle() {
        var state = ProjectionState()
        for (id, name) in [("claude", "Claude"), ("museApp", "Muse"), ("codexCLI", "Codex CLI"), ("grok", "Grok"), ("dotsApp", "Dots")] {
            state.agents[id] = AgentAvailability(agentID: id, product: AgentProduct(rawValue: id), form: .website, displayName: name, visibleInGrid: true, selectedForSharedSend: true,
                capabilities: AgentCapabilities(sharedSend: true, privateSend: true, attachments: false, namedCopies: false, endConversation: true, sharesOneConversation: false),
                readiness: .ready, reasons: [], observedAt: fixedNow, source: .live)
        }
        let presenter = ProjectionPresenter(state: state)
        let id = UUID(), three = ["claude", "museApp", "codexCLI"], five = three + ["grok", "dotsApp"]
        func action(_ selection: Set<String>, _ members: [String] = three) -> RemoteAction {
            ProjectionPresenter.sendAction(conversationID: id, members: members, recipients: ProjectionPresenter.recipients(selection: selection, members: members), text: "Hi", attachmentIDs: [])
        }
        XCTAssertEqual(action([]), .sendShared(conversationID: id, text: "Hi", agentIDs: [], attachmentIDs: []), "All sends to everyone")
        XCTAssertEqual(action(["museApp"]), .sendPrivate(conversationID: id, agentID: "museApp", text: "Hi", attachmentIDs: []), "One is private")
        XCTAssertEqual(action(["museApp", "claude"]), .sendShared(conversationID: id, text: "Hi", agentIDs: ["claude", "museApp"], attachmentIDs: []), "Several: those agents, in member order")
        XCTAssertEqual(action(["claude"], ["claude"]), .sendShared(conversationID: id, text: "Hi", agentIDs: [], attachmentIDs: []), "A direct thread is unchanged")
        XCTAssertEqual(presenter.placeholder(recipients: ProjectionPresenter.recipients(selection: [], members: three)), "Message")
        XCTAssertEqual(presenter.placeholder(recipients: ProjectionPresenter.recipients(selection: ["claude"], members: three)), "Message Claude")
        XCTAssertEqual(presenter.placeholder(recipients: ProjectionPresenter.recipients(selection: ["claude", "museApp"], members: three)), "Message")
        XCTAssertEqual(presenter.selectionTitle([], members: three), "3 Agents")
        XCTAssertEqual(presenter.selectionTitle(["claude"], members: three), "Claude")
        XCTAssertEqual(presenter.selectionTitle(["museApp", "claude"], members: three), "Claude & Muse")
        XCTAssertEqual(presenter.selectionTitle(["claude", "museApp", "grok"], members: five), "3 of 5")
        XCTAssertEqual(presenter.selectionTitle(Set(three), members: three), "3 Agents", "Everyone selected reads as All")

        // Details' checkmarks: All checks everyone; unchecking walks down, the last returns to All.
        XCTAssertTrue(three.allSatisfy { ProjectionPresenter.isChecked($0, selection: []) })
        var selection = ProjectionPresenter.toggling("codexCLI", selection: [], members: three)
        XCTAssertEqual(selection, ["claude", "museApp"]); XCTAssertEqual(presenter.selectionTitle(selection, members: three), "Claude & Muse")
        XCTAssertFalse(ProjectionPresenter.isChecked("codexCLI", selection: selection))
        selection = ProjectionPresenter.toggling("museApp", selection: selection, members: three)
        XCTAssertEqual(selection, ["claude"])
        selection = ProjectionPresenter.toggling("claude", selection: selection, members: three)
        XCTAssertEqual(selection, [], "Unchecking the last returns to All")
        XCTAssertTrue(three.allSatisfy { ProjectionPresenter.isChecked($0, selection: selection) })
        selection = ProjectionPresenter.toggling("museApp", selection: ["claude"], members: three)
        XCTAssertEqual(selection, ["claude", "museApp"], "Checking adds to a subset")
        XCTAssertEqual(ProjectionPresenter.toggling("codexCLI", selection: selection, members: three), [], "Checking the last missing one is All")
    }

    func testAReplyQuotesTheRightResponseOnly() {
        var state = ProjectionState()
        let conversation = UUID(), sent = Date(timeIntervalSince1970: 1_800_000_000)
        state.conversations[conversation] = RemoteConversation(id: conversation, title: "T", prompt: "P", created: sent, endedAt: nil, agentIDs: ["claude", "codexCLI"], canEnd: true, unresolvedAttemptCount: 0, lastActivity: sent)
        state.turns["answer"] = RemoteTurn(id: "answer", conversationID: conversation, agentID: "claude", role: .assistant, origin: .agentTranscript, text: "Trofie", created: sent.addingTimeInterval(-60), ordinal: 0, contentHash: "a")
        let reply = RemoteTurn(id: "reply", conversationID: conversation, agentID: "claude", role: .user, origin: .followUp, text: "Why trofie?", created: sent.addingTimeInterval(2), ordinal: 1, contentHash: "b")
        let other = RemoteTurn(id: "other", conversationID: conversation, agentID: "codexCLI", role: .user, origin: .followUp, text: "Why trofie?", created: sent.addingTimeInterval(2), ordinal: 2, contentHash: "c")
        state.turns[reply.id] = reply; state.turns[other.id] = other
        let command = RemoteCommand(action: .sendPrivate(conversationID: conversation, agentID: "claude", text: "Why trofie?", attachmentIDs: []))
        let presenter = ProjectionPresenter(state: state, commands: [command.clientCommandID: CommandLedger.record(command, at: sent)], replyTo: [command.clientCommandID: "answer"])
        XCTAssertEqual(presenter.quotedTurn(for: reply)?.id, "answer")
        XCTAssertNil(presenter.quotedTurn(for: other), "Never on another agent's turn, even with the same text")
        XCTAssertNil(presenter.quotedTurn(for: state.turns["answer"]!), "Only your own turns quote")
        XCTAssertNil(ProjectionPresenter(state: state, commands: [command.clientCommandID: CommandLedger.record(command, at: sent)]).quotedTurn(for: reply), "No link, no quote")
    }

    @MainActor func testReplyLinksSurviveRelaunchAndForget() throws {
        let database = try LocalDatabase(url: nil)
        let store = MobileStore(database: database)
        let command = UUID()
        store.recordReply(command, quoting: "answer")
        XCTAssertEqual(MobileStore(database: database).replyTo[command], "answer")
        store.forgetMac()
        XCTAssertTrue(MobileStore(database: database).replyTo.isEmpty)
    }

    @MainActor func testEmojiSurviveTheReducerStoreAndPresenterUnchanged() throws {
        let samples = ["👩‍👩‍👧‍👦", "👍🏽 thanks", "🇵🇹🇮🇹", "❤️❤️❤️", "Café ☕️ e cappuccino", "🫶🏾✨"]
        var state = ProjectionState()
        let conversation = UUID()
        state.conversations[conversation] = RemoteConversation(id: conversation, title: samples[0], prompt: samples[0], created: fixedNow, endedAt: nil, agentIDs: ["messages:x"], canEnd: true, unresolvedAttemptCount: 0, lastActivity: fixedNow)
        let turns = samples.enumerated().map { index, text in
            RemoteTurn(id: "t\(index)", conversationID: conversation, agentID: "messages:x", role: index.isMultiple(of: 2) ? .assistant : .user, origin: .messagesHistory,
                       text: text, created: fixedNow.addingTimeInterval(Double(index)), ordinal: index, contentHash: "h\(index)")
        }
        let snapshot = RemoteSnapshot(seq: 1, macStatus: MacStatus(macName: "Mac", variant: .demo, locked: false, awake: true, databaseAvailable: true, databaseStatus: "ok", messagesBusy: false,
            broadcastBusy: false, sendingAgentIDs: [], keepAwakeEnabled: false, keepAwakeHeld: false, messagesSendsAllowed: true, observedAt: fixedNow),
            grid: RemoteGrid(visibleAgentIDs: []), agents: [], conversations: Array(state.conversations.values), turns: turns, attempts: [])
        // Over the wire, through the reducer, into SQLite and back.
        let wire = try RemoteProtocol.decoder().decode(RemoteMessage.self, from: RemoteProtocol.encoder().encode(RemoteMessage.snapshot(snapshot)))
        guard case .snapshot(let received) = wire else { return XCTFail("Not a snapshot") }
        let database = try LocalDatabase(url: nil)
        let store = MobileStore(database: database)
        store.handle(.snapshot(received))
        store.saveNow()
        let reloaded = MobileStore(database: database).projection
        for (index, text) in samples.enumerated() {
            XCTAssertEqual(reloaded.turns["t\(index)"]?.text, text)
            XCTAssertEqual(reloaded.turns["t\(index)"]?.text.unicodeScalars.map(\.value), text.unicodeScalars.map(\.value), "No normalization or escaping")
        }
        XCTAssertEqual(reloaded.conversations[conversation]?.title, "👩‍👩‍👧‍👦")
        let row = ProjectionPresenter(state: reloaded).inbox.first
        XCTAssertEqual(row?.preview, samples[5], "The latest message, your own here, previews exactly")
        XCTAssertEqual(row?.fromYou, true, "Marked as yours, as Messages marks your replies")
        XCTAssertTrue(SharedContent.isEmojiOnly("👩‍👩‍👧‍👦"), "A ZWJ family is one emoji")
        XCTAssertTrue(SharedContent.isEmojiOnly("🇵🇹🇮🇹"))
        XCTAssertTrue(SharedContent.isEmojiOnly("❤️❤️❤️"))
        XCTAssertTrue(SharedContent.isEmojiOnly(" 👍🏽 "))
        XCTAssertFalse(SharedContent.isEmojiOnly("❤️❤️❤️❤️"), "Four is regular text")
        XCTAssertFalse(SharedContent.isEmojiOnly("👍🏽 thanks"))
        XCTAssertFalse(SharedContent.isEmojiOnly("123"), "Digits are not emoji")
        XCTAssertFalse(SharedContent.isEmojiOnly(""))
    }

    func testReactionStacksShowUpToThreeAndACount() {
        func turn(_ emoji: [String]) -> RemoteTurn {
            RemoteTurn(id: "t", conversationID: UUID(), agentID: "messages:x", role: .assistant, origin: .messagesHistory, text: "Hi", created: fixedNow, ordinal: 0, contentHash: "h",
                       reactions: emoji.enumerated().map { RemoteReaction(emoji: $0.element, agentID: $0.offset == 0 ? nil : "messages:x") })
        }
        let presenter = ProjectionPresenter(state: ProjectionState())
        XCTAssertNil(presenter.reactionSummary(for: turn([])))
        XCTAssertEqual(presenter.reactionSummary(for: turn(["❤️"])), ReactionSummary(emoji: ["❤️"], total: 1))
        XCTAssertNil(presenter.reactionSummary(for: turn(["❤️"]))?.countLabel)
        let many = presenter.reactionSummary(for: turn(["❤️", "👍", "❤️", "😂", "‼️"]))
        XCTAssertEqual(many?.emoji, ["❤️", "😂", "‼️"], "Three distinct, newest last")
        XCTAssertEqual(many?.countLabel, "5")
    }

    func testLinksAttachmentsAndSharedContent() throws {
        let text = "See https://en.wikipedia.org/wiki/Trofie and www.seriouseats.com/pesto, not mailto:a@b.c."
        let found = SharedContent.links(in: text)
        XCTAssertEqual(found.map(\.url.host), ["en.wikipedia.org", "www.seriouseats.com"], "Web links only, in order")
        XCTAssertEqual(String(text[found[0].range]), "https://en.wikipedia.org/wiki/Trofie")
        XCTAssertTrue(SharedContent.isImage(filename: "IMG_0001.HEIC", mimeType: nil))
        XCTAssertTrue(SharedContent.isImage(filename: "photo", mimeType: "image/png"))
        XCTAssertFalse(SharedContent.isImage(filename: "Menu.pdf", mimeType: "application/pdf"))
        XCTAssertFalse(SharedContent.isImage(filename: "notes", mimeType: nil))

        var state = ProjectionState()
        let conversation = UUID()
        state.conversations[conversation] = RemoteConversation(id: conversation, title: "T", prompt: "P", created: fixedNow, endedAt: nil, agentIDs: ["claude", "cedar"], canEnd: true, unresolvedAttemptCount: 0, lastActivity: fixedNow)
        state.turns["p"] = RemoteTurn(id: "p", conversationID: conversation, agentID: nil, role: .user, origin: .sharedPrompt, text: "Which is better?", created: fixedNow, ordinal: 0,
                                      attachments: [RemoteAttachmentRef(id: "1", filename: "a.jpg", mimeType: "image/jpeg", byteCount: 10), RemoteAttachmentRef(id: "2", filename: "Menu.pdf", mimeType: "application/pdf", byteCount: 2000)], contentHash: "a")
        state.turns["r"] = RemoteTurn(id: "r", conversationID: conversation, agentID: "claude", role: .assistant, origin: .agentTranscript, text: "Read https://example.com/a\nand https://example.com/a again",
                                      created: fixedNow.addingTimeInterval(5), ordinal: 1, attachments: [RemoteAttachmentRef(id: "3", filename: "b.png", mimeType: nil, byteCount: nil)], contentHash: "b")
        let shared = ProjectionPresenter(state: state).sharedContent(in: conversation)
        XCTAssertEqual(shared.photos.map(\.id), ["p#0", "r#0"])
        XCTAssertEqual(shared.documents.map(\.filename), ["Menu.pdf"]); XCTAssertNil(shared.documents[0].agentID, "Your own file")
        XCTAssertEqual(shared.links.count, 1, "A repeated link is listed once")
        XCTAssertEqual(shared.links.first?.host, "example.com"); XCTAssertEqual(shared.links.first?.context, "Read https://example.com/a"); XCTAssertEqual(shared.links.first?.agentID, "claude")
    }

    @MainActor func testFetchedAttachmentsAreCachedAndForgotten() throws {
        let database = try LocalDatabase(url: nil)
        let store = MobileStore(database: database)
        store.storeAttachment(Data([1, 2]), type: "image/jpeg", turnID: "m:1", index: 0, thumbnail: true)
        XCTAssertNil(store.attachment(turnID: "m:1", index: 0, thumbnail: false), "Thumbnails and full files are cached apart")
        let cached = try XCTUnwrap(MobileStore(database: database).attachment(turnID: "m:1", index: 0, thumbnail: true))
        XCTAssertEqual(cached.data, Data([1, 2])); XCTAssertEqual(cached.type, "image/jpeg")
        store.forgetMac()
        XCTAssertNil(MobileStore(database: database).attachment(turnID: "m:1", index: 0, thumbnail: true), "Forget This Mac clears the cache")
    }

    func testPinnedPromptIsAGroupsSharedPromptOrADirectThreadsFirstMessage() {
        var state = ProjectionState()
        let group = UUID(), direct = UUID(), noPrompt = UUID(), start = Date(timeIntervalSince1970: 1_800_000_000)
        for (id, agents) in [(group, ["claude", "codexCLI"]), (direct, ["claude"]), (noPrompt, ["claude", "codexCLI"])] {
            state.conversations[id] = RemoteConversation(id: id, title: "T", prompt: "P", created: start, endedAt: nil, agentIDs: agents, canEnd: true, unresolvedAttemptCount: 0, lastActivity: start)
        }
        state.turns["g0"] = RemoteTurn(id: "g0", conversationID: group, agentID: nil, role: .user, origin: .sharedPrompt, text: "Compare these", created: start, ordinal: 0, contentHash: "a")
        state.turns["g1"] = RemoteTurn(id: "g1", conversationID: group, agentID: "claude", role: .assistant, origin: .agentTranscript, text: "Sure", created: start.addingTimeInterval(5), ordinal: 1, contentHash: "b")
        state.turns["d0"] = RemoteTurn(id: "d0", conversationID: direct, agentID: nil, role: .user, origin: .sharedPrompt, text: "Hi", created: start, ordinal: 0, contentHash: "c")
        state.turns["n0"] = RemoteTurn(id: "n0", conversationID: noPrompt, agentID: "claude", role: .user, origin: .followUp, text: "Only Claude", created: start, ordinal: 0, contentHash: "d")
        let presenter = ProjectionPresenter(state: state)
        XCTAssertEqual(presenter.pinnedPrompt(for: group)?.id, "g0")
        XCTAssertEqual(presenter.pinnedPrompt(for: group, agentID: "codexCLI")?.id, "g0", "An agent's view still starts with the shared prompt")
        XCTAssertEqual(presenter.pinnedPrompt(for: direct)?.id, "d0", "A direct thread pins the prompt that started it")
        XCTAssertNil(presenter.pinnedPrompt(for: noPrompt), "No shared prompt, no pin")
        XCTAssertNil(presenter.pinnedPrompt(for: noPrompt, agentID: "claude"))
    }

    func testSenderLabelsNameTheFormOnlyWhenTwoFormsShareAConversation() {
        var state = ProjectionState()
        func agent(_ id: String, _ product: AgentProduct, _ form: AgentForm, _ name: String) -> AgentAvailability {
            AgentAvailability(agentID: id, product: product, form: form, displayName: name, visibleInGrid: true, selectedForSharedSend: true,
                              capabilities: AgentCapabilities(sharedSend: true, privateSend: true, attachments: false, namedCopies: false, endConversation: true, sharesOneConversation: false),
                              readiness: .ready, reasons: [], observedAt: fixedNow, source: .live)
        }
        for a in [agent("chatgpt", .chatgpt, .website, "ChatGPT"), agent("chatgptApp", .chatgpt, .macApp, "ChatGPT"), agent("claude", .claude, .website, "Claude")] { state.agents[a.agentID] = a }
        let both = UUID(), one = UUID()
        state.conversations[both] = RemoteConversation(id: both, title: "T", prompt: "P", created: fixedNow, endedAt: nil, agentIDs: ["chatgpt", "chatgptApp", "claude"], canEnd: true, unresolvedAttemptCount: 0, lastActivity: fixedNow)
        state.conversations[one] = RemoteConversation(id: one, title: "T", prompt: "P", created: fixedNow, endedAt: nil, agentIDs: ["chatgptApp", "claude"], canEnd: true, unresolvedAttemptCount: 0, lastActivity: fixedNow)
        let presenter = ProjectionPresenter(state: state)
        XCTAssertEqual(presenter.senderLabel("chatgptApp", in: both), "ChatGPT · Mac app")
        XCTAssertEqual(presenter.senderLabel("chatgpt", in: both), "ChatGPT · Web")
        XCTAssertEqual(presenter.senderLabel("claude", in: both), "Claude")
        XCTAssertEqual(presenter.senderLabel("chatgptApp", in: one), "ChatGPT", "One form: the name alone")
    }

    @MainActor func testOpeningAConversationIsRememberedAndForgotten() throws {
        let database = try LocalDatabase(url: nil)
        let store = MobileStore(database: database)
        let id = UUID(), opened = Date(timeIntervalSince1970: 1_800_000_000)
        store.markOpened(id, at: opened)
        store.markOpened(id, at: opened.addingTimeInterval(-10))
        XCTAssertEqual(MobileStore(database: database).lastOpened[id], opened, "Kept across launches; never moves back")
        store.forgetMac()
        XCTAssertNil(MobileStore(database: database).lastOpened[id])
    }

    func testBlockedLinesKeepTheMacsLongerReasonAsDetail() throws {
        var state = try RecordedFixtures.reduce(["snapshot"])
        var app = try XCTUnwrap(state.agents["chatgptApp"])
        let usage = "An earlier request to ChatGPT did not complete. Review it before sending again; usage may have been consumed."
        app.readiness = .blocked
        app.reasons = [AvailabilityReason(code: .incompleteRequestBlocking, userText: "Finish the ChatGPT request first", fixOn: .phone, attemptID: "A1", detail: usage)]
        state.agents["chatgptApp"] = app
        let block = try XCTUnwrap(ProjectionPresenter(state: state).composeBlock(canSend: true, connectionText: "", agentIDs: ["chatgptApp"], conversation: nil, prepareReasons: [:]))
        XCTAssertEqual(block, .blocked("Finish the ChatGPT request first", detail: usage))
        XCTAssertFalse(block.allowsSend)
        XCTAssertEqual(ProjectionPresenter.agentStatus(app), "Finish the ChatGPT request first")
    }

    func testIncompleteSummaryRecipientsAndTimestamps() throws {
        var state = ProjectionState()
        let conversation = UUID(), started = Date(timeIntervalSince1970: 1_800_000_000)
        state.agents["museApp"] = AgentAvailability(agentID: "museApp", product: .muse, form: .macApp, displayName: "Muse", visibleInGrid: true, selectedForSharedSend: true,
            capabilities: AgentCapabilities(sharedSend: true, privateSend: true, attachments: false, namedCopies: false, endConversation: true, sharesOneConversation: false),
            readiness: .blocked, reasons: [AvailabilityReason(code: .incompleteRequestBlocking, userText: "Finish the Muse request first", fixOn: .phone, detail: "Usage may have been consumed.")],
            observedAt: started, source: .live)
        state.attempts["wa:1"] = RemoteAttempt(id: "wa:1", conversationID: conversation, agentID: "museApp", text: "Hi", status: .attempting, detail: "Outgoing message observed in the app. Waiting for its reply.", created: started)
        let incomplete = RemoteIncompleteAttempt(agentID: "museApp", attemptID: "wa:1", reasonCode: .incompleteRequestBlocking)
        let running = ProjectionPresenter(state: state).incompleteSummary(incomplete)
        XCTAssertTrue(running.running); XCTAssertEqual(running.title, "Waiting for Muse…"); XCTAssertEqual(running.started, started)
        XCTAssertEqual(running.details, ["Outgoing message observed in the app. Waiting for its reply.", "Usage may have been consumed."], "Every Mac reason stays reachable")
        state.attempts["wa:1"]?.status = .uncertain
        let review = ProjectionPresenter(state: state).incompleteSummary(incomplete)
        XCTAssertFalse(review.running); XCTAssertEqual(review.title, "Muse didn't reply")

        let presenter = ProjectionPresenter(state: state)
        XCTAssertEqual(presenter.recipientSummary(["museApp", "claude"], members: ["claude", "museApp"]), "To everyone")
        XCTAssertEqual(presenter.recipientSummary(["museApp"], members: ["claude", "museApp"]), "Only Muse")
        XCTAssertEqual(presenter.recipientSummary(["a", "b"], members: ["a", "b", "c"]), "To 2 agents")
        let chip = StatusChip(agentID: "museApp", agentName: "Muse", state: .sending, reason: nil)
        XCTAssertEqual(chip.label(showsName: false), "Sending"); XCTAssertEqual(chip.label(showsName: true), "Muse\u{00A0}·\u{00A0}Sending", "The separator never starts a line")

        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US")
        let now = Date(timeIntervalSince1970: 1_800_000_000)  // Friday 15 January 2027, 08:00 UTC
        XCTAssertEqual(ProjectionPresenter.inboxTimestamp(now.addingTimeInterval(-3600), now: now, calendar: calendar, locale: locale).replacingOccurrences(of: "\u{202F}", with: " "), "7:00 AM")
        XCTAssertEqual(ProjectionPresenter.inboxTimestamp(now.addingTimeInterval(-86_400), now: now, calendar: calendar, locale: locale), "Yesterday")
        XCTAssertEqual(ProjectionPresenter.inboxTimestamp(now.addingTimeInterval(-3 * 86_400), now: now, calendar: calendar, locale: locale), "Tuesday")
        XCTAssertEqual(ProjectionPresenter.inboxTimestamp(now.addingTimeInterval(-30 * 86_400), now: now, calendar: calendar, locale: locale), "12/16/26")
    }
}

@MainActor
final class MobileAppTests: XCTestCase {
    func testPairSendAndUnconfirmedWhenTheConnectionDrops() async throws {
        let mac = FakeMac()
        let defaults = UserDefaults(suiteName: "msgblast-mobile-tests-\(UUID().uuidString)")!
        let app = MobileApp(database: try LocalDatabase(url: nil), keys: MemoryDeviceKeyStore(), defaults: defaults,
                            makeTransport: { [mac] in mac.transport(for: $0, spki: $1) })
        app.connection.timing.backoff = [.seconds(30)]
        XCTAssertThrowsError(try app.send(.setKeepAwake(enabled: true)), "Never queued while disconnected")
        let paired = try await app.pair(link: mac.offer().url.absoluteString, deviceName: "Phone")
        XCTAssertEqual(paired.macName, "Fake Mac")
        for _ in 0..<100 where app.store.projection.seq == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(app.store.projection.seq, 10)

        let result = try await app.perform(.sendPrivate(conversationID: nil, agentID: "codexCLI", text: "Hi", attachmentIDs: []))
        XCTAssertEqual(result.outcome, .applied)
        XCTAssertEqual(app.store.commands[result.clientCommandID]?.status, .applied)

        mac.answerCommands = false
        let pending = try app.send(.sendPrivate(conversationID: nil, agentID: "codexCLI", text: "Lost", attachmentIDs: []))
        for _ in 0..<100 where !mac.commands.contains(where: { $0.clientCommandID == pending.clientCommandID }) { try await Task.sleep(for: .milliseconds(5)) }
        mac.sessions.last!.transport.drop()
        for _ in 0..<100 where app.store.commands[pending.clientCommandID]?.status != .unconfirmed { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(app.store.commands[pending.clientCommandID]?.status, .unconfirmed)
        XCTAssertEqual(mac.commands.filter { $0.clientCommandID == pending.clientCommandID }.count, 1, "Not resent")
        app.forgetMac()
        XCTAssertEqual(app.connection.state, .unpaired)
    }

    func testAvatarsAreFetchedOnceCachedAndClearedByForget() async throws {
        let mac = FakeMac()
        let image = Data("png-bytes".utf8)
        let ref = "sha256:" + SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
        let lying = "sha256:" + String(repeating: "0", count: 64)
        mac.avatars = [ref: image, lying: Data("other".utf8)]
        func agent(_ id: String, _ avatarRef: String?) -> AgentAvailability {
            AgentAvailability(agentID: id, product: .claude, form: .website, displayName: id, avatarRef: avatarRef, visibleInGrid: true, selectedForSharedSend: true,
                              capabilities: AgentCapabilities(sharedSend: true, privateSend: true, attachments: false, namedCopies: false, endConversation: true, sharesOneConversation: false),
                              readiness: .ready, reasons: [], observedAt: fixedNow, source: .live)
        }
        mac.snapshot.agents = [agent("claude", ref), agent("copy", ref), agent("liar", lying), agent("old", "provider:grok"), agent("none", nil)]
        let database = try LocalDatabase(url: nil)
        let app = MobileApp(database: database, keys: MemoryDeviceKeyStore(), defaults: UserDefaults(suiteName: "msgblast-mobile-tests-\(UUID().uuidString)")!,
                            makeTransport: { [mac] in mac.transport(for: $0, spki: $1) })
        _ = try await app.pairAndWaitForInbox(offer: mac.offer(), deviceName: "Phone")
        for _ in 0..<200 where app.store.avatar(ref) == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(app.store.avatar(ref), image)
        XCTAssertNil(app.store.avatar(lying), "Bytes that do not match their reference are dropped")
        let fetches = mac.commands.compactMap { if case .fetchAvatar(let ref) = $0.action { ref } else { nil } }
        XCTAssertEqual(fetches.sorted(), [ref, lying].sorted(), "One request per content reference; other strings are never fetched")
        XCTAssertTrue(app.store.commands.isEmpty, "Artwork requests stay out of the command ledger")

        app.requestAvatars()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(mac.commands.filter { if case .fetchAvatar = $0.action { true } else { false } }.count, 2, "No retry storm")
        XCTAssertEqual(MobileStore(database: database).avatar(ref), image, "Cached across launches")
        app.forgetMac()
        XCTAssertTrue(app.store.avatars.isEmpty)
        XCTAssertNil(MobileStore(database: database).avatar(ref), "Forget This Mac clears the cache")
    }

    func testAnOlderMacLeavesInitials() async throws {
        let mac = FakeMac()
        mac.avatars = nil
        mac.snapshot.agents = [AgentAvailability(agentID: "claude", product: .claude, form: .website, displayName: "Claude", avatarRef: "sha256:" + String(repeating: "a", count: 64),
            visibleInGrid: true, selectedForSharedSend: true, capabilities: AgentCapabilities(sharedSend: true, privateSend: true, attachments: false, namedCopies: false, endConversation: true, sharesOneConversation: false),
            readiness: .ready, reasons: [], observedAt: fixedNow, source: .live)]
        let app = MobileApp(database: try LocalDatabase(url: nil), keys: MemoryDeviceKeyStore(), defaults: UserDefaults(suiteName: "msgblast-mobile-tests-\(UUID().uuidString)")!,
                            makeTransport: { [mac] in mac.transport(for: $0, spki: $1) })
        _ = try await app.pairAndWaitForInbox(offer: mac.offer(), deviceName: "Phone")
        for _ in 0..<100 where !mac.commands.contains(where: { if case .fetchAvatar = $0.action { true } else { false } }) { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(30))
        app.requestAvatars()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(app.store.avatars.isEmpty)
        XCTAssertEqual(mac.commands.filter { if case .fetchAvatar = $0.action { true } else { false } }.count, 1, "An unsupported answer is not repeated")
        XCTAssertEqual(app.connection.state, .connected, "No artwork is not an error")
    }

    func testRepairingReturnsOnlyOnceTheNewInboxIsReady() async throws {
        let mac = FakeMac()
        let app = MobileApp(database: try LocalDatabase(url: nil), keys: MemoryDeviceKeyStore(),
                            defaults: UserDefaults(suiteName: "msgblast-mobile-tests-\(UUID().uuidString)")!,
                            makeTransport: { [mac] in mac.transport(for: $0, spki: $1) })
        _ = try await app.pairAndWaitForInbox(offer: mac.offer(), deviceName: "Phone")
        XCTAssertTrue(app.inboxReady)

        // Pairing again replaces the cache; the call waits for the new Mac's snapshot.
        mac.snapshotDelay = .milliseconds(200)
        let started = ContinuousClock.now
        _ = try await app.pairAndWaitForInbox(offer: mac.offer(), deviceName: "Phone")
        XCTAssertTrue(app.inboxReady, "Returns onto a filled inbox")
        XCTAssertEqual(app.store.projection.seq, 10)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(200))

        // A failed attempt throws and keeps the existing pairing, so a sheet can stay open.
        let before = app.connection.pairedMac
        var wrong = mac.offer(); wrong.code = "wrong"
        do { _ = try await app.pairAndWaitForInbox(offer: wrong, deviceName: "Phone"); XCTFail("A wrong code must not pair") } catch {}
        XCTAssertEqual(app.connection.pairedMac, before)
    }
}
