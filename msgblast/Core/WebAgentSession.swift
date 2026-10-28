import AppKit
import Combine
import CryptoKit
import WebKit

@MainActor
public final class WebAgentSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published public private(set) var state = WebWorkspaceState()
    @Published public private(set) var snapshot = WebPageSnapshot() { didSet { activePage?.snapshot = snapshot } }
    @Published public private(set) var isSending = false
    @Published public private(set) var connected = false
    @Published public private(set) var loading = false { didSet { activePage?.loading = loading } }
    @Published public private(set) var error: String? { didSet { activePage?.error = error } }
    @Published public private(set) var popup: WKWebView?
    @Published public private(set) var popupURL = ""
    @Published public private(set) var avatar: Data? { didSet { activePage?.avatar = avatar } }
    // Account cookies are shared; DOM, navigation and receipt ownership belong to a comparison.
    private lazy var websiteDataStore = fixture ? WKWebsiteDataStore.nonPersistent() : WKWebsiteDataStore(forIdentifier: state.sessionID)
    private var pages: [String: WebConversationPage] = [:]
    private var activePage: WebConversationPage?
    public var webView: WKWebView { currentPage().view }
    private var fixtureBrowserSignInRequired = false
    private var browserImportCookieBaseline: [HTTPCookie]?
    private func makePage(_ id: UUID?) -> WebConversationPage {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        view.navigationDelegate = self; view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        return WebConversationPage(comparisonID: id, view: view)
    }
    private func currentPage() -> WebConversationPage {
        if let activePage { return activePage }
        let page = makePage(state.comparisonID)
        if provider == .dots { page.avatar = state.savedAvatar }
        pages[page.key] = page
        activePage = page
        return page
    }
    public func messagesForComparison(_ id: UUID) -> [WebPageMessage] {
        if state.comparisonID == id { return snapshot.messages }
        return pages[id.uuidString]?.snapshot.messages ?? state.localConversations[id.uuidString] ?? []
    }
    public func canArchiveComparison(_ id: UUID) -> Bool {
        let submitted = state.attempts.contains { $0.comparisonID == id && $0.status.confirmsSubmission }
        if provider.usesNativeConversation {
            return !submitted || state.localConversations[id.uuidString] != nil
        }
        let historyExpected = state.conversationURLs[id.uuidString] != nil || submitted
        if !historyExpected { return true }
        guard let page = pages[id.uuidString], !page.loading else { return false }
        return !page.snapshot.messages.isEmpty
    }
    private func selectPage(previous: UUID?) {
        guard let old = activePage else { return }
        let key = state.comparisonID?.uuidString ?? "new"
        if old.key == key { return }
        // Account-wide conversations keep their live page across comparisons,
        // including unsent drafts and replies that arrive between polls.
        if provider == .dots || provider.sharesOneConversation {
            pages.removeValue(forKey: old.key)
            old.comparisonID = state.comparisonID
            pages[key] = old
            return
        }
        // The first send adopts the signed-in new-chat pane prepared by the composer.
        if previous == nil, let id = state.comparisonID, pages[key] == nil,
           state.attempts.filter({ $0.comparisonID == id }).allSatisfy({ $0.status == .preparing }),
           (state.conversationURLs[key] == nil && !old.snapshot.messages.contains(where: { $0.role == "user" })) ||
           (state.conversationURLs[key] != nil && old.view.url.flatMap(provider.canonicalConversationURL) == state.conversationURLs[key]) {
            pages.removeValue(forKey: old.key)
            old.comparisonID = id
            pages[key] = old
            return
        }
        let page = pages[key] ?? makePage(state.comparisonID)
        pages[key] = page
        page.lastUsed = Date()
        activePage = page
        publish(page)
        if connected && page.view.url == nil { loadComparisonChat() }
    }
    private func publish(_ page: WebConversationPage) {
        guard activePage === page else { return }
        if snapshot != page.snapshot { snapshot = page.snapshot }
        if loading != page.loading { loading = page.loading }
        if !storageFailed && error != page.error { error = page.error }
        if avatar != page.avatar { avatar = page.avatar }
    }
    @Published public private(set) var desktopReady = false
    public var desktopRecoveryMessage: String? {
        guard let app = provider.desktopApp, isEnabled, !desktopReady else { return nil }
        if !desktopInstallation.isInstalled { return "Install \(app.name) to continue." }
        if isAutomaticallyWaitingForNativeReply, error == latestComparisonAttempt?.detail { return nil }
        if let error, !error.isEmpty { return error }
        // A saved chat reconnects during the next explicit send. Only an
        // observed failure needs a recovery action; stale readiness is normal.
        return nil
    }
    @Published public private(set) var desktopStatus = "Connect an open app conversation."
    @Published public private(set) var desktopInstallation = DesktopAppInstallation(url: nil, processID: nil)
    @Published public private(set) var grokBotNames: [String] = []
    @Published public private(set) var accountStatus: PersonalAgentAccountStatus = .unknown
    private var installedAgent: InstalledPersonalAgent?
    private var nativeRequest: Task<PersonalAgentReply, Error>?
    private let museApp: MuseAppConversation
    private let claudeApp: ClaudeAppConversation
    private let chatgptApp: ChatGPTAppConversation
    private var chatgptKind: ChatGPTAppKind? { provider == .chatgptApp ? .chatgpt : provider == .dotsApp ? .dots : nil }
    private let geminiApp: GeminiAppConversation
    @Published public private(set) var geminiOptions = GeminiOptions()
    private var geminiConfigurationError: String?
    private let wabiApp: WabiAppConversation
    private let desktopApps: DesktopAppInstallationClient
    private let desktopDriver: DesktopAppConversation
    private var grokBotCredentials: GrokBotCredentials?
    private var grokBotConnectionReady: Bool?
    private var grokBotReceiver: GrokBotCallbackReceiver?
    private var grokBotTunnel: GrokBotTunnel?
    private var grokBotReplyURL: URL?
    @Published public private(set) var grokBotConnectionActivity: GrokBotConnectionActivity?
    @Published public private(set) var grokBotNeedsKeychainRetry = false
    @Published public private(set) var grokBotRemembersConnection = false
    public var configuringGrokBot: Bool { grokBotConnectionActivity != nil }
    private var shuttingDown = false
    private var requestCancelled = false
    private var nativeCancellationRequestedBeforeShutdown = false
    public let fixture: Bool
    private let storageURL: URL
    private var storageFailed = false
    private var grokBotReplyStorageFailure: UUID?
    private var poll: Task<Void, Never>?
    private var nativeRecoveryPoll: Task<Void, Never>?
    private var nativeRecoveryGeneration = UUID()
    private var refreshing = false
    private var flushingDrafts = false
    private var navigationGeneration: Int { activePage?.generation ?? 0 }
    private var comparisonGeneration = 0
    private var readinessError: String? { get { activePage?.readinessError } set { currentPage().readinessError = newValue } }
    private var receiptGenerations: [UUID: WebReceiptGeneration] = [:]
    private var manualRecoveryScopes: [UUID: (comparison: Int, page: WebReceiptGeneration)] = [:]
    private static let sharedDraftKey = "shared-account"
    public let provider: WebProvider
    public let id: WebAgentID
    public var name: String { state.displayName ?? provider.name }
    public var isStorageAvailable: Bool { !storageFailed }
    private var script: WebPageScript { WebPageScript(provider: provider) }

    public var canSubmitNativePrompt: Bool {
        guard isEnabled, !storageFailed, !loading, !isSending, !shuttingDown else { return false }
        return snapshot.ready || (provider.desktopApp != nil && desktopInstallation.isInstalled &&
            state.desktopConversation != nil &&
            !hasIncompleteNativeRequest(for: state.comparisonID))
    }

    public var isReadyForOnboarding: Bool {
        guard isEnabled, connected, !storageFailed, !loading else { return false }
        if provider.usesNativeConversation { return snapshot.ready }
        return !webView.isLoading && canInspectWebsite && snapshot.signedIn == true
    }

    public convenience init(provider: WebProvider, storageURL: URL, fixture: Bool, migrationError: String? = nil, agentID: WebAgentID? = nil, accountID: UUID? = nil, name: String? = nil) {
        self.init(provider: provider, storageURL: storageURL, fixture: fixture, migrationError: migrationError, agentID: agentID, accountID: accountID, name: name, museApp: .shared)
    }
    init(provider: WebProvider, storageURL: URL, fixture: Bool, migrationError: String? = nil, agentID: WebAgentID? = nil, accountID: UUID? = nil, name: String? = nil, museApp: MuseAppConversation, desktopApps: DesktopAppInstallationClient? = nil, wabiApp: WabiAppConversation = .shared, desktopDriver: DesktopAppConversation = .shared, geminiApp: GeminiAppConversation = .shared, claudeApp: ClaudeAppConversation = .shared, chatgptApp: ChatGPTAppConversation = .shared) {
        self.museApp = museApp
        self.claudeApp = claudeApp
        self.chatgptApp = chatgptApp
        self.geminiApp = geminiApp
        self.wabiApp = wabiApp
        self.desktopApps = desktopApps ?? (fixture ? .demo : .system)
        self.desktopDriver = desktopDriver
        self.provider = provider
        self.id = agentID ?? WebAgentID(provider: provider)
        self.storageURL = storageURL
        self.fixture = fixture
        var loaded = WebWorkspaceState()
        loaded.selected = false
        if let accountID { loaded.sessionID = accountID }
        loaded.displayName = name
        var failure: String? = migrationError
        do { loaded = try JSONDecoder().decode(WebWorkspaceState.self, from: Data(contentsOf: storageURL)).recoveringInFlight() }
        catch CocoaError.fileReadNoSuchFile { }
        catch { failure = "Web session state could not be read. The saved file has been preserved: \(error.localizedDescription)" }
        // Import the last active draft before WebAgents can select a different
        // comparison. Retain old entries for recovery; an empty shared value
        // records an explicit clear and must never revive a legacy draft.
        if failure == nil, provider.sharesOneConversation, loaded.webDrafts[Self.sharedDraftKey] == nil {
            if let draft = loaded.webDrafts[loaded.comparisonID?.uuidString ?? "new"] {
                loaded.webDrafts[Self.sharedDraftKey] = draft
            } else {
                let drafts = Set(loaded.webDrafts.values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                if drafts.count == 1 { loaded.webDrafts[Self.sharedDraftKey] = drafts.first }
            }
        }
        super.init()
        state = loaded
        if provider == .dots { avatar = loaded.savedAvatar }
        storageFailed = failure != nil
        error = failure
        if provider == .grokbot {
            for index in state.attempts.indices where state.attempts[index].status == .waiting {
                state.attempts[index].status = .uncertain
                state.attempts[index].detail = "msgblast stopped waiting for this reply. Check Grok Bot before continuing."
            }
        }
        if provider == .grokbot && !fixture && !storageFailed && state.grokBotRememberedConnection != false {
            setGrokBotConnectionActivity(.readingKey)
            Task { [weak self] in _ = await self?.restoreGrokBotConnection() }
        }
        if provider.desktopApp != nil { refreshDesktopInstallation() }
        else if provider.usesNativeConversation { updateNativeSnapshot() }
        if failure == nil { persist() }
    }

    deinit { poll?.cancel(); nativeRecoveryPoll?.cancel() }

    public func rename(_ name: String) throws {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= 80 else { throw WebAgentConfigurationError.invalidName }
        let previous = state.displayName
        state.displayName = cleaned
        do { try save() } catch { state.displayName = previous; throw error }
    }

    public func updateState(_ edit: (inout WebWorkspaceState) -> Void) {
        guard !storageFailed else { return }
        let previous = state.comparisonID
        let previousDraft = state.draft
        edit(&state)
        if state.comparisonID != previous {
            if provider.sharesOneConversation {
                // Keep failed request context for review, but a later echo may
                // belong to the next comparison. Automatic recovery requires
                // continuous ownership of the page in this running session.
                manualRecoveryScopes.removeAll()
            }
            browserImportCookieBaseline = nil
            comparisonGeneration += 1
            if provider.desktopApp != nil { desktopReady = false }
            if !provider.usesNativeConversation { selectPage(previous: previous) }
        }
        if provider.usesNativeConversation {
            if previous != state.comparisonID {
                state.localDrafts[previous?.uuidString ?? "new"] = previousDraft
                let target = state.comparisonID?.uuidString ?? "new"
                if let saved = state.localDrafts[target] { state.draft = saved }
                else if previous != nil || state.comparisonID == nil || state.localConversations[target] != nil {
                    state.draft = ""
                } else {
                    // A new comparison inherits its unsent draft and its identity.
                    state.localDraftRevisions[target] = state.localDraftRevisions["new"]
                    state.localDrafts["new"] = ""
                    state.localDraftRevisions["new"] = UUID()
                }
            } else if state.draft != previousDraft {
                state.localDraftRevisions[state.comparisonID?.uuidString ?? "new"] = UUID()
            }
            state.localDrafts[state.comparisonID?.uuidString ?? "new"] = state.draft
            updateNativeSnapshot()
        }
        persist()
    }

    public var isEnabled: Bool { provider.isAvailableInBuild && (provider.usesNativeConversation ? state.enabled == true : state.websiteEnabled != false) }

    public func setEnabled(_ enabled: Bool) {
        if enabled, provider.desktopApp != nil {
            refreshDesktopInstallation()
            guard desktopInstallation.isInstalled else { return }
        }
        updateState {
            if provider.usesNativeConversation { $0.enabled = enabled }
            else { $0.websiteEnabled = enabled }
            if !enabled { $0.selected = false }
        }
        if !enabled { cancelNativeRequest(); stopNativeRecovery() }
        else { startNativeRecoveryIfNeeded() }
        if provider == .grokbot {
            if enabled, grokBotReplyURL == nil { grokBotConnectionReady = nil }
            if connected { Task { await refresh() } }
        }
    }

    public func connect() {
        connect(automaticallyRefresh: true)
    }

    /// Register only this website's cookies before loading its onboarding page.
    /// Existing comparison accounts must not be replaced by another browser profile.
    public func registerBrowserCookies(_ cookies: [HTTPCookie]) async throws -> Int {
        guard !provider.usesNativeConversation, !storageFailed, !isSending, !shuttingDown else {
            throw WebSessionFailure.notSent("This account cannot import a browser login right now.")
        }
        // Back can return here after a provider page has already opened. Flush
        // its draft and reconcile any manual submission before changing cookies.
        try await saveBrowserDrafts()
        guard state.conversationURLs.isEmpty, state.comparisonID == nil, state.dotsURL == nil else {
            throw WebSessionFailure.notSent("Sign in to the account used by your saved conversations.")
        }
        let host = provider.homeURL.host!
        let belongsToProvider: (HTTPCookie) -> Bool = { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return BrowserLoginImporter.matches(domain: domain, websiteHost: host)
        }
        let applicable = cookies.filter { belongsToProvider($0) && ($0.expiresDate.map { $0 > Date() } ?? true) }
        let store = websiteDataStore.httpCookieStore
        let replacingImport = browserImportCookieBaseline != nil
        // A second profile must replace this setup's first import, including
        // server-refreshed cookies, while retaining the original app session.
        if let baseline = browserImportCookieBaseline {
            for cookie in await store.allCookies() where belongsToProvider(cookie) { await store.deleteCookie(cookie) }
            for cookie in baseline { await store.setCookie(cookie) }
        }
        if fixture { fixtureBrowserSignInRequired = applicable.isEmpty }
        guard !applicable.isEmpty else {
            if connected && (fixture || replacingImport) { reload() }
            return 0
        }
        if browserImportCookieBaseline == nil { browserImportCookieBaseline = await store.allCookies().filter(belongsToProvider) }
        for cookie in applicable {
            try Task.checkCancellation()
            await store.setCookie(cookie)
        }
        let registered = await store.allCookies()
        if connected { reload() }
        return applicable.filter { candidate in
            registered.contains { $0.name == candidate.name && $0.domain == candidate.domain && $0.path == candidate.path && $0.value == candidate.value }
        }.count
    }

    // Controlled fixtures can own refresh boundaries without racing the poller.
    func connect(automaticallyRefresh: Bool) {
        if connected {
            if automaticallyRefresh { startNativeRecoveryIfNeeded() }
            return
        }
        connected = true
        if provider == .grokbot {
            if !fixture { Task { await refresh() }; return }
            poll = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                }
            }
            return
        }
        if provider.personalAgentProvider != nil || provider.desktopApp != nil {
            if automaticallyRefresh { startNativeRecoveryIfNeeded() }
            if automaticallyRefresh { Task { await refresh() } }
            return
        }
        loadComparisonChat()
        guard automaticallyRefresh else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshPages()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    public func reload() {
        guard !isSending else { return }
        if provider == .grokbot && grokBotReplyURL == nil { grokBotConnectionReady = nil }
        if provider.usesNativeConversation { connect(); Task { await refresh() }; return }
        if !connected { connect() }
        else if fixture { loadComparisonChat() }
        else { webView.reload() }
    }

    public func openComparisonChat() {
        guard !isSending else { return }
        if provider.usesNativeConversation { reload(); return }
        if !connected { connect() }
        else { loadComparisonChat() }
    }

    private var comparisonURL: URL { comparisonURL(for: state.comparisonID) }
    private func comparisonURL(for id: UUID?) -> URL {
        if let id,
           let url = state.conversationURLs[id.uuidString], provider.isSavedConversation(url) { return url }
        if let url = unresolvedWebAttempt(for: id)?.pinnedConversationURL, provider.isSavedConversation(url) { return url }
        if provider == .dots, let url = state.dotsURL, provider.isSavedConversation(url) { return url }
        return provider.newChatURL
    }

    private var unresolvedWebAttempt: WebSendAttempt? {
        unresolvedWebAttempt(for: state.comparisonID)
    }
    private func unresolvedWebAttempt(for id: UUID?) -> WebSendAttempt? {
        guard !provider.usesNativeConversation, id != nil else { return nil }
        return state.attempts.first { $0.comparisonID == id && $0.status == .uncertain }
    }

    private var linkableWebAttempt: WebSendAttempt? {
        guard !provider.usesNativeConversation else { return nil }
        if let attempt = unresolvedWebAttempt { return attempt }
        guard let id = state.comparisonID, state.conversationURLs[id.uuidString] == nil else { return nil }
        // Older versions did not retain preparation context for a rejected send.
        // Link only after the user reviews its existing request and reply.
        return state.attempts.first {
            $0.comparisonID == id && $0.status == .notSent &&
            ($0.manualContext == nil || !canAutomaticallyRecoverManual($0, in: activePage))
        }
    }

    private func canAutomaticallyRecoverManual(_ attempt: WebSendAttempt, in page: WebConversationPage?) -> Bool {
        guard provider.sharesOneConversation else { return true }
        guard !hasCompetingUnresolvedAttempt(for: attempt),
              let scope = manualRecoveryScopes[attempt.id], let page else { return false }
        return scope.comparison == comparisonGeneration && scope.page.matches(page)
    }

    private func hasCompetingUnresolvedAttempt(for attempt: WebSendAttempt) -> Bool {
        state.attempts.contains {
            $0.id != attempt.id && $0.status.isUnresolved &&
            Self.normalized($0.text) == Self.normalized(attempt.text)
        }
    }

    public var draftRecoveryText: String? {
        guard !provider.usesNativeConversation, snapshot.ready, !snapshot.hasDraft,
              activePage?.restoredDraft == false,
              let draft = state.webDrafts[draftKey(for: state.comparisonID)] ??
                (provider.sharesOneConversation ? state.webDrafts[state.comparisonID?.uuidString ?? "new"] : nil),
              !draft.isEmpty else { return nil }
        return draft
    }

    private func draftKey(for comparison: UUID?) -> String {
        provider.sharesOneConversation ? Self.sharedDraftKey : comparison?.uuidString ?? "new"
    }

    public var needsConversationLink: Bool {
        linkableWebAttempt != nil
    }

    public var canLinkCurrentConversation: Bool {
        guard needsConversationLink, !isSending, !loading, snapshot.ready, snapshot.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let attempt = linkableWebAttempt, let comparison = state.comparisonID, let current = URL(string: snapshot.url),
              let url = provider.canonicalConversationURL(current),
              webView.url.flatMap(provider.canonicalConversationURL) == url,
              (provider == .dots || provider.sharesOneConversation || !state.conversationURLs.contains(where: { $0.key != comparison.uuidString && provider.canonicalConversationURL($0.value) == url })) else { return false }
        if let saved = state.conversationURLs[comparison.uuidString], provider.canonicalConversationURL(saved) != url { return false }
        if let candidate = attempt.pinnedConversationURL, candidate != url { return false }
        if provider.sharesOneConversation, hasCompetingUnresolvedAttempt(for: attempt) { return false }
        let matches = linkCandidates(for: attempt)
        guard matches.count == 1 else { return false }
        return snapshot.messages.dropFirst(matches[0] + 1).prefix { $0.role != "user" }.contains { $0.role == "assistant" }
    }

    // In a shared conversation, a message another attempt already observed belongs to that attempt.
    private func claimedMessageIDs(excluding attempt: WebSendAttempt) -> Set<String> {
        provider.sharesOneConversation ? Set(state.attempts.compactMap { $0.id == attempt.id ? nil : $0.messageID }) : []
    }

    private func linkCandidates(for attempt: WebSendAttempt) -> [Int] {
        let claimed = claimedMessageIDs(excluding: attempt)
        return snapshot.messages.indices.filter { snapshot.messages[$0].role == "user" && !claimed.contains(snapshot.messages[$0].id) && Self.normalized(snapshot.messages[$0].text) == Self.normalized(attempt.text) }
    }

    // Explicit user linking recovers requests whose automatic attribution could not finish.
    // It observes the existing request; it never clicks Send or repeats that request.
    public func linkCurrentConversation() async {
        guard !provider.usesNativeConversation, !isSending, !loading, !storageFailed else { return }
        let comparison = state.comparisonID
        let generation = comparisonGeneration
        let navigation = navigationGeneration
        do {
            guard let result = try await webView.callAsyncJavaScript(script.inspect, arguments: [:], in: nil, contentWorld: .defaultClient),
                  generation == comparisonGeneration, navigation == navigationGeneration, !loading else { return }
            snapshot = try JSONDecoder().decode(WebPageSnapshot.self, from: JSONSerialization.data(withJSONObject: result))
        } catch { return }
        guard comparisonGeneration == generation, !isSending, canLinkCurrentConversation,
              var attempt = linkableWebAttempt, let comparison, let current = URL(string: snapshot.url),
              let url = provider.canonicalConversationURL(current) else { return }
        attempt.status = .observed
        attempt.messageID = linkCandidates(for: attempt).first.map { snapshot.messages[$0].id }
        attempt.conversationURL = url
        attempt.recoveryConversationURL = nil
        attempt.receiptContext = nil
        attempt.manualContext = nil
        manualRecoveryScopes.removeValue(forKey: attempt.id)
        receiptGenerations.removeValue(forKey: attempt.id)
        attempt.detail = "Conversation linked after the user reviewed its existing request and reply."
        state.conversationURLs[comparison.uuidString] = url
        do { try store(attempt); error = nil }
        catch { self.error = "Could not save the linked conversation. Repair storage before sending." }
    }
    private func loadComparisonChat() {
        if fixture {
            var html = script.fixture
            if fixtureBrowserSignInRequired {
                html = html.replacingOccurrences(of: "<div id=\"login\" hidden>", with: "<div id=\"login\">")
                    .replacingOccurrences(of: "<main id=\"chat\">", with: "<main id=\"chat\" hidden>")
                    .replacingOccurrences(of: "<div id=\"chat\">", with: "<div id=\"chat\" hidden>")
            }
            webView.loadHTMLString(html, baseURL: comparisonURL)
        }
        else { webView.load(URLRequest(url: comparisonURL)) }
    }

    public var latestComparisonAttempt: WebSendAttempt? {
        guard state.comparisonID != nil else { return nil }
        return state.attempts.first { $0.comparisonID == state.comparisonID }
    }

    /// Preserve a shared prompt for an app that failed before any submission.
    /// This never changes the app's own draft or schedules a retry.
    public func recordUnsentPreparation(_ text: String, comparisonID: UUID, reason: String) -> WebSendAttempt? {
        guard provider.desktopApp != nil, !storageFailed, !isSending, state.comparisonID == comparisonID else { return nil }
        var attempt = WebSendAttempt(text: text, status: .notSent)
        attempt.comparisonID = comparisonID
        attempt.detail = reason
        state.attempts.insert(attempt, at: 0)
        do { try save(); objectWillChange.send(); return attempt }
        catch { self.error = "Could not save the unsent request: \(error.localizedDescription)"; return nil }
    }

    /// Persist each recipient's intent before another transport can submit.
    public func planNativePreparation(_ text: String, comparisonID: UUID) -> WebSendAttempt? {
        guard provider.desktopApp != nil, isEnabled, !storageFailed, !isSending,
              state.comparisonID == comparisonID, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var attempt = WebSendAttempt(text: text, status: .preparing)
        attempt.comparisonID = comparisonID
        state.attempts.insert(attempt, at: 0)
        do { try save(); objectWillChange.send(); return attempt }
        catch { self.error = "Could not save the request: \(error.localizedDescription)"; return nil }
    }

    /// Only a request that never reached native submission can become retryable.
    @discardableResult
    public func failNativePreparation(_ attemptID: UUID, reason: String) -> WebSendAttempt? {
        guard !storageFailed, let index = state.attempts.firstIndex(where: { $0.id == attemptID }),
              state.attempts[index].status == .preparing else { return nil }
        state.attempts[index].status = .notSent
        state.attempts[index].detail = reason
        do { try save(); objectWillChange.send(); return state.attempts[index] }
        catch { self.error = "Could not save the unsent request: \(error.localizedDescription)"; return nil }
    }

    public var isAutomaticallyWaitingForNativeReply: Bool {
        guard !isSending, let latest = latestComparisonAttempt else { return false }
        let attempt = recoverableDotsAttempt() ?? recoverableWabiAttempt() ?? recoverableMuseAttempt() ??
            recoverableClaudeAttempt() ?? recoverableGrokAttempt() ?? recoverableChatGPTAttempt()
        return attempt?.id == latest.id
    }

    public var pendingNativeAttempt: WebSendAttempt? {
        guard provider.usesNativeConversation, let attempt = latestComparisonAttempt,
              [.preparing, .attempting, .waiting, .uncertain].contains(attempt.status),
              !snapshot.messages.contains(where: { $0.id == (attempt.messageID ?? attempt.id.uuidString) }) else { return nil }
        return attempt
    }

    public var locationLabel: String {
        if provider.desktopApp != nil {
            if fixture { return "Simulated desktop app · no app contacted" }
            switch provider {
            case .chatgptApp: return "ChatGPT app · Dedicated chat"
            case .claudeApp: return "Claude app · Dedicated chat"
            case .dotsApp: return "ChatGPT app · Your continuing dot"
            case .museApp: return "Muse app · Side chat"
            case .geminiApp: return "Gemini · Dedicated \(geminiPreferences.mode.name.lowercased())"
            case .wabi: return "Wabi · Dedicated chat"
            default: return "Desktop app · Shared conversation"
            }
        }
        if provider == .grokbot { return fixture ? "Simulated webhook · no Bot contacted" : "Webhook connection" }
        if let agent = provider.personalAgentProvider { return fixture ? "\(agent.name) · Simulated local account" : "\(agent.name) · Local account" }
        let host = webView.url?.host ?? provider.homeURL.host!
        if provider.sharesOneConversation { return "\(host) · Shared account conversation" }
        return provider == .dots ? "\(host) · Your dot" : provider == .muse && webView.url.map(provider.isChatURL) == true ? "\(host) · Side chat" : host
    }

    /// Only an explicit first submission may launch an app without a comparison ID.
    @discardableResult
    public func openComparison(_ id: UUID?, startNativeApp: Bool = false, allowSavedPrivateDraft: Bool = false, foregroundPreparation: Bool = false) async -> Bool {
        guard !isSending else { return false }
        if state.comparisonID != id {
            if provider == .geminiApp { geminiConfigurationError = nil; geminiOptions = .init() }
            updateState { $0.comparisonID = id }
        }
        connect(automaticallyRefresh: !provider.usesNativeConversation)
        if provider.usesNativeConversation {
            // An explicit first shared prompt is prepared before it has a
            // comparison ID. Passive blank selection must remain read-only.
            if provider.desktopApp != nil, id != nil || startNativeApp {
                do { try await launchDesktopAppForConversation() }
                catch is CancellationError { return false }
                catch { self.error = error.localizedDescription; return false }
            }
            while provider.desktopApp != nil && refreshing {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return false }
                guard state.comparisonID == id, !shuttingDown else { return false }
            }
            guard state.comparisonID == id, !shuttingDown else { return false }
            await refresh()
            if provider == .geminiApp, snapshot.ready { await configureGemini(geminiPreferences) }
            if snapshot.ready { await prepareAdditionalDesktopConversation(foreground: foregroundPreparation) }
            let ready = snapshot.ready && (allowSavedPrivateDraft || snapshot.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && !hasIncompleteNativeRequest(for: id)
            if ready { error = nil }
            else if !snapshot.ready || hasIncompleteNativeRequest(for: id) { error = snapshot.reason }
            else { error = "\(provider.name) has an unsent draft. It was preserved." }
            return ready
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
        catch WebSessionFailure.notSent(let message) {
            // Viewing a retained draft is allowed; only shared submission is blocked.
            if !snapshot.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               webView.url == comparisonURL || webView.url.flatMap(provider.canonicalConversationURL) == comparisonURL {
                self.error = nil
            } else { self.error = message }
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
            recordCurrentDot(from: snapshot)
            reconcileUnconfirmedReceipt()
            reconcileManualSubmission(in: currentPage())
            readyBeforeSetup = snapshot.ready
        }
        try checkCurrent()
        guard snapshot.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WebSessionFailure.notSent("\(provider.name) has a draft. Send or clear it before sending from the shared composer.")
        }
        let target = comparisonURL // Inspection above may have recovered a late receipt.
        func matchesTarget(_ location: String) -> Bool {
            if location == target.absoluteString { return true }
            // /dots resolves to the account's ongoing dot, never a new ChatGPT chat.
            return provider == .dots && target == provider.newChatURL &&
                URL(string: location).flatMap(provider.canonicalConversationURL) != nil
        }
        let pinned = unresolvedWebAttempt?.pinnedConversationURL
        // Viewing an unlinked live page must not navigate it away, including a
        // request sent directly in the website after automatic preparation failed.
        if let id = state.comparisonID, state.conversationURLs[id.uuidString] == nil, !needsConversationLink,
           let current = webView.url, provider.canonicalConversationURL(current) != nil,
           snapshot.messages.contains(where: { $0.role == "user" }) || state.attempts.contains(where: { $0.comparisonID == id && $0.manualContext != nil }) {
            return readyBeforeSetup
        }
        // A missed first receipt must not erase the live chat before recovery can inspect it.
        if needsConversationLink, state.comparisonID.flatMap({ state.conversationURLs[$0.uuidString] }) == nil,
           let current = URL(string: snapshot.url), let currentChat = provider.canonicalConversationURL(current),
           pinned == nil || pinned == currentChat {
            return readyBeforeSetup
        }
        if !loading, snapshot.url == target.absoluteString, !snapshot.ready {
            throw WebSessionFailure.notReady(snapshot.reason)
        }
        if !provider.sharesOneConversation, target == provider.newChatURL, snapshot.url == target.absoluteString,
           snapshot.messages.contains(where: { $0.role == "user" }) {
            throw WebSessionFailure.notSent("\(provider.name) has an unfinished conversation submission. Check its page before starting another comparison.")
        }
        if !loading, snapshot.ready, matchesTarget(snapshot.url),
           webView.url == target || webView.url.flatMap(provider.canonicalConversationURL) == target || (provider == .dots && target == provider.newChatURL) { return readyBeforeSetup }
        let resolvingDotLanding = provider == .dots && target == provider.newChatURL &&
            (loading || webView.url == nil || webView.url.flatMap(provider.canonicalConversationURL) != nil)
        if webView.url != target && !resolvingDotLanding {
            if fixture, webView.url != nil {
                _ = try await webView.callAsyncJavaScript("navigateFixtureThread(url)", arguments: ["url":target.absoluteString], in: nil, contentWorld: .page)
            } else { webView.load(URLRequest(url: target)) }
        }
        for _ in 0..<80 {
            try await Task.sleep(for: .milliseconds(250))
            try checkCurrent()
            await refresh()
            try checkCurrent()
            if !loading, snapshot.ready, matchesTarget(snapshot.url) { return readyBeforeSetup }
        }
        throw WebSessionFailure.notReady("\(provider.name)’s comparison chat could not open. Open it in this pane and sign in if needed. Nothing was sent.")
    }

    // Inspect rendered account controls afresh; send readiness also includes busy pages and dialogs.
    public func checkSignIn() async -> Bool? {
        guard !provider.usesNativeConversation else { return nil }
        connect()
        do {
            for _ in 0..<40 {
                try Task.checkCancellation()
                if !loading, !webView.isLoading, webView.url != nil { break }
                try await Task.sleep(for: .milliseconds(250))
            }
            guard !loading, !webView.isLoading, canInspectWebsite else { return nil }
            let generation = navigationGeneration
            let result = try await webView.callAsyncJavaScript(script.signInStatus, arguments: [:], in: nil, contentWorld: .defaultClient)
            guard !loading, !webView.isLoading, generation == navigationGeneration, let result else { return nil }
            var fresh = try JSONDecoder().decode(WebPageSnapshot.self, from: JSONSerialization.data(withJSONObject: result))
            if fresh.url == snapshot.url {
                fresh.messages = snapshot.messages
                fresh.submissionInterrupted = snapshot.submissionInterrupted
            }
            if snapshot != fresh { snapshot = fresh }
            if fixture, fresh.signedIn == true { fixtureBrowserSignInRequired = false }
            return fresh.signedIn
        } catch { return nil }
    }

    private var canInspectWebsite: Bool {
        guard let url = webView.url else { return false }
        return url.scheme == "https" && url.host == provider.homeURL.host
    }

    public func closePopup() { popup = nil; popupURL = ""; Task { await refresh() } }

    public func checkNativeAccount() async -> Bool {
        guard provider.personalAgentProvider != nil, !shuttingDown else { return false }
        connect()
        // Finish any earlier status check, then request a current result.
        while refreshing || loading {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
            guard !shuttingDown else { return false }
        }
        await refresh()
        return !Task.isCancelled && !shuttingDown && !loading && snapshot.ready
    }

    public func refresh() async {
        guard connected else { return }
        if provider.desktopApp != nil {
            await refreshDesktop(); return
        }
        if provider == .grokbot {
            guard !loading, !refreshing else { return }
            await refreshGrokBot(); return
        }
        if let localProvider = provider.personalAgentProvider {
            guard !loading, !refreshing else { return }
            refreshing = true; loading = true
            defer { refreshing = false; loading = false }
            if fixture { accountStatus = .subscription }
            else {
                installedAgent = await LocalPersonalAgent.discover().first { $0.provider == localProvider }
                accountStatus = if let installedAgent { await LocalPersonalAgent.accountStatus(using: installedAgent) } else { .unknown }
            }
            updateNativeSnapshot()
            return
        }
        await refresh(currentPage())
    }

    private func refreshPages() async {
        guard connected, !shuttingDown, !flushingDrafts else { return }
        for page in Array(pages.values) { await refresh(page) }
        await unloadInactivePages()
    }

    private func refresh(_ page: WebConversationPage) async {
        guard !shuttingDown, !flushingDrafts, !page.loading, !page.refreshing, pages[page.key] === page else { return }
        page.refreshing = true
        defer { page.refreshing = false }
        guard let url = page.view.url, url.scheme == "https", url.host == provider.homeURL.host else {
            var current = WebPageSnapshot(); current.url = page.view.url?.absoluteString ?? ""
            current.reason = "Sign in to \(provider.name) and open this comparison’s chat."
            page.snapshot = current
            if provider != .dots { clearAvatar(in: page) }
            if provider == .dots, state.savedAvatar != nil || state.dotsURL != nil,
               ["/auth/login", "/auth/logout", "/login", "/logout"].contains(page.view.url?.path ?? "") {
                clearSavedDot(in: page)
            }
            publish(page)
            return
        }
        let generation = page.generation
        do {
            if (provider == .chatgpt || provider == .dots) && !isSending && provider.isChatURL(url) {
                _ = try await page.view.callAsyncJavaScript(script.configureInitialLayout, arguments: [:], in: nil, contentWorld: .defaultClient)
                guard generation == page.generation, !shuttingDown, !flushingDrafts else { return }
            }
            let result = try await page.view.callAsyncJavaScript(script.inspect, arguments: [:], in: nil, contentWorld: .defaultClient)
            guard generation == page.generation, !shuttingDown, !flushingDrafts, let result else { return }
            let fresh = try JSONDecoder().decode(WebPageSnapshot.self, from: JSONSerialization.data(withJSONObject: result))
            // WebKit can expose the destination before its new document replaces about:blank.
            guard let inspectedURL = URL(string: fresh.url), let displayedURL = page.view.url,
                  inspectedURL == displayedURL ||
                  (provider.canonicalConversationURL(inspectedURL) != nil &&
                   provider.canonicalConversationURL(inspectedURL) == provider.canonicalConversationURL(displayedURL)) else { return }
            page.snapshot = fresh
            if provider == .dots, page.snapshot.signedOut == true {
                clearSavedDot(in: page)
                publish(page)
                return
            }
            recordCurrentDot(from: page.snapshot, in: page)
            reconcileUnconfirmedReceipt(in: page)
            reconcileManualSubmission(in: page)
            if page.snapshot.draftAvailable != true || page.snapshot.signedIn == false { page.restoredDraft = false }
            // Restore only an empty editor at its saved destination; restoring never submits.
            if !page.restoredDraft, page.snapshot.ready, page.snapshot.url == comparisonURL(for: page.comparisonID).absoluteString {
                if !page.snapshot.hasDraft, let draft = state.webDrafts[draftKey(for: page.comparisonID)], !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let restored = try await page.view.callAsyncJavaScript(script.prepare, arguments: ["text": draft], in: nil, contentWorld: .defaultClient) as? [String: Any]
                    guard generation == page.generation, !shuttingDown, !flushingDrafts else { return }
                    if restored?["ok"] as? Bool == true {
                        page.snapshot.draft = draft
                        page.restoredDraft = true
                    }
                } else if provider.sharesOneConversation, state.webDrafts[Self.sharedDraftKey] == nil,
                          state.webDrafts.values.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    // Ambiguous legacy drafts remain available for explicit
                    // recovery; an empty editor must not mark them discarded.
                    page.restoredDraft = false
                } else { page.restoredDraft = true }
            }
            try recordDraft(in: page, from: page.snapshot)
            if page.snapshot.ready, page.snapshot.url == comparisonURL(for: page.comparisonID).absoluteString,
               let readiness = page.readinessError, page.error == readiness {
                page.error = nil; page.readinessError = nil
            }
            publish(page)
            await refreshAvatar(in: page, generation: generation)
        } catch {
            guard generation == page.generation, !shuttingDown, !flushingDrafts else { return }
            if storageFailed {
                self.error = "Could not save this comparison’s draft. Repair storage before quitting."
                return
            }
            var current = WebPageSnapshot()
            current.reason = "\(provider.name)’s page is not ready. Reload or use the page directly."
            page.snapshot = current
            if provider != .dots { clearAvatar(in: page) }
            publish(page)
        }
    }

    private func recordDraft(in page: WebConversationPage, from snapshot: WebPageSnapshot) throws {
        // An unavailable editor is not an empty draft. Failed restoration retains its saved text.
        guard snapshot.draftAvailable == true, snapshot.signedIn != false,
              page.restoredDraft || snapshot.hasDraft else { return }
        let key = draftKey(for: page.comparisonID)
        if state.webDrafts[key] != snapshot.draft {
            state.webDrafts[key] = snapshot.draft
            try save()
        }
    }

    // Read the editors directly at Quit rather than waiting for unrelated avatar/media polling.
    public func saveBrowserDrafts() async throws {
        guard !provider.usesNativeConversation, connected else { return }
        flushingDrafts = true
        defer { flushingDrafts = false }
        for page in Array(pages.values) where !page.loading && page.view.url != nil {
            let generation = page.generation
            let result = try await page.view.callAsyncJavaScript(script.inspect, arguments: [:], in: nil, contentWorld: .defaultClient)
            guard generation == page.generation, pages[page.key] === page, let result else { continue }
            let fresh = try JSONDecoder().decode(WebPageSnapshot.self, from: JSONSerialization.data(withJSONObject: result))
            page.snapshot = fresh
            reconcileManualSubmission(in: page)
            try recordDraft(in: page, from: fresh)
        }
        try save()
    }

    // Four recent panes per account normally suffice. Freshly inspect each candidate:
    // an edit or a pending reply may have arrived since its last polling snapshot.
    func unloadInactivePages(limit: Int = 4) async {
        guard pages.count > limit, !shuttingDown, !flushingDrafts else { return }
        let candidates = pages.values.sorted { $0.lastUsed < $1.lastUsed }
        for page in candidates where pages.count > limit {
            guard page !== activePage, !page.loading, !page.refreshing else { continue }
            let generation = page.generation
            page.refreshing = true
            defer { page.refreshing = false }
            do {
                let result = try await page.view.callAsyncJavaScript(script.inspect, arguments: [:], in: nil, contentWorld: .defaultClient)
                guard !shuttingDown, !flushingDrafts, generation == page.generation, pages[page.key] === page, let result else { continue }
                let fresh = try JSONDecoder().decode(WebPageSnapshot.self, from: JSONSerialization.data(withJSONObject: result))
                page.snapshot = fresh
                try recordDraft(in: page, from: fresh)
                guard page !== activePage, fresh.ready, fresh.draftAvailable == true, !fresh.hasDraft,
                      page.restoredDraft, state.webDrafts[page.key, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      unresolvedWebAttempt(for: page.comparisonID) == nil else { continue }
                if page.comparisonID == nil {
                    guard !fresh.messages.contains(where: { $0.role == "user" }) else { continue }
                } else {
                    guard let saved = state.conversationURLs[page.key],
                          provider.canonicalConversationURL(page.view.url ?? provider.newChatURL) == saved,
                          fresh.messages.last?.role == "assistant", fresh.messages.last?.text.isEmpty == false else { continue }
                }
                page.view.navigationDelegate = nil; page.view.uiDelegate = nil
                page.view.stopLoading()
                pages.removeValue(forKey: page.key)
            } catch { continue } // A page we could not inspect safely stays alive.
        }
    }

    private func recordCurrentDot(from fresh: WebPageSnapshot) {
        recordCurrentDot(from: fresh, in: currentPage())
    }

    private func recordCurrentDot(from fresh: WebPageSnapshot, in page: WebConversationPage) {
        guard provider == .dots, fresh.ready, !page.loading, let url = URL(string: fresh.url),
              page.view.url == url, let saved = provider.canonicalConversationURL(url), saved != state.dotsURL else { return }
        updateState { $0.dotsURL = saved; $0.savedAvatar = nil }
        clearAvatar(in: page)
    }

    private func clearAvatar(in page: WebConversationPage) {
        page.avatarKey = nil; page.avatar = nil
        publish(page)
    }

    private func clearSavedDot(in page: WebConversationPage) {
        clearAvatar(in: page)
        if state.savedAvatar != nil || state.dotsURL != nil {
            updateState { $0.savedAvatar = nil; $0.dotsURL = nil }
        }
    }

    private func refreshAvatar(in page: WebConversationPage, generation: Int) async {
        guard provider == .muse || provider == .dots else { return }
        if provider == .dots && page.view.window == nil { return }
        if provider == .muse && !page.snapshot.ready { clearAvatar(in: page); return }
        do {
            let result = try await page.view.callAsyncJavaScript(script.avatar, arguments: ["previousKey": page.avatarKey ?? ""], in: nil, contentWorld: .defaultClient) as? [String: Any]
            guard generation == page.generation, !shuttingDown, !flushingDrafts else { return }
            guard let key = result?["key"] as? String else {
                if provider == .muse { clearAvatar(in: page) }
                return
            }
            if key == page.avatarKey { return }
            let data: Data
            if provider == .dots {
                let bounds = page.view.bounds
                guard page.view.window != nil, !page.loading, let capturedURL = page.view.url, let result,
                      result["url"] as? String == capturedURL.absoluteString,
                      let viewport = result["viewport"] as? [String: Double],
                      let viewportWidth = viewport["width"], let viewportHeight = viewport["height"],
                      // CSS viewport dimensions round native fractional pane sizes.
                      abs(viewportWidth - Double(bounds.width)) < 1, abs(viewportHeight - Double(bounds.height)) < 1,
                      let rect = result["rect"] as? [String: Double],
                      let x = rect["x"], let y = rect["y"], let width = rect["width"], let height = rect["height"] else { return }
                let crop = CGRect(x: x, y: y, width: width, height: height)
                let configuration = WKSnapshotConfiguration()
                // Capture the viewport first. Cropping in WebKit can reposition Dots'
                // anchored header and capture the composer instead of its pet.
                configuration.rect = bounds
                configuration.snapshotWidth = NSNumber(value: bounds.width)
                let image: NSImage = try await withCheckedThrowingContinuation { continuation in
                    page.view.takeSnapshot(with: configuration) { image, error in
                        if let image { continuation.resume(returning: image) }
                        else { continuation.resume(throwing: error ?? WebSessionFailure.unconfirmed) }
                    }
                }
                // Layout and artwork can change while WebKit captures. Leave the old
                // image and key intact on mismatch so the next refresh retries.
                let verified = try await page.view.callAsyncJavaScript(script.avatar, arguments: ["previousKey": key], in: nil, contentWorld: .defaultClient) as? [String: Any]
                guard generation == page.generation, !shuttingDown, !flushingDrafts, !page.loading, page.view.url == capturedURL, page.view.bounds == bounds,
                      let verified, NSDictionary(dictionary: result).isEqual(to: verified),
                      state.dotsURL == capturedURL, let png = Self.avatarPNG(image, crop: crop) else { return }
                data = png
                updateState { $0.savedAvatar = png }
            } else {
                guard let png = result?["png"] as? String, png.hasPrefix("data:image/png;base64,"), png.count < 400_000,
                      let decoded = Data(base64Encoded: String(png.dropFirst(22))),
                      let image = NSBitmapImageRep(data: decoded), image.pixelsWide == 256, image.pixelsHigh == 256 else { clearAvatar(in: page); return }
                data = decoded
            }
            page.avatarKey = key
            page.avatar = data
            publish(page)
        } catch {
            if generation == page.generation && provider == .muse { clearAvatar(in: page) }
        }
    }

    private static func avatarPNG(_ image: NSImage, crop: CGRect) -> Data? {
        guard crop.width > 0, crop.height > 0,
              CGRect(origin: .zero, size: image.size).contains(crop) else { return nil }
        // JavaScript uses a top-left origin; NSImage's source rectangle uses bottom-left.
        let source = NSRect(x: crop.minX, y: image.size.height - crop.maxY, width: crop.width, height: crop.height)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: 256, height: 256), from: source, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    @discardableResult
    public func send(_ text: String, comparisonID: UUID? = nil,
                     onSubmissionFinished: @escaping @MainActor @Sendable () -> Void = {},
                     onConfirmedSubmission: @escaping @MainActor @Sendable () -> Void = {},
                     plannedAttemptID: UUID? = nil, consumePrivateDraft: Bool = true) async -> WebSendAttempt? {
        defer { onSubmissionFinished() }
        guard plannedAttemptID == nil || provider.desktopApp != nil else { return nil }
        if provider == .grokbot { return await sendGrokBot(text, comparisonID: comparisonID, consumePrivateDraft: consumePrivateDraft) }
        if provider.personalAgentProvider != nil || provider.desktopApp != nil { return await sendNative(text, comparisonID: comparisonID, onSubmissionFinished: onSubmissionFinished, onConfirmedSubmission: onConfirmedSubmission, plannedAttemptID: plannedAttemptID, consumePrivateDraft: consumePrivateDraft) }
        guard isEnabled, !isSending, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard !storageFailed else { error = "Repair web session storage before sending."; return nil }
        await refresh()
        guard isEnabled, !isSending else { return nil }
        guard !hasUnresolvedSend(text) else { error = "An earlier send of this text is unconfirmed. Check \(provider.name); MsgBlast will not resend it automatically."; return nil }
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
                throw WebSessionFailure.notSent("Open the original \(provider.name) chat and choose Use this conversation before sending a follow-up.")
            }
            updateState { $0.comparisonID = id }
            try save()
            connect()
            try await prepareConversation()
            await refresh()
            guard draftRecoveryText == nil else {
                throw WebSessionFailure.notSent("Your saved draft is preserved. Copy it into this chat before sending another message.")
            }
            guard let url = webView.url, provider.isChatURL(url), snapshot.ready, !loading else {
                throw WebSessionFailure.notSent(snapshot.reason)
            }
            if let destination = provider.canonicalConversationURL(url), state.conversationURLs[id.uuidString] != destination,
               !provider.sharesOneConversation,
               !(provider == .dots && state.dotsURL == destination) {
                throw WebSessionFailure.notSent("This page’s conversation is not linked to this comparison. Review it and continue in the page; nothing was sent from the shared composer.")
            }
            let generation = navigationGeneration
            let expectedURL = snapshot.url
            let preparation: [String: Any]?
            do {
                preparation = try await webView.callAsyncJavaScript(script.prepare, arguments: ["text": text], in: nil, contentWorld: .defaultClient) as? [String: Any]
            } catch {
                guard generation == navigationGeneration, !loading else {
                    throw WebSessionFailure.notSent("\(provider.name) navigated before submission. Review its draft.")
                }
                throw error
            }
            guard preparation?["ok"] as? Bool == true, preparation?["messageIDs"] as? [String] != nil else {
                throw WebSessionFailure.notSent(preparation?["reason"] as? String ?? "Could not prepare \(provider.name)’s message field.")
            }
            guard let messages = preparation?["messages"], let paths = preparation?["existingConversationPaths"] as? [String] else {
                throw WebSessionFailure.notSent("Could not establish the conversation before sending.")
            }
            let baseline = try JSONDecoder().decode([WebPageMessage].self, from: JSONSerialization.data(withJSONObject: messages))
            let existingPaths = Set(paths)
            attempt.receiptContext = WebReceiptContext(originalURL: url, baseline: baseline, existingPaths: existingPaths)
            receiptGenerations[attempt.id] = WebReceiptGeneration(page: currentPage(), generation: generation)
            let preparedDraft = preparation?["preparedDraft"] as? String ?? text
            if provider == .muse { try await Task.sleep(for: .milliseconds(150)) }
            else { try await waitForSendControl(preparedDraft, expectedURL: expectedURL, generation: generation) }
            guard generation == navigationGeneration, !loading else { throw WebSessionFailure.notSent("\(provider.name) navigated before submission. Review its draft.") }
            attempt.status = .attempting
            try store(attempt) // The possible external side effect is durably recorded first.
            submissionWasPossible = true
            let result = try await webView.callAsyncJavaScript(script.clickSend, arguments: ["text": text, "preparedDraft": preparedDraft, "expectedURL": expectedURL], in: nil, contentWorld: .defaultClient) as? [String: Any]
            if result?["clicked"] as? Bool == false {
                submissionWasPossible = false
                throw WebSessionFailure.notSent(result?["reason"] as? String ?? "\(provider.name)’s Send control was not clicked.")
            }
            guard result?["clicked"] as? Bool == true else { throw WebSessionFailure.unconfirmed }
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(250))
                await refresh()
                let previous = attempt
                if observeReceipt(&attempt) { try store(attempt); return attempt }
                if attempt.receiptContext == nil { break }
                if attempt != previous { try store(attempt) } // Retain the safely assigned URL while markup is delayed.
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
        if attempt.status == .notSent {
            attempt.manualContext = attempt.receiptContext
            if provider.sharesOneConversation, attempt.manualContext != nil, let page = receiptGenerations[attempt.id] {
                manualRecoveryScopes[attempt.id] = (comparisonGeneration, page)
            }
            attempt.recoveryConversationURL = nil
            attempt.receiptContext = nil
            receiptGenerations.removeValue(forKey: attempt.id)
        }
        do { try store(attempt) } catch { self.error = "Could not save the send result. Check \(provider.name) before retrying." }
        return attempt
    }

    private func observeReceipt(_ attempt: inout WebSendAttempt) -> Bool {
        observeReceipt(&attempt, in: currentPage())
    }

    private func observeReceipt(_ attempt: inout WebSendAttempt, in page: WebConversationPage) -> Bool {
        let snapshot = page.snapshot
        guard var context = attempt.receiptContext else { return false }
        func invalidate() -> Bool {
            attempt.recoveryConversationURL = attempt.pinnedConversationURL
            attempt.receiptContext = nil
            receiptGenerations.removeValue(forKey: attempt.id)
            return false
        }
        guard snapshot.submissionInterrupted != true, let current = URL(string: snapshot.url) else { return invalidate() }
        // Across reloads/restarts only the already pinned candidate can be recovered.
        let pinned = attempt.pinnedConversationURL
        guard receiptGenerations[attempt.id]?.matches(page) == true || pinned != nil else { return invalidate() }
        if !provider.sharesOneConversation, context.originalURL == provider.newChatURL, current == context.originalURL { return false }
        guard provider.acceptsReceipt(from: context.originalURL, at: current), let url = provider.canonicalConversationURL(current),
              pinned == nil || pinned == url,
              current.path == context.originalURL.path || (!context.existingPaths.contains(current.path) && !state.conversationURLs.values.contains(where: { provider.canonicalConversationURL($0) == url })),
              snapshot.messages.starts(with: context.baseline) else { return invalidate() }
        context.candidateURL = url
        attempt.recoveryConversationURL = url
        attempt.receiptContext = context
        let before = Set(context.baseline.map(\.id))
        let text = Self.normalized(attempt.text)
        let claimed = claimedMessageIDs(excluding: attempt)
        let matches = snapshot.messages.filter { !before.contains($0.id) && !claimed.contains($0.id) && $0.role == "user" && Self.normalized($0.text) == text }
        guard matches.count <= 1 else { return invalidate() }
        guard let match = matches.first, let comparison = attempt.comparisonID else { return false }
        attempt.status = .observed
        attempt.messageID = match.id
        attempt.conversationURL = url
        attempt.recoveryConversationURL = nil
        attempt.receiptContext = nil
        attempt.detail = "The outgoing message appeared in \(provider.name). This is a page observation, not a server delivery receipt."
        state.conversationURLs[comparison.uuidString] = url
        receiptGenerations.removeValue(forKey: attempt.id)
        return true
    }

    private func reconcileUnconfirmedReceipt() { reconcileUnconfirmedReceipt(in: currentPage()) }
    private func reconcileManualSubmission(in page: WebConversationPage) {
        guard !isSending, !storageFailed, let comparison = page.comparisonID,
              var attempt = state.attempts.first(where: { $0.comparisonID == comparison && $0.status == .notSent && $0.manualContext != nil }),
              canAutomaticallyRecoverManual(attempt, in: page),
              let context = attempt.manualContext, let current = page.view.url,
              let url = provider.canonicalConversationURL(current),
              URL(string: page.snapshot.url).flatMap(provider.canonicalConversationURL) == url,
              page.snapshot.draftAvailable == true, page.snapshot.signedIn != false,
              page.snapshot.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              provider.acceptsReceipt(from: context.originalURL, at: current),
              state.conversationURLs[page.key] == nil || state.conversationURLs[page.key] == url,
              (provider == .dots || provider.sharesOneConversation || !state.conversationURLs.contains(where: { $0.key != page.key && provider.canonicalConversationURL($0.value) == url })),
              current.path == context.originalURL.path || !context.existingPaths.contains(current.path),
              page.snapshot.messages.starts(with: context.baseline) else { return }
        let previous = Set(context.baseline.map(\.id))
        let expectedText = Self.normalized(attempt.text)
        let claimed = claimedMessageIDs(excluding: attempt)
        let matches = page.snapshot.messages.filter { !previous.contains($0.id) && !claimed.contains($0.id) && $0.role == "user" && Self.normalized($0.text) == expectedText }
        guard matches.count == 1 else { return }
        attempt.status = .observed
        attempt.messageID = matches[0].id
        attempt.conversationURL = url
        attempt.manualContext = nil
        manualRecoveryScopes.removeValue(forKey: attempt.id)
        attempt.detail = "The request appeared after using the page directly. MsgBlast did not click Send."
        state.conversationURLs[page.key] = url
        do { try store(attempt); page.error = nil; page.readinessError = nil; publish(page) }
        catch { self.error = "Could not save the conversation used in the page. Repair storage before sending." }
    }
    private func reconcileUnconfirmedReceipt(in page: WebConversationPage) {
        guard !isSending, !storageFailed, var attempt = unresolvedWebAttempt(for: page.comparisonID), attempt.receiptContext != nil else { return }
        let previous = attempt
        _ = observeReceipt(&attempt, in: page)
        guard attempt != previous else { return }
        do { try store(attempt); if attempt.status == .observed { page.error = nil; publish(page) } }
        catch { self.error = "Could not save the recovered conversation. Repair storage before sending." }
    }

    public var geminiPreferences: GeminiPreferences {
        state.comparisonID.flatMap { state.geminiComparisonPreferences[$0.uuidString] } ?? state.geminiPreferences
    }
    public var geminiModeLocked: Bool {
        state.comparisonID.flatMap { state.geminiConversations[$0.uuidString]?.firstPrompt } != nil
    }
    public func configureGemini(_ preferences: GeminiPreferences) async {
        guard provider == .geminiApp, provider.isAvailableInBuild, !loading, !isSending, !storageFailed, !shuttingDown else { return }
        guard !geminiModeLocked || preferences.mode == geminiPreferences.mode else { return }
        guard !hasIncompleteNativeRequest(for: state.comparisonID) else { return }
        loading = true; desktopReady = false
        defer { loading = false; updateNativeSnapshot() }
        do {
            try await waitForDesktopRefresh()
            try await prepareGemini(preferences)
            desktopReady = true; desktopStatus = "Gemini ready · \(geminiPreferences.mode.name) · background input"; error = nil
        } catch { self.error = error.localizedDescription; desktopStatus = error.localizedDescription }
    }
    private func prepareGemini(_ desired: GeminiPreferences? = nil) async throws {
        let comparison = state.comparisonID
        let binding = try comparison.flatMap { try state.geminiBinding(for: $0) }
        guard binding != nil || comparison.flatMap({ state.localConversations[$0.uuidString] })?.isEmpty != false else {
            throw WebSessionFailure.notReady("This comparison has Gemini history without a tracked conversation. Start a new comparison; its history was preserved.")
        }
        let requested = desired ?? geminiPreferences
        let result: (GeminiPreferences, GeminiOptions)
        if fixture {
            let models = requested.mode == .chat ? ["3.5 Flash-Lite, Fastest answers", "3.8 Flash, All-around help", "3.1 Pro, Advanced reasoning", "4 Argon, Complex tasks"] : ["3.8 Flash, All-around help", "4 Argon, Complex tasks"]
            var selected = requested
            selected.model = selected.model ?? models[0]
            let levels = requested.mode == .chat && selected.model == "4 Argon, Complex tasks" ? ["Low, Quick and efficient", "Medium, Balanced depth", "High, Extra thorough"] : []
            selected.thinking = levels.isEmpty ? nil : selected.thinking ?? levels[0]
            result = (selected, .init(models: models, thinkingLevels: levels))
        } else {
            do { result = try await geminiApp.prepare(binding: binding, preferences: requested) }
            catch let problem as GeminiSelectionError {
                guard state.comparisonID == comparison else { throw CancellationError() }
                geminiOptions = problem.options
                geminiConfigurationError = problem.localizedDescription
                throw problem
            }
        }
        guard state.comparisonID == comparison, !shuttingDown else { throw CancellationError() }
        if let comparison { state.geminiComparisonPreferences[comparison.uuidString] = result.0 }
        else { state.geminiPreferences = result.0 }
        geminiOptions = result.1
        geminiConfigurationError = nil
        try save()
    }
    private func recordGeminiSubmission(_ binding: GeminiConversationBinding) throws {
        try state.recordGeminiBinding(binding)
        try save()
    }

    public var desktopConnectionConfirmation: String? {
        guard isReadyForOnboarding, desktopReady, let app = provider.desktopApp, let binding = state.desktopConversation else { return nil }
        if app == .dots { return "Your comparisons continue your existing dot in the ChatGPT Mac app. This check didn’t send a message." }
        if app == .chatgpt || app == .claude { return "Each comparison gets its own \(app.name) chat. msgblast opens the installed app when a conversation starts. This check didn’t send a message." }
        if app == .gemini { return "Each comparison gets its own Gemini conversation. Choose Chat or Task, model, and available thinking level here. This check didn’t send a message." }
        if app == .wabi { return "Your first prompt in a new comparison starts a dedicated AI chat in Wabi. Follow-ups stay in that chat. This check didn’t send a message." }
        if app == .grokBot { return "Messages go to “\(binding.name)” in Grok Bot, using that bot’s existing chat. No message was sent." }
        return app == .muse
            ? "Your first prompt in a new comparison starts a new side chat in Muse. This check didn’t send a message."
            : "Your prompts will go to “\(binding.name)” in \(app.name). Comparisons share that conversation. This check didn’t send a message."
    }

    public func refreshGrokBots(activateIfNeeded: Bool = false) async {
        guard provider == .grokBotApp, !loading, !isSending, !shuttingDown, !storageFailed else { return }
        refreshDesktopInstallation()
        guard desktopInstallation.isRunning else { grokBotNames = []; return }
        loading = true
        defer { loading = false; updateNativeSnapshot() }
        // A restart can invalidate discovery while the saved bot is checked.
        // Re-read the new process once; never restore its predecessor's list.
        for _ in 0..<2 {
            refreshDesktopInstallation()
            guard desktopInstallation.isRunning, !shuttingDown, !Task.isCancelled else { return }
            let installation = desktopInstallation
            desktopReady = false
            desktopStatus = "Finding your bots…"
            updateNativeSnapshot()
            do {
                try await waitForDesktopRefresh()
                let names = fixture ? ["Demo Bot", "Research Bot", "Writing Bot"] : try await DesktopAppWorkflow.connection(.grokBot, driver: activateIfNeeded ? desktopDriver : nil) {
                    try await self.desktopDriver.availableGrokBots()
                }
                refreshDesktopInstallation()
                guard desktopInstallation == installation else { continue }
                guard !shuttingDown, !Task.isCancelled else { return }
                grokBotNames = names
                desktopStatus = "Choose a bot to start chatting."
                if let name = state.desktopConversation?.name, grokBotNames.contains(name), isEnabled {
                    connected = true
                    await refreshDesktop(duringConnection: true)
                }
                refreshDesktopInstallation()
                guard desktopInstallation == installation else { continue }
                return
            } catch {
                refreshDesktopInstallation()
                if desktopInstallation != installation, !shuttingDown, !Task.isCancelled { continue }
                grokBotNames = []
                desktopReady = false
                desktopStatus = error.localizedDescription
                return
            }
        }
        grokBotNames = []
        desktopReady = false
        desktopStatus = "Grok Bot changed while connecting. Try connecting again."
    }

    private func waitForDesktopRefresh() async throws {
        while refreshing && !shuttingDown { try await Task.sleep(for: .milliseconds(20)) }
        try Task.checkCancellation()
        guard !shuttingDown else { throw CancellationError() }
    }

    public func refreshDesktopInstallation() {
        guard let app = provider.desktopApp else { return }
        let fresh = desktopApps.inspect(app)
        let changed = fresh != desktopInstallation
        if changed { desktopReady = false; grokBotNames = [] }
        desktopInstallation = fresh
        if !fresh.isInstalled { desktopStatus = "Install \(app.name) on this Mac to connect." }
        else if !fresh.isRunning { desktopStatus = app == .grokBot ? "Open Grok Bot and sign in to choose your bot." : "Open \(app.name) and sign in, then check the connection." }
        else if !desktopReady && (changed || desktopStatus.isEmpty) { desktopStatus = "Check the connection to get ready for your first prompt." }
        updateNativeSnapshot()
    }

    public func openDesktopApp() async {
        guard provider.desktopApp != nil, !loading, !isSending else { return }
        refreshDesktopInstallation()
        guard let url = desktopInstallation.url else { return }
        loading = true
        defer { loading = false }
        do { try await desktopApps.open(url); refreshDesktopInstallation() }
        catch { desktopStatus = error.localizedDescription; self.error = error.localizedDescription }
    }

    /// An explicit Connect may reopen a closed window; passive refreshes never do.
    public func prepareDesktopConnection() async -> Bool {
        do {
            try await launchDesktopAppForConversation()
            return true
        } catch is CancellationError { return false }
        catch {
            desktopReady = false
            desktopStatus = error.localizedDescription
            self.error = error.localizedDescription
            updateNativeSnapshot()
            return false
        }
    }

    private func launchDesktopAppForConversation() async throws {
        guard let app = provider.desktopApp else { return }
        try Task.checkCancellation()
        guard isEnabled, !storageFailed, !shuttingDown else { throw CancellationError() }
        guard !loading else { throw WebSessionFailure.notReady("Wait for the app connection check to finish before starting a conversation.") }
        refreshDesktopInstallation()
        if desktopInstallation.isRunning, fixture, !desktopApps.isHidden(app) { return }
        guard let url = desktopInstallation.url else { throw WebSessionFailure.notReady(desktopStatus) }
        let generation = comparisonGeneration
        func checkCurrent() throws {
            try Task.checkCancellation()
            guard !shuttingDown, isEnabled, comparisonGeneration == generation else { throw CancellationError() }
        }
        loading = true
        desktopStatus = "Opening \(app.name)…"
        updateNativeSnapshot()
        defer { loading = false }
        do {
            if desktopInstallation.isRunning, !desktopApps.isHidden(app) {
                do {
                    _ = try await desktopDriver.target(app)
                    try checkCurrent()
                    return
                } catch is CancellationError { throw CancellationError() }
                catch { try checkCurrent() }
            }
            try await desktopApps.open(url)
            try checkCurrent()
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            repeat {
                refreshDesktopInstallation()
                if desktopInstallation.isRunning {
                    if fixture { return }
                    do {
                        _ = try await desktopDriver.target(app)
                        try checkCurrent()
                        return
                    } catch is CancellationError { throw CancellationError() }
                    catch { /* Window creation may lag behind the process launch. */ }
                }
                try checkCurrent()
                guard ContinuousClock.now < deadline else { break }
                try await Task.sleep(for: .milliseconds(200))
            } while true
            throw WebSessionFailure.notReady("\(app.name) opened, but its main window is not ready. Finish signing in or dismiss any dialogs, then try again.")
        } catch {
            try checkCurrent()
            desktopStatus = error.localizedDescription
            updateNativeSnapshot()
            throw error
        }
    }

    private func recordClaudeSubmission(_ binding: ClaudeConversationBinding, attemptID: UUID? = nil) throws {
        let index = attemptID.flatMap { id in state.attempts.firstIndex(where: { $0.id == id && $0.comparisonID == binding.comparisonID }) }
        guard attemptID == nil || index != nil else { throw WebSessionFailure.notSent("Claude's chat identity could not be saved.") }
        try state.recordClaudeBinding(binding)
        if let index { state.attempts[index].conversationURL = binding.url }
        try save()
    }
    private func recordChatGPTSubmission(_ binding: ChatGPTConversationBinding) throws {
        try state.recordChatGPTBinding(binding)
        try save()
    }
    private func prepareAdditionalDesktopConversation(foreground: Bool = false) async {
        guard provider == .claudeApp || chatgptKind != nil, let comparison = state.comparisonID,
              !loading, !shuttingDown else { return }
        let generation = comparisonGeneration
        loading = true
        defer { loading = false }
        do {
            if provider == .claudeApp {
                let saved = try state.claudeBinding(for: comparison)
                let prepared = fixture ? saved ?? .init(comparisonID: comparison) : try await DesktopAppWorkflow.preparation(.claude, driver: foreground ? desktopDriver : nil) {
                    try await claudeApp.prepare(comparisonID: comparison, binding: saved)
                }
                guard !shuttingDown, comparisonGeneration == generation else { throw CancellationError() }
                try recordClaudeSubmission(prepared)
            } else if let kind = chatgptKind {
                let saved = try state.chatgptBinding(for: comparison, kind: kind)
                let prepared = fixture ? saved ?? .init(comparisonID: comparison, kind: kind) : try await DesktopAppWorkflow.preparation(kind == .dots ? .dots : .chatgpt, driver: foreground ? desktopDriver : nil) {
                    try await chatgptApp.prepare(comparisonID: comparison, kind: kind, binding: saved)
                }
                guard !shuttingDown, comparisonGeneration == generation else { throw CancellationError() }
                try recordChatGPTSubmission(prepared)
            }
        } catch {
            desktopReady = false
            desktopStatus = error.localizedDescription
            self.error = error.localizedDescription
        }
        updateNativeSnapshot()
    }

    public func connectDesktopConversation(botName: String? = nil) async {
        guard let app = provider.desktopApp, !isSending, !storageFailed, !loading, !shuttingDown else { return }
        refreshDesktopInstallation()
        guard isEnabled, desktopInstallation.isRunning else { return }
        if app == .grokBot, hasIncompleteNativeRequest(for: state.comparisonID) {
            desktopReady = false
            desktopStatus = "Review the previous incomplete request before changing bots."
            updateNativeSnapshot()
            return
        }
        if app == .grokBot, botName == nil {
            desktopStatus = "Choose your bot in msgblast."
            return
        }
        let installation = desktopInstallation
        desktopReady = false
        desktopStatus = "Checking \(app.name)'s conversation…"
        loading = true
        updateNativeSnapshot()
        defer { loading = false }
        do {
            try await waitForDesktopRefresh()
            guard isEnabled else { throw CancellationError() }
            let binding = try await DesktopAppWorkflow.connection(app, driver: fixture ? nil : desktopDriver) { () async throws -> DesktopConversationBinding in
                if app == .muse {
                    if !fixture { try await museApp.checkAvailable() }
                    return DesktopConversationBinding(name: "Muse")
                } else if app == .claude {
                    if !fixture { try await claudeApp.checkAvailable() }
                    return .init(name: "Claude")
                } else if let kind = chatgptKind {
                    if !fixture { try await chatgptApp.checkAvailable(kind: kind) }
                    return .init(name: app.name)
                } else if app == .gemini {
                    if !fixture { try await geminiApp.checkAvailable() }
                    return .init(name: "Gemini")
                } else if app == .wabi {
                    if !fixture { try await wabiApp.checkAvailable() }
                    return DesktopConversationBinding(name: "Wabi")
                } else if let botName {
                    if fixture {
                        guard grokBotNames.contains(botName) else { throw DesktopAppError.unavailable("Refresh the bots and choose your bot again.") }
                        return .init(name: botName)
                    } else { return try await desktopDriver.connectGrokBot(named: botName) }
                } else { throw DesktopAppError.unavailable("Choose your bot in msgblast.") }
            }
            refreshDesktopInstallation()
            guard isEnabled, !shuttingDown else { throw CancellationError() }
            guard desktopInstallation == installation else { throw DesktopAppError.unavailable("\(app.name) changed while checking. Check the connection again.") }
            state.desktopConversation = binding
            try save()
            connected = true
            desktopReady = true
            desktopStatus = "Connected to \(binding.name)"
            error = nil
        } catch { desktopReady = false; desktopStatus = error.localizedDescription; self.error = error.localizedDescription }
        updateNativeSnapshot()
    }

    private func refreshDesktop(duringConnection: Bool = false) async {
        guard let app = provider.desktopApp, provider.isAvailableInBuild, (!loading || duringConnection), !refreshing, !shuttingDown else { return }
        refreshing = true
        let generation = comparisonGeneration
        defer { refreshing = false }
        refreshDesktopInstallation()
        desktopReady = false
        guard desktopInstallation.isRunning else { updateNativeSnapshot(); return }
        if let binding = state.desktopConversation {
            do {
                if app == .claude || chatgptKind != nil {
                    guard !hasIncompleteNativeRequest(for: state.comparisonID) else { throw WebSessionFailure.notReady("Review the previous native app request before continuing.") }
                    if let comparison = state.comparisonID {
                        if app == .claude {
                            let saved = try state.claudeBinding(for: comparison)
                            guard saved?.firstPrompt == nil || saved?.url != nil else { throw WebSessionFailure.notReady("Claude’s first submission was interrupted. Review it before starting a new comparison.") }
                            guard saved != nil || state.localConversations[comparison.uuidString]?.isEmpty != false else { throw WebSessionFailure.notReady("Claude’s history has no tracked native chat. Start a new comparison; its history was preserved.") }
                        } else if let kind = chatgptKind {
                            let saved = try state.chatgptBinding(for: comparison, kind: kind)
                            guard saved?.firstPrompt == nil || saved?.title != nil else { throw WebSessionFailure.notReady("The first native ChatGPT submission was interrupted. Review it before starting a new comparison.") }
                            guard saved != nil || state.localConversations[comparison.uuidString]?.isEmpty != false else { throw WebSessionFailure.notReady("This history has no tracked native chat. Start a new comparison; its history was preserved.") }
                        }
                    }
                    if !fixture {
                        if app == .claude { try await claudeApp.checkAvailable() }
                        else if let kind = chatgptKind { try await chatgptApp.checkAvailable(kind: kind) }
                    }
                    guard generation == comparisonGeneration, !shuttingDown else { return }
                    desktopReady = true
                    desktopStatus = app == .dots ? "Your continuing dot is ready · background input" : "\(app.name) ready · dedicated chat · background input"
                    updateNativeSnapshot()
                    return
                }
                if app == .gemini {
                    if let geminiConfigurationError { throw WebSessionFailure.notReady(geminiConfigurationError) }
                    guard !hasIncompleteNativeRequest(for: state.comparisonID) else { throw WebSessionFailure.notReady("Review the previous Gemini request before navigating.") }
                    if let comparison = state.comparisonID {
                        let saved = try state.geminiBinding(for: comparison)
                        guard saved?.firstPrompt == nil || saved?.title != nil else { throw WebSessionFailure.notReady("Gemini’s first submission was interrupted. Review it before starting a new comparison.") }
                        guard saved != nil || state.localConversations[comparison.uuidString]?.isEmpty != false else { throw WebSessionFailure.notReady("Gemini’s saved history has no tracked conversation. Start a new comparison; its history was preserved.") }
                    }
                    if !fixture { try await geminiApp.checkAvailable(binding: try state.comparisonID.flatMap { try state.geminiBinding(for: $0) }) }
                    guard generation == comparisonGeneration, !shuttingDown else { return }
                    desktopReady = true
                    desktopStatus = "Gemini ready · \(geminiPreferences.mode.name) · background input"
                    updateNativeSnapshot()
                    return
                }
                if app == .wabi {
                    guard !hasIncompleteNativeRequest(for: state.comparisonID) else { throw WebSessionFailure.notReady("Review the previous incomplete Wabi request before navigating to another chat.") }
                    if let comparison = state.comparisonID {
                        let saved = try state.wabiConversation(for: comparison)
                        guard saved != nil || state.localConversations[comparison.uuidString]?.isEmpty != false else {
                            throw WebSessionFailure.notReady("This comparison has Wabi history without a tracked dedicated chat. Its history was preserved; start a new comparison.")
                        }
                        if isSending || desktopDriver.delivery == .background {
                            let url: URL
                            if fixture { url = saved ?? URL(string: "wabi://app/threads/\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24))")! }
                            else {
                                let refreshNavigation: (@Sendable (DesktopAppConversation.Target, String) async throws -> Void)?
                                if isSending && desktopDriver.delivery == .foreground {
                                    let driver = desktopDriver
                                    refreshNavigation = { target, session in try await driver.activate(target, session: session) }
                                } else { refreshNavigation = nil }
                                url = try await wabiApp.prepare(savedURL: saved, refreshNavigation: refreshNavigation)
                            }
                            guard generation == comparisonGeneration, state.comparisonID == comparison, !shuttingDown else { throw CancellationError() }
                            try state.recordWabiConversation(url, for: comparison)
                            try save()
                        } else if !fixture { try await wabiApp.checkAvailable() }
                    } else if !fixture { try await wabiApp.checkAvailable() }
                    guard generation == comparisonGeneration, !shuttingDown else { return }
                    desktopReady = true
                    desktopStatus = state.comparisonID == nil ? "Connected to Wabi · each comparison gets its own AI chat" : "Dedicated Wabi chat ready"
                    updateNativeSnapshot()
                    return
                }
                if app == .muse {
                    guard !hasIncompleteNativeRequest(for: state.comparisonID) else { throw WebSessionFailure.notReady("Review the previous incomplete Muse request before navigating to another side chat.") }
                    let comparison = state.comparisonID
                    if let comparison {
                        let saved = try state.museAppBinding(for: comparison)
                        guard saved != nil || state.localConversations[comparison.uuidString]?.isEmpty != false else {
                            throw WebSessionFailure.notReady("This comparison has Muse history without a tracked side chat. Its history was preserved; no replacement chat was created.")
                        }
                        if isSending || desktopDriver.delivery == .background {
                            let pending = state.attempts.first { $0.comparisonID == comparison && $0.recoveryConversationURL != nil }
                            let prepared: MuseSideChatBinding
                            if fixture { prepared = saved ?? MuseSideChatBinding(comparisonID: comparison, threadID: nil, title: "Simulated side chat") }
                            else if saved?.threadID == nil, let pending, let candidate = pending.recoveryConversationURL {
                                prepared = try await museApp.recover(comparisonID: comparison, candidateURL: candidate, prompt: pending.text, requestID: pending.id)
                            } else { prepared = try await museApp.prepare(comparisonID: comparison, binding: saved) }
                            guard generation == comparisonGeneration, state.comparisonID == comparison, !shuttingDown else { throw CancellationError() }
                            try state.recordMuseAppBinding(prepared)
                            if prepared.threadID != nil, saved?.threadID == nil, let pending {
                                try recordMuseAppSubmission(prepared, attemptID: pending.id)
                            } else { try save() }
                        } else {
                            if !fixture { try await museApp.checkAvailable() }
                            guard generation == comparisonGeneration, state.comparisonID == comparison, !shuttingDown else { throw CancellationError() }
                            if saved == nil {
                                try state.recordMuseAppBinding(.init(comparisonID: comparison, threadID: nil, title: "New side chat"))
                                try save()
                            }
                        }
                    } else if !fixture { try await museApp.checkAvailable() }
                    guard generation == comparisonGeneration, !shuttingDown else { return }
                    desktopReady = true
                    desktopStatus = comparison == nil ? "Connected to Muse · each comparison gets its own side chat" : "Muse side chat ready"
                    updateNativeSnapshot()
                    return
                }
                guard !hasIncompleteNativeRequest(for: state.comparisonID) else { throw WebSessionFailure.notReady("Review the previous incomplete request before changing bots.") }
                if !fixture { try await desktopDriver.checkGrokBot(named: binding.name) }
                guard generation == comparisonGeneration, !shuttingDown else { return }
                desktopReady = true
                desktopStatus = "Connected to \(binding.name)"
            } catch {
                guard generation == comparisonGeneration, !shuttingDown else { return }
                desktopStatus = error.localizedDescription
            }
        } else { desktopStatus = app == .grokBot ? "Choose your bot in msgblast." : "Open the intended conversation in \(app.name), then connect it here." }
        updateNativeSnapshot()
    }

    private func updateNativeSnapshot() {
        var fresh = snapshot
        fresh.messages = state.comparisonID.flatMap { state.localConversations[$0.uuidString] } ?? []
        fresh.draft = state.draft
        if provider.desktopApp != nil {
            if provider == .museApp { fresh.url = state.comparisonID.flatMap { state.museAppConversations[$0.uuidString]?.url?.absoluteString } ?? "" }
            if provider == .wabi { fresh.url = state.comparisonID.flatMap { state.conversationURLs[$0.uuidString]?.absoluteString } ?? "" }
            fresh.ready = isEnabled && !storageFailed && desktopInstallation.isRunning && desktopReady && !hasIncompleteNativeRequest(for: state.comparisonID)
            fresh.reason = !isEnabled ? "Enable \(provider.name) to send." : hasIncompleteNativeRequest(for: state.comparisonID) ? "Review the previous incomplete request before continuing." : desktopStatus
            if fresh != snapshot { snapshot = fresh }
            return
        }
        if provider == .grokbot {
            fresh.ready = isEnabled && !storageFailed && !configuringGrokBot && (fixture || (grokBotConnectionReady == true && grokBotCredentials != nil)) && !hasIncompleteNativeRequest(for: state.comparisonID)
            fresh.reason = !isEnabled ? "Enable Grok Bot in Settings to send." : hasIncompleteNativeRequest(for: state.comparisonID) ? "Waiting for the previous request. No automatic resend." : grokBotConnectionActivity?.title ?? (fresh.ready ? "Grok Bot ready" : "Connect Grok Bot's webhook in Settings.")
            if fresh != snapshot { snapshot = fresh }
            return
        }
        fresh.ready = isEnabled && !storageFailed && (fixture || (installedAgent != nil && [.subscription, .apiKey, .other].contains(accountStatus)))
        fresh.reason = !isEnabled ? "Enable \(provider.name) in Settings to send." : installedAgent == nil && !fixture ? "Install \(provider.personalAgentProvider!.name), then sign in with your local account." : accountStatus.label
        if fresh != snapshot { snapshot = fresh }
    }

    public var incompleteDesktopAttempt: WebSendAttempt? {
        guard provider.desktopApp != nil else { return nil }
        return state.attempts.first { $0.status.isUnresolved }
    }

    public func acknowledgeIncompleteRequest(attemptID: UUID? = nil) {
        guard provider.usesNativeConversation, !isSending else { return }
        let dismissedDetails = state.attempts.filter { attempt in
            (attemptID.map { attempt.id == $0 } ?? (attempt.comparisonID == state.comparisonID)) && [.waiting, .uncertain].contains(attempt.status)
        }.compactMap(\.detail)
        updateState { state in
            for i in state.attempts.indices where (attemptID.map { state.attempts[i].id == $0 } ?? (state.attempts[i].comparisonID == state.comparisonID)) && [.waiting, .uncertain].contains(state.attempts[i].status) {
                state.attempts[i].status = .dismissed
            }
        }
        if !storageFailed, let error, dismissedDetails.contains(error) { self.error = nil }
    }

    public func hasUnresolvedSend(_ text: String) -> Bool {
        if provider.desktopApp != nil { return hasIncompleteNativeRequest(for: state.comparisonID) }
        if provider.sharesOneConversation {
            return state.attempts.contains { $0.status.isUnresolved && Self.normalized($0.text) == Self.normalized(text) }
        }
        if !provider.usesNativeConversation { return state.hasUnresolvedSend(text) }
        return hasIncompleteNativeRequest(for: state.comparisonID)
    }
    private func hasIncompleteNativeRequest(for id: UUID?) -> Bool {
        state.attempts.contains { (provider.desktopApp != nil || $0.comparisonID == id) && $0.status.isUnresolved }
    }

    public func cancelNativeRequest() {
        if !shuttingDown { nativeCancellationRequestedBeforeShutdown = true }
        requestCancelled = true
        nativeRequest?.cancel()
    }
    public func beginShutdown() { shuttingDown = true; poll?.cancel(); stopNativeRecovery(); cancelNativeRequest(); stopGrokBotConnection() }
    public func cancelAndWait() async {
        if !shuttingDown { try? await saveBrowserDrafts() }
        beginShutdown()
        while provider.usesNativeConversation && isSending { try? await Task.sleep(for: .milliseconds(20)) }
    }

    func conversationWorkingDirectory(_ id: UUID) -> URL {
        storageURL.deletingLastPathComponent().appendingPathComponent("local-conversations/\(provider.localConversationDirectoryName)/\(id.uuidString)", isDirectory: true)
    }

    private func sendNative(_ text: String, comparisonID: UUID?, onSubmissionFinished: @escaping @MainActor @Sendable () -> Void, onConfirmedSubmission: @escaping @MainActor @Sendable () -> Void, plannedAttemptID: UUID?, consumePrivateDraft: Bool) async -> WebSendAttempt? {
        guard isEnabled, !shuttingDown, !isSending, !storageFailed, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard provider.desktopApp == nil || !loading else { error = "Wait for the app connection check to finish before sending."; return nil }
        let id = comparisonID ?? state.comparisonID ?? UUID()
        let planned: WebSendAttempt?
        if let plannedAttemptID {
            guard provider.desktopApp != nil, state.comparisonID == id,
                  let existing = state.attempts.first(where: { $0.id == plannedAttemptID }),
                  existing.status == .preparing, existing.comparisonID == id, existing.text == text else { return nil }
            planned = existing
        } else { planned = nil }
        guard !hasIncompleteNativeRequest(for: id) else {
            error = "An earlier request did not complete. Review it before explicitly allowing another request; usage may have been consumed."
            return nil
        }
        // Capture the identity of the draft before opening an app, which may
        // suspend while the user edits or changes comparisons.
        var submittedDraftRevision: UUID?
        if consumePrivateDraft, state.draft == text, state.comparisonID == id || (state.comparisonID == nil && comparisonID == nil) {
            let key = state.comparisonID?.uuidString ?? "new"
            let previous = state
            let revision = state.localDraftRevisions[key] ?? UUID()
            state.localDraftRevisions[key] = revision
            state.localDrafts[key] = state.draft
            do { try save(); submittedDraftRevision = revision }
            catch { state = previous; self.error = error.localizedDescription; return nil }
        }
        isSending = true
        requestCancelled = false
        nativeCancellationRequestedBeforeShutdown = false
        defer { nativeRequest = nil; isSending = false; startNativeRecoveryIfNeeded() }
        error = nil
        if provider.desktopApp != nil {
            do {
                try await launchDesktopAppForConversation()
                guard !requestCancelled else { throw CancellationError() }
            } catch is CancellationError { return nil }
            catch { self.error = error.localizedDescription; return nil }
        }
        if let plannedAttemptID {
            guard !requestCancelled, !shuttingDown, state.comparisonID == id,
                  let current = state.attempts.first(where: { $0.id == plannedAttemptID }),
                  current.status == .preparing, current.comparisonID == id, current.text == text else { return nil }
        }
        var attempt = planned ?? WebSendAttempt(text: text)
        attempt.comparisonID = id
        attempt.nativeDraftRevision = submittedDraftRevision
        updateState { $0.comparisonID = id }
        if let plannedAttemptID, let index = state.attempts.firstIndex(where: { $0.id == plannedAttemptID }) {
            state.attempts[index] = attempt
        } else { state.attempts.insert(attempt, at: 0) }
        var started = false
        var foreground: DesktopForegroundLease?
        do {
            try save()
            if !fixture, let app = provider.desktopApp, app.requiresForegroundSubmission {
                foreground = try await desktopDriver.beginForeground(app, session: "msgblast-foreground-\(attempt.id)", onRestored: { await onSubmissionFinished() })
            }
            connected = true
            await refresh()
            guard !shuttingDown, !requestCancelled else { throw CancellationError() }
            guard snapshot.ready else { throw WebSessionFailure.notSent(snapshot.reason) }
            guard !consumePrivateDraft || snapshot.draft.isEmpty || snapshot.draft == text else {
                throw WebSessionFailure.notSent("\(provider.name) has a draft. Send or clear it before continuing.")
            }
            let user = WebPageMessage(id: attempt.id.uuidString, role: "user", text: text)
            let history = (state.localConversations[id.uuidString] ?? []) + [user]
            attempt.status = .attempting
            let wabiURL = provider == .wabi ? try state.wabiConversation(for: id) : nil
            if provider == .wabi { attempt.conversationURL = wabiURL }
            try store(attempt)
            started = true
            let savedSessionID = state.resumableLocalSessionID(for: id)
            let workingDirectory = conversationWorkingDirectory(id)
            let binding = state.desktopConversation
            let museBinding = provider == .museApp ? try state.museAppBinding(for: id) : nil
            var geminiBinding: GeminiConversationBinding?
            let geminiPreferences = self.geminiPreferences
            let claudeBinding = provider == .claudeApp ? try state.claudeBinding(for: id) ?? ClaudeConversationBinding(comparisonID: id) : nil
            let nativeKind = chatgptKind
            let chatgptBinding = try nativeKind.map { try state.chatgptBinding(for: id, kind: $0) ?? ChatGPTConversationBinding(comparisonID: id, kind: $0) }
            if provider == .geminiApp {
                geminiBinding = try state.geminiBinding(for: id) ?? GeminiConversationBinding(comparisonID: id, mode: geminiPreferences.mode)
            }
            let sendFocus = foreground
            let submitAction: @Sendable () async -> Void = { await sendFocus?.restoreAfterSubmission() }
            let outgoingID = attempt.id
            let submitted: @Sendable () async throws -> Void = { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.recordDesktopSubmission(attemptID: outgoingID)
                await onConfirmedSubmission()
            }
            let request = Task { [fixture, provider, installedAgent, museApp, wabiApp, desktopDriver, geminiApp, claudeApp, chatgptApp] in
                if fixture {
                    try await Task.sleep(for: .milliseconds(350))
                    if var saved = claudeBinding {
                        saved.firstPrompt = saved.firstPrompt ?? saved.firstMessage(text)
                        saved.url = saved.url ?? URL(string: "https://claude.ai/chat/\(UUID().uuidString.lowercased())")!
                        try self.recordClaudeSubmission(saved)
                    }
                    if var saved = chatgptBinding {
                        saved.firstPrompt = saved.firstPrompt ?? saved.firstMessage(text)
                        saved.title = saved.title ?? (saved.kind == .dots ? "Simulated dot" : saved.dedicatedTitle)
                        try self.recordChatGPTSubmission(saved)
                    }
                    if provider == .museApp {
                        let simulated = MuseSideChatBinding(comparisonID: id, threadID: museBinding?.threadID ?? UUID(), title: "Simulated side chat")
                        try self.recordMuseAppSubmission(simulated, attemptID: attempt.id)
                    }
                    if provider == .geminiApp, var saved = geminiBinding {
                        saved.firstPrompt = saved.firstPrompt ?? saved.firstMessage(text)
                        saved.title = saved.dedicatedTitle
                        try self.recordGeminiSubmission(saved)
                    }
                    return PersonalAgentReply(text: "\(provider.name) fixture reply: \(text)", sessionID: savedSessionID ?? UUID().uuidString)
                }
                let refreshInput: (@Sendable (DesktopAppConversation.Target, String) async throws -> Void)?
                if sendFocus != nil {
                    refreshInput = { target, session in try await desktopDriver.activate(target, session: session) }
                } else { refreshInput = nil }
                if provider == .museApp {
                    guard let museBinding else { throw WebSessionFailure.notSent("Prepare this comparison's Muse side chat first.") }
                    let attemptID = attempt.id
                    let answer = try await museApp.reply(text, binding: museBinding, requestID: attemptID, onCandidate: { [weak self] url in
                        guard let self else { throw CancellationError() }
                        try await self.recordMuseAppCandidate(url, comparisonID: id, attemptID: attemptID)
                    }, onSubmitAction: submitAction, onSubmitted: submitted, onReceipt: { [weak self] baseline, wirePrompt in
                        guard let self else { throw CancellationError() }
                        let receipt = try MuseReplyReceipt(comparisonID: id, requestID: attemptID, initialThreadID: museBinding.threadID,
                                                           prompt: wirePrompt, baseline: baseline)
                        try await self.recordMuseReceipt(receipt, attemptID: attemptID)
                    }, refreshInput: refreshInput, releaseFocus: { _ = try? await sendFocus?.restore() }, onBinding: { [weak self] discovered in
                        guard let self else { throw CancellationError() }
                        try await self.recordMuseAppSubmission(discovered, attemptID: attemptID)
                    })
                    return PersonalAgentReply(text: answer, sessionID: "Muse side chat")
                }
                if provider == .wabi {
                    guard let wabiURL else { throw WebSessionFailure.notSent("Prepare this comparison's dedicated Wabi chat first.") }
                    return PersonalAgentReply(text: try await wabiApp.reply(text, in: wabiURL, onSubmitAction: submitAction, onSubmitted: submitted, onReceipt: { [weak self] baseline in
                        guard let self else { throw CancellationError() }
                        let receipt = try WabiReplyReceipt(comparisonID: id, url: wabiURL, prompt: text, baseline: baseline)
                        try await self.recordWabiReceipt(receipt, attemptID: outgoingID)
                    }, refreshInput: refreshInput, releaseFocus: { _ = try? await sendFocus?.restore() }), sessionID: "Dedicated Wabi chat")
                }
                if provider == .geminiApp {
                    guard let saved = geminiBinding else { throw WebSessionFailure.notSent("Prepare Gemini first.") }
                    let answer = try await geminiApp.reply(text, binding: saved, preferences: geminiPreferences, onPrepared: { [weak self] prepared in
                        guard let self else { throw CancellationError() }
                        try await self.recordGeminiSubmission(prepared)
                    }) { [weak self] discovered in
                        guard let self else { throw CancellationError() }
                        try await self.recordGeminiSubmission(discovered)
                    }
                    return PersonalAgentReply(text: answer, sessionID: "Dedicated Gemini conversation")
                }
                if let saved = claudeBinding {
                    let answer = try await claudeApp.reply(text, binding: saved, onSubmitAction: submitAction, onPrepared: { [weak self] pending in
                        guard let self else { throw CancellationError() }
                        try await self.recordClaudeSubmission(pending)
                    }, onReceipt: { [weak self] baseline, wirePrompt in
                        guard let self else { throw CancellationError() }
                        let receipt = try ClaudeReplyReceipt(comparisonID: id, initialURL: saved.url, prompt: wirePrompt, baseline: baseline)
                        try await self.recordClaudeReceipt(receipt, attemptID: outgoingID)
                    }, onSubmitted: submitted, onBinding: { [weak self] discovered in
                        guard let self else { throw CancellationError() }
                        try await self.recordClaudeSubmission(discovered, attemptID: outgoingID)
                    })
                    return PersonalAgentReply(text: answer, sessionID: "Dedicated Claude chat")
                }
                if let saved = chatgptBinding {
                    let answer = try await chatgptApp.reply(text, binding: saved, onSubmitAction: submitAction, refreshUnreadReply: { target in
                        try await desktopDriver.beginReplyRefresh(target, session: "msgblast-dot-reply-\(UUID())", host: sendFocus?.host, onRestoreFailure: { [weak self] detail in
                            await MainActor.run { self?.error = detail }
                        })
                    }, onPrepared: { [weak self] pending in
                        guard let self else { throw CancellationError() }
                        try await self.recordChatGPTSubmission(pending)
                    }, onDotsReceipt: { [weak self] receipt in
                        guard let self else { throw CancellationError() }
                        try await self.recordDotsReceipt(receipt, attemptID: outgoingID)
                    }, onChatGPTReceipt: { [weak self] receipt in
                        guard let self else { throw CancellationError() }
                        try await self.recordChatGPTReceipt(receipt, attemptID: outgoingID)
                    }, onSubmitted: submitted, onBinding: { [weak self] discovered in
                        guard let self else { throw CancellationError() }
                        try await self.recordChatGPTSubmission(discovered)
                    })
                    return PersonalAgentReply(text: answer, sessionID: saved.kind == .dots ? "Your continuing dot" : "Dedicated ChatGPT chat")
                }
                if let app = provider.desktopApp {
                    guard let binding else { throw WebSessionFailure.notSent("Connect an app conversation first.") }
                    return PersonalAgentReply(text: try await desktopDriver.reply(text, app: app, binding: binding, onSubmitAction: submitAction, onReceipt: { [weak self] anchor in
                        guard let self else { throw CancellationError() }
                        try await self.recordGrokReceipt(.init(comparisonID: id, bot: binding.name, prompt: text, anchor: anchor), attemptID: outgoingID)
                    }, onSubmitted: submitted, releaseFocus: { _ = try? await sendFocus?.restore() }), sessionID: binding.name)
                }
                guard let installedAgent else { throw PersonalAgentError.unavailable(provider.name) }
                return try await LocalPersonalAgent.reply(to: history, using: installedAgent, sessionID: savedSessionID, workingDirectory: workingDirectory)
            }
            nativeRequest = request
            let answer = try await withTaskCancellationHandler { try await request.value } onCancel: { request.cancel() }
            try Task.checkCancellation()
            state.localConversations[id.uuidString] = history + [WebPageMessage(role: "assistant", text: answer.text)]
            if provider.desktopApp == nil { state.recordLocalSession(answer.sessionID, for: id) }
            consumeNativeDraftIfUnchanged(attempt, comparison: id)
            if provider == .claudeApp { attempt.conversationURL = state.claudeConversations[id.uuidString]?.url }
            if provider == .museApp {
                attempt.conversationURL = state.museAppConversations[id.uuidString]?.url
                attempt.recoveryConversationURL = state.attempts.first { $0.id == attempt.id }?.recoveryConversationURL
            }
            attempt.status = .observed; attempt.messageID = user.id
            attempt.detail = fixture ? "Simulated reply. No app, local CLI or provider was contacted." : provider.desktopApp != nil ? "Reply text observed in the background and stable for three seconds. The app may continue working." : "Completed reply from the local CLI."
            try store(attempt)
        } catch {
            attempt.messageID = state.attempts.first { $0.id == attempt.id }?.messageID ?? attempt.messageID
            attempt.dotsReplyReceipt = state.attempts.first { $0.id == attempt.id }?.dotsReplyReceipt
            attempt.wabiReplyReceipt = state.attempts.first { $0.id == attempt.id }?.wabiReplyReceipt
            attempt.museReplyReceipt = state.attempts.first { $0.id == attempt.id }?.museReplyReceipt
            attempt.claudeReplyReceipt = state.attempts.first { $0.id == attempt.id }?.claudeReplyReceipt
            attempt.grokReplyReceipt = state.attempts.first { $0.id == attempt.id }?.grokReplyReceipt
            attempt.chatgptReplyReceipt = state.attempts.first { $0.id == attempt.id }?.chatgptReplyReceipt
            if error is CancellationError, !shuttingDown || nativeCancellationRequestedBeforeShutdown {
                attempt.dotsReplyReceipt?.automaticRecovery = false
                attempt.wabiReplyReceipt?.automaticRecovery = false
                attempt.museReplyReceipt?.automaticRecovery = false
                attempt.claudeReplyReceipt?.automaticRecovery = false
                attempt.grokReplyReceipt?.automaticRecovery = false
                attempt.chatgptReplyReceipt?.automaticRecovery = false
            }
            if provider == .claudeApp { attempt.conversationURL = state.claudeConversations[id.uuidString]?.url }
            if provider == .museApp {
                attempt.conversationURL = state.museAppConversations[id.uuidString]?.url
                attempt.recoveryConversationURL = state.attempts.first { $0.id == attempt.id }?.recoveryConversationURL
            }
            if provider == .geminiApp, let problem = error as? GeminiSelectionError {
                geminiOptions = problem.options; geminiConfigurationError = problem.localizedDescription; desktopReady = false
            }
            attempt.status = provider == .geminiApp && error is GeminiSelectionError ? .notSent : started ? .uncertain : .notSent
            let detail = error is CancellationError
                ? started ? "Stopped waiting for a reply. Check \(provider.name) before sending again." : "Stopped before sending. Your draft is saved."
                : error.localizedDescription
            attempt.detail = detail
            self.error = detail
            do { try store(attempt) } catch { self.error = "Could not save this request. Repair storage before sending again." }
        }
        do { try await foreground?.restore() }
        catch { self.error = error.localizedDescription }
        updateNativeSnapshot()
        return attempt
    }

    private func recordDesktopSubmission(attemptID: UUID) throws {
        guard !storageFailed, let index = state.attempts.firstIndex(where: { $0.id == attemptID }),
              state.attempts[index].status == .attempting, let comparison = state.attempts[index].comparisonID else {
            throw WebSessionFailure.notSent("The app submission receipt could not be saved. Review the app before continuing.")
        }
        let message = WebPageMessage(id: attemptID.uuidString, role: "user", text: state.attempts[index].text)
        var messages = state.localConversations[comparison.uuidString] ?? []
        if let existing = messages.first(where: { $0.id == message.id }) {
            guard existing == message else { throw WebSessionFailure.notReady("The saved outgoing message conflicts with its receipt. Review this conversation before continuing.") }
        } else { messages.append(message) }
        state.localConversations[comparison.uuidString] = messages
        state.attempts[index].status = .waiting
        state.attempts[index].messageID = attemptID.uuidString
        state.attempts[index].detail = "Outgoing message observed in the app. Waiting for its reply."
        try save()
        updateNativeSnapshot()
    }

    private func recordDotsReceipt(_ receipt: DotsReplyReceipt, attemptID: UUID) throws {
        guard provider == .dotsApp, !storageFailed,
              let index = state.attempts.firstIndex(where: { $0.id == attemptID }),
              state.attempts[index].status == .attempting,
              state.attempts[index].comparisonID == receipt.comparisonID,
              state.attempts[index].dotsReplyReceipt == nil, receipt.version == 1,
              !receipt.title.isEmpty, !receipt.prompt.isEmpty else {
            throw WebSessionFailure.notSent("The Dot request could not be saved. Nothing was sent.")
        }
        state.attempts[index].dotsReplyReceipt = receipt
        try save()
    }

    private func recordWabiReceipt(_ receipt: WabiReplyReceipt, attemptID: UUID) throws {
        guard provider == .wabi, !storageFailed,
              let index = state.attempts.firstIndex(where: { $0.id == attemptID }),
              state.attempts[index].status == .attempting,
              state.attempts[index].comparisonID == receipt.comparisonID,
              state.attempts[index].wabiReplyReceipt == nil,
              receipt.version == 1, WabiThread.isValid(receipt.url), !receipt.prompt.isEmpty else {
            throw WebSessionFailure.notSent("The Wabi request could not be saved. Nothing was sent.")
        }
        state.attempts[index].wabiReplyReceipt = receipt
        try save()
    }

    private func recordMuseReceipt(_ receipt: MuseReplyReceipt, attemptID: UUID) throws {
        guard provider == .museApp, !storageFailed,
              let index = state.attempts.firstIndex(where: { $0.id == attemptID }),
              state.attempts[index].status == .attempting,
              state.attempts[index].comparisonID == receipt.comparisonID,
              state.attempts[index].museReplyReceipt == nil, receipt.requestID == attemptID,
              receipt.version == 1, !receipt.prompt.isEmpty else {
            throw WebSessionFailure.notSent("The Muse request could not be saved. Nothing was sent.")
        }
        state.attempts[index].museReplyReceipt = receipt
        try save()
    }

    private func recordClaudeReceipt(_ receipt: ClaudeReplyReceipt, attemptID: UUID) throws {
        guard provider == .claudeApp, !storageFailed,
              let index = state.attempts.firstIndex(where: { $0.id == attemptID }),
              state.attempts[index].status == .attempting,
              state.attempts[index].comparisonID == receipt.comparisonID,
              state.attempts[index].claudeReplyReceipt == nil, receipt.version == 1,
              receipt.initialURL == nil || receipt.initialURL.map(ClaudeChatURL.isChat) == true,
              !receipt.prompt.isEmpty else {
            throw WebSessionFailure.notSent("The Claude request could not be saved. Nothing was sent.")
        }
        state.attempts[index].claudeReplyReceipt = receipt
        state.attempts[index].conversationURL = receipt.initialURL
        try save()
    }

    private func recordGrokReceipt(_ receipt: GrokReplyReceipt, attemptID: UUID) throws {
        guard provider == .grokBotApp, !storageFailed,
              let index = state.attempts.firstIndex(where: { $0.id == attemptID }),
              state.attempts[index].status == .attempting,
              state.attempts[index].comparisonID == receipt.comparisonID,
              state.attempts[index].grokReplyReceipt == nil, receipt.version == 1,
              state.desktopConversation?.name == receipt.bot, !receipt.bot.isEmpty,
              receipt.prompt == state.attempts[index].text, !receipt.anchor.digests.isEmpty else {
            throw WebSessionFailure.notSent("The Grok Bot request could not be saved. Nothing was sent.")
        }
        state.attempts[index].grokReplyReceipt = receipt
        try save()
    }

    private func recordChatGPTReceipt(_ receipt: ChatGPTReplyReceipt, attemptID: UUID) throws {
        guard provider == .chatgptApp, !storageFailed,
              let index = state.attempts.firstIndex(where: { $0.id == attemptID }),
              state.attempts[index].status == .attempting,
              state.attempts[index].comparisonID == receipt.comparisonID,
              state.attempts[index].chatgptReplyReceipt == nil, receipt.version == 1,
              let binding = try state.chatgptBinding(for: receipt.comparisonID, kind: .chatgpt),
              binding.firstPrompt == receipt.firstPrompt, !receipt.prompt.isEmpty,
              receipt.initialTitle == nil || [binding.title, binding.fallbackTitle].contains(receipt.initialTitle) else {
            throw WebSessionFailure.notSent("The ChatGPT request could not be saved. Nothing was sent.")
        }
        state.attempts[index].chatgptReplyReceipt = receipt
        try save()
    }

    private func recoverableDotsAttempt() -> WebSendAttempt? {
        guard provider == .dotsApp, connected, isEnabled, !fixture, !storageFailed, !shuttingDown else { return nil }
        let pending = state.attempts.filter { $0.status.isUnresolved }
        // A shared Dot cannot safely attribute a reply if old state contains
        // more than one unresolved request, even if only one has a receipt.
        guard pending.count == 1, let attempt = pending.first else { return nil }
        guard [.waiting, .uncertain].contains(attempt.status), attempt.messageID == attempt.id.uuidString,
                  let comparison = attempt.comparisonID, let receipt = attempt.dotsReplyReceipt,
                  receipt.version == 1, receipt.automaticRecovery, receipt.comparisonID == comparison,
                  let binding = state.chatgptConversations[comparison.uuidString], binding.kind == .dots,
                  binding.comparisonID == comparison, binding.title == receipt.title,
                  let messages = state.localConversations[comparison.uuidString],
                  messages.last == WebPageMessage(id: attempt.id.uuidString, role: "user", text: attempt.text),
                  !messages.contains(where: { $0.id == "native-reply-\(attempt.id.uuidString)" }),
                  receipt.prompt == attempt.text || receipt.prompt == binding.firstMessage(attempt.text) else { return nil }
        return attempt
    }

    private func stopNativeRecovery() {
        nativeRecoveryGeneration = UUID()
        nativeRecoveryPoll?.cancel()
        nativeRecoveryPoll = nil
    }

    private func startNativeRecoveryIfNeeded() {
        guard nativeRecoveryPoll == nil,
              recoverableDotsAttempt() != nil || recoverableWabiAttempt() != nil || recoverableMuseAttempt() != nil || recoverableClaudeAttempt() != nil || recoverableGrokAttempt() != nil || recoverableChatGPTAttempt() != nil else { return }
        let generation = UUID()
        nativeRecoveryGeneration = generation
        nativeRecoveryPoll = Task { [weak self] in
            while !Task.isCancelled {
                guard await self?.reconcileNativeReplyOnce() == true else { break }
                do { try await Task.sleep(for: .seconds(10)) } catch { break }
            }
            guard let self, self.nativeRecoveryGeneration == generation else { return }
            self.nativeRecoveryPoll = nil
        }
    }

    private func reconcileNativeReplyOnce() async -> Bool {
        if provider == .dotsApp { return await reconcileDotsReplyOnce() }
        if provider == .wabi { return await reconcileWabiReplyOnce() }
        if provider == .museApp { return await reconcileMuseReplyOnce() }
        if provider == .claudeApp { return await reconcileClaudeReplyOnce() }
        if provider == .grokBotApp { return await reconcileGrokReplyOnce() }
        if provider == .chatgptApp { return await reconcileChatGPTReplyOnce() }
        return false
    }

    private func recoverableWabiAttempt() -> WebSendAttempt? {
        guard provider == .wabi, connected, isEnabled, !fixture, !storageFailed, !shuttingDown else { return nil }
        let pending = state.attempts.filter { $0.status.isUnresolved }
        guard pending.count == 1, let attempt = pending.first,
              [.waiting, .uncertain].contains(attempt.status),
              let comparison = attempt.comparisonID, let receipt = attempt.wabiReplyReceipt,
              receipt.version == 1, receipt.automaticRecovery, receipt.comparisonID == comparison,
              receipt.prompt == attempt.text, WabiThread.isValid(receipt.url),
              (try? state.wabiConversation(for: comparison)) == receipt.url else { return nil }
        let messages = state.localConversations[comparison.uuidString] ?? []
        let outgoing = WebPageMessage(id: attempt.id.uuidString, role: "user", text: attempt.text)
        let confirmed = attempt.messageID == attempt.id.uuidString && messages.last == outgoing
        // The persisted pre-send receipt can also prove a previously
        // unconfirmed send, but only by matching the exact outgoing and reply
        // in the saved thread. A later attempt blocks attribution unless it
        // was never submitted, and an existing outgoing ID also blocks it.
        let laterAttempts = state.attempts.prefix { $0.id != attempt.id }.filter { $0.comparisonID == comparison }
        let awaitingProof = attempt.status == .uncertain && attempt.messageID == nil &&
            laterAttempts.allSatisfy { [.preparing, .notSent].contains($0.status) } &&
            !messages.contains(where: { $0.id == outgoing.id })
        guard (confirmed || awaitingProof),
              !messages.contains(where: { $0.id == "native-reply-\(attempt.id.uuidString)" }) else { return nil }
        return attempt
    }

    func reconcileWabiReplyOnce() async -> Bool {
        guard let attempt = recoverableWabiAttempt(), let receipt = attempt.wabiReplyReceipt else { return false }
        guard !isSending, !loading, !refreshing else { return true }
        refreshDesktopInstallation()
        guard desktopInstallation.isRunning else { return true }
        let originalMessages = state.localConversations[receipt.comparisonID.uuidString] ?? []
        let priorMessages = attempt.messageID == nil ? originalMessages : Array(originalMessages.dropLast())
        let converted = priorMessages.compactMap { message -> WabiAppMessage? in
            guard let role = WabiAppMessage.Role(rawValue: message.role) else { return nil }
            return WabiAppMessage(role: role, text: message.text)
        }
        let knownHistory = converted.count == priorMessages.count ? converted : nil
        do {
            let result = try await wabiApp.recoverReply(receipt, knownHistory: knownHistory)
            try Task.checkCancellation()
            guard let result, let current = recoverableWabiAttempt(), current.id == attempt.id,
                  current.wabiReplyReceipt == receipt,
                  (state.localConversations[receipt.comparisonID.uuidString] ?? []) == originalMessages else { return recoverableWabiAttempt() != nil }
            try finishRecoveredNativeReply(result, attempt: attempt, comparison: receipt.comparisonID, allowUnconfirmedWabi: attempt.messageID == nil)
        } catch is CancellationError { return false }
        catch {
            if storageFailed { self.error = "Could not save the Wabi reply. Repair storage before continuing." }
        }
        return recoverableWabiAttempt() != nil
    }

    private func recoverableMuseAttempt() -> WebSendAttempt? {
        guard provider == .museApp, connected, isEnabled, !fixture, !storageFailed, !shuttingDown else { return nil }
        let pending = state.attempts.filter { $0.status.isUnresolved }
        guard pending.count == 1, let attempt = pending.first,
              [.waiting, .uncertain].contains(attempt.status), attempt.messageID == attempt.id.uuidString,
              let comparison = attempt.comparisonID, let receipt = attempt.museReplyReceipt,
              receipt.version == 1, receipt.automaticRecovery, receipt.comparisonID == comparison,
              receipt.requestID == attempt.id,
              let binding = try? state.museAppBinding(for: comparison), let threadID = binding.threadID,
              receipt.initialThreadID == nil || receipt.initialThreadID == threadID,
              binding.url == attempt.conversationURL,
              receipt.prompt == (receipt.initialThreadID == nil ? MuseAppConversation.firstPrompt(attempt.text, requestID: attempt.id) : attempt.text),
              let messages = state.localConversations[comparison.uuidString],
              messages.last == WebPageMessage(id: attempt.id.uuidString, role: "user", text: attempt.text),
              !messages.contains(where: { $0.id == "native-reply-\(attempt.id.uuidString)" }) else { return nil }
        return attempt
    }

    func reconcileMuseReplyOnce() async -> Bool {
        guard let attempt = recoverableMuseAttempt(), let receipt = attempt.museReplyReceipt,
              let binding = try? state.museAppBinding(for: receipt.comparisonID) else { return false }
        guard !isSending, !loading, !refreshing else { return true }
        refreshDesktopInstallation()
        guard desktopInstallation.isRunning else { return true }
        do {
            let result = try await museApp.recoverReply(receipt, binding: binding)
            try Task.checkCancellation()
            guard let result, let current = recoverableMuseAttempt(), current.id == attempt.id,
                  current.museReplyReceipt == receipt,
                  (try? state.museAppBinding(for: receipt.comparisonID)) == binding else { return recoverableMuseAttempt() != nil }
            try finishRecoveredNativeReply(result, attempt: attempt, comparison: receipt.comparisonID)
        } catch is CancellationError { return false }
        catch {
            if storageFailed { self.error = "Could not save the Muse reply. Repair storage before continuing." }
        }
        return recoverableMuseAttempt() != nil
    }

    private func recoverableClaudeAttempt() -> WebSendAttempt? {
        guard provider == .claudeApp, connected, isEnabled, !fixture, !storageFailed, !shuttingDown else { return nil }
        let pending = state.attempts.filter { $0.status.isUnresolved }
        guard pending.count == 1, let attempt = pending.first,
              [.waiting, .uncertain].contains(attempt.status), attempt.messageID == attempt.id.uuidString,
              let comparison = attempt.comparisonID, let receipt = attempt.claudeReplyReceipt,
              receipt.version == 1, receipt.automaticRecovery, receipt.comparisonID == comparison,
              let binding = try? state.claudeBinding(for: comparison), let url = binding.url, ClaudeChatURL.isChat(url),
              attempt.conversationURL == url, receipt.initialURL == nil || receipt.initialURL == url,
              let firstPrompt = binding.firstPrompt, firstPrompt.hasPrefix("[msgblast comparison \(comparison.uuidString)]\n\n"),
              receipt.prompt == (receipt.initialURL == nil ? binding.firstMessage(attempt.text) : attempt.text),
              let messages = state.localConversations[comparison.uuidString],
              messages.last == WebPageMessage(id: attempt.id.uuidString, role: "user", text: attempt.text),
              !messages.contains(where: { $0.id == "native-reply-\(attempt.id.uuidString)" }) else { return nil }
        return attempt
    }

    func reconcileClaudeReplyOnce() async -> Bool {
        guard let attempt = recoverableClaudeAttempt(), let receipt = attempt.claudeReplyReceipt,
              let binding = try? state.claudeBinding(for: receipt.comparisonID) else { return false }
        guard !isSending, !loading, !refreshing else { return true }
        refreshDesktopInstallation()
        guard desktopInstallation.isRunning else { return true }
        do {
            let result = try await claudeApp.recoverReply(receipt, binding: binding)
            try Task.checkCancellation()
            guard let result, let current = recoverableClaudeAttempt(), current.id == attempt.id,
                  current.claudeReplyReceipt == receipt,
                  (try? state.claudeBinding(for: receipt.comparisonID)) == binding else { return recoverableClaudeAttempt() != nil }
            try finishRecoveredNativeReply(result, attempt: attempt, comparison: receipt.comparisonID)
        } catch is CancellationError { return false }
        catch {
            if storageFailed { self.error = "Could not save the Claude reply. Repair storage before continuing." }
        }
        return recoverableClaudeAttempt() != nil
    }

    private func recoverableGrokAttempt() -> WebSendAttempt? {
        guard provider == .grokBotApp, connected, isEnabled, !fixture, !storageFailed, !shuttingDown else { return nil }
        let pending = state.attempts.filter { $0.status.isUnresolved }
        guard pending.count == 1, let attempt = pending.first,
              [.waiting, .uncertain].contains(attempt.status), attempt.messageID == attempt.id.uuidString,
              let comparison = attempt.comparisonID, let receipt = attempt.grokReplyReceipt,
              receipt.version == 1, receipt.automaticRecovery, receipt.comparisonID == comparison,
              receipt.bot == state.desktopConversation?.name, receipt.prompt == attempt.text,
              let messages = state.localConversations[comparison.uuidString],
              messages.last == WebPageMessage(id: attempt.id.uuidString, role: "user", text: attempt.text),
              !messages.contains(where: { $0.id == "native-reply-\(attempt.id.uuidString)" }) else { return nil }
        return attempt
    }

    func reconcileGrokReplyOnce() async -> Bool {
        guard let attempt = recoverableGrokAttempt(), let receipt = attempt.grokReplyReceipt else { return false }
        guard !isSending, !loading, !refreshing else { return true }
        refreshDesktopInstallation()
        guard desktopInstallation.isRunning else { return true }
        do {
            let result = try await desktopDriver.recoverGrokReply(receipt)
            try Task.checkCancellation()
            guard let result, let current = recoverableGrokAttempt(), current.id == attempt.id,
                  current.grokReplyReceipt == receipt else { return recoverableGrokAttempt() != nil }
            try finishRecoveredNativeReply(result, attempt: attempt, comparison: receipt.comparisonID)
        } catch is CancellationError { return false }
        catch {
            if storageFailed { self.error = "Could not save the Grok Bot reply. Repair storage before continuing." }
        }
        return recoverableGrokAttempt() != nil
    }

    private func recoverableChatGPTAttempt() -> WebSendAttempt? {
        guard provider == .chatgptApp, connected, isEnabled, !fixture, !storageFailed, !shuttingDown else { return nil }
        let pending = state.attempts.filter { $0.status.isUnresolved }
        guard pending.count == 1, let attempt = pending.first,
              [.waiting, .uncertain].contains(attempt.status), attempt.messageID == attempt.id.uuidString,
              let comparison = attempt.comparisonID, let receipt = attempt.chatgptReplyReceipt,
              receipt.version == 1, receipt.automaticRecovery, receipt.comparisonID == comparison,
              let binding = try? state.chatgptBinding(for: comparison, kind: .chatgpt),
              binding.firstPrompt == receipt.firstPrompt,
              receipt.initialTitle == nil || [binding.title, binding.fallbackTitle].contains(receipt.initialTitle),
              receipt.prompt == (receipt.initialTitle == nil ? binding.firstMessage(attempt.text) : attempt.text),
              let messages = state.localConversations[comparison.uuidString],
              messages.last == WebPageMessage(id: attempt.id.uuidString, role: "user", text: attempt.text),
              !messages.contains(where: { $0.id == "native-reply-\(attempt.id.uuidString)" }) else { return nil }
        return attempt
    }

    func reconcileChatGPTReplyOnce() async -> Bool {
        guard let attempt = recoverableChatGPTAttempt(), let receipt = attempt.chatgptReplyReceipt,
              let binding = try? state.chatgptBinding(for: receipt.comparisonID, kind: .chatgpt) else { return false }
        guard !isSending, !loading, !refreshing else { return true }
        refreshDesktopInstallation()
        guard desktopInstallation.isRunning else { return true }
        do {
            let result = try await chatgptApp.recoverChatGPTReply(receipt)
            try Task.checkCancellation()
            guard let result, let current = recoverableChatGPTAttempt(), current.id == attempt.id,
                  current.chatgptReplyReceipt == receipt,
                  (try? state.chatgptBinding(for: receipt.comparisonID, kind: .chatgpt)) == binding else { return recoverableChatGPTAttempt() != nil }
            var saved = binding
            if saved.title == nil { saved.title = saved.dedicatedTitle; saved.fallbackTitle = result.title }
            try finishRecoveredNativeReply(result.answer, attempt: attempt, comparison: receipt.comparisonID, chatgptBinding: saved)
        } catch is CancellationError { return false }
        catch {
            if storageFailed { self.error = "Could not save the ChatGPT reply. Repair storage before continuing." }
        }
        return recoverableChatGPTAttempt() != nil
    }

    private func consumeNativeDraftIfUnchanged(_ attempt: WebSendAttempt, comparison: UUID) {
        let key = comparison.uuidString
        guard let revision = attempt.nativeDraftRevision,
              state.localDraftRevisions[key] == revision,
              state.localDrafts[key] == attempt.text,
              state.comparisonID != comparison || state.draft == attempt.text else { return }
        state.localDrafts[key] = ""
        state.localDraftRevisions[key] = UUID()
        if state.comparisonID == comparison { state.draft = "" }
    }

    private func finishRecoveredNativeReply(_ result: String, attempt: WebSendAttempt, comparison: UUID, chatgptBinding: ChatGPTConversationBinding? = nil, allowUnconfirmedWabi: Bool = false) throws {
        guard let index = state.attempts.firstIndex(where: { $0.id == attempt.id }) else { return }
        let key = comparison.uuidString
        var messages = state.localConversations[key] ?? []
        let outgoing = WebPageMessage(id: attempt.id.uuidString, role: "user", text: attempt.text)
        let reply = WebPageMessage(id: "native-reply-\(attempt.id.uuidString)", role: "assistant", text: result)
        guard !messages.contains(where: { $0.id == reply.id }) else { return }
        if messages.last != outgoing {
            guard allowUnconfirmedWabi, provider == .wabi, attempt.messageID == nil,
                  !messages.contains(where: { $0.id == outgoing.id }) else { return }
            messages.append(outgoing)
        }
        messages.append(reply)
        let previous = state
        if let chatgptBinding { try state.recordChatGPTBinding(chatgptBinding) }
        state.localConversations[key] = messages
        consumeNativeDraftIfUnchanged(attempt, comparison: comparison)
        state.attempts[index].status = .observed
        if allowUnconfirmedWabi { state.attempts[index].messageID = attempt.id.uuidString }
        state.attempts[index].detail = "Reply observed in the app conversation."
        state.attempts[index].dotsReplyReceipt = nil
        state.attempts[index].wabiReplyReceipt = nil
        state.attempts[index].museReplyReceipt = nil
        state.attempts[index].claudeReplyReceipt = nil
        state.attempts[index].grokReplyReceipt = nil
        state.attempts[index].chatgptReplyReceipt = nil
        do { try save() } catch { state = previous; throw error }
        if error == attempt.detail { error = nil }
        updateNativeSnapshot()
        if provider == .dotsApp { Task { await refresh() } }
        else if provider == .wabi || provider == .museApp || provider == .claudeApp || provider == .grokBotApp || provider == .chatgptApp { Task { await refreshAppAfterRecovery(comparison: comparison) } }
    }

    private func refreshAppAfterRecovery(comparison: UUID) async {
        guard !shuttingDown, isEnabled, connected, state.comparisonID == comparison,
              !isSending, !refreshing, !loading else { return }
        refreshing = true
        defer { refreshing = false }
        let grokBinding = provider == .grokBotApp ? state.desktopConversation : nil
        do {
            // The ordinary app refresh may navigate. Check only the current
            // window here; a later explicit send can reopen the saved chat.
            if provider == .wabi { try await wabiApp.checkAvailable() }
            else if provider == .museApp { try await museApp.checkAvailable() }
            else if provider == .claudeApp { try await claudeApp.checkAvailable() }
            else if provider == .chatgptApp { try await chatgptApp.checkAvailable(kind: .chatgpt) }
            else if provider == .grokBotApp, let binding = grokBinding { try await desktopDriver.checkGrokBot(named: binding.name) }
            else { return }
            guard !shuttingDown, state.comparisonID == comparison,
                  provider != .grokBotApp || state.desktopConversation == grokBinding else { return }
            desktopReady = true
            desktopStatus = provider == .wabi ? "Dedicated Wabi chat ready" : provider == .museApp ? "Muse side chat ready" : provider == .grokBotApp ? "Connected to \(state.desktopConversation?.name ?? "Grok Bot")" : provider == .chatgptApp ? "ChatGPT ready" : "Claude ready"
        } catch {
            guard !shuttingDown, state.comparisonID == comparison,
                  provider != .grokBotApp || state.desktopConversation == grokBinding else { return }
            desktopReady = false
            desktopStatus = error.localizedDescription
        }
        updateNativeSnapshot()
    }

    // A single poll never opens or switches a provider conversation. A nil
    // result or ambiguous observation leaves the original request unresolved.
    func reconcileDotsReplyOnce() async -> Bool {
        guard let attempt = recoverableDotsAttempt(), let receipt = attempt.dotsReplyReceipt else { return false }
        guard !isSending, !loading, !refreshing else { return true }
        refreshDesktopInstallation()
        guard desktopInstallation.isRunning else { return true }
        do {
            let result = try await chatgptApp.recoverDotsReply(receipt, refreshUnreadReply: { [weak self] target, count in
                guard let self, try await self.reserveDotsRefresh(attemptID: attempt.id, receipt: receipt, count: count) else { return nil }
                let focus = try await self.desktopDriver.beginReplyRefresh(target, session: "msgblast-dot-recovery-\(UUID())", onRestoreFailure: { [weak self] detail in
                    await MainActor.run { self?.error = detail }
                })
                if focus == nil { try await self.undoDotsRefreshReservation(attemptID: attempt.id, count: count) }
                return focus
            })
            try Task.checkCancellation()
            guard let result, let current = recoverableDotsAttempt(), current.id == attempt.id,
                  var currentReceipt = current.dotsReplyReceipt else { return recoverableDotsAttempt() != nil }
            var expectedReceipt = receipt
            currentReceipt.refreshedUnreadCount = nil; expectedReceipt.refreshedUnreadCount = nil
            guard currentReceipt == expectedReceipt else { return recoverableDotsAttempt() != nil }
            try finishRecoveredNativeReply(result, attempt: attempt, comparison: receipt.comparisonID)
        } catch is CancellationError { return false }
        catch {
            // Closed apps, transient reads, or changed conversations never
            // cause navigation, resending, or attribution to a different chat.
            if storageFailed { self.error = "Could not save the Dot reply. Repair storage before continuing." }
        }
        return recoverableDotsAttempt() != nil
    }

    private func reserveDotsRefresh(attemptID: UUID, receipt: DotsReplyReceipt, count: Int) throws -> Bool {
        guard let attempt = recoverableDotsAttempt(), attempt.id == attemptID,
              let index = state.attempts.firstIndex(where: { $0.id == attemptID }),
              state.attempts[index].dotsReplyReceipt == receipt,
              count != receipt.initialUnreadCount, count != receipt.refreshedUnreadCount else { return false }
        state.attempts[index].dotsReplyReceipt?.refreshedUnreadCount = count
        try save()
        return true
    }

    private func undoDotsRefreshReservation(attemptID: UUID, count: Int) throws {
        guard let index = state.attempts.firstIndex(where: { $0.id == attemptID }),
              state.attempts[index].status.isUnresolved,
              state.attempts[index].dotsReplyReceipt?.refreshedUnreadCount == count else { return }
        state.attempts[index].dotsReplyReceipt?.refreshedUnreadCount = nil
        try save()
    }

    private func recordMuseAppCandidate(_ url: URL, comparisonID: UUID, attemptID: UUID) throws {
        guard !storageFailed, MuseSideChatBinding.threadID(in: url) != nil,
              let index = state.attempts.firstIndex(where: { $0.id == attemptID }),
              state.attempts[index].comparisonID == comparisonID,
              state.attempts[index].recoveryConversationURL == nil || state.attempts[index].recoveryConversationURL == url else {
            throw WebSessionFailure.notSent("Muse's pending side-chat address could not be saved. Review Muse before continuing.")
        }
        state.attempts[index].recoveryConversationURL = url
        try save()
    }

    private func recordMuseAppSubmission(_ binding: MuseSideChatBinding, attemptID: UUID) throws {
        guard !storageFailed, let index = state.attempts.firstIndex(where: { $0.id == attemptID }),
              state.attempts[index].comparisonID == binding.comparisonID else {
            throw WebSessionFailure.notSent("Muse's side-chat receipt could not be saved. Review Muse before continuing.")
        }
        try state.recordMuseAppBinding(binding)
        state.attempts[index].conversationURL = binding.url
        state.attempts[index].recoveryConversationURL = nil
        try save()
    }

    private func waitForSendControl(_ preparedDraft: String, expectedURL: String, generation: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while true {
            try Task.checkCancellation()
            guard generation == navigationGeneration, !loading else {
                throw WebSessionFailure.notSent("\(provider.name) navigated before submission. Review its draft.")
            }
            // Read-only polling leaves the attempt in .preparing until a click is possible.
            // A navigation that cancels this read is still "not sent", with the same detail as the generation check.
            let result: [String: Any]?
            do {
                result = try await webView.callAsyncJavaScript(script.sendReadiness, arguments: ["preparedDraft": preparedDraft, "expectedURL": expectedURL], in: nil, contentWorld: .defaultClient) as? [String: Any]
            } catch {
                guard generation == navigationGeneration, !loading else {
                    throw WebSessionFailure.notSent("\(provider.name) navigated before submission. Review its draft.")
                }
                throw error
            }
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

    private func page(for view: WKWebView) -> WebConversationPage? {
        pages.values.first { $0.view === view }
    }
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let page = page(for: webView) else { return }
        page.generation += 1; page.loading = true; page.snapshot = WebPageSnapshot()
        if provider != .dots { clearAvatar(in: page) }; page.restoredDraft = false
        publish(page)
    }
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let page = page(for: webView) else { popupURL = webView.url?.absoluteString ?? ""; return }
        page.loading = false
        if let navigation = page.navigationError, page.error == navigation { page.error = nil }
        page.navigationError = nil
        publish(page)
        Task { await refresh(page) }
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failedNavigation(webView, error: error) }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failedNavigation(webView, error: error) }
    private func failedNavigation(_ view: WKWebView, error: Error) {
        guard let page = page(for: view) else { return }
        page.loading = false
        if (error as NSError).code != NSURLErrorCancelled, !storageFailed {
            page.navigationError = "\(provider.name) could not load: \(error.localizedDescription)"
            page.error = page.navigationError
        }
        publish(page)
    }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let page = page(for: webView) else { return }
        page.generation += 1; page.loading = false; page.snapshot = WebPageSnapshot()
        if provider != .dots { clearAvatar(in: page) }
        page.error = "\(provider.name)’s web process stopped. Reload its page. Pending submissions will not be resent."
        publish(page)
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
            if let page = page(for: webView) {
                page.navigationError = "This link cannot open inside MsgBlast. Stay on \(provider.name)’s website to continue."
                page.error = page.navigationError; publish(page)
            }
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

@MainActor
private final class WebConversationPage {
    let id = UUID()
    var comparisonID: UUID?
    var key: String { comparisonID?.uuidString ?? "new" }
    let view: WKWebView
    var snapshot = WebPageSnapshot()
    var loading = false
    var refreshing = false
    var generation = 0
    var error: String?
    var navigationError: String?
    var readinessError: String?
    var avatarKey: String?
    var avatar: Data?
    var restoredDraft = false
    var lastUsed = Date()
    init(comparisonID: UUID?, view: WKWebView) { self.comparisonID = comparisonID; self.view = view }
}

@MainActor
private struct WebReceiptGeneration {
    let pageID: UUID
    let generation: Int
    init(page: WebConversationPage, generation: Int) { pageID = page.id; self.generation = generation }
    func matches(_ page: WebConversationPage) -> Bool { page.id == pageID && page.generation == generation }
}

extension WebAgentSession {
    func setGrokBotConnectionActivity(_ activity: GrokBotConnectionActivity?) {
        grokBotConnectionActivity = activity
        updateNativeSnapshot()
    }
    public var grokBotWebhookURL: String { grokBotCredentials?.webhookURL.absoluteString ?? "" }
    public var grokBotIsConfigured: Bool { fixture || grokBotCredentials != nil }
    public var hasPendingGrokBotRequests: Bool {
        provider == .grokbot && state.attempts.contains { $0.status.isUnresolved }
    }
    @discardableResult
    public func retryGrokBotSavedConnection() async -> Bool {
        guard provider == .grokbot, !fixture, !isSending, !configuringGrokBot, !storageFailed, !shuttingDown, state.grokBotRememberedConnection != false else { return false }
        setGrokBotConnectionActivity(.readingKey)
        return await restoreGrokBotConnection()
    }
    private func restoreGrokBotConnection() async -> Bool {
        defer {
            setGrokBotConnectionActivity(nil)
            if !shuttingDown, connected, isEnabled, grokBotCredentials != nil { Task { await refresh() } }
        }
        do {
            let credentials = try await GrokBotCredentialStore.read(storageURL)
            guard !shuttingDown else { return false }
            grokBotCredentials = credentials; grokBotRemembersConnection = credentials != nil
            grokBotNeedsKeychainRetry = false
            if !storageFailed { error = nil }
            if grokBotReplyURL == nil { grokBotConnectionReady = nil }
            return credentials != nil
        } catch {
            if !shuttingDown { self.error = error.localizedDescription; grokBotNeedsKeychainRetry = true }
            return false
        }
    }
    @discardableResult
    public func configureGrokBot(webhookURL: String, webhookKey: String, selectAfterConnecting: Bool = true) async -> Bool {
        guard provider == .grokbot, !isSending, !configuringGrokBot, !hasPendingGrokBotRequests, !storageFailed, !shuttingDown else { return false }
        setGrokBotConnectionActivity(.startingTunnel)
        defer { setGrokBotConnectionActivity(nil) }
        do {
            let credentials = try GrokBotCredentials(webhookURL: webhookURL, webhookKey: webhookKey)
            var remembered = fixture
            if !fixture {
                try await startGrokBotConnection()
                setGrokBotConnectionActivity(.savingKey)
                // Failure to remember a key must not prevent a session-only connection.
                remembered = (try? await GrokBotCredentialStore.save(credentials, at: storageURL)) ?? false
            }
            guard !shuttingDown else { return false }
            guard fixture || grokBotReplyURL != nil else { throw GrokBotServiceError.callbackUnavailable }
            // A late secure-storage write must not revive an older key after a newer
            // session-only connection. Persist only this non-secret restore policy.
            state.grokBotRememberedConnection = remembered
            try save()
            grokBotCredentials = credentials
            grokBotRemembersConnection = remembered
            grokBotConnectionReady = true; grokBotNeedsKeychainRetry = false; error = nil
            if selectAfterConnecting { setEnabled(true) }
            else { updateState { $0.enabled = true; $0.selected = false } }
            connect()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
    private func startGrokBotConnection() async throws {
        if grokBotReplyURL != nil { return }
        guard grokBotReceiver == nil else { throw GrokBotServiceError.callbackUnavailable }
        setGrokBotConnectionActivity(.startingTunnel)
        defer { if grokBotConnectionActivity == .startingTunnel { setGrokBotConnectionActivity(nil) } }
        let receiver = GrokBotCallbackReceiver { [weak self] receipt in
            guard let self else { throw GrokBotServiceError.callbackUnavailable }
            try self.receiveGrokBotReceipt(receipt)
        }
        receiver.onDrained = { [weak self] in
            guard let self, !self.isEnabled, !self.configuringGrokBot, !self.hasPendingGrokBotRequests else { return }
            self.stopGrokBotConnection()
        }
        for attempt in state.attempts { if let hash = attempt.callbackHash { receiver.register(id: attempt.id, tokenHash: hash) } }
        grokBotReceiver = receiver
        let tunnel = GrokBotTunnel(); grokBotTunnel = tunnel
        tunnel.onDisconnect = { [weak self] in
            guard let self else { return }
            self.stopGrokBotConnection()
            self.error = GrokBotServiceError.callbackUnavailable.localizedDescription
            self.updateNativeSnapshot()
        }
        do {
            let local = try await receiver.start()
            let address = try await tunnel.start(localURL: local)
            guard !shuttingDown else { throw GrokBotServiceError.callbackUnavailable }
            grokBotReplyURL = address; grokBotConnectionReady = true
        } catch { stopGrokBotConnection(); throw error }
    }
    private func stopGrokBotConnection() {
        grokBotTunnel?.onDisconnect = nil; grokBotTunnel?.stop(); grokBotTunnel = nil
        grokBotReceiver?.stop(); grokBotReceiver = nil
        grokBotReplyURL = nil; grokBotConnectionReady = false
        for index in state.attempts.indices where [.attempting, .waiting].contains(state.attempts[index].status) {
            state.attempts[index].status = .uncertain
            state.attempts[index].detail = "The reply connection ended. Check Grok Bot before continuing; no automatic resend."
        }
        if provider == .grokbot { persist() }
    }
    private func refreshGrokBot() async {
        refreshing = true
        defer { refreshing = false; updateNativeSnapshot() }
        guard !storageFailed, !shuttingDown, !configuringGrokBot else { return }
        if fixture {
            for attempt in state.attempts.filter({ $0.status == .waiting }) {
                do { try applyGrokBotReceipt(GrokBotReceipt(request_id: attempt.id, status: .answered, answer: "Grok Bot fixture reply: \(attempt.text)"), to: attempt) }
                catch { self.error = error.localizedDescription }
            }
        } else if isEnabled, grokBotCredentials != nil, grokBotConnectionReady == nil {
            do { try await startGrokBotConnection(); error = nil }
            catch { self.error = error.localizedDescription }
        } else if !isEnabled, !hasPendingGrokBotRequests, grokBotReceiver != nil, grokBotReceiver?.hasActiveConnections != true { stopGrokBotConnection() }
    }
    func receiveGrokBotReceipt(_ receipt: GrokBotReceipt) throws {
        guard let attempt = state.attempts.first(where: { $0.id == receipt.request_id }) else { throw GrokBotServiceError.invalidReply }
        guard !storageFailed || grokBotReplyStorageFailure == receipt.request_id else {
            throw WebSessionFailure.notSent("Web session storage is unavailable.")
        }
        do { try applyGrokBotReceipt(receipt, to: attempt) }
        catch {
            self.error = "Grok Bot's reply could not be saved. Repair storage before sending again."
            updateNativeSnapshot()
            throw error
        }
        updateNativeSnapshot()
    }
    private func applyGrokBotReceipt(_ receipt: GrokBotReceipt, to previous: WebSendAttempt) throws {
        guard let index = state.attempts.firstIndex(where: { $0.id == previous.id }), let comparisonID = previous.comparisonID else { throw GrokBotServiceError.invalidReply }
        var attempt = state.attempts[index]
        guard attempt.status != .dismissed else { throw GrokBotServiceError.callbackUnavailable }
        let replyID = "grokbot-\(attempt.id.uuidString)"
        if let saved = state.localConversations[comparisonID.uuidString]?.first(where: { $0.id == replyID }) {
            guard saved.text == receipt.answer else { throw GrokBotServiceError.invalidReply }
            return
        }
        let previousState = state
        state.localConversations[comparisonID.uuidString, default: []].append(WebPageMessage(id: replyID, role: "assistant", text: receipt.answer))
        attempt.status = receipt.status == .answered ? .observed : .notSent
        attempt.detail = receipt.status == .failed ? receipt.answer : fixture ? "Simulated callback. No Grok Bot or tunnel was contacted." : "Reply received on this Mac."
        // Only a callback whose write failed may retry storage; sends remain blocked.
        if grokBotReplyStorageFailure == attempt.id { storageFailed = false }
        do {
            try store(attempt)
            grokBotReplyStorageFailure = nil; error = nil
        } catch {
            state = previousState
            grokBotReplyStorageFailure = attempt.id
            throw error
        }
    }
    private func sendGrokBot(_ text: String, comparisonID: UUID?, consumePrivateDraft: Bool) async -> WebSendAttempt? {
        guard isEnabled, !shuttingDown, !isSending, !configuringGrokBot, !storageFailed, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let comparisonID = comparisonID ?? state.comparisonID ?? UUID()
        guard !hasIncompleteNativeRequest(for: comparisonID) else { error = "Wait for Grok Bot's previous reply or stop waiting before sending another request."; return nil }
        isSending = true
        defer { isSending = false; updateNativeSnapshot() }
        var attempt = WebSendAttempt(text: text); attempt.comparisonID = comparisonID
        state.attempts.insert(attempt, at: 0)
        var submitted = false
        do {
            try save()
            guard fixture || grokBotCredentials != nil else { throw WebSessionFailure.notSent("Connect Grok Bot in Settings before sending.") }
            guard !consumePrivateDraft || state.draft.isEmpty || state.draft == text else { throw WebSessionFailure.notSent("Grok Bot has a draft. Send or clear it before continuing.") }
            if !fixture { try await startGrokBotConnection() }
            let token = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
            attempt.callbackHash = Data(SHA256.hash(data: Data(token.utf8)))
            let baseURL = grokBotReplyURL ?? URL(string: "https://fixture.trycloudflare.com")!
            let body = try GrokBotService.encodeRequest(id: attempt.id, comparisonID: comparisonID, message: text,
                history: state.localConversations[comparisonID.uuidString] ?? [], callbackURL: baseURL.appendingPathComponent("reply/\(attempt.id.uuidString.lowercased())"), callbackToken: token)
            updateState { $0.comparisonID = comparisonID }
            attempt.status = .attempting
            state.localConversations[comparisonID.uuidString, default: []].append(WebPageMessage(id: attempt.id.uuidString, role: "user", text: text))
            try store(attempt)
            grokBotReceiver?.register(id: attempt.id, tokenHash: attempt.callbackHash!)
            submitted = true
            if !fixture { try await GrokBotService.submit(grokBotCredentials!, body: body) }
            if let saved = state.attempts.first(where: { $0.id == attempt.id && $0.status != .attempting }) { attempt = saved }
            else {
                attempt.status = fixture || grokBotReplyURL == baseURL ? .waiting : .uncertain
                attempt.detail = fixture ? "Simulated webhook accepted. Waiting for the simulated callback." : attempt.status == .waiting ? "Grok Bot accepted the request. Keep msgblast open and this Mac awake for its reply." : "The reply connection ended during submission. Check Grok Bot before continuing."
                try store(attempt)
            }
            if consumePrivateDraft && state.draft == text { state.draft = ""; state.localDrafts[comparisonID.uuidString] = ""; try save() }
            connect()
        } catch {
            if let saved = state.attempts.first(where: { $0.id == attempt.id && [.observed, .notSent].contains($0.status) }) { attempt = saved }
            else {
                attempt.status = submitted && (error as? GrokBotServiceError)?.definitelyNotSubmitted != true ? .uncertain : .notSent
                if (error as? GrokBotServiceError)?.definitelyNotSubmitted == true {
                    state.localConversations[comparisonID.uuidString]?.removeAll { $0.id == attempt.id.uuidString }
                }
                attempt.detail = error.localizedDescription
                self.error = error.localizedDescription
                do { try store(attempt) } catch { self.error = "Could not save Grok Bot's request. Repair storage before sending again." }
            }
        }
        return attempt
    }
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
