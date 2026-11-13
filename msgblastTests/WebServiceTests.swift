import XCTest
import WebKit
import msgblastRemoteProtocol
@testable import msgblastCore

@MainActor
final class WebServiceTests: XCTestCase {
    func testAlexaShoppingSignedOutSetupOpensAmazonSignInInsteadOfTheStorefront() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = WebAgentSession(provider: .alexaShopping, storageURL: directory.appendingPathComponent("alexa.json"), fixture: true)
        defer { session.beginShutdown() }
        session.connect()
        try await waitFor { session.snapshot.ready }
        _ = try await session.webView.callAsyncJavaScript("""
            document.getElementById('chat').hidden=true;
            const account=document.getElementById('nav-link-accountList');
            account.outerHTML='<a id="nav-link-accountList" href="/ap/signin?openid.return_to=%2F" data-nav-ref="nav_signin">Hello, sign in</a>';
            document.getElementById('nav-link-accountList').onclick=event=>{
                event.preventDefault();history.replaceState({},'',event.currentTarget.href);
                document.getElementById('login').hidden=false;
            };
            """, arguments: [:], in: nil, contentWorld: .page)
        await session.refresh()
        XCTAssertEqual(session.webView.url?.path, "/ap/signin")
        XCTAssertEqual(session.snapshot.signedIn, false)
        XCTAssertFalse(session.isReadyForOnboarding)
    }

    func testAlexaShoppingRequiresSignInAndOpensOnlyItsChatComposer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = WebAgentSession(provider: .alexaShopping, storageURL: directory.appendingPathComponent("alexa.json"), fixture: true)
        defer { session.beginShutdown() }
        session.connect()
        try await waitFor { session.snapshot.ready }
        XCTAssertTrue(session.isReadyForOnboarding)
        _ = try await session.webView.callAsyncJavaScript("history.replaceState({}, '', '/ref=nav_logo')", arguments: [:], in: nil, contentWorld: .page)
        await session.refresh()
        let comparison = UUID()
        let sent = await session.send("Compare reusable water bottle materials", comparisonID: comparison)
        XCTAssertEqual(sent?.status, .observed, sent?.detail ?? "Missing receipt")
        try await waitFor { session.snapshot.messages.contains { $0.role == "assistant" } }
        XCTAssertEqual(session.snapshot.messages.filter { $0.role == "user" }.map(\.text), ["Compare reusable water bottle materials"])
        let search = try await session.webView.callAsyncJavaScript("return document.getElementById('twotabsearchtextbox').value", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(search as? String, "")
        let originalView = session.webView
        session.updateState { $0.comparisonID = UUID() }
        XCTAssertTrue(session.webView === originalView, "Changing comparisons must preserve Amazon’s selected chat")
        _ = try await session.webView.callAsyncJavaScript("document.getElementById('rufus-panel-header-overflow-button').click();document.getElementById('rufus-new-chat-ingress-button').click()", arguments: [:], in: nil, contentWorld: .page)
        await session.refresh()
        XCTAssertTrue(session.snapshot.messages.isEmpty)
        try await openAlexaFixtureHistory(session)
        _ = try await session.webView.callAsyncJavaScript("document.querySelector('#history-rows button').click();", arguments: [:], in: nil, contentWorld: .page)
        for _ in 0..<40 {
            let reopened = try await session.webView.callAsyncJavaScript("return panel.hidden", arguments: [:], in: nil, contentWorld: .page) as? Bool
            if reopened == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        _ = try await session.webView.callAsyncJavaScript("document.getElementById('nav-rufus-disco').click()", arguments: [:], in: nil, contentWorld: .page)
        try await waitFor { session.snapshot.messages.filter { $0.role == "user" }.count == 1 }
        _ = try await session.webView.callAsyncJavaScript("document.getElementById('rufus-text-area').value='Keep my private draft'", arguments: [:], in: nil, contentWorld: .page)
        let blocked = await session.send("Must not replace draft", comparisonID: comparison)
        XCTAssertEqual(blocked?.status, .notSent)
        XCTAssertEqual(session.snapshot.draft, "Keep my private draft")
        _ = try await session.webView.callAsyncJavaScript("document.getElementById('rufus-text-area').value='';chat.hidden=true;login.hidden=false;document.getElementById('nav-link-accountList').hidden=true", arguments: [:], in: nil, contentWorld: .page)
        await session.refresh()
        XCTAssertEqual(session.snapshot.signedIn, false)
        XCTAssertFalse(session.isReadyForOnboarding)
        let signedOut = await session.send("Must not send while signed out", comparisonID: comparison)
        XCTAssertEqual(signedOut?.status, .notSent)
    }

    func testAlexaShoppingDistinguishesUnavailablePanelAndPreservesLongRequests() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = WebAgentSession(provider: .alexaShopping, storageURL: directory.appendingPathComponent("alexa.json"), fixture: true)
        defer { session.beginShutdown() }
        session.connect()
        try await waitFor { session.snapshot.ready }
        let tooLong = await session.send(String(repeating: "x", count: 501))
        XCTAssertEqual(tooLong?.status, .notSent)
        XCTAssertTrue(tooLong?.detail?.contains("500-character") == true)
        XCTAssertFalse(session.snapshot.hasDraft)
        _ = try await session.webView.callAsyncJavaScript("document.getElementById('nav-flyout-rufus').remove();document.getElementById('nav-rufus-disco').remove()", arguments: [:], in: nil, contentWorld: .page)
        await session.refresh()
        XCTAssertEqual(session.snapshot.signedIn, true)
        XCTAssertFalse(session.snapshot.ready)
        XCTAssertFalse(session.isReadyForOnboarding)
        XCTAssertTrue(session.snapshot.reason.contains("unavailable"))
    }

    func testAlexaShoppingProductCardsReachTheTranscriptAsText() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = WebAgentSession(provider: .alexaShopping, storageURL: directory.appendingPathComponent("alexa.json"), fixture: true)
        defer { session.beginShutdown() }
        session.connect()
        try await waitFor { session.snapshot.ready }
        // Amazon's reply: a text section, a category header, then one section per product card.
        let card = #"<div data-csa-c-type="container" data-csa-c-group-id="container-1" data-csa-c-content-id="rufus-dsk-section-container-1"><div><div><div><div role="presentation" tabindex="0" class="r-1loqt21"><div role="presentation"><div><div class="r-1mlwlqe" aria-label="Anker USB C to USB C Cable, 60W (2-Pack, 6 ft)"><img src="x.jpg"></div></div></div><div role="checkbox" aria-label="Select this product to compare"></div><div><div><div><div class="css-146c3p1">Purchased Apr 2025</div></div></div><div class="css-146c3p1 r-8akbws">Anker USB C to USB C Cable, 60W (2-Pack, 6 ft)</div><div aria-label="4.7 out of 5 stars. 91,395 ratings."><div class="css-146c3p1">4.7</div><svg></svg><div class="css-146c3p1">(91,395)</div></div><div class="css-146c3p1">10K+ bought in past month</div><div><div><div><div class="css-146c3p1">$</div><div class="css-146c3p1">9</div><div class="css-146c3p1">99</div></div></div><div class="css-146c3p1">($5.00/count)</div></div><div role="image" aria-label="Prime eligible"><svg></svg></div><div class="css-146c3p1">Two-Day</div><button role="button" data-csa-c-content-id="rufus-dsk-section-asinCard-1" data-csa-c-nile-action-id="asin_cards_B0ABCDEFGH_open_url_1_2"><div class="css-146c3p1">Add to cart</div></button></div></div></div></div></div><div class="css-146c3p1"><span><span>Braided nylon 6 ft cables rated for 60W charging.</span></span></div><div class="css-146c3p1 r-1loqt21" role="link" aria-label="More details about Braided nylon 6 ft cables rated for 60W charging.">More details</div></div>"#
        _ = try await session.webView.callAsyncJavaScript("""
            const container=document.getElementById('rufus-conversation-container');
            const user=document.createElement('article');
            user.className='rufus-customer-text-wrap';
            user.textContent='Suggest a USB-C cable';
            container.append(user);
            container.insertAdjacentHTML('beforeend', '<div data-csa-c-group-id="markdownSection-a" data-csa-c-content-id="rufus-dsk-section-markdownSection-a">Here are some cables.</div>'
                + '<div data-csa-c-group-id="categoryHeader-b" data-csa-c-content-id="rufus-dsk-section-categoryHeader-b"><div>Top Picks Under $15</div><div role="link" aria-label="see more Top Picks Under $15">see more</div></div>'
                + card);
            """, arguments: ["card": card], in: nil, contentWorld: .page)
        await session.refresh()
        let replies = session.snapshot.messages.filter { $0.role == "assistant" }.map(\.text)
        XCTAssertEqual(replies, [
            "Here are some cables.",
            "Top Picks Under $15",
            "Anker USB C to USB C Cable, 60W (2-Pack, 6 ft) · $9.99 · 4.7★ (91,395) · Braided nylon 6 ft cables rated for 60W charging. · https://www.amazon.com/dp/B0ABCDEFGH",
        ])
        XCTAssertFalse(replies.joined().contains("Purchased"), "Order history badges stay on the Mac")
        XCTAssertTrue(session.snapshot.messages.allSatisfy { $0.images == nil }, "A relative image src is not an Amazon CDN URL")
    }

    func testSavedWebPageMessageWithoutImagesStillMatchesAUserReceipt() throws {
        let saved = try JSONDecoder().decode(WebPageMessage.self, from: Data(#"{"id":"u","role":"user","text":"Suggest a cable"}"#.utf8))
        XCTAssertNil(saved.images)
        XCTAssertEqual(saved, WebPageMessage(id: "u", role: "user", text: "Suggest a cable"))
    }

    func testAlexaShoppingProductCardsCarryAmazonImageURLsOnly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = WebAgentSession(provider: .alexaShopping, storageURL: directory.appendingPathComponent("alexa.json"), fixture: true)
        defer { session.beginShutdown() }
        session.connect()
        try await waitFor { session.snapshot.ready }
        let html = #"""
        <div data-csa-c-type="container" data-csa-c-group-id="ok" data-csa-c-content-id="rufus-dsk-section-container-ok"><div aria-label="Example Cable"><img src="https://m.media-amazon.com/images/I/test.jpg"></div><div>Example Cable</div><div>$9.99</div><button data-csa-c-nile-action-id="asin_cards_B000TEST01_open_url_1_2"></button></div>
        <div data-csa-c-type="container" data-csa-c-group-id="bad" data-csa-c-content-id="rufus-dsk-section-container-bad"><div aria-label="Sample Adapter"><img src="https://evil.example.com/x.jpg"></div><div>Sample Adapter</div></div>
        <div data-csa-c-type="container" data-csa-c-group-id="plain" data-csa-c-content-id="rufus-dsk-section-container-plain"><div aria-label="Plain Cord"><img src="http://m.media-amazon.com/images/I/plain.jpg"></div><div>Plain Cord</div></div>
        <div data-csa-c-type="container" data-csa-c-group-id="listed" data-csa-c-content-id="rufus-dsk-section-container-listed"><div aria-label="Listed Cord"><img src="https://images-na.ssl-images-amazon.com/images/I/listed.jpg"></div><div>Listed Cord</div></div>
        <div data-csa-c-type="container" data-csa-c-group-id="suffix" data-csa-c-content-id="rufus-dsk-section-container-suffix"><div aria-label="Suffix Cord"><img src="https://images.media-amazon.com/images/I/suffix.jpg"></div><div>Suffix Cord</div></div>
        """#
        _ = try await session.webView.callAsyncJavaScript("""
            const user=document.createElement('article');
            user.className='rufus-customer-text-wrap';
            user.textContent='Suggest a cable';
            const container=document.getElementById('rufus-conversation-container');
            container.append(user);
            container.insertAdjacentHTML('beforeend', card);
            """, arguments: ["card": html], in: nil, contentWorld: .page)
        await session.refresh()
        func images(_ title: String) -> [String]? { session.snapshot.messages.first { $0.text.hasPrefix(title) }?.images }
        XCTAssertEqual(session.snapshot.messages.first { $0.text.hasPrefix("Example Cable") }?.text,
                       "Example Cable · $9.99 · https://www.amazon.com/dp/B000TEST01")
        XCTAssertEqual(images("Example Cable"), ["https://m.media-amazon.com/images/I/test.jpg"])
        XCTAssertNil(images("Sample Adapter"))
        XCTAssertNil(images("Plain Cord"))
        XCTAssertEqual(images("Listed Cord"), ["https://images-na.ssl-images-amazon.com/images/I/listed.jpg"])
        XCTAssertEqual(images("Suffix Cord"), ["https://images.media-amazon.com/images/I/suffix.jpg"])
        XCTAssertTrue(session.snapshot.messages.filter { $0.role == "user" }.allSatisfy { $0.images == nil })
    }

    func testSharedConversationPageGivesEachComparisonOnlyItsOwnTurns() {
        let first = UUID(), second = UUID(), unsent = UUID()
        var clock = Date(timeIntervalSince1970: 0)
        func attempt(_ text: String, _ comparison: UUID, _ status: WebSendStatus, id: String? = nil) -> WebSendAttempt {
            var attempt = WebSendAttempt(text: text, status: status)
            attempt.comparisonID = comparison; attempt.messageID = id
            clock += 1; attempt.created = clock
            return attempt
        }
        func message(_ id: String, _ role: String, _ text: String) -> WebPageMessage { WebPageMessage(id: id, role: role, text: text) }
        var page = [
            message("u0", "user", "hi"), message("a0", "assistant", "From the website, before any request"),
            message("u1", "user", "hi"), message("a1", "assistant", "First answer"),
            message("u2", "user", "hi"), message("a2", "assistant", "Second answer"),
            message("u3", "user", "and a bottle?"), message("a3", "assistant", "First follow-up answer"),
        ]
        // The same prompt in two comparisons: an observed request keeps its message, and the
        // unattributed one takes the next unowned match. A, B, A interleave on one page.
        var attempts = [
            attempt("hi", first, .observed, id: "u1"),
            attempt("hi", second, .uncertain),
            attempt("and  a bottle?", first, .observed, id: "u3"),
            attempt("never reached the page", unsent, .notSent),
        ]
        func turns(_ id: UUID) -> [String] { WebAgentSession.comparisonTurns(page, attempts: attempts)[id]?.map(\.id) ?? [] }
        XCTAssertEqual(turns(first), ["u1", "a1", "u3", "a3"])
        XCTAssertEqual(turns(second), ["u2", "a2"])
        XCTAssertEqual(turns(unsent), [], "An unsent or new comparison shows nothing from the shared page")
        // A request with no matching message on the page resolves nothing and steals nothing.
        attempts.append(attempt("not on the page", second, .uncertain))
        XCTAssertEqual(turns(second), ["u2", "a2"])
        // An ended comparison's turns stay the same as the shared page keeps growing.
        let ended = turns(first)
        page += [message("u4", "user", "later"), message("a4", "assistant", "Later answer")]
        attempts.append(attempt("later", second, .observed, id: "u4"))
        XCTAssertEqual(turns(first), ended)
        XCTAssertEqual(turns(second), ["u2", "a2", "u4", "a4"])
    }

    func testAlexaShoppingIdleLoaderIsNotAPendingReply() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = WebAgentSession(provider: .alexaShopping, storageURL: directory.appendingPathComponent("alexa.json"), fixture: true)
        defer { session.beginShutdown() }
        session.connect()
        try await waitFor { session.snapshot.ready }
        let loader = try await session.webView.callAsyncJavaScript(
            "return !!document.querySelector('#rufus-loader-avatar:not(.rufus-visibility-hidden)')",
            arguments: [:], in: nil, contentWorld: .page) as? Bool
        XCTAssertEqual(loader, true)
        XCTAssertTrue(session.snapshot.ready, session.snapshot.reason)
        XCTAssertFalse(session.snapshot.reason.hasPrefix("Wait for"))
        let idle = AvailabilityCalculator.availability(AgentSessionSignals(session), inputs: MacAvailabilityInputs(), otherDesktopSending: false, now: Date())
        XCTAssertNotEqual(idle.readiness.state, "busy", idle.readiness.state)
        // A storefront control outside the Alexa panel, such as a carousel's Stop button, is not a reply.
        _ = try await session.webView.callAsyncJavaScript("""
            const stop=document.createElement('button');
            stop.setAttribute('aria-label','Stop');
            stop.textContent='Stop';
            document.body.prepend(stop);
            """, arguments: [:], in: nil, contentWorld: .page)
        await session.refresh()
        XCTAssertTrue(session.snapshot.ready, session.snapshot.reason)
        _ = try await session.webView.callAsyncJavaScript("""
            const user=document.createElement('article');
            user.className='rufus-customer-text-wrap';
            user.textContent='Need a bottle';
            document.getElementById('rufus-conversation-container').append(user);
            """, arguments: [:], in: nil, contentWorld: .page)
        await session.refresh()
        XCTAssertFalse(session.snapshot.ready)
        XCTAssertTrue(session.snapshot.reason.hasPrefix("Wait for"))
        XCTAssertTrue(session.snapshot.reason.hasSuffix("current reply."))
        _ = try await session.webView.callAsyncJavaScript("""
            const reply=document.createElement('article');
            reply.setAttribute('data-csa-c-content-id','rufus-dsk-section-markdownSection-idle');
            reply.setAttribute('data-csa-c-group-id','idle-reply');
            reply.textContent='Try this bottle';
            document.getElementById('rufus-conversation-container').append(reply);
            """, arguments: [:], in: nil, contentWorld: .page)
        await session.refresh()
        XCTAssertTrue(session.snapshot.ready, session.snapshot.reason)
    }

    func testAlexaShoppingNewDocumentCannotReuseAnEarlierSubmissionReceipt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = directory.appendingPathComponent("alexa.json")
        let first = WebAgentSession(provider: .alexaShopping, storageURL: storage, fixture: true)
        first.connect()
        try await waitFor { first.snapshot.ready }
        let previous = await first.send("First fixture request", comparisonID: UUID())
        XCTAssertEqual(previous?.status, .observed)
        first.beginShutdown()
        let reopened = WebAgentSession(provider: .alexaShopping, storageURL: storage, fixture: true)
        defer { reopened.beginShutdown() }
        reopened.connect()
        try await waitFor { reopened.snapshot.ready }
        let next = await reopened.send("Another fixture request", comparisonID: UUID())
        XCTAssertEqual(next?.status, .observed, next?.detail ?? "Missing receipt")
        XCTAssertNotEqual(next?.messageID, previous?.messageID)
        var ambiguous = WebSendAttempt(text: "Another fixture request", status: .uncertain)
        ambiguous.comparisonID = reopened.state.comparisonID
        ambiguous.receiptContext = WebReceiptContext(originalURL: WebProvider.alexaShopping.homeURL, baseline: [], existingPaths: [], candidateURL: WebProvider.alexaShopping.homeURL)
        reopened.updateState { $0.attempts = [ambiguous] }
        try await waitFor { reopened.snapshot.messages.contains { $0.role == "assistant" } }
        await reopened.refresh()
        XCTAssertEqual(reopened.state.attempts.first?.status, .uncertain, "Amazon’s home URL cannot prove the original chat after reload")
        XCTAssertFalse(reopened.canLinkCurrentConversation, "An earlier message cannot resolve an attempt without its original document identity")
    }

    func testAlexaShoppingAcceptsOnlyAmazonHomeAndKeepsItsOwnSavedIdentity() throws {
        let provider = WebProvider.alexaShopping
        XCTAssertEqual(provider.homeURL.absoluteString, "https://www.amazon.com/")
        XCTAssertTrue(OnboardingChoice.offeredChoices.contains(.alexaShopping))
        XCTAssertEqual(try JSONDecoder().decode(WebProvider.self, from: JSONEncoder().encode(provider)), provider)
        for address in ["https://www.amazon.com/", "https://www.amazon.com/ref=nav_logo", "https://www.amazon.com/?ref_=nav_signin"] {
            let url = try XCTUnwrap(URL(string: address))
            XCTAssertTrue(provider.isChatURL(url))
            XCTAssertEqual(provider.canonicalConversationURL(url), provider.homeURL)
        }
        for address in ["https://www.amazon.com/ap/signin", "https://www.amazon.com/gp/cart/view.html", "https://www.amazon.com/s?k=bottles", "https://www.amazon.com.evil.test/", "http://www.amazon.com/", "https://www.amazon.com/#other"] {
            XCTAssertFalse(provider.isChatURL(try XCTUnwrap(URL(string: address))), address)
        }
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

    func testBroadcastPreservesAnEditedAndRetypedDraft() async {
        let draft = BroadcastDraft("First message")
        let (gate, release) = AsyncStream<Void>.makeStream()
        let started = expectation(description: "The broadcast is waiting for its reply")
        let revision = draft.revision.value
        let send = Task { @MainActor in
            await AgentBroadcast.send(draft: draft.text, currentDraft: { draft.text }, shouldClearDraft: { draft.revision.value == revision }, clearDraft: { draft.text = "" }, web: { text in
                started.fulfill()
                for await _ in gate { break }
                return [.muse: WebSendAttempt(text: text, status: .observed)]
            }, messages: { _ in nil })
        }
        await fulfillment(of: [started], timeout: 2)
        draft.text = "Next message"
        draft.text = "First message"
        release.yield(()); release.finish()
        _ = await send.value
        XCTAssertEqual(draft.text, "First message", "The retyped draft belongs to the next message")
    }

    func testBroadcastDraftOwnershipSurvivesPromotionButNotWorkspaceChanges() async {
        for scenario in ["unchanged", "promotion", "switched", "returned", "rejected"] {
            let draft = BroadcastDraft("First message")
            let sentRevision = draft.revision.value
            let comparison = UUID(), other = UUID()
            var workspace: UUID? = comparison
            let (gate, release) = AsyncStream<Void>.makeStream()
            let started = expectation(description: "Broadcast started: \(scenario)")
            let send = Task { @MainActor in
                await AgentBroadcast.send(draft: draft.text, currentDraft: { draft.text }, shouldClearDraft: {
                    draft.revision.value == sentRevision && workspace == comparison
                }, clearDraft: { draft.text = "" }, web: { text in
                    started.fulfill()
                    for await _ in gate { break }
                    return [.muse: WebSendAttempt(text: text, status: scenario == "rejected" ? .notSent : .observed)]
                }, messages: { _ in nil })
            }
            await fulfillment(of: [started], timeout: 2)
            if scenario == "promotion" { draft.revision.switchedWorkspace(promotingDraft: true) }
            if scenario == "switched" || scenario == "returned" {
                draft.revision.switchedWorkspace(promotingDraft: false)
                workspace = other
            }
            if scenario == "returned" {
                draft.revision.switchedWorkspace(promotingDraft: false)
                workspace = comparison
            }
            release.yield(()); release.finish()
            _ = await send.value
            XCTAssertEqual(draft.text, ["unchanged", "promotion"].contains(scenario) ? "" : "First message", scenario)
        }
    }

    func testConfirmedSubmissionClearsDraftBeforeReplyWithoutClearingTheNextDraft() async {
        let draft = BroadcastDraft("First message")
        let submitted = expectation(description: "A durable outgoing receipt was recorded")
        let (gate, release) = AsyncStream<Void>.makeStream()
        let send = Task { @MainActor in
            await AgentBroadcast.send(draft: draft.text, currentDraft: { draft.text }, clearDraft: { draft.text = "" }, web: { text, confirmed in
                confirmed()
                submitted.fulfill()
                for await _ in gate { break }
                return [.muse: WebSendAttempt(text: text, status: .observed)]
            }, messages: { _, _ in nil })
        }
        await fulfillment(of: [submitted], timeout: 2)
        XCTAssertEqual(draft.text, "", "The user need not wait for the reply to start a new draft")
        draft.text = "First message"
        release.yield(()); release.finish()
        _ = await send.value
        XCTAssertEqual(draft.text, "First message", "Completing the reply must not clear a later draft")
    }

    func testConfirmationDoesNotClearAnEditedAndRetypedDraft() async {
        let draft = BroadcastDraft("First message")
        let revision = draft.revision.value
        let started = expectation(description: "The recipient is preparing")
        let (gate, release) = AsyncStream<Void>.makeStream()
        let send = Task { @MainActor in
            await AgentBroadcast.send(draft: draft.text, currentDraft: { draft.text }, shouldClearDraft: { draft.revision.value == revision }, clearDraft: { draft.text = "" }, web: { text, confirmed in
                started.fulfill()
                for await _ in gate { break }
                confirmed()
                return [.muse: WebSendAttempt(text: text, status: .waiting)]
            }, messages: { _, _ in nil })
        }
        await fulfillment(of: [started], timeout: 2)
        draft.text = "Next message"
        draft.text = "First message"
        release.yield(()); release.finish()
        _ = await send.value
        XCTAssertEqual(draft.text, "First message")
    }

    func testMessagesReceiptClearsOnlyWhenARecipientMayHaveBeenSent() async {
        for (states, clearsBeforeReply, clearsAtEnd) in [
            ([Submission.failed, .ready], false, false),
            ([.uncertain, .failed], false, true),
            ([.submitted, .failed], true, true)
        ] {
            let draft = BroadcastDraft("First message")
            let comparison = UUID()
            let finishedMessages = expectation(description: "Messages processing finished")
            let (gate, release) = AsyncStream<Void>.makeStream()
            let send = Task { @MainActor in
                await AgentBroadcast.send(draft: draft.text, currentDraft: { draft.text }, clearDraft: { draft.text = "" }, web: { text, _ in
                    for await _ in gate { break }
                    return [.muse: WebSendAttempt(text: text, status: .notSent)]
                }, messages: { _, confirmed in
                    let result = AgentBroadcast.messagesResult(states: states, comparisonID: comparison, onConfirmed: confirmed)
                    finishedMessages.fulfill()
                    return result
                })
            }
            await fulfillment(of: [finishedMessages], timeout: 2)
            XCTAssertEqual(draft.text.isEmpty, clearsBeforeReply)
            release.yield(()); release.finish()
            let result = await send.value
            XCTAssertEqual(draft.text.isEmpty, clearsAtEnd)
            XCTAssertEqual(result.comparisonID, clearsAtEnd ? comparison : nil)
        }
    }

    func testNoConfirmedSubmissionKeepsDraftWhileRecipientsFail() async {
        let draft = BroadcastDraft("First message")
        let (gate, release) = AsyncStream<Void>.makeStream()
        let started = expectation(description: "A recipient is still checking")
        let send = Task { @MainActor in
            await AgentBroadcast.send(draft: draft.text, currentDraft: { draft.text }, clearDraft: { draft.text = "" }, web: { text, _ in
                started.fulfill()
                for await _ in gate { break }
                return [.muse: WebSendAttempt(text: text, status: .notSent)]
            }, messages: { _, _ in nil })
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(draft.text, "First message")
        release.yield(()); release.finish()
        _ = await send.value
        XCTAssertEqual(draft.text, "First message")
    }

    func testIndependentRepliesUnlockAfterBothSubmissionsWhileAnAgentStillWorks() async {
        let nativeInputFinished = expectation(description: "Native input finished")
        let ready = expectation(description: "Both submission paths finished")
        let (replyGate, releaseReply) = AsyncStream<Void>.makeStream()
        let (messagesGate, releaseMessages) = AsyncStream<Void>.makeStream()
        defer { releaseReply.finish(); releaseMessages.finish() }
        var readyCount = 0
        let barrier = BroadcastSubmissionBarrier { readyCount += 1; ready.fulfill() }
        var draft = "Shared question"
        let broadcast = Task { @MainActor in
            await AgentBroadcast.send(draft: draft, currentDraft: { draft }, clearDraft: { draft = "" }, web: { text in
                barrier.finishNativeInputs()
                nativeInputFinished.fulfill()
                for await _ in replyGate { break }
                return [.init(provider: .wabi): WebSendAttempt(text: text, status: .observed)]
            }, messages: { _ in
                for await _ in messagesGate { break }
                barrier.finishMessages()
                return UUID()
            })
        }
        await fulfillment(of: [nativeInputFinished], timeout: 2)
        XCTAssertEqual(readyCount, 0, "A pending Messages submission must still block private replies")
        releaseMessages.yield(()); releaseMessages.finish()
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertEqual(readyCount, 1)
        XCTAssertEqual(draft, "Shared question", "A reply in progress does not clear or replace the shared draft")
        barrier.finishNativeInputs(); barrier.finishMessages()
        XCTAssertEqual(readyCount, 1, "Repeated handoffs cannot unlock twice")
        releaseReply.yield(()); releaseReply.finish()
        _ = await broadcast.value
        XCTAssertEqual(draft, "")
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

    private func openAlexaFixtureHistory(_ session: WebAgentSession) async throws {
        _ = try await session.webView.callAsyncJavaScript("document.getElementById('rufus-panel-header-overflow-button').click();document.getElementById('rufus-chat-history-ingress-button').click()", arguments: [:], in: nil, contentWorld: .page)
        for _ in 0..<40 {
            let loaded = try await session.webView.callAsyncJavaScript("return !!document.querySelector('#history-rows button') && !document.querySelector('#history-rows [role=status]')", arguments: [:], in: nil, contentWorld: .page) as? Bool
            if loaded == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Fixture history did not finish loading")
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
    var revision = SharedDraftRevision()
    var text: String { didSet { revision.edited(from: oldValue, to: text) } }
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
