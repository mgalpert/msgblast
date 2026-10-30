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
    @State private var requestedAgents: Set<WebAgentID> = []
    @State private var showingDetails = false
    @State private var optionsSession: OptionsTarget?
    @State private var pinnedExpanded = false
    /// `sheet(item:)` needs an `Identifiable` value; a session has an id but does not declare the conformance.
    private struct OptionsTarget: Identifiable {
        let session: WebAgentSession
        let id: String
        @MainActor init(_ session: WebAgentSession) { self.session = session; id = session.id.id }
    }
    /// A status line this long or longer keeps its full text behind an ⓘ.
    private static let shortLineLength = 60
    private var sending: Bool { model.busy || model.webBroadcastBusy || web.sessions.contains { $0.isSending } }
    private var canUseOtherRecipients: Bool {
        !model.busy && model.webBroadcastBusy && model.webBroadcastReplyGate.canBrowseWhileWaiting &&
            model.webBroadcastReplyGate.canBeginBroadcast(in: web.comparisonID)
    }
    private var busy: Bool { (windowComparisonID != nil && web.comparisonID != windowComparisonID) || (sending && !canUseOtherRecipients) }
    private var nativeRecipients: [Agent] {
        let ids = model.messageGridIDs
        let shown = Set(model.agentGridLayout.visibleIDs)
        return model.state.agents.filter { model.state.selection.contains($0.id) &&
            (showingComparison || shown.contains(ids[$0.id] ?? .messages($0.id))) }
    }
    private var selectedWebSessions: [WebAgentSession] {
        let members = showingComparison ? nativeComparison.map { Set($0.resolvedWebAgentIDs) } : nil
        return web.broadcastSelection.filter { session in
            if let members { return members.contains(session.id) }
            return showingComparison || model.isVisibleInAgentGrid(session.id.gridID)
        }
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
        let drafts = selectedWebSessions.filter { !$0.provider.usesNativeConversation && $0.snapshot.hasDraft }.map { $0.name }
        guard !drafts.isEmpty else { return nil }
        let names = drafts.formatted(.list(type: .and))
        return "Finish or clear the draft in \(names), or deselect \(names) to send to the other agents."
    }
    /// The one selected app agent that can take a private reply while the broadcast still runs.
    private var directReplySession: WebAgentSession? {
        guard busy, nativeRecipients.isEmpty, selectedWebSessions.count == 1, let session = selectedWebSessions.first,
              canReplyWhileBroadcasting(to: session) else { return nil }
        return session
    }
    private var canSend: Bool {
        let text = model.state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if directReplySession != nil && !text.isEmpty && attachments.isEmpty && nativeComparison?.endedAt == nil { return true }
        return nativeComparison?.endedAt == nil && !busy && !WebAgents.hasConflictingNativeRecipients(selectedWebSessions.map(\.provider)) && preparingDesktopSessions.isEmpty && !editingAgents && !showingConnectionIntro && (!selectedWebSessions.isEmpty || !nativeRecipients.isEmpty)
            && (selectedWebSessions.isEmpty || (!text.isEmpty && attachments.isEmpty))
            && selectedWebSessions.allSatisfy { $0.provider.usesNativeConversation || ($0.snapshot.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.draftRecoveryText == nil && !$0.hasUnresolvedSend(text)) }
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
                AgentGridView(model: model, web: web, editing: $editingAgents, busy: sending, selectionBusy: busy,
                    toggleMessages: toggle, openChat: { session in
                        if web.comparisonID == nil { model.deselectHiddenGridRecipients(); model.persist() }
                        if !session.state.selected { web.toggle(session) }
                        hiddenWebAgents.remove(session.id)
                        session.connect(); showingComparison = true
                    })
            }
            composer
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay { if showingConnectionIntro { connectionIntro } }
        .sheet(item: $optionsSession) { target in
            VStack(alignment: .leading, spacing: Space.screen) {
                HStack {
                    Text("\(target.session.name) Options").font(.headline)
                    Spacer()
                    Button("Done") { optionsSession = nil }.keyboardShortcut(.defaultAction)
                }
                DesktopAppSetupView(session: target.session, busy: sending, showConnectionConfirmation: false)
            }.padding(Space.screen).frame(width: Space.sheetWidth)
        }
        .task { if !model.webBroadcastBusy { web.connectSelected() } }
        .onChange(of: web.comparisonID) { _, _ in
            if windowComparisonID == nil { hiddenMembers = []; hiddenWebAgents = []; requestedAgents = [] }
        }
        .onChange(of: newBlastRequest) { _, _ in
            showingConnectionIntro = false; editingAgents = false
            if windowComparisonID == nil { hiddenMembers = []; hiddenWebAgents = []; requestedAgents = [] }
        }
        .onChange(of: showingComparison) { _, value in if value { editingAgents = false } }
        .toolbar {
            if showingComparison {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingDetails.toggle() } label: { Image(systemName: "info.circle") }
                        .help("Details").accessibilityLabel("Conversation details")
                        .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
                            ConversationDetailsView(title: nativeComparison?.title ?? "New Blast", members: detailsMembers,
                                                    additions: detailsAdditions, footer: detailsFooter)
                        }
                }
                ToolbarItem(placement: .primaryAction) {
                    ChatShareButton(title: nativeComparison?.title ?? "Chat", captureLayout: captureLayout)
                }
            }
            if !showingComparison {
                ToolbarItem(placement: .primaryAction) {
                    Button(editingAgents ? "Done" : "Edit") { editingAgents.toggle() }
                        .accessibilityLabel(editingAgents ? "Done editing agents" : "Edit agents")
                        .disabled(sending)
                }
            }
            if windowComparisonID == nil && !model.state.comparisons.isEmpty { ToolbarItem(placement: .navigation) {
                Button {
                    model.requestNewBlast()
                } label: {
                    Label("New Blast", systemImage: "square.and.pencil").labelStyle(.iconOnly)
                }
                .help("New Blast").accessibilityLabel("New Blast").disabled(!model.canStartNewBlast)
            } }
        }
    }

    // MARK: Details

    /// The agents workspace's pane `busy`: sends in flight, or another window owns the live comparison.
    private var paneBusy: Bool { sending || (windowComparisonID != nil && web.comparisonID != windowComparisonID) }

    /// Whether a column's agent receives the next message, and whether that can be changed now;
    /// the header and the Details popover share it.
    private func recipientState(_ session: WebAgentSession) -> (included: Bool, enabled: Bool) {
        let agentBusy = web.isBusyForSelection(session)
        let joined = nativeComparison?.resolvedWebAgentIDs.contains(session.id) ?? true
        return (session.isEnabled && session.state.selected && !agentBusy && joined,
                !(busy || agentBusy || !session.isEnabled || (model.webBroadcastBusy && !joined) || nativeComparison?.endedAt != nil))
    }

    private func removeSession(_ session: WebAgentSession) {
        if windowComparisonID == nil || web.comparisonID == windowComparisonID {
            session.updateState { $0.selected = false }
        }
        hiddenWebAgents.insert(session.id)
    }

    private func removeMember(_ id: UUID) {
        if windowComparisonID == nil || web.comparisonID == windowComparisonID {
            model.state.selection.remove(id)
            model.persist()
        }
        hiddenMembers.insert(id)
    }

    private func toggleMember(_ id: UUID) {
        hiddenMembers.remove(id)
        toggle(id)
    }

    /// Adds a Messages agent: into a saved conversation, or into the selection for a new one.
    private func addMessageAgent(_ agent: Agent) {
        if let comparison = nativeComparison, !comparison.members.contains(where: { $0.id == agent.id }) {
            guard !model.webBroadcastBusy else { return }
            model.webBroadcastBusy = true
            Task { @MainActor in
                defer { model.webBroadcastBusy = false }
                await model.addAgent(agent, to: comparison.id)
            }
        } else {
            hiddenMembers.remove(agent.id)
            if !model.state.selection.contains(agent.id) { toggle(agent.id) }
        }
    }

    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    /// The column header's menu items as Details actions.
    private func sessionActions(_ session: WebAgentSession) -> [DetailsAction] {
        var actions: [DetailsAction] = []
        if session.provider != .grokbot {
            actions.append(DetailsAction(id: "reload", title: "Reload", systemImage: "arrow.clockwise",
                                         disabled: paneBusy || archivedMessages(for: session) != nil) { session.reload() })
        }
        if session.provider.desktopApp != nil {
            actions.append(DetailsAction(id: "options", title: "Options…", systemImage: "gearshape") { optionsSession = OptionsTarget(session) })
        }
        if session.provider == .grokbot {
            actions.append(DetailsAction(id: "settings", title: "Grok Bot Settings…", systemImage: "gearshape") { openSettings() })
        }
        actions.append(DetailsAction(id: "remove", title: "Remove from View", systemImage: "eye.slash", disabled: sending) { removeSession(session) })
        return actions
    }

    private var detailsMembers: [DetailsMember] {
        let sessions = displayedSessions.map { session in
            let state = recipientState(session)
            return DetailsMember(id: session.id.id, agent: AgentArtwork.agent(for: session), name: session.name, detail: session.locationLabel,
                                 included: state.included, enabled: state.enabled, busy: session.loading,
                                 toggle: { selectRecipient(session) }, actions: sessionActions(session))
        }
        let members = displayedMembers.map { member in
            DetailsMember(id: member.id.uuidString, agent: model.state.agents.first { $0.id == member.id }, name: member.name, detail: member.chat.handle,
                          included: model.state.selection.contains(member.id), enabled: !(model.busy || model.webBroadcastBusy), busy: false,
                          toggle: { toggleMember(member.id) }, actions: [
                            DetailsAction(id: "open", title: "Open in Messages", systemImage: "message") { model.openMessages(member) },
                            DetailsAction(id: "remove", title: "Remove from View", systemImage: "eye.slash") { removeMember(member.id) }
                          ])
        }
        // Agents whose message is not sent yet (a new blast with no saved conversation).
        let unsent = unsentMessageAgents.map { agent in
            DetailsMember(id: agent.id.uuidString, agent: agent, name: agent.name, detail: model.route(agent)?.handle,
                          included: true, enabled: false, busy: false, toggle: {}, actions: [
                            DetailsAction(id: "remove", title: "Remove from View", systemImage: "eye.slash", disabled: sending) { removeUnsent(agent) }
                          ])
        }
        return sessions + members + unsent
    }

    private var detailsAdditions: [DetailsAddition] {
        let shownSessions = Set(displayedSessions.map(\.id))
        let sessions = model.recipientWebSessions(for: nativeComparison).filter { !shownSessions.contains($0.id) }.map { session in
            DetailsAddition(id: session.id.id, agent: AgentArtwork.agent(for: session), name: session.name,
                            enabled: !web.isBusyForSelection(session) && session.isEnabled && !model.webBroadcastBusy) { selectRecipient(session) }
        }
        let shownAgents = Set((nativeComparison?.members.map(\.id) ?? []) + unsentMessageAgents.map(\.id))
        let agents = model.recipientMessageAgents(for: nativeComparison).filter { !shownAgents.contains($0.id) }.map { agent in
            DetailsAddition(id: agent.id.uuidString, agent: agent, name: agent.name,
                            enabled: model.route(agent) != nil && !model.webBroadcastBusy) { addMessageAgent(agent) }
        }
        return sessions + agents
    }

    private var detailsFooter: [DetailsAction] {
        var actions: [DetailsAction] = []
        if !model.databaseAvailable {
            actions.append(DetailsAction(id: "access", title: "Check Messages Access", systemImage: "arrow.clockwise") { model.refresh() })
        }
        if let comparison = nativeComparison {
            actions.append(DetailsAction(id: "end", title: "End Conversation", systemImage: "xmark.circle", destructive: true, disabled: comparison.endedAt != nil) {
                _ = model.endConversation(comparison.id)
                showingDetails = false
            })
        }
        return actions
    }

    private func removeUnsent(_ agent: Agent) {
        model.state.selection.remove(agent.id)
        hiddenMembers.insert(agent.id)
        model.persist()
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
        if let comparison = nativeComparison {
            let joined = comparison.resolvedWebAgentIDs.compactMap { web.session(for: $0) }
            // Keep a joining agent's sign-in/preparation pane in this window too.
            let preparing = web.comparisonID == comparison.id ? web.sessions.filter {
                requestedAgents.contains($0.id) && !comparison.resolvedWebAgentIDs.contains($0.id)
            } : []
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
        VStack(spacing: 0) {
            // A group's forming prompt stays in view under the headers; the title is derived from it.
            if comparisonChatCount > 1, let prompt = nativeComparison?.prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                PinnedPromptRow(text: prompt, expanded: $pinnedExpanded)
            }
            chatColumns
        }
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
                        let state = recipientState(session)
                        WebAgentPane(session: session, account: model.personalAgent, busy: paneBusy, endedMessages: archivedMessages(for: session), removalDisabled: sending,
                                     isRecipient: state.included, recipientEnabled: state.enabled,
                                     toggleRecipient: { selectRecipient(session) }, showOptions: { optionsSession = OptionsTarget(session) },
                                     sendNative: { sendDirect($0, to: session) }, removeFromView: { removeSession(session) })
                            .frame(width: width).id(session.id.id)
                    }
                    if let comparison = nativeComparison {
                        ForEach(displayedMembers) { member in
                            if !displayedSessions.isEmpty || member.id != displayedMembers.first?.id { Divider() }
                            ConversationView(model: model, comparisonID: comparison.id, memberID: member.id,
                                             recipient: (model.state.selection.contains(member.id), { toggleMember(member.id) }),
                                             showsComposer: false, removeFromView: { removeMember(member.id) })
                                .frame(width: width).id(member.id.uuidString)
                        }
                    }
                    ForEach(unsentAgents) { agent in
                        if !displayedSessions.isEmpty || agent.id != unsentAgents.first?.id { Divider() }
                        VStack(spacing: 0) {
                            ColumnHeader(agent: agent, name: agent.name + (model.demo ? " (Demo)" : ""), included: true, enabled: false,
                                         detail: model.route(agent)?.handle, toggle: {}) {
                                Button("Remove from View") { removeUnsent(agent) }.disabled(sending)
                            }
                            Spacer()
                            Text("Your message has not been sent. Use Send & compare after signing in to your selected accounts.")
                                .font(.system(size: Space.bodyText)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(Space.section)
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

    /// "Message Claude" when exactly one agent receives the next message, else "Message".
    private var composePlaceholder: String {
        let names = selectedWebSessions.map(\.name) + nativeRecipients.map(\.name)
        return names.count == 1 ? "Message \(names[0])" : "Message"
    }

    /// The one compose bar, Messages-style: at most one status line, then the field.
    private var composer: some View {
        VStack(alignment: .leading, spacing: Space.gap) {
            let signedOut = selectedWebSessions.filter { !$0.provider.usesNativeConversation && $0.snapshot.signedIn == false }
            if !signedOut.isEmpty {
                Text("Sign in required: \(signedOut.map { $0.name }.formatted(.list(type: .and)))")
                    .font(.caption).foregroundStyle(.orange).lineLimit(1).accessibilityIdentifier("Website sign-in status")
            } else if !selectedWebSessions.isEmpty && !attachments.isEmpty {
                Text("Web agents support text here. Remove the attachments or deselect them to send.")
                    .font(.caption).foregroundStyle(.orange).lineLimit(1)
            } else if let reason = sharedSendDisabledReason {
                HStack(spacing: Space.tight) {
                    Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if reason.count > Self.shortLineLength { DetailButton(detail: reason) }
                }
            } else if showingComparison, let comparison = nativeComparison {
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
                         placeholder: composePlaceholder, accessibilityName: "Shared prompt", sendLabel: "Send & compare",
                         disabled: !canSend, attachmentsEnabled: selectedWebSessions.isEmpty,
                         sendDisabledReason: sharedSendDisabledReason, send: send, focusRequest: newBlastRequest)
        }.padding(.horizontal, Space.barEdge).padding(.vertical, Space.barV)
    }

    private func selectRecipient(_ session: WebAgentSession) {
        guard !busy, !web.isBusyForSelection(session), session.provider.supportsSharedSubmissions else { return }
        hiddenWebAgents.remove(session.id)
        guard let comparison = nativeComparison, !comparison.resolvedWebAgentIDs.contains(session.id) else {
            web.toggle(session)
            return
        }
        guard !model.webBroadcastBusy else { return }
        requestedAgents.insert(session.id)
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
        // A private reply to the one selected app agent while the broadcast is still running.
        if let session = directReplySession {
            let text = model.state.draft
            sendDirect(text, to: session)
            model.setSharedDraft("")
            return
        }
        let sessions = selectedWebSessions
        let recipients = Set(nativeRecipients.map(\.id))
        if !showingComparison {
            let previousSelection = model.state.selection
            model.state.selection = recipients
            do { try model.save() }
            catch { model.state.selection = previousSelection; model.error = error.localizedDescription; return }
            model.deselectHiddenGridRecipients()
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
        let nativeOnly = !sessions.isEmpty && sessions.allSatisfy { $0.provider.desktopApp != nil }
        guard let broadcast = model.beginSharedWebBroadcast(nativeOnly: nativeOnly, comparisonID: existingID) else { return }
        showingComparison = true
        Task { @MainActor in
            defer { model.finishSharedWebBroadcast(broadcast) }
            let needsSignIn = await web.signInRequired(for: sessions)
            if !needsSignIn.isEmpty {
                signInProviders = needsSignIn
                showingConnectionIntro = true
                return
            }
            // New comparisons and already-joined native apps can prepare one
            // recipient at a time while Messages submits independently.
            let progressiveNative = nativeOnly &&
                (existingID.map { id in sessions.allSatisfy { model.comparison(id)?.resolvedWebAgentIDs.contains($0.id) == true } } ?? true)
            let comparisonID: UUID
            var readySessions: [WebAgentSession] = []
            var unsent: [WebAgentID: WebSendAttempt] = [:]
            var planned: [WebAgentID: UUID] = [:]
            if progressiveNative {
                if let existingID { comparisonID = existingID }
                else {
                    guard let id = await model.prepareWebComparison(originalDraft.trimmingCharacters(in: .whitespacesAndNewlines), recipientIDs: recipients, agents: sessions.map(\.id)) else { return }
                    comparisonID = id
                }
            } else {
                guard let preparation = await web.prepareComparisonRecipients(existingID, for: sessions, startNativeApps: true, allowSavedPrivateDraft: true, foregroundPreparation: true),
                      existingID.flatMap({ model.comparison($0)?.endedAt }) == nil else { return }
                readySessions = sessions.filter { preparation[$0.id] == true }
                let failedSessions = sessions.filter { preparation[$0.id] != true }
                // Website sign-in and joining an existing comparison retain their explicit setup flow.
                guard failedSessions.allSatisfy({ $0.provider.desktopApp != nil }),
                      existingID.map({ id in failedSessions.allSatisfy { model.comparison(id)?.resolvedWebAgentIDs.contains($0.id) == true } }) ?? true,
                      !readySessions.isEmpty || !recipients.isEmpty else { return }
                let failures = failedSessions.map { ($0, $0.error ?? $0.snapshot.reason) }
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
                for (session, reason) in failures {
                    guard let attempt = session.recordUnsentPreparation(originalDraft.trimmingCharacters(in: .whitespacesAndNewlines), comparisonID: comparisonID, reason: reason) else { return }
                    unsent[session.id] = attempt
                }
            }
            guard model.bindSharedWebBroadcast(broadcast, to: comparisonID), model.comparison(comparisonID)?.endedAt == nil else { return }
            if let i = model.index(comparisonID) {
                let previous = model.state.comparisons[i].resolvedWebAgentIDs
                model.state.comparisons[i].setWebAgents(previous + sessions.map(\.id))
                do { try model.save() } catch { model.error = error.localizedDescription; return }
            }
            do { try model.freezeSharedContext(comparisonID) } catch { model.error = error.localizedDescription; return }
            if progressiveNative {
                for session in sessions {
                    guard let attempt = session.planNativePreparation(originalDraft.trimmingCharacters(in: .whitespacesAndNewlines), comparisonID: comparisonID) else {
                        for earlier in sessions {
                            if let id = planned[earlier.id] { _ = earlier.failNativePreparation(id, reason: "The request could not be prepared. Nothing was sent.") }
                        }
                        return
                    }
                    planned[session.id] = attempt.id
                }
            }
            let unsentAttempts = unsent
            let plannedAttempts = planned
            let preparedSessions = readySessions
            let allRecipients = model.comparison(comparisonID).map { comparison in
                Set(comparison.resolvedWebAgentIDs) == Set(sessions.map(\.id)) && Set(comparison.members.map(\.id)) == recipients
            } ?? false
            let followUpID = UUID()
            let telemetryStarted = Date()
            let barrier = BroadcastSubmissionBarrier {
                guard !Task.isCancelled, !sessions.isEmpty,
                      web.comparisonID == comparisonID, model.comparison(comparisonID)?.endedAt == nil else { return }
                model.finishSharedWebInputs(broadcast)
            }
            let result = await AgentBroadcast.send(draft: originalDraft, currentDraft: { model.state.draft }, shouldClearDraft: {
                model.sharedDraftRevision.value == submittedDraftRevision && web.comparisonID == comparisonID
            }, clearDraft: {
                model.setSharedDraft("")
            }, web: { text, confirmed in
                let didConfirm: @MainActor @Sendable () -> Void = {
                    confirmed()
                    model.confirmSharedWebSubmission(broadcast)
                }
                let submitted: [WebAgentID: WebSendAttempt]
                if progressiveNative {
                    submitted = await web.prepareAndSendPlanned(text, to: sessions, comparisonID: comparisonID, plannedAttempts: plannedAttempts,
                        onInputsFinished: { barrier.finishNativeInputs() }, onConfirmedSubmission: didConfirm)
                } else {
                    submitted = await WebAgents.send(text, to: preparedSessions, comparisonID: comparisonID,
                        onInputsFinished: { barrier.finishNativeInputs() }, onConfirmedSubmission: didConfirm)
                }
                return unsentAttempts.merging(submitted) { _, latest in latest }
            }, messages: { text, confirmed in
                defer { if !Task.isCancelled { barrier.finishMessages() } }
                guard !recipients.isEmpty else { return nil }
                let states: [Submission]
                if existingID != nil {
                    guard let i = model.index(comparisonID) else { return nil }
                    model.state.comparisons[i].allDraft = text
                    await model.followUp(comparisonID, recipients: Array(recipients), newAttemptID: followUpID, telemetryManagedExternally: true)
                    states = model.comparison(comparisonID)?.followUps.first(where: { $0.id == followUpID }).map { Array($0.states.values) } ?? []
                } else {
                    await model.submit(comparisonID, retry: false, telemetryManagedExternally: true)
                    states = model.comparison(comparisonID)?.members.filter { recipients.contains($0.id) }.map(\.submission) ?? []
                }
                return AgentBroadcast.messagesResult(states: states, comparisonID: comparisonID, onConfirmed: {
                    confirmed()
                    model.confirmSharedWebSubmission(broadcast)
                })
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
        }
    }

    private func sendDirect(_ text: String, to session: WebAgentSession) {
        guard nativeComparison?.endedAt == nil else { return }
        let independent = canReplyWhileBroadcasting(to: session)
        guard (!model.webBroadcastBusy || independent), (!busy || independent), session.isEnabled, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
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
    let busy: Bool
    var endedMessages: [WebPageMessage]? = nil
    var removalDisabled = false
    /// This agent receives the workspace's next message.
    let isRecipient: Bool
    let recipientEnabled: Bool
    let toggleRecipient: () -> Void
    /// Opens the desktop options sheet the workspace owns.
    let showOptions: () -> Void
    let sendNative: (String) -> Void
    let removeFromView: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader(agent: AgentArtwork.agent(for: session), name: session.name, included: isRecipient, enabled: recipientEnabled,
                         busy: session.loading, detail: session.locationLabel, toggle: toggleRecipient) {
                if session.provider != .grokbot {
                    Button("Reload") { session.reload() }.disabled(busy || endedMessages != nil)
                }
                if session.provider.desktopApp != nil { Button("Options…", action: showOptions) }
                if session.provider == .grokbot { SettingsLink { Text("Grok Bot Settings…") } }
                Button("Remove from View", action: removeFromView).disabled(removalDisabled)
            }
            if session.needsConversationLink {
                NoticeRow(text: session.canLinkCurrentConversation ? "Continue in this conversation" : "Open the original chat to continue",
                          detail: session.canLinkCurrentConversation ? nil : "Open the original chat to continue this comparison.") {
                    Button("Use this conversation") { Task { await session.linkCurrentConversation() } }
                        .disabled(busy || !session.canLinkCurrentConversation)
                }
            }
            if let latest = session.latestComparisonAttempt, !session.isAutomaticallyWaitingForNativeReply,
               !(session.provider.desktopApp != nil && latest.status == .waiting && latest.messageID != nil),
               latest.status.showsAttemptBanner(for: session.provider) {
                let line = "\(latest.status.label(for: session.provider)): \(latest.text)"
                let detail = latest.detail.flatMap { $0 != session.desktopRecoveryMessage ? $0 : nil }
                NoticeRow(text: line, systemImage: "info.circle", detail: [line, detail].compactMap { $0 }.joined(separator: "\n"),
                          attention: latest.status == .notSent || latest.status == .uncertain) {
                    if latest.status == .notSent, latest.messageID == nil, session.provider.desktopApp != nil {
                        Button("Retry") { sendNative(latest.text) }
                            .disabled(busy || !session.canSubmitNativePrompt)
                    }
                }
                .accessibilityElement(children: .contain)
            }
            if let error = session.error, error != session.latestComparisonAttempt?.detail,
               endedMessages != nil || session.desktopRecoveryMessage != error {
                NoticeRow(error, systemImage: "exclamationmark.circle", detail: error, attention: true)
            }
            if let draft = session.draftRecoveryText {
                NoticeRow(text: "Your saved draft is retained", detail: "Your saved draft is retained. Copy it into this chat to continue.") {
                    Button("Copy saved draft") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(draft, forType: .string)
                    }
                }
            }
            if let endedMessages {
                NativeTranscriptView(agent: AgentArtwork.agent(for: session), name: session.name, messages: endedMessages,
                                     statuses: [:], dates: [:], typing: false, emptyText: "No messages", bottomID: "ended-\(session.id.id)")
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

    /// The status caption under one of your messages: Sent, Sending…, or Submission unconfirmed.
    private func nativeStatus(_ message: WebPageMessage) -> (text: String, color: Color)? {
        guard message.role == "user", let attempt = session.state.attempts.first(where: {
            ($0.messageID ?? $0.id.uuidString) == message.id
        }) else { return nil }
        if attempt.status == .observed { return nil }
        if attempt.messageID != nil { return ("Sent", .secondary) }
        if attempt.status == .uncertain { return ("Submission unconfirmed", .orange) }
        return [.preparing, .attempting].contains(attempt.status) ? ("Sending…", .secondary) : nil
    }

    private var nativeMessages: [WebPageMessage] {
        var messages = session.snapshot.messages
        if let attempt = session.pendingNativeAttempt {
            messages.append(WebPageMessage(id: attempt.id.uuidString, role: "user", text: attempt.text))
        }
        return messages
    }

    private var nativeStatuses: [String: (text: String, color: Color)] {
        var statuses: [String: (text: String, color: Color)] = [:]
        for message in nativeMessages where message.role == "user" {
            if let status = nativeStatus(message) { statuses[message.id] = status }
        }
        return statuses
    }

    /// When each of your messages was sent, from its attempt; replies carry no time.
    private var nativeDates: [String: Date] {
        var dates: [String: Date] = [:]
        for message in nativeMessages where message.role == "user" {
            if let attempt = session.state.attempts.first(where: { ($0.messageID ?? $0.id.uuidString) == message.id }) {
                dates[message.id] = attempt.created
            }
        }
        return dates
    }

    private func nativeConversation(_ provider: PersonalAgentProvider?) -> some View {
        VStack(spacing: 0) {
            let connected = session.provider.desktopApp != nil ? session.desktopReady : session.provider == .grokbot ? session.grokBotIsConfigured : [.subscription, .apiKey, .other].contains(session.accountStatus)
            if !session.provider.isAvailableInBuild {
                NoticeRow("\(session.name) is unavailable in this build",
                          detail: "\(session.name) is unavailable in this build. Your saved conversation is preserved.")
            } else if !session.isEnabled {
                NoticeRow("Enable \(session.name) in Settings to send",
                          detail: "Enable \(session.name) in Settings to send. Your saved conversation is still available here.")
            } else if let app = session.provider.desktopApp, !connected,
                      let recovery = session.desktopRecoveryMessage {
                NoticeRow(text: recovery, detail: recovery, attention: true) {
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
                    NoticeRow("Simulated webhook and callback · no Bot contacted")
                } else if !connected {
                    NoticeRow(text: "Connect your Grok Bot webhook in Settings", attention: true) {
                        SettingsLink { Text("Grok Bot Settings…") }
                    }
                }
            } else if !connected, let provider {
                NoticeRow(text: session.fixture ? "Simulated local account · no provider requests" : session.accountStatus.label,
                          systemImage: "person.crop.circle", attention: !session.fixture) {
                    if account.installed.contains(where: { $0.provider == provider }) {
                        Button(provider == .codex ? "Sign in with ChatGPT" : "Sign in with Claude") { account.signIn(provider) }
                            .disabled(session.fixture || busy)
                    } else {
                        Link("Install \(provider.name)", destination: URL(string: provider == .codex
                             ? "https://developers.openai.com/codex/cli" : "https://code.claude.com/docs/en/setup")!)
                    }
                }
                if let error = account.accountError { NoticeRow(error, systemImage: "exclamationmark.circle", detail: error, attention: true) }
            }
            NativeTranscriptView(agent: AgentArtwork.agent(for: session), name: session.name, messages: nativeMessages,
                                 statuses: nativeStatuses, dates: nativeDates, typing: session.isSending,
                                 emptyText: session.provider.desktopApp != nil ? "Send a message to start a conversation." : connected ? "Ready to chat. Send a message below, or use the shared message box to ask your selected agents." : "Sign in to \(session.name) to start chatting. Your request stays in the message box until you send it.",
                                 bottomID: "native-\(session.id.id)")
            if session.isSending {
                // The typing bubble shows the activity; this line carries the one way to stop it.
                NoticeRow(text: "Replying…", progress: true) {
                    if provider != nil || session.provider.desktopApp != nil {
                        Button("Stop") { session.cancelNativeRequest() }
                    }
                }
            }
            if let attempt = session.incompleteDesktopAttempt, attempt.comparisonID != session.state.comparisonID {
                let origin = "“" + String(attempt.text.prefix(80)) + "”"
                NoticeRow(text: "An incomplete request is blocking this app", systemImage: "exclamationmark.circle",
                          detail: "An incomplete request in \(origin) is blocking this app. Review its reply in the native app before continuing.",
                          attention: true) {
                    Button("Acknowledge") { session.acknowledgeIncompleteRequest(attemptID: attempt.id) }
                        .disabled(busy || session.isSending)
                }
            }
            if session.isAutomaticallyWaitingForNativeReply {
                NoticeRow(text: "Waiting for \(session.name)…", progress: true) {
                    Button("Stop Waiting") { session.acknowledgeIncompleteRequest() }.disabled(busy)
                }
            } else if session.latestComparisonAttempt?.status == .uncertain {
                NoticeRow(text: "The last request was incomplete", systemImage: "exclamationmark.circle",
                          detail: "The last request was incomplete. Continuing may consume provider usage again.", attention: true) {
                    Button("Acknowledge") { session.acknowledgeIncompleteRequest() }.disabled(busy)
                }
            }
            if session.provider == .grokbot, session.latestComparisonAttempt?.status == .waiting {
                NoticeRow(text: "Grok Bot may continue working if you stop waiting") {
                    Button("Stop Waiting") { session.acknowledgeIncompleteRequest() }.disabled(busy)
                }
            }
        }
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
