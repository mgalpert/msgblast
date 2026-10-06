import XCTest
import WebKit
@testable import msgblastCore

@MainActor
final class WebServiceTests: XCTestCase {
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

    func testSwitchingComparisonPreservesFreshPageDraft() async throws {
        let session = try makeSession()
        session.connect()
        try await waitFor { session.snapshot.ready }
        let first = await session.send("First comparison", comparisonID: UUID())
        _ = try await session.webView.callAsyncJavaScript("document.querySelector('textarea').value = 'Keep this draft'", arguments: [:], in: nil, contentWorld: .page)
        await session.openComparison(UUID())
        XCTAssertEqual(session.webView.url, first?.conversationURL)
        XCTAssertEqual(session.snapshot.draft, "Keep this draft")
        XCTAssertNotNil(session.error)
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
        _ = NSApplication.shared
        let session = try makeSession()
        let window = NSWindow(contentRect: session.webView.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = session.webView
        window.orderFront(nil)
        defer { window.close() }
        session.connect()
        try await waitFor { session.snapshot.ready }
        XCTAssertNil(session.avatar)
        _ = try await session.webView.callAsyncJavaScript("changeFixtureAvatar()", arguments: [:], in: nil, contentWorld: .page)
        try await waitFor { session.avatar != nil }
        await diagnoseAvatar(session)
        let first = try XCTUnwrap(session.avatar)
        await session.refresh()
        XCTAssertEqual(session.avatar, first, "Unchanged media should retain its cached still")
        _ = try await session.webView.callAsyncJavaScript("changeFixtureAvatar()", arguments: [:], in: nil, contentWorld: .page)
        try await waitFor { session.avatar != nil && session.avatar != first }
        await diagnoseAvatar(session)
        XCTAssertTrue(session.state.attempts.isEmpty, "Reading an avatar must never submit a message")
    }

    func testAvatarClearsOnSignOutAndIsNotPersistedForAnotherAccount() async throws {
        _ = NSApplication.shared
        let session = try makeSession()
        let window = NSWindow(contentRect: session.webView.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = session.webView
        window.orderFront(nil)
        defer { window.close() }
        session.connect()
        try await waitFor { session.snapshot.ready }
        _ = try await session.webView.callAsyncJavaScript("changeFixtureAvatar()", arguments: [:], in: nil, contentWorld: .page)
        try await waitFor { session.avatar != nil }
        await diagnoseAvatar(session)
        let first = session.avatar
        _ = try await session.webView.callAsyncJavaScript("chat.hidden=true;login.hidden=false", arguments: [:], in: nil, contentWorld: .page)
        try await waitFor { !session.snapshot.ready && session.avatar == nil }
        _ = try await session.webView.callAsyncJavaScript("changeFixtureAvatar();chat.hidden=false;login.hidden=true", arguments: [:], in: nil, contentWorld: .page)
        try await waitFor { session.avatar != nil && session.avatar != first }
        await diagnoseAvatar(session)
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

    private func diagnoseAvatar(_ session: WebAgentSession) async {
        print("AVATAR_DIAGNOSTIC snapshot=\(session.snapshot.ready) bytes=\(session.avatar?.count ?? 0)")
        let code = #"""
        const i=document.querySelector('[data-hatch-avatar-layer]');
        const h=i?.parentElement;
        const detail={secure:isSecureContext,uuid:typeof crypto.randomUUID,cache:!!globalThis.__msgblastAvatarSource,srcLength:i?.src.length,srcPrefix:i?.src.slice(0,80),complete:i?.complete,width:i?.naturalWidth,height:i?.naturalHeight,currentSourceMatches:i?.currentSrc===i?.src,imageRects:i?.getClientRects().length,hostRects:h?.getClientRects().length,opacity:i?getComputedStyle(i).opacity:null};
        {const c=document.createElement('canvas');c.width=c.height=256;const ctx=c.getContext('2d');ctx.fillStyle='#ff0000';ctx.fillRect(0,0,256,256);const png=c.toDataURL('image/png');detail.freshPNGLength=png.length;detail.freshPNGPrefix=png.slice(0,80);}
        try {const c=document.createElement('canvas');c.width=c.height=256;c.getContext('2d').drawImage(i,0,0,256,256);detail.pngLength=c.toDataURL('image/png').length;detail.pixel=[...c.getContext('2d').getImageData(128,128,1,1).data];}catch(e){detail.error=String(e);}
        return detail;
        """#
        for (name,world) in [("page",WKContentWorld.page),("client",WKContentWorld.defaultClient)] {
            do {print("AVATAR_DIAGNOSTIC \(name): \(String(describing: try await session.webView.callAsyncJavaScript(code,arguments:[:],in:nil,contentWorld:world)))")}
            catch { print("AVATAR_DIAGNOSTIC \(name) error: \(error)") }
        }
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
