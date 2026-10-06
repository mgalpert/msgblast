import AppKit
import Combine
import WebKit

@MainActor
public final class WebAgentSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published public private(set) var state = WebWorkspaceState()
    @Published public private(set) var snapshot = WebPageSnapshot()
    @Published public private(set) var isSending = false
    @Published public private(set) var connected = false
    @Published public private(set) var loading = false
    @Published public private(set) var error: String?
    @Published public private(set) var popup: WKWebView?
    @Published public private(set) var popupURL = ""
    @Published public private(set) var avatar: Data?
    // ChatGPT/Claude never touch this lazy view: their transcript is native.
    public lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = fixture ? .nonPersistent() : WKWebsiteDataStore(forIdentifier: state.sessionID)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        view.navigationDelegate = self; view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        return view
    }()
    @Published public private(set) var accountStatus: PersonalAgentAccountStatus = .unknown
    private var installedAgent: InstalledPersonalAgent?
    private var nativeRequest: Task<PersonalAgentReply, Error>?
    private var shuttingDown = false
    private var requestCancelled = false
    public let fixture: Bool
    private let storageURL: URL
    private var storageFailed = false
    private var poll: Task<Void, Never>?
    private var refreshing = false
    private var navigationGeneration = 0
    private var comparisonGeneration = 0
    private var avatarKey: String?
    private var navigationError: String?
    private var readinessError: String?
    public let provider: WebProvider
    private var script: WebPageScript { WebPageScript(provider: provider) }

    public init(provider: WebProvider, storageURL: URL, fixture: Bool) {
        self.provider = provider
        self.storageURL = storageURL
        self.fixture = fixture
        var loaded = WebWorkspaceState()
        var failure: String?
        do { loaded = try JSONDecoder().decode(WebWorkspaceState.self, from: Data(contentsOf: storageURL)).recoveringInFlight() }
        catch CocoaError.fileReadNoSuchFile { }
        catch { failure = "Web session state could not be read. The saved file has been preserved: \(error.localizedDescription)" }
        super.init()
        state = loaded
        storageFailed = failure != nil
        error = failure
        if provider.personalAgentProvider != nil { updateNativeSnapshot() }
        if failure == nil { persist() }
    }

    deinit { poll?.cancel() }

    public func updateState(_ edit: (inout WebWorkspaceState) -> Void) {
        guard !storageFailed else { return }
        let previous = state.comparisonID
        let previousDraft = state.draft
        edit(&state)
        if state.comparisonID != previous { comparisonGeneration += 1 }
        if provider.personalAgentProvider != nil {
            if previous != state.comparisonID {
                state.localDrafts[previous?.uuidString ?? "new"] = previousDraft
                let target = state.comparisonID?.uuidString ?? "new"
                if let saved = state.localDrafts[target] { state.draft = saved }
                else if previous != nil || state.comparisonID == nil || state.localConversations[target] != nil {
                    state.draft = ""
                } else { state.localDrafts["new"] = "" }
            }
            state.localDrafts[state.comparisonID?.uuidString ?? "new"] = state.draft
            updateNativeSnapshot()
        }
        persist()
    }

    public func connect() {
        guard !connected else { return }
        connected = true
        if provider.personalAgentProvider != nil {
            Task { await refresh() }
            return
        }
        loadComparisonChat()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    public func reload() {
        guard !isSending else { return }
        if provider.personalAgentProvider != nil { connect(); Task { await refresh() }; return }
        if !connected { connect() }
        else if fixture { loadComparisonChat() }
        else { webView.reload() }
    }

    public func openComparisonChat() {
        guard !isSending else { return }
        if provider.personalAgentProvider != nil { reload(); return }
        if !connected { connect() }
        else { loadComparisonChat() }
    }

    private var comparisonURL: URL {
        if let id = state.comparisonID,
           let url = state.conversationURLs[id.uuidString], provider.isSavedConversation(url) { return url }
        return provider.newChatURL
    }
    private func loadComparisonChat() {
        if fixture { webView.loadHTMLString(script.fixture, baseURL: comparisonURL) }
        else { webView.load(URLRequest(url: comparisonURL)) }
    }

    public var latestComparisonAttempt: WebSendAttempt? {
        guard state.comparisonID != nil else { return nil }
        return state.attempts.first { $0.comparisonID == state.comparisonID }
    }

    public var locationLabel: String {
        if let agent = provider.personalAgentProvider { return fixture ? "\(agent.name) · Simulated local account" : "\(agent.name) · Local account" }
        let host = webView.url?.host ?? provider.homeURL.host!
        return provider == .muse && webView.url.map(provider.isChatURL) == true ? "\(host) · Side chat" : host
    }

    @discardableResult
    public func openComparison(_ id: UUID?) async -> Bool {
        guard !isSending else { return false }
        if state.comparisonID != id { updateState { $0.comparisonID = id } }
        connect()
        if provider.personalAgentProvider != nil {
            await refresh()
            return snapshot.ready && snapshot.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasIncompleteNativeRequest(for: id)
        }
        do {
            let readyBeforeSetup = try await prepareConversation()
            self.error = nil
            readinessError = nil
            return readyBeforeSetup
        }
        catch is CancellationError { return false }
        catch WebSessionFailure.notReady(let message) {
            readinessError = message
            error = message
            return false
        }
        catch { self.error = error.localizedDescription; return false }
    }

    @discardableResult
    private func prepareConversation() async throws -> Bool {
        // Readiness must come from this click's inspection, not the polling cache.
        // A page that becomes ready during setup needs another explicit submission.
        var readyBeforeSetup = false
        if let id = state.comparisonID, let saved = state.conversationURLs[id.uuidString], !provider.isSavedConversation(saved) {
            throw WebSessionFailure.notSent("This comparison’s saved \(provider.name) chat is invalid. Nothing was sent; its saved address has been preserved.")
        }
        let target = comparisonURL
        let request = comparisonGeneration
        func checkCurrent() throws {
            try Task.checkCancellation()
            guard comparisonGeneration == request else { throw CancellationError() }
        }
        // Polling may be awaiting avatar media. Read the page again immediately before
        // navigation, so an in-flight poll cannot hide a draft the user just typed.
        if !loading, let url = webView.url, provider.isChatURL(url) {
            let result = try await webView.callAsyncJavaScript(script.inspect, arguments: [:], in: nil, contentWorld: .defaultClient)
            try checkCurrent()
            guard let result else { throw WebSessionFailure.notSent("\(provider.name)’s page could not be checked before switching chats.") }
            snapshot = try JSONDecoder().decode(WebPageSnapshot.self, from: JSONSerialization.data(withJSONObject: result))
            readyBeforeSetup = snapshot.ready
        }
        try checkCurrent()
        guard snapshot.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WebSessionFailure.notSent("\(provider.name) has a draft. Send or clear it before switching chats.")
        }
        if !loading, snapshot.url == target.absoluteString, !snapshot.ready {
            throw WebSessionFailure.notReady(snapshot.reason)
        }
        if target == provider.newChatURL, snapshot.url == target.absoluteString,
           snapshot.messages.contains(where: { $0.role == "user" }) {
            throw WebSessionFailure.notSent("\(provider.name) has an unfinished conversation submission. Check its page before starting another comparison.")
        }
        if !loading, snapshot.ready, snapshot.url == target.absoluteString,
           webView.url == target || webView.url.flatMap(provider.canonicalConversationURL) == target { return readyBeforeSetup }
        if webView.url != target {
            if fixture, webView.url != nil {
                _ = try await webView.callAsyncJavaScript("navigateFixtureThread(url)", arguments: ["url":target.absoluteString], in: nil, contentWorld: .page)
            } else { webView.load(URLRequest(url: target)) }
        }
        for _ in 0..<80 {
            try await Task.sleep(for: .milliseconds(250))
            try checkCurrent()
            await refresh()
            try checkCurrent()
            if !loading, snapshot.ready, snapshot.url == target.absoluteString { return readyBeforeSetup }
        }
        throw WebSessionFailure.notReady("\(provider.name)’s comparison chat could not open. Open it in this pane and sign in if needed. Nothing was sent.")
    }

    public func closePopup() { popup = nil; popupURL = ""; Task { await refresh() } }

    public func refresh() async {
        guard connected, !loading, !refreshing else { return }
        if let localProvider = provider.personalAgentProvider {
            refreshing = true
            loading = true
            defer { refreshing = false; loading = false }
            if fixture { accountStatus = .subscription }
            else {
                installedAgent = await LocalPersonalAgent.discover().first { $0.provider == localProvider }
                accountStatus = if let installedAgent { await LocalPersonalAgent.accountStatus(using: installedAgent) } else { .unknown }
            }
            updateNativeSnapshot()
            return
        }
        guard let url = webView.url, provider.isChatURL(url) else {
            var current = WebPageSnapshot()
            current.url = webView.url?.absoluteString ?? ""
            current.reason = provider == .muse ? "Sign in to Muse and open this comparison’s side chat." : "Sign in to \(provider.name) and open a chat."
            if snapshot != current { snapshot = current }
            clearAvatar()
            return
        }
        refreshing = true
        defer { refreshing = false }
        let generation = navigationGeneration
        do {
            if provider == .chatgpt && !isSending {
                _ = try await webView.callAsyncJavaScript(script.configureInitialLayout, arguments: [:], in: nil, contentWorld: .defaultClient)
                guard generation == navigationGeneration else { return }
            }
            let result = try await webView.callAsyncJavaScript(script.inspect, arguments: [:], in: nil, contentWorld: .defaultClient)
            guard generation == navigationGeneration, let result else { return }
            let fresh = try JSONDecoder().decode(WebPageSnapshot.self, from: JSONSerialization.data(withJSONObject: result))
            if snapshot != fresh { snapshot = fresh }
            if fresh.ready, fresh.url == comparisonURL.absoluteString, !storageFailed,
               let readinessError, error == readinessError {
                error = nil
                self.readinessError = nil
            }
            await refreshAvatar(generation: generation)
        } catch {
            guard generation == navigationGeneration else { return }
            var current = WebPageSnapshot()
            current.reason = "\(provider.name)’s page is not ready. Reload or use the page directly."
            if snapshot != current { snapshot = current }
            clearAvatar()
        }
    }

    private func clearAvatar() {
        avatarKey = nil
        if avatar != nil { avatar = nil }
    }

    private func refreshAvatar(generation: Int) async {
        guard provider == .muse, snapshot.ready else { clearAvatar(); return }
        do {
            let result = try await webView.callAsyncJavaScript(MusePageScript.avatar, arguments: ["previousKey": avatarKey ?? ""], in: nil, contentWorld: .defaultClient) as? [String: Any]
            guard generation == navigationGeneration else { return }
            guard let key = result?["key"] as? String else { clearAvatar(); return }
            if key == avatarKey { return }
            guard let png = result?["png"] as? String, png.hasPrefix("data:image/png;base64,"), png.count < 400_000,
                  let data = Data(base64Encoded: String(png.dropFirst(22))),
                  let image = NSBitmapImageRep(data: data), image.pixelsWide == 256, image.pixelsHigh == 256 else { clearAvatar(); return }
            avatarKey = key
            avatar = data
        } catch {
            if generation == navigationGeneration { clearAvatar() }
        }
    }

    @discardableResult
    public func send(_ text: String, comparisonID: UUID? = nil) async -> WebSendAttempt? {
        if provider.personalAgentProvider != nil { return await sendNative(text, comparisonID: comparisonID) }
        guard !isSending, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard !storageFailed else { error = "Repair web session storage before sending."; return nil }
        guard !state.hasUnresolvedSend(text) else { error = "An earlier send of this text is unconfirmed. Check \(provider.name); MsgBlast will not resend it automatically."; return nil }
        isSending = true
        defer { isSending = false }
        var attempt = WebSendAttempt(text: text)
        let id = comparisonID ?? state.comparisonID ?? UUID()
        attempt.comparisonID = id
        var submissionWasPossible = false
        state.attempts.insert(attempt, at: 0)
        do {
            try save()
            guard !state.attempts.contains(where: { $0.comparisonID == id && [.attempting, .uncertain].contains($0.status) }) else {
                throw WebSessionFailure.notSent("This comparison has an unconfirmed \(provider.name) send. Check its chat before continuing; no new chat or resend was attempted.")
            }
            if state.comparisonID != id { comparisonGeneration += 1 }
            state.comparisonID = id
            try save()
            connect()
            try await prepareConversation()
            await refresh()
            guard let url = webView.url, provider.isChatURL(url), snapshot.ready, !loading else {
                throw WebSessionFailure.notSent(snapshot.reason)
            }
            let generation = navigationGeneration
            let expectedURL = snapshot.url
            let preparation = try await webView.callAsyncJavaScript(script.prepare, arguments: ["text": text], in: nil, contentWorld: .defaultClient) as? [String: Any]
            guard preparation?["ok"] as? Bool == true, let messageIDs = preparation?["messageIDs"] as? [String] else {
                throw WebSessionFailure.notSent(preparation?["reason"] as? String ?? "Could not prepare \(provider.name)’s message field.")
            }
            let before = Set(messageIDs)
            guard let messages = preparation?["messages"], let paths = preparation?["existingConversationPaths"] as? [String] else {
                throw WebSessionFailure.notSent("Could not establish the conversation before sending.")
            }
            let baseline = try JSONDecoder().decode([WebPageMessage].self, from: JSONSerialization.data(withJSONObject: messages))
            let existingPaths = Set(paths)
            if provider == .muse { try await Task.sleep(for: .milliseconds(150)) }
            else { try await waitForSendControl(text, expectedURL: expectedURL, generation: generation) }
            guard generation == navigationGeneration, !loading else { throw WebSessionFailure.notSent("\(provider.name) navigated before submission. Review its draft.") }
            attempt.status = .attempting
            try store(attempt) // The possible external side effect is durably recorded first.
            submissionWasPossible = true
            let result = try await webView.callAsyncJavaScript(script.clickSend, arguments: ["text": text, "expectedURL": expectedURL], in: nil, contentWorld: .defaultClient) as? [String: Any]
            if result?["clicked"] as? Bool == false {
                submissionWasPossible = false
                throw WebSessionFailure.notSent(result?["reason"] as? String ?? "\(provider.name)’s Send control was not clicked.")
            }
            guard result?["clicked"] as? Bool == true else { throw WebSessionFailure.unconfirmed }
            let normalizedText = Self.normalized(text)
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(250))
                await refresh()
                guard generation == navigationGeneration, let currentURL = URL(string: snapshot.url) else { break }
                // Draft routes are optimistic: require an assigned conversation URL before saving.
                if url == provider.newChatURL, currentURL == url {
                    if snapshot.submissionInterrupted == true { break }
                    continue
                }
                guard provider.acceptsReceipt(from: url, at: currentURL),
                      let savedURL = provider.canonicalConversationURL(currentURL) else { break }
                // A user edit/navigation or changed history makes attribution ambiguous.
                // First sends may create a URL, but cannot reuse an already linked chat.
                guard snapshot.submissionInterrupted != true,
                      currentURL.path == url.path || (!existingPaths.contains(currentURL.path) && !state.conversationURLs.values.contains(currentURL)),
                      snapshot.messages.starts(with: baseline) else { break }
                let matches = snapshot.messages.filter { !before.contains($0.id) && $0.role == "user" && Self.normalized($0.text) == normalizedText }
                if matches.count == 1 {
                    attempt.status = .observed
                    attempt.messageID = matches[0].id
                    attempt.conversationURL = savedURL
                    state.conversationURLs[id.uuidString] = savedURL
                    attempt.detail = "The outgoing message appeared in \(provider.name). This is a page observation, not a server delivery receipt."
                    try store(attempt)
                    return attempt
                }
                if matches.count > 1 { break }
            }
            attempt.status = .uncertain
            attempt.detail = "Send was clicked, but a unique outgoing message could not be confirmed. Check \(provider.name); no automatic resend."
        } catch {
            if attempt.status == .observed {
                self.error = "The message appeared in \(provider.name), but its receipt could not be saved. Repair storage before sending again."
            } else {
                attempt.status = submissionWasPossible ? .uncertain : .notSent
                attempt.detail = error.localizedDescription
            }
        }
        do { try store(attempt) } catch { self.error = "Could not save the send result. Check \(provider.name) before retrying." }
        return attempt
    }

    private func updateNativeSnapshot() {
        var fresh = snapshot
        fresh.messages = state.comparisonID.flatMap { state.localConversations[$0.uuidString] } ?? []
        fresh.draft = state.draft
        fresh.ready = !storageFailed && (fixture || (installedAgent != nil && [.subscription, .apiKey, .other].contains(accountStatus)))
        fresh.reason = installedAgent == nil && !fixture ? "Install \(provider.personalAgentProvider!.name), then sign in with your local account." : accountStatus.label
        if fresh != snapshot { snapshot = fresh }
    }

    public func acknowledgeIncompleteRequest() {
        guard provider.personalAgentProvider != nil, !isSending else { return }
        updateState { state in
            for i in state.attempts.indices where state.attempts[i].comparisonID == state.comparisonID && state.attempts[i].status == .uncertain {
                state.attempts[i].status = .dismissed
            }
        }
    }

    public func hasUnresolvedSend(_ text: String) -> Bool {
        if provider.personalAgentProvider == nil { return state.hasUnresolvedSend(text) }
        return hasIncompleteNativeRequest(for: state.comparisonID)
    }
    private func hasIncompleteNativeRequest(for id: UUID?) -> Bool {
        state.attempts.contains { $0.comparisonID == id && [.attempting, .uncertain].contains($0.status) }
    }

    public func cancelNativeRequest() { requestCancelled = true; nativeRequest?.cancel() }
    public func beginShutdown() { shuttingDown = true; cancelNativeRequest() }
    public func cancelAndWait() async {
        beginShutdown()
        while provider.personalAgentProvider != nil && isSending { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private func sendNative(_ text: String, comparisonID: UUID?) async -> WebSendAttempt? {
        guard !shuttingDown, !isSending, !storageFailed, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let id = comparisonID ?? state.comparisonID ?? UUID()
        guard !hasIncompleteNativeRequest(for: id) else {
            error = "An earlier request did not complete. Review it before explicitly allowing another request; usage may have been consumed."
            return nil
        }
        isSending = true
        requestCancelled = false
        defer { nativeRequest = nil; isSending = false }
        error = nil
        var attempt = WebSendAttempt(text: text)
        attempt.comparisonID = id
        updateState { $0.comparisonID = id }
        state.attempts.insert(attempt, at: 0)
        var started = false
        do {
            try save()
            connected = true
            await refresh()
            guard !shuttingDown, !requestCancelled else { throw CancellationError() }
            guard snapshot.ready else { throw WebSessionFailure.notSent(snapshot.reason) }
            guard snapshot.draft.isEmpty || snapshot.draft == text else {
                throw WebSessionFailure.notSent("\(provider.name) has a draft. Send or clear it before using the shared composer.")
            }
            let user = WebPageMessage(role: "user", text: text)
            let history = (state.localConversations[id.uuidString] ?? []) + [user]
            attempt.status = .attempting
            try store(attempt)
            started = true
            let savedSessionID = state.localSessionIDs[id.uuidString]
            let workingDirectory = storageURL.deletingLastPathComponent().appendingPathComponent("local-conversations/\(provider.rawValue)/\(id.uuidString)", isDirectory: true)
            let request = Task { [fixture, provider, installedAgent] in
                if fixture {
                    try await Task.sleep(for: .milliseconds(350))
                    return PersonalAgentReply(text: "\(provider.name) fixture reply: \(text)", sessionID: savedSessionID ?? UUID().uuidString)
                }
                guard let installedAgent else { throw PersonalAgentError.unavailable(provider.name) }
                return try await LocalPersonalAgent.reply(to: history, using: installedAgent, sessionID: savedSessionID, workingDirectory: workingDirectory)
            }
            nativeRequest = request
            let answer = try await withTaskCancellationHandler { try await request.value } onCancel: { request.cancel() }
            try Task.checkCancellation()
            state.localConversations[id.uuidString] = history + [WebPageMessage(role: "assistant", text: answer.text)]
            state.localSessionIDs[id.uuidString] = answer.sessionID
            if state.draft == text { state.draft = "" }
            state.localDrafts[id.uuidString] = state.draft
            attempt.status = .observed; attempt.messageID = user.id
            attempt.detail = fixture ? "Simulated reply. No local CLI or provider was contacted." : "Completed reply from the local CLI."
            try store(attempt)
        } catch {
            attempt.status = started ? .uncertain : .notSent
            attempt.detail = error.localizedDescription
            self.error = error.localizedDescription
            do { try store(attempt) } catch { self.error = "Could not save this request. Repair storage before sending again." }
        }
        updateNativeSnapshot()
        return attempt
    }

    private func waitForSendControl(_ text: String, expectedURL: String, generation: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while true {
            try Task.checkCancellation()
            guard generation == navigationGeneration, !loading else {
                throw WebSessionFailure.notSent("\(provider.name) navigated before submission. Review its draft.")
            }
            // Read-only polling leaves the attempt in .preparing until a click is possible.
            let result = try await webView.callAsyncJavaScript(script.sendReadiness, arguments: ["text": text, "expectedURL": expectedURL], in: nil, contentWorld: .defaultClient) as? [String: Any]
            guard ContinuousClock.now < deadline else {
                throw WebSessionFailure.notSent("\(provider.name)’s Send control is unavailable. Review the prepared draft.")
            }
            if result?["ready"] as? Bool == true { return }
            guard result?["retryable"] as? Bool == true else {
                throw WebSessionFailure.notSent(result?["reason"] as? String ?? "Could not check \(provider.name)’s Send control.")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func normalized(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    private func store(_ attempt: WebSendAttempt) throws {
        if let index = state.attempts.firstIndex(where: { $0.id == attempt.id }) { state.attempts[index] = attempt }
        try save()
    }
    private func save() throws {
        guard !storageFailed else { throw WebSessionFailure.notSent("Web session storage is unavailable.") }
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(state).write(to: storageURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
        } catch {
            storageFailed = true
            throw error
        }
    }
    private func persist() {
        do { try save() } catch { storageFailed = true; self.error = "Could not save the web session: \(error.localizedDescription)" }
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if webView === self.webView {
            navigationGeneration += 1; loading = true; snapshot = WebPageSnapshot(); clearAvatar()
        }
    }
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === self.webView {
            loading = false
            if let navigationError, error == navigationError { error = nil }
            navigationError = nil
            Task { await refresh() }
        }
        else { popupURL = webView.url?.absoluteString ?? "" }
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failedNavigation(webView, error: error) }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failedNavigation(webView, error: error) }
    private func failedNavigation(_ view: WKWebView, error: Error) {
        guard view === webView else { return }
        loading = false
        if (error as NSError).code != NSURLErrorCancelled, !storageFailed {
            navigationError = "\(provider.name) could not load: \(error.localizedDescription)"
            self.error = navigationError
        }
    }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === self.webView {
            navigationGeneration += 1; loading = false; snapshot = WebPageSnapshot(); clearAvatar()
            error = "\(provider.name)’s web process stopped. Reload its page. Pending submissions will not be resent."
        }
    }
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        let blankPage = url.scheme == "about" && ["blank", "srcdoc"].contains(url.path)
        // WebKit and sign-in pages use empty windows and inline child frames.
        // These load inside the browser; they never open another app or read local files.
        let allowed = fixture ? (url.absoluteString == "about:blank" || provider.isChatURL(url))
            : url.scheme == "https" || blankPage || (!mainFrame && ["blob", "data"].contains(url.scheme ?? ""))
        if !allowed, mainFrame, navigationAction.navigationType == .linkActivated, !storageFailed {
            navigationError = "This link cannot open inside MsgBlast. Stay on \(provider.name)’s website to continue."
            error = navigationError
        }
        if webView === popup { popupURL = url.absoluteString }
        return allowed ? .allow : .cancel
    }
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard !fixture, navigationAction.targetFrame == nil, let url = navigationAction.request.url,
              url.scheme == "https" || url.absoluteString == "about:blank", popup == nil else { return nil }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self; view.uiDelegate = self
        popupURL = navigationAction.request.url?.absoluteString ?? ""
        popup = view
        return view
    }
    public func webViewDidClose(_ webView: WKWebView) { if webView === popup { closePopup() } }
}

private enum WebSessionFailure: LocalizedError {
    case notSent(String), notReady(String), unconfirmed
    var errorDescription: String? {
        switch self {
        case .notSent(let message), .notReady(let message): message
        case .unconfirmed: "The page did not return a reliable result after Send. Check its page; no automatic resend."
        }
    }
}
