import Combine
import Foundation

@MainActor
public final class WebAgents: ObservableObject {
    public let sessions: [WebAgentSession]
    private let workspaceSession: WebAgentSession
    public let fixture: Bool
    private var subscriptions: Set<AnyCancellable> = []
    public var selected: [WebAgentSession] { sessions.filter { $0.state.selected } }
    public var comparisonID: UUID? { workspaceSession.state.comparisonID }
    public init(directory: URL, fixture: Bool) {
        self.fixture = fixture
        sessions = WebProvider.allCases.map { WebAgentSession(provider: $0, storageURL: directory.appendingPathComponent($0.storageFilename), fixture: fixture) }
        workspaceSession = sessions.first { $0.provider == .muse }!
        for session in sessions {
            session.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        }
        setComparison(workspaceSession.state.comparisonID)
    }
    public func setComparison(_ id: UUID?) {
        for session in sessions where session.state.comparisonID != id { session.updateState { $0.comparisonID = id } }
    }
    public func toggle(_ session: WebAgentSession) {
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
    public var hasNativeRequests: Bool { sessions.contains { $0.provider.personalAgentProvider != nil && $0.isSending } }
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
