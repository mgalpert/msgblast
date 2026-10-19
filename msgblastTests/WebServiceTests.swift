import XCTest
import WebKit
@testable import msgblastCore

@MainActor
final class WebServiceTests: XCTestCase {
    func testGeminiSavedModelIsAppliedBeforeSending() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("gemini.json")
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(WebWorkspaceState())) as? [String: Any])
        saved["geminiModel"] = ["id": "thinking-fixture", "name": "Thinking fixture"]
        try JSONSerialization.data(withJSONObject: saved).write(to: url)
        let session = WebAgentSession(provider: .gemini, storageURL: url, fixture: true)
        defer { session.beginShutdown() }
        session.connect()
        try await waitFor { session.snapshot.ready }
        _ = try await session.webView.callAsyncJavaScript("""
            document.getElementById('fixture-model-picker')?.remove();
            const picker=document.createElement('button'); picker.setAttribute('aria-label','Open mode picker, currently Flash fixture'); document.body.append(picker);
            let selectedID='flash-fixture';
            picker.onclick=()=>{const open=document.querySelector('[data-test-id="gem-mode-menu"]');if(open){open.remove();return;}const menu=document.createElement('div');menu.setAttribute('role','menu');menu.dataset.testId='gem-mode-menu';
              for(const [id,name] of [['flash-fixture','Flash fixture'],['thinking-fixture','Thinking fixture']]){
                const option=document.createElement('div');option.setAttribute('role','menuitem');option.dataset.modeId=id;option.className=id===selectedID?'selected':'';
                option.innerHTML='<span class="label">'+name+'</span>';option.onclick=()=>{selectedID=id;picker.setAttribute('aria-label','Open mode picker, currently '+name);menu.remove();};menu.append(option);
              }document.body.append(menu);};
            document.getElementById('fixture-send').addEventListener('click',()=>document.body.dataset.sentModel=picker.getAttribute('aria-label'));
            """, arguments: [:], in: nil, contentWorld: .page)
        let attempt = await session.send("Saved model request")
        XCTAssertEqual(attempt?.status, .observed, attempt?.detail ?? "Missing attempt")
        let model = try await session.webView.callAsyncJavaScript("return document.body.dataset.sentModel", arguments: [:], in: nil, contentWorld: .page) as? String
        XCTAssertEqual(model, "Open mode picker, currently Thinking fixture")
    }

    func testGeminiModelsRunTogetherAndRestoreIndependently() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let agents = WebAgents(directory: directory, fixture: true)
        defer { agents.beginShutdown() }
        let first = try XCTUnwrap(agents.session(for: .gemini))
        first.connect()
        try await waitFor { first.snapshot.ready }
        let models = try await first.availableGeminiModels()
        XCTAssertEqual(models.map(\.name), ["3.6 Flash", "3.6 Thinking", "3.1 Pro"])
        let flash = try XCTUnwrap(models.first { $0.name == "3.6 Flash" })
        let thinking = try XCTUnwrap(models.first { $0.name == "3.6 Thinking" })
        try first.setGeminiModel(flash)
        let second = try agents.duplicate(first, name: "Gemini Thinking", geminiModel: thinking)
        XCTAssertEqual(first.state.sessionID, second.state.sessionID)
        let comparison = UUID()
        let result = await WebAgents.send("Compare these models", to: [first, second], comparisonID: comparison)
        for session in [first, second] {
            XCTAssertEqual(result[session.id]?.status, .observed, result[session.id]?.detail ?? "No attempt")
            try await waitFor { session.snapshot.messages.last?.role == "assistant" }
            XCTAssertTrue(session.snapshot.messages.last?.text.contains(session.state.geminiModel!.name) == true)
        }
        XCTAssertNotEqual(first.state.conversationURLs[comparison.uuidString], second.state.conversationURLs[comparison.uuidString])
        let reopened = WebAgents(directory: directory, fixture: true)
        defer { reopened.beginShutdown() }
        XCTAssertEqual(reopened.session(for: first.id)?.state.geminiModel, flash)
        XCTAssertEqual(reopened.session(for: second.id)?.state.geminiModel, thinking)
        _ = await second.openComparison(UUID())
        let fresh = await second.send("Another chat with the saved model")
        XCTAssertEqual(fresh?.status, .observed, fresh?.detail ?? "No attempt")
        let model = try await second.webView.callAsyncJavaScript("return document.body.dataset.sentModel", arguments: [:], in: nil, contentWorld: .page) as? String
        XCTAssertEqual(model, "Open mode picker, currently Thinking")
    }

    func testGeminiUnavailableModelAndModelChangeBeforeClickNeverSend() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = WebAgentSession(provider: .gemini, storageURL: directory.appendingPathComponent("gemini.json"), fixture: true)
        defer { session.beginShutdown() }
        session.connect()
        try await waitFor { session.snapshot.ready }
        try session.setGeminiModel(GeminiModelChoice(id: "removed", name: "Unavailable model"))
        let missing = await session.send("Never fall back")
        XCTAssertEqual(missing?.status, .notSent)
        XCTAssertTrue(missing?.detail?.contains("unavailable") == true)
        XCTAssertFalse(session.snapshot.hasDraft)
        XCTAssertTrue(session.snapshot.messages.isEmpty)
        let models = try await session.availableGeminiModels()
        try session.setGeminiModel(try XCTUnwrap(models.first { $0.name == "3.6 Thinking" }))
        // A provider change after insertion must still be caught at the last Send boundary.
        _ = try await session.webView.callAsyncJavaScript("""
            document.querySelector('[role=textbox]').addEventListener('input',()=>{
                document.getElementById('fixture-model-picker').setAttribute('aria-label','Open mode picker, currently 3.6 Flash');
            });
            """, arguments: [:], in: nil, contentWorld: .page)
        let changed = await session.send("Keep this draft instead")
        await session.refresh()
        XCTAssertEqual(changed?.status, .notSent)
        XCTAssertTrue(changed?.detail?.contains("changed during preparation") == true, changed?.detail ?? "Missing failure detail")
        XCTAssertTrue(session.snapshot.messages.isEmpty)
        XCTAssertEqual(session.snapshot.draft.trimmingCharacters(in: .whitespacesAndNewlines), "Keep this draft instead")
        try session.setGeminiModel(nil)
        XCTAssertNil(session.state.geminiModel)
    }

    func testGeminiOnboardingAndConversationIdentity() throws {
        let provider = try XCTUnwrap(WebProvider(rawValue: "gemini"))
        let choice = try XCTUnwrap(OnboardingChoice(rawValue: "gemini"))
        XCTAssertEqual(choice.provider, provider)
        XCTAssertTrue(OnboardingConnector.apps.includes(choice))
        XCTAssertEqual(provider.newChatURL.absoluteString, "https://gemini.google.com/app")
        let thread = URL(string: "https://gemini.google.com/app/5cd339559845be83")!
        XCTAssertTrue(provider.isChatURL(provider.newChatURL))
        XCTAssertNil(provider.canonicalConversationURL(provider.newChatURL))
        XCTAssertEqual(provider.canonicalConversationURL(thread), thread)
        XCTAssertTrue(provider.acceptsReceipt(from: provider.newChatURL, at: thread))
        XCTAssertFalse(provider.acceptsReceipt(from: thread, at: URL(string: "https://gemini.google.com/app/abcdef0123456789")!))
        for value in ["https://gemini.google.com/", "https://gemini.google.com/app/settings", "https://gemini.google.com/app/5cd339559845be83/extra", "https://gemini.google.com/app/5cd339559845be83?other=chat", "https://gemini.google.com.evil.test/app/5cd339559845be83"] {
            XCTAssertNil(provider.canonicalConversationURL(URL(string: value)!))
        }
    }

    func testGeminiQuillSubmissionStartsSeparateChatsAndPreservesDrafts() async throws {
        let provider = try XCTUnwrap(WebProvider(rawValue: "gemini"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = WebAgentSession(provider: provider, storageURL: directory.appendingPathComponent("gemini.json"), fixture: true)
        session.connect()
        try await waitFor { session.snapshot.ready }
        XCTAssertTrue(session.isReadyForOnboarding)
        let first = UUID(), second = UUID()
        let text = "Compare these ideas.\nKeep  both spaces and this apostrophe: it's useful."
        let attempt = await session.send(text, comparisonID: first)
        XCTAssertEqual(attempt?.status, .observed)
        try await waitFor { session.snapshot.messages.last?.role == "assistant" }
        XCTAssertEqual(session.snapshot.messages.filter { $0.role == "user" }.map(\.text), [text.split(whereSeparator: \.isWhitespace).joined(separator: " ")])
        XCTAssertFalse(session.snapshot.messages.contains { $0.text.contains("You said") || $0.text.contains("Gemini said") })
        let firstURL = try XCTUnwrap(session.state.conversationURLs[first.uuidString])
        _ = await session.openComparison(second)
        XCTAssertEqual(session.webView.url, provider.newChatURL)
        let secondAttempt = await session.send("Separate Gemini thread", comparisonID: second)
        XCTAssertEqual(secondAttempt?.status, .observed)
        XCTAssertNotEqual(session.state.conversationURLs[second.uuidString], firstURL)
        _ = await session.openComparison(first)
        XCTAssertEqual(session.webView.url, firstURL)
        _ = try await session.webView.callAsyncJavaScript("document.querySelector('[role=textbox]').textContent='Keep my private draft'", arguments: [:], in: nil, contentWorld: .page)
        let blocked = await session.send("Must not overwrite", comparisonID: first)
        XCTAssertEqual(blocked?.status, .notSent)
        XCTAssertEqual(session.snapshot.draft, "Keep my private draft")
        XCTAssertEqual(session.state.attempts.filter { $0.status == .observed }.count, 2)
    }

    func testGeminiRequiresSignInAndWaitsForAnActiveResponse() async throws {
        let provider = try XCTUnwrap(WebProvider(rawValue: "gemini"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = WebAgentSession(provider: provider, storageURL: directory.appendingPathComponent("gemini.json"), fixture: true)
        session.connect()
        try await waitFor { session.snapshot.ready }
        _ = try await session.webView.callAsyncJavaScript("const stop=document.createElement('button');stop.setAttribute('aria-label','Stop response');document.body.append(stop)", arguments: [:], in: nil, contentWorld: .page)
        let busy = await session.send("Wait for the current reply")
        XCTAssertEqual(busy?.status, .notSent)
        XCTAssertFalse(session.snapshot.hasDraft)
        _ = try await session.webView.callAsyncJavaScript("document.querySelector('[aria-label=\"Stop response\"]').remove();document.getElementById('chat').hidden=true;document.getElementById('login').hidden=false", arguments: [:], in: nil, contentWorld: .page)
        _ = await session.checkSignIn()
        XCTAssertEqual(session.snapshot.signedIn, false)
        XCTAssertFalse(session.isReadyForOnboarding)
        let signedOut = await session.send("Do not submit anonymously")
        XCTAssertEqual(signedOut?.status, .notSent)
        XCTAssertTrue(session.snapshot.messages.isEmpty)
    }

    func testCurrentGrokComboboxAndAccountMenuAllowSimultaneousBroadcast() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let grok = WebAgentSession(provider: .grok, storageURL: directory.appendingPathComponent("grok.json"), fixture: true)
        let claude = WebAgentSession(provider: .claude, storageURL: directory.appendingPathComponent("claude.json"), fixture: true)
        for session in [grok, claude] { session.connect() }
        try await waitFor { grok.snapshot.ready && claude.snapshot.ready }
        // October 12 live Grok markup: the editor changed from textbox to combobox,
        // and the account label now includes the user's display name.
        _ = try await grok.webView.callAsyncJavaScript("""
            const old = document.querySelector('textarea');
            const editor = document.createElement('div');
            editor.contentEditable = 'true'; editor.setAttribute('role', 'combobox');
            editor.setAttribute('aria-label', 'Ask Grok anything'); old.replaceWith(editor);
            const account = document.querySelector('[data-testid="user-menu-button"]');
            account.removeAttribute('data-testid'); account.setAttribute('aria-label', 'Account menu, Fixture');
            const send = document.getElementById('fixture-send');
            editor.addEventListener('input', () => { send.disabled = !editor.innerText.trim(); });
            send.addEventListener('click', () => {
                const message = document.createElement('article');
                message.dataset.messageRole = 'user'; message.dataset.messageId = 'current-grok-message';
                message.textContent = editor.innerText; document.getElementById('transcript').append(message);
                editor.textContent = ''; send.disabled = true;
                history.replaceState({}, '', '/c/current-grok-fixture');
            });
            """, arguments: [:], in: nil, contentWorld: .page)
        await grok.refresh()
        XCTAssertTrue(grok.snapshot.ready, grok.snapshot.reason)
        guard grok.snapshot.ready else { return }
        let id = UUID()
        let results = await WebAgents.send("Simultaneous fixture prompt", to: [claude, grok], comparisonID: id)
        for session in [claude, grok] {
            XCTAssertEqual(results[session.id]?.status, .observed, results[session.id]?.detail ?? session.name)
            XCTAssertEqual(session.snapshot.messages.filter { $0.role == "user" && $0.text == "Simultaneous fixture prompt" }.count, 1)
            XCTAssertFalse(session.snapshot.hasDraft)
        }
        // The new editor must retain the same protection for an independent private draft.
        _ = try await grok.webView.callAsyncJavaScript("document.querySelector('[role=combobox]').textContent = 'Keep private Grok draft'", arguments: [:], in: nil, contentWorld: .page)
        let blocked = await grok.send("Do not overwrite", comparisonID: id)
        XCTAssertEqual(blocked?.status, .notSent)
        XCTAssertEqual(grok.snapshot.draft, "Keep private Grok draft")
    }

    func testHarkOnlyRecognizesItsChatAndNeverAutomatesAnUnknownLayout() async throws {
        XCTAssertEqual(WebProvider.hark.homeURL.absoluteString, "https://hark.com/chat")
        XCTAssertTrue(WebProvider.hark.isChatURL(URL(string: "https://hark.com/chat")!))
        for url in ["https://hark.com/login", "https://hark.com/chat/other", "https://hark.com.evil.test/chat"] {
            XCTAssertFalse(WebProvider.hark.isChatURL(URL(string: url)!))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = WebAgentSession(provider: .hark, storageURL: directory.appendingPathComponent("hark.json"), fixture: true)
        session.connect()
        try await waitFor { session.snapshot.signedIn == true }
        XCTAssertTrue(session.isReadyForOnboarding)
        XCTAssertFalse(session.snapshot.ready)
        let attempt = await session.send("Do not submit this")
        XCTAssertEqual(attempt?.status, .notSent)
        XCTAssertTrue(session.snapshot.messages.isEmpty)
    }

    func testWorkspaceReloadPreservesNewProvidersAlongsideComparisonDrafts() throws {
        var state = WebWorkspaceState()
        let comparison = UUID().uuidString
        state.dotsURL = URL(string: "https://chatgpt.com/dots/home")!
        state.savedAvatar = Data([1, 2, 3])
        state.grokBotRememberedConnection = false
        state.webDrafts[comparison] = "Keep this private web draft"
        state.localDrafts[comparison] = "Keep this native draft"
        let restored = try JSONDecoder().decode(WebWorkspaceState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.dotsURL, state.dotsURL)
        XCTAssertEqual(restored.savedAvatar, state.savedAvatar)
        XCTAssertEqual(restored.grokBotRememberedConnection, false)
        XCTAssertEqual(restored.webDrafts, state.webDrafts)
        XCTAssertEqual(restored.localDrafts, state.localDrafts)
    }

    func testUnconfirmedWebSubmissionsNeverShowAnAttemptBanner() {
        for provider in WebProvider.webDefaults {
            XCTAssertFalse(WebSendStatus.uncertain.showsAttemptBanner(for: provider), provider.name)
            XCTAssertFalse(WebSendStatus.observed.showsAttemptBanner(for: provider), provider.name)
            XCTAssertTrue(WebSendStatus.notSent.showsAttemptBanner(for: provider), provider.name)
        }
        for provider in [WebProvider.codexCLI, .claudeCode] {
            XCTAssertTrue(WebSendStatus.uncertain.showsAttemptBanner(for: provider), "Native requests still need their acknowledgement flow")
        }
        var state = WebWorkspaceState()
        state.attempts = [WebSendAttempt(text: "Hello", status: .attempting)]
        let recovered = state.recoveringInFlight()
        XCTAssertFalse(recovered.attempts[0].status.showsAttemptBanner(for: .chatgpt))
        XCTAssertTrue(recovered.hasUnresolvedSend("Hello"), "Hiding an internal receipt warning must not permit automatic duplicate sends")
    }

    func testOnlyMuseSideChatsAreAutomationDestinations() {
        XCTAssertTrue(WebProvider.muse.isChatURL(URL(string: "https://muse.ai/thread/new")!))
        XCTAssertTrue(WebProvider.muse.isChatURL(URL(string: "https://muse.ai/thread/abcdef01-1234-4567-8910-abcdef012345")!))
        for url in ["https://muse.ai/", "https://muse.ai/thread/main", "https://muse.ai/thread/", "https://muse.ai/thread/new/extra", "http://muse.ai/", "https://muse.ai.evil.test/", "https://muse.ai/login", "https://grok.com/bot", "file:///tmp/chat.html"] {
            XCTAssertFalse(WebProvider.muse.isChatURL(URL(string: url)!))
        }
    }

    func testReopeningShowsOnlyThatComparisonsReceipt() async throws {
        let session = try makeSession()
        session.connect()
        try await waitFor { session.snapshot.ready }
        let firstID = UUID(), secondID = UUID()
        let first = await session.send("First comparison", comparisonID: firstID)
        let second = await session.send("Second comparison", comparisonID: secondID)
        XCTAssertNotEqual(first?.conversationURL, second?.conversationURL)
        await session.openComparison(firstID)
        XCTAssertEqual(session.latestComparisonAttempt?.id, first?.id)
        XCTAssertEqual(session.locationLabel, "muse.ai · Side chat")
        session.updateState { $0.comparisonID = nil }
        XCTAssertNil(session.latestComparisonAttempt)
    }

    func testChangedComparisonCancelsPendingReopenWithoutStaleError() async throws {
        let session = try makeSession()
        session.connect()
        try await waitFor { session.snapshot.ready }
        let firstID = UUID(), secondID = UUID()
        let first = await session.send("First comparison", comparisonID: firstID)
        let second = await session.send("Second comparison", comparisonID: secondID)
        let older = Task { await session.openComparison(firstID) }
        try await waitFor { session.state.comparisonID == firstID }
        await session.openComparison(secondID)
        _ = await older.value
        XCTAssertEqual(session.state.comparisonID, secondID)
        XCTAssertEqual(session.webView.url, second?.conversationURL)
        XCTAssertNotEqual(session.webView.url, first?.conversationURL)
        XCTAssertNil(session.error)

        let pending = Task { await session.openComparison(firstID) }
        try await waitFor { session.state.comparisonID == firstID }
        session.updateState { $0.comparisonID = nil }
        _ = await pending.value
        XCTAssertNil(session.state.comparisonID)
        XCTAssertNil(session.error, "New comparison must invalidate an older reopen's timeout")
    }

    func testSwitchingComparisonPreservesDraftInItsOriginalPage() async throws {
        let session = try makeSession()
        session.connect(); try await waitFor { session.snapshot.ready }
        let firstID = UUID()
        let first = await session.send("First comparison", comparisonID: firstID)
        let originalPage = session.webView
        _ = try await originalPage.callAsyncJavaScript("document.querySelector('textarea').value = 'Keep this draft'", arguments: [:], in: nil, contentWorld: .page)
        await session.openComparison(UUID())
        XCTAssertFalse(session.webView === originalPage)
        XCTAssertEqual(session.snapshot.draft, "")
        await session.openComparison(firstID)
        XCTAssertTrue(session.webView === originalPage)
        XCTAssertEqual(session.webView.url, first?.conversationURL)
        XCTAssertEqual(session.snapshot.draft, "Keep this draft")
    }

    func testInvalidSavedConversationNeverStartsAnotherChat() async throws {
        let session = try makeSession()
        session.connect()
        try await waitFor { session.snapshot.ready }
        let id = UUID()
        session.updateState { $0.conversationURLs[id.uuidString] = URL(string: "https://muse.ai/thread/main")! }
        let attempt = await session.send("Do not send", comparisonID: id)
        XCTAssertEqual(attempt?.status, .notSent)
        XCTAssertFalse(session.snapshot.messages.contains { $0.role == "user" })
        XCTAssertEqual(session.state.conversationURLs[id.uuidString]?.path, "/thread/main")
    }

    func testInterruptedClickRemainsUncertainAcrossReload() throws {
        var state = WebWorkspaceState()
        state.attempts = [WebSendAttempt(text: "Hello", status: .attempting)]
        let decoded = try JSONDecoder().decode(WebWorkspaceState.self, from: JSONEncoder().encode(state)).recoveringInFlight()
        XCTAssertEqual(decoded.attempts.first?.status, .uncertain)
        XCTAssertTrue(decoded.hasUnresolvedSend("Hello"))
        XCTAssertFalse(decoded.hasUnresolvedSend("Different prompt"))
    }

    func testRealWebViewSendsOnceAndObservesAReply() async throws {
        let session = try makeSession()
        session.connect()
        try await waitFor { session.snapshot.ready }
        let attempt = await session.send("Hello from MsgBlast")
        XCTAssertEqual(attempt?.status, .observed)
        try await waitFor { session.snapshot.messages.contains { $0.role == "assistant" && $0.text.contains("Hello from MsgBlast") } }
        XCTAssertEqual(session.snapshot.messages.filter { $0.role == "user" }.count, 1)
        XCTAssertEqual(session.snapshot.draft, "")
    }

    func testExistingSiteDraftIsNeverOverwritten() async throws {
        let session = try makeSession()
        session.connect()
        try await waitFor { session.snapshot.ready }
        _ = try await session.webView.callAsyncJavaScript("document.querySelector('textarea').value = 'My unfinished draft'", arguments: [:], in: nil, contentWorld: .page)
        let attempt = await session.send("Another message")
        XCTAssertEqual(attempt?.status, .notSent)
        await session.refresh()
        XCTAssertEqual(session.snapshot.draft, "My unfinished draft")
        XCTAssertFalse(session.snapshot.messages.contains { $0.role == "user" })
    }

    func testExpiredSessionCannotReceiveSharedPrompt() async throws {
        let session = try makeSession()
        session.connect()
        try await waitFor { session.snapshot.ready }
        _ = try await session.webView.callAsyncJavaScript("document.getElementById('chat').hidden = true", arguments: [:], in: nil, contentWorld: .page)
        let attempt = await session.send("Do not submit while signed out")
        XCTAssertEqual(attempt?.status, .notSent)
        XCTAssertFalse(session.snapshot.ready)
        XCTAssertFalse(session.snapshot.messages.contains { $0.role == "user" })
    }

    func testMissingOutgoingObservationIsNotRetried() async throws {
        let session = try makeSession()
        session.connect()
        try await waitFor { session.snapshot.ready }
        _ = try await session.webView.callAsyncJavaScript("document.querySelector('[aria-label=Send]').addEventListener('click', e => e.stopImmediatePropagation(), true)", arguments: [:], in: nil, contentWorld: .page)
        let first = await session.send("Ambiguous send")
        XCTAssertEqual(first?.status, .uncertain)
        let second = await session.send("Ambiguous send")
        XCTAssertNil(second)
        XCTAssertEqual(session.state.attempts.count, 1)
    }

    func testReopeningWorkspaceRetainsSessionAndDraft() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MsgBlast-WebPersistence-\(UUID())")
        let url = directory.appendingPathComponent("web.json")
        let first = WebAgentSession(provider: .muse, storageURL: url, fixture: false)
        first.updateState { $0.draft = "Keep my draft" }
        let second = WebAgentSession(provider: .muse, storageURL: url, fixture: false)
        XCTAssertEqual(first.state.sessionID, second.state.sessionID)
        XCTAssertEqual(second.state.draft, "Keep my draft")
        XCTAssertTrue(second.webView.configuration.websiteDataStore.isPersistent)
        XCTAssertEqual(second.webView.configuration.websiteDataStore.identifier, first.webView.configuration.websiteDataStore.identifier)
    }

    func testStorageFailureAfterOutgoingObservationNeverClaimsNotSent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MsgBlast-WebFailure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = WebAgentSession(provider: .muse, storageURL: directory.appendingPathComponent("web.json"), fixture: true)
        let failure = StorageFailureOnSend(directory: directory)
        session.webView.configuration.userContentController.add(failure, name: "failStorage")
        session.connect()
        try await waitFor { session.snapshot.ready }
        _ = try await session.webView.callAsyncJavaScript("document.querySelector('[aria-label=Send]').addEventListener('click', () => window.webkit.messageHandlers.failStorage.postMessage(null))", arguments: [:], in: nil, contentWorld: .page)

        let attempt = await session.send("Persist failure fixture")
        XCTAssertNil(failure.error)
        XCTAssertTrue(failure.triggered)
        XCTAssertEqual(attempt?.status, .observed)
        XCTAssertNotNil(session.error)
        let repeated = await session.send("Persist failure fixture")
        XCTAssertNil(repeated, "Storage failure must block further submissions even when the outgoing message was observed")
        XCTAssertEqual(session.snapshot.messages.filter { $0.role == "user" }.count, 1)
    }

    func testIdenticalEarlierTextIsNotTheNewSubmissionReceipt() async throws {
        let session = try makeSession()
        session.connect()
        try await waitFor { session.snapshot.ready }
        let first = await session.send("Repeatable text")
        let second = await session.send("Repeatable text")
        XCTAssertEqual(first?.status, .observed)
        XCTAssertEqual(second?.status, .observed)
        XCTAssertNotEqual(first?.messageID, second?.messageID)
        XCTAssertEqual(session.snapshot.messages.filter { $0.role == "user" }.count, 2)
    }

    func testPartialBroadcastKeepsIndependentResultsAndConsumesOnlySubmittedDraft() async {
        for museSucceeds in [true, false] {
            for messagesSucceeds in [true, false] {
                var draft = "  Shared question  "
                let comparisonID = messagesSucceeds ? UUID() : nil
                let result = await AgentBroadcast.send(draft: draft, currentDraft: { draft }, clearDraft: { draft = "" }, web: { text in
                    XCTAssertEqual(text, "Shared question")
                    await Task.yield()
                    return [.muse: WebSendAttempt(text: text, status: museSucceeds ? .observed : .notSent)]
                }, messages: { text in
                    XCTAssertEqual(text, "Shared question")
                    await Task.yield()
                    return comparisonID
                })
                XCTAssertEqual(result.web[.muse]?.status, museSucceeds ? .observed : .notSent)
                XCTAssertEqual(result.comparisonID, comparisonID)
                XCTAssertEqual(draft, museSucceeds || messagesSucceeds ? "" : "  Shared question  ")
            }
        }
    }

    func testBroadcastCompletionPreservesEditsToTheNextDraft() async {
        let draft = BroadcastDraft("First message")
        _ = await AgentBroadcast.send(draft: draft.text, currentDraft: { draft.text }, clearDraft: { draft.text = "" }, web: { text in
            await Task.yield()
            return [.muse: WebSendAttempt(text: text, status: .observed)]
        }, messages: { _ in
            draft.text = "My next message"
            await Task.yield()
            return UUID()
        })
        XCTAssertEqual(draft.text, "My next message")
    }

    func testPersonalAvatarFollowsTheMainChatMediaAndChanges() async throws {
        let session = try makeSession()
        let window = displayAvatarFixture(session)
        defer { window.orderOut(nil); window.contentView = nil }
        session.connect()
        try await waitFor { session.snapshot.ready }
        XCTAssertNil(session.avatar)
        _ = try await session.webView.callAsyncJavaScript("changeFixtureAvatar(); await document.querySelector('[data-hatch-avatar-layer]').decode()", arguments: [:], in: nil, contentWorld: .page)
        try await waitFor { session.avatar != nil }
        let first = try XCTUnwrap(session.avatar)
        await session.refresh()
        XCTAssertEqual(session.avatar, first, "Unchanged media should retain its cached still")
        _ = try await session.webView.callAsyncJavaScript("changeFixtureAvatar(); await document.querySelector('[data-hatch-avatar-layer]').decode()", arguments: [:], in: nil, contentWorld: .page)
        try await waitFor { session.avatar != nil && session.avatar != first }
        XCTAssertTrue(session.state.attempts.isEmpty, "Reading an avatar must never submit a message")
    }

    func testAvatarClearsOnSignOutAndIsNotPersistedForAnotherAccount() async throws {
        let session = try makeSession()
        let window = displayAvatarFixture(session)
        defer { window.orderOut(nil); window.contentView = nil }
        session.connect()
        try await waitFor { session.snapshot.ready }
        _ = try await session.webView.callAsyncJavaScript("changeFixtureAvatar(); await document.querySelector('[data-hatch-avatar-layer]').decode()", arguments: [:], in: nil, contentWorld: .page)
        try await waitFor { session.avatar != nil }
        let first = session.avatar
        _ = try await session.webView.callAsyncJavaScript("chat.hidden=true;login.hidden=false", arguments: [:], in: nil, contentWorld: .page)
        try await waitFor { !session.snapshot.ready && session.avatar == nil }
        _ = try await session.webView.callAsyncJavaScript("changeFixtureAvatar(); await document.querySelector('[data-hatch-avatar-layer]').decode();chat.hidden=false;login.hidden=true", arguments: [:], in: nil, contentWorld: .page)
        try await waitFor { session.avatar != nil && session.avatar != first }
        session.reload()
        try await waitFor { session.snapshot.ready && session.avatar == nil }
    }

    func testAvatarIgnoresChatImagesAndAmbiguousOrHiddenHosts() async throws {
        let session = try makeSession()
        session.connect()
        try await waitFor { session.snapshot.ready }
        _ = try await session.webView.callAsyncJavaScript("changeFixtureAvatar();const host=document.querySelector('[data-hatch-avatar-host]');host.removeAttribute('data-hatch-avatar-host')", arguments: [:], in: nil, contentWorld: .page)
        await session.refresh()
        XCTAssertNil(session.avatar, "Ordinary images are not a personal Muse avatar")
        _ = try await session.webView.callAsyncJavaScript("const host=document.querySelector('[data-hatch-avatar-display-stage]');host.setAttribute('data-hatch-avatar-host','true');host.setAttribute('data-hatch-avatar-host-hidden','true')", arguments: [:], in: nil, contentWorld: .page)
        await session.refresh()
        XCTAssertNil(session.avatar)
        _ = try await session.webView.callAsyncJavaScript("const host=document.querySelector('[data-hatch-avatar-host]');host.removeAttribute('data-hatch-avatar-host-hidden');host.after(host.cloneNode(true))", arguments: [:], in: nil, contentWorld: .page)
        await session.refresh()
        XCTAssertNil(session.avatar, "Multiple candidate hosts must not guess which avatar belongs to this account")
    }

    func testComparisonCreatesSideChatAndFollowUpsReuseItAfterReopening() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SideChat-\(UUID())")
        let storage = directory.appendingPathComponent("web.json")
        let session = WebAgentSession(provider: .muse, storageURL: storage, fixture: true)
        session.connect()
        try await waitFor { session.snapshot.ready }
        let firstID = UUID(), secondID = UUID()
        let first = await session.send("First comparison", comparisonID: firstID)
        XCTAssertEqual(first?.status, .observed)
        let firstURL = try XCTUnwrap(first?.conversationURL)
        XCTAssertTrue(WebProvider.muse.isSavedConversation(firstURL))
        let followUp = await session.send("Follow-up", comparisonID: firstID)
        XCTAssertEqual(followUp?.conversationURL, firstURL)
        XCTAssertEqual(session.snapshot.messages.filter { $0.role == "user" }.count, 2)
        try await waitFor { session.snapshot.messages.contains { $0.text == "Fixture reply: Follow-up" } }
        let second = await session.send("Second comparison", comparisonID: secondID)
        XCTAssertEqual(second?.status, .observed)
        XCTAssertNotEqual(second?.conversationURL, firstURL)
        XCTAssertEqual(session.snapshot.messages.filter { $0.role == "user" }.map(\.text), ["Second comparison"])
        try await waitFor { session.snapshot.messages.contains { $0.text == "Fixture reply: Second comparison" } }
        await session.openComparison(firstID)
        XCTAssertEqual(session.webView.url, firstURL)
        XCTAssertEqual(session.snapshot.messages.filter { $0.role == "user" }.map(\.text), ["First comparison", "Follow-up"])
        let reopened = WebAgentSession(provider: .muse, storageURL: storage, fixture: true)
        XCTAssertEqual(reopened.state.sessionID, session.state.sessionID)
        XCTAssertEqual(reopened.state.conversationURLs[firstID.uuidString], firstURL)
        reopened.connect()
        try await waitFor { reopened.snapshot.ready }
        XCTAssertEqual(reopened.webView.url, firstURL)
    }

    func testOptimisticMessageWithoutAssignedThreadIsUnconfirmedAndBlocksFollowUp() async throws {
        let session = try makeSession()
        session.connect()
        try await waitFor { session.snapshot.ready }
        _ = try await session.webView.callAsyncJavaScript("history.replaceState = () => {}", arguments: [:], in: nil, contentWorld: .page)
        let id = UUID()
        let attempt = await session.send("Unconfirmed creation", comparisonID: id)
        XCTAssertEqual(attempt?.status, .uncertain)
        XCTAssertNil(session.state.conversationURLs[id.uuidString])
        let next = await session.send("Different follow-up", comparisonID: id)
        XCTAssertEqual(next?.status, .notSent)
        XCTAssertEqual(session.snapshot.messages.filter { $0.role == "user" }.count, 1)
        XCTAssertEqual(session.webView.url, WebProvider.muse.newChatURL)
    }

    func testMainChatRedirectNeverReceivesPreparedText() async throws {
        let session = try makeSession()
        session.connect()
        try await waitFor { session.snapshot.ready }
        _ = try await session.webView.callAsyncJavaScript("history.replaceState({}, '', '/'); window.navigateFixtureThread = () => {}", arguments: [:], in: nil, contentWorld: .page)
        let attempt = await session.send("Never main", comparisonID: UUID())
        XCTAssertEqual(attempt?.status, .notSent)
        let draft = try await session.webView.callAsyncJavaScript("return document.querySelector('textarea').value", arguments: [:], in: nil, contentWorld: .page) as? String
        XCTAssertEqual(draft, "")
        XCTAssertTrue(session.state.conversationURLs.isEmpty)
    }

    func testChangedSideChatCannotBeAttributedToTheComparison() async throws {
        let session = try makeSession()
        session.connect()
        try await waitFor { session.snapshot.ready }
        let id = UUID()
        let first = await session.send("Original side chat", comparisonID: id)
        let savedURL = try XCTUnwrap(first?.conversationURL)
        _ = try await session.webView.callAsyncJavaScript("document.querySelector('[aria-label=Send]').addEventListener('click', () => history.replaceState({}, '', '/thread/'+crypto.randomUUID()))", arguments: [:], in: nil, contentWorld: .page)
        let second = await session.send("Ambiguous follow-up", comparisonID: id)
        XCTAssertEqual(second?.status, .uncertain)
        XCTAssertEqual(session.state.conversationURLs[id.uuidString], savedURL)
    }

    func testMuseReceiptRequiresSavedThreadAndRejectsMainAliases() {
        let provider = WebProvider.muse
        let saved = URL(string: "https://muse.ai/thread/abcdef01-1234-4567-8910-abcdef012345")!
        XCTAssertTrue(provider.acceptsReceipt(from: provider.newChatURL, at: saved))
        XCTAssertTrue(provider.acceptsReceipt(from: saved, at: saved))
        XCTAssertFalse(provider.acceptsReceipt(from: provider.newChatURL, at: provider.newChatURL))
        XCTAssertFalse(provider.acceptsReceipt(from: provider.newChatURL, at: provider.homeURL))
        XCTAssertFalse(provider.acceptsReceipt(from: saved, at: provider.newChatURL))
    }

    private func displayAvatarFixture(_ session: WebAgentSession) -> NSWindow {
        // Avatar capture rasterizes displayed media. Give WebKit the same rendering
        // context as the app instead of depending on detached-view painting in CI.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = session.webView
        window.orderFront(nil)
        return window
    }

    private func makeSession() throws -> WebAgentSession {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MsgBlast-WebTests-\(UUID())")
        return WebAgentSession(provider: .muse, storageURL: directory.appendingPathComponent("web.json"), fixture: true)
    }

    private func waitFor(file: StaticString = #filePath, line: UInt = #line, _ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("WebKit did not reach the expected state", file: file, line: line)
    }
}

@MainActor
private final class BroadcastDraft {
    var text: String
    init(_ text: String) { self.text = text }
}

@MainActor
private final class StorageFailureOnSend: NSObject, WKScriptMessageHandler {
    let directory: URL
    var triggered = false
    var error: Error?
    init(directory: URL) { self.directory = directory }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        do {
            try FileManager.default.removeItem(at: directory)
            try Data("Owned test fixture blocks directory recreation".utf8).write(to: directory)
            triggered = true
        } catch { self.error = error }
    }
}
