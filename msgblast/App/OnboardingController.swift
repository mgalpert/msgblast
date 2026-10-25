import AppKit
import Combine
import msgblastCore

@MainActor
final class OnboardingController: ObservableObject {
    unowned let model: AppModel
    @Published private(set) var checking = false
    @Published private(set) var compatibility: [WebProvider: Bool] = [:]
    @Published private(set) var desktopInstallations: [WebProvider: DesktopAppInstallation] = [:]
    @Published var error: String?
    @Published var browserSource: BrowserLoginSource?
    @Published private(set) var browserProfiles: [BrowserLoginProfile] = []
    @Published private(set) var browserImportNotice: String?
    let messagesPermissions = AppPermissions()
    let appPermissions: CuaPermissionsController
    @Published private(set) var checkingPermissions = false
    private var browserTask: Task<Void, Never>?
    private var checkGeneration = UUID()

    init(model: AppModel, appPermissions: CuaPermissionsController? = nil) {
        self.model = model
        self.appPermissions = appPermissions ?? CuaPermissionsController(demoInitiallyAllowed: !model.onboardingPermissionsPreview)
    }
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

    var permissionReadiness: OnboardingPermissionReadiness {
        .init(fullDiskAccess: messagesPermissions.history == .allowed,
              contacts: messagesPermissions.contacts == .allowed,
              automation: messagesPermissions.sending == .allowed,
              hostAccessibility: appPermissions.hostAccessibility == .allowed,
              screenCapture: appPermissions.windowCapture == .allowed,
              driverInstalled: appPermissions.installed)
    }
    var permissionSetupReady: Bool { permissionReadiness.canContinue }
    private var permissionReviewRequired: Bool { messagesPermissions.requiresReview || !permissionReadiness.appsReady }
    var permissionChecksBusy: Bool {
        checkingPermissions || messagesPermissions.checkingSending || messagesPermissions.requestingContacts || appPermissions.checking ||
        messagesPermissions.history == .checking || messagesPermissions.contacts == .checking || messagesPermissions.sending == .checking ||
        appPermissions.hostAccessibility == .checking || appPermissions.windowCapture == .checking
    }

    func resumePermissionsAtLaunch() async {
        await refreshPermissions()
        guard model.state.onboarding == nil || state.isFinished,
              state.permissionsSkipped != true, permissionReviewRequired else { return }
        checkpointPermissionChange()
    }

    func refreshPermissions() async {
        guard !checkingPermissions else { return }
        checkingPermissions = true
        defer { checkingPermissions = false }
        await messagesPermissions.refresh(model: model)
        await appPermissions.refresh(demo: model.demo)
        // Saved sections describe completed setup, never a cached permission
        // grant. Revalidate them whenever the app returns from System Settings.
        if state.permissionsCompleted == true {
            let sections = permissionReadiness.completedSections
            var next = state
            if permissionReviewRequired && next.permissionsSkipped != true { next.preparePermissionChange() }
            next.revalidatePermissionSections(sections)
            if !next.isFinished {
                next.completed = next.completed.filter { choice in
                    if choice.isMessages { return sections.contains(.messaging) }
                    if choice.provider?.desktopApp != nil { return sections.contains(.apps) }
                    return true
                }
            }
            if next != state {
                // Revoked access must stay revoked in memory even when storage
                // fails. A saved checkpoint is never authority to use an app.
                model.state.onboarding = next
                do { try model.save() }
                catch { self.error = "Could not save setup progress: \(error.localizedDescription)" }
            }
        }
    }

    func finishPermissionSetup() async {
        guard !permissionChecksBusy, !model.busy, !model.webBroadcastBusy else { return }
        await refreshPermissions()
        let ready = permissionReadiness
        guard permissionSetupReady else { return }
        error = nil
        edit { $0.completePermissions(messaging: ready.messagingReady, apps: ready.appsReady) }
        await addMessagesAutomatically()
    }

    func skipPermissionSetup() async {
        guard !permissionChecksBusy, !model.busy, !model.webBroadcastBusy else { return }
        await refreshPermissions()
        let ready = permissionReadiness
        error = nil
        edit { $0.skipPermissions(messaging: ready.messagingReady, apps: ready.appsReady) }
        await addMessagesAutomatically()
    }

    @discardableResult
    func checkpointPermissionChange() -> Bool {
        guard !model.busy, !model.webBroadcastBusy else { return false }
        let previous = model.state.onboarding
        let previousGrid = model.state.agentGrid
        var next = previous ?? OnboardingState()
        if previous == nil {
            // Existing users may predate onboarding. A permission restart must
            // preserve their inferred workspace, not treat them as a new user.
            model.state.agentGrid = previousGrid ?? model.agentGridLayout
            next.stage = .finished
        }
        next.preparePermissionChange()
        model.state.onboarding = next
        do { try model.saveForTermination(); error = nil; return true }
        catch {
            model.state.onboarding = previous
            model.state.agentGrid = previousGrid
            self.error = "Could not save setup progress: \(error.localizedDescription)"
            return false
        }
    }

    func reviewPermissions() {
        invalidateCheck()
        model.accessGuide.cancel()
        edit { $0.preparePermissionChange() }
    }

    func reviewStats() {
        guard checkpointPermissionChange() else { return }
        model.reviewingSharingChoice = true
    }

    func completePrerequisites(discoverMessages: Bool = false) {
        error = nil
        edit {
            $0.prerequisitesCompleted = true
            if discoverMessages, $0.messagesDiscoveryReviewed == nil { $0.messagesDiscoveryReviewed = false }
        }
    }

    func restartForAccess() {
        guard checkpointPermissionChange() else { return }
        model.onboardingRestartRequested = true
        NSApp.terminate(nil)
    }

    func begin() {
        guard !state.needsPermissionSetup, !permissionChecksBusy else { return }
        let sections = state.approvedPermissionSections ?? []
        guard state.availableSelected.allSatisfy({ choice in
            if choice.isMessages { return sections.contains(.messaging) }
            if choice.provider?.desktopApp != nil { return sections.contains(.apps) }
            return true
        }) else { return }
        error = nil
        browserImportNotice = nil
        invalidateCheck()
        // Saved completion survives permission restarts; live readiness does not.
        // Return only stale app checks to the connection step.
        let stale = Set(state.completed.intersection(state.availableSelected).filter { choice in
            guard let provider = choice.provider, provider.desktopApp != nil else { return false }
            return !isReady(session(for: provider))
        })
        edit { $0.completed.subtract(stale); $0.begin() }
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

    var unresolvedMessageAgents: [Agent] {
        guard model.databaseAvailable else { return [] }
        return state.unresolvedMessageAgents(in: model.state.agents, chats: model.chats,
                                             selectedIDs: model.state.selection)
    }
    var setupReminderNames: [String] {
        let selectedProviders = Set(model.webAgents.sessions.filter {
            $0.isEnabled && $0.state.selected && model.isVisibleInAgentGrid($0.id.gridID) && !isReady($0)
        }.map(\.provider))
        let other = state.connectionReminderChoices(selectedProviders: selectedProviders).map(\.name)
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
        next.messagesAutomaticallyAdded = false
        next.preparePermissionChange()
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
        guard state.stage == .feedback, !checking, !permissionChecksBusy else { return }
        checking = true
        let generation = UUID()
        checkGeneration = generation
        defer { if checkGeneration == generation { checking = false } }
        await refreshPermissions()
        guard checkGeneration == generation, !state.needsPermissionSetup,
              permissionReadiness.canContinue || state.permissionsSkipped == true else { return }
        model.refresh()
        var hasUsableAgent = false
        var checkedChoices: Set<OnboardingChoice> = []
        for choice in OnboardingChoice.allCases where state.completed.intersection(state.selected).contains(choice) {
            checkedChoices.insert(choice)
            if let provider = choice.provider {
                if provider.desktopApp != nil, !permissionReadiness.appsReady { continue }
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
                guard permissionReadiness.messagingReady else { continue }
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
        guard state.stage == .connecting, (state.approvedPermissionSections ?? []).contains(.apps),
              state.pendingChoices.contains(where: { $0.provider == session.provider }), session.provider.desktopApp != nil else { return }
        session.refreshDesktopInstallation()
        guard session.desktopInstallation.isInstalled else { return }
        if !session.isEnabled { session.setEnabled(true); session.updateState { $0.selected = false } }
        // Checking a saved binding can start Cua's permission gate. Desktop
        // onboarding waits for the user's explicit connection check.
    }

    var pendingDesktopSessions: [WebAgentSession] {
        state.pendingChoices.compactMap(\.provider).filter { $0.desktopApp != nil }.map { session(for: $0) }
    }

    func completeDesktopConnections(checked: Set<WebProvider>, skipped: Set<WebProvider>) {
        guard state.stage == .connecting, case .agent(let current) = state.currentStep,
              current.desktopApp != nil, !checking, !permissionChecksBusy, !model.busy, !model.webBroadcastBusy else { return }
        let sessions = pendingDesktopSessions
        guard !sessions.isEmpty, sessions.allSatisfy({ session in
            !session.loading && !session.isSending && (skipped.contains(session.provider) || ((state.approvedPermissionSections ?? []).contains(.apps) && checked.contains(session.provider) && isReady(session)))
        }) else { return }
        let completed = Set(sessions.filter { !skipped.contains($0.provider) }.map(\.provider))
        edit { next in
            for choice in next.pendingChoices {
                guard let provider = choice.provider, provider.desktopApp != nil else { continue }
                if completed.contains(provider) { next.complete(choice) }
                else if skipped.contains(provider) { next.skip(choice) }
            }
        }
    }

    func refreshDesktopInstallations() {
        for provider in WebProvider.allCases where provider.desktopApp != nil {
            let session = session(for: provider)
            session.refreshDesktopInstallation()
            desktopInstallations[provider] = session.desktopInstallation
        }
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

    // Discovery adds existing, routable Contacts entries to setup, never creates
    // Contacts or selects recipients. A saved completion preserves later opt-outs.
    func addMessagesAutomatically(suggestions: [Agent]? = nil) async {
        guard state.stage == .choosing, !state.needsPermissionSetup,
              state.messagesAutomaticallyAdded != true, !checking, !model.busy,
              (state.approvedPermissionSections ?? []).contains(.messaging) else { return }
        checking = true
        error = nil
        let generation = checkGeneration
        defer { if checkGeneration == generation { checking = false } }
        do {
            let agents: [Agent]
            if let suggestions { agents = suggestions }
            else { agents = try await model.onboardingContactSuggestions() }
            for agent in agents {
                guard !Task.isCancelled, checkGeneration == generation, state.stage == .choosing,
                      !state.needsPermissionSetup,
                      (state.approvedPermissionSections ?? []).contains(.messaging) else { return }
                guard agent.contactID != nil, model.route(agent) != nil else { continue }
                if let saved = model.savedAgent(matching: agent),
                   (state.excludedDiscoveredMessageAgentIDs ?? []).contains(saved.id) { continue }
                await model.addAgent(agent)
                guard model.contactStatus.isEmpty, let saved = model.savedAgent(matching: agent) else {
                    error = model.contactStatus
                    return
                }
                let choice = OnboardingChoice.allCases.first { !$0.contactSuggestions(in: [saved]).isEmpty } ?? .otherMessages
                edit {
                    $0.selected.insert(choice)
                    $0.messageAgentIDs[choice.rawValue] = saved.id
                    if !($0.discoveredMessageAgentIDs ?? []).contains(saved.id) {
                        $0.discoveredMessageAgentIDs = ($0.discoveredMessageAgentIDs ?? []) + [saved.id]
                    }
                    $0.completed.insert(choice)
                    $0.skipped.remove(choice)
                }
                if error != nil { return }
            }
            guard !Task.isCancelled, checkGeneration == generation, state.stage == .choosing else { return }
            edit {
                $0.messagesAutomaticallyAdded = true
                $0.messagesDiscoveryReviewed = true
            }
        } catch { self.error = "Couldn’t add your Messages agents: \(error.localizedDescription)" }
    }

    func toggleChoice(_ choice: OnboardingChoice) {
        edit { next in
            next.toggle(choice)
            guard choice.isMessages else { return }
            let ids = model.state.agents.filter { agent in
                choice.contactSuggestions(in: [agent]).isEmpty == false || next.messageAgentIDs[choice.rawValue] == agent.id
            }.map(\.id)
            var excluded = Set(next.excludedDiscoveredMessageAgentIDs ?? [])
            if next.selected.contains(choice) { excluded.subtract(ids) }
            else { excluded.formUnion(ids) }
            next.excludedDiscoveredMessageAgentIDs = Array(excluded)
        }
    }

    // Older checkpoints may still contain a Messages step. Resolve it without
    // resurrecting the removed discovery or conversation-picker screens.
    func resolveMessagesAutomatically() async {
        guard state.currentStep == .messages, !checking, !model.busy,
              !state.needsPermissionSetup,
              (state.approvedPermissionSections ?? []).contains(.messaging) else { return }
        checking = true
        error = nil
        let generation = checkGeneration
        defer { if checkGeneration == generation { checking = false } }
        do {
            let contacts = try await model.onboardingContactSuggestions()
            var connected: Set<OnboardingChoice> = []
            for choice in state.selected.filter(\.isMessages) {
                guard !Task.isCancelled, checkGeneration == generation, state.currentStep == .messages else { return }
                if let saved = candidate(for: choice), model.route(saved) != nil {
                    connected.insert(choice)
                    continue
                }
                guard let agent = choice.contactSuggestions(in: contacts).first(where: { model.route($0) != nil }) else { continue }
                await model.addAgent(agent)
                guard model.contactStatus.isEmpty, let saved = model.savedAgent(matching: agent) else { return }
                edit { $0.messageAgentIDs[choice.rawValue] = saved.id }
                connected.insert(choice)
            }
            guard !Task.isCancelled, checkGeneration == generation, state.currentStep == .messages,
                  !state.needsPermissionSetup,
                  (state.approvedPermissionSections ?? []).contains(.messaging) else { return }
            edit {
                $0.messagesDiscoveryReviewed = true
                $0.confirmMessages(connected: connected, skipped: Set($0.selected.filter(\.isMessages)).subtracting(connected))
            }
        } catch {
            self.error = "Couldn’t connect your Messages agents: \(error.localizedDescription)"
            edit { $0.stage = .choosing }
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
