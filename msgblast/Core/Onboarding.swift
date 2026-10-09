import Foundation

public enum OnboardingChoice: String, CaseIterable, Codable, Identifiable, Sendable, Hashable {
    case chatgpt, claude, grokbot, instinct, fo, szn, grok, muse, codexCLI, claudeCode, dots, openclaw, hermes, otherMessages

    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .instinct: "Instinct"
        case .fo: "Fo"
        case .szn: "Szn"
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
        case .instinct, .fo, .szn, .otherMessages, .openclaw, .hermes: nil
        }
    }
    public var runtime: LocalAgentRuntime? {
        switch self { case .openclaw: .openclaw; case .hermes: .hermes; default: nil }
    }
    public var isMessages: Bool {
        switch self { case .instinct, .fo, .szn, .otherMessages: true; default: false }
    }
}

public enum OnboardingStep: Hashable, Sendable {
    case agent(WebProvider)
    case runtime(LocalAgentRuntime)
    case messages
}

public struct OnboardingState: Codable, Equatable, Sendable {
    public enum Stage: String, Codable, Sendable { case choosing, connecting, finished }

    public var selected: Set<OnboardingChoice> = []
    public var completed: Set<OnboardingChoice> = []
    public var skipped: Set<OnboardingChoice> = []
    public var messageAgentIDs: [String: UUID] = [:]
    public var stage: Stage = .choosing

    public init() {}

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
    public var isFinished: Bool { stage == .finished }
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
        stage = .connecting
        finishIfResolved()
    }
    public mutating func chooseAgain() { stage = .choosing }
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
        guard hasConnectedAgent else { return }
        skipped.formUnion(selected.subtracting(completed))
        stage = .finished
    }
    public mutating func resume() {
        skipped.removeAll()
        stage = .choosing
    }
    private mutating func finishIfResolved() {
        if stage == .connecting && pendingSteps.isEmpty {
            stage = hasConnectedAgent ? .finished : .choosing
        }
    }
}
