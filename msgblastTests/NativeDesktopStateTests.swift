import XCTest
@testable import msgblastCore

@MainActor
final class NativeDesktopStateTests: XCTestCase {
    func testNativeSendClearsOnlyTheDraftThatWasActuallySubmitted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = DesktopAppInstallationClient(inspect: { _ in
            .init(url: URL(fileURLWithPath: "/Fixture/Claude.app"), processID: 42)
        }, open: { _ in XCTFail("The fixture app is already running") })
        for scenario in ["unchanged", "edited", "retyped"] {
            let session = WebAgentSession(provider: .claudeApp, storageURL: directory.appendingPathComponent("\(scenario).json"), fixture: true, museApp: .shared, desktopApps: client)
            defer { session.beginShutdown() }
            session.setEnabled(true)
            session.updateState { $0.desktopConversation = .init(name: "Claude") }
            let id = UUID()
            let ready = await session.openComparison(id, startNativeApp: true)
            XCTAssertTrue(ready)
            session.updateState { $0.draft = "Question" }
            let send = Task { await session.send("Question", comparisonID: id) }
            for _ in 0..<10000 where session.state.attempts.first?.status != .attempting { await Task.yield() }
            XCTAssertEqual(session.state.attempts.first?.status, .attempting, "The test must edit while the reply is pending")
            if scenario != "unchanged" { session.updateState { $0.draft = "New draft" } }
            if scenario == "retyped" { session.updateState { $0.draft = "Question" } }
            let attempt = await send.value
            XCTAssertEqual(attempt?.status, .observed)
            XCTAssertEqual(session.state.draft, scenario == "unchanged" ? "" : scenario == "edited" ? "New draft" : "Question", scenario)
        }
    }

    func testLegacyNativeDraftAndAttemptDecodeWithoutRevisionMetadata() throws {
        let comparison = UUID()
        var workspace = WebWorkspaceState()
        workspace.comparisonID = comparison
        workspace.draft = "Unsent draft"
        workspace.localDrafts[comparison.uuidString] = workspace.draft
        var attempt = WebSendAttempt(text: "Earlier request", status: .uncertain)
        attempt.comparisonID = comparison
        workspace.attempts = [attempt]
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace)) as? [String: Any])
        old.removeValue(forKey: "localDraftRevisions")
        var attempts = try XCTUnwrap(old["attempts"] as? [[String: Any]])
        attempts[0].removeValue(forKey: "nativeDraftRevision")
        old["attempts"] = attempts
        let restored = try JSONDecoder().decode(WebWorkspaceState.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertEqual(restored.draft, "Unsent draft")
        XCTAssertEqual(restored.localDrafts[comparison.uuidString], "Unsent draft")
        XCTAssertTrue(restored.localDraftRevisions.isEmpty)
        XCTAssertNil(restored.attempts.first?.nativeDraftRevision)
        XCTAssertEqual(restored.attempts.first?.status, .uncertain)
    }

    func testWorkspaceRemainsOwnedUntilAnIndependentReplyAndItsBroadcastBothFinish() throws {
        var gate = BroadcastReplyGate()
        let broadcast = try XCTUnwrap(gate.beginBroadcast())
        XCTAssertFalse(gate.beginIndependentReply(), "Do not start a private reply while the broadcast is still entering input")
        gate.finishInputs(broadcast)
        XCTAssertTrue(gate.beginIndependentReply())
        XCTAssertFalse(gate.beginIndependentReply(), "Native private input must remain serialized")
        gate.finishBroadcast(broadcast)
        XCTAssertTrue(gate.busy, "Finishing the first broadcast must not unlock a private reply in flight")
        XCTAssertFalse(gate.inputsFinished)
        XCTAssertNil(gate.beginBroadcast())
        gate.finishIndependentReply()
        XCTAssertFalse(gate.busy)
        XCTAssertNotNil(gate.beginBroadcast())
    }

    func testNativeBroadcastAllowsBrowsingOnlyAfterInputAndAConfirmedSubmission() throws {
        var gate = BroadcastReplyGate()
        let first = try XCTUnwrap(gate.beginBroadcast(nativeOnly: true))
        XCTAssertFalse(gate.canBrowseWhileWaiting)
        gate.confirmSubmission(first)
        XCTAssertFalse(gate.canBrowseWhileWaiting, "The other app inputs still own their destinations")
        gate.finishInputs(first)
        XCTAssertTrue(gate.canBrowseWhileWaiting)
        XCTAssertTrue(gate.beginIndependentReply())
        XCTAssertFalse(gate.canBrowseWhileWaiting, "A private send also owns the workspace")
        gate.finishIndependentReply()
        XCTAssertTrue(gate.canBrowseWhileWaiting)
        gate.finishBroadcast(first)
        XCTAssertFalse(gate.canBrowseWhileWaiting)

        let unconfirmed = try XCTUnwrap(gate.beginBroadcast(nativeOnly: true))
        gate.finishInputs(unconfirmed)
        XCTAssertFalse(gate.canBrowseWhileWaiting, "An unconfirmed send must retain its draft ownership")
        gate.finishBroadcast(unconfirmed)
        let website = try XCTUnwrap(gate.beginBroadcast())
        gate.finishInputs(website); gate.confirmSubmission(website)
        XCTAssertFalse(gate.canBrowseWhileWaiting, "Website sessions cannot safely switch during a send")
    }

    func testIndependentSharedBroadcastCanStartWhileAnEarlierNativeReplyIsPending() throws {
        var gate = BroadcastReplyGate()
        let firstComparison = UUID(), secondComparison = UUID()
        let first = try XCTUnwrap(gate.beginBroadcast(nativeOnly: true, comparisonID: firstComparison))
        gate.finishInputs(first)
        gate.confirmSubmission(first)
        XCTAssertTrue(gate.canBrowseWhileWaiting)
        XCTAssertNil(gate.beginBroadcast(nativeOnly: true, comparisonID: firstComparison), "A second send in the same conversation must preserve message order")
        XCTAssertFalse(gate.bindComparison(UUID(), to: first), "A broadcast cannot change conversations after it is bound")
        let second = try XCTUnwrap(gate.beginBroadcast(nativeOnly: true, comparisonID: secondComparison), "A new independent shared send should not wait for an earlier app reply")
        XCTAssertFalse(gate.bindComparison(firstComparison, to: second), "An active comparison cannot be rebound to a different broadcast")
        XCTAssertFalse(gate.canBrowseWhileWaiting, "The new broadcast still owns input")
        gate.finishBroadcast(first)
        XCTAssertTrue(gate.busy, "The earlier reply must not unlock the later broadcast")
        gate.confirmSubmission(first)
        gate.finishInputs(first)
        XCTAssertFalse(gate.canBrowseWhileWaiting, "A stale callback cannot confirm or finish another broadcast")
        gate.confirmSubmission(second)
        gate.finishInputs(second)
        XCTAssertTrue(gate.canBrowseWhileWaiting)
        gate.finishBroadcast(second)
        XCTAssertFalse(gate.busy)

        let slow = try XCTUnwrap(gate.beginBroadcast(nativeOnly: true, comparisonID: firstComparison))
        gate.finishInputs(slow); gate.confirmSubmission(slow)
        let fast = try XCTUnwrap(gate.beginBroadcast(nativeOnly: true, comparisonID: secondComparison))
        gate.finishInputs(fast); gate.confirmSubmission(fast)
        gate.finishBroadcast(fast)
        XCTAssertTrue(gate.busy, "Finishing the newer reply must keep the older request owned")
        XCTAssertTrue(gate.canBrowseWhileWaiting)
        gate.finishBroadcast(slow)
        XCTAssertFalse(gate.busy)
    }

    func testIndependentReplyDoesNotTakeAWaitingAgentsSharedAppSurface() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let agents = WebAgents(directory: directory, fixture: true)
        defer { agents.beginShutdown() }
        let comparison = UUID()
        let chatgpt = try XCTUnwrap(agents.session(for: .init(provider: .chatgptApp)))
        let dots = try XCTUnwrap(agents.session(for: .init(provider: .dotsApp)))
        let wabi = try XCTUnwrap(agents.session(for: .init(provider: .wabi)))
        for session in [chatgpt, dots, wabi] {
            session.setEnabled(true)
            let name = session.name
            session.updateState { $0.comparisonID = comparison; $0.desktopConversation = .init(name: name) }
        }
        var pending = WebSendAttempt(text: "Still waiting", status: .waiting)
        pending.comparisonID = comparison; pending.messageID = pending.id.uuidString
        dots.updateState { $0.attempts = [pending] }
        XCTAssertFalse(agents.canSendIndependentNativeReply(to: chatgpt, comparisonID: comparison), "ChatGPT and Dots share one app")
        XCTAssertFalse(agents.canUseNativeSurface(to: chatgpt, comparisonID: comparison), "A new shared send cannot take an app owned by Dots")
        XCTAssertFalse(agents.canSendIndependentNativeReply(to: dots, comparisonID: comparison), "Never send a second request to a waiting agent")
        XCTAssertTrue(agents.canSendIndependentNativeReply(to: wabi, comparisonID: comparison), "An independent app can still receive a private reply")
        XCTAssertFalse(agents.canSendIndependentNativeReply(to: wabi, comparisonID: UUID()), "A different comparison must not take the request")
        var wabiPending = WebSendAttempt(text: "Wabi is still working", status: .waiting)
        wabiPending.comparisonID = comparison; wabiPending.messageID = wabiPending.id.uuidString
        wabi.updateState { $0.attempts = [wabiPending] }
        XCTAssertFalse(agents.canSendIndependentNativeReply(to: wabi, comparisonID: comparison), "A ready-looking app with an unresolved send still owns its surface")
        XCTAssertFalse(agents.canUseNativeSurface(to: wabi, comparisonID: comparison))
        wabi.updateState { $0.attempts = [] }
        XCTAssertTrue(agents.canSendIndependentNativeReply(to: wabi, comparisonID: comparison))
        XCTAssertTrue(agents.canUseNativeSurface(to: wabi, comparisonID: comparison))
        dots.acknowledgeIncompleteRequest()
        XCTAssertTrue(agents.canSendIndependentNativeReply(to: chatgpt, comparisonID: comparison))
    }

    func testBusyAppCannotBeSelectedInAnotherConversationOrThroughItsSharedSurface() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let agents = WebAgents(directory: directory, fixture: true)
        defer { agents.beginShutdown() }
        let chatgpt = try XCTUnwrap(agents.session(for: .init(provider: .chatgptApp)))
        let dots = try XCTUnwrap(agents.session(for: .init(provider: .dotsApp)))
        let claude = try XCTUnwrap(agents.session(for: .init(provider: .claudeApp)))
        for session in [chatgpt, dots, claude] { session.setEnabled(true); agents.select(session, selected: false) }
        agents.select(chatgpt, selected: true)
        agents.select(claude, selected: true)
        var pending = WebSendAttempt(text: "An earlier question", status: .waiting)
        pending.comparisonID = UUID(); pending.messageID = pending.id.uuidString
        chatgpt.updateState { $0.attempts = [pending] }
        agents.setComparison(UUID())
        XCTAssertTrue(chatgpt.state.selected, "The prior selection can still exist when navigating to a new conversation")
        XCTAssertEqual(agents.broadcastSelection.map(\.id), [claude.id], "A stale selection must not block or receive the new broadcast")
        agents.select(chatgpt, selected: false)
        agents.select(chatgpt, selected: true)
        agents.select(dots, selected: true)
        XCTAssertEqual(agents.selected.map(\.id), [claude.id], "Busy agents must be unavailable without making the user deselect them")
        XCTAssertEqual(chatgpt.state.attempts, [pending], "Selection must not dismiss, resend, or reassign a pending request")
        XCTAssertTrue(agents.isBusyForSelection(chatgpt))
        XCTAssertTrue(agents.isBusyForSelection(dots))
        XCTAssertFalse(agents.isBusyForSelection(claude))
        chatgpt.updateState { $0.attempts[0].status = .observed }
        agents.select(dots, selected: true)
        XCTAssertTrue(dots.state.selected, "The shared app becomes selectable when its reply finishes")
        XCTAssertEqual(Set(agents.broadcastSelection.map(\.id)), Set([claude.id, dots.id]))
    }

    func testNextAppSubmitsAfterInputHandoffWhilePreviousReplyIsPending() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = [WebProvider.grokBotApp, .wabi].map {
            WebAgentSession(provider: $0, storageURL: directory.appendingPathComponent($0.storageFilename), fixture: true)
        }
        defer { sessions.forEach { $0.beginShutdown() } }
        let firstStarted = expectation(description: "Grok submission started")
        let secondStarted = expectation(description: "Wabi submitted while Grok reply is pending")
        let inputsFinished = expectation(description: "All native input was handed back before the slow reply")
        let (inputGate, input) = AsyncStream<Void>.makeStream()
        let (replyGate, reply) = AsyncStream<Void>.makeStream()
        defer { input.finish(); reply.finish() }
        var events: [String] = []
        let broadcast = Task {
            await WebAgents.send(to: sessions, onInputsFinished: {
                events.append("inputs finished")
                inputsFinished.fulfill()
            }) { session, handoff in
                if session.provider == .grokBotApp {
                    events.append("grok input")
                    firstStarted.fulfill()
                    for await _ in inputGate { break }
                    events.append("grok restored")
                    handoff()
                    for await _ in replyGate { break }
                    events.append("grok reply")
                } else {
                    events.append("wabi input")
                    secondStarted.fulfill()
                }
                var attempt = WebSendAttempt(text: "Controlled scheduling input")
                attempt.status = .observed
                return attempt
            }
        }
        await fulfillment(of: [firstStarted], timeout: 2)
        XCTAssertEqual(events, ["grok input"], "The next app must not race the previous app’s input")
        input.yield(()); input.finish()
        await fulfillment(of: [secondStarted], timeout: 2)
        await fulfillment(of: [inputsFinished], timeout: 2)
        XCTAssertEqual(events, ["grok input", "grok restored", "wabi input", "inputs finished"])
        reply.yield(()); reply.finish()
        let results = await broadcast.value
        XCTAssertEqual(Set(results.keys), Set(sessions.map(\.id)))
        XCTAssertEqual(events.last, "grok reply")
    }

    func testChatGPTAndDotsDoNotSwitchTheirSharedAppWhileAReplyIsPending() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = [WebProvider.chatgptApp, .wabi, .dotsApp].map {
            WebAgentSession(provider: $0, storageURL: directory.appendingPathComponent($0.storageFilename), fixture: true)
        }
        defer { sessions.forEach { $0.beginShutdown() } }
        let otherAppStarted = expectation(description: "An independent app can submit")
        let (replyGate, reply) = AsyncStream<Void>.makeStream()
        defer { reply.finish() }
        var events: [String] = []
        let broadcast = Task {
            await WebAgents.send(to: sessions) { session, handoff in
                events.append("\(session.provider.rawValue) input")
                handoff()
                if session.provider == .chatgptApp {
                    for await _ in replyGate { break }
                    events.append("chatgpt reply")
                } else if session.provider == .wabi { otherAppStarted.fulfill() }
                else { XCTAssertTrue(events.contains("chatgpt reply"), "Dots must not navigate away from ChatGPT’s pending reply") }
                return WebSendAttempt(text: "Controlled scheduling input")
            }
        }
        await fulfillment(of: [otherAppStarted], timeout: 2)
        reply.yield(()); reply.finish()
        let results = await broadcast.value
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(events, ["chatgptApp input", "wabi input", "chatgpt reply", "dotsApp input"])
    }

    func testSelectingChatGPTOrDotsReplacesTheOtherWithoutDisablingEither() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let agents = WebAgents(directory: directory, fixture: true)
        defer { agents.beginShutdown() }
        let chatgpt = try XCTUnwrap(agents.session(for: .init(provider: .chatgptApp)))
        let dots = try XCTUnwrap(agents.session(for: .init(provider: .dotsApp)))
        let wabi = try XCTUnwrap(agents.session(for: .init(provider: .wabi)))
        [chatgpt, dots, wabi].forEach { $0.setEnabled(true) }
        agents.toggle(chatgpt)
        agents.toggle(wabi)
        agents.toggle(dots)
        XCTAssertFalse(chatgpt.state.selected)
        XCTAssertTrue(dots.state.selected)
        XCTAssertTrue(wabi.state.selected)
        XCTAssertTrue(chatgpt.isEnabled && dots.isEnabled)
        agents.toggle(chatgpt)
        XCTAssertTrue(chatgpt.state.selected)
        XCTAssertFalse(dots.state.selected)
        XCTAssertTrue(wabi.state.selected)
    }

    func testRestoringOldComparisonWithChatGPTAndDotsSelectsOnlyOne() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let agents = WebAgents(directory: directory, fixture: true)
        defer { agents.beginShutdown() }
        let chatgpt = try XCTUnwrap(agents.session(for: .init(provider: .chatgptApp)))
        let dots = try XCTUnwrap(agents.session(for: .init(provider: .dotsApp)))
        [chatgpt, dots].forEach { $0.setEnabled(true) }
        let comparison = UUID()
        chatgpt.updateState { $0.localConversations[comparison.uuidString] = [WebPageMessage(id: "chatgpt-history", role: "assistant", text: "ChatGPT reply")] }
        dots.updateState { $0.localConversations[comparison.uuidString] = [WebPageMessage(id: "dots-history", role: "assistant", text: "Dots reply")] }
        agents.restoreSelection(forAgentIDs: [dots.id, chatgpt.id])
        XCTAssertTrue(dots.state.selected)
        XCTAssertFalse(chatgpt.state.selected)
        XCTAssertTrue(agents.displayed.contains { $0 === chatgpt }, "Keep both saved conversation panes available")
        XCTAssertTrue(agents.displayed.contains { $0 === dots })
        XCTAssertEqual(chatgpt.messagesForComparison(comparison).map(\.text), ["ChatGPT reply"])
        XCTAssertEqual(dots.messagesForComparison(comparison).map(\.text), ["Dots reply"])
    }

    func testStartupNormalizesPreviouslySavedChatGPTAndDotsSelection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for provider in [WebProvider.chatgptApp, .dotsApp] {
            let session = WebAgentSession(provider: provider, storageURL: directory.appendingPathComponent(provider.storageFilename), fixture: true)
            session.setEnabled(true)
            session.updateState { $0.selected = true }
            session.beginShutdown()
        }
        let agents = WebAgents(directory: directory, fixture: true)
        defer { agents.beginShutdown() }
        let chatgpt = try XCTUnwrap(agents.session(for: .init(provider: .chatgptApp)))
        let dots = try XCTUnwrap(agents.session(for: .init(provider: .dotsApp)))
        XCTAssertTrue(chatgpt.state.selected)
        XCTAssertFalse(dots.state.selected)
        XCTAssertTrue(chatgpt.isEnabled && dots.isEnabled)
        agents.toggle(dots)
        XCTAssertFalse(chatgpt.state.selected)
        XCTAssertTrue(dots.state.selected)
    }

    func testConflictingNativeRecipientsNeverSubmitEvenIfSelectionWasBypassed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = [WebProvider.chatgptApp, .dotsApp, .wabi].map {
            WebAgentSession(provider: $0, storageURL: directory.appendingPathComponent($0.storageFilename), fixture: true)
        }
        defer { sessions.forEach { $0.beginShutdown() } }
        sessions.forEach { $0.setEnabled(true) }
        let results = await WebAgents.send("Do not submit", to: sessions, comparisonID: UUID())
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.values.allSatisfy { $0.status == .notSent })
        XCTAssertTrue(sessions.allSatisfy { $0.state.attempts.isEmpty && $0.snapshot.messages.isEmpty })
    }

    func testMixedBroadcastWaitsForWebsiteSubmissionBeforeOpeningPrivateReplies() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = [WebProvider.grokBotApp, .grok].map {
            WebAgentSession(provider: $0, storageURL: directory.appendingPathComponent($0.storageFilename), fixture: true)
        }
        defer { sessions.forEach { $0.beginShutdown() } }
        let nativeHandoff = expectation(description: "Native input is finished")
        let websiteStarted = expectation(description: "Website submission is in progress")
        let ready = expectation(description: "All submissions are finished")
        let (nativeReplyGate, nativeReply) = AsyncStream<Void>.makeStream()
        let (websiteGate, website) = AsyncStream<Void>.makeStream()
        defer { nativeReply.finish(); website.finish() }
        var inputsFinished = false
        let broadcast = Task {
            await WebAgents.send(to: sessions, onInputsFinished: { inputsFinished = true; ready.fulfill() }) { session, handoff in
                if session.provider == .grokBotApp {
                    handoff(); nativeHandoff.fulfill()
                    for await _ in nativeReplyGate { break }
                } else {
                    websiteStarted.fulfill()
                    for await _ in websiteGate { break }
                    handoff()
                }
                return WebSendAttempt(text: "Controlled scheduling input", status: .observed)
            }
        }
        await fulfillment(of: [nativeHandoff, websiteStarted], timeout: 2)
        XCTAssertFalse(inputsFinished, "A website submission still owns its input")
        website.yield(()); website.finish()
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertTrue(inputsFinished, "The native reply can still be pending")
        nativeReply.yield(()); nativeReply.finish()
        let results = await broadcast.value
        XCTAssertEqual(results.count, 2)
    }

    func testCancelledNativeBroadcastDoesNotStartTheNextApp() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = [WebProvider.grokBotApp, .wabi].map {
            WebAgentSession(provider: $0, storageURL: directory.appendingPathComponent($0.storageFilename), fixture: true)
        }
        defer { sessions.forEach { $0.beginShutdown() } }
        let started = expectation(description: "First app is preparing input")
        let (inputGate, input) = AsyncStream<Void>.makeStream()
        defer { input.finish() }
        var submissions: [WebProvider] = []
        var inputBarrierPassed = false
        let broadcast = Task {
            await WebAgents.send(to: sessions, onInputsFinished: { inputBarrierPassed = true }) { session, _ in
                submissions.append(session.provider)
                if session.provider == .grokBotApp {
                    started.fulfill()
                    for await _ in inputGate { break }
                }
                return nil
            }
        }
        await fulfillment(of: [started], timeout: 2)
        broadcast.cancel()
        let results = await broadcast.value
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(submissions, [.grokBotApp])
        XCTAssertFalse(inputBarrierPassed, "Cancellation must not open the reply window")
    }

    func testRejectedNativeSendFinishesHandoffWithoutClaimingSubmission() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = WebAgentSession(provider: .wabi, storageURL: directory.appendingPathComponent("state.json"), fixture: true)
        defer { session.beginShutdown() }
        session.setEnabled(false)
        var handoffs = 0
        let attempt = await session.send("Do not submit", onSubmissionFinished: { handoffs += 1 })
        XCTAssertNil(attempt)
        XCTAssertEqual(handoffs, 1)
        XCTAssertTrue(session.state.attempts.isEmpty)
    }

    func testNativeBindingsMigrateAndKeepImmutableOwnership() throws {
        var old = WebWorkspaceState()
        old.draft = "Keep this draft"
        let bytes = try JSONEncoder().encode(old)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        json.removeValue(forKey: "claudeConversations")
        json.removeValue(forKey: "chatgptConversations")
        var state = try JSONDecoder().decode(WebWorkspaceState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(state.claudeConversations.isEmpty)
        XCTAssertTrue(state.chatgptConversations.isEmpty)
        XCTAssertEqual(state.sessionID, old.sessionID)
        XCTAssertEqual(state.draft, "Keep this draft")
        let id = UUID()
        var claude = ClaudeConversationBinding(comparisonID: id)
        claude.firstPrompt = claude.firstMessage("One")
        claude.url = URL(string: "https://claude.ai/chat/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        try state.recordClaudeBinding(claude)
        var changed = claude
        changed.url = URL(string: "https://claude.ai/chat/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        XCTAssertThrowsError(try state.recordClaudeBinding(changed))
        var other = ClaudeConversationBinding(comparisonID: UUID(), url: claude.url)
        other.firstPrompt = other.firstMessage("Other")
        XCTAssertThrowsError(try state.recordClaudeBinding(other))
        XCTAssertEqual(try state.claudeBinding(for: id), claude)
        var gpt = ChatGPTConversationBinding(comparisonID: id, kind: .chatgpt)
        gpt.firstPrompt = gpt.firstMessage("Two")
        gpt.title = gpt.dedicatedTitle
        try state.recordChatGPTBinding(gpt)
        var wrong = gpt
        wrong.firstPrompt = wrong.firstMessage("Replacement")
        XCTAssertThrowsError(try state.recordChatGPTBinding(wrong))
        XCTAssertThrowsError(try state.chatgptBinding(for: id, kind: .dots))
        let restored = try JSONDecoder().decode(WebWorkspaceState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(try restored.claudeBinding(for: id), claude)
        XCTAssertEqual(try restored.chatgptBinding(for: id, kind: .chatgpt), gpt)
    }


    func testConfirmedChatGPTFallbackMigratesAndCannotBeReassignedOrRemoved() throws {
        let id = UUID()
        var state = WebWorkspaceState()
        var pending = ChatGPTConversationBinding(comparisonID: id, kind: .chatgpt)
        pending.firstPrompt = pending.firstMessage("One confirmed prompt")
        try state.recordChatGPTBinding(pending)
        var confirmed = pending
        confirmed.title = confirmed.dedicatedTitle
        confirmed.fallbackTitle = "Native automatic title"
        try state.recordChatGPTBinding(confirmed)
        let restored = try JSONDecoder().decode(WebWorkspaceState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(try restored.chatgptBinding(for: id, kind: .chatgpt), confirmed)
        var changed = confirmed
        changed.fallbackTitle = "Unrelated native title"
        XCTAssertThrowsError(try state.recordChatGPTBinding(changed))
        changed.fallbackTitle = nil
        XCTAssertThrowsError(try state.recordChatGPTBinding(changed))
        XCTAssertEqual(try state.chatgptBinding(for: id, kind: .chatgpt), confirmed)
        var legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(confirmed)) as? [String: Any])
        legacyJSON.removeValue(forKey: "fallbackTitle")
        let oldBinding = try JSONDecoder().decode(ChatGPTConversationBinding.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        XCTAssertNil(oldBinding.fallbackTitle)
        var oldState = WebWorkspaceState()
        try oldState.recordChatGPTBinding(oldBinding)
        XCTAssertThrowsError(try oldState.recordChatGPTBinding(confirmed))
    }
    func testFallbackRequiresConfirmedChatGPTIdentityAndNonce() throws {
        let id = UUID()
        for kind in [ChatGPTAppKind.chatgpt, .dots] {
            var state = WebWorkspaceState()
            var invalid = ChatGPTConversationBinding(comparisonID: id, kind: kind, fallbackTitle: "Native title")
            XCTAssertThrowsError(try state.recordChatGPTBinding(invalid))
            invalid.title = invalid.dedicatedTitle
            XCTAssertThrowsError(try state.recordChatGPTBinding(invalid))
            invalid.firstPrompt = invalid.firstMessage("Prompt")
            if kind == .dots { XCTAssertThrowsError(try state.recordChatGPTBinding(invalid)) }
            else {
                invalid.fallbackTitle = ""
                XCTAssertThrowsError(try state.recordChatGPTBinding(invalid))
            }
            XCTAssertTrue(state.chatgptConversations.isEmpty)
        }
    }

    func testNativeFixtureConversationsResumeWithoutReplacingTheirBindings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for provider in [WebProvider.chatgptApp, .dotsApp, .claudeApp] {
            let url = directory.appendingPathComponent(provider.storageFilename)
            let id = UUID()
            let session = WebAgentSession(provider: provider, storageURL: url, fixture: true)
            session.setEnabled(true)
            await session.connectDesktopConversation()
            XCTAssertTrue(session.isReadyForOnboarding)
            let opened = await session.openComparison(id)
            XCTAssertTrue(opened)
            let first = await session.send("First", comparisonID: id)
            XCTAssertEqual(first?.status, .observed)
            XCTAssertEqual(session.state.localConversations[id.uuidString]?.map(\.role), ["user", "assistant"])
            let chatgptBinding = session.state.chatgptConversations[id.uuidString]
            let claudeBinding = session.state.claudeConversations[id.uuidString]
            session.beginShutdown()
            let restored = WebAgentSession(provider: provider, storageURL: url, fixture: true)
            let reopened = await restored.openComparison(id)
            XCTAssertTrue(reopened)
            let followUp = await restored.send("Follow-up", comparisonID: id)
            XCTAssertEqual(followUp?.status, .observed)
            XCTAssertEqual(restored.state.chatgptConversations[id.uuidString], chatgptBinding)
            XCTAssertEqual(restored.state.claudeConversations[id.uuidString], claudeBinding)
            XCTAssertTrue(restored.state.localSessionIDs.isEmpty)
            XCTAssertEqual(restored.state.localConversations[id.uuidString]?.count, 4)
            restored.beginShutdown()
        }
    }

    func testNativePromptAppearsDuringSubmissionAndIsNotDuplicatedAfterReply() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for provider in WebProvider.desktopProviders {
            let file = directory.appendingPathComponent(provider.storageFilename), id = UUID()
            let session = WebAgentSession(provider: provider, storageURL: file, fixture: true)
            session.setEnabled(true)
            if provider == .grokBotApp { await session.refreshGrokBots() }
            await session.connectDesktopConversation(botName: provider == .grokBotApp ? "Demo Bot" : nil)
            _ = await session.openComparison(id)
            let sending = Task { await session.send("Visible while sending", comparisonID: id) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while session.state.attempts.first?.status != .attempting && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            let pending = try XCTUnwrap(session.pendingNativeAttempt, provider.name)
            XCTAssertEqual(pending.text, "Visible while sending")
            XCTAssertEqual(pending.status, .attempting)
            XCTAssertTrue(session.snapshot.messages.isEmpty, "A pending bubble is not a claimed provider receipt")
            let attempt = await sending.value
            XCTAssertEqual(attempt?.status, .observed)
            XCTAssertNil(session.pendingNativeAttempt)
            XCTAssertEqual(session.snapshot.messages.filter { $0.role == "user" }.map(\.text), ["Visible while sending"])
            XCTAssertEqual(session.snapshot.messages.first?.id, pending.id.uuidString)
            XCTAssertEqual(session.snapshot.messages.last?.role, "assistant")
            session.beginShutdown()
            let reopened = WebAgentSession(provider: provider, storageURL: file, fixture: true)
            XCTAssertNil(reopened.pendingNativeAttempt)
            XCTAssertEqual(reopened.state.localConversations[id.uuidString]?.filter { $0.role == "user" }.count, 1)
            reopened.beginShutdown()
        }
    }

    func testNativeCancellationExplainsRecoveryAndRetainsTheUncertainReceiptAcrossRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for provider in WebProvider.desktopProviders {
            let file = directory.appendingPathComponent(provider.storageFilename), id = UUID()
            let session = WebAgentSession(provider: provider, storageURL: file, fixture: true)
            session.setEnabled(true)
            if provider == .grokBotApp { await session.refreshGrokBots() }
            await session.connectDesktopConversation(botName: provider == .grokBotApp ? "Demo Bot" : nil)
            _ = await session.openComparison(id)
            session.updateState { $0.draft = "Keep this cancelled request" }
            let sending = Task { await session.send("Keep this cancelled request", comparisonID: id) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while session.state.attempts.first?.status != .attempting && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            XCTAssertEqual(session.state.attempts.first?.status, .attempting, provider.name)
            session.cancelNativeRequest()
            let attempt = await sending.value
            XCTAssertEqual(attempt?.status, .uncertain, provider.name)
            XCTAssertEqual(attempt?.detail, "Stopped waiting for a reply. Check \(provider.name) before sending again.")
            XCTAssertEqual(session.error, attempt?.detail)
            XCTAssertEqual(session.state.draft, "Keep this cancelled request")
            XCTAssertTrue(session.snapshot.messages.isEmpty)
            session.beginShutdown()
            let restored = WebAgentSession(provider: provider, storageURL: file, fixture: true)
            XCTAssertEqual(restored.state.attempts.first?.id, attempt?.id)
            XCTAssertEqual(restored.state.attempts.first?.status, .uncertain)
            XCTAssertEqual(restored.state.attempts.first?.detail, attempt?.detail)
            let blocked = await restored.send("Do not retry", comparisonID: id)
            XCTAssertNil(blocked)
            XCTAssertEqual(restored.state.attempts.count, 1)
            restored.beginShutdown()
        }
    }

    func testInstalledNativeHistoryDoesNotClaimAReconnectIsRequiredBeforeAnExplicitSend() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for provider in WebProvider.desktopProviders {
            let file = directory.appendingPathComponent(provider.storageFilename), id = UUID()
            let session = WebAgentSession(provider: provider, storageURL: file, fixture: true)
            session.setEnabled(true)
            session.updateState {
                $0.comparisonID = id
                $0.localConversations[id.uuidString] = [.init(role: "user", text: "Saved question"), .init(role: "assistant", text: "Saved answer")]
            }
            session.beginShutdown()
            let restored = WebAgentSession(provider: provider, storageURL: file, fixture: true)
            XCTAssertFalse(restored.desktopReady)
            XCTAssertEqual(restored.snapshot.messages.count, 2)
            XCTAssertNil(restored.desktopRecoveryMessage, provider.name)
            XCTAssertTrue(restored.state.attempts.isEmpty)
            restored.beginShutdown()
        }
    }

    func testFailedFirstConversationShowsRecoveryWithoutLosingDraftOrSubmitting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reason = "The app could not open its chat window."
        let client = DesktopAppInstallationClient(inspect: { app in
            .init(url: URL(fileURLWithPath: "/Fixture/\(app.name).app"), processID: nil)
        }, open: { _ in throw NSError(domain: "FixtureLaunch", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) })
        for provider in WebProvider.desktopProviders {
            let session = WebAgentSession(provider: provider, storageURL: directory.appendingPathComponent(provider.storageFilename), fixture: true, museApp: .shared, desktopApps: client)
            defer { session.beginShutdown() }
            session.setEnabled(true)
            session.updateState { $0.draft = "Keep my first prompt" }
            XCTAssertNil(session.desktopRecoveryMessage, "A fresh empty pane should stay uncluttered")
            let ready = await session.openComparison(UUID())
            XCTAssertFalse(ready)
            XCTAssertEqual(session.error, reason)
            XCTAssertEqual(session.desktopRecoveryMessage, reason, "The empty conversation must explain the failed preparation and offer recovery")
            XCTAssertEqual(session.state.draft, "Keep my first prompt")
            XCTAssertTrue(session.state.attempts.isEmpty, "Opening a conversation must never submit or retry a prompt")
            XCTAssertTrue(session.snapshot.messages.isEmpty)
        }
    }

    func testFailedAppPreparationKeepsItsPromptWhileAnotherAppSubmits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var running: Set<URL> = []
        let client = DesktopAppInstallationClient(inspect: { app in
            let url = URL(fileURLWithPath: "/Fixture/\(app.name).app")
            return .init(url: url, processID: running.contains(url) ? 42 : nil)
        }, open: { url in
            if url.lastPathComponent == "Wabi.app" {
                throw NSError(domain: "FixtureLaunch", code: 1, userInfo: [NSLocalizedDescriptionKey: "Wabi could not open."])
            }
            running.insert(url)
        })
        let wabi = WebAgentSession(provider: .wabi, storageURL: directory.appendingPathComponent("wabi.json"), fixture: true, museApp: .shared, desktopApps: client)
        let claude = WebAgentSession(provider: .claudeApp, storageURL: directory.appendingPathComponent("claude.json"), fixture: true, museApp: .shared, desktopApps: client)
        let agents = WebAgents(directory: directory.appendingPathComponent("workspace"), fixture: true)
        defer { wabi.beginShutdown(); claude.beginShutdown(); agents.beginShutdown() }
        [wabi, claude].forEach { $0.setEnabled(true); $0.updateState { $0.desktopConversation = .init(name: "Fixture") } }
        wabi.updateState { $0.draft = "A separate app draft" }
        let comparison = UUID(), prompt = "A shared question"
        let prepared = await agents.prepareComparisonRecipients(comparison, for: [wabi, claude], startNativeApps: true)
        let preparation = try XCTUnwrap(prepared)
        XCTAssertEqual(preparation[wabi.id], false)
        XCTAssertEqual(preparation[claude.id], true)
        XCTAssertTrue(wabi.state.attempts.isEmpty, "Preparation alone never submits or records a request")
        let failed = try XCTUnwrap(wabi.recordUnsentPreparation(prompt, comparisonID: comparison, reason: "Wabi could not open."))
        XCTAssertEqual(failed.status, .notSent)
        XCTAssertEqual(wabi.state.draft, "A separate app draft")
        let replies = await WebAgents.send(prompt, to: [claude], comparisonID: comparison)
        XCTAssertEqual(replies[claude.id]?.status, .observed)
        XCTAssertTrue(wabi.snapshot.messages.isEmpty, "The failed app must never receive the prompt automatically")
        let reopened = WebAgentSession(provider: .wabi, storageURL: directory.appendingPathComponent("wabi.json"), fixture: true, museApp: .shared, desktopApps: client)
        defer { reopened.beginShutdown() }
        XCTAssertEqual(reopened.latestComparisonAttempt?.text, prompt)
        XCTAssertEqual(reopened.latestComparisonAttempt?.status, .notSent)
        XCTAssertEqual(reopened.state.draft, "A separate app draft")
        XCTAssertNil(reopened.recordUnsentPreparation("Wrong workspace", comparisonID: UUID(), reason: "Not ready"))
        XCTAssertEqual(reopened.state.attempts.count, 1)
    }

    func testPlannedNativePreparationDoesNotHoldMessagesAndPreservesFailures() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (gate, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        let appBlocked = expectation(description: "The first app is still opening")
        let messageSubmitted = expectation(description: "Messages submitted while the app was opening")
        var running: Set<URL> = []
        let client = DesktopAppInstallationClient(inspect: { app in
            let url = URL(fileURLWithPath: "/Fixture/\(app.name).app")
            return .init(url: url, processID: running.contains(url) ? 42 : nil)
        }, open: { url in
            if url.lastPathComponent == "Wabi.app" {
                appBlocked.fulfill()
                for await _ in gate { break }
                throw NSError(domain: "FixtureLaunch", code: 1, userInfo: [NSLocalizedDescriptionKey: "Wabi could not open."])
            }
            running.insert(url)
        })
        let sessions = [WebProvider.wabi, .claudeApp].map { provider in
            let session = WebAgentSession(provider: provider, storageURL: directory.appendingPathComponent(provider.storageFilename), fixture: true, museApp: .shared, desktopApps: client)
            session.setEnabled(true)
            session.updateState { $0.desktopConversation = .init(name: provider.name) }
            return session
        }
        let agents = WebAgents(directory: directory.appendingPathComponent("workspace"), fixture: true)
        defer { sessions.forEach { $0.beginShutdown() }; agents.beginShutdown() }
        let comparison = UUID(), text = "A shared question"
        agents.setComparison(comparison)
        sessions.forEach { $0.updateState { $0.comparisonID = comparison } }
        sessions[0].updateState { $0.draft = "A separate app draft" }
        var planned: [WebAgentID: UUID] = [:]
        for session in sessions {
            let attempt = try XCTUnwrap(session.planNativePreparation(text, comparisonID: comparison))
            planned[session.id] = attempt.id
        }
        let intent = planned
        var draft = text
        let broadcast = Task { @MainActor in
            await AgentBroadcast.send(draft: text, currentDraft: { draft }, clearDraft: { draft = "" }, web: { text, confirmed in
                await agents.prepareAndSendPlanned(text, to: sessions, comparisonID: comparison, plannedAttempts: intent, onConfirmedSubmission: confirmed)
            }, messages: { _, confirmed in
                confirmed(); messageSubmitted.fulfill(); return comparison
            })
        }
        await fulfillment(of: [appBlocked, messageSubmitted], timeout: 3)
        XCTAssertEqual(draft, "", "Confirmed Messages submission should not wait for app setup")
        XCTAssertEqual(sessions[0].state.attempts.first?.status, .preparing)
        XCTAssertEqual(sessions[1].state.attempts.first?.status, .preparing)
        XCTAssertTrue(sessions[1].snapshot.messages.isEmpty)
        release.yield(()); release.finish()
        let result = await broadcast.value
        XCTAssertEqual(result.comparisonID, comparison)
        XCTAssertEqual(result.web[sessions[0].id]?.status, .notSent)
        XCTAssertEqual(result.web[sessions[0].id]?.id, intent[sessions[0].id])
        XCTAssertEqual(result.web[sessions[1].id]?.status, .observed)
        XCTAssertEqual(result.web[sessions[1].id]?.id, intent[sessions[1].id])
        XCTAssertEqual(sessions[0].state.draft, "A separate app draft")
        XCTAssertEqual(sessions[0].state.attempts.count, 1)
        XCTAssertEqual(sessions[1].state.attempts.count, 1)
        let reopened = WebAgentSession(provider: .wabi, storageURL: directory.appendingPathComponent(WebProvider.wabi.storageFilename), fixture: true, museApp: .shared, desktopApps: client)
        defer { reopened.beginShutdown() }
        XCTAssertEqual(reopened.state.attempts.first?.status, .notSent)
        XCTAssertEqual(reopened.state.attempts.first?.text, text)
    }

    func testReadyNativeAgentSubmitsBeforeNextAgentFinishesPreparation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (gate, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        let secondBlocked = expectation(description: "The next app is still opening")
        var running: Set<URL> = [URL(fileURLWithPath: "/Fixture/Wabi.app")]
        let client = DesktopAppInstallationClient(inspect: { app in
            let url = URL(fileURLWithPath: "/Fixture/\(app.name).app")
            return .init(url: url, processID: running.contains(url) ? 42 : nil)
        }, open: { url in
            secondBlocked.fulfill()
            for await _ in gate { break }
            running.insert(url)
        })
        let sessions = [WebProvider.wabi, .claudeApp].map { provider in
            let session = WebAgentSession(provider: provider, storageURL: directory.appendingPathComponent(provider.storageFilename), fixture: true, museApp: .shared, desktopApps: client)
            session.setEnabled(true)
            session.updateState { $0.desktopConversation = .init(name: provider.name) }
            return session
        }
        let agents = WebAgents(directory: directory.appendingPathComponent("workspace"), fixture: true)
        defer { sessions.forEach { $0.beginShutdown() }; agents.beginShutdown() }
        let comparison = UUID(), text = "A shared question"
        agents.setComparison(comparison)
        sessions.forEach { $0.updateState { $0.comparisonID = comparison } }
        var planned: [WebAgentID: UUID] = [:]
        for session in sessions { planned[session.id] = try XCTUnwrap(session.planNativePreparation(text, comparisonID: comparison)).id }
        let send = Task { await agents.prepareAndSendPlanned(text, to: sessions, comparisonID: comparison, plannedAttempts: planned) }
        await fulfillment(of: [secondBlocked], timeout: 3)
        XCTAssertEqual(sessions[0].state.attempts.first?.status, .observed)
        XCTAssertEqual(sessions[0].state.localConversations[comparison.uuidString]?.map(\.text), [text, "Wabi fixture reply: \(text)"])
        XCTAssertEqual(sessions[1].state.attempts.first?.status, .preparing)
        release.yield(()); release.finish()
        let result = await send.value
        XCTAssertEqual(result[sessions[0].id]?.status, .observed)
        XCTAssertEqual(result[sessions[1].id]?.status, .observed)
        XCTAssertEqual(sessions[0].state.attempts.count, 1)
        XCTAssertEqual(sessions[1].state.attempts.count, 1)
    }

    func testPlannedNativePromptCannotBeReplacedWithDifferentText() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let agents = WebAgents(directory: directory, fixture: true)
        defer { agents.beginShutdown() }
        let session = try XCTUnwrap(agents.session(for: .init(provider: .wabi)))
        session.setEnabled(true)
        session.updateState { $0.desktopConversation = .init(name: "Wabi") }
        let comparison = UUID()
        agents.setComparison(comparison)
        let planned = try XCTUnwrap(session.planNativePreparation("Original", comparisonID: comparison))
        let result = await agents.prepareAndSendPlanned("Different", to: [session], comparisonID: comparison, plannedAttempts: [session.id: planned.id])
        XCTAssertEqual(result[session.id]?.status, .notSent)
        XCTAssertEqual(result[session.id]?.text, "Original")
        XCTAssertTrue(session.state.localConversations[comparison.uuidString]?.isEmpty ?? true)
        XCTAssertEqual(session.state.attempts.count, 1)
    }

    func testPlannedNativePreparationDoesNotSendAfterWorkspaceChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (gate, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        let appBlocked = expectation(description: "The app is opening")
        var running = false
        let client = DesktopAppInstallationClient(inspect: { _ in
            .init(url: URL(fileURLWithPath: "/Fixture/Wabi.app"), processID: running ? 42 : nil)
        }, open: { _ in
            appBlocked.fulfill()
            for await _ in gate { break }
            running = true
        })
        let session = WebAgentSession(provider: .wabi, storageURL: directory.appendingPathComponent("wabi.json"), fixture: true, museApp: .shared, desktopApps: client)
        let agents = WebAgents(directory: directory.appendingPathComponent("workspace"), fixture: true)
        defer { session.beginShutdown(); agents.beginShutdown() }
        session.setEnabled(true)
        session.updateState { $0.desktopConversation = .init(name: "Wabi") }
        let comparison = UUID(), other = UUID(), text = "Question"
        agents.setComparison(comparison)
        session.updateState { $0.comparisonID = comparison }
        let planned = try XCTUnwrap(session.planNativePreparation(text, comparisonID: comparison))
        let send = Task { await agents.prepareAndSendPlanned(text, to: [session], comparisonID: comparison, plannedAttempts: [session.id: planned.id]) }
        await fulfillment(of: [appBlocked], timeout: 3)
        agents.setComparison(other)
        session.updateState { $0.comparisonID = other }
        release.yield(()); release.finish()
        let result = await send.value
        XCTAssertEqual(agents.comparisonID, other)
        XCTAssertEqual(session.state.comparisonID, other)
        XCTAssertEqual(result[session.id]?.id, planned.id)
        XCTAssertEqual(result[session.id]?.status, .notSent)
        XCTAssertTrue(session.state.localConversations[comparison.uuidString]?.isEmpty ?? true)
        XCTAssertTrue(session.state.localConversations[other.uuidString]?.isEmpty ?? true)
    }

    func testSharedNativeSendPreservesMatchingAndDifferentPrivateDrafts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for privateDraft in ["Shared question", "A different private draft"] {
            let agents = WebAgents(directory: directory.appendingPathComponent(UUID().uuidString), fixture: true)
            defer { agents.beginShutdown() }
            let session = try XCTUnwrap(agents.session(for: .init(provider: .claudeApp)))
            session.setEnabled(true)
            session.updateState { $0.desktopConversation = .init(name: "Claude") }
            let comparison = UUID(), text = "Shared question"
            agents.setComparison(comparison)
            session.updateState { $0.draft = privateDraft }
            let planned = try XCTUnwrap(session.planNativePreparation(text, comparisonID: comparison))
            let result = await agents.prepareAndSendPlanned(text, to: [session], comparisonID: comparison, plannedAttempts: [session.id: planned.id])
            XCTAssertEqual(result[session.id]?.status, .observed, privateDraft)
            XCTAssertEqual(session.state.draft, privateDraft, "A shared send must not consume a private draft")
            XCTAssertEqual(session.state.localDrafts[comparison.uuidString], privateDraft)
            XCTAssertEqual(session.state.localConversations[comparison.uuidString]?.first?.text, text)
        }
    }

    func testSharedNativeSendOutsideProgressivePathPreservesPrivateDraft() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let agents = WebAgents(directory: directory, fixture: true)
        defer { agents.beginShutdown() }
        let session = try XCTUnwrap(agents.session(for: .init(provider: .claudeApp)))
        session.setEnabled(true)
        session.updateState { $0.desktopConversation = .init(name: "Claude") }
        let comparison = UUID(), text = "Shared question"
        agents.setComparison(comparison)
        session.updateState { $0.draft = "A private draft" }
        let ready = await agents.prepareComparison(comparison, for: [session], startNativeApps: true, allowSavedPrivateDraft: true)
        XCTAssertTrue(ready)
        let result = await WebAgents.send(text, to: [session], comparisonID: comparison)
        XCTAssertEqual(result[session.id]?.status, .observed)
        XCTAssertEqual(session.state.draft, "A private draft")
        XCTAssertEqual(session.state.localDrafts[comparison.uuidString], "A private draft")
    }

    func testInterruptedPlannedNativeRequestBecomesRetryableWithoutSending() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = directory.appendingPathComponent("wabi.json"), comparison = UUID()
        let session = WebAgentSession(provider: .wabi, storageURL: storage, fixture: true)
        session.setEnabled(true)
        session.updateState { $0.comparisonID = comparison; $0.desktopConversation = .init(name: "Wabi") }
        let planned = try XCTUnwrap(session.planNativePreparation("Question", comparisonID: comparison))
        session.beginShutdown()
        let reopened = WebAgentSession(provider: .wabi, storageURL: storage, fixture: true)
        defer { reopened.beginShutdown() }
        XCTAssertEqual(reopened.state.attempts.first?.id, planned.id)
        XCTAssertEqual(reopened.state.attempts.first?.status, .notSent)
        XCTAssertEqual(reopened.state.attempts.first?.text, "Question")
        XCTAssertTrue(reopened.state.localConversations[comparison.uuidString]?.isEmpty ?? true)
    }

    func testChatGPTAndDotsShareOneAppLaunchDuringBroadcastPreparation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var running = false, launches = 0
        let client = DesktopAppInstallationClient(inspect: { _ in
            .init(url: URL(fileURLWithPath: "/Fixture/ChatGPT.app"), processID: running ? 42 : nil)
        }, open: { _ in
            launches += 1
            try await Task.sleep(for: .milliseconds(30))
            running = true
        })
        let sessions = [WebProvider.chatgptApp, .dotsApp].map { provider in
            let session = WebAgentSession(provider: provider, storageURL: directory.appendingPathComponent(provider.storageFilename), fixture: true, museApp: .shared, desktopApps: client)
            session.setEnabled(true)
            session.updateState { $0.desktopConversation = .init(name: provider.name) }
            return session
        }
        let agents = WebAgents(directory: directory.appendingPathComponent("workspace"), fixture: true)
        let id = UUID()
        let ready = await agents.prepareComparison(id, for: sessions)
        XCTAssertTrue(ready)
        XCTAssertEqual(launches, 1, "Both providers use the same installed application")
        for session in sessions {
            let replies = await WebAgents.send("Compare", to: [session], comparisonID: id)
            XCTAssertEqual(replies[session.id]?.status, .observed)
        }
        for session in sessions { session.beginShutdown() }
        agents.beginShutdown()
    }
    func testNativeAppPreparationDoesNotRaceWindowLaunchesAcrossProviders() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var running: Set<URL> = [], activeLaunches = 0, maximumLaunches = 0
        let client = DesktopAppInstallationClient(inspect: { app in
            let url = URL(fileURLWithPath: "/Fixture/\(app.name).app")
            return .init(url: url, processID: running.contains(url) ? 42 : nil)
        }, open: { url in
            activeLaunches += 1
            maximumLaunches = max(maximumLaunches, activeLaunches)
            try await Task.sleep(for: .milliseconds(30))
            running.insert(url)
            activeLaunches -= 1
        })
        let sessions = [WebProvider.chatgptApp, .claudeApp].map { provider in
            let session = WebAgentSession(provider: provider, storageURL: directory.appendingPathComponent(provider.storageFilename), fixture: true, museApp: .shared, desktopApps: client)
            session.setEnabled(true)
            session.updateState { $0.desktopConversation = .init(name: provider.name) }
            return session
        }
        let agents = WebAgents(directory: directory.appendingPathComponent("workspace"), fixture: true)
        let ready = await agents.prepareComparison(UUID(), for: sessions)
        XCTAssertTrue(ready)
        XCTAssertEqual(running.count, 2)
        XCTAssertEqual(maximumLaunches, 1, "Window launches must not compete for the active Space")
        sessions.forEach { $0.beginShutdown() }
        agents.beginShutdown()
    }

}
