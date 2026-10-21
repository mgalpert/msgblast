import Combine
import Foundation

@MainActor
public final class WebAgents: ObservableObject {
    @Published public private(set) var sessions: [WebAgentSession]
    private let workspaceSession: WebAgentSession
    private let directory: URL
    private var configurations: [WebAgentConfiguration] = []
    private var preparation: Task<Bool, Never>?
    private(set) var preparationID: UUID?
    private var shuttingDown = false
    @Published public private(set) var configurationError: String?
    private var registryURL: URL { directory.appendingPathComponent("web-agent-instances.json") }
    public let fixture: Bool
    private var subscriptions: Set<AnyCancellable> = []
    @Published private var archivedAgents: Set<WebAgentID> = []
    public var availableSessions: [WebAgentSession] { sessions.filter { $0.isEnabled } }
    public var selected: [WebAgentSession] { availableSessions.filter { $0.state.selected && $0.provider.supportsSharedSubmissions } }
    public var displayed: [WebAgentSession] {
        sessions.filter { ($0.isEnabled && $0.state.selected) || (!$0.isEnabled && archivedAgents.contains($0.id)) }
    }
    public var comparisonID: UUID? { workspaceSession.state.comparisonID }
    public init(directory: URL, fixture: Bool) {
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
        let defaults = WebProvider.allCases.map { WebAgentSession(provider: $0, storageURL: directory.appendingPathComponent($0.storageFilename), fixture: fixture, migrationError: migrationErrors[$0]) }
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
        guard let session = sessions.first(where: { $0.provider == provider }), provider.usesNativeConversation else { return }
        session.setEnabled(enabled)
        if enabled { session.connect() }
    }
    public func restoreSelection(for providers: [WebProvider]) {
        restoreSelection(forAgentIDs: providers.map { WebAgentID(provider: $0) })
    }
    public func restoreSelection(forAgentIDs agents: [WebAgentID]) {
        archivedAgents = Set(agents)
        for session in sessions {
            let selected = session.isEnabled && archivedAgents.contains(session.id)
            session.updateState { $0.selected = selected }
        }
    }
    public func toggle(_ session: WebAgentSession) {
        guard session.isEnabled else { return }
        session.updateState { $0.selected.toggle() }
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
    public func connectSelected() { availableSessions.filter { $0.state.selected }.forEach { $0.connect() } }
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
    public func prepareComparison(_ id: UUID?, for sessions: [WebAgentSession]) async -> Bool {
        guard !shuttingDown else { return false }
        // Muse stores the workspace identity even when it is deselected.
        setComparison(id)
        let previous = preparation
        let token = UUID()
        let task = Task { @MainActor in
            _ = await previous?.value
            guard !Task.isCancelled, !self.shuttingDown, self.comparisonID == id else { return false }
            let tasks = Self.executionGroups(sessions).map { group in Task { @MainActor in
                var ready = true
                for session in group {
                    guard !Task.isCancelled, !self.shuttingDown, self.comparisonID == id else { return false }
                    if !(await session.openComparison(id)) { ready = false }
                }
                return ready
            } }
            var ready = true
            for task in tasks { if !(await task.value) { ready = false } }
            return ready
        }
        preparation = task
        preparationID = token
        let ready = await task.value
        if preparationID == token { preparation = nil; preparationID = nil }
        return ready
    }

    public static func send(_ text: String, to sessions: [WebAgentSession], comparisonID: UUID? = nil) async -> [WebAgentID: WebSendAttempt] {
        let tasks = executionGroups(sessions).map { group in Task { @MainActor in
            var results: [WebAgentID: WebSendAttempt] = [:]
            for session in group { results[session.id] = await session.send(text, comparisonID: comparisonID) }
            return results
        } }
        var results: [WebAgentID: WebSendAttempt] = [:]
        for task in tasks { results.merge(await task.value, uniquingKeysWith: { _, latest in latest }) }
        return results
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
