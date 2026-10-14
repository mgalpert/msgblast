import Foundation

public enum AgentGridID: Codable, Hashable, Sendable, Identifiable {
    case web(WebProvider)
    case webInstance(WebAgentID)
    case messages(UUID)
    case featuredMessages(OnboardingChoice)
    case runtime(LocalAgentRuntime)

    public var id: String {
        switch self {
        case .web(let provider): "web:\(provider.rawValue)"
        case .webInstance(let agent): "web-instance:\(agent.id)"
        case .messages(let id): "messages:\(id.uuidString)"
        case .featuredMessages(let choice): "featured:\(choice.rawValue)"
        case .runtime(let runtime): "runtime:\(runtime.rawValue)"
        }
    }
}

public extension WebAgentID {
    var gridID: AgentGridID { instance == nil ? .web(provider) : .webInstance(self) }
}

// Membership here controls the picker, not account configuration or chat history.
public struct AgentGridLayout: Codable, Equatable, Sendable {
    public static let featured: [AgentGridID] = [
        .web(.muse), .web(.chatgpt), .web(.claude), .web(.grok), .web(.codexCLI), .web(.dshCLI), .web(.dots), .web(.os3),
        .featuredMessages(.instinct), .featuredMessages(.fo), .featuredMessages(.szn)
    ]
    public private(set) var visibleIDs: [AgentGridID]

    public init(visibleIDs: [AgentGridID]) {
        var seen: Set<AgentGridID> = []
        self.visibleIDs = visibleIDs.filter { seen.insert($0).inserted }
    }

    public init(onboarding: OnboardingState, messageGridIDs: [UUID: AgentGridID]) {
        let selected = onboarding.selected
        let choices: [AgentGridID] = OnboardingChoice.allCases.compactMap { choice in
            guard selected.contains(choice) else { return nil }
            if let provider = choice.provider { return .web(provider) }
            if let runtime = choice.runtime { return .runtime(runtime) }
            guard let id = onboarding.messageAgentIDs[choice.rawValue] else { return nil }
            return messageGridIDs[id] ?? .messages(id)
        }
        let excluded = Set(onboarding.excludedDiscoveredMessageAgentIDs ?? [])
        self.init(visibleIDs: choices + (onboarding.discoveredMessageAgentIDs ?? []).filter { !excluded.contains($0) }.map { messageGridIDs[$0] ?? .messages($0) })
    }

    public func shown(in catalog: [AgentGridID]) -> [AgentGridID] {
        let available = Set(catalog)
        return visibleIDs.filter { available.contains($0) }
    }

    public func available(in catalog: [AgentGridID]) -> [AgentGridID] {
        let shown = Set(visibleIDs)
        return catalog.filter { !shown.contains($0) }
    }

    public mutating func add(_ id: AgentGridID) {
        if !visibleIDs.contains(id) { visibleIDs.insert(id, at: 0) }
    }

    public mutating func hide(_ id: AgentGridID) { visibleIDs.removeAll { $0 == id } }

    public mutating func move(_ id: AgentGridID, to target: AgentGridID) {
        guard id != target, let source = visibleIDs.firstIndex(of: id),
              let destination = visibleIDs.firstIndex(of: target) else { return }
        visibleIDs.remove(at: source)
        visibleIDs.insert(id, at: destination)
    }
}
