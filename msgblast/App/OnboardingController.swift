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
        let previousGrid = model.state.agentGrid
        change(&next)
        if next.isFinished {
            if !previous.isFinished {
                let setupGrid = AgentGridLayout(onboarding: next, messageGridIDs: model.messageGridIDs)
                if var grid = model.state.agentGrid {
                    for id in setupGrid.visibleIDs.reversed() { grid.add(id) }
                    model.state.agentGrid = grid
                } else {
                    model.state.agentGrid = setupGrid
                }
            }
        }
        model.state.onboarding = next
        do { try model.save() }
        catch {
            model.state.onboarding = previous
            model.state.agentGrid = previousGrid
            self.error = "Could not save setup progress: \(error.localizedDescription)"
        }
        model.telemetryHeartbeat()
    }

    func completePrerequisites(discoverMessages: Bool = false) {
        error = nil
        edit {
            $0.prerequisitesCompleted = true
            if discoverMessages, $0.messagesDiscoveryReviewed == nil { $0.messagesDiscoveryReviewed = false }
        }
    }

    func restartForAccess() {
        guard !model.busy, !model.webBroadcastBusy else { return }
        error = nil
        let previous = model.state.onboarding
        model.state.onboarding?.prerequisitesCompleted = false
        do {
            try model.saveForTermination()
        } catch {
            model.state.onboarding = previous
            self.error = "Could not save setup progress: \(error.localizedDescription)"
            return
        }
        model.onboardingRestartRequested = true
        NSApp.terminate(nil)
    }

    func begin() {
        error = nil
        browserImportNotice = nil
        invalidateCheck()
        edit { $0.begin() }
    }

    func back() {
        invalidateCheck()
        model.accessGuide.cancel()
        edit {
            if $0.connector == .messages { $0.reviewMessages(prerequisitesReady: $0.prerequisitesCompleted == true) }
            else { $0.chooseAgain() }
        }
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
        invalidateCheck()
        edit { $0.resume() }
    }

    var unresolvedMessageAgents: [Agent] { state.unresolvedMessageAgents(in: model.state.agents, chats: model.chats) }
    var setupReminderNames: [String] {
        let other = state.skipped.intersection(state.selected).filter { choice in
            if choice.isMessages { return candidate(for: choice) == nil }
            if let provider = choice.provider { return !isReady(session(for: provider)) }
            return true
        }.map { $0 == .otherMessages ? "Messages contact" : $0.name }
        return Array(Set(unresolvedMessageAgents.map(\.name) + other)).sorted()
    }

    func reviewMessagesAgents() {
        invalidateCheck()
        model.refresh()
        let previous = model.state.onboarding
        let previousGrid = model.state.agentGrid
        let preservedGrid = model.agentGridLayout
        var next = previous ?? OnboardingState()
        next.reviewMessages(prerequisitesReady: false)
        model.state.agentGrid = previousGrid ?? preservedGrid
        model.state.onboarding = next
        do { try model.save() }
        catch { model.state.onboarding = previous; model.state.agentGrid = previousGrid; self.error = "Could not save setup progress: \(error.localizedDescription)" }
        model.telemetryHeartbeat()
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
                        ? [BrowserLoginProfile(id: "demo", name: "Alex (Personal)"), BrowserLoginProfile(id: "signed-out", name: "Jordan (Work)")]
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
        let telemetryStarted = Date()
        guard state.stage == .feedback, !checking else { return }
        checking = true
        let generation = UUID()
        checkGeneration = generation
        defer { if checkGeneration == generation { checking = false } }
        model.refresh()
        var hasUsableAgent = false
        var checkedChoices: Set<OnboardingChoice> = []
        for choice in OnboardingChoice.allCases where state.completed.intersection(state.selected).contains(choice) {
            checkedChoices.insert(choice)
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
            edit { $0.completed.subtract(checkedChoices); $0.chooseAgain() }
            error = "Connect at least one agent before starting a chat."
            return
        }
        edit { $0.finish() }
        if state.isFinished {
            model.recordTelemetry(.onboardingCompleted)
            model.recordOperation(.setup, success: true, started: telemetryStarted)
            model.telemetryHeartbeat()
        }
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

    func prepareDesktopConnection(_ session: WebAgentSession) {
        guard state.stage == .connecting, state.currentStep == .agent(session.provider), session.provider.desktopApp != nil else { return }
        if !session.isEnabled { session.setEnabled(true); session.updateState { $0.selected = false } }
        // Checking a saved binding can start Cua's permission gate. Desktop
        // onboarding waits for the user's explicit Connect/Reconnect action.
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
        edit { $0.complete(choice) }
    }

    func candidate(for choice: OnboardingChoice) -> Agent? {
        guard let id = state.messageAgentIDs[choice.rawValue] else { return nil }
        return model.state.agents.first { $0.id == id }
    }

    func connectDiscoveredMessage(_ agent: Agent, choice: OnboardingChoice) async {
        guard state.messagesDiscoveryReviewed == false, !model.busy else { return }
        if let saved = model.savedAgent(matching: agent), (state.excludedDiscoveredMessageAgentIDs ?? []).contains(saved.id) { return }
        await model.addAgent(agent)
        model.matchConversationAutomatically(for: agent)
        guard !Task.isCancelled, state.messagesDiscoveryReviewed == false,
              model.contactStatus.isEmpty, let saved = model.savedAgent(matching: agent) else { return }
        let ready = model.route(saved) != nil
        edit {
            $0.selected.insert(choice)
            // Keep a usable representative when several contacts share Other Messages.
            if ready || !$0.completed.contains(choice) { $0.messageAgentIDs[choice.rawValue] = saved.id }
            if !($0.discoveredMessageAgentIDs ?? []).contains(saved.id) {
                $0.discoveredMessageAgentIDs = ($0.discoveredMessageAgentIDs ?? []) + [saved.id]
            }
            if ready {
                $0.completed.insert(choice)
                $0.skipped.remove(choice)
            }
        }
    }

    func toggleDiscoveredMessage(_ agent: Agent) async {
        guard let saved = model.savedAgent(matching: agent), !model.busy else { return }
        if (state.excludedDiscoveredMessageAgentIDs ?? []).contains(saved.id) {
            edit { $0.excludedDiscoveredMessageAgentIDs?.removeAll { $0 == saved.id } }
            let choice = OnboardingChoice.allCases.first { !$0.contactSuggestions(in: [saved]).isEmpty } ?? .otherMessages
            await connectDiscoveredMessage(saved, choice: choice)
        } else {
            let available = Set(model.state.agents.filter { model.route($0) != nil }.map(\.id))
            edit { $0.excludeDiscoveredMessageAgent(saved.id, agents: model.state.agents, availableIDs: available) }
        }
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

}
