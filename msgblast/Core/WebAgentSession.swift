import AppKit
import Combine
import CryptoKit
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
    // Optional CLI providers never touch this lazy view: their transcript is native.
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
    public let fixture: Bool
    private let storageURL: URL
    private var storageFailed = false
    private var grokBotReplyStorageFailure: UUID?
    private var poll: Task<Void, Never>?
    private var refreshing = false
    private var navigationGeneration = 0
    private var comparisonGeneration = 0
    private var avatarKey: String?
    private var navigationError: String?
    private var readinessError: String?
    private var receiptGenerations: [UUID: Int] = [:]
    public let provider: WebProvider
    private var script: WebPageScript { WebPageScript(provider: provider) }

    public init(provider: WebProvider, storageURL: URL, fixture: Bool, migrationError: String? = nil) {
        self.provider = provider
        self.storageURL = storageURL
        self.fixture = fixture
        var loaded = WebWorkspaceState()
        loaded.selected = WebProvider.webDefaults.contains(provider)
        var failure: String? = migrationError
        do { loaded = try JSONDecoder().decode(WebWorkspaceState.self, from: Data(contentsOf: storageURL)).recoveringInFlight() }
        catch CocoaError.fileReadNoSuchFile { }
        catch { failure = "Web session state could not be read. The saved file has been preserved: \(error.localizedDescription)" }
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
        if provider.usesNativeConversation { updateNativeSnapshot() }
        if failure == nil { persist() }
    }

    deinit { poll?.cancel() }

    public func updateState(_ edit: (inout WebWorkspaceState) -> Void) {
        guard !storageFailed else { return }
        let previous = state.comparisonID
        let previousDraft = state.draft
        edit(&state)
        if state.comparisonID != previous { comparisonGeneration += 1 }
        if provider.usesNativeConversation {
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

    public var isEnabled: Bool { !provider.usesNativeConversation || state.enabled == true }

    public func setEnabled(_ enabled: Bool) {
        guard provider.usesNativeConversation else { return }
        updateState { $0.enabled = enabled; $0.selected = enabled }
        if !enabled { cancelNativeRequest() }
        if provider == .grokbot {
            if enabled, grokBotReplyURL == nil { grokBotConnectionReady = nil }
            if connected { Task { await refresh() } }
        }
    }

    public func connect() {
        connect(automaticallyRefresh: true)
    }

    // Controlled fixtures can own refresh boundaries without racing the poller.
    func connect(automaticallyRefresh: Bool) {
        guard !connected else { return }
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
        if provider.personalAgentProvider != nil {
            Task { await refresh() }
            return
        }
        loadComparisonChat()
        guard automaticallyRefresh else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
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

    private var comparisonURL: URL {
        if let id = state.comparisonID,
           let url = state.conversationURLs[id.uuidString], provider.isSavedConversation(url) { return url }
        if let url = unresolvedWebAttempt?.pinnedConversationURL, provider.isSavedConversation(url) { return url }
        if provider == .dots, let url = state.dotsURL, provider.isSavedConversation(url) { return url }
        return provider.newChatURL
    }

    private var unresolvedWebAttempt: WebSendAttempt? {
        guard !provider.usesNativeConversation, state.comparisonID != nil else { return nil }
        return state.attempts.first { $0.comparisonID == state.comparisonID && $0.status == .uncertain }
    }

    public var needsConversationLink: Bool {
        unresolvedWebAttempt != nil
    }

    public var canLinkCurrentConversation: Bool {
        guard needsConversationLink, !isSending, !loading, snapshot.ready, snapshot.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let attempt = unresolvedWebAttempt, let comparison = state.comparisonID, let current = URL(string: snapshot.url),
              let url = provider.canonicalConversationURL(current),
              webView.url.flatMap(provider.canonicalConversationURL) == url,
              (provider == .dots || !state.conversationURLs.contains(where: { $0.key != comparison.uuidString && provider.canonicalConversationURL($0.value) == url })) else { return false }
        if let saved = state.conversationURLs[comparison.uuidString], provider.canonicalConversationURL(saved) != url { return false }
        if let candidate = attempt.pinnedConversationURL, candidate != url { return false }
        let matches = snapshot.messages.indices.filter { snapshot.messages[$0].role == "user" && Self.normalized(snapshot.messages[$0].text) == Self.normalized(attempt.text) }
        guard matches.count == 1 else { return false }
        return snapshot.messages.dropFirst(matches[0] + 1).prefix { $0.role != "user" }.contains { $0.role == "assistant" }
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
              var attempt = unresolvedWebAttempt, let comparison, let current = URL(string: snapshot.url),
              let url = provider.canonicalConversationURL(current) else { return }
        attempt.status = .observed
        attempt.messageID = snapshot.messages.first { $0.role == "user" && Self.normalized($0.text) == Self.normalized(attempt.text) }?.id
        attempt.conversationURL = url
        attempt.recoveryConversationURL = nil
        attempt.receiptContext = nil
        receiptGenerations.removeValue(forKey: attempt.id)
        attempt.detail = "Conversation linked after the user reviewed its existing request and reply."
        state.conversationURLs[comparison.uuidString] = url
        do { try store(attempt); error = nil }
        catch { self.error = "Could not save the linked conversation. Repair storage before sending." }
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
        if provider == .grokbot { return fixture ? "Simulated webhook · no Bot contacted" : "Webhook connection" }
        if let agent = provider.personalAgentProvider { return fixture ? "\(agent.name) · Simulated local account" : "\(agent.name) · Local account" }
        let host = webView.url?.host ?? provider.homeURL.host!
        return provider == .dots ? "\(host) · Your dot" : provider == .muse && webView.url.map(provider.isChatURL) == true ? "\(host) · Side chat" : host
    }

    @discardableResult
    public func openComparison(_ id: UUID?) async -> Bool {
        guard !isSending else { return false }
        if state.comparisonID != id { updateState { $0.comparisonID = id } }
        connect()
        if provider.usesNativeConversation {
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
            readyBeforeSetup = snapshot.ready
        }
        try checkCurrent()
        guard snapshot.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WebSessionFailure.notSent("\(provider.name) has a draft. Send or clear it before switching chats.")
        }
        let target = comparisonURL // Inspection above may have recovered a late receipt.
        func matchesTarget(_ location: String) -> Bool {
            if location == target.absoluteString { return true }
            // /dots resolves to the account's ongoing dot, never a new ChatGPT chat.
            return provider == .dots && target == provider.newChatURL &&
                URL(string: location).flatMap(provider.canonicalConversationURL) != nil
        }
        let pinned = unresolvedWebAttempt?.pinnedConversationURL
        // A missed first receipt must not erase the live chat before recovery can inspect it.
        if needsConversationLink, state.comparisonID.flatMap({ state.conversationURLs[$0.uuidString] }) == nil,
           let current = URL(string: snapshot.url), let currentChat = provider.canonicalConversationURL(current),
           pinned == nil || pinned == currentChat {
            return readyBeforeSetup
        }
        if !loading, snapshot.url == target.absoluteString, !snapshot.ready {
            throw WebSessionFailure.notReady(snapshot.reason)
        }
        if target == provider.newChatURL, snapshot.url == target.absoluteString,
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
            return fresh.signedIn
        } catch { return nil }
    }

    private var canInspectWebsite: Bool {
        guard let url = webView.url else { return false }
        return url.scheme == "https" && url.host == provider.homeURL.host
    }

    public func closePopup() { popup = nil; popupURL = ""; Task { await refresh() } }

    public func refresh() async {
        guard connected, !loading, !refreshing else { return }
        if provider == .grokbot { await refreshGrokBot(); return }
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
        guard canInspectWebsite else {
            var current = WebPageSnapshot()
            current.url = webView.url?.absoluteString ?? ""
            current.reason = provider == .muse ? "Sign in to Muse and open this comparison’s side chat." : "Sign in to \(provider.name) and open a chat."
            if snapshot != current { snapshot = current }
            if provider != .dots { clearAvatar() }
            if provider == .dots, state.savedAvatar != nil || state.dotsURL != nil, ["/auth/login", "/auth/logout", "/login", "/logout"].contains(webView.url?.path ?? "") {
                clearAvatar()
                updateState { $0.savedAvatar = nil; $0.dotsURL = nil }
            }
            return
        }
        refreshing = true
        defer { refreshing = false }
        let generation = navigationGeneration
        do {
            if (provider == .chatgpt || provider == .dots) && !isSending && webView.url.map(provider.isChatURL) == true {
                _ = try await webView.callAsyncJavaScript(script.configureInitialLayout, arguments: [:], in: nil, contentWorld: .defaultClient)
                guard generation == navigationGeneration else { return }
            }
            let result = try await webView.callAsyncJavaScript(script.inspect, arguments: [:], in: nil, contentWorld: .defaultClient)
            guard generation == navigationGeneration, let result else { return }
            let fresh = try JSONDecoder().decode(WebPageSnapshot.self, from: JSONSerialization.data(withJSONObject: result))
            if snapshot != fresh { snapshot = fresh }
            if provider == .dots, fresh.signedOut == true {
                clearAvatar()
                if state.savedAvatar != nil || state.dotsURL != nil {
                    updateState { $0.savedAvatar = nil; $0.dotsURL = nil }
                }
                return
            }
            recordCurrentDot(from: fresh)
            reconcileUnconfirmedReceipt()
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
            if provider != .dots { clearAvatar() }
        }
    }

    private func recordCurrentDot(from fresh: WebPageSnapshot) {
        guard provider == .dots, fresh.ready, !loading, let url = URL(string: fresh.url),
              webView.url == url, let saved = provider.canonicalConversationURL(url), saved != state.dotsURL else { return }
        updateState { $0.dotsURL = saved; $0.savedAvatar = nil }
        clearAvatar()
    }

    private func clearAvatar() {
        avatarKey = nil
        if avatar != nil { avatar = nil }
    }

    private func refreshAvatar(generation: Int) async {
        guard provider == .muse || provider == .dots else { return }
        if provider == .dots && webView.window == nil { return }
        if provider == .muse && !snapshot.ready { clearAvatar(); return }
        do {
            let result = try await webView.callAsyncJavaScript(script.avatar, arguments: ["previousKey": avatarKey ?? ""], in: nil, contentWorld: .defaultClient) as? [String: Any]
            guard generation == navigationGeneration else { return }
            guard let key = result?["key"] as? String else {
                if provider == .muse { clearAvatar() }
                return
            }
            if key == avatarKey { return }
            let data: Data
            if provider == .dots {
                let bounds = webView.bounds
                guard webView.window != nil, !loading, let capturedURL = webView.url, let result,
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
                    webView.takeSnapshot(with: configuration) { image, error in
                        if let image { continuation.resume(returning: image) }
                        else { continuation.resume(throwing: error ?? WebSessionFailure.unconfirmed) }
                    }
                }
                // Layout and artwork can change while WebKit captures. Leave the old
                // image and key intact on mismatch so the next refresh retries.
                let verified = try await webView.callAsyncJavaScript(script.avatar, arguments: ["previousKey": key], in: nil, contentWorld: .defaultClient) as? [String: Any]
                guard generation == navigationGeneration, !loading, webView.url == capturedURL, webView.bounds == bounds,
                      let verified, NSDictionary(dictionary: result).isEqual(to: verified),
                      state.dotsURL == capturedURL, let png = Self.avatarPNG(image, crop: crop) else { return }
                data = png
                updateState { $0.savedAvatar = png }
            } else {
                guard let png = result?["png"] as? String, png.hasPrefix("data:image/png;base64,"), png.count < 400_000,
                      let decoded = Data(base64Encoded: String(png.dropFirst(22))),
                      let image = NSBitmapImageRep(data: decoded), image.pixelsWide == 256, image.pixelsHigh == 256 else { clearAvatar(); return }
                data = decoded
            }
            avatarKey = key
            avatar = data
        } catch {
            if generation == navigationGeneration && provider == .muse { clearAvatar() }
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
    public func send(_ text: String, comparisonID: UUID? = nil) async -> WebSendAttempt? {
        if provider == .grokbot { return await sendGrokBot(text, comparisonID: comparisonID) }
        if provider.personalAgentProvider != nil { return await sendNative(text, comparisonID: comparisonID) }
        guard !isSending, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard !storageFailed else { error = "Repair web session storage before sending."; return nil }
        await refresh()
        guard !isSending else { return nil }
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
                throw WebSessionFailure.notSent("Open the original \(provider.name) chat and choose Use this conversation before sending a follow-up.")
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
            receiptGenerations[attempt.id] = generation
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
            attempt.recoveryConversationURL = nil
            attempt.receiptContext = nil
            receiptGenerations.removeValue(forKey: attempt.id)
        }
        do { try store(attempt) } catch { self.error = "Could not save the send result. Check \(provider.name) before retrying." }
        return attempt
    }

    private func observeReceipt(_ attempt: inout WebSendAttempt) -> Bool {
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
        guard receiptGenerations[attempt.id] == navigationGeneration || pinned != nil else { return invalidate() }
        if context.originalURL == provider.newChatURL, current == context.originalURL { return false }
        guard provider.acceptsReceipt(from: context.originalURL, at: current), let url = provider.canonicalConversationURL(current),
              pinned == nil || pinned == url,
              current.path == context.originalURL.path || (!context.existingPaths.contains(current.path) && !state.conversationURLs.values.contains(where: { provider.canonicalConversationURL($0) == url })),
              snapshot.messages.starts(with: context.baseline) else { return invalidate() }
        context.candidateURL = url
        attempt.recoveryConversationURL = url
        attempt.receiptContext = context
        let before = Set(context.baseline.map(\.id))
        let text = Self.normalized(attempt.text)
        let matches = snapshot.messages.filter { !before.contains($0.id) && $0.role == "user" && Self.normalized($0.text) == text }
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

    private func reconcileUnconfirmedReceipt() {
        guard !isSending, !storageFailed, var attempt = unresolvedWebAttempt, attempt.receiptContext != nil else { return }
        let previous = attempt
        _ = observeReceipt(&attempt)
        guard attempt != previous else { return }
        do { try store(attempt); if attempt.status == .observed { error = nil } }
        catch { self.error = "Could not save the recovered conversation. Repair storage before sending." }
    }

    private func updateNativeSnapshot() {
        var fresh = snapshot
        fresh.messages = state.comparisonID.flatMap { state.localConversations[$0.uuidString] } ?? []
        fresh.draft = state.draft
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

    public func acknowledgeIncompleteRequest() {
        guard provider.usesNativeConversation, !isSending else { return }
        updateState { state in
            for i in state.attempts.indices where state.attempts[i].comparisonID == state.comparisonID && [.waiting, .uncertain].contains(state.attempts[i].status) {
                state.attempts[i].status = .dismissed
            }
        }
    }

    public func hasUnresolvedSend(_ text: String) -> Bool {
        if !provider.usesNativeConversation { return state.hasUnresolvedSend(text) }
        return hasIncompleteNativeRequest(for: state.comparisonID)
    }
    private func hasIncompleteNativeRequest(for id: UUID?) -> Bool {
        state.attempts.contains { $0.comparisonID == id && $0.status.isUnresolved }
    }

    public func cancelNativeRequest() { requestCancelled = true; nativeRequest?.cancel() }
    public func beginShutdown() { shuttingDown = true; poll?.cancel(); cancelNativeRequest(); stopGrokBotConnection() }
    public func cancelAndWait() async {
        beginShutdown()
        while provider.usesNativeConversation && isSending { try? await Task.sleep(for: .milliseconds(20)) }
    }

    func conversationWorkingDirectory(_ id: UUID) -> URL {
        storageURL.deletingLastPathComponent().appendingPathComponent("local-conversations/\(provider.localConversationDirectoryName)/\(id.uuidString)", isDirectory: true)
    }

    private func sendNative(_ text: String, comparisonID: UUID?) async -> WebSendAttempt? {
        guard isEnabled, !shuttingDown, !isSending, !storageFailed, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
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
            let savedSessionID = state.resumableLocalSessionID(for: id)
            let workingDirectory = conversationWorkingDirectory(id)
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
            state.recordLocalSession(answer.sessionID, for: id)
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
            // A navigation that cancels this read is still "not sent", with the same detail as the generation check.
            let result: [String: Any]?
            do {
                result = try await webView.callAsyncJavaScript(script.sendReadiness, arguments: ["text": text, "expectedURL": expectedURL], in: nil, contentWorld: .defaultClient) as? [String: Any]
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

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if webView === self.webView {
            navigationGeneration += 1; loading = true; snapshot = WebPageSnapshot(); if provider != .dots { clearAvatar() }
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
            navigationGeneration += 1; loading = false; snapshot = WebPageSnapshot(); if provider != .dots { clearAvatar() }
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
    private func sendGrokBot(_ text: String, comparisonID: UUID?) async -> WebSendAttempt? {
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
            guard state.draft.isEmpty || state.draft == text else { throw WebSessionFailure.notSent("Grok Bot has a draft. Send or clear it before using the shared composer.") }
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
            if state.draft == text { state.draft = ""; state.localDrafts[comparisonID.uuidString] = ""; try save() }
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
