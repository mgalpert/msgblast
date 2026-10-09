import AppKit
import Combine
import msgblastCore

@MainActor
final class OnboardingController: ObservableObject {
    unowned let model: AppModel
    @Published private(set) var checking = false
    @Published private(set) var compatibility: [WebProvider: Bool] = [:]
    @Published var error: String?
    private var checkGeneration = UUID()

    init(model: AppModel) { self.model = model }
    var state: OnboardingState { model.state.onboarding ?? OnboardingState() }

    func edit(_ change: (inout OnboardingState) -> Void) {
        guard var next = model.state.onboarding else { return }
        let previous = next
        change(&next)
        if next.isFinished { restoreRecipients(from: next) }
        model.state.onboarding = next
        do { try model.save() }
        catch {
            model.state.onboarding = previous
            self.error = "Could not save setup progress: \(error.localizedDescription)"
        }
    }

    func begin() {
        error = nil
        invalidateCheck()
        restoreRecipients(from: state)
        edit { $0.begin() }
    }

    func back() {
        invalidateCheck()
        model.accessGuide.cancel()
        edit { $0.chooseAgain() }
    }

    func skip() {
        invalidateCheck()
        if case .agent(let provider) = state.currentStep {
            model.webAgents.sessions.first { $0.provider == provider }?.updateState { $0.selected = false }
        }
        if state.currentStep == .messages { model.accessGuide.cancel() }
        edit { $0.skipCurrentStep() }
    }

    func resume() {
        edit { $0.resume(); $0.completed = [] }
    }

    func finish() async {
        guard state.stage == .feedback, !checking else { return }
        checking = true
        let generation = UUID()
        checkGeneration = generation
        defer { if checkGeneration == generation { checking = false } }
        model.refresh()
        var hasUsableAgent = false
        for choice in OnboardingChoice.allCases where state.completed.intersection(state.selected).contains(choice) {
            if let provider = choice.provider {
                let session = session(for: provider)
                guard session.isEnabled else { continue }
                if provider.personalAgentProvider != nil {
                    guard await session.checkNativeAccount() else { continue }
                    if let supported = await personalAgentCompatibility(for: session) { compatibility[provider] = supported }
                }
                guard checkGeneration == generation, state.stage == .feedback else { return }
                hasUsableAgent = session.isEnabled && isReady(session)
            } else if choice.isMessages {
                model.refresh()
                if model.databaseAvailable, model.contactsAvailable, let agent = candidate(for: choice) {
                    hasUsableAgent = model.route(agent) != nil
                }
            }
            if hasUsableAgent { break }
        }
        guard checkGeneration == generation, state.stage == .feedback else { return }
        guard hasUsableAgent else {
            edit { $0.recheckConnections(); $0.chooseAgain() }
            error = "Connect at least one agent before starting a chat."
            return
        }
        edit { $0.finish() }
        if state.isFinished { model.accessGuide.dismissCompletion() }
    }

    func completeRuntime(_ runtime: LocalAgentRuntime) {
        guard state.stage == .connecting, state.currentStep == .runtime(runtime),
              model.personalAgent.detectedLocalAgents.contains(where: { $0.runtime == runtime }),
              let choice = state.pendingChoices.first(where: { $0.runtime == runtime }) else { return }
        edit { $0.complete(choice) }
    }

    func session(for provider: WebProvider) -> WebAgentSession {
        model.webAgents.sessions.first { $0.provider == provider }!
    }

    func isReady(_ session: WebAgentSession) -> Bool {
        session.snapshot.ready && (session.provider != .claudeCode || compatibility[.claudeCode] == true)
    }

    func refresh(_ session: WebAgentSession) async {
        guard !checking, state.stage == .connecting, state.currentStep == .agent(session.provider) else { return }
        checking = true
        let generation = UUID()
        checkGeneration = generation
        defer { if checkGeneration == generation { checking = false } }
        if session.provider.usesNativeConversation {
            if !session.isEnabled { session.setEnabled(true); session.updateState { $0.selected = false } }
            session.connect()
            await session.refresh()
            let supported = await personalAgentCompatibility(for: session)
            guard checkGeneration == generation else { return }
            if let supported { compatibility[session.provider] = supported }
        } else {
            session.connect()
            _ = await session.checkSignIn()
        }
        guard checkGeneration == generation, state.currentStep == .agent(session.provider) else { return }
        checking = false
        advanceIfReady(session)
    }

    func advanceIfReady(_ session: WebAgentSession) {
        guard !model.onboardingPreview, !checking else { return }
        complete(session)
    }

    func complete(_ session: WebAgentSession) {
        guard state.stage == .connecting, !checking, state.currentStep == .agent(session.provider), isReady(session),
              let choice = state.pendingChoices.first(where: { $0.provider == session.provider }) else { return }
        session.updateState { $0.selected = true }
        edit { $0.complete(choice) }
    }

    func candidate(for choice: OnboardingChoice) -> Agent? {
        guard let id = state.messageAgentIDs[choice.rawValue] else { return nil }
        return model.state.agents.first { $0.id == id }
    }

    func connectMessages(_ contacts: [OnboardingChoice: Agent], selected: Set<OnboardingChoice>) async {
        guard state.stage == .connecting, state.currentStep == .messages, !checking, !model.busy else { return }
        model.refresh()
        guard model.databaseAvailable, model.contactsAvailable else { return }
        let choices = Set(state.selected.filter(\.isMessages))
        let selected = selected.intersection(choices)
        guard selected.allSatisfy({ contacts[$0] != nil }) else { return }
        checking = true
        let generation = UUID()
        checkGeneration = generation
        defer { if checkGeneration == generation { checking = false } }
        error = nil
        var savedIDs: [String: UUID] = [:]
        var connected: Set<OnboardingChoice> = []
        for choice in OnboardingChoice.allCases where selected.contains(choice) {
            guard let candidate = contacts[choice] else { continue }
            await model.addAgent(candidate)
            guard checkGeneration == generation, state.stage == .connecting, state.currentStep == .messages else { return }
            guard model.contactStatus.isEmpty, let saved = model.savedAgent(matching: candidate) else { break }
            savedIDs[choice.rawValue] = saved.id
            model.refresh()
            if model.databaseAvailable, model.contactsAvailable, model.route(saved) != nil { connected.insert(choice) }
        }
        guard checkGeneration == generation, state.stage == .connecting, state.currentStep == .messages else { return }
        model.refresh()
        if !model.databaseAvailable || !model.contactsAvailable { connected = [] }
        edit {
            $0.messageAgentIDs.merge(savedIDs) { _, new in new }
            $0.confirmMessages(connected: connected, skipped: choices.subtracting(selected))
        }
    }

    func openMessages(for agent: Agent) {
        guard !model.demo else { return }
        var parts = URLComponents()
        parts.scheme = "sms"
        parts.path = agent.handles.first ?? ""
        if let url = parts.url { NSWorkspace.shared.open(url) }
    }

    private func personalAgentCompatibility(for session: WebAgentSession) async -> Bool? {
        guard let provider = session.provider.personalAgentProvider else { return nil }
        await model.personalAgent.discover()
        guard provider == .claude else { return nil }
        if session.fixture { return true }
        if let installed = model.personalAgent.installed.first(where: { $0.provider == provider }) {
            return await LocalPersonalAgent.supportsConfiguredConversation(using: installed)
        }
        return nil
    }

    private func invalidateCheck() {
        checkGeneration = UUID()
        checking = false
    }

    private func restoreRecipients(from state: OnboardingState) {
        let connected = state.completed.intersection(state.selected)
        for session in model.webAgents.sessions {
            let selected = connected.contains { $0.provider == session.provider }
            if session.state.selected != selected { session.updateState { $0.selected = selected } }
        }
        model.state.selection = Set(connected.compactMap { state.messageAgentIDs[$0.rawValue] })
    }
}
