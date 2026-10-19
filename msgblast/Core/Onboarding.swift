import Foundation

public enum OnboardingChoice: String, CaseIterable, Codable, Identifiable, Sendable, Hashable {
    case chatgpt, claude, grokbot, muse, instinct, fo, szn, grok, codexCLI, claudeCode, openclaw, dots, hermes, os3, hark, poke, otherMessages, gemini

    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .instinct: "Instinct"
        case .fo: "Fo"
        case .szn: "Szn"
        case .poke: "Poke"
        case .otherMessages: "I use another agent in Messages"
        case .openclaw: "OpenClaw"
        case .hermes: "Hermes"
        default: provider!.name
        }
    }
    public var provider: WebProvider? {
        switch self {
        case .chatgpt: .chatgpt
        case .claude: .claude
        case .grokbot: .grokbot
        case .grok: .grok
        case .muse: .muse
        case .codexCLI: .codexCLI
        case .claudeCode: .claudeCode
        case .dots: .dots
        case .os3: .os3
        case .hark: .hark
        case .gemini: .gemini
        case .instinct, .fo, .szn, .poke, .otherMessages, .openclaw, .hermes: nil
        }
    }
    public var runtime: LocalAgentRuntime? {
        switch self { case .openclaw: .openclaw; case .hermes: .hermes; default: nil }
    }
    public var isMessages: Bool {
        switch self { case .instinct, .fo, .szn, .poke, .otherMessages: true; default: false }
    }

    public func contactSuggestions(in contacts: [Agent]) -> [Agent] {
        guard isMessages, self != .otherMessages else { return [] }
        return contacts.filter { contact in
            contact.contactID != nil && !contact.handles.isEmpty &&
            contact.name.trimmingCharacters(in: self == .poke ? .alphanumerics.inverted : .whitespacesAndNewlines)
                .compare(name, options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")) == .orderedSame
        }
    }
}

public enum OnboardingConnector: String, CaseIterable, Codable, Sendable {
    case messages, apps, clis
    public var name: String { switch self { case .messages: "Messages"; case .apps: "Apps"; case .clis: "CLIs" } }
    public func includes(_ choice: OnboardingChoice) -> Bool {
        switch self {
        case .messages: choice.isMessages
        case .apps: !choice.isMessages && choice.runtime == nil && choice != .codexCLI && choice != .claudeCode
        case .clis: choice.runtime != nil || choice == .codexCLI || choice == .claudeCode
        }
    }
}

public enum OnboardingStep: Hashable, Sendable {
    case agent(WebProvider)
    case runtime(LocalAgentRuntime)
    case messages
}

public struct OnboardingState: Codable, Equatable, Sendable {
    public enum Stage: String, Codable, Sendable { case choosing, importing, connecting, feedback, finished }

    // Optional for compatibility: older saved setups continue at their existing step.
    public var connectorStartCompleted: Bool? = false
    public var connector: OnboardingConnector?
    public var prerequisitesCompleted: Bool? = false
    public var messagesDiscoveryReviewed: Bool?
    public var discoveredMessageAgentIDs: [UUID]?
    public var excludedDiscoveredMessageAgentIDs: [UUID]?
    public var selected: Set<OnboardingChoice> = []
    public var completed: Set<OnboardingChoice> = []
    public var skipped: Set<OnboardingChoice> = []
    public var messageAgentIDs: [String: UUID] = [:]
    public var stage: Stage = .choosing

    public init() {}

    public mutating func chooseConnector(_ connector: OnboardingConnector) {
        self.connector = connector
        connectorStartCompleted = true
        stage = .choosing
        prerequisitesCompleted = connector != .messages
        messagesDiscoveryReviewed = connector == .messages ? false : true
    }

    public var pendingChoices: [OnboardingChoice] {
        OnboardingChoice.allCases.filter { selected.contains($0) && !completed.contains($0) && !skipped.contains($0) }
    }
    public var pendingSteps: [OnboardingStep] {
        let choices = pendingChoices
        let agents = choices.compactMap { choice in
            if let provider = choice.provider { return OnboardingStep.agent(provider) }
            return choice.runtime.map(OnboardingStep.runtime)
        }
        return choices.contains(where: \.isMessages) ? agents + [.messages] : agents
    }
    public var currentStep: OnboardingStep? { pendingSteps.first }
    public var pendingWebProviders: Set<WebProvider> {
        Set(pendingChoices.compactMap(\.provider).filter { !$0.usesNativeConversation })
    }
    public var isFinished: Bool { stage == .finished }
    public var selectedMessageAgentIDs: Set<UUID> {
        Set(selected.filter(\.isMessages).compactMap { messageAgentIDs[$0.rawValue] } + (discoveredMessageAgentIDs ?? []))
            .subtracting(excludedDiscoveredMessageAgentIDs ?? [])
    }
    public func unresolvedMessageAgents(in agents: [Agent], chats: [Chat]) -> [Agent] {
        agents.filter { selectedMessageAgentIDs.contains($0.id) && ChatResolver.resolve(agent: $0, chats: chats) == nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public mutating func excludeDiscoveredMessageAgent(_ id: UUID, agents: [Agent], availableIDs: Set<UUID>) {
        excludedDiscoveredMessageAgentIDs = Array(Set(excludedDiscoveredMessageAgentIDs ?? []).union([id]))
        discoveredMessageAgentIDs?.removeAll { $0 == id }
        for choice in OnboardingChoice.allCases where messageAgentIDs[choice.rawValue] == id {
            messageAgentIDs.removeValue(forKey: choice.rawValue)
            selected.remove(choice); completed.remove(choice); skipped.remove(choice)
            let included = Set(discoveredMessageAgentIDs ?? []).subtracting(excludedDiscoveredMessageAgentIDs ?? [])
            let replacement = agents.filter { agent in
                let category = OnboardingChoice.allCases.first { !$0.contactSuggestions(in: [agent]).isEmpty } ?? .otherMessages
                return included.contains(agent.id) && category == choice
            }.sorted { lhs, rhs in
                if availableIDs.contains(lhs.id) != availableIDs.contains(rhs.id) { return availableIDs.contains(lhs.id) }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }.first
            if let replacement {
                messageAgentIDs[choice.rawValue] = replacement.id
                selected.insert(choice)
                if availableIDs.contains(replacement.id) { completed.insert(choice) }
            }
        }
    }
    public mutating func reviewMessages(prerequisitesReady: Bool) {
        connector = .messages
        connectorStartCompleted = true
        prerequisitesCompleted = prerequisitesReady
        messagesDiscoveryReviewed = false
        stage = .choosing
    }
    public var hasConnectedAgent: Bool {
        completed.intersection(selected).contains { $0.provider != nil || $0.isMessages }
    }

    public mutating func toggle(_ choice: OnboardingChoice) {
        guard stage == .choosing else { return }
        if selected.contains(choice) { selected.remove(choice) } else { selected.insert(choice) }
    }
    public mutating func begin() {
        guard !selected.isEmpty else { return }
        if !hasConnectedAgent && pendingSteps.isEmpty { skipped = [] }
        stage = pendingWebProviders.isEmpty ? .connecting : .importing
        finishIfResolved()
    }
    public mutating func beginConnections() {
        guard stage == .importing else { return }
        stage = .connecting
        finishIfResolved()
    }
    public mutating func reviewMessagesDiscovery() {
        messagesDiscoveryReviewed = true
        // Contacts without a supported conversation remain saved for later setup.
        skipped.formUnion(pendingChoices.filter(\.isMessages))
        if stage == .connecting && currentStep == nil { finishIfResolved() }
        else if stage == .connecting { stage = .choosing }
    }
    public mutating func chooseAgain() {
        stage = .choosing
        if connector == .messages { messagesDiscoveryReviewed = false }
    }
    public mutating func complete(_ choice: OnboardingChoice) {
        guard selected.contains(choice) else { return }
        completed.insert(choice)
        skipped.remove(choice)
        finishIfResolved()
    }
    public mutating func skip(_ choice: OnboardingChoice) {
        guard selected.contains(choice), !completed.contains(choice) else { return }
        skipped.insert(choice)
        finishIfResolved()
    }
    public mutating func confirmMessages(connected: Set<OnboardingChoice>, skipped: Set<OnboardingChoice>) {
        guard stage == .connecting, currentStep == .messages else { return }
        let choices = selected.filter(\.isMessages)
        completed.subtract(choices)
        self.skipped.subtract(choices)
        completed.formUnion(connected.intersection(choices))
        self.skipped.formUnion(skipped.intersection(choices).subtracting(connected))
        finishIfResolved()
    }
    public mutating func skipCurrentStep() {
        guard let currentStep else { return }
        for choice in pendingChoices {
            switch currentStep {
            case .agent(let provider) where choice.provider == provider: skipped.insert(choice)
            case .runtime(let runtime) where choice.runtime == runtime: skipped.insert(choice)
            case .messages where choice.isMessages: skipped.insert(choice)
            default: break
            }
        }
        finishIfResolved()
    }
    public mutating func finish() {
        guard stage == .feedback, hasConnectedAgent, pendingSteps.isEmpty else { return }
        stage = .finished
    }
    public mutating func recheckConnections() {
        guard !isFinished else { return }
        completed = []
        if stage == .feedback { stage = .connecting }
    }
    public mutating func resume() {
        skipped.removeAll()
        stage = .choosing
        connectorStartCompleted = false
    }
    private mutating func finishIfResolved() {
        if stage == .connecting && pendingSteps.isEmpty {
            stage = hasConnectedAgent ? .feedback : .choosing
        }
    }
}
