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
    @Published var contactResults: [Agent] = []
    @Published var contactQuery = ""
    @Published var demoFailureOnce = false
    @Published var contactStatus = ""
    let demo: Bool
    let personalAgent: PersonalAgentController
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
    lazy var webAgents = WebAgents(directory: local.url.deletingLastPathComponent(), fixture: demo && Bundle.main.object(forInfoDictionaryKey: "msgblastLiveWebPreview") as? Bool != true)
    var database: MessagesDatabase?
    var timer: Timer?
    var coordinator: WindowCoordinator?
    var demoRow: Int64 = 100
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
        local = LocalStore(demo: demo, isolated: ProcessInfo.processInfo.arguments.contains("--isolated-demo") || Bundle.main.object(forInfoDictionaryKey: "msgblastPermissionGuidePreview") as? Bool == true || Bundle.main.object(forInfoDictionaryKey: "msgblastIsolatedDemo") as? Bool == true, fixtureDirectory: fixtureDirectory, webPreview: Bundle.main.object(forInfoDictionaryKey: "msgblastLiveWebPreview") as? Bool == true)
        do { state = try local.load(); try local.save(state) } catch { storageLoadFailed = true; self.error = "Local state could not be loaded or saved: \(error.localizedDescription). Sending is unavailable until storage works." }
        if demo { setupDemo() }
        state.selection = Set(state.agents.map(\.id))
        persist()
        accessGuide.checkHistory = { [weak self] in
            guard let self, !self.busy else { return false }
            self.refresh()
            return self.databaseAvailable
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.refreshIfChanged() } }
    }
    func save() throws {
        guard !storageLoadFailed else { throw AppFailure.blocked("Local state could not be loaded. Preserve the state.json file and repair it before sending; it will not be overwritten.") }
        try local.save(state)
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
        // Synthetic transcripts are reconstructed from app-owned prompts, never copied into the local store.
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
        guard !busy, !demo else { return }
        do {
            if let database, try database.changeVersion() == lastDataVersion { return }
        } catch { database = nil; lastDataVersion = nil }
        refresh()
    }
    func refresh() {
        guard !busy else { return }
        defer { accessGuide.observeHistory(available: databaseAvailable) }
        if permissionGuidePreview {
            databaseAvailable = false
            databaseStatus = "Permission guide preview · history access is simulated as unavailable · no real sends"
            return
        }
        if demo {
            databaseAvailable = true; databaseStatus = "Simulated Messages · no real sends"
            if state.retainAvailableSelection(chats: chats) { persist() }
            return
        }
        do {
            if database == nil { database = try MessagesDatabase(path: NSHomeDirectory() + "/Library/Messages/chat.db") }
            guard let database else { return }
            let version = try database.changeVersion()
            let freshChats = try database.chats()
            if chats != freshChats { chats = freshChats }
            if state.retainAvailableSelection(chats: freshChats) { try save() }
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
    func searchAgents() async {
        let query = contactQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let manual = Agent.manualAccount(for: query)
        do {
            if demo { contactResults = state.agents.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) } }
            else if contacts.status == .authorized { contactResults = try contacts.search(query) }
            else if manual == nil {
                if contacts.status == .notDetermined { try await contacts.request() }
                contactResults = try contacts.search(query)
            } else { contactResults = [] }
            if let manual {
                let normalized = ChatResolver.normalize(query)
                let hasExactContact = contactResults.contains { $0.handles.contains { ChatResolver.normalize($0) == normalized } }
                if !hasExactContact { contactResults.append(manual) }
            }
            contactStatus = contactResults.isEmpty ? "No matching contact. Try a name, email, or full phone number." : ""
        } catch {
            contactResults = manual.map { [$0] } ?? []
            contactStatus = manual == nil ? error.localizedDescription : ""
        }
    }
    func addAgent(_ agent: Agent) async {
        guard !busy else { return }
        let normalizedHandles = Set(agent.handles.map(ChatResolver.normalize))
        guard !state.agents.contains(where: { saved in
            if let contactID = agent.contactID { return saved.contactID == contactID }
            return saved.handles.contains { normalizedHandles.contains(ChatResolver.normalize($0)) }
        }) else { return }
        busy = true
        defer { busy = false }
        do {
            var saved = agent
            if saved.contactID == nil {
                if demo { saved.contactID = "fixture-manual-\(saved.id.uuidString)" }
                else { saved = try await contacts.saveManual(saved) }
            }
            if let existing = state.agents.first(where: { $0.contactID == saved.contactID }) {
                if route(existing) != nil { state.selection.insert(existing.id) }
            } else {
                state.agents.append(saved)
                if route(saved) != nil { state.selection.insert(saved.id) }
            }
            try save()
            if let i = contactResults.firstIndex(where: { $0.id == agent.id }) { contactResults[i] = saved }
            contactStatus = ""
        } catch {
            contactStatus = error.localizedDescription
        }
    }
    func route(_ agent: Agent) -> Chat? { ChatResolver.resolve(handles: agent.handles, chats: chats) }
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
            guard ChatResolver.resolve(handles: agent.handles, chats: previewChats)?.id == chat.id else { throw AppFailure.blocked("\(agent.name)'s destination changed. Refresh and review the new destination.") }
            guard !state.comparisons.contains(where: { $0.prompt == prompt && $0.members.contains(where: { $0.chat.id == chat.id && $0.anchor == nil && [.submitted, .uncertain, .sending].contains($0.submission) }) }) else {
                throw AppFailure.blocked("An earlier submission of this text to \(agent.name) still needs reconciliation. Resolve it before sending the same prompt again.")
            }
            result.append(Member(agentID: agent.id, name: agent.name, chat: chat))
        }
        guard !result.isEmpty else { throw AppFailure.blocked("Select at least one agent.") }
        try RecipientSet.validate(result)
        return result
    }
    func start() async {
        let text = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = state.attachmentsDraft ?? []
        guard (!text.isEmpty || !attachments.isEmpty), !busy else { return }
        do {
            if !demo, contacts.status == .notDetermined {
                busy = true
                defer { busy = false }
                try await contacts.request()
            }
            let members = try validateMembers(prompt: text)
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
    func prepareWebComparison(_ text: String, recipientIDs: Set<UUID>, providers: [WebProvider]) async -> UUID? {
        guard !busy else { return nil }
        do {
            if !recipientIDs.isEmpty, !demo, contacts.status == .notDetermined { try await contacts.request() }
            let members = recipientIDs.isEmpty ? [] : try validateMembers(prompt: text, selectedIDs: recipientIDs)
            var comparison = Comparison(prompt: text, members: members)
            comparison.webProviders = providers
            state.comparisons.insert(comparison, at: 0)
            do { try save() }
            catch { state.comparisons.removeAll { $0.id == comparison.id }; throw error }
            webAgents.setComparison(comparison.id)
            return comparison.id
        } catch { self.error = error.localizedDescription; return nil }
    }
    func openWebComparison(_ id: UUID) {
        guard !webBroadcastBusy, let comparison = comparison(id) else { return }
        webAgents.setComparison(id)
        state.selection = Set(comparison.members.map(\.id))
        for session in webAgents.sessions {
            session.updateState { $0.selected = comparison.webProviders?.contains(session.provider) == true }
        }
        webAgents.connectSelected()
        webComparisonRequest = UUID()
        for session in webAgents.selected {
            Task {
                guard webAgents.comparisonID == id else { return }
                await session.openComparison(id)
            }
        }
    }
    func comparison(_ id: UUID) -> Comparison? { state.comparisons.first { $0.id == id } }
    func index(_ id: UUID) -> Int? { state.comparisons.firstIndex { $0.id == id } }
    func transcript(_ comparison: Comparison, member: Member) -> [Message] {
        guard let anchor = member.anchor else { return [] }
        return ComparisonRange.messages(messages[member.chat.id] ?? [], anchor: anchor, next: ComparisonRange.nextAnchor(for: comparison, member: member, comparisons: state.comparisons))
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
    func submit(_ id: UUID, retry: Bool) async {
        guard let i = index(id), !busy else { return }
        do { try RecipientSet.validate(state.comparisons[i].members) } catch { self.error = error.localizedDescription; return }
        busy = true; defer { busy = false; refresh() }
        for j in state.comparisons[i].members.indices {
            let member = state.comparisons[i].members[j]
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
    func followUp(_ id: UUID, only memberID: UUID? = nil, recipients recipientIDs: [UUID]? = nil, retry attemptID: UUID? = nil, resumeUnsent: Bool = false) async {
        guard let i = index(id), !busy else { return }
        let comparison = state.comparisons[i]
        let selected = recipientIDs.map(Set.init)
        var targets = comparison.members.filter { member in memberID.map { $0 == member.id } ?? selected?.contains(member.id) ?? true }
        let text = (memberID.map { comparison.privateDrafts[$0.uuidString] ?? "" } ?? comparison.allDraft).trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = attachmentDraft(comparisonID: id, memberID: memberID)
        if attemptID == nil && text.isEmpty && attachments.isEmpty { return }
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
        } catch { self.error = error.localizedDescription }
        busy = false; refresh()
    }
    func appendDemo(_ text: String, chat: Chat, outgoing: Bool, replyTo: String? = nil, attachments: [MessageAttachment] = []) {
        demoRow += 1
        messages[chat.id, default: []].append(Message(id: demoRow, guid: "fixture-\(demoRow)", chatID: chat.id, text: text, outgoing: outgoing, replyTo: replyTo, attachments: attachments))
    }
    func scheduleDemoReply(_ id: UUID, memberID: UUID) {
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
