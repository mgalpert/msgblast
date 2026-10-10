import AppKit
import Combine
import msgblastCore

@MainActor
final class OnboardingController: ObservableObject {
    unowned let model: AppModel
    @Published private(set) var checking = false
    @Published private(set) var compatibility: [WebProvider: Bool] = [:]
    @Published var error: String?
    @Published var browserSource: BrowserLoginSource?
    @Published private(set) var browserProfiles: [BrowserLoginProfile] = []
    @Published private(set) var browserImportNotice: String?
    private var browserTask: Task<Void, Never>?
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
        browserImportNotice = nil
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
        if state.stage == .importing {
            edit { $0.beginConnections() }
            return
        }
        if case .agent(let provider) = state.currentStep {
            model.webAgents.sessions.first { $0.provider == provider }?.updateState { $0.selected = false }
        }
        if state.currentStep == .messages { model.accessGuide.cancel() }
        edit { $0.skipCurrentStep() }
    }

    func resume() {
        edit { $0.resume(); $0.completed = [] }
    }

    func chooseBrowser(_ source: BrowserLoginSource) {
        guard state.stage == .importing, !checking else { return }
        checking = true
        error = nil
        browserSource = source
        let generation = UUID()
        checkGeneration = generation
        browserTask = Task { [weak self] in
            guard let self else { return }
            do {
                let profiles: [BrowserLoginProfile]
                if model.demo {
                    profiles = source == .chrome
                        ? [BrowserLoginProfile(id: "demo", name: "Demo profile"), BrowserLoginProfile(id: "signed-out", name: "Signed-out profile")]
                        : [BrowserLoginProfile(id: "signed-out", name: "Demo Safari")]
                } else {
                    profiles = try await Task.detached(priority: .userInitiated) {
                        try BrowserLoginImporter().profiles(in: source)
                    }.value
                }
                guard checkGeneration == generation, state.stage == .importing else { return }
                checking = false
                if profiles.count == 1, let profile = profiles.first { importBrowserProfile(profile) }
                else if profiles.isEmpty { await finishBrowserImport(notice: "No accounts could be imported from \(source.name). Sign in here to continue.", resetImports: true) }
                else { browserProfiles = profiles }
            } catch {
                guard checkGeneration == generation, state.stage == .importing else { return }
                await finishBrowserImport(notice: "Couldn't access \(source.name). Sign in here to continue.", resetImports: true)
            }
        }
    }

    func cancelBrowserProfileSelection() {
        browserProfiles = []
        browserSource = nil
    }

    func importBrowserProfile(_ profile: BrowserLoginProfile) {
        guard let source = browserSource, state.stage == .importing, !checking else { return }
        let providers = state.pendingWebProviders
        browserProfiles = []
        checking = true
        let generation = UUID()
        checkGeneration = generation
        browserTask = Task { [weak self] in
            guard let self else { return }
            var registered = 0
            do {
                let result: BrowserLoginImportResult
                if model.demo {
                    let cookies = Dictionary(uniqueKeysWithValues: providers.map { provider in
                        let cookie = profile.id == "demo" ? HTTPCookie(properties: [
                            .domain: provider.homeURL.host!, .path: "/", .name: "msgblast_demo_session",
                            .value: "simulated", .secure: true, .expires: Date().addingTimeInterval(3600)
                        ]) : nil
                        return (provider, cookie.map { [$0] } ?? [])
                    })
                    result = BrowserLoginImportResult(cookies: cookies)
                } else {
                    result = try await Task.detached(priority: .userInitiated) {
                        try BrowserLoginImporter().readCookies(in: source, profileID: profile.id, providers: providers)
                    }.value
                }
                guard checkGeneration == generation, state.stage == .importing else { return }
                for provider in WebProvider.allCases where providers.contains(provider) {
                    registered += (try? await session(for: provider).registerBrowserCookies(result.cookies[provider] ?? [])) ?? 0
                    guard checkGeneration == generation, state.stage == .importing else { return }
                }
                await finishBrowserImport(notice: registered == 0 ? "No accounts could be imported from \(source.name). Sign in here to continue." : nil)
            } catch {
                guard checkGeneration == generation, state.stage == .importing else { return }
                await finishBrowserImport(notice: "Couldn't import from \(source.name). Sign in here to continue.", resetImports: true)
            }
        }
    }

    private func finishBrowserImport(notice: String?, resetImports: Bool = false) async {
        let generation = checkGeneration
        checking = true
        if resetImports {
            for provider in state.pendingWebProviders {
                _ = try? await session(for: provider).registerBrowserCookies([])
                guard checkGeneration == generation, state.stage == .importing else { return }
            }
        }
        checking = false
        cancelBrowserProfileSelection()
        browserImportNotice = notice
        edit { $0.beginConnections() }
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
                } else if !provider.usesNativeConversation {
                    guard await session.checkSignIn() == true else { continue }
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
        session.isReadyForOnboarding && (session.provider != .claudeCode || compatibility[.claudeCode] == true)
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
        let choices = Set(state.selected.filter(\.isMessages))
        let selected = selected.intersection(choices)
        if selected.isEmpty {
            model.accessGuide.cancel()
            error = nil
            edit { $0.confirmMessages(connected: [], skipped: choices) }
            return
        }
        model.refresh()
        guard model.databaseAvailable, model.contactsAvailable else { return }
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
        browserTask?.cancel()
        browserTask = nil
        cancelBrowserProfileSelection()
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
