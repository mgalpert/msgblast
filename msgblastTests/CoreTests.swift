import XCTest
@testable import msgblastCore
final class CoreTests: XCTestCase {
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
