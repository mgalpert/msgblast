import XCTest
import WebKit
@testable import msgblastCore

@MainActor
final class MultiWebAgentTests: XCTestCase {
    func testProviderDestinationsAndFirstConversationTransition() {
        for provider in WebProvider.allCases {
            XCTAssertTrue(provider.isChatURL(provider.newChatURL))
            for invalid in ["https://\(provider.homeURL.host!).evil.test/", "http://\(provider.homeURL.host!)/", "https://\(provider.homeURL.host!)/login", "https://\(provider.homeURL.host!)/settings", "https://\(provider.homeURL.host!):444/", "https://user@\(provider.homeURL.host!)/"] {
                XCTAssertFalse(provider.isChatURL(URL(string: invalid)!), invalid)
            }
        }
        for provider in [WebProvider.chatgpt, .claude, .grok] {
            let path = provider == .claude ? "/chat/abc-123" : "/c/abc-123"
            let conversation = URL(string: path, relativeTo: provider.homeURL)!.absoluteURL
            XCTAssertTrue(provider.acceptsReceipt(from: provider.homeURL, at: conversation))
            XCTAssertFalse(provider.acceptsReceipt(from: conversation, at: provider.homeURL))
            XCTAssertFalse(provider.acceptsReceipt(from: conversation, at: URL(string: path + "different", relativeTo: provider.homeURL)!.absoluteURL))
        }
    }

    func testLegacyMuseSessionSelectionAndPendingReceiptSurviveUpgrade() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID(), comparison = UUID()
        let json = """
        {"sessionID":"\(id)","draft":"Legacy draft","includeMuse":true,"messageRecipients":[],"comparisonID":"\(comparison)","attempts":[]}
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("web-services.json"))
        let web = WebAgents(directory: directory, fixture: false)
        XCTAssertEqual(web.selected.map(\.provider), WebProvider.allCases)
        XCTAssertEqual(web.sessions[0].state.sessionID, id)
        XCTAssertEqual(web.sessions[0].state.draft, "Legacy draft")
        XCTAssertEqual(web.comparisonID, comparison)
        XCTAssertEqual(Set(web.sessions.map { $0.state.sessionID }).count, 4)
        for session in web.sessions where session.provider.personalAgentProvider == nil { XCTAssertEqual(session.webView.configuration.websiteDataStore.identifier, session.state.sessionID) }
        web.toggle(web.sessions[2])
        let reopened = WebAgents(directory: directory, fixture: false)
        XCTAssertEqual(reopened.selected.map(\.provider), [.muse, .chatgpt, .grok])
        XCTAssertEqual(reopened.sessions.map { $0.state.sessionID }, web.sessions.map { $0.state.sessionID })
    }

    func testAllProvidersBroadcastAndObserveRepliesWithoutAnAttachedWindow() async throws {
        let web = WebAgents(directory: temporaryDirectory(), fixture: true)
        web.connectSelected()
        try await waitFor { web.sessions.allSatisfy { $0.snapshot.ready } }
        let results = await WebAgents.send("Compare a morning walk with an afternoon walk.", to: web.selected)
        XCTAssertEqual(results.count, 4)
        for provider in WebProvider.allCases { XCTAssertEqual(results[provider]?.status, .observed, provider.name) }
        try await waitFor { web.sessions.allSatisfy { $0.snapshot.messages.contains { $0.role == "assistant" && $0.text.contains("afternoon walk") } } }
        for session in web.sessions {
            XCTAssertEqual(session.snapshot.messages.filter { $0.role == "user" }.count, 1)
            XCTAssertEqual(session.snapshot.draft, "")
            if session.provider.personalAgentProvider == nil { XCTAssertNil(session.webView.window, "Submission must not depend on window focus") }
        }
        let again = await WebAgents.send("Compare a morning walk with an afternoon walk.", to: web.selected)
        for provider in WebProvider.allCases {
            XCTAssertEqual(again[provider]?.status, .observed, provider.name)
            XCTAssertNotEqual(again[provider]?.messageID, results[provider]?.messageID)
        }
    }

    func testDraftOrUnavailableAgentDoesNotBlockIndependentSubmissions() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("invalid persisted state".utf8).write(to: directory.appendingPathComponent(WebProvider.claude.storageFilename))
        let web = WebAgents(directory: directory, fixture: true)
        web.sessions.forEach { $0.connect() }
        try await waitFor { web.sessions.filter { $0.provider != .claude }.allSatisfy { $0.snapshot.ready } }
        let chatgpt = web.sessions[1], claude = web.sessions[2]
        chatgpt.updateState { $0.draft = "Keep this draft" }
        let results = await WebAgents.send("New question", to: web.sessions)
        XCTAssertEqual(results[.muse]?.status, .observed)
        XCTAssertEqual(results[.grok]?.status, .observed)
        XCTAssertEqual(results[.chatgpt]?.status, .notSent)
        XCTAssertNil(results[.claude])
        XCTAssertEqual(chatgpt.snapshot.draft, "Keep this draft")
        XCTAssertFalse(claude.snapshot.ready)
    }

    func testSignedOutEditorsAndAmbiguousSendControlsAreNotSubmitted() async throws {
        for provider in [WebProvider.grok] {
            let session = WebAgentSession(provider: provider, storageURL: temporaryDirectory().appendingPathComponent("state.json"), fixture: true)
            session.connect()
            try await waitFor { session.snapshot.ready }
            _ = try await session.webView.callAsyncJavaScript("document.querySelector('button[data-testid]').remove()", arguments: [:], in: nil, contentWorld: .page)
            let signedOut = await session.send("Do not send signed out")
            XCTAssertEqual(signedOut?.status, .notSent, provider.name)
            session.reload()
            try await waitFor { session.snapshot.ready }
            _ = try await session.webView.callAsyncJavaScript("const s=document.querySelector('button[aria-label]');s.after(s.cloneNode(true))", arguments: [:], in: nil, contentWorld: .page)
            let ambiguous = await session.send("One intended recipient")
            XCTAssertEqual(ambiguous?.status, .notSent, provider.name)
            XCTAssertFalse(session.snapshot.messages.contains { $0.role == "user" })
        }
    }

    func testRevealingAnOlderMatchingMessageIsNotANewSendReceipt() async throws {
        let session = WebAgentSession(provider: .grok, storageURL: temporaryDirectory().appendingPathComponent("state.json"), fixture: true)
        session.connect()
        try await waitFor { session.snapshot.ready }
        try await bindExistingFixtureChat(session)
        _ = try await session.webView.callAsyncJavaScript("""
        const old=document.createElement('article');old.hidden=true;old.dataset.messageRole='user';old.className='message-bubble';old.dataset.messageId='earlier-message';old.textContent='Repeated question';document.getElementById('transcript').append(old);
        document.querySelector('button[aria-label]').addEventListener('click',e=>{e.stopImmediatePropagation();old.hidden=false;document.querySelector('textarea').value='';},true);
        """, arguments: [:], in: nil, contentWorld: .page)
        let attempt = await session.send("Repeated question")
        XCTAssertEqual(attempt?.status, .uncertain, "An earlier matching message becoming visible does not confirm a new submission")
        let retry = await session.send("Repeated question")
        XCTAssertNil(retry)
    }

    func testPrependingHistoryDoesNotChangeAnOlderMessageIntoAReceipt() async throws {
        let session = WebAgentSession(provider: .grok, storageURL: temporaryDirectory().appendingPathComponent("state.json"), fixture: true)
        session.connect()
        try await waitFor { session.snapshot.ready }
        try await bindExistingFixtureChat(session)
        _ = try await session.webView.callAsyncJavaScript("""
        const old=document.createElement('article');old.dataset.messageRole='user';old.className='message-bubble';old.dataset.messageId='earlier-message';old.textContent='Repeated question';document.getElementById('transcript').append(old);
        document.querySelector('button[aria-label]').addEventListener('click',e=>{e.stopImmediatePropagation();const history=document.createElement('article');history.dataset.messageRole='assistant';history.className='message-bubble';history.dataset.messageId='earlier-history';history.textContent='Earlier history loaded';old.before(history);document.querySelector('textarea').value='';},true);
        """, arguments: [:], in: nil, contentWorld: .page)
        let attempt = await session.send("Repeated question")
        XCTAssertEqual(attempt?.status, .uncertain, "History insertion must not make an old role/index identity look new")
    }

    func testEditingThePageDuringSubmissionCannotConfirmAnotherConversation() async throws {
        let session = WebAgentSession(provider: .grok, storageURL: temporaryDirectory().appendingPathComponent("state.json"), fixture: true)
        session.connect()
        try await waitFor { session.snapshot.ready }
        _ = try await session.webView.callAsyncJavaScript("""
        document.querySelector('button[aria-label]').addEventListener('click',e=>{e.stopImmediatePropagation();
        const input=document.querySelector('textarea');input.focus();document.execCommand('insertText',false,' Changed draft');
        history.replaceState(null,'','/c/older-conversation');
        const old=document.createElement('article');old.dataset.messageRole='user';old.className='message-bubble';old.dataset.messageId='earlier-message';old.textContent='Repeated question';document.getElementById('transcript').append(old);},true);
        """, arguments: [:], in: nil, contentWorld: .page)
        let attempt = await session.send("Repeated question")
        XCTAssertEqual(attempt?.status, .uncertain, "A browser edit during submission invalidates receipt attribution across conversations")
        XCTAssertTrue(session.snapshot.draft.contains("Changed draft"))
    }

    func testAnExistingSidebarConversationCannotConfirmANewChatSend() async throws {
        let session = WebAgentSession(provider: .grok, storageURL: temporaryDirectory().appendingPathComponent("state.json"), fixture: true)
        session.connect()
        try await waitFor { session.snapshot.ready }
        _ = try await session.webView.callAsyncJavaScript("""
        const link=document.createElement('a');link.href='/c/older-conversation';link.textContent='Earlier conversation';document.body.append(link);
        document.querySelector('button[aria-label]').addEventListener('click',e=>{e.stopImmediatePropagation();
        history.replaceState(null,'',link.href);document.querySelector('textarea').value='';
        const old=document.createElement('article');old.dataset.messageRole='user';old.className='message-bubble';old.dataset.messageId='older-message';old.textContent='Repeated question';document.getElementById('transcript').append(old);},true);
        """, arguments: [:], in: nil, contentWorld: .page)
        let attempt = await session.send("Repeated question")
        XCTAssertEqual(attempt?.status, .uncertain, "A known pre-existing conversation cannot be the new-chat receipt")
    }

    func testMultilinePromptMatchesRenderedParagraphs() async throws {
        for provider in [WebProvider.grok] {
            let session = WebAgentSession(provider: provider, storageURL: temporaryDirectory().appendingPathComponent("state.json"), fixture: true)
            session.connect()
            try await waitFor { session.snapshot.ready }
            // Model a site's rendered paragraph markup after its normal Send handler.
            _ = try await session.webView.callAsyncJavaScript("""
            document.querySelector('button[aria-label]').addEventListener('click',()=>{
                document.querySelector('#transcript article').innerHTML='<p>First line</p><p>Second line<br>Third line</p>';
            });
            """, arguments: [:], in: nil, contentWorld: .page)
            let attempt = await session.send("First line\nSecond line\nThird line")
            XCTAssertEqual(attempt?.status, .observed, provider.name)
        }
    }

    func testRecoveredReadinessClearsOnlyTransientComparisonSetupWarnings() async throws {
        for provider in [WebProvider.muse, .grok] {
            let session = WebAgentSession(provider: provider, storageURL: temporaryDirectory().appendingPathComponent("state.json"), fixture: true)
            session.connect()
            try await waitFor { session.snapshot.ready }
            let blocking = provider == .muse
                ? "document.getElementById('hatch-chat-scroll').hidden=true"
                : "const dialog=document.createElement('div');dialog.id='loading-dialog';dialog.setAttribute('role','dialog');dialog.textContent='Loading';document.body.append(dialog)"
            _ = try await session.webView.callAsyncJavaScript(blocking, arguments: [:], in: nil, contentWorld: .page)
            let opened = await session.openComparison(UUID())
            XCTAssertFalse(opened)
            XCTAssertNotNil(session.error)
            let recovery = provider == .muse
                ? "document.getElementById('hatch-chat-scroll').hidden=false"
                : "document.getElementById('loading-dialog').remove()"
            _ = try await session.webView.callAsyncJavaScript(recovery, arguments: [:], in: nil, contentWorld: .page)
            await session.refresh()
            XCTAssertTrue(session.snapshot.ready)
            XCTAssertNil(session.error, "A recovered page must not retain its temporary setup warning")
            XCTAssertTrue(session.state.attempts.isEmpty, "Recovery never sends automatically")

            // An unrelated draft-protection error is not a transient readiness warning.
            _ = try await session.webView.callAsyncJavaScript("const input=document.querySelector('textarea,[contenteditable]');if(input.tagName==='TEXTAREA')input.value='Keep draft';else input.textContent='Keep draft'", arguments: [:], in: nil, contentWorld: .page)
            _ = await session.openComparison(UUID())
            let draftError = try XCTUnwrap(session.error)
            XCTAssertTrue(draftError.contains("has a draft"))
            _ = try await session.webView.callAsyncJavaScript("const input=document.querySelector('textarea,[contenteditable]');if(input.tagName==='TEXTAREA')input.value='';else input.textContent=''", arguments: [:], in: nil, contentWorld: .page)
            await session.refresh()
            XCTAssertTrue(session.snapshot.ready)
            XCTAssertEqual(session.error, draftError)
        }
    }

    // Control structures observed in the signed-in narrow panes on 2026-10-05.
    // No account data or provider network calls are used by these fixtures.
    func testLiveBrowserSupportsInternalFramesWithoutNavigationWarnings() async throws {
        for provider in [WebProvider.grok] {
            let session = WebAgentSession(provider: provider, storageURL: temporaryDirectory().appendingPathComponent("state.json"), fixture: false)
            session.webView.loadHTMLString("""
            <body data-test="navigation"><iframe id="blank" src="about:blank"></iframe>
            <script>
            window.frameReady = [];
            window.addEventListener('message', event => {
                if (['data-frame', 'blob-frame'].includes(event.data)) window.frameReady.push(event.data);
            });
            for (const kind of ['data', 'blob']) {
                const payload = '<script>parent.postMessage("' + kind + '-frame", "*")<' + '/script>';
                const frame = document.createElement('iframe');
                frame.src = kind === 'data' ? 'data:text/html,' + encodeURIComponent(payload)
                    : URL.createObjectURL(new Blob([payload], {type: 'text/html'}));
                document.body.append(frame);
            }
            </script></body>
            """, baseURL: provider.homeURL)
            try await waitFor { session.error != nil || (!session.webView.isLoading && session.webView.url != nil) }
            XCTAssertNil(session.error, provider.name)
            guard session.error == nil else { continue }
            let result = try await session.webView.callAsyncJavaScript("""
            for (let i = 0; i < 40 && window.frameReady.length < 2; i++)
                await new Promise(resolve => setTimeout(resolve, 50));
            return {blank: document.querySelector('#blank').contentDocument.URL, ready: window.frameReady.sort()};
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
            XCTAssertEqual(result?["blank"] as? String, "about:blank")
            XCTAssertEqual(result?["ready"] as? [String], ["blob-frame", "data-frame"])
            XCTAssertNil(session.error)
        }
    }

    func testBlockedAutomaticFrameDoesNotInterruptTheParentPage() async throws {
        let session = WebAgentSession(provider: .grok, storageURL: temporaryDirectory().appendingPathComponent("state.json"), fixture: false)
        session.webView.loadHTMLString("<body>Parent stays usable<iframe src='msgblast-test-blocked://child'></iframe></body>", baseURL: WebProvider.grok.homeURL)
        try await waitFor { !session.webView.isLoading && session.webView.url != nil }
        XCTAssertNil(session.error)
        let text = try await session.webView.callAsyncJavaScript("return document.body.textContent", arguments: [:], in: nil, contentWorld: .page) as? String
        XCTAssertEqual(text, "Parent stays usable")
    }

    func testSuccessfulPageLoadClearsOnlyNavigationErrors() async throws {
        let session = WebAgentSession(provider: .grok, storageURL: temporaryDirectory().appendingPathComponent("state.json"), fixture: false)
        session.webView(session.webView, didFailProvisionalNavigation: nil, withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        XCTAssertNotNil(session.error)
        session.webView.loadHTMLString("<body>Recovered</body>", baseURL: WebProvider.grok.homeURL)
        try await waitFor { !session.webView.isLoading && session.webView.url != nil }
        XCTAssertNil(session.error)
        let brokenStorage = temporaryDirectory()
        try FileManager.default.createDirectory(at: brokenStorage, withIntermediateDirectories: true)
        let blocked = WebAgentSession(provider: .grok, storageURL: brokenStorage, fixture: false)
        let storageError = blocked.error
        XCTAssertNotNil(storageError)
        blocked.webView(blocked.webView, didFailProvisionalNavigation: nil, withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        XCTAssertEqual(blocked.error, storageError)
        blocked.webView.loadHTMLString("<body>Storage remains blocked</body>", baseURL: WebProvider.grok.homeURL)
        try await waitFor { !blocked.webView.isLoading && blocked.webView.url != nil }
        XCTAssertEqual(blocked.error, storageError)
    }

    func testLiveBrowserKeepsBlankLoginPopupInTheSameSession() async throws {
        let session = WebAgentSession(provider: .grok, storageURL: temporaryDirectory().appendingPathComponent("state.json"), fixture: false)
        session.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        session.webView.loadHTMLString("<body>Local login popup test</body>", baseURL: WebProvider.grok.homeURL)
        try await waitFor { session.error != nil || (!session.webView.isLoading && session.webView.url != nil) }
        XCTAssertNil(session.error)
        guard session.error == nil else { return }
        _ = try await session.webView.callAsyncJavaScript("window.open('about:blank','login')", arguments: [:], in: nil, contentWorld: .page)
        try await waitFor { session.popup != nil }
        XCTAssertTrue(session.popup?.configuration.websiteDataStore === session.webView.configuration.websiteDataStore)
        XCTAssertNil(session.error)
        session.closePopup()
    }

    func testGrokFollowUpWaitsForSubmitToBecomeEnabledAndClicksOnce() async throws {
        let session = WebAgentSession(provider: .grok, storageURL: temporaryDirectory().appendingPathComponent("state.json"), fixture: true)
        let html = WebPageScript(provider: .grok).fixture.replacingOccurrences(of: #"<textarea aria-label="Ask Grok anything"></textarea>"#,
            with: #"<div contenteditable="true" role="textbox" aria-label="Ask Grok anything"></div>"#)
        session.connect()
        try await waitFor { session.snapshot.ready }
        session.webView.loadHTMLString(html, baseURL: WebProvider.grok.newChatURL)
        try await waitFor { !session.webView.isLoading }
        let comparison = UUID()
        let first = await session.send("First question", comparisonID: comparison)
        XCTAssertEqual(first?.status, .observed)
        guard first?.status == .observed else { return }
        try await waitFor { session.snapshot.messages.contains { $0.role == "assistant" } }
        _ = try await session.webView.callAsyncJavaScript("""
        window.submitClicks=0;
        send.addEventListener('click',()=>window.submitClicks++);
        input.addEventListener('input',()=>{send.disabled=true;history.replaceState({},'',location.pathname+'?rid=11111111-2222-4333-8444-555555555555');setTimeout(()=>send.disabled=false,600)});
        """, arguments: [:], in: nil, contentWorld: .page)
        let followup = await session.send("Delayed follow-up", comparisonID: comparison)
        XCTAssertEqual(followup?.status, .observed)
        XCTAssertEqual(followup?.conversationURL, first?.conversationURL)
        let clicks = try await session.webView.callAsyncJavaScript("return window.submitClicks", arguments: [:], in: nil, contentWorld: .page) as? Int
        XCTAssertEqual(clicks, 1)
        XCTAssertEqual(session.snapshot.messages.filter { $0.role == "user" }.map(\.text), ["First question", "Delayed follow-up"])
    }

    func testUnavailableSubmitTimesOutWithoutClickingAndKeepsTheDraft() async throws {
        let session = WebAgentSession(provider: .grok, storageURL: temporaryDirectory().appendingPathComponent("state.json"), fixture: true)
        session.connect()
        try await waitFor { session.snapshot.ready }
        try await bindExistingFixtureChat(session)
        _ = try await session.webView.callAsyncJavaScript("""
        window.submitClicks=0;
        send.addEventListener('click',()=>window.submitClicks++);
        input.addEventListener('input',()=>send.disabled=true);
        """, arguments: [:], in: nil, contentWorld: .page)
        let attempt = await session.send("Keep this unsent draft")
        XCTAssertEqual(attempt?.status, .notSent)
        XCTAssertTrue(attempt?.detail?.contains("Send control is unavailable") == true)
        XCTAssertEqual(session.snapshot.draft, "Keep this unsent draft")
        let clicks = try await session.webView.callAsyncJavaScript("return window.submitClicks", arguments: [:], in: nil, contentWorld: .page) as? Int
        XCTAssertEqual(clicks, 0)
        XCTAssertTrue(session.snapshot.messages.isEmpty)
    }

    func testWaitingForSubmitNeverSendsAfterDraftOrConversationChanges() async throws {
        for change in [
            "input.value='Keep my changed draft'",
            "history.replaceState({},'', '/c/different-conversation')",
            "send.after(send.cloneNode(true))",
            "input.focus();input.select();document.execCommand('insertText',false,'Edited then restored');input.value='Do not send after a change'"
        ] {
            let session = WebAgentSession(provider: .grok, storageURL: temporaryDirectory().appendingPathComponent("state.json"), fixture: true)
            session.connect()
            try await waitFor { session.snapshot.ready }
            try await bindExistingFixtureChat(session)
            _ = try await session.webView.callAsyncJavaScript("""
            window.submitClicks=0;
            send.addEventListener('click',()=>window.submitClicks++);
            input.addEventListener('input',()=>{send.disabled=true;setTimeout(()=>{\(change);send.disabled=false},600)},{once:true});
            """, arguments: [:], in: nil, contentWorld: .page)
            let attempt = await session.send("Do not send after a change")
            XCTAssertEqual(attempt?.status, .notSent)
            let clicks = try await session.webView.callAsyncJavaScript("return window.submitClicks", arguments: [:], in: nil, contentWorld: .page) as? Int
            XCTAssertEqual(clicks, 0)
            XCTAssertTrue(session.snapshot.messages.isEmpty)
        }
    }

    func testNavigationWhileWaitingForSubmitStopsBeforeAttempting() async throws {
        let session = WebAgentSession(provider: .grok, storageURL: temporaryDirectory().appendingPathComponent("state.json"), fixture: true)
        session.connect()
        try await waitFor { session.snapshot.ready }
        try await bindExistingFixtureChat(session)
        _ = try await session.webView.callAsyncJavaScript("input.addEventListener('input',()=>send.disabled=true)", arguments: [:], in: nil, contentWorld: .page)
        let navigation = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(300))
            session.webView.loadHTMLString("<body>Different page</body>", baseURL: WebProvider.grok.homeURL)
        }
        let attempt = await session.send("Do not follow a navigation")
        try await navigation.value
        XCTAssertEqual(attempt?.status, .notSent)
        XCTAssertTrue(attempt?.detail?.contains("navigated") == true)
        XCTAssertFalse(session.state.hasUnresolvedSend("Do not follow a navigation"))
        XCTAssertFalse(session.isSending)
    }

    func testGrokResponseSelectorPreservesOnlyTheSameConversationIdentity() throws {
        let base = try XCTUnwrap(URL(string: "https://grok.com/c/known-chat"))
        let response = try XCTUnwrap(URL(string: base.absoluteString + "?rid=11111111-2222-4333-8444-555555555555"))
        XCTAssertEqual(WebProvider.grok.canonicalConversationURL(response), base)
        XCTAssertTrue(WebProvider.grok.acceptsReceipt(from: base, at: response))
        XCTAssertTrue(WebProvider.grok.acceptsReceipt(from: response, at: base))
        XCTAssertFalse(WebProvider.grok.isSavedConversation(response), "Persist only the conversation URL")
        for suffix in ["?rid=not-an-id", "?rid=11111111-2222-4333-8444-555555555555%00ignored", "?rid=11111111-2222-4333-8444-555555555555&mode=other", "?other=1", "#other"] {
            XCTAssertNil(WebProvider.grok.canonicalConversationURL(try XCTUnwrap(URL(string: base.absoluteString + suffix))))
        }
        XCTAssertFalse(WebProvider.grok.acceptsReceipt(from: base, at: try XCTUnwrap(URL(string: "https://grok.com/c/another-chat"))))
        XCTAssertNil(WebProvider.chatgpt.canonicalConversationURL(try XCTUnwrap(URL(string: "https://chatgpt.com/c/chat?rid=11111111-2222-4333-8444-555555555555"))))
    }

    func testLegacyMuseSavedChatMigratesWithoutChangingTheLoginStore() throws {
        let sessionID = UUID(), comparisonID = UUID()
        let url = "https://muse.ai/thread/11111111-2222-3333-4444-555555555555"
        let json = """
        {"sessionID":"\(sessionID)","includeMuse":true,"comparisonID":"\(comparisonID)","museConversations":{"\(comparisonID.uuidString)":"\(url)"}}
        """
        let migrated = try JSONDecoder().decode(WebWorkspaceState.self, from: Data(json.utf8))
        XCTAssertEqual(migrated.sessionID, sessionID)
        XCTAssertTrue(migrated.selected)
        XCTAssertEqual(migrated.conversationURLs[comparisonID.uuidString]?.absoluteString, url)
        let roundTrip = try JSONDecoder().decode(WebWorkspaceState.self, from: JSONEncoder().encode(migrated))
        XCTAssertEqual(roundTrip.conversationURLs, migrated.conversationURLs)
    }

    func testComparisonSelectionSynchronizesEveryProviderIncludingDeselectedOnes() {
        let directory = temporaryDirectory()
        let web = WebAgents(directory: directory, fixture: true), id = UUID()
        web.setComparison(id)
        XCTAssertTrue(web.sessions.allSatisfy { $0.state.comparisonID == id })
        let restored = WebAgents(directory: directory, fixture: true)
        XCTAssertTrue(restored.sessions.allSatisfy { $0.state.comparisonID == id })
        restored.setComparison(nil)
        XCTAssertTrue(restored.sessions.allSatisfy { $0.state.comparisonID == nil && $0.latestComparisonAttempt == nil })
    }

    func testComparisonSetupWaitsForAllLoginsAndDoesNotSubmitOnSignIn() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let web = WebAgents(directory: directory, fixture: true)
        web.connectSelected()
        try await waitFor { web.sessions.allSatisfy { $0.snapshot.ready } }
        let claude = web.sessions[3]
        _ = try await claude.webView.callAsyncJavaScript("chat.hidden=true;login.hidden=false", arguments: [:], in: nil, contentWorld: .page)
        let signedOut = await web.prepareComparison(nil, for: web.selected)
        XCTAssertFalse(signedOut)
        XCTAssertTrue(web.sessions.allSatisfy { $0.state.attempts.isEmpty && !$0.snapshot.messages.contains { $0.role == "user" } })
        _ = try await claude.webView.callAsyncJavaScript("chat.hidden=false;login.hidden=true", arguments: [:], in: nil, contentWorld: .page)
        await claude.refresh()
        // Muse can return to its main page after login; submission must open a side chat.
        _ = try await web.sessions[0].webView.callAsyncJavaScript("history.replaceState({},'', '/')", arguments: [:], in: nil, contentWorld: .page)
        let openedSideChat = await web.prepareComparison(nil, for: web.selected)
        XCTAssertFalse(openedSideChat, "Navigating from an unready main page must only prepare the comparison")
        XCTAssertEqual(web.sessions[0].webView.url, WebProvider.muse.newChatURL)
        let connected = await web.prepareComparison(nil, for: web.selected)
        XCTAssertTrue(connected)
        XCTAssertTrue(web.sessions.allSatisfy { $0.state.attempts.isEmpty && !$0.snapshot.messages.contains { $0.role == "user" } }, "Setup and sign-in must never send")
        let results = await WebAgents.send("Explicit submission after sign-in", to: web.selected)
        XCTAssertEqual(results.count, 4)
        XCTAssertTrue(results.values.allSatisfy { $0.status == .observed })
    }

    func testFailedNewComparisonSetupClearsDeselectedWorkspaceIdentity() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let web = WebAgents(directory: directory, fixture: true), previousID = UUID()
        web.connectSelected()
        try await waitFor { web.sessions.allSatisfy { $0.snapshot.ready } }
        let previous = await WebAgents.send("Previous comparison", to: web.selected, comparisonID: previousID)
        XCTAssertTrue(previous.values.allSatisfy { $0.status == .observed })
        web.setComparison(previousID)
        web.sessions[0].updateState { $0.selected = false }
        let claude = web.sessions[3]
        _ = try await claude.webView.callAsyncJavaScript("chat.hidden=true;login.hidden=false", arguments: [:], in: nil, contentWorld: .page)
        let prepared = await web.prepareComparison(nil, for: web.selected)
        XCTAssertFalse(prepared)
        XCTAssertNil(web.comparisonID, "Failed setup must not restore an old comparison on retry")
        XCTAssertTrue(web.sessions.allSatisfy { $0.state.comparisonID == nil })
        XCTAssertTrue(web.sessions.allSatisfy { $0.state.conversationURLs[previousID.uuidString] == previous[$0.provider]?.conversationURL })
    }

    func testLoginCompletingDuringSetupRequiresAnotherExplicitSubmission() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let web = WebAgents(directory: directory, fixture: true)
        web.connectSelected()
        try await waitFor { web.sessions.allSatisfy { $0.snapshot.ready } }
        let claude = web.sessions[3]
        _ = try await claude.webView.callAsyncJavaScript("chat.hidden=true;login.hidden=false;history.replaceState({},'', '/login')", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertTrue(claude.snapshot.ready, "Exercise a stale snapshot before the next polling tick")
        let signIn = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(500))
            _ = try await claude.webView.callAsyncJavaScript("chat.hidden=false;login.hidden=true", arguments: [:], in: nil, contentWorld: .page)
        }
        let maySubmit = await web.prepareComparison(nil, for: web.selected)
        try await signIn.value
        XCTAssertTrue(claude.snapshot.ready, "The fixture must finish signing in during preparation")
        XCTAssertFalse(maySubmit, "An unready click must never become a queued send after sign-in")
        XCTAssertTrue(web.sessions.allSatisfy { $0.state.attempts.isEmpty })
        let explicitRetry = await web.prepareComparison(nil, for: web.selected)
        XCTAssertTrue(explicitRetry)
    }

    func testComparisonSetupPreservesExistingPageDraft() async throws {
        let web = WebAgents(directory: temporaryDirectory(), fixture: true)
        web.connectSelected()
        try await waitFor { web.sessions.allSatisfy { $0.snapshot.ready } }
        let chatgpt = web.sessions[3]
        _ = try await chatgpt.webView.callAsyncJavaScript("document.querySelector('textarea').value='Keep my page draft'", arguments: [:], in: nil, contentWorld: .page)
        let ready = await web.prepareComparison(nil, for: web.selected)
        XCTAssertFalse(ready)
        XCTAssertEqual(chatgpt.snapshot.draft, "Keep my page draft")
        XCTAssertTrue(web.sessions.allSatisfy { $0.state.attempts.isEmpty })
    }

    func testNewAgentsStartSelectedAndRememberDeselectionAfterRelaunch() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let web = WebAgents(directory: directory, fixture: true)
        XCTAssertEqual(web.selected.map(\.provider), WebProvider.allCases)
        web.toggle(web.sessions[3])
        let restored = WebAgents(directory: directory, fixture: true)
        XCTAssertEqual(restored.selected.map(\.provider), [.muse, .chatgpt, .claude])
        XCTAssertEqual(restored.sessions.map { $0.state.sessionID }, web.sessions.map { $0.state.sessionID })
    }

    func testNewProvidersAttachReceiptsToTheirComparison() async throws {
        for provider in [WebProvider.grok] {
            let session = WebAgentSession(provider: provider, storageURL: temporaryDirectory().appendingPathComponent("state.json"), fixture: true)
            session.connect()
            try await waitFor { session.snapshot.ready }
            let id = UUID()
            let attempt = await session.send("A dedicated conversation", comparisonID: id)
            XCTAssertEqual(attempt?.status, .observed, provider.name)
            XCTAssertEqual(attempt?.comparisonID, id, provider.name)
            XCTAssertEqual(session.state.comparisonID, id, provider.name)
        }
    }

    func testEachProviderKeepsSeparateSavedChatsAcrossComparisonsAndReopening() async throws {
        for provider in WebProvider.allCases.filter({ $0.personalAgentProvider == nil }) {
            let directory = temporaryDirectory(), firstID = UUID(), secondID = UUID()
            let storage = directory.appendingPathComponent("state.json")
            let session = WebAgentSession(provider: provider, storageURL: storage, fixture: true)
            session.connect()
            try await waitFor { session.snapshot.ready }
            let first = await session.send("First question", comparisonID: firstID)
            XCTAssertEqual(first?.status, .observed, provider.name)
            let firstURL = try XCTUnwrap(first?.conversationURL)
            XCTAssertTrue(provider.isSavedConversation(firstURL))
            try await waitFor { session.snapshot.messages.contains { $0.role == "assistant" } }
            let second = await session.send("Second question", comparisonID: secondID)
            XCTAssertEqual(second?.status, .observed, provider.name)
            XCTAssertNotEqual(second?.conversationURL, firstURL, provider.name)
            XCTAssertEqual(session.snapshot.messages.filter { $0.role == "user" }.map(\.text), ["Second question"])
            try await waitFor { session.snapshot.messages.contains { $0.role == "assistant" } }
            await session.openComparison(firstID)
            XCTAssertEqual(session.webView.url, firstURL)
            XCTAssertEqual(session.latestComparisonAttempt?.id, first?.id)
            let followup = await session.send("Follow up", comparisonID: firstID)
            XCTAssertEqual(followup?.status, .observed)
            XCTAssertEqual(followup?.conversationURL, firstURL)
            XCTAssertEqual(session.snapshot.messages.filter { $0.role == "user" }.map(\.text), ["First question", "Follow up"])
            let restored = WebAgentSession(provider: provider, storageURL: storage, fixture: true)
            XCTAssertEqual(restored.state.sessionID, session.state.sessionID)
            XCTAssertEqual(restored.state.conversationURLs[firstID.uuidString], firstURL)
            XCTAssertEqual(restored.state.conversationURLs[secondID.uuidString], second?.conversationURL)
            restored.connect()
            try await waitFor { restored.snapshot.ready }
            XCTAssertEqual(restored.webView.url, firstURL, "The saved destination must survive a new session instance")
        }
    }

    func testEveryProviderRequiresSavedURLAndBlocksUnconfirmedFollowUps() async throws {
        for provider in [WebProvider.grok] {
            let session = WebAgentSession(provider: provider, storageURL: temporaryDirectory().appendingPathComponent("state.json"), fixture: true)
            session.connect()
            try await waitFor { session.snapshot.ready }
            _ = try await session.webView.callAsyncJavaScript("history.replaceState = () => {}", arguments: [:], in: nil, contentWorld: .page)
            let id = UUID()
            let first = await session.send("No saved conversation yet", comparisonID: id)
            XCTAssertEqual(first?.status, .uncertain, provider.name)
            XCTAssertNil(session.state.conversationURLs[id.uuidString])
            let followup = await session.send("Different follow-up", comparisonID: id)
            XCTAssertEqual(followup?.status, .notSent)
            XCTAssertEqual(session.snapshot.messages.filter { $0.role == "user" }.count, 1)
            XCTAssertFalse(provider.acceptsReceipt(from: provider.newChatURL, at: provider.newChatURL))
        }
    }

    private func bindExistingFixtureChat(_ session: WebAgentSession) async throws {
        let id = UUID(), path = session.provider == .claude ? "/chat/existing-fixture" : "/c/existing-fixture"
        let url = URL(string: path, relativeTo: session.provider.homeURL)!.absoluteURL
        _ = try await session.webView.callAsyncJavaScript("history.replaceState({},'',url)", arguments: ["url":url.absoluteString], in: nil, contentWorld: .page)
        session.updateState { $0.comparisonID = id; $0.conversationURLs[id.uuidString] = url }
    }

    private func temporaryDirectory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("MsgBlast-MultiWeb-\(UUID())") }
    private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("WebKit did not reach expected state")
        throw NSError(domain: "WebAgentTests", code: 1)
    }
}
