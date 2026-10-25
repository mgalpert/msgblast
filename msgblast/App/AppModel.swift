import SwiftUI
import AppKit
import msgblastCore

@MainActor
final class AppModel: ObservableObject {
    @Published var state = AppState()
    @Published var chats: [Chat] = []
    @Published var messages: [String: [Message]] = [:]
    @Published var databaseStatus = "Checking Messages history…"
    @Published var databaseAvailable = false
    @Published var error: String?
    @Published var busy = false
    @Published var webBroadcastBusy = false
    @Published var webComparisonRequest = UUID()
    @Published var newBlastRequest = UUID()
    private(set) var newBlastShowsChat = false
    @Published var contactResults: [Agent] = []
    @Published var contactQuery = ""
    @Published var demoFailureOnce = false
    @Published var contactStatus = ""
    @Published private(set) var contactsAvailable = false
    let demo: Bool
    let personalAgent: PersonalAgentController
    lazy var onboarding = OnboardingController(model: self)
    var onboardingPreview: Bool {
        #if DEBUG
        demo && (ProcessInfo.processInfo.arguments.contains("--onboarding-preview") || Bundle.main.object(forInfoDictionaryKey: "msgblastOnboardingPreview") as? Bool == true)
        #else
        false
        #endif
    }
    var onboardingPermissionsPreview: Bool {
        #if DEBUG
        demo && (ProcessInfo.processInfo.arguments.contains("--onboarding-permissions-preview") || Bundle.main.object(forInfoDictionaryKey: "msgblastOnboardingPermissionsPreview") as? Bool == true)
        #else
        false
        #endif
    }
    @Published var reviewingSharingChoice = false
    var onboardingRestartRequested = false
    var needsOnboarding: Bool { state.onboarding.map { !$0.isFinished || $0.needsPermissionSetup } ?? false }
    var usesMessages: Bool {
        (state.onboarding?.stage == .connecting && state.onboarding?.currentStep == .messages) || !state.agents.isEmpty ||
        state.comparisons.contains { !$0.members.isEmpty } || accessGuide.flow.isActive
    }
    var permissionGuidePreview: Bool {
        #if DEBUG
        demo && (ProcessInfo.processInfo.arguments.contains("--permission-guide-preview") || Bundle.main.object(forInfoDictionaryKey: "msgblastPermissionGuidePreview") as? Bool == true)
        #else
        false
        #endif
    }
    let contacts = ContactSearch()
    let linkPreviews = LinkPreviewStore()
    let accessGuide = MessagesAccessGuide(defaults: ProcessInfo.processInfo.arguments.contains("--demo") ? UserDefaults(suiteName: "com.msgblast.demo-permissions") ?? .standard : .standard)
    let local: LocalStore
    lazy var telemetry = TelemetryCollector(endpoint: TelemetryCollector.endpoint(demo: demo), queueURL: local.url.deletingLastPathComponent().appendingPathComponent("telemetry-queue.json"))
    var lastTelemetryInventory: [String: Int]?
    var lastTelemetryActivityDay: Int?
    var telemetryTimer: Timer?
    lazy var webAgents = WebAgents(directory: local.url.deletingLastPathComponent(), fixture: demo && Bundle.main.object(forInfoDictionaryKey: "msgblastLiveWebPreview") as? Bool != true, websiteOptInRequired: true)
    var database: MessagesDatabase?
    var timer: Timer?
    var coordinator: WindowCoordinator?
    var demoRow: Int64 = 100
    private var demoContactsConnected = !ProcessInfo.processInfo.arguments.contains("--contacts-access-preview")
    private var storageLoadFailed = false
    private var lastDataVersion: Int64?
    init() {
        demo = ProcessInfo.processInfo.arguments.contains("--demo") || Bundle.main.object(forInfoDictionaryKey: "msgblastDemo") as? Bool == true
        personalAgent = PersonalAgentController(demo: demo && Bundle.main.object(forInfoDictionaryKey: "msgblastLiveWebPreview") as? Bool != true)
        var fixtureDirectory: URL?
        #if DEBUG
        if UpdateProbe.isLocalFixture, let path = Bundle.main.object(forInfoDictionaryKey: "msgblastFixtureStore") as? String {
            let directory = URL(fileURLWithPath: path).standardizedFileURL
            let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path + "/"
            if directory.path.hasPrefix(temporaryRoot) { fixtureDirectory = directory }
        }
        #endif
        local = LocalStore(demo: demo, isolated: ProcessInfo.processInfo.arguments.contains("--isolated-demo") || Bundle.main.object(forInfoDictionaryKey: "msgblastPermissionGuidePreview") as? Bool == true || Bundle.main.object(forInfoDictionaryKey: "msgblastIsolatedDemo") as? Bool == true, fixtureDirectory: fixtureDirectory, supportDirectoryName: Bundle.main.object(forInfoDictionaryKey: "msgblastSupportDirectory") as? String, webPreview: Bundle.main.object(forInfoDictionaryKey: "msgblastLiveWebPreview") as? Bool == true)
        let existingStore = FileManager.default.fileExists(atPath: local.url.path)
        do {
            state = try local.load()
            if !existingStore && (!demo || onboardingPreview) { state.onboarding = OnboardingState() }
            state.onboarding?.reconcileBuildAvailability()
            // Preserve completed setup across permission restarts. The final
            // connection check verifies readiness before opening chats.
            try local.save(state)
        } catch { storageLoadFailed = true; self.error = "Local state could not be loaded or saved: \(error.localizedDescription). Sending is unavailable until storage works." }
        if demo { setupDemo() }
        if state.onboarding?.isFinished == true, state.agentGrid == nil {
            state.agentGrid = defaultAgentGrid
        }
        if state.agentGrid == nil, state.onboarding?.stage == .choosing, state.onboarding?.completed.isEmpty == true {
            state.selection = []
            webAgents.sessions.forEach { $0.updateState { $0.selected = false } }
        }
        persist()
        accessGuide.checkHistory = { [weak self] in
            guard let self, !self.busy else { return false }
            self.refresh(forMessagesSetup: true)
            return self.databaseAvailable
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.refreshIfChanged() } }
        Task { await telemetry.configure(storageLoadFailed ? nil : state.sharingConsent); telemetryHeartbeat() }
        if TelemetryCollector.endpoint(demo: demo) != nil {
            telemetryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.telemetryHeartbeat() } }
        }
    }
    func save() throws {
        guard !storageLoadFailed else { throw AppFailure.blocked("Saved state is unavailable. It will not be overwritten. You can quit or update after new drafts are saved separately in \(local.url.deletingLastPathComponent().appendingPathComponent("Recovery").path). Repair the saved state before sending.") }
        try local.save(state)
    }
    func saveForTermination() throws {
        if storageLoadFailed {
            try QuitStateRecovery.preserve(state, originalURL: local.url)
        } else {
            try save()
        }
    }
    func persist() { do { try save() } catch { self.error = "Could not save local state: \(error.localizedDescription)" } }
    func setWindowStyle(_ style: ComparisonWindowStyle) {
        guard state.effectiveWindowStyle != style else { return }
        let previous = state.windowStyle
        state.windowStyle = style
        do { try save() }
        catch {
            state.windowStyle = previous
            self.error = "Could not save Settings: \(error.localizedDescription)"
            return
        }
        coordinator?.reopenComparisons()
    }
    func setRecipients(_ selection: ConversationRecipients, for id: UUID) {
        guard let i = index(id) else { return }
        guard (state.comparisons[i].recipientSelection ?? ConversationRecipients()) != selection else { return }
        state.comparisons[i].recipientSelection = selection
        persist()
    }
    func resetDemo() {
        guard demo, !busy else { return }
        personalAgent.cancelAll()
        coordinator?.closeAll()
        let windowStyle = state.windowStyle
        state = AppState(); state.windowStyle = windowStyle
        messages = [:]; demoRow = 100; demoFailureOnce = false
        setupDemo()
    }
    func setupDemo() {
        let names = ["Cedar", "Lumen", "Orbit", "Maple", "Echo", "Flint"]
        chats = names.enumerated().map { Chat(id: "demo-\($0.offset)", handle: "\($0.element.lowercased())@example.com", lastActivity: Int64($0.offset)) }
        if state.agents.isEmpty {
            state.agents = names.enumerated().map { Agent(contactID: "fixture-\($0.offset)", name: $0.element, handles: [chats[$0.offset].handle], colorIndex: $0.offset) }
            state.selection = Set(state.agents.map(\.id))
            state.draft = "What is the clearest way to compare three approaches to the same problem?"
        }
        if ProcessInfo.processInfo.arguments.contains("--business-choices-preview") {
            let address = "urn:biz:00000000-0000-0000-0000-000000000001"
            chats[0] = Chat(id: "iMessage;-;" + address, handle: address, lastActivity: 0, displayName: "Poke", businessConversation: true)
            state.agents[0].name = "Poke 🌴"
            state.agents[0].destination = MessagesDestination(chat: chats[0])
        }
        // Synthetic transcripts are reconstructed from app-owned prompts, never copied into the local store.
        if onboardingPreview {
            state.draft = ""
            for name in ["Fo", "Instinct", "Szn", "Poke"] {
                if name == "Poke", ProcessInfo.processInfo.arguments.contains("--business-messages-preview") {
                    chats.append(Chat(id: "any;-;urn:biz:00000000-0000-0000-0000-000000000123", handle: "urn:biz:00000000-0000-0000-0000-000000000123", lastActivity: 0,
                                      displayName: "Poke", businessConversation: true))
                    continue
                }
                let handle = name.lowercased() + "@example.com"
                if !chats.contains(where: { $0.handle == handle }) {
                    chats.append(Chat(id: "demo-onboarding-" + name.lowercased(), handle: handle, lastActivity: 0))
                }
            }
        }
        for comparison in state.comparisons {
            for member in comparison.members {
                if member.payload == nil, let anchor = member.anchor {
                    messages[member.chat.id, default: []].append(Message(id: anchor.rowID, guid: anchor.guid, chatID: member.chat.id, text: comparison.prompt, outgoing: true, date: comparison.created))
                    demoRow = max(demoRow, anchor.rowID + 1)
                }
                let payloads = [member.payload].compactMap { $0 } + comparison.followUps.compactMap { $0.payloads?[member.id.uuidString] }
                if !payloads.isEmpty {
                    for part in payloads.flatMap(\.parts) {
                        if let anchor = part.anchor {
                            messages[member.chat.id, default: []].append(Message(id: anchor.rowID, guid: anchor.guid, chatID: member.chat.id, text: part.text ?? "", outgoing: true, date: part.attemptedAt ?? comparison.created, attachments: part.attachment.map { [$0] } ?? []))
                            demoRow = max(demoRow, anchor.rowID + 1)
                        }
                    }

                }
            }
        }
        persist()
    }
    private func refreshIfChanged() {
        refreshContactAccess()
        guard !needsOnboarding || usesMessages else { return }
        guard !busy, !demo else { return }
        do {
            if let database, try database.changeVersion() == lastDataVersion { return }
        } catch { database = nil; lastDataVersion = nil }
        refresh()
    }
    func refresh(forMessagesSetup: Bool = false) {
        guard !busy else { return }
        refreshContactAccess()
        guard forMessagesSetup || !needsOnboarding || usesMessages else { return }
        defer { accessGuide.observeHistory(available: databaseAvailable) }
        if permissionGuidePreview {
            databaseAvailable = false
            databaseStatus = "Permission guide preview · history access is simulated as unavailable · no real sends"
            return
        }
        if demo {
            databaseAvailable = true; databaseStatus = "Simulated Messages · no real sends"
            let destinationChanged = state.pinBusinessDestinations(chats: chats)
            let selectionChanged = state.retainAvailableSelection(chats: chats)
            if destinationChanged || selectionChanged { persist() }
            return
        }
        do {
            if database == nil { database = try MessagesDatabase(path: NSHomeDirectory() + "/Library/Messages/chat.db") }
            guard let database else { return }
            let version = try database.changeVersion()
            let freshChats = try database.chats()
            if chats != freshChats { chats = freshChats }
            let destinationChanged = state.pinBusinessDestinations(chats: freshChats)
            let selectionChanged = state.retainAvailableSelection(chats: freshChats)
            if destinationChanged || selectionChanged { try save() }
            if !databaseAvailable { databaseAvailable = true }
            if databaseStatus != "Messages history available · read-only" { databaseStatus = "Messages history available · read-only" }
            let members = state.comparisons.flatMap(\.members)
            for chatID in Set(members.map(\.chat.id)) {
                let start = members.filter { $0.chat.id == chatID }.compactMap(\.anchor?.rowID).min() ?? 0
                let fresh = try database.messages(chatID: chatID, after: start)
                if messages[chatID] != fresh { messages[chatID] = fresh }
            }
            try reconcile()
            lastDataVersion = version
        } catch { databaseAvailable = false; databaseStatus = error.localizedDescription; database = nil }
    }
    func refreshContactAccess() {
        let available = demo ? demoContactsConnected : contacts.status == .authorized
        if contactsAvailable != available {
            contactsAvailable = available
            if available { contactQuery = "" }
        }
    }
    func connectContacts() async {
        guard !busy else { return }
        contactStatus = ""
        if demo {
            demoContactsConnected = true
            refreshContactAccess()
            return
        }
        do {
            if contacts.status == .notDetermined { try await contacts.request() }
            else if contacts.status != .authorized {
                if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Contacts") {
                    NSWorkspace.shared.open(url)
                }
            }
            refreshContactAccess()
        } catch { contactStatus = error.localizedDescription }
    }
    func searchDiscoverContacts(knownAgents: [DiscoveredAgent]) async {
        guard databaseAvailable, contactsAvailable else { contactResults = []; return }
        let query = contactQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let known = KnownAgentContacts(agents: knownAgents)
            if demo {
                let samples = (["Fo", "Szn", "Instinct", "Poke"] + knownAgents.prefix(1).map(\.name)).map { Agent(contactID: "fixture-known-" + $0.lowercased(), name: $0, handles: [$0.lowercased() + "@example.com"]) }
                let contacts = samples.filter { sample in !state.agents.contains { $0.contactID == sample.contactID } } + state.agents
                contactResults = contacts.filter { query.isEmpty ? known.contains(name: $0.name) :
                    $0.name.localizedCaseInsensitiveContains(query) || $0.handles.contains(where: { $0.localizedCaseInsensitiveContains(query) }) }
            } else {
                let searchTask = Task.detached(priority: .userInitiated) {
                    let search = ContactSearch()
                    return try query.isEmpty ? search.knownAgents(matching: known) : search.search(query)
                }
                let results = try await withTaskCancellationHandler {
                    try await searchTask.value
                } onCancel: { searchTask.cancel() }
                guard !Task.isCancelled, databaseAvailable, contactsAvailable,
                      contactQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
                contactResults = results
            }
            if let manual = Agent.manualAccount(for: query), !contactResults.contains(where: {
                $0.handles.contains { ChatResolver.normalize($0) == ChatResolver.normalize(query) }
            }) { contactResults.append(manual) }
            contactStatus = query.isEmpty || !contactResults.isEmpty ? "" : "No matching contact. Try a name, email, or full phone number."
        } catch {
            guard !Task.isCancelled, databaseAvailable, contactsAvailable,
                  contactQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            contactResults = []; contactStatus = error.localizedDescription
        }
    }
    func savedAgent(matching agent: Agent) -> Agent? {
        let handles = Set(agent.handles.map(ChatResolver.normalize))
        return state.agents.first { saved in
            if let contactID = agent.contactID { return saved.contactID == contactID }
            return saved.handles.contains { handles.contains(ChatResolver.normalize($0)) }
        }
    }

    func onboardingContactSuggestions() async throws -> [Agent] {
        refresh(forMessagesSetup: true)
        guard databaseAvailable, contactsAvailable else {
            throw AppFailure.blocked(databaseAvailable ? "Enable Contacts access to find your agents." : databaseStatus)
        }
        if demo {
            return ["Fo", "Instinct", "Szn", "Poke"].map {
                Agent(contactID: "fixture-known-" + $0.lowercased(), name: $0 == "Poke" ? "Poke 🌴" : $0, handles: $0 == "Poke" && ProcessInfo.processInfo.arguments.contains("--business-messages-preview") ? ["+15550000001", "+15550000002"] : [$0.lowercased() + "@example.com"])
            }
        }
        let known = KnownAgentContacts(agents: try DiscoverCatalog.bundled().discoverAgents)
        let search = Task.detached(priority: .userInitiated) {
            try ContactSearch().knownAgents(matching: known)
        }
        let results = try await withTaskCancellationHandler { try await search.value } onCancel: { search.cancel() }
        guard !Task.isCancelled, databaseAvailable, contactsAvailable else { return [] }
        return results
    }
    func addAgent(_ agent: Agent) async {
        guard !busy else { return }
        contactStatus = ""
        if let existing = savedAgent(matching: agent) {
            if let destination = agent.destination, let chat = chats.first(where: destination.matches) {
                chooseConversation(chat, for: existing)
            }
            return
        }
        busy = true
        defer { busy = false }
        do {
            var saved = agent
            if saved.contactID == nil {
                if demo { saved.contactID = "fixture-manual-\(saved.id.uuidString)" }
                else { saved = try await contacts.saveManual(saved) }
            }
            if saved.destination == nil, let chat = conversation(saved), chat.businessConversation == true {
                saved.destination = MessagesDestination(chat: chat)
            }
            if !state.agents.contains(where: { $0.contactID == saved.contactID }) {
                state.agents.append(saved)
                if state.agentGrid != nil { state.agentGrid?.add(gridID(for: saved)) }
            }
            try save()
            if let i = contactResults.firstIndex(where: { $0.id == agent.id }) { contactResults[i] = saved }
            contactStatus = ""
        } catch {
            contactStatus = error.localizedDescription
        }
    }
    private func destinationAgent(_ agent: Agent) -> Agent {
        // Discovery rows may still hold a Contacts snapshot from before the choice was saved.
        agent.destination != nil ? agent : savedAgent(matching: agent) ?? agent
    }
    func conversation(_ agent: Agent) -> Chat? { ChatResolver.conversation(agent: destinationAgent(agent), chats: chats) }
    func route(_ agent: Agent) -> Chat? { ChatResolver.resolve(agent: destinationAgent(agent), chats: chats) }
    func matchConversationAutomatically(for agent: Agent) {
        guard let saved = savedAgent(matching: agent), saved.destination == nil,
              let chat = ChatResolver.conversation(agent: saved, chats: chats), chat.businessConversation == true,
              let index = state.agents.firstIndex(where: { $0.id == saved.id }) else { return }
        let previous = state
        state.agents[index].destination = MessagesDestination(chat: chat)
        do { try save() } catch { state = previous; self.error = error.localizedDescription }
    }
    func chooseConversation(_ chat: Chat, for agent: Agent) {
        guard let saved = savedAgent(matching: agent),
              let index = state.agents.firstIndex(where: { $0.id == saved.id }),
              chats.contains(chat) else { return }
        let previous = state
        state.agents[index].destination = MessagesDestination(chat: chat)
        state.selection.remove(saved.id)
        do { try save() } catch { state = previous; self.error = error.localizedDescription }
    }
    func messageConnectionStatus(_ agent: Agent) -> String {
        guard databaseAvailable else { return "Connect Messages" }
        return ChatResolver.status(agent: destinationAgent(agent), chats: chats)
    }
    func removeAgent(_ agent: Agent) { state.agents.removeAll { $0.id == agent.id }; state.selection.remove(agent.id); persist() }
    func validateMembers(prompt: String, selectedIDs: Set<UUID>? = nil) throws -> [Member] {
        guard databaseAvailable else { throw AppFailure.blocked(databaseStatus) }
        var result: [Member] = []
        let previewChats = chats
        if !demo { chats = try database!.chats() }
        for agent in state.agents where (selectedIDs ?? state.selection).contains(agent.id) {
            let fresh = demo ? agent : try contacts.refreshed(agent)
            if fresh != agent, let saved = state.agents.firstIndex(where: { $0.id == agent.id }) {
                state.agents[saved] = fresh
                try save()
            }
            guard let chat = route(fresh) else { throw AppFailure.blocked("\(agent.name) no longer has a matching existing one-to-one Messages chat. Refresh setup before sending.") }
            // If activity reroutes the contact after preview, update the picker and require a new review.
            guard ChatResolver.resolve(agent: agent, chats: previewChats)?.id == chat.id else { throw AppFailure.blocked("\(agent.name)'s destination changed. Refresh and review the new destination.") }
            guard !state.comparisons.contains(where: { $0.prompt == prompt && $0.members.contains(where: { $0.chat.id == chat.id && $0.anchor == nil && [.submitted, .uncertain, .sending].contains($0.submission) }) }) else {
                throw AppFailure.blocked("An earlier submission of this text to \(agent.name) still needs reconciliation. Resolve it before sending the same prompt again.")
            }
            result.append(Member(agentID: agent.id, name: agent.name, chat: chat))
        }
        guard !result.isEmpty else { throw AppFailure.blocked("Select at least one agent.") }
        try RecipientSet.validate(result)
        return result
    }
    func start(recipientIDs: Set<UUID>) async {
        let text = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = state.attachmentsDraft ?? []
        guard (!text.isEmpty || !attachments.isEmpty), !busy else { return }
        do {
            if !demo, contacts.status == .notDetermined {
                busy = true
                defer { busy = false }
                try await contacts.request()
            }
            let members = try validateMembers(prompt: text, selectedIDs: recipientIDs)
            var comparison = Comparison(prompt: text, members: members)
            if !attachments.isEmpty {
                comparison.attachments = attachments
                for j in comparison.members.indices { comparison.members[j].payload = OutgoingPayload(text: text, attachments: attachments) }
            }
            state.comparisons.insert(comparison, at: 0)
            try save() // Durable intent exists before any external send.
            state.draft = ""; state.attachmentsDraft = nil; try save()
            coordinator?.open(comparison.id)
            await submit(comparison.id, retry: false)
        } catch { self.error = error.localizedDescription }
    }
    func setSharedDraft(_ text: String) {
        state.draft = text
        if state.workspaceDrafts == nil { state.workspaceDrafts = [:] }
        state.workspaceDrafts?[webAgents.comparisonID?.uuidString ?? "new"] = text
        persist()
    }
    var canStartNewBlast: Bool {
        !needsOnboarding && !needsSharingChoice && error == nil && !busy && !webBroadcastBusy && !webAgents.sessions.contains { $0.isSending }
    }
    @discardableResult
    func requestNewBlast(agent: AgentGridID? = nil) -> Bool {
        guard canStartNewBlast else { return false }
        if let agent {
            guard quickChatAgents.contains(where: { $0.id == agent }) else { return false }
        }
        selectWorkspace(nil)
        newBlastShowsChat = false
        if let agent {
            state.selection = Set(messageAgent(for: agent).map { [$0.id] } ?? [])
            for session in webAgents.sessions where session.state.selected != (session.id.gridID == agent) {
                session.updateState { $0.selected = session.id.gridID == agent }
            }
            if let session = webAgents.session(for: agent) {
                session.connect()
                newBlastShowsChat = true
            }
            persist()
        }
        newBlastRequest = UUID()
        return true
    }
    var quickChatAgents: [AgentGridEntry] {
        let catalog = agentGridCatalog
        return agentGridLayout.visibleIDs.compactMap { id in catalog.first { $0.id == id } }.filter { entry in
            if let agent = messageAgent(for: entry.id) { return route(agent) != nil }
            guard let session = webAgents.session(for: entry.id), session.isEnabled, session.isStorageAvailable else { return false }
            let savedAccount = webAgents.session(for: WebAgentID(provider: session.provider))?.state.sessionID
            let completedAccount = state.onboarding?.completed.contains(where: { $0.provider == session.provider }) == true &&
                session.state.sessionID == savedAccount
            return session.isReadyForOnboarding || session.snapshot.signedIn == true || completedAccount ||
                !session.state.conversationURLs.isEmpty || !session.state.attempts.isEmpty ||
                (session.provider.usesNativeConversation && session.state.enabled == true)
        }
    }
    func selectWorkspace(_ id: UUID?, promotingDraft: Bool = false) {
        if id == nil { deselectHiddenGridRecipients(); persist() }
        let previous = webAgents.comparisonID
        guard previous != id else { return }
        var drafts = state.workspaceDrafts ?? [:]
        drafts[previous?.uuidString ?? "new"] = state.draft
        let key = id?.uuidString ?? "new"
        if promotingDraft {
            drafts["new"] = ""
            drafts[key] = state.draft
        } else {
            // New Blast keeps an unsent draft while the original comparison retains its copy.
            state.draft = drafts[key].flatMap { id == nil && $0.isEmpty ? nil : $0 } ?? (id == nil ? state.draft : "")
            drafts[key] = state.draft
        }
        state.workspaceDrafts = drafts
        webAgents.setComparison(id)
        persist()
    }

    func prepareWebComparison(_ text: String, recipientIDs: Set<UUID>, agents: [WebAgentID]) async -> UUID? {
        guard !busy else { return nil }
        do {
            if !recipientIDs.isEmpty, !demo, contacts.status == .notDetermined { try await contacts.request() }
            let members = recipientIDs.isEmpty ? [] : try validateMembers(prompt: text, selectedIDs: recipientIDs)
            var comparison = Comparison(prompt: text, members: members)
            comparison.setWebAgents(agents)
            state.comparisons.insert(comparison, at: 0)
            do { try save() }
            catch { state.comparisons.removeAll { $0.id == comparison.id }; throw error }
            selectWorkspace(comparison.id, promotingDraft: true)
            return comparison.id
        } catch { self.error = error.localizedDescription; return nil }
    }
    func joinWebAgent(_ session: WebAgentSession, comparisonID: UUID) async -> Bool {
        guard comparison(comparisonID)?.endedAt == nil, !busy, session.isEnabled, session.provider.supportsSharedSubmissions else { return false }
        if comparison(comparisonID)?.resolvedWebAgentIDs.contains(session.id) == true { return true }
        do {
            try freezeSharedContext(comparisonID)
            guard let saved = comparison(comparisonID), let i = index(comparisonID) else { return false }
            guard saved.joiningContext().allSatisfy({ $0.attachments.isEmpty }) else {
                error = "This conversation contains attachments. Add a Messages agent to share the full context."
                session.updateState { $0.selected = false }
                return false
            }
            guard await webAgents.prepareComparison(comparisonID, for: [session]),
                  comparison(comparisonID)?.endedAt == nil else { return false }
            // Save membership before sending so an interrupted join is never automatically repeated.
            state.comparisons[i].setWebAgents(saved.resolvedWebAgentIDs + [session.id])
            try save()
            let attempt = await session.send(saved.joiningPrompt(), comparisonID: comparisonID)
            if attempt == nil || attempt?.status == .notSent {
                state.comparisons[i].setWebAgents(state.comparisons[i].resolvedWebAgentIDs.filter { $0 != session.id })
                try save()
            }
            return attempt?.status == .observed
        } catch { self.error = error.localizedDescription; return false }
    }

    func freezeSharedContext(_ id: UUID) throws {
        guard let i = index(id) else { return }
        let verified = Array(state.comparisons[i].joiningContext().dropFirst())
        guard state.comparisons[i].sharedContext != verified else { return }
        state.comparisons[i].sharedContext = verified
        try save()
    }
    func addAgent(_ agent: Agent, to id: UUID) async {
        guard let i = index(id), state.comparisons[i].endedAt == nil, !busy, !state.comparisons[i].members.contains(where: { $0.id == agent.id }) else { return }
        do {
            try freezeSharedContext(id)
            var member = try validateMembers(prompt: state.comparisons[i].prompt, selectedIDs: [agent.id])[0]
            try RecipientSet.validate(state.comparisons[i].members + [member])
            member.payload = state.comparisons[i].joiningPayload()
            state.comparisons[i].members.append(member)
            do { try save() } catch { state.comparisons[i].members.removeLast(); throw error }
            state.selection.insert(agent.id)
            try save()
            coordinator?.updateMembershipWindow(id)
            await submit(id, retry: false, only: agent.id)
        } catch { self.error = error.localizedDescription }
    }
    func openWebComparison(_ id: UUID, present: Bool = true) {
        guard !webBroadcastBusy, let comparison = comparison(id) else { return }
        selectWorkspace(id)
        state.selection = Set(comparison.members.map(\.id))
        webAgents.restoreSelection(forAgentIDs: comparison.resolvedWebAgentIDs)
        if present { webComparisonRequest = UUID() }
        let sessions = webAgents.selected
        Task {
            guard webAgents.comparisonID == id else { return }
            await webAgents.prepareComparison(id, for: sessions)
        }
    }
    @discardableResult
    func endConversation(_ id: UUID) -> Bool {
        guard let i = index(id) else { return false }
        if state.comparisons[i].endedAt != nil { return true }
        let previous = state.comparisons[i]
        guard previous.resolvedWebAgentIDs.allSatisfy({ webAgents.session(for: $0)?.canArchiveComparison(id) == true }) else {
            self.error = "Open the saved agent chats and wait for their history to load before ending this conversation."
            return false
        }
        // The normal poll is paused during sends. Read the cutoff independently
        // so rows already received are retained even when a send is in flight.
        do {
            for member in previous.members { messages[member.chat.id] = try latest(member.chat) }
        } catch {
            self.error = "Could not retain conversation history before ending: " + error.localizedDescription
            return false
        }
        state.comparisons[i].endedAt = Date()
        state.comparisons[i].endMessageRows = Dictionary(uniqueKeysWithValues: previous.members.map {
            ($0.chat.id, messages[$0.chat.id]?.map(\.id).max() ?? 0)
        })
        state.comparisons[i].endedWebHistory = Dictionary(uniqueKeysWithValues: previous.resolvedWebAgentIDs.map { agent in
            (agent.id, webAgents.session(for: agent)?.messagesForComparison(id) ?? [])
        })
        do { try save(); return true }
        catch { state.comparisons[i] = previous; self.error = error.localizedDescription; return false }
    }

    func comparison(_ id: UUID) -> Comparison? { state.comparisons.first { $0.id == id } }
    func index(_ id: UUID) -> Int? { state.comparisons.firstIndex { $0.id == id } }
    func transcript(_ comparison: Comparison, member: Member) -> [Message] {
        guard let anchor = member.anchor else { return [] }
        let history = messages[member.chat.id] ?? []
        return ComparisonRange.messages(comparison.endedAt == nil ? history : history.filter { comparison.includes($0) }, anchor: anchor, next: ComparisonRange.nextAnchor(for: comparison, member: member, comparisons: state.comparisons))
    }
    func latest(_ chat: Chat) throws -> [Message] {
        if demo { return messages[chat.id] ?? [] }
        guard let database else { throw AppFailure.blocked(databaseStatus) }
        return try database.messages(chatID: chat.id)
    }
    func validate(_ chat: Chat) throws {
        let available = demo ? chats : try database?.chats() ?? []
        guard available.contains(where: { $0.id == chat.id && $0.eligible && ChatResolver.normalize($0.handle) == ChatResolver.normalize(chat.handle) }) else { throw AppFailure.blocked("The saved destination is no longer an eligible one-to-one Messages chat. Nothing was sent.") }
    }
    func submit(_ id: UUID, retry: Bool, only memberID: UUID? = nil) async {
        guard let i = index(id), state.comparisons[i].endedAt == nil, !busy else { return }
        let telemetryStarted = Date()
        let previouslySubmitted = Set(state.comparisons[i].members.filter { $0.submission == .submitted }.map(\.id))
        do { try RecipientSet.validate(state.comparisons[i].members) } catch { self.error = error.localizedDescription; return }
        busy = true; defer { busy = false; refresh() }
        for j in state.comparisons[i].members.indices {
            let member = state.comparisons[i].members[j]
            guard memberID == nil || member.id == memberID else { continue }
            guard retry ? member.submission.canRetry : member.submission == .ready else { continue }
            if let payload = member.payload {
                _ = await deliver(payload, to: member.chat, simulateFailure: demo && demoFailureOnce && j == state.comparisons[i].members.count - 1) { updated in
                    self.state.comparisons[i].members[j].apply(updated)
                    try self.save()
                }
                if demo && state.comparisons[i].members[j].submission == .submitted { scheduleDemoReply(id, memberID: member.id) }
                continue
            }
            var attempted = false
            do {
                try validate(member.chat)
                let baseline = try latest(member.chat).map(\.id).max() ?? 0
                if demo && demoFailureOnce && j == state.comparisons[i].members.count - 1 {
                    demoFailureOnce = false
                    throw AppFailure.blocked("Simulated failure before submission. This fixture recipient can safely be retried.")
                }
                state.comparisons[i].members[j].baseline = baseline
                state.comparisons[i].members[j].attemptedAt = Date()
                state.comparisons[i].members[j].submission = .sending
                state.comparisons[i].members[j].error = nil
                try save()
                attempted = true
                if demo { appendDemo(state.comparisons[i].prompt, chat: member.chat, outgoing: true) }
                else { try await MessageSender().send(state.comparisons[i].prompt, to: member.chat) }
                state.comparisons[i].members[j].submission = .submitted
                try save()
                // Keep submitted status even when the record takes time to appear. No automatic resend.
                for _ in 0..<6 {
                    let fresh = try latest(member.chat)
                    let candidates = fresh.filter { $0.id > baseline && $0.outgoing && $0.text == state.comparisons[i].prompt }
                    if candidates.count == 1, let found = candidates.first {
                        state.comparisons[i].members[j].anchor = Anchor(rowID: found.id, guid: found.guid)
                        messages[member.chat.id] = fresh
                        break
                    }
                    if candidates.count > 1 { state.comparisons[i].members[j].error = "Multiple matching outgoing records. Anchor is ambiguous; no resend."; break }
                    try await Task.sleep(for: .milliseconds(500))
                }
                if state.comparisons[i].members[j].anchor == nil { state.comparisons[i].members[j].error = "Submitted, awaiting an unambiguous history anchor. Refresh to reconcile." }
                try save()
                if demo { scheduleDemoReply(id, memberID: member.id) }
            } catch {
                state.comparisons[i].members[j].submission = Submission.failure(afterAttempt: attempted, error: error)
                state.comparisons[i].members[j].error = error.localizedDescription
                persist()
            }
        }
        if !webBroadcastBusy {
            let submitted = state.comparisons[i].members.filter { $0.submission == .submitted && !previouslySubmitted.contains($0.id) }.count
            if submitted > 0 { recordMessageSubmission(kind: .shared, recipientCount: submitted, started: telemetryStarted, logicalID: id) }
            else { recordOperation(.send, success: false, started: telemetryStarted) }
        }
    }
    func reconcile() throws {
        var changed = false
        for i in state.comparisons.indices {
            for j in state.comparisons[i].members.indices {
                let member = state.comparisons[i].members[j]
                if var payload = member.payload {
                    guard payload.needsReconciliation else { continue }
                    let upper = state.comparisons.filter { $0.created > state.comparisons[i].created }.flatMap(\.members).filter { $0.chat.id == member.chat.id }.compactMap(\.baseline).min().map { $0 + 1 }
                    payload.reconcile(in: messages[member.chat.id] ?? [], before: upper, excluding: claimedAnchors(chatID: member.chat.id, except: payload))
                    if payload != member.payload {
                        state.comparisons[i].members[j].apply(payload)
                        changed = true
                    }
                    continue
                }
                guard member.anchor == nil, [.submitted, .uncertain].contains(member.submission), member.baseline != nil else { continue }
                if let message = ComparisonRange.anchorCandidate(messages: messages[member.chat.id] ?? [], comparison: state.comparisons[i], member: member, comparisons: state.comparisons) {
                    state.comparisons[i].members[j].anchor = Anchor(rowID: message.id, guid: message.guid)
                    state.comparisons[i].members[j].submission = .submitted
                    state.comparisons[i].members[j].error = nil
                    changed = true
                }
            }
        }
        for i in state.comparisons.indices {
            for k in state.comparisons[i].followUps.indices {
                for member in state.comparisons[i].members {
                    let key = member.id.uuidString
                    guard var payload = state.comparisons[i].followUps[k].payloads?[key], payload.needsReconciliation else { continue }
                    let previous = payload
                    payload.reconcile(in: messages[member.chat.id] ?? [], excluding: claimedAnchors(chatID: member.chat.id, except: payload))
                    if previous != payload {
                        state.comparisons[i].followUps[k].apply(payload, for: key)
                        changed = true
                    }
                }
            }
        }
        if changed { try save() }
    }
    func followUp(_ id: UUID, only memberID: UUID? = nil, recipients recipientIDs: [UUID]? = nil, retry attemptID: UUID? = nil, resumeUnsent: Bool = false, newAttemptID: UUID? = nil) async {
        guard let i = index(id), state.comparisons[i].endedAt == nil, !busy, memberID == nil || !webBroadcastBusy else { return }
        do { try freezeSharedContext(id) } catch { self.error = error.localizedDescription; return }
        let comparison = state.comparisons[i]
        let selected = recipientIDs.map(Set.init)
        var targets = comparison.members.filter { member in memberID.map { $0 == member.id } ?? selected?.contains(member.id) ?? true }
        let text = (memberID.map { comparison.privateDrafts[$0.uuidString] ?? "" } ?? comparison.allDraft).trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = attachmentDraft(comparisonID: id, memberID: memberID)
        if attemptID == nil && text.isEmpty && attachments.isEmpty { return }
        let telemetryStarted = Date()
        var k: Int
        do {
            try RecipientSet.validate(comparison.members)
            if let attemptID {
                guard let existing = comparison.followUps.firstIndex(where: { $0.id == attemptID }) else { throw AppFailure.blocked("The saved follow-up is unavailable.") }
                k = existing
                let attempt = comparison.followUps[k]
                let pending = Set(attempt.recipientsForRecovery(resumeUnsent: resumeUnsent))
                targets = comparison.members.filter { pending.contains($0.id) }
            } else { k = comparison.followUps.count }
            guard !targets.isEmpty else { return }
            guard targets.allSatisfy({ $0.anchor != nil && $0.submission == .submitted }) else { throw AppFailure.blocked("Wait for every target's prompt anchor before following up.") }
            // Ordinary follow-ups to an older comparison would lose its original prompt context.
            for member in targets where ComparisonRange.nextAnchor(for: comparison, member: member, comparisons: state.comparisons) != nil {
                throw AppFailure.blocked("\(member.name) has joined a newer comparison. Genuine inline replies have not been validated on this Mac. Open the original prompt in Messages to reply; the shared follow-up was not sent.")
            }
            if attemptID == nil {
                var attempt = FollowUp(text: text, memberIDs: targets.map(\.id))
                if let newAttemptID { attempt.id = newAttemptID }
                attempt.sharedWithAll = memberID == nil && comparison.webProviders == nil && Set(targets.map(\.id)) == Set(comparison.members.map(\.id))
                for member in targets {
                    attempt.states[member.id.uuidString] = .ready
                    if !attachments.isEmpty {
                        if attempt.payloads == nil { attempt.payloads = [:] }
                        attempt.payloads?[member.id.uuidString] = OutgoingPayload(text: text, attachments: attachments)
                    }
                }
                state.comparisons[i].followUps.append(attempt); k = state.comparisons[i].followUps.count - 1
                if memberID == nil { state.comparisons[i].allDraft = "" } else { state.comparisons[i].privateDrafts[memberID!.uuidString] = "" }
                setAttachmentDraft([], comparisonID: id, memberID: memberID, saveNow: false)
                try save()
            }
            let previouslySubmitted = Set(state.comparisons[i].followUps[k].states.filter { $0.value == .submitted }.map(\.key))
            busy = true
            for member in targets where state.comparisons[i].followUps[k].memberIDs.contains(member.id) {
                let key = member.id.uuidString
                let status = state.comparisons[i].followUps[k].states[key]
                guard status == .ready || status == .failed else { continue }
                if let payload = state.comparisons[i].followUps[k].payloads?[key] {
                    _ = await deliver(payload, to: member.chat) { updated in
                        self.state.comparisons[i].followUps[k].apply(updated, for: key)
                        try self.save()
                    }
                    if demo && state.comparisons[i].followUps[k].states[key] == .submitted { scheduleDemoReply(id, memberID: member.id) }
                    continue
                }
                var attempted = false
                do {
                    try validate(member.chat)
                    state.comparisons[i].followUps[k].states[key] = .sending; try save()
                    attempted = true
                    let body = state.comparisons[i].followUps[k].text
                    if demo { appendDemo(body, chat: member.chat, outgoing: true) }
                    else { try await MessageSender().send(body, to: member.chat) }
                    state.comparisons[i].followUps[k].states[key] = .submitted
                    state.comparisons[i].followUps[k].errors[key] = nil
                    try save()
                    if demo { scheduleDemoReply(id, memberID: member.id) }
                } catch {
                    state.comparisons[i].followUps[k].states[key] = Submission.failure(afterAttempt: attempted, error: error)
                    state.comparisons[i].followUps[k].errors[key] = error.localizedDescription; persist()
                }
            }
            try save()
            let completed = state.comparisons[i].followUps[k]
            state.comparisons[i].recordSharedFollowUp(completed)
            try save()
            if !webBroadcastBusy {
                let submitted = completed.states.filter { $0.value == .submitted && !previouslySubmitted.contains($0.key) }.count
                if submitted > 0 { recordMessageSubmission(kind: memberID == nil ? .shared : .private, recipientCount: submitted, started: telemetryStarted, logicalID: completed.id) }
                else { recordOperation(.send, success: false, started: telemetryStarted) }
            }
        } catch { self.error = error.localizedDescription }
        busy = false; refresh()
    }
    func appendDemo(_ text: String, chat: Chat, outgoing: Bool, replyTo: String? = nil, attachments: [MessageAttachment] = []) {
        demoRow += 1
        messages[chat.id, default: []].append(Message(id: demoRow, guid: "fixture-\(demoRow)", chatID: chat.id, text: text, outgoing: outgoing, replyTo: replyTo, attachments: attachments))
    }
    func scheduleDemoReply(_ id: UUID, memberID: UUID) {
        if demo && ProcessInfo.processInfo.arguments.contains("--no-demo-replies") { return }
        guard let comparison = comparison(id), let member = comparison.members.first(where: { $0.id == memberID }), let anchor = member.anchor,
              let sent = messages[member.chat.id]?.last(where: { $0.outgoing }) else { return }
        let offset = comparison.members.firstIndex { $0.id == memberID } ?? 0
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard self.comparison(id)?.members.contains(where: { $0.id == memberID }) == true else { return }
            let answers = ["Start with a common question and compare each answer against the same criteria. I would use clarity, cost, and reversibility.", "Try each approach on a small example. Keep the assumptions visible so you can see why the answers differ.", "Choose a concrete outcome first. Then test each option against it, and follow up where the reasoning is unclear."]
            if let index = messages[member.chat.id]?.firstIndex(where: { $0.guid == sent.guid }) {
                messages[member.chat.id]?[index].reactions = [MessageReaction(id: "fixture-recipient", emoji: "✅", outgoing: false)]
                let answer = sent.linkPreview?.url.absoluteString ?? answers[offset % answers.count]
                appendDemo(answer, chat: member.chat, outgoing: false, replyTo: anchor.guid)
                if ProcessInfo.processInfo.arguments.contains("--business-choices-preview"), member.chat.businessConversation == true {
                    appendBusinessChoiceFixture(chat: member.chat)
                }
            } else {
                appendDemo(answers[offset % answers.count], chat: member.chat, outgoing: false, replyTo: anchor.guid)
            }
        }
    }
    func openMessages(_ member: Member) {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+#?="))
        if let encoded = member.chat.id.addingPercentEncoding(withAllowedCharacters: allowed), let url = URL(string: "imessage://?chat=\(encoded)") { NSWorkspace.shared.open(url) }
    }
    func setting(_ pane: String) { if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) } }
}
