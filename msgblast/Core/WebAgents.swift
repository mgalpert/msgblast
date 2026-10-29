import Combine
import Foundation

@MainActor
public final class WebAgents: ObservableObject {
    @Published public private(set) var sessions: [WebAgentSession]
    private let workspaceSession: WebAgentSession
    private let directory: URL
    private var configurations: [WebAgentConfiguration] = []
    private var preparation: Task<[WebAgentID: Bool]?, Never>?
    private(set) var preparationID: UUID?
    private var shuttingDown = false
    @Published public private(set) var configurationError: String?
    private var registryURL: URL { directory.appendingPathComponent("web-agent-instances.json") }
    public let fixture: Bool
    private var subscriptions: Set<AnyCancellable> = []
    @Published private var archivedAgents: Set<WebAgentID> = []
    public var availableSessions: [WebAgentSession] { sessions.filter { $0.isEnabled } }
    public var selected: [WebAgentSession] { availableSessions.filter { $0.state.selected && $0.provider.supportsSharedSubmissions } }
    public var broadcastSelection: [WebAgentSession] { selected.filter { !isBusyForSelection($0) } }

    public func isBusyForSelection(_ session: WebAgentSession) -> Bool {
        if session.isSending { return true }
        guard let app = session.provider.desktopApp else { return false }
        return sessions.contains { $0.provider.desktopApp?.bundleID == app.bundleID &&
            ($0.isSending || $0.incompleteDesktopAttempt != nil) }
    }
    public var displayed: [WebAgentSession] {
        let hasBothSavedChats = Self.hasConflictingNativeRecipients(archivedAgents.map(\.provider))
        return sessions.filter { ($0.isEnabled && $0.state.selected) || (!$0.isEnabled && archivedAgents.contains($0.id)) ||
            (hasBothSavedChats && archivedAgents.contains($0.id) && [.chatgptApp, .dotsApp].contains($0.provider)) }
    }
    public var comparisonID: UUID? { workspaceSession.state.comparisonID }
    public init(directory: URL, fixture: Bool, websiteOptInRequired: Bool = false) {
        self.fixture = fixture
        self.directory = directory
        var migrationErrors: [WebProvider: String] = [:]
        for pair in WebProviderStateMigration.pairs {
            do { try WebProviderStateMigration.migrate(web: pair.web, native: pair.native, directory: directory) }
            catch {
                let message = "Saved \(pair.web.name)/\(pair.native.name) history could not be separated. Original files have been preserved: \(error.localizedDescription)"
                migrationErrors[pair.web] = message
                migrationErrors[pair.native] = message
            }
        }
        let defaults = WebProvider.allCases.map { provider in
            let url = directory.appendingPathComponent(provider.storageFilename)
            let existed = FileManager.default.fileExists(atPath: url.path)
            let session = WebAgentSession(provider: provider, storageURL: url, fixture: fixture, migrationError: migrationErrors[provider])
            // Only fresh accounts opt in. Existing histories and explicit choices survive upgrades.
            if websiteOptInRequired, !existed, WebProvider.settingsOnlyWebProviders.contains(provider) {
                session.setEnabled(false)
            }
            return session
        }
        sessions = defaults
        workspaceSession = defaults.first { $0.provider == .muse }!
        do {
            let url = directory.appendingPathComponent("web-agent-instances.json")
            let saved = try JSONDecoder().decode([WebAgentConfiguration].self, from: Data(contentsOf: url))
            guard Set(saved.map(\.id)).count == saved.count,
                  saved.allSatisfy({ $0.id.instance != nil && ($0.id.provider.supportsCopies || $0.id.provider == .grokbot) }) else {
                throw WebAgentConfigurationError.invalidRegistry
            }
            configurations = saved
            for configuration in saved {
                sessions.append(WebAgentSession(provider: configuration.id.provider,
                    storageURL: directory.appendingPathComponent(configuration.filename), fixture: fixture,
                    agentID: configuration.id, accountID: configuration.accountID))
            }
        } catch CocoaError.fileReadNoSuchFile {
            // No copies have been saved yet.
        } catch {
            configurationError = "Saved agent copies could not be read. The original file has been preserved: \(error.localizedDescription)"
        }
        for session in sessions { observe(session) }
        setComparison(workspaceSession.state.comparisonID)
        // Older saved selections may contain both recipients. Keep ChatGPT
        // selected on startup; the user can switch to Dots at any time.
        if sessions.contains(where: { $0.provider == .chatgptApp && $0.isEnabled && $0.state.selected }),
           let dots = sessions.first(where: { $0.provider == .dotsApp && $0.isEnabled && $0.state.selected }) {
            dots.updateState { $0.selected = false }
        }
    }
    private func observe(_ session: WebAgentSession) {
        session.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
    }
    public func session(for id: WebAgentID) -> WebAgentSession? { sessions.first { $0.id == id } }
    public func session(for gridID: AgentGridID) -> WebAgentSession? {
        switch gridID {
        case .web(let provider): session(for: WebAgentID(provider: provider))
        case .webInstance(let id): session(for: id)
        default: nil
        }
    }
    public func name(for id: WebAgentID) -> String { session(for: id)?.name ?? id.provider.name }
    @discardableResult
    public func duplicate(_ source: WebAgentSession, name: String, separateAccount: Bool = false) throws -> WebAgentSession {
        guard source.provider.supportsCopies, sessions.contains(where: { $0 === source }), source.isStorageAvailable else {
            throw WebAgentConfigurationError.unavailable
        }
        return try add(provider: source.provider, name: name, accountID: separateAccount ? UUID() : source.state.sessionID)
    }
    @discardableResult
    public func addGrokBot(name: String) throws -> WebAgentSession {
        try add(provider: .grokbot, name: name, accountID: UUID())
    }
    private func add(provider: WebProvider, name: String, accountID: UUID) throws -> WebAgentSession {
        guard configurationError == nil else { throw WebAgentConfigurationError.invalidRegistry }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { throw WebAgentConfigurationError.invalidName }
        let configuration = WebAgentConfiguration(id: WebAgentID(provider: provider, instance: UUID()), accountID: accountID)
        let session = WebAgentSession(provider: provider, storageURL: directory.appendingPathComponent(configuration.filename),
            fixture: fixture, agentID: configuration.id, accountID: accountID, name: name)
        guard session.isStorageAvailable else { throw WebAgentConfigurationError.unavailable }
        let saved = configurations + [configuration]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(to: registryURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: registryURL.path)
        } catch { session.beginShutdown(); throw error }
        configurations = saved
        session.updateState { $0.comparisonID = comparisonID }
        observe(session)
        sessions.append(session)
        return session
    }
    public func setComparison(_ id: UUID?) {
        if id == nil && !archivedAgents.isEmpty { archivedAgents = [] }
        for session in sessions where session.state.comparisonID != id { session.updateState { $0.comparisonID = id } }
    }
    public func setEnabled(_ enabled: Bool, for provider: WebProvider) {
        guard let session = sessions.first(where: { $0.provider == provider }) else { return }
        session.setEnabled(enabled)
        if enabled { session.connect() }
    }
    public func restoreSelection(for providers: [WebProvider]) {
        restoreSelection(forAgentIDs: providers.map { WebAgentID(provider: $0) })
    }
    public func restoreSelection(forAgentIDs agents: [WebAgentID]) {
        archivedAgents = Set(agents)
        let firstSharedApp = agents.first { [.chatgptApp, .dotsApp].contains($0.provider) && session(for: $0)?.isEnabled == true }
        for session in sessions {
            let selected = session.isEnabled && archivedAgents.contains(session.id) &&
                (![.chatgptApp, .dotsApp].contains(session.provider) || session.id == firstSharedApp)
            session.updateState { $0.selected = selected }
        }
    }
    /// ChatGPT and Dots use the same native app and cannot be recipients together.
    public static func hasConflictingNativeRecipients(_ providers: [WebProvider]) -> Bool {
        providers.contains(.chatgptApp) && providers.contains(.dotsApp)
    }
    public func select(_ session: WebAgentSession, selected: Bool) {
        guard !selected || (session.isEnabled && !isBusyForSelection(session)) else { return }
        if selected, [.chatgptApp, .dotsApp].contains(session.provider) {
            for other in sessions where other !== session && [.chatgptApp, .dotsApp].contains(other.provider) && other.provider != session.provider && other.state.selected {
                other.updateState { $0.selected = false }
            }
        }
        session.updateState { $0.selected = selected }
    }
    public func toggle(_ session: WebAgentSession) {
        guard session.isEnabled, !isBusyForSelection(session) else { return }
        select(session, selected: !session.state.selected)
        if session.state.selected {
            let id = comparisonID
            session.connect(automaticallyRefresh: !session.provider.usesNativeConversation)
            if session.provider.supportsSharedSubmissions {
                Task {
                    guard self.comparisonID == id, session.state.selected else { return }
                    await self.prepareComparison(id, for: [session])
                }
            }
        }
    }
    public func connectSelected() {
        availableSessions.filter { $0.state.selected || $0.incompleteDesktopAttempt != nil }.forEach { $0.connect() }
    }
    public func signInRequired(for sessions: [WebAgentSession]) async -> [WebAgentID] {
        let tasks = sessions.filter { !$0.provider.usesNativeConversation }.map { session in
            Task { @MainActor in (session.id, await session.checkSignIn()) }
        }
        var providers: [WebAgentID] = []
        for task in tasks {
            let (provider, signedIn) = await task.value
            if signedIn == false { providers.append(provider) }
        }
        return providers
    }
    public var hasConnectedWebSessions: Bool { sessions.contains { !$0.provider.usesNativeConversation && $0.connected } }
    public func saveBrowserDrafts() async throws { for session in sessions { try await session.saveBrowserDrafts() } }
    public var hasNativeRequests: Bool { sessions.contains { $0.provider.usesNativeConversation && $0.isSending } }
    /// A private reply may proceed after a broadcast's inputs have finished,
    /// provided no other request owns the same native app surface.
    public func canSendIndependentNativeReply(to session: WebAgentSession, comparisonID: UUID?) -> Bool {
        canUseNativeSurface(to: session, comparisonID: comparisonID) && session.canSubmitNativePrompt
    }
    /// Preparation may still be needed, but another request must not own this app.
    public func canUseNativeSurface(to session: WebAgentSession, comparisonID: UUID?) -> Bool {
        guard sessions.contains(where: { $0 === session }), session.provider.desktopApp != nil,
              session.state.comparisonID == comparisonID else { return false }
        return !isBusyForSelection(session)
    }
    public func beginShutdown() {
        shuttingDown = true
        preparation?.cancel()
        sessions.forEach { $0.beginShutdown() }
    }
    public func cancelAndWait() async {
        beginShutdown()
        _ = await preparation?.value
        for session in sessions { await session.cancelAndWait() }
    }
    private static func executionGroups(_ sessions: [WebAgentSession]) -> [[WebAgentSession]] {
        var groups: [[WebAgentSession]] = []
        for session in sessions {
            if session.provider.desktopApp != nil,
               let index = groups.firstIndex(where: { $0.contains { $0.provider.desktopApp != nil } }) {
                groups[index].append(session)
            } else { groups.append([session]) }
        }
        return groups
    }
    public func prepareComparison(_ id: UUID?, for sessions: [WebAgentSession], startNativeApps: Bool = false, allowSavedPrivateDraft: Bool = false, foregroundPreparation: Bool = false) async -> Bool {
        guard let results = await prepareComparisonRecipients(id, for: sessions, startNativeApps: startNativeApps, allowSavedPrivateDraft: allowSavedPrivateDraft, foregroundPreparation: foregroundPreparation) else { return false }
        return sessions.allSatisfy { results[$0.id] == true }
    }

    /// A nil result means preparation was cancelled or its workspace changed;
    /// individual false values represent recipients that were not ready.
    public func prepareComparisonRecipients(_ id: UUID?, for sessions: [WebAgentSession], startNativeApps: Bool = false, allowSavedPrivateDraft: Bool = false, foregroundPreparation: Bool = false) async -> [WebAgentID: Bool]? {
        guard !shuttingDown else { return nil }
        // Muse stores the workspace identity even when it is deselected.
        setComparison(id)
        let previous = preparation
        let token = UUID()
        let task = Task { @MainActor () -> [WebAgentID: Bool]? in
            _ = await previous?.value
            guard !Task.isCancelled, !self.shuttingDown, self.comparisonID == id else { return nil }
            let tasks = Self.executionGroups(sessions).map { group in Task { @MainActor () -> [WebAgentID: Bool]? in
                var results: [WebAgentID: Bool] = [:]
                for session in group {
                    guard !Task.isCancelled, !self.shuttingDown, self.comparisonID == id else { return nil }
                    results[session.id] = await session.openComparison(id, startNativeApp: startNativeApps, allowSavedPrivateDraft: allowSavedPrivateDraft, foregroundPreparation: foregroundPreparation)
                }
                return results
            } }
            var results: [WebAgentID: Bool] = [:]
            for task in tasks {
                guard let group = await task.value else { return nil }
                results.merge(group) { _, latest in latest }
            }
            guard !Task.isCancelled, !self.shuttingDown, self.comparisonID == id else { return nil }
            return results
        }
        preparation = task
        preparationID = token
        let results = await task.value
        if preparationID == token { preparation = nil; preparationID = nil }
        return results
    }

    /// Prepare each native app immediately before handing it the already-saved prompt.
    /// Other transports can submit concurrently without racing native window focus.
    public func prepareAndSendPlanned(_ text: String, to sessions: [WebAgentSession], comparisonID: UUID,
                                      plannedAttempts: [WebAgentID: UUID],
                                      onInputsFinished: @escaping @MainActor @Sendable () -> Void = {},
                                      onConfirmedSubmission: @escaping @MainActor @Sendable () -> Void = {}) async -> [WebAgentID: WebSendAttempt] {
        guard sessions.allSatisfy({ $0.provider.desktopApp != nil }),
              !Self.hasConflictingNativeRecipients(sessions.map(\.provider)) else {
            var rejected: [WebAgentID: WebSendAttempt] = [:]
            for session in sessions {
                if let id = plannedAttempts[session.id], let attempt = session.failNativePreparation(id, reason: "Choose compatible app agents before sending.") { rejected[session.id] = attempt }
            }
            onInputsFinished()
            return rejected
        }
        var results = await Self.send(to: sessions, onInputsFinished: onInputsFinished) { session, handoff in
            guard let attemptID = plannedAttempts[session.id] else { return nil }
            guard !Task.isCancelled, !self.shuttingDown, self.comparisonID == comparisonID,
                  let ready = await self.prepareComparisonRecipients(comparisonID, for: [session], startNativeApps: true, allowSavedPrivateDraft: true, foregroundPreparation: true),
                  ready[session.id] == true, !Task.isCancelled, !self.shuttingDown, self.comparisonID == comparisonID else {
                let reason = Task.isCancelled || self.shuttingDown ? "Stopped before sending." : session.error ?? session.snapshot.reason
                return session.failNativePreparation(attemptID, reason: reason)
            }
            let attempt = await session.send(text, comparisonID: comparisonID, onSubmissionFinished: handoff,
                                             onConfirmedSubmission: onConfirmedSubmission, plannedAttemptID: attemptID, consumePrivateDraft: false)
            if attempt?.status.confirmsSubmission == true { onConfirmedSubmission() }
            return attempt ?? session.failNativePreparation(attemptID, reason: session.error ?? session.snapshot.reason)
        }
        // Cancellation may stop the scheduler before it reaches later apps.
        for session in sessions where results[session.id] == nil {
            if let id = plannedAttempts[session.id], let attempt = session.failNativePreparation(id, reason: "Stopped before sending.") {
                results[session.id] = attempt
            }
        }
        return results
    }

    public static func send(_ text: String, to sessions: [WebAgentSession], comparisonID: UUID? = nil,
                            onInputsFinished: @escaping @MainActor @Sendable () -> Void = {},
                            onConfirmedSubmission: @escaping @MainActor @Sendable () -> Void = {}) async -> [WebAgentID: WebSendAttempt] {
        guard !hasConflictingNativeRecipients(sessions.map(\.provider)) else {
            var rejected: [WebAgentID: WebSendAttempt] = [:]
            for session in sessions {
                var attempt = WebSendAttempt(text: text, status: .notSent)
                attempt.comparisonID = comparisonID
                attempt.detail = "Choose ChatGPT or Dots before sending."
                rejected[session.id] = attempt
            }
            return rejected
        }
        return await send(to: sessions, onInputsFinished: onInputsFinished) { session, handoff in
            let attempt = await session.send(text, comparisonID: comparisonID, onSubmissionFinished: handoff, onConfirmedSubmission: onConfirmedSubmission, consumePrivateDraft: false)
            if attempt?.status.confirmsSubmission == true { onConfirmedSubmission() }
            return attempt
        }
    }

    static func send(to sessions: [WebAgentSession], onInputsFinished: @escaping @MainActor @Sendable () -> Void = {}, perform: @escaping @MainActor @Sendable (WebAgentSession, @escaping @MainActor @Sendable () -> Void) async -> WebSendAttempt?) async -> [WebAgentID: WebSendAttempt] {
        let operation = WebBroadcastOperation(perform)
        return await withTaskGroup(of: (WebAgentID, WebSendAttempt?).self) { group in
            var otherInputs: [DesktopBroadcastHandoff] = []
            for session in sessions where session.provider.desktopApp == nil {
                let input = DesktopBroadcastHandoff()
                otherInputs.append(input)
                group.addTask { await operation.send(session, input: input) }
            }
            var replies: [String: DesktopBroadcastHandoff] = [:]
            for session in sessions where session.provider.desktopApp != nil {
                // ChatGPT/Dots and copies of a bot share one native surface.
                // Keep that surface owned until its reply has been collected.
                let app = session.provider.desktopApp!.bundleID
                await replies[app]?.wait()
                guard !group.isCancelled else { break }
                let input = DesktopBroadcastHandoff(), reply = DesktopBroadcastHandoff()
                replies[app] = reply
                group.addTask { await operation.send(session, input: input, reply: reply) }
                await input.wait()
            }
            for input in otherInputs {
                guard !group.isCancelled else { break }
                await input.wait()
            }
            if !group.isCancelled { await onInputsFinished() }
            var results: [WebAgentID: WebSendAttempt] = [:]
            for await (id, attempt) in group { results[id] = attempt }
            return results
        }
    }
}

@MainActor
private final class WebBroadcastOperation {
    let perform: @MainActor @Sendable (WebAgentSession, @escaping @MainActor @Sendable () -> Void) async -> WebSendAttempt?
    init(_ perform: @escaping @MainActor @Sendable (WebAgentSession, @escaping @MainActor @Sendable () -> Void) async -> WebSendAttempt?) { self.perform = perform }
    func send(_ session: WebAgentSession, input: DesktopBroadcastHandoff? = nil, reply: DesktopBroadcastHandoff? = nil) async -> (WebAgentID, WebSendAttempt?) {
        defer { input?.finish(); reply?.finish() }
        let attempt = await perform(session, { input?.finish() })
        return (session.id, attempt)
    }
}

@MainActor
private final class DesktopBroadcastHandoff {
    private var finished = false
    private var waiting: CheckedContinuation<Void, Never>?
    func finish() {
        finished = true
        waiting?.resume(); waiting = nil
    }
    func wait() async {
        guard !finished else { return }
        await withCheckedContinuation { waiting = $0 }
    }
}

private struct WebAgentConfiguration: Codable {
    let id: WebAgentID
    let accountID: UUID
    var filename: String { "web-instance-\(id.instance!.uuidString).json" }
}

public enum WebAgentConfigurationError: LocalizedError {
    case invalidName, invalidRegistry, unavailable
    public var errorDescription: String? {
        switch self {
        case .invalidName: "Enter an agent name between 1 and 80 characters."
        case .invalidRegistry: "Saved agent copies are unavailable. Repair their storage before adding another agent."
        case .unavailable: "This agent cannot be copied while its saved state is unavailable."
        }
    }
}
