import SwiftUI
import WebKit
import msgblastCore

struct EmbeddedServicePage: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct AgentsWorkspaceView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var web: WebAgents
    @Binding var showingComparison: Bool
    var newBlastRequest: UUID? = nil
    var captureLayout: ChatCaptureLayout? = nil
    var preservesWindowFrame = false
    var windowComparisonID: UUID? = nil
    @State private var showingConnectionIntro = false
    @State private var signInProviders: [WebAgentID] = []
    @State private var editingAgents = false
    @State private var hiddenMembers: Set<UUID> = []
    @State private var hiddenWebAgents: Set<WebAgentID> = []
    private var sending: Bool { model.busy || model.webBroadcastBusy || web.sessions.contains { $0.isSending } }
    private var busy: Bool { (windowComparisonID != nil && web.comparisonID != windowComparisonID) || sending }
    private var nativeRecipients: [Agent] {
        let ids = model.messageGridIDs
        let shown = Set(model.agentGridLayout.visibleIDs)
        return model.state.agents.filter { model.state.selection.contains($0.id) &&
            (showingComparison || shown.contains(ids[$0.id] ?? .messages($0.id))) }
    }
    private var selectedWebSessions: [WebAgentSession] {
        web.selected.filter { showingComparison || model.isVisibleInAgentGrid($0.id.gridID) }
    }
    private var attachmentComparisonID: UUID? { showingComparison ? nativeComparison?.id : nil }
    private var attachments: [MessageAttachment] { model.attachmentDraft(comparisonID: attachmentComparisonID) }
    private var preparingDesktopSessions: [WebAgentSession] {
        selectedWebSessions.filter { $0.provider.desktopApp != nil && $0.loading }
    }
    private var sharedSendDisabledReason: String? {
        guard !busy else { return nil }
        if WebAgents.hasConflictingNativeRecipients(selectedWebSessions.map(\.provider)) {
            return "Choose ChatGPT or Dots."
        }
        if !preparingDesktopSessions.isEmpty {
            return "Getting \(preparingDesktopSessions.map(\.name).formatted(.list(type: .and))) ready…"
        }
        let drafts = selectedWebSessions.filter { $0.provider.desktopApp == nil && $0.snapshot.hasDraft }.map { $0.name }
        guard !drafts.isEmpty else { return nil }
        let names = drafts.formatted(.list(type: .and))
        return "Finish or clear the draft in \(names), or deselect \(names) to send to the other agents."
    }
    private var canSend: Bool {
        let text = model.state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return nativeComparison?.endedAt == nil && !busy && !WebAgents.hasConflictingNativeRecipients(selectedWebSessions.map(\.provider)) && preparingDesktopSessions.isEmpty && !editingAgents && !showingConnectionIntro && (!selectedWebSessions.isEmpty || !nativeRecipients.isEmpty)
            && (selectedWebSessions.isEmpty || (!text.isEmpty && attachments.isEmpty))
            && selectedWebSessions.allSatisfy { $0.provider.desktopApp != nil || ($0.snapshot.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.draftRecoveryText == nil && !$0.hasUnresolvedSend(text)) }
            && (nativeRecipients.isEmpty || (model.databaseAvailable && nativeRecipients.allSatisfy { model.route($0) != nil }))
    }

    private func canReplyWhileBroadcasting(to session: WebAgentSession) -> Bool {
        guard model.webBroadcastBusy, model.webBroadcastInputsFinished, model.independentNativeReplies == 0, !model.busy,
              let comparison = nativeComparison, comparison.endedAt == nil,
              comparison.resolvedWebAgentIDs.contains(session.id), web.comparisonID == comparison.id else { return false }
        return web.canSendIndependentNativeReply(to: session, comparisonID: comparison.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            if showingComparison {
                comparisonPanes
            } else {
                AgentGridView(model: model, web: web, editing: $editingAgents, busy: busy,
                    toggleMessages: toggle, openChat: { session in
                        if web.comparisonID == nil { model.deselectHiddenGridRecipients(); model.persist() }
                        if !session.state.selected { web.toggle(session) }
                        hiddenWebAgents.remove(session.id)
                        session.connect(); showingComparison = true
                    })
            }
            Divider()
            composer
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay { if showingConnectionIntro { connectionIntro } }
        .task { web.connectSelected() }
        .onChange(of: web.comparisonID) { _, _ in
            if windowComparisonID == nil { hiddenMembers = []; hiddenWebAgents = [] }
        }
        .onChange(of: newBlastRequest) { _, _ in
            showingConnectionIntro = false; editingAgents = false
            if windowComparisonID == nil { hiddenMembers = []; hiddenWebAgents = [] }
        }
        .onChange(of: showingComparison) { _, value in if value { editingAgents = false } }
        .toolbar {
            if showingComparison {
                ToolbarItem(placement: .primaryAction) {
                    ChatShareButton(title: nativeComparison?.title ?? "Chat", captureLayout: captureLayout)
                }
            }
            if !showingComparison {
                ToolbarItem(placement: .primaryAction) {
                    Button(editingAgents ? "Done" : "Edit") { editingAgents.toggle() }
                        .accessibilityLabel(editingAgents ? "Done editing agents" : "Edit agents")
                        .disabled(busy)
                }
            }
            if windowComparisonID == nil && !model.state.comparisons.isEmpty { ToolbarItem(placement: .navigation) {
                Button {
                    model.requestNewBlast()
                } label: {
                    Label("New Blast", systemImage: "square.and.pencil")
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                }
                .accessibilityLabel("New Blast").disabled(busy)
            } }
        }
    }

    private var connectionIntro: some View {
        ZStack {
            Color.black.opacity(0.35)
            VStack(spacing: 18) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 34)).foregroundStyle(Color.accentColor)
                Text("Connect your accounts").font(.title2.weight(.semibold))
                Text("Sign in to \(signInProviders.map { web.name(for: $0) }.formatted(.list(type: .and))) in the chat panes. Then press Send & compare again.")
                    .multilineTextAlignment(.center)
                Text("Your request is saved in the message box below. Signing in won’t send it.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Start signing in") { showingConnectionIntro = false }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            }
            .padding(28).frame(maxWidth: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .padding(20).accessibilityElement(children: .contain)
        }
    }

    private var nativeComparison: Comparison? { (windowComparisonID ?? web.comparisonID).flatMap { model.comparison($0) } }

    private var displayedSessions: [WebAgentSession] {
        if let windowComparisonID, let comparison = model.comparison(windowComparisonID) {
            let joined = comparison.resolvedWebAgentIDs.compactMap { web.session(for: $0) }
            // Keep a joining agent's sign-in/preparation pane in this window too.
            let preparing = web.comparisonID == windowComparisonID ? web.selected.filter { !comparison.resolvedWebAgentIDs.contains($0.id) } : []
            return (joined + preparing).filter { !hiddenWebAgents.contains($0.id) }
        }
        return web.displayed.filter { !hiddenWebAgents.contains($0.id) }
    }
    private var displayedMembers: [Member] { nativeComparison?.members.filter { !hiddenMembers.contains($0.id) } ?? [] }
    private var unsentMessageAgents: [Agent] {
        windowComparisonID == nil && web.comparisonID == nil ? nativeRecipients.filter { !hiddenMembers.contains($0.id) } : []
    }
    private var comparisonChatCount: Int { displayedSessions.count + displayedMembers.count + unsentMessageAgents.count }

    private var comparisonPanes: some View {
        chatColumns
            .background(ChatWindowFrame(chatCount: comparisonChatCount, enabled: !preservesWindowFrame))
    }

    private var chatColumns: some View {
        GeometryReader { geometry in
            let unsentAgents = unsentMessageAgents
            let columns = comparisonChatCount
            let width = max(320, (geometry.size.width - CGFloat(max(0, columns - 1))) / CGFloat(max(1, columns)))
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(displayedSessions, id: \.id) { session in
                        if session.id != displayedSessions.first?.id { Divider() }
                        WebAgentPane(session: session, account: model.personalAgent, busy: busy, allowPrivateReplyWhileBusy: canReplyWhileBroadcasting(to: session), endedMessages: archivedMessages(for: session), removalDisabled: sending, sendNative: { sendDirect($0, to: session) }, removeFromView: {
                            if windowComparisonID == nil || web.comparisonID == windowComparisonID {
                                session.updateState { $0.selected = false }
                            }
                            hiddenWebAgents.insert(session.id)
                        })
                            .frame(width: width).id(session.id.id)
                    }
                    if let comparison = nativeComparison {
                        ForEach(displayedMembers) { member in
                            if !displayedSessions.isEmpty || member.id != displayedMembers.first?.id { Divider() }
                            ConversationView(model: model, comparisonID: comparison.id, memberID: member.id, removeFromView: {
                                if windowComparisonID == nil || web.comparisonID == windowComparisonID {
                                    model.state.selection.remove(member.id)
                                    model.persist()
                                }
                                hiddenMembers.insert(member.id)
                            })
                                .frame(width: width).id(member.id.uuidString)
                        }
                    }
                    ForEach(unsentAgents) { agent in
                        if !displayedSessions.isEmpty || agent.id != unsentAgents.first?.id { Divider() }
                        VStack(spacing: 0) {
                            ContactHeader(agent: agent, name: agent.name + (model.demo ? " (Demo)" : ""), destination: model.route(agent)?.handle ?? "", removeFromView: {
                                model.state.selection.remove(agent.id)
                                hiddenMembers.insert(agent.id)
                                model.persist()
                            })
                            .background(.bar).disabled(sending)
                            Spacer()
                            Text("Your message has not been sent. Use Send & compare after signing in to your selected accounts.")
                                .foregroundStyle(.secondary).multilineTextAlignment(.center).padding(24)
                            Spacer()
                        }
                        .frame(width: width).id(agent.id.uuidString)
                    }
                }.frame(height: geometry.size.height)
            }.scrollIndicators(.visible)
        }
    }

    private func archivedMessages(for session: WebAgentSession) -> [WebPageMessage]? {
        guard let comparison = nativeComparison else { return nil }
        if comparison.endedAt != nil { return comparison.endedWebHistory?[session.id.id] ?? [] }
        if windowComparisonID != nil && session.state.comparisonID != comparison.id {
            return session.messagesForComparison(comparison.id)
        }
        return nil
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            let signedOut = selectedWebSessions.filter { !$0.provider.usesNativeConversation && $0.snapshot.signedIn == false }
            if !signedOut.isEmpty {
                Text("Sign in required: \(signedOut.map { $0.name }.formatted(.list(type: .and)))")
                    .font(.caption).foregroundStyle(.orange).accessibilityIdentifier("Website sign-in status")
            }
            if !selectedWebSessions.isEmpty && !attachments.isEmpty {
                Text("Web agents support text here. Remove the attachments or deselect them to send.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if showingComparison { ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    Text("Send to").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.recipientWebSessions(for: nativeComparison), id: \.id) { session in
                        recipient(session.name, selected: session.isEnabled && session.state.selected) { selectRecipient(session) }
                            .disabled(!session.isEnabled)
                    }
                    ForEach(model.recipientMessageAgents(for: nativeComparison)) { agent in
                        recipient(agent.name, selected: model.state.selection.contains(agent.id)) {
                            if let comparison = nativeComparison, !comparison.members.contains(where: { $0.id == agent.id }) {
                                model.webBroadcastBusy = true
                                Task { @MainActor in
                                    defer { model.webBroadcastBusy = false }
                                    await model.addAgent(agent, to: comparison.id)
                                }
                            } else { hiddenMembers.remove(agent.id); toggle(agent.id) }
                        }
                            .disabled(model.route(agent) == nil)
                            .help("Messages · \(agent.name)")
                    }
                }
            }.scrollIndicators(.hidden).disabled(nativeComparison?.endedAt != nil) }
            if showingComparison, let comparison = nativeComparison {
                FollowUpStatus(model: model, comparison: comparison, universal: true).disabled(busy)
            }
            MessageInput(text: Binding(get: {
                if let windowComparisonID { return model.state.workspaceDrafts?[windowComparisonID.uuidString] ?? model.comparison(windowComparisonID)?.allDraft ?? "" }
                return model.state.draft
            }, set: { text in
                if let windowComparisonID, web.comparisonID != windowComparisonID {
                    if model.state.workspaceDrafts == nil { model.state.workspaceDrafts = [:] }
                    model.state.workspaceDrafts?[windowComparisonID.uuidString] = text
                    model.persist()
                } else { model.setSharedDraft(text) }
            }),
                         attachments: attachments, addAttachments: { await model.addAttachments($0, comparisonID: attachmentComparisonID) },
                         removeAttachment: { id in model.setAttachmentDraft(attachments.filter { $0.id != id }, comparisonID: attachmentComparisonID) },
                         placeholder: "Message", accessibilityName: "Shared prompt", sendLabel: "Send & compare",
                         disabled: !canSend, attachmentsEnabled: selectedWebSessions.isEmpty,
                         sendDisabledReason: sharedSendDisabledReason, send: send, focusRequest: newBlastRequest)
        }.padding(20)
    }

    private func recipient(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                Text(title)
            }.font(.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 6)
        }.buttonStyle(.plain).background(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08), in: Capsule())
            .accessibilityLabel("Recipient \(title)").accessibilityValue(selected ? "Selected" : "Not selected").disabled(busy)
    }

    private func selectRecipient(_ session: WebAgentSession) {
        guard !busy, session.provider.supportsSharedSubmissions else { return }
        hiddenWebAgents.remove(session.id)
        guard let comparison = nativeComparison, !comparison.resolvedWebAgentIDs.contains(session.id) else {
            web.toggle(session)
            return
        }
        model.webBroadcastBusy = true
        web.select(session, selected: true)
        if !session.provider.usesNativeConversation { session.connect() }
        Task { @MainActor in
            defer { model.webBroadcastBusy = false }
            _ = await model.joinWebAgent(session, comparisonID: comparison.id)
        }
    }

    private func toggle(_ id: UUID) {
        if model.state.selection.contains(id) { model.state.selection.remove(id) }
        else { model.state.selection.insert(id) }
        model.persist()
    }

    private func send() {
        guard canSend else { return }
        let model = model
        let sessions = selectedWebSessions
        let recipients = Set(nativeRecipients.map(\.id))
        if !showingComparison {
            let previousSelection = model.state.selection
            model.state.selection = recipients
            do { try model.save() }
            catch { model.state.selection = previousSelection; model.error = error.localizedDescription; return }
            let included = Set(sessions.map(\.id))
            for session in web.sessions where session.provider.supportsSharedSubmissions && session.state.selected && !included.contains(session.id) {
                session.updateState { $0.selected = false }
            }
        }
        if !showingComparison && selectedWebSessions.isEmpty {
            Task { await model.start(recipientIDs: recipients) }
            return
        }
        let originalDraft = model.state.draft
        let submittedDraftRevision = model.sharedDraftRevision.value
        let sentAttachments = attachments
        let broadcastCreated = Date()
        let existingID = showingComparison ? nativeComparison?.id : nil
        guard model.beginSharedWebBroadcast() else { return }
        showingComparison = true
        Task { @MainActor in
            defer { model.finishSharedWebBroadcast() }
            let needsSignIn = await web.signInRequired(for: sessions)
            if !needsSignIn.isEmpty {
                signInProviders = needsSignIn
                showingConnectionIntro = true
                return
            }
            guard let preparation = await web.prepareComparisonRecipients(existingID, for: sessions, startNativeApps: true),
                  existingID.flatMap({ model.comparison($0)?.endedAt }) == nil else { return }
            let readySessions = sessions.filter { preparation[$0.id] == true }
            let failedSessions = sessions.filter { preparation[$0.id] != true }
            // Website sign-in and joining an existing comparison retain their
            // explicit setup flow; do not silently change their conversation context.
            guard failedSessions.allSatisfy({ $0.provider.desktopApp != nil }),
                  existingID.map({ id in failedSessions.allSatisfy { model.comparison(id)?.resolvedWebAgentIDs.contains($0.id) == true } }) ?? true,
                  !readySessions.isEmpty || !recipients.isEmpty else { return }
            let failures = failedSessions.map { ($0, $0.error ?? $0.snapshot.reason) }
            let comparisonID: UUID
            if let existingID { comparisonID = existingID }
            else {
                guard let id = await model.prepareWebComparison(originalDraft.trimmingCharacters(in: .whitespacesAndNewlines), recipientIDs: recipients, agents: sessions.map(\.id)) else { return }
                comparisonID = id
            }
            if existingID != nil {
                for session in readySessions where model.comparison(comparisonID)?.resolvedWebAgentIDs.contains(session.id) != true {
                    guard await model.joinWebAgent(session, comparisonID: comparisonID) else { return }
                }
            }
            guard model.comparison(comparisonID)?.endedAt == nil else { return }
            if let i = model.index(comparisonID) {
                let previous = model.state.comparisons[i].resolvedWebAgentIDs
                model.state.comparisons[i].setWebAgents(previous + sessions.map(\.id))
                do { try model.save() } catch { model.error = error.localizedDescription; return }
            }
            do { try model.freezeSharedContext(comparisonID) } catch { model.error = error.localizedDescription; return }
            var unsent: [WebAgentID: WebSendAttempt] = [:]
            for (session, reason) in failures {
                guard let attempt = session.recordUnsentPreparation(originalDraft.trimmingCharacters(in: .whitespacesAndNewlines), comparisonID: comparisonID, reason: reason) else { return }
                unsent[session.id] = attempt
            }
            let unsentAttempts = unsent
            let allRecipients = model.comparison(comparisonID).map { comparison in
                Set(comparison.resolvedWebAgentIDs) == Set(sessions.map(\.id)) && Set(comparison.members.map(\.id)) == recipients
            } ?? false
            let followUpID = UUID()
            let telemetryStarted = Date()
            let barrier = BroadcastSubmissionBarrier {
                guard !Task.isCancelled, !sessions.isEmpty,
                      web.comparisonID == comparisonID, model.comparison(comparisonID)?.endedAt == nil else { return }
                model.finishSharedWebInputs()
            }
            let result = await AgentBroadcast.send(draft: originalDraft, currentDraft: { model.state.draft }, shouldClearDraft: {
                model.sharedDraftRevision.value == submittedDraftRevision && web.comparisonID == comparisonID
            }, clearDraft: {
                model.setSharedDraft("")
            }, web: { text in
                let submitted = await WebAgents.send(text, to: readySessions, comparisonID: comparisonID, onInputsFinished: { barrier.finishNativeInputs() })
                return unsentAttempts.merging(submitted) { _, latest in latest }
            }, messages: { text in
                defer { if !Task.isCancelled { barrier.finishMessages() } }
                guard !recipients.isEmpty else { return nil }
                if existingID != nil {
                    guard let i = model.index(comparisonID) else { return nil }
                    model.state.comparisons[i].allDraft = text
                    await model.followUp(comparisonID, recipients: Array(recipients), newAttemptID: followUpID)
                    return model.comparison(comparisonID)?.followUps.contains(where: { $0.id == followUpID }) == true ? comparisonID : nil
                }
                await model.submit(comparisonID, retry: false)
                return comparisonID
            })
            let webSubmitted = result.web.values.filter { $0.status.confirmsSubmission }.count
            let messagesSubmitted = model.comparison(comparisonID).map { comparison in
                existingID == nil ? comparison.members.filter { recipients.contains($0.id) && $0.submission == .submitted }.count :
                comparison.followUps.first(where: { $0.id == followUpID })?.states.values.filter { $0 == .submitted }.count ?? 0
            } ?? 0
            if webSubmitted + messagesSubmitted > 0 {
                model.recordMessageSubmission(kind: .shared, recipientCount: webSubmitted + messagesSubmitted, started: telemetryStarted, logicalID: existingID == nil ? comparisonID : followUpID)
            } else { model.recordOperation(.send, success: false, started: telemetryStarted) }
            if existingID != nil, allRecipients,
               result.web.values.allSatisfy({ $0.status.confirmsSubmission }), result.web.count == sessions.count,
               let i = model.index(comparisonID) {
                if recipients.isEmpty {
                    model.state.comparisons[i].recordSharedMessage(ConversationContextMessage(text: originalDraft.trimmingCharacters(in: .whitespacesAndNewlines), attachments: sentAttachments, created: broadcastCreated))
                } else if result.comparisonID == comparisonID {
                    model.state.comparisons[i].completeSharedBroadcast(followUpID: followUpID, recipients: recipients)
                }
                model.persist()
            }
            web.setComparison(comparisonID)
        }
    }

    private func sendDirect(_ text: String, to session: WebAgentSession) {
        guard nativeComparison?.endedAt == nil else { return }
        let independent = canReplyWhileBroadcasting(to: session)
        guard (!busy || independent), session.isEnabled, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let existingID = nativeComparison?.id
        if independent {
            guard model.beginIndependentNativeReply() else { return }
        } else { model.webBroadcastBusy = true }
        Task { @MainActor in
            defer {
                if independent { model.finishIndependentNativeReply() }
                else { model.webBroadcastBusy = false }
            }
            let id: UUID
            if let existingID { id = existingID }
            else {
                guard let created = await model.prepareWebComparison(text, recipientIDs: [], agents: [session.id]) else { return }
                id = created
            }
            do { try model.freezeSharedContext(id) } catch { model.error = error.localizedDescription; return }
            guard let i = model.index(id) else { return }
            if model.state.comparisons[i].resolvedWebAgentIDs.contains(session.id) != true {
                model.state.comparisons[i].setWebAgents(model.state.comparisons[i].resolvedWebAgentIDs + [session.id])
            }
            do { try model.save() } catch { model.error = error.localizedDescription; return }
            showingComparison = true
            let telemetryStarted = Date()
            let attempt = await session.send(text, comparisonID: id)
            if let attempt, attempt.status.confirmsSubmission {
                model.recordMessageSubmission(kind: .private, recipientCount: 1, started: telemetryStarted, logicalID: attempt.id)
            } else { model.recordOperation(.send, success: false, started: telemetryStarted) }
            web.setComparison(id)
        }
    }
}

struct LocalAgentSettingsView: View {
    @ObservedObject var agent: PersonalAgentController
    @ObservedObject var web: WebAgents
    var busy = false
    @State private var setupRuntime: LocalAgentRuntime?
    private var isBusy: Bool { busy || !agent.running.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(agent.demo ? "Your local accounts (simulated)" : "Your local accounts").font(.headline)
                Spacer()
                Button {
                    Task { await refresh() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh accounts")
                    .accessibilityLabel("Refresh accounts")
                    .disabled(isBusy || agent.checkingAccounts || agent.detectingLocalAgents)
            }.padding(.bottom, 12)
            Text("Enable a CLI to add it as a separate agent.")
                .font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
            ForEach(WebProvider.optionalProviders) { webProvider in
                let provider = webProvider.personalAgentProvider!
                Toggle("Enable \(webProvider.name)", isOn: Binding(
                    get: { web.sessions.first(where: { $0.provider == webProvider })?.isEnabled == true },
                    set: { web.setEnabled($0, for: webProvider) }
                )).toggleStyle(.switch).accessibilityIdentifier("Enable \(webProvider.name)")
                    .disabled(isBusy).padding(.top, 8)
                let installed = agent.installed.contains { $0.provider == provider }
                let connected = [.subscription, .apiKey, .other].contains(agent.accounts[provider] ?? PersonalAgentAccountStatus.unknown)
                accountRow(name: webProvider.name,
                           icon: provider == .codex ? "chatgpt" : "claude",
                           status: installed ? (agent.accounts[provider]?.label ?? "Checking sign-in…") : "Not installed") {
                    if installed {
                        Button(connected ? "Switch account" : provider == .codex ? "Sign in with ChatGPT" : "Sign in with Claude") { agent.signIn(provider) }
                            .disabled(agent.demo || isBusy || agent.checkingAccounts)
                    } else {
                        Link("Install \(provider.name)", destination: URL(string: provider == .codex
                             ? "https://developers.openai.com/codex/cli" : "https://code.claude.com/docs/en/setup")!)
                    }
                }
                Divider()
            }
            ForEach(LocalAgentRuntime.allCases) { runtime in
                let installed = agent.detectedLocalAgents.contains { $0.runtime == runtime }
                accountRow(name: runtime.name, icon: runtime == .openclaw ? "openclaw" : "hermes",
                           status: agent.detectingLocalAgents ? "Checking installation…" : installed ? "CLI found · Provider setup not checked" : "CLI not found") {
                    if installed {
                        Button("Set up \(runtime.name)") { setupRuntime = runtime }.disabled(isBusy)
                    } else {
                        Button("Setup instructions") { setupRuntime = runtime }.disabled(isBusy)
                        Link("Install \(runtime.name)", destination: runtime.documentation)
                    }
                }
                Text(runtime == .openclaw
                     ? "Setup shortcut only · OpenClaw chats and reports are not connected yet."
                     : "Messages comparison reports · Configure your provider and model in Terminal.")
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 44).padding(.bottom, 10)
                if runtime != LocalAgentRuntime.allCases.last { Divider() }
            }
            if agent.demo {
                Text("Demo accounts · sign-in and setup are simulated.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }
            if let error = agent.accountError {
                Text(error).font(.caption).foregroundStyle(.orange).padding(.top, 8)
            }
        }
        .padding(16)
        .background(.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 640)
        .sheet(item: $setupRuntime) { runtime in
            LocalAgentSetupView(agent: agent, runtime: runtime)
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        if agent.demo { await agent.discover() }
        async let accounts: Void = agent.refreshAccounts()
        async let installations: Void = agent.detectLocalAgents()
        _ = await (accounts, installations)
    }

    private func accountRow<Action: View>(name: String, icon: String, status: String,
                                          @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 12) {
            if let image = localAccountIcons[icon] {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(name).fontWeight(.medium)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            action().controlSize(.regular)
        }.padding(.vertical, 10)
    }
}

struct LocalAgentTerminalInstructions: View {
    let runtime: LocalAgentRuntime

    private var steps: [String] {
        runtime == .openclaw ? [
            "Choose Model in the wizard, then select your AI provider.",
            "Complete the provider’s sign-in flow or enter its API key in Terminal.",
            "Choose a default model and save the configuration."
        ] : [
            "Choose your AI provider and model in the setup wizard.",
            "Complete the provider’s sign-in flow or enter its API key in Terminal, then save the setup.",
            "Return to msgblast and refresh local accounts. Open a Messages comparison’s report with Summarize. Choose Hermes in Report options from the ellipsis menu for your next Generate report or Update report."
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(runtime == .openclaw
                 ? "This configures OpenClaw itself. OpenClaw is not connected to msgblast chats or comparison reports yet; you can skip this setup."
                 : "Hermes can generate comparison reports from Messages replies. It does not have a msgblast chat pane. Reports use your configured provider and its usage limits.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text("In Terminal").font(.headline)
            Text(runtime.setup).font(.body.monospaced()).textSelection(.enabled)
            Text("Continue in Terminal runs this command for you. Complete these steps in its wizard:")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1).").foregroundStyle(.secondary)
                    Text(step).fixedSize(horizontal: false, vertical: true)
                }.font(.callout)
            }
            Text(runtime == .openclaw
                 ? "First-time OpenClaw setup? Run openclaw onboard for its full setup wizard. Returning here does not connect OpenClaw to msgblast."
                 : "To change a configured provider or model, run hermes model. A messaging gateway is not required for comparison reports.")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Link("Official \(runtime.name) setup guide", destination: runtime.documentation)
                .font(.callout)
        }
    }
}

private struct LocalAgentSetupView: View {
    @ObservedObject var agent: PersonalAgentController
    let runtime: LocalAgentRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var showingDetails = false
    private var installed: Bool { agent.detectedLocalAgents.contains { $0.runtime == runtime } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Set up \(runtime.name)").font(.title2.bold())
            if !installed {
                Text("Install the command-line app from the guide below, then return here and refresh local accounts.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            LocalAgentTerminalInstructions(runtime: runtime)
            if agent.demo {
                Label("Simulated installation · Terminal setup is disabled", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Installation details", isExpanded: $showingDetails) {
                VStack(alignment: .leading, spacing: 8) {
                    if let installation = agent.detectedLocalAgents.first(where: { $0.runtime == runtime }), !agent.demo {
                        Text(installation.executableURL.path).font(.caption).textSelection(.enabled)
                    }
                    Text("msgblast finds the command-line app; it does not verify provider sign-in or model configuration.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }.font(.callout)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Continue in Terminal") {
                    agent.setUp(runtime)
                    dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(agent.demo || !installed || agent.detectingLocalAgents)
            }
        }.padding(24).frame(width: 520)
    }
}

private struct WebAgentPane: View {
    @ObservedObject var session: WebAgentSession
    @ObservedObject var account: PersonalAgentController
    @State private var showingDesktopOptions = false
    let busy: Bool
    var allowPrivateReplyWhileBusy = false
    var endedMessages: [WebPageMessage]? = nil
    var removalDisabled = false
    let sendNative: (String) -> Void
    let removeFromView: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                AgentAvatar(agent: AgentArtwork.agent(for: session), name: session.name, size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.name).font(.headline)
                    Text(session.locationLabel).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if session.loading { ProgressView().controlSize(.small) }
                if session.provider.desktopApp != nil {
                    Button { showingDesktopOptions = true } label: { Image(systemName: "gearshape") }
                        .help("\(session.name) options").accessibilityLabel("\(session.name) options")
                        .popover(isPresented: $showingDesktopOptions) {
                            VStack(alignment: .leading, spacing: 16) {
                                HStack {
                                    Text("\(session.name) options").font(.headline)
                                    Spacer()
                                    Button("Done") { showingDesktopOptions = false }
                                }
                                DesktopAppSetupView(session: session, busy: busy, showConnectionConfirmation: false)
                            }.padding(20).frame(width: 440)
                        }
                }
                if session.provider == .grokbot {
                    SettingsLink { Image(systemName: "gearshape") }
                        .help("Grok Bot settings").accessibilityLabel("Grok Bot settings")
                } else {
                    Button { session.reload() } label: { Image(systemName: "arrow.clockwise") }.help("Reload \(session.name)").accessibilityLabel("Reload \(session.name)").disabled(busy || endedMessages != nil)
                }
            }.padding(14).background(.bar).contentShape(Rectangle())
                .accessibilityIdentifier("Agent header \(session.name)")
                .contextMenu { Button("Remove from view", action: removeFromView).disabled(removalDisabled) }
            if session.needsConversationLink {
                HStack {
                    Text(session.canLinkCurrentConversation ? "Continue in this conversation." : "Open the original chat to continue this comparison.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Use this conversation") { Task { await session.linkCurrentConversation() } }
                        .disabled(busy || !session.canLinkCurrentConversation)
                }.padding(10)
            }
            if let latest = session.latestComparisonAttempt, !session.isAutomaticallyWaitingForNativeReply,
               !(session.provider.desktopApp != nil && latest.status == .waiting && latest.messageID != nil),
               latest.status.showsAttemptBanner(for: session.provider) {
                VStack(alignment: .leading, spacing: 3) {
                    Label(latest.status.label(for: session.provider), systemImage: "info.circle")
                        .font(.caption.weight(.semibold))
                    Text(latest.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let detail = latest.detail, detail != session.desktopRecoveryMessage { Text(detail).font(.caption).foregroundStyle(.secondary) }
                    if latest.status == .notSent, latest.messageID == nil, session.provider.desktopApp != nil {
                        Button("Retry") { sendNative(latest.text) }
                            .disabled(busy || !session.canSubmitNativePrompt)
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .contain)
            }
            if let error = session.error, error != session.latestComparisonAttempt?.detail,
               endedMessages != nil || session.desktopRecoveryMessage != error {
                Text(error).font(.caption).foregroundStyle(.orange).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let draft = session.draftRecoveryText {
                HStack {
                    Text("Your saved draft is retained. Copy it into this chat to continue.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy saved draft") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(draft, forType: .string)
                    }
                }.padding(10)
            }
            if let endedMessages {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(endedMessages) { message in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(message.role == "user" ? "You" : session.name).font(.caption.bold()).foregroundStyle(.secondary)
                                Text(message.text).textSelection(.enabled)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(message.role == "user" ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }.padding(12)
                }
            } else if session.provider.usesNativeConversation {
                nativeConversation(session.provider.personalAgentProvider)
            } else if session.connected {
                if session.provider == .dots {
                    Text("Blasts continue your ongoing dot conversation.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
                }
                EmbeddedServicePage(webView: session.webView).id(ObjectIdentifier(session.webView))
            } else {
                VStack(spacing: 18) {
                    AgentAvatar(agent: AgentArtwork.agent(for: session), name: session.name, size: 80)
                    Text("\(session.name), inside MsgBlast").font(.title2.weight(.semibold))
                    Text("Sign in here once, then send from the shared composer. Your \(session.name) conversation and replies stay in this window.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                    Button("Connect \(session.name)") { session.connect() }.buttonStyle(.borderedProminent).controlSize(.large)
                    Text("Safari’s login is separate. MsgBlast remembers its own web session.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(28)
            }
        }
        .task { if endedMessages == nil, session.provider.personalAgentProvider != nil { await account.discover() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if session.provider.personalAgentProvider != nil { session.reload() }
        }
        .sheet(isPresented: Binding(get: { session.popup != nil }, set: { if !$0 { session.closePopup() } })) {
            VStack(spacing: 0) {
                HStack {
                    Text(session.popupURL).font(.caption).textSelection(.enabled).lineLimit(2)
                    Spacer()
                    Button("Done") { session.closePopup() }
                }.padding(12)
                Divider()
                if let popup = session.popup { EmbeddedServicePage(webView: popup) }
            }.frame(minWidth: 650, minHeight: 650)
        }
    }

    private func nativeMessage(_ message: WebPageMessage, status: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(message.role == "user" ? "You" : session.name).font(.caption.bold()).foregroundStyle(.secondary)
            Text((try? AttributedString(markdown: message.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(message.text))
                .textSelection(.enabled)
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(message.role == "user" ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            .id(message.id)
    }

    private func nativeStatus(_ message: WebPageMessage) -> String? {
        guard message.role == "user", let attempt = session.state.attempts.first(where: {
            ($0.messageID ?? $0.id.uuidString) == message.id
        }) else { return nil }
        if attempt.status == .observed { return nil }
        if attempt.messageID != nil { return "Sent" }
        if attempt.status == .uncertain { return "Submission unconfirmed" }
        return [.preparing, .attempting].contains(attempt.status) ? "Sending…" : nil
    }

    private var nativeMessages: [WebPageMessage] {
        var messages = session.snapshot.messages
        if let attempt = session.pendingNativeAttempt {
            messages.append(WebPageMessage(id: attempt.id.uuidString, role: "user", text: attempt.text))
        }
        return messages
    }

    private func nativeConversation(_ provider: PersonalAgentProvider?) -> some View {
        VStack(spacing: 12) {
            let connected = session.provider.desktopApp != nil ? session.desktopReady : session.provider == .grokbot ? session.grokBotIsConfigured : [.subscription, .apiKey, .other].contains(session.accountStatus)
            if !session.provider.isAvailableInBuild {
                Text("\(session.name) is unavailable in this build. Your saved conversation is preserved.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !session.isEnabled {
                Text("Enable \(session.name) in Settings to send. Your saved conversation is still available here.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let app = session.provider.desktopApp, !connected,
                      let recovery = session.desktopRecoveryMessage {
                HStack {
                    Text(recovery)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if session.desktopInstallation.isInstalled {
                        Button("Reconnect") { Task {
                            if !session.desktopInstallation.isRunning { await session.openDesktopApp() }
                            await session.connectDesktopConversation(botName: session.state.desktopConversation?.name)
                        } }.disabled(busy || session.loading || session.isSending)
                    } else {
                        Link("Get \(app.name)", destination: session.provider.homeURL)
                    }
                }.accessibilityIdentifier("desktop-connection-recovery")
            } else if session.provider == .grokbot {
                if session.fixture {
                    Text("Simulated webhook and callback · no Bot contacted")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !connected {
                    Text("Connect your Grok Bot webhook using the settings gear.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if !connected, let provider {
                HStack {
                    Label(session.fixture ? "Simulated local account · no provider requests" : session.accountStatus.label,
                          systemImage: "person.crop.circle")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if account.installed.contains(where: { $0.provider == provider }) {
                        Button(provider == .codex ? "Sign in with ChatGPT" : "Sign in with Claude") { account.signIn(provider) }
                            .disabled(session.fixture || busy)
                    } else {
                        Link("Install \(provider.name)", destination: URL(string: provider == .codex
                             ? "https://developers.openai.com/codex/cli" : "https://code.claude.com/docs/en/setup")!)
                    }
                }
                if let error = account.accountError { Text(error).font(.caption).foregroundStyle(.orange) }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if session.snapshot.messages.isEmpty, session.pendingNativeAttempt == nil {
                            Text(session.provider.desktopApp != nil ? "Send a message to start a conversation." : connected ? "Ready to chat. Send a message below, or use the shared message box to ask your selected agents." : "Sign in to \(session.name) to start chatting. Your request stays in the message box until you send it.")
                                .foregroundStyle(.secondary).padding(.vertical, 20)
                        }
                        ForEach(nativeMessages) { message in
                            nativeMessage(message, status: nativeStatus(message))
                        }
                        if session.isSending { ProgressView(session.provider == .grokbot ? "Sending to Grok Bot…" : "\(session.name) is replying…").id("replying") }
                    }
                }.onChange(of: session.snapshot.messages.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }.onChange(of: session.pendingNativeAttempt?.id) { _, id in
                    if let id { proxy.scrollTo(id.uuidString, anchor: .bottom) }
                }
            }
            if session.isSending, provider != nil || session.provider.desktopApp != nil { Button("Cancel \(session.name) reply") { session.cancelNativeRequest() } }
            if let attempt = session.incompleteDesktopAttempt, attempt.comparisonID != session.state.comparisonID {
                let origin = "“" + String(attempt.text.prefix(80)) + "”"
                Text("An incomplete request in \(origin) is blocking this app. Review its reply in the native app before continuing.")
                    .font(.caption).foregroundStyle(.orange)
                Button("Acknowledge that incomplete request") { session.acknowledgeIncompleteRequest(attemptID: attempt.id) }
                    .disabled(busy || session.isSending)
            }
            if session.isAutomaticallyWaitingForNativeReply {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Waiting for \(session.name)…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop waiting") { session.acknowledgeIncompleteRequest() }.disabled(busy)
                }
            } else if session.latestComparisonAttempt?.status == .uncertain {
                Text("The last request was incomplete. Continuing may consume provider usage again.").font(.caption).foregroundStyle(.orange)
                Button("Acknowledge incomplete request") { session.acknowledgeIncompleteRequest() }.disabled(busy)
            }
            if session.provider == .grokbot, session.latestComparisonAttempt?.status == .waiting {
                Text("Grok Bot may continue working if you stop waiting.").font(.caption).foregroundStyle(.secondary)
                Button("Stop waiting for this reply") { session.acknowledgeIncompleteRequest() }.disabled(busy)
            }
            MessageInput(text: Binding(get: { session.state.draft }, set: { text in session.updateState { $0.draft = text } }),
                attachments: [], addAttachments: { _ in }, removeAttachment: { _ in }, placeholder: "Message \(session.name)",
                accessibilityName: "Message \(session.name)", sendLabel: "Send to \(session.name)",
                disabled: (busy && !allowPrivateReplyWhileBusy) || !session.canSubmitNativePrompt, attachmentsEnabled: false) {
                    sendNative(session.state.draft)
                }
        }.padding(14)
    }

}

private let localAccountIcons: [String: NSImage] = Dictionary(uniqueKeysWithValues:
    ["chatgpt.jpg", "claude.jpg", "openclaw.png", "hermes.png"].compactMap { filename in
        guard let url = Bundle.main.url(forResource: filename, withExtension: nil, subdirectory: "WebAgentIcons"),
              let image = NSImage(contentsOf: url) else { return nil }
        return (url.deletingPathExtension().lastPathComponent, image)
    }
)

// Resize only when the open-chat count changes; ordinary manual resizing stays intact.
private struct ChatWindowFrame: NSViewRepresentable {
    let chatCount: Int
    var enabled = true
    func makeNSView(context: Context) -> ChatWindowSizingView { ChatWindowSizingView() }
    func updateNSView(_ view: ChatWindowSizingView, context: Context) {
        view.enabled = enabled
        guard view.chatCount != chatCount else { return }
        view.chatCount = chatCount
        view.needsLayout = true
    }
}

private final class ChatWindowSizingView: NSView {
    var chatCount = -1
    var enabled = true
    private var appliedCount: Int?
    override func layout() {
        super.layout()
        guard enabled, chatCount > 0, let window, bounds.width > 0, appliedCount == nil else { return }
        let count = chatCount
        appliedCount = count
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.chatCount == count,
                  !window.styleMask.contains(.fullScreen), let screen = window.screen else { return }
            let available = screen.visibleFrame
            let surroundingWidth = max(0, window.frame.width - self.bounds.width)
            let width = WindowLayout.chatWindowWidth(count: count, surroundingWidth: surroundingWidth, screenWidth: available.width)
            var frame = window.frame
            frame.size.width = width
            frame.origin.x = min(max(frame.minX, available.minX), available.maxX - width)
            window.setFrame(frame, display: true)
        }
    }
}

// SwiftUI owns the main window delegate. Forward its lifecycle rather than replacing it.
struct ConversationCloseBridge: NSViewRepresentable {
    @ObservedObject var model: AppModel
    let comparisonID: UUID?
    func makeNSView(context: Context) -> ConversationCloseView { ConversationCloseView() }
    func updateNSView(_ view: ConversationCloseView, context: Context) {
        view.owner = model.coordinator
        view.comparisonID = comparisonID
        view.install()
    }
    static func dismantleNSView(_ view: ConversationCloseView, coordinator: ()) { view.detach() }
}

final class ConversationCloseView: NSView, NSWindowDelegate {
    weak var owner: WindowCoordinator?
    var comparisonID: UUID?
    nonisolated(unsafe) weak var originalDelegate: (any NSWindowDelegate)?
    weak var installedWindow: NSWindow?
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); install() }
    func install() {
        guard let window else { return }
        // Dedicated windows already use the same confirmation owner.
        if window.delegate === owner { return }
        if installedWindow !== window {
            detach()
            originalDelegate = window.delegate
            installedWindow = window
            window.isReleasedWhenClosed = false
            window.delegate = self
        }
        owner?.workspaceWindow = window
        owner?.workspaceComparisonID = comparisonID
    }
    func detach() {
        if let installedWindow, installedWindow.delegate === self { installedWindow.delegate = originalDelegate }
        installedWindow = nil
    }
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || originalDelegate?.responds(to: selector) == true
    }
    override func forwardingTarget(for selector: Selector!) -> Any? {
        originalDelegate?.responds(to: selector) == true ? originalDelegate : super.forwardingTarget(for: selector)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let owner else { return originalDelegate?.windowShouldClose?(sender) ?? true }
        if let comparisonID, owner.confirmClose(sender, comparisonID: comparisonID) == false { return false }
        owner.dismissConversationWindow(sender)
        return false
    }
}
