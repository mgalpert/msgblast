import Combine
import Foundation

@MainActor
public final class WebAgents: ObservableObject {
    public let sessions: [WebAgentSession]
    private let workspaceSession: WebAgentSession
    public let fixture: Bool
    private var subscriptions: Set<AnyCancellable> = []
    @Published private var archivedProviders: Set<WebProvider> = []
    public var availableSessions: [WebAgentSession] { sessions.filter { $0.isEnabled } }
    public var selected: [WebAgentSession] { availableSessions.filter { $0.state.selected } }
    public var displayed: [WebAgentSession] {
        sessions.filter { ($0.isEnabled && $0.state.selected) || (!$0.isEnabled && archivedProviders.contains($0.provider)) }
    }
    public var comparisonID: UUID? { workspaceSession.state.comparisonID }
    public init(directory: URL, fixture: Bool) {
        self.fixture = fixture
        var migrationErrors: [WebProvider: String] = [:]
        for pair in WebProviderStateMigration.pairs {
            do { try WebProviderStateMigration.migrate(web: pair.web, native: pair.native, directory: directory) }
            catch {
                let message = "Saved \(pair.web.name)/\(pair.native.name) history could not be separated. Original files have been preserved: \(error.localizedDescription)"
                migrationErrors[pair.web] = message
                migrationErrors[pair.native] = message
            }
        }
        sessions = WebProvider.allCases.map { WebAgentSession(provider: $0, storageURL: directory.appendingPathComponent($0.storageFilename), fixture: fixture, migrationError: migrationErrors[$0]) }
        workspaceSession = sessions.first { $0.provider == .muse }!
        for session in sessions {
            session.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        }
        setComparison(workspaceSession.state.comparisonID)
    }
    public func setComparison(_ id: UUID?) {
        if id == nil && !archivedProviders.isEmpty { archivedProviders = [] }
        for session in sessions where session.state.comparisonID != id { session.updateState { $0.comparisonID = id } }
    }
    public func setEnabled(_ enabled: Bool, for provider: WebProvider) {
        guard let session = sessions.first(where: { $0.provider == provider }), provider.usesNativeConversation else { return }
        session.setEnabled(enabled)
        if enabled { session.connect() }
    }
    public func restoreSelection(for providers: [WebProvider]) {
        archivedProviders = Set(providers)
        for session in sessions {
            let selected = session.isEnabled && archivedProviders.contains(session.provider)
            session.updateState { $0.selected = selected }
        }
    }
    public func toggle(_ session: WebAgentSession) {
        guard session.isEnabled else { return }
        session.updateState { $0.selected.toggle() }
        if session.state.selected {
            let id = comparisonID
            session.connect()
            Task {
                guard self.comparisonID == id, session.state.selected else { return }
                await session.openComparison(id)
            }
        }
    }
    public func connectSelected() { selected.forEach { $0.connect() } }
    public func signInRequired(for sessions: [WebAgentSession]) async -> [WebProvider] {
        let tasks = sessions.filter { !$0.provider.usesNativeConversation }.map { session in
            Task { @MainActor in (session.provider, await session.checkSignIn()) }
        }
        var providers: [WebProvider] = []
        for task in tasks {
            let (provider, signedIn) = await task.value
            if signedIn == false { providers.append(provider) }
        }
        return providers
    }
    public var hasConnectedWebSessions: Bool { sessions.contains { !$0.provider.usesNativeConversation && $0.connected } }
    public func saveBrowserDrafts() async throws { for session in sessions { try await session.saveBrowserDrafts() } }
    public var hasNativeRequests: Bool { sessions.contains { $0.provider.usesNativeConversation && $0.isSending } }
    public func beginShutdown() { sessions.forEach { $0.beginShutdown() } }
    public func cancelAndWait() async { for session in sessions { await session.cancelAndWait() } }
    public func prepareComparison(_ id: UUID?, for sessions: [WebAgentSession]) async -> Bool {
        // Muse stores the workspace identity even when it is deselected.
        setComparison(id)
        let tasks = sessions.map { session in Task { @MainActor in await session.openComparison(id) } }
        var ready = true
        for task in tasks { if !(await task.value) { ready = false } }
        return ready
    }
    public static func send(_ text: String, to sessions: [WebAgentSession], comparisonID: UUID? = nil) async -> [WebProvider: WebSendAttempt] {
        let tasks = sessions.map { session in Task { @MainActor in (session.provider, await session.send(text, comparisonID: comparisonID)) } }
        var results: [WebProvider: WebSendAttempt] = [:]
        for task in tasks { let (provider, attempt) = await task.value; results[provider] = attempt }
        return results
    }
}
