import Foundation
import msgblastCore

struct AgentGridEntry: Identifiable {
    let id: AgentGridID
    let agent: Agent
    var name: String { agent.name }
}

extension AppModel {
    private var featuredMessageChoices: [OnboardingChoice] {
        AgentGridLayout.featured.compactMap { id in
            guard case .featuredMessages(let choice) = id else { return nil }
            return choice
        }
    }

    func featuredMessageAgent(for choice: OnboardingChoice) -> Agent? {
        onboarding.candidate(for: choice) ?? choice.contactSuggestions(in: state.agents).first
    }

    var messageGridIDs: [UUID: AgentGridID] {
        var result: [UUID: AgentGridID] = [:]
        for agent in state.agents { result[agent.id] = .messages(agent.id) }
        for choice in featuredMessageChoices {
            if let agent = featuredMessageAgent(for: choice), result[agent.id] == .messages(agent.id) {
                result[agent.id] = .featuredMessages(choice)
            }
        }
        return result
    }

    func gridID(for agent: Agent) -> AgentGridID {
        messageGridIDs[agent.id] ?? .messages(agent.id)
    }

    var agentGridCatalog: [AgentGridEntry] {
        let webEntries = webAgents.sessions.map { AgentGridEntry(id: .web($0.provider), agent: AgentArtwork.agent(for: $0)) }
        let featured = featuredMessageChoices.map { choice in
            AgentGridEntry(id: .featuredMessages(choice), agent: featuredMessageAgent(for: choice) ??
                Agent(name: choice.name, handles: [], avatar: AgentArtwork.messageAvatar(for: choice)))
        }
        let ids = messageGridIDs
        let messages = state.agents.compactMap { agent -> AgentGridEntry? in
            guard let id = ids[agent.id], case .messages = id else { return nil }
            return AgentGridEntry(id: .messages(agent.id), agent: agent)
        }
        let local = LocalAgentRuntime.allCases.map { runtime in
            AgentGridEntry(id: .runtime(runtime), agent: Agent(name: runtime.name, handles: [], avatar: AgentArtwork.runtimeAvatar(for: runtime)))
        }
        let all = webEntries + featured + messages + local
        return AgentGridLayout.featured.compactMap { id in all.first { $0.id == id } } +
            all.filter { !AgentGridLayout.featured.contains($0.id) }
    }

    var defaultAgentGrid: AgentGridLayout {
        let ids = messageGridIDs
        let connected = webAgents.availableSessions.map { AgentGridID.web($0.provider) }
        let messages = state.agents.map { ids[$0.id] ?? .messages($0.id) }
        let local = LocalAgentRuntime.allCases.filter { runtime in
            state.onboarding?.completed.contains { $0.runtime == runtime } == true
        }.map(AgentGridID.runtime)
        return AgentGridLayout(visibleIDs: AgentGridLayout.featured + connected + messages + local)
    }

    var agentGridLayout: AgentGridLayout { state.agentGrid ?? defaultAgentGrid }

    @discardableResult
    func setAgentGrid(_ grid: AgentGridLayout) -> Bool {
        let previousGrid = state.agentGrid
        let previousSelection = state.selection
        let changed = Set(agentGridLayout.visibleIDs).symmetricDifference(Set(grid.visibleIDs))
        for id in changed {
            if let agent = messageAgent(for: id) { state.selection.remove(agent.id) }
        }
        state.agentGrid = grid
        do { try save() }
        catch {
            state.agentGrid = previousGrid
            state.selection = previousSelection
            self.error = "Could not save your agent list: \(error.localizedDescription)"
            return false
        }
        // Membership changes never inherit recipient selections from a previous comparison.
        for id in changed {
            if case .web(let provider) = id,
               let session = webAgents.sessions.first(where: { $0.provider == provider }) {
                session.updateState { $0.selected = false }
            }
        }
        return true
    }

    func messageAgent(for id: AgentGridID) -> Agent? {
        switch id {
        case .messages(let id): state.agents.first { $0.id == id }
        case .featuredMessages(let choice): featuredMessageAgent(for: choice)
        default: nil
        }
    }

    func isVisibleInAgentGrid(_ id: AgentGridID) -> Bool { agentGridLayout.visibleIDs.contains(id) }

    func deselectHiddenGridRecipients() {
        let shown = Set(agentGridLayout.visibleIDs)
        let ids = messageGridIDs
        state.selection = state.selection.filter { shown.contains(ids[$0] ?? .messages($0)) }
        for session in webAgents.sessions where session.state.selected && !shown.contains(.web(session.provider)) {
            session.updateState { $0.selected = false }
        }
    }
}
