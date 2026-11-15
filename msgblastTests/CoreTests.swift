import XCTest
@testable import msgblastCore
final class CoreTests: XCTestCase {
    func testEndedConversationCutoffSurvivesCodableAndRejectsLateLinkedReplies() throws {
        var comparison = Comparison(prompt: "Original", members: [])
        let cutoff = Date(timeIntervalSince1970: 100)
        comparison.endedAt = cutoff
        comparison.endMessageRows = ["chat": 5]
        let restored = try JSONDecoder().decode(Comparison.self, from: JSONEncoder().encode(comparison))
        let before = Message(id: 5, guid: "before", chatID: "chat", text: "Kept", outgoing: false, date: cutoff)
        let late = Message(id: 6, guid: "late", chatID: "chat", text: "Late", outgoing: false, replyTo: "before", date: cutoff.addingTimeInterval(-1))
        XCTAssertTrue(restored.includes(before))
        XCTAssertFalse(restored.includes(late))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(comparison)) as! [String: Any]
        json.removeValue(forKey: "endedAt"); json.removeValue(forKey: "endMessageRows")
        let legacy = try JSONDecoder().decode(Comparison.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.endedAt)
        XCTAssertTrue(legacy.includes(late))
    }
    func testJoiningAgentReceivesOnlySharedContextAndKeepsItAfterMembershipChanges() throws {
        let members = ["A", "B"].map { Member(agentID: UUID(), name: $0, chat: Chat(id: $0, handle: $0, lastActivity: 0)) }
        var comparison = Comparison(prompt: "Original ask", members: members)
        var shared = FollowUp(text: "Shared follow-up", memberIDs: members.map(\.id))
        shared.sharedWithAll = true
        for member in members { shared.states[member.id.uuidString] = .submitted }
        var privateMessage = FollowUp(text: "Private detail", memberIDs: [members[0].id])
        privateMessage.states[members[0].id.uuidString] = .submitted
        comparison.followUps = [shared, privateMessage]
        let context = comparison.joiningContext()
        XCTAssertEqual(context.map(\.text), ["Original ask", "Shared follow-up"])
        XCTAssertEqual(comparison.joiningPrompt(), "Original ask\n\nShared follow-up")
        comparison.sharedContext = Array(context.dropFirst())
        comparison.members.append(Member(agentID: UUID(), name: "C", chat: Chat(id: "C", handle: "C", lastActivity: 0)))
        let restored = try JSONDecoder().decode(Comparison.self, from: JSONEncoder().encode(comparison))
        XCTAssertEqual(restored.joiningContext().map(\.text), ["Original ask", "Shared follow-up"])
        XCTAssertEqual(restored.joiningPrompt(), "Original ask\n\nShared follow-up")
    }

    func testUnmarkedMultiProviderLegacyHistoryIsExcluded() throws {
        var comparison = Comparison(prompt: "Original", members: [])
        comparison.webProviders = [.muse, .chatgpt]
        var unknown = ConversationContextMessage(text: "Repeated private detail")
        unknown.sharedWithAll = nil
        comparison.sharedContext = [unknown, unknown]
        let restored = try JSONDecoder().decode(Comparison.self, from: JSONEncoder().encode(comparison))
        XCTAssertEqual(restored.joiningContext().map(\.text), ["Original"])
        XCTAssertEqual(restored.joiningPrompt(), "Original")
    }

    func testJoiningPayloadPreservesAttachmentAndMessageOrder() {
        let originalFile = MessageAttachment(filename: "original.txt", path: "/fixture/original.txt")
        let sharedFile = MessageAttachment(filename: "shared.txt", path: "/fixture/shared.txt")
        var comparison = Comparison(prompt: "Original", members: [])
        comparison.attachments = [originalFile]
        comparison.sharedContext = [ConversationContextMessage(text: "Follow-up", attachments: [sharedFile])]
        let parts = comparison.joiningPayload().parts
        XCTAssertEqual(parts.count, 4)
        XCTAssertEqual(parts[0].text, "Original")
        XCTAssertEqual(parts[1].attachment, originalFile)
        XCTAssertEqual(parts[2].text, "Follow-up")
        XCTAssertEqual(parts[3].attachment, sharedFile)
        XCTAssertTrue(parts.allSatisfy { $0.state == .ready })
    }

    func testLegacySingleMessagesRecipientNeverInfersPrivateHistoryAsShared() throws {
        let member = Member(agentID: UUID(), name: "A", chat: Chat(id: "A", handle: "A", lastActivity: 0))
        var comparison = Comparison(prompt: "Original", members: [member])
        var privateReply = FollowUp(text: "Private detail", memberIDs: [member.id])
        privateReply.states[member.id.uuidString] = .submitted
        comparison.followUps = [privateReply]
        let restored = try JSONDecoder().decode(Comparison.self, from: JSONEncoder().encode(comparison))
        XCTAssertEqual(restored.joiningContext().map(\.text), ["Original"])
    }

    func testLegacySoleCLIReceiptsNeverAuthorizeSharingPrivateFollowUps() throws {
        var comparison = Comparison(prompt: "Original", members: [])
        comparison.webProviders = [.codexCLI]
        var unknown = ConversationContextMessage(text: "Private detail")
        unknown.sharedWithAll = nil
        comparison.sharedContext = [unknown]
        let restored = try JSONDecoder().decode(Comparison.self, from: JSONEncoder().encode(comparison))
        XCTAssertEqual(restored.joiningContext().map(\.text), ["Original"])
    }

    func testUnmarkedCachedLegacyContextIsNotSharedWithNewRecipients() throws {
        var comparison = Comparison(prompt: "Original", members: [])
        comparison.sharedContext = [ConversationContextMessage(text: "Private detail")]
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(comparison)) as? [String: Any])
        var cached = try XCTUnwrap(json["sharedContext"] as? [[String: Any]])
        cached[0].removeValue(forKey: "sharedWithAll")
        json["sharedContext"] = cached
        let restored = try JSONDecoder().decode(Comparison.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored.joiningContext().map(\.text), ["Original"])
    }

    func testPrivateAndSubsetFollowUpsAreExcludedFromEveryJoinTransport() throws {
        let members = ["A", "B"].map { Member(agentID: UUID(), name: $0, chat: Chat(id: $0, handle: $0, lastActivity: 0)) }
        var comparison = Comparison(prompt: "Original", members: members)
        var shared = FollowUp(text: "Shared", memberIDs: members.map(\.id))
        shared.sharedWithAll = true
        for member in members { shared.states[member.id.uuidString] = .submitted }
        var subset = FollowUp(text: "Subset secret", memberIDs: [members[0].id])
        subset.sharedWithAll = false
        subset.states[members[0].id.uuidString] = .submitted
        var privateReply = FollowUp(text: "Private secret", memberIDs: [members[1].id])
        privateReply.sharedWithAll = false
        privateReply.states[members[1].id.uuidString] = .submitted
        comparison.followUps = [shared, subset, privateReply]
        let restored = try JSONDecoder().decode(Comparison.self, from: JSONEncoder().encode(comparison))
        XCTAssertEqual(restored.joiningContext().map(\.text), ["Original", "Shared"])
        XCTAssertFalse(restored.joiningPrompt().contains("secret"))
        XCTAssertEqual(restored.joiningPayload().parts.compactMap(\.text), ["Original", "Shared"])
    }

    func testRetryOfEarlierSharedFollowUpKeepsOriginalOrderAndAttachments() throws {
        let members = ["A", "B"].map { Member(agentID: UUID(), name: $0, chat: Chat(id: $0, handle: $0, lastActivity: 0)) }
        var comparison = Comparison(prompt: "Original", members: members)
        let fileA = MessageAttachment(filename: "A.txt", path: "/fixture/A.txt")
        let fileB = MessageAttachment(filename: "B.txt", path: "/fixture/B.txt")
        var a = FollowUp(text: "A", memberIDs: members.map(\.id))
        a.sharedWithAll = true; a.created = Date(timeIntervalSince1970: 1)
        a.states = [members[0].id.uuidString: .submitted, members[1].id.uuidString: .failed]
        a.payloads = [members[0].id.uuidString: OutgoingPayload(text: "A", attachments: [fileA])]
        var b = FollowUp(text: "B", memberIDs: members.map(\.id))
        b.sharedWithAll = true; b.created = Date(timeIntervalSince1970: 2)
        for member in members { b.states[member.id.uuidString] = .submitted }
        b.payloads = [members[0].id.uuidString: OutgoingPayload(text: "B", attachments: [fileB])]
        comparison.followUps = [a, b]
        comparison.recordSharedFollowUp(a)
        comparison.recordSharedFollowUp(b)
        XCTAssertEqual(comparison.joiningContext().map(\.text), ["Original", "B"])
        a.states[members[1].id.uuidString] = .submitted
        comparison.followUps[0] = a
        comparison.recordSharedFollowUp(a)
        comparison.recordSharedFollowUp(a)
        let restored = try JSONDecoder().decode(Comparison.self, from: JSONEncoder().encode(comparison))
        XCTAssertEqual(restored.joiningContext().map(\.text), ["Original", "A", "B"])
        XCTAssertEqual(restored.joiningContext().dropFirst().map(\.followUpID), [a.id, b.id])
        let parts = restored.joiningPayload().parts
        XCTAssertEqual(parts.compactMap(\.text), ["Original", "A", "B"])
        XCTAssertEqual(parts.compactMap(\.attachment), [fileA, fileB])
        XCTAssertEqual(restored.joiningPrompt(), "Original\n\nA\n\nB")
    }

    func testDelayedBroadcastCompletionMarksOnlyItsExactFollowUp() {
        let member = Member(agentID: UUID(), name: "A", chat: Chat(id: "A", handle: "A", lastActivity: 0))
        var comparison = Comparison(prompt: "Original", members: [member])
        var shared = FollowUp(text: "Shared broadcast", memberIDs: [member.id])
        shared.sharedWithAll = false
        shared.states[member.id.uuidString] = .submitted
        var laterPrivate = FollowUp(text: "Private after Messages completed", memberIDs: [member.id])
        laterPrivate.sharedWithAll = false
        laterPrivate.states[member.id.uuidString] = .submitted
        comparison.followUps = [shared, laterPrivate]
        comparison.completeSharedBroadcast(followUpID: shared.id, recipients: [member.id])
        XCTAssertEqual(comparison.followUps[0].sharedWithAll, true)
        XCTAssertEqual(comparison.followUps[1].sharedWithAll, false)
        XCTAssertEqual(comparison.joiningContext().map(\.text), ["Original", "Shared broadcast"])
        XCTAssertEqual(comparison.joiningPayload().parts.compactMap(\.text), ["Original", "Shared broadcast"])
    }

    func testManualAccountCanBeCreatedWithoutAnExistingChat() throws {
        let email = try XCTUnwrap(Agent.manualAccount(for: "  msgisaway@outlook.com\n"))
        XCTAssertEqual(email.handles, ["msgisaway@outlook.com"])
        XCTAssertNil(email.contactID)
        XCTAssertNil(ChatResolver.resolve(handles: email.handles, chats: []))
        XCTAssertEqual(Agent.manualAccount(for: "+1 (415) 555-0123")?.handles, ["+1 (415) 555-0123"])
        for invalid in ["", "Michael Galpert", "@outlook.com", "user@", "user@@example.com", "user name@example.com", "agent12345", "123"] {
            XCTAssertNil(Agent.manualAccount(for: invalid), invalid)
        }
    }
    func testRefreshRemovesUnavailableSelectionsWithoutReselectingExcludedAgents() throws {
        let available = Agent(contactID: "available", name: "Available", handles: ["a@example.com"])
        let excluded = Agent(contactID: "excluded", name: "Excluded", handles: ["b@example.com"])
        let pending = Agent(contactID: "pending", name: "Pending", handles: ["pending@example.com"])
        var state = AppState()
        state.agents = [available, excluded, pending]
        state.selection = [available.id, pending.id, UUID()]
        let chats = [Chat(id: "a", handle: "a@example.com", lastActivity: 0), Chat(id: "b", handle: "b@example.com", lastActivity: 0), Chat(id: "sms", handle: "pending@example.com", lastActivity: 0, service: "SMS")]
        XCTAssertTrue(state.retainAvailableSelection(chats: chats))
        XCTAssertEqual(state.selection, [available.id])
        XCTAssertFalse(state.retainAvailableSelection(chats: chats))
        let restored = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.agents.last?.contactID, "pending")
        XCTAssertEqual(restored.selection, [available.id])
    }
    func testUniversalRecipientsDefaultToEveryoneAndConversationSelectionTargetsOnlyOne() {
        let members = ["Cedar", "Lumen", "Orbit"].map { Member(agentID: UUID(), name: $0, chat: Chat(id: $0, handle: $0 + "@example.com", lastActivity: 0)) }
        var recipients = ConversationRecipients()
        XCTAssertEqual(recipients.recipientIDs(in: members), members.map(\.id))
        recipients.selectConversation(members[1].id)
        XCTAssertEqual(recipients.recipientIDs(in: members), [members[1].id])
        recipients.selectConversation(members[1].id)
        XCTAssertEqual(recipients.recipientIDs(in: members), [members[1].id])
        recipients = ConversationRecipients()
        XCTAssertEqual(recipients.recipientIDs(in: members), members.map(\.id))
        recipients.selectConversation(UUID())
        XCTAssertTrue(recipients.recipientIDs(in: members).isEmpty)
    }
    func testNamePillsToggleDisplayedRecipientsIncludingAfterPrivateFocus() {
        let members = ["Cedar", "Lumen", "Orbit"].map { Member(agentID: UUID(), name: $0, chat: Chat(id: $0, handle: $0 + "@example.com", lastActivity: 0)) }
        var recipients = ConversationRecipients()
        recipients.toggleRecipient(members[0].id, in: members)
        XCTAssertEqual(recipients.recipientIDs(in: members), [members[1].id, members[2].id])
        recipients.toggleRecipient(members[0].id, in: members)
        XCTAssertEqual(recipients.recipientIDs(in: members), members.map(\.id))
        recipients.selectConversation(members[0].id)
        recipients.toggleRecipient(members[1].id, in: members)
        XCTAssertNil(recipients.selectedConversation)
        XCTAssertEqual(recipients.recipientIDs(in: members), [members[0].id, members[1].id])
        recipients.toggleRecipient(members[0].id, in: members)
        XCTAssertEqual(recipients.recipientIDs(in: members), [members[1].id])
        recipients.toggleRecipient(members[1].id, in: members)
        XCTAssertTrue(recipients.recipientIDs(in: members).isEmpty)
        recipients.toggleRecipient(members[2].id, in: members)
        XCTAssertEqual(recipients.recipientIDs(in: members), [members[2].id])
    }
    func testUniversalSelectionPersistsWithOneDraftAndDoesNotRetargetSavedRetry() throws {
        let members = ["Cedar", "Lumen", "Orbit"].map { Member(agentID: UUID(), name: $0, chat: Chat(id: $0, handle: $0 + "@example.com", lastActivity: 0)) }
        var comparison = Comparison(prompt: "prompt", members: members)
        var recipients = ConversationRecipients()
        recipients.toggleRecipient(members[1].id, in: members)
        comparison.recipientSelection = recipients
        comparison.allDraft = "the same draft"
        var attempt = FollowUp(text: "frozen", memberIDs: recipients.recipientIDs(in: members))
        attempt.states[members[0].id.uuidString] = .submitted
        attempt.states[members[2].id.uuidString] = .failed
        comparison.followUps = [attempt]
        recipients.selectConversation(members[1].id)
        comparison.recipientSelection = recipients
        let restored = try JSONDecoder().decode(Comparison.self, from: JSONEncoder().encode(comparison))
        XCTAssertEqual(restored.recipientSelection?.recipientIDs(in: members), [members[1].id])
        XCTAssertEqual(restored.allDraft, "the same draft")
        XCTAssertEqual(restored.followUps[0].recipientsForRecovery(resumeUnsent: false), [members[2].id])
        XCTAssertFalse(restored.followUps[0].memberIDs.contains(members[1].id))
    }
    func testComparisonWindowsDefaultToConnectedAndLegacyStateStillLoads() throws {
        XCTAssertEqual(AppState().effectiveWindowStyle, .connected)
        let legacy = Data("""
        {"version":1,"agents":[],"comparisons":[],"draft":"saved prompt","selection":[],"frames":{}}
        """.utf8)
        let restored = try JSONDecoder().decode(AppState.self, from: legacy)
        XCTAssertEqual(restored.effectiveWindowStyle, .connected)
        XCTAssertEqual(restored.draft, "saved prompt")
    }
    func testWindowPreferencePersistsWithoutChangingConversationDraftsOrReceipts() throws {
        let member = Member(agentID: UUID(), name: "Cedar", chat: Chat(id: "cedar", handle: "cedar@example.com", lastActivity: 0))
        var comparison = Comparison(prompt: "original prompt", members: [member])
        comparison.members[0].submission = .submitted
        comparison.members[0].anchor = Anchor(rowID: 100, guid: "accepted")
        comparison.allDraft = "everyone draft"
        comparison.privateDrafts[member.id.uuidString] = "private draft"
        var state = AppState()
        state.comparisons = [comparison]
        for style in [ComparisonWindowStyle.separate, .connected] {
            state.windowStyle = style
            let restored = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state)).recoveringInFlight()
            XCTAssertEqual(restored.effectiveWindowStyle, style)
            XCTAssertEqual(restored.comparisons[0].allDraft, "everyone draft")
            XCTAssertEqual(restored.comparisons[0].privateDrafts[member.id.uuidString], "private draft")
            XCTAssertEqual(restored.comparisons[0].members[0].anchor?.guid, "accepted")
            XCTAssertEqual(restored.comparisons[0].members[0].submission, .submitted)
        }
    }
    func testManualCandidateResolvesItsExistingChatAndSavedContactsRetainTheirIDs() throws {
        let data = Data("""
        {"id":"00000000-0000-0000-0000-000000000001","name":"manual@example.com","handles":["manual@example.com"],"colorIndex":0}
        """.utf8)
        let agent = try JSONDecoder().decode(Agent.self, from: data)
        XCTAssertNil(agent.contactID)
        let chats = [Chat(id: "older", handle: "manual@example.com", lastActivity: 1), Chat(id: "newer", handle: "MANUAL@example.com", lastActivity: 2), Chat(id: "group", handle: "manual@example.com", lastActivity: 9, participantCount: 2)]
        XCTAssertEqual(ChatResolver.resolve(handles: agent.handles, chats: chats)?.id, "newer")
        XCTAssertNil(ChatResolver.resolve(handles: agent.handles, chats: []))
        let contact = Agent(contactID: "existing-contact", name: "Saved Contact", handles: ["saved@example.com"])
        XCTAssertEqual(try JSONDecoder().decode(Agent.self, from: JSONEncoder().encode(contact)).contactID, "existing-contact")
    }
    func testWebPreviewPreservesSurroundingTextAndLeavesOtherLinksAlone() {
        let url = "https://www.apple.com/shop/buy-mac/mac-mini"
        let link = Message(id: 1, guid: "link", chatID: "A", text: url, outgoing: false)
        XCTAssertEqual(link.linkPreview?.url.absoluteString, url)
        XCTAssertEqual(link.linkPreview?.remainingText, "")
        let caption = Message(id: 2, guid: "caption", chatID: "A", text: "See \(url) today", outgoing: false)
        XCTAssertEqual(caption.linkPreview?.remainingText, "See  today")
        let email = Message(id: 3, guid: "email", chatID: "A", text: "mailto:test@example.com", outgoing: false)
        XCTAssertNil(email.linkPreview)
        let unicode = Message(id: 4, guid: "unicode", chatID: "A", text: "https://example.com/café", outgoing: false)
        XCTAssertNotNil(unicode.linkPreview)
        XCTAssertEqual(unicode.linkPreview?.remainingText, "")
    }
    func testChosenDestinationPersistsAndDoesNotRerouteAcrossContactNumbers() throws {
        let first = Chat(id: "first", handle: "+100001", lastActivity: 1)
        let second = Chat(id: "second", handle: "+100002", lastActivity: 99)
        var agent = Agent(name: "Poke", handles: [first.handle, second.handle])
        XCTAssertEqual(ChatResolver.resolve(agent: agent, chats: [first, second])?.id, second.id, "Two numbers automatically use one most recent existing conversation")
        agent.destination = MessagesDestination(chat: first)
        let restored = try JSONDecoder().decode(Agent.self, from: JSONEncoder().encode(agent))
        XCTAssertEqual(ChatResolver.resolve(agent: restored, chats: [second, first])?.id, first.id)
        XCTAssertNil(ChatResolver.resolve(agent: restored, chats: [second]))
        var changed = first; changed.handle = second.handle
        XCTAssertNil(ChatResolver.resolve(agent: restored, chats: [changed, second]))
        var business = first; business.businessConversation = true
        XCTAssertNil(ChatResolver.resolve(agent: restored, chats: [business]))
        XCTAssertNil(ChatResolver.resolve(agent: restored, chats: [first, first]), "Duplicate identities are ambiguous")
        XCTAssertEqual(ChatResolver.normalize("opaque-100001"), "opaque-100001")
    }
    func testExistingSavedPokeIsPinnedOnceAndNeverFallsBackAfterRefresh() throws {
        let handle = "urn:biz:00000000-0000-0000-0000-000000000123"
        let chat = Chat(id: "any;-;" + handle, handle: handle, lastActivity: 1, displayName: "Poke", businessConversation: true)
        var state = AppState()
        let poke = Agent(contactID: "fixture-poke", name: "Poke 🌴", handles: ["+15550000001", "+15550000002"])
        let regular = Agent(name: "Fo", handles: ["fo@example.com"])
        state.agents = [poke, regular]
        XCTAssertTrue(state.pinBusinessDestinations(chats: [chat]))
        let destination = try XCTUnwrap(state.agents[0].destination)
        XCTAssertEqual(destination.chatID, chat.id)
        XCTAssertNil(state.agents[1].destination, "Regular legacy routing is unchanged")
        state = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state))
        var newer = chat; newer.id = "iMessage;-;" + handle; newer.lastActivity = 999
        XCTAssertFalse(state.pinBusinessDestinations(chats: [newer]))
        XCTAssertEqual(state.agents[0].destination, destination)
        let phone = Chat(id: "phone", handle: poke.handles[0], lastActivity: 1000)
        XCTAssertNil(ChatResolver.resolve(agent: state.agents[0], chats: [phone, newer]))
    }
    func testVerifiedBusinessURNIsOneExactSendableDestination() throws {
        let handle = "urn:biz:00000000-0000-0000-0000-000000000123"
        let chat = Chat(id: "iMessage;-;" + handle, handle: handle, lastActivity: 1,
                        displayName: "Poke", businessConversation: true)
        XCTAssertTrue(chat.eligible)
        let agent = Agent(name: "Poke 🌴", handles: ["+15550000001", "+15550000002"])
        XCTAssertEqual(ChatResolver.resolve(agent: agent, chats: [chat])?.id, chat.id)
        XCTAssertEqual(ChatResolver.status(agent: agent, chats: [chat]), "Connected · Business conversation")
        var restored = agent; restored.destination = MessagesDestination(chat: chat)
        restored = try JSONDecoder().decode(Agent.self, from: JSONEncoder().encode(restored))
        XCTAssertEqual(ChatResolver.resolve(agent: restored, chats: [chat])?.id, chat.id)
        var group = chat; group.participantCount = 2
        XCTAssertFalse(group.eligible)
        var sms = chat; sms.service = "SMS"
        XCTAssertFalse(sms.eligible)
        var unverified = chat; unverified.businessConversation = nil
        XCTAssertFalse(unverified.eligible)
        var wrongGUID = chat; wrongGUID.id = "any;+;some-other-thread"
        XCTAssertFalse(wrongGUID.eligible)
        var invalidURN = chat; invalidURN.handle = "urn:biz:not-a-uuid"
        XCTAssertFalse(invalidURN.eligible)
    }
    func testPokeBusinessConversationMatchesAutomaticallyAndPersistsWithoutPhoneGuessing() throws {
        var poke = Agent(name: "Poke 🌴", handles: ["+15550000001", "+15550000002"])
        let business = Chat(id: "business-poke", handle: "opaque-brand-destination", lastActivity: 10,
                            displayName: "Poke", businessConversation: true)
        let ordinary = Chat(id: "ordinary", handle: poke.handles[0], lastActivity: 100)
        let selected = try XCTUnwrap(ChatResolver.conversation(agent: poke, chats: [ordinary, business]))
        XCTAssertEqual(selected.id, business.id)
        poke.destination = MessagesDestination(chat: selected)
        let restored = try JSONDecoder().decode(Agent.self, from: JSONEncoder().encode(poke))
        XCTAssertEqual(ChatResolver.conversation(agent: restored, chats: [business, ordinary])?.id, business.id)
        XCTAssertNil(ChatResolver.conversation(agent: restored, chats: [ordinary]), "Never fall back to phone numbers when the saved Business thread disappears")
        XCTAssertNil(ChatResolver.resolve(agent: restored, chats: [business, ordinary]), "Matching does not prove Business sending is supported")
    }
    func testAutomaticBusinessMatchRejectsUnidentifiedAndAmbiguousBrands() {
        let poke = Agent(name: "Poke", handles: ["+15550000001"])
        let wrongBrand = Chat(id: "wrong", handle: "opaque-one", lastActivity: 10, displayName: "Pokemon", businessConversation: true)
        let unverified = Chat(id: "unknown", handle: "opaque-two", lastActivity: 20, displayName: "Poke")
        XCTAssertNil(ChatResolver.conversation(agent: poke, chats: [wrongBrand, unverified]))
        let first = Chat(id: "one", handle: "business-one", lastActivity: 10, displayName: "Poke", businessConversation: true)
        let second = Chat(id: "two", handle: "business-two", lastActivity: 20, displayName: "Poke", businessConversation: true)
        XCTAssertNil(ChatResolver.conversation(agent: poke, chats: [first, second]))
        let ordinary = Chat(id: "old-phone", handle: poke.handles[0], lastActivity: 100)
        XCTAssertNil(ChatResolver.conversation(agent: poke, chats: [first, second, ordinary]), "Ambiguity must not fall back to either phone number")
        XCTAssertNil(ChatResolver.resolve(agent: poke, chats: [first, second, ordinary]))
        XCTAssertEqual(ChatResolver.status(agent: poke, chats: [first, second, ordinary]), "Multiple Business conversations found · sending unavailable")
        XCTAssertEqual(ChatResolver.resolve(agent: poke, chats: [ordinary])?.id, ordinary.id, "Ordinary Poke chats still work when no Business identity exists")
        XCTAssertNil(ChatResolver.conversation(agent: Agent(name: "Alex Poke", handles: poke.handles), chats: [first]))
        var missingHandle = first; missingHandle.handle = ""
        var anotherMissing = second; anotherMissing.handle = ""
        XCTAssertNil(ChatResolver.conversation(agent: poke, chats: [missingHandle, anotherMissing]))
    }
    func testLegacyAgentStillDecodesWithoutDestination() throws {
        let bytes = Data(#"{"id":"00000000-0000-0000-0000-000000000001","name":"Old","handles":["old@example.com"],"colorIndex":0}"#.utf8)
        let agent = try JSONDecoder().decode(Agent.self, from: bytes)
        XCTAssertNil(agent.destination)
        XCTAssertEqual(ChatResolver.resolve(agent: agent, chats: [Chat(id: "old", handle: "old@example.com", lastActivity: 1)])?.id, "old")
    }
    func testResolverExcludesGroupsAndChoosesNewestExistingIMessage() throws {
        let chats = [Chat(id: "old", handle: "palcowen@gmail.com", lastActivity: 1), Chat(id: "new", handle: "PALCOWEN@gmail.com", lastActivity: 9), Chat(id: "group", handle: "palcowen@gmail.com", lastActivity: 99, participantCount: 2), Chat(id: "sms", handle: "palcowen@gmail.com", lastActivity: 100, service: "SMS")]
        XCTAssertEqual(ChatResolver.resolve(handles: ["palcowen@gmail.com"], chats: chats)?.id, "new")
        XCTAssertNil(ChatResolver.resolve(handles: ["unknown@gmail.com"], chats: chats))
    }
    func testOldRangeKeepsThreadRepliesAndOtherAgentRemainsOpen() {
        let messages = [Message(id: 10, guid: "anchor", chatID: "A", text: "Prompt", outgoing: true), Message(id: 11, guid: "ordinary", chatID: "A", text: "First", outgoing: false), Message(id: 20, guid: "next", chatID: "A", text: "New prompt", outgoing: true), Message(id: 21, guid: "later", chatID: "A", text: "Unrelated", outgoing: false), Message(id: 22, guid: "reply", chatID: "A", text: "Old answer", outgoing: false, replyTo: "anchor"), Message(id: 23, guid: "nested", chatID: "A", text: "Nested", outgoing: false, replyTo: "reply")]
        XCTAssertEqual(ComparisonRange.messages(messages, anchor: Anchor(rowID: 10, guid: "anchor"), next: 20).map(\.id), [10, 11, 22, 23])
        XCTAssertEqual(ComparisonRange.messages(messages, anchor: Anchor(rowID: 10, guid: "anchor"), next: nil).count, 6)
    }
    func testRetryOnlyKnownFailuresNeverUncertainOrSubmitted() {
        XCTAssertTrue(Submission.failed.canRetry)
        XCTAssertFalse(Submission.submitted.canRetry)
        XCTAssertFalse(Submission.sending.canRetry)
        XCTAssertFalse(Submission.uncertain.canRetry)
    }
    func testRestartQuarantinesInFlightSubmission() throws {
        var state = AppState()
        var comparison = Comparison(prompt: "same text", members: [Member(agentID: UUID(), name: "A", chat: Chat(id: "A", handle: "a@example.com", lastActivity: 0))])
        comparison.members[0].submission = .sending
        state.comparisons = [comparison]
        let restored = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state)).recoveringInFlight()
        XCTAssertEqual(restored.comparisons[0].members[0].submission, .uncertain)
    }
    func testChatWindowWidthGrowsWithSevenOpenChats() {
        XCTAssertEqual(WindowLayout.chatWindowWidth(count: 4, surroundingWidth: 260, screenWidth: 3200), 1823)
        XCTAssertEqual(WindowLayout.chatWindowWidth(count: 7, surroundingWidth: 260, screenWidth: 3200), 2996)
    }
    func testChatWindowWidthFitsScreenAndShrinksForFewerChats() {
        XCTAssertEqual(WindowLayout.chatWindowWidth(count: 7, surroundingWidth: 260, screenWidth: 1440), 1440)
        XCTAssertEqual(WindowLayout.chatWindowWidth(count: 1, surroundingWidth: 260, screenWidth: 1440), 760)
    }
    func testSixColumnsRemainReadableAndOrdered() {
        let frames = WindowLayout.columns(count: 6, screenWidth: 1200, screenHeight: 800)
        XCTAssertEqual(frames.count, 6)
        XCTAssertTrue(frames.allSatisfy { $0.width >= 320 && $0.y == frames[0].y })
        XCTAssertTrue(zip(frames, frames.dropFirst()).allSatisfy { $0.x + $0.width <= $1.x })
    }
    func testPhoneAndEmailNormalization() {
        XCTAssertEqual(ChatResolver.normalize("+1 (415) 555-0123"), "+14155550123")
        XCTAssertEqual(ChatResolver.normalize("A@EXAMPLE.COM"), "a@example.com")
    }
    private func heldConversation(prompt: String = "Prompt", chat: Chat = Chat(id: "A", handle: "a@example.com", lastActivity: 0)) -> Comparison {
        var comparison = Comparison(prompt: prompt, members: [Member(agentID: UUID(), name: "Fo", chat: chat)])
        comparison.members[0].submission = .submitted
        comparison.members[0].baseline = 9
        comparison.members[0].anchor = Anchor(rowID: 10, guid: "anchor")
        return comparison
    }
    private func row(_ id: Int64, _ text: String, outgoing: Bool = false, hours: Double) -> Message {
        Message(id: id, guid: "g\(id)", chatID: "A", text: text, outgoing: outgoing, date: Date(timeIntervalSince1970: hours * 3600))
    }
    func testConversationLetsGoWhenYouMessageTheContactOutsideMsgblast() {
        let comparison = heldConversation()
        let history = [Message(id: 10, guid: "anchor", chatID: "A", text: "Prompt", outgoing: true, date: Date(timeIntervalSince1970: 0)),
                       row(11, "Answer", hours: 0.1), row(20, "Typed in Messages", outgoing: true, hours: 1), row(21, "Answer to that", hours: 1.1)]
        XCTAssertEqual(ComparisonRange.transcript(history, comparison: comparison, member: comparison.members[0], comparisons: [comparison]).map(\.id), [10, 11])
    }
    func testConversationLetsGoAfterAQuietHalfHourAndItsOwnFollowUpTakesTheChatBack() {
        var comparison = heldConversation()
        let anchor = Message(id: 10, guid: "anchor", chatID: "A", text: "Prompt", outgoing: true, date: Date(timeIntervalSince1970: 0))
        var history = [anchor, row(11, "Answer", hours: 0.4), row(12, "More", hours: 0.8), row(13, "Weeks later", hours: 500), row(14, "And again", hours: 500.1)]
        XCTAssertEqual(ComparisonRange.transcript(history, comparison: comparison, member: comparison.members[0], comparisons: [comparison]).map(\.id), [10, 11, 12])
        var followUp = FollowUp(text: "Follow-up", memberIDs: [comparison.members[0].id])
        followUp.states[comparison.members[0].id.uuidString] = .submitted
        comparison.followUps = [followUp]
        history += [row(15, "Follow-up", outgoing: true, hours: 600), row(16, "Reply", hours: 600.1)]
        XCTAssertEqual(ComparisonRange.transcript(history, comparison: comparison, member: comparison.members[0], comparisons: [comparison]).map(\.id), [10, 11, 12, 15, 16])
    }
    func testUnidentifiedSendKeepsEverySentRowUntilItResolves() {
        var comparison = heldConversation()
        var followUp = FollowUp(text: "Photo", memberIDs: [comparison.members[0].id])
        followUp.states[comparison.members[0].id.uuidString] = .uncertain
        comparison.followUps = [followUp]
        let history = [Message(id: 10, guid: "anchor", chatID: "A", text: "Prompt", outgoing: true, date: Date(timeIntervalSince1970: 0)),
                       row(11, "", outgoing: true, hours: 0.1), row(12, "Nice photo", hours: 0.2)]
        XCTAssertEqual(ComparisonRange.transcript(history, comparison: comparison, member: comparison.members[0], comparisons: [comparison]).map(\.id), [10, 11, 12])
    }
    func testNewConversationWithoutAnAnchorTakesItsRepliesFromTheOlderOne() {
        let old = heldConversation()
        var newer = heldConversation(prompt: "Sent by an outside agent")
        newer.members[0].anchor = nil
        newer.members[0].baseline = 30
        let history = [Message(id: 10, guid: "anchor", chatID: "A", text: "Prompt", outgoing: true, date: Date(timeIntervalSince1970: 0)),
                       row(11, "Old answer", hours: 0.1), row(31, "Text Messages changed", outgoing: true, hours: 1), row(32, "New answer", hours: 1.1)]
        let all = [newer, old]
        XCTAssertEqual(ComparisonRange.transcript(history, comparison: old, member: old.members[0], comparisons: all).map(\.id), [10, 11])
        XCTAssertEqual(ComparisonRange.transcript(history, comparison: newer, member: newer.members[0], comparisons: all).map(\.id), [31, 32])
        XCTAssertEqual(ComparisonRange.nextAnchor(for: old, member: old.members[0], comparisons: all), 31)
        // A send that never left the Mac claims nothing.
        newer.members[0].submission = .failed
        XCTAssertNil(ComparisonRange.nextAnchor(for: old, member: old.members[0], comparisons: [newer, old]))
        XCTAssertTrue(ComparisonRange.transcript(history, comparison: newer, member: newer.members[0], comparisons: [newer, old]).isEmpty)
    }
    private func letGoHistory() -> [Message] {
        [Message(id: 10, guid: "anchor", chatID: "A", text: "Prompt", outgoing: true, date: Date(timeIntervalSince1970: 0)),
         row(11, "Answer", hours: 0.1), row(20, "Typed in Messages", outgoing: true, hours: 100), row(21, "Weeks later", hours: 100.1)]
    }
    func testAMessageNoConversationHoldsStartsTheContactsDirectThread() throws {
        let old = heldConversation()
        var history = letGoHistory()
        let now = Date(timeIntervalSince1970: 101 * 3600)
        let thread = try XCTUnwrap(ComparisonRange.directThread(chatID: "A", history: history, comparisons: [old], now: now))
        XCTAssertEqual(thread.title, "Fo"); XCTAssertEqual(thread.prompt, ""); XCTAssertEqual(thread.members[0].anchor?.rowID, 20)
        XCTAssertEqual(thread.members[0].agentID, old.members[0].agentID); XCTAssertEqual(thread.created, history[2].date)
        var all = [thread, old]
        XCTAssertEqual(ComparisonRange.transcript(history, comparison: thread, member: thread.members[0], comparisons: all).map(\.id), [20, 21])
        XCTAssertEqual(ComparisonRange.transcript(history, comparison: old, member: old.members[0], comparisons: all).map(\.id), [10, 11])
        XCTAssertNil(ComparisonRange.nextAnchor(for: old, member: old.members[0], comparisons: all), "A direct thread never blocks a follow-up in the conversation")
        XCTAssertNil(ComparisonRange.directThread(chatID: "A", history: history, comparisons: all, now: now), "One open direct thread per contact")
        // A new conversation holds its own rows; the same thread takes what comes after it lets go.
        var newer = heldConversation(prompt: "Newer")
        newer.members[0].baseline = 29
        newer.members[0].anchor = Anchor(rowID: 30, guid: "g30")
        history += [row(30, "Newer", outgoing: true, hours: 100.2), row(31, "Newer answer", hours: 100.3), row(32, "An hour later", hours: 101.3)]
        all = [newer, thread, old]
        XCTAssertEqual(ComparisonRange.transcript(history, comparison: newer, member: newer.members[0], comparisons: all).map(\.id), [30, 31])
        XCTAssertEqual(ComparisonRange.transcript(history, comparison: thread, member: thread.members[0], comparisons: all).map(\.id), [20, 21, 32])
    }
    func testDirectThreadsStartOnlyForRecentMessagesFromTheContact() throws {
        let old = heldConversation()
        let history = letGoHistory()
        XCTAssertNil(ComparisonRange.directThread(chatID: "A", history: history, comparisons: [old], now: Date(timeIntervalSince1970: 1000 * 3600)), "Old history is left in Messages")
        XCTAssertNil(ComparisonRange.directThread(chatID: "A", history: Array(history.prefix(3)), comparisons: [old], now: Date(timeIntervalSince1970: 101 * 3600)), "Your own message alone starts nothing")
        XCTAssertNil(ComparisonRange.directThread(chatID: "B", history: history, comparisons: [old], now: Date(timeIntervalSince1970: 101 * 3600)), "Only contacts msgblast has a conversation with")
        var sending = heldConversation(prompt: "In flight")
        sending.members[0].anchor = nil; sending.members[0].submission = .sending; sending.members[0].baseline = 21
        XCTAssertNil(ComparisonRange.directThread(chatID: "A", history: history, comparisons: [sending, old], now: Date(timeIntervalSince1970: 101 * 3600)))
        // Ending the thread keeps what it showed; the next message starts a new one after it.
        var ended = try XCTUnwrap(ComparisonRange.directThread(chatID: "A", history: history, comparisons: [old], now: Date(timeIntervalSince1970: 101 * 3600)))
        ended.endedAt = Date(timeIntervalSince1970: 102 * 3600); ended.endMessageRows = ["A": 21]
        let later = history + [row(40, "Hello again", hours: 103)]
        let next = try XCTUnwrap(ComparisonRange.directThread(chatID: "A", history: later, comparisons: [ended, old], now: Date(timeIntervalSince1970: 104 * 3600)))
        XCTAssertEqual(next.members[0].anchor?.rowID, 40)
        XCTAssertEqual(ComparisonRange.transcript(later, comparison: ended, member: ended.members[0], comparisons: [next, ended, old]).map(\.id), [20, 21])
        let decoded = try JSONDecoder().decode(Comparison.self, from: JSONEncoder().encode(old))
        XCTAssertNil(decoded.direct, "Saved conversations decode unchanged")
    }
    func testKnownUnsubmittedErrorsCanRetryButUnknownPostSendErrorsCannot() {
        XCTAssertEqual(Submission.failure(afterAttempt: true, error: SendFailure.notSubmitted("Automation denied")), .failed)
        XCTAssertEqual(Submission.failure(afterAttempt: true, error: SendFailure.ambiguous("Timeout")), .uncertain)
        XCTAssertEqual(Submission.failure(afterAttempt: true, error: NSError(domain: "Storage", code: 1)), .uncertain)
        XCTAssertEqual(Submission.failure(afterAttempt: false, error: NSError(domain: "Validation", code: 1)), .failed)
    }
    func testReconciliationDoesNotClaimLaterSameTextOrOwnedAnchor() {
        let chat = Chat(id: "A", handle: "a@example.com", lastActivity: 0)
        var old = Comparison(prompt: "same", members: [Member(agentID: UUID(), name: "A", chat: chat)])
        old.created = Date(timeIntervalSince1970: 100)
        old.members[0].baseline = 100; old.members[0].submission = .uncertain
        var newer = Comparison(prompt: "same", members: [Member(agentID: UUID(), name: "A", chat: chat)])
        newer.created = old.created.addingTimeInterval(10); newer.members[0].baseline = 100
        let message = Message(id: 101, guid: "new", chatID: "A", text: "same", outgoing: true, date: newer.created)
        XCTAssertNil(ComparisonRange.anchorCandidate(messages: [message], comparison: old, member: old.members[0], comparisons: [newer, old]))
        newer.members[0].anchor = Anchor(rowID: 101, guid: "new")
        // Ownership also protects against legacy records without a saved attempt baseline.
        newer.members[0].baseline = nil
        XCTAssertNil(ComparisonRange.anchorCandidate(messages: [message], comparison: old, member: old.members[0], comparisons: [newer, old]))
        let original = Message(id: 102, guid: "original", chatID: "A", text: "same", outgoing: true, date: old.created)
        XCTAssertEqual(ComparisonRange.anchorCandidate(messages: [original], comparison: old, member: old.members[0], comparisons: [old])?.guid, "original")
        XCTAssertNil(ComparisonRange.anchorCandidate(messages: [original, message], comparison: old, member: old.members[0], comparisons: [old]))
        // Retrying a known failure uses its current attempt time, even if its comparison was created earlier.
        old.members[0].baseline = 101; old.members[0].attemptedAt = newer.created.addingTimeInterval(10)
        newer.members[0].baseline = 100
        let retried = Message(id: 102, guid: "retry", chatID: "A", text: "same", outgoing: true, date: old.members[0].attemptedAt!)
        XCTAssertEqual(ComparisonRange.anchorCandidate(messages: [message, retried], comparison: old, member: old.members[0], comparisons: [newer, old])?.guid, "retry")
    }
    func testDuplicateResolvedDestinationsAreRejected() {
        let chat = Chat(id: "same-chat", handle: "a@example.com", lastActivity: 0)
        XCTAssertThrowsError(try RecipientSet.validate([Member(agentID: UUID(), name: "First card", chat: chat), Member(agentID: UUID(), name: "Second card", chat: chat)]))
        XCTAssertNoThrow(try RecipientSet.validate([Member(agentID: UUID(), name: "First card", chat: chat)]))
    }
    func testRestoredFollowUpSeparatesUnsentAndFailedFromAcceptedOrUncertain() throws {
        let ids = (0..<4).map { _ in UUID() }
        var attempt = FollowUp(text: "saved follow-up", memberIDs: ids)
        for (id, state) in zip(ids, [Submission.submitted, .sending, .ready, .failed]) { attempt.states[id.uuidString] = state }
        var state = AppState()
        var comparison = Comparison(prompt: "prompt", members: [])
        comparison.followUps = [attempt]; state.comparisons = [comparison]
        let restored = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state)).recoveringInFlight().comparisons[0].followUps[0]
        XCTAssertEqual(restored.recipientsForRecovery(resumeUnsent: true), [ids[2]])
        XCTAssertEqual(restored.recipientsForRecovery(resumeUnsent: false), [ids[3]])
        XCTAssertEqual(restored.states[ids[1].uuidString], .uncertain)
    }
}
