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
    @State private var showingConnectionIntro = false
    @State private var signInProviders: [WebProvider] = []
    private var busy: Bool { model.busy || model.webBroadcastBusy || web.sessions.contains { $0.isSending } }
    private var nativeRecipients: [Agent] { model.state.agents.filter { model.state.selection.contains($0.id) } }
    private var attachmentComparisonID: UUID? { showingComparison ? nativeComparison?.id : nil }
    private var attachments: [MessageAttachment] { model.attachmentDraft(comparisonID: attachmentComparisonID) }
    private var canSend: Bool {
        let text = model.state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !busy && !showingConnectionIntro && (!web.selected.isEmpty || !nativeRecipients.isEmpty)
            && (web.selected.isEmpty || (!text.isEmpty && attachments.isEmpty))
            && web.selected.allSatisfy { $0.snapshot.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.hasUnresolvedSend(text) }
            && (nativeRecipients.isEmpty || (model.databaseAvailable && nativeRecipients.allSatisfy { model.route($0) != nil }))
    }

    var body: some View {
        VStack(spacing: 0) {
            if showingComparison {
                comparisonPanes
            } else {
                agentPicker
            }
            Divider()
            composer
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay { if showingConnectionIntro { connectionIntro } }
        .task { web.connectSelected() }
        .onChange(of: newBlastRequest) { _, _ in showingConnectionIntro = false }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    showingConnectionIntro = false
                    showingComparison = false
                    web.setComparison(nil)
                } label: {
                    Label("New Blast", systemImage: "square.and.pencil")
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                }
                .accessibilityLabel("New Blast").disabled(busy)
            }
        }
    }

    private var connectionIntro: some View {
        ZStack {
            Color.black.opacity(0.35)
            VStack(spacing: 18) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 34)).foregroundStyle(Color.accentColor)
                Text("Connect your accounts").font(.title2.weight(.semibold))
                Text("Sign in to \(signInProviders.map(\.name).formatted(.list(type: .and))) in the chat panes. Then press Send & compare again.")
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

    private var nativeComparison: Comparison? { web.comparisonID.flatMap { model.comparison($0) } }

    private var comparisonChatCount: Int { web.displayed.count + (nativeComparison?.members.count ?? 0) }

    private var agentPicker: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 20), count: 3), spacing: 28) {
                    ForEach(web.availableSessions, id: \.provider) { session in
                        PinnedAgentTile(agent: AgentArtwork.agent(for: session), selected: session.state.selected, size: tileSize(geometry)) {
                            web.toggle(session)
                        }.disabled(busy).help("\(session.provider.name) · \(session.locationLabel)")
                            .contextMenu {
                                Button("Open chat") {
                                    session.connect(); showingComparison = true
                                }.disabled(busy || !session.state.selected)
                            }
                    }
                    ForEach(model.state.agents) { agent in
                        PinnedAgentTile(agent: agent, selected: model.state.selection.contains(agent.id), size: tileSize(geometry)) {
                            toggle(agent.id)
                        }.disabled(busy || model.route(agent) == nil)
                            .help(model.route(agent)?.handle ?? "No matching conversation")
                    }
                }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 20)
            }
        }
    }

    private func tileSize(_ geometry: GeometryProxy) -> CGFloat { min(100, max(48, (geometry.size.width - 80) / 3)) }

    private var comparisonPanes: some View {
        chatColumns.background(ChatWindowFrame(chatCount: comparisonChatCount))
    }

    private var chatColumns: some View {
        GeometryReader { geometry in
            let columns = comparisonChatCount
            let width = max(320, (geometry.size.width - CGFloat(max(0, columns - 1))) / CGFloat(max(1, columns)))
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(web.displayed, id: \.provider) { session in
                        if session.provider != web.displayed.first?.provider { Divider() }
                        WebAgentPane(session: session, account: model.personalAgent, busy: busy, sendNative: { sendDirect($0, to: session) })
                            .frame(width: width).id(session.provider.rawValue)
                    }
                    if let comparison = nativeComparison {
                        ForEach(comparison.members) { member in
                            if !web.displayed.isEmpty || member.id != comparison.members.first?.id { Divider() }
                            ConversationView(model: model, comparisonID: comparison.id, memberID: member.id)
                                .frame(width: width).id(member.id.uuidString)
                        }
                    }
                }.frame(height: geometry.size.height)
            }.scrollIndicators(.visible)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            let signedOut = web.selected.filter { !$0.provider.usesNativeConversation && $0.snapshot.signedIn == false }
            if !signedOut.isEmpty {
                Text("Sign in required: \(signedOut.map { $0.provider.name }.formatted(.list(type: .and)))")
                    .font(.caption).foregroundStyle(.orange).accessibilityIdentifier("Website sign-in status")
            }
            if !web.selected.isEmpty && !attachments.isEmpty {
                Text("Web agents support text here. Remove the attachments or deselect them to send.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if showingComparison { ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    Text("Send to").font(.caption).foregroundStyle(.secondary)
                    ForEach(web.sessions.filter { session in session.isEnabled || web.displayed.contains(where: { $0.provider == session.provider }) }, id: \.provider) { session in
                        recipient(session.provider.name, selected: session.isEnabled && session.state.selected) { selectRecipient(session) }
                            .disabled(!session.isEnabled)
                    }
                    ForEach(model.state.agents) { agent in
                        recipient(agent.name, selected: model.state.selection.contains(agent.id)) {
                            if let comparison = nativeComparison, !comparison.members.contains(where: { $0.id == agent.id }) {
                                model.webBroadcastBusy = true
                                Task { @MainActor in
                                    defer { model.webBroadcastBusy = false }
                                    await model.addAgent(agent, to: comparison.id)
                                }
                            } else { toggle(agent.id) }
                        }
                            .disabled(model.route(agent) == nil)
                            .help("Messages · \(agent.name)")
                    }
                }
            }.scrollIndicators(.hidden) }
            if showingComparison, let comparison = nativeComparison {
                FollowUpStatus(model: model, comparison: comparison, universal: true).disabled(busy)
            }
            MessageInput(text: Binding(get: { model.state.draft }, set: { model.state.draft = $0; model.persist() }),
                         attachments: attachments, addAttachments: { await model.addAttachments($0, comparisonID: attachmentComparisonID) },
                         removeAttachment: { id in model.setAttachmentDraft(attachments.filter { $0.id != id }, comparisonID: attachmentComparisonID) },
                         placeholder: "Message", accessibilityName: "Shared prompt", sendLabel: "Send & compare",
                         disabled: !canSend, attachmentsEnabled: web.selected.isEmpty, send: send, focusRequest: newBlastRequest)
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
        guard !busy else { return }
        guard let comparison = nativeComparison, !(comparison.webProviders ?? []).contains(session.provider) else {
            web.toggle(session)
            return
        }
        model.webBroadcastBusy = true
        session.updateState { $0.selected = true }
        session.connect()
        Task { @MainActor in
            defer { model.webBroadcastBusy = false }
            _ = await join(session, comparisonID: comparison.id)
        }
    }

    private func join(_ session: WebAgentSession, comparisonID: UUID) async -> Bool {
        do {
            try model.freezeSharedContext(comparisonID)
            guard let saved = model.comparison(comparisonID), let i = model.index(comparisonID) else { return false }
            guard saved.joiningContext().allSatisfy({ $0.attachments.isEmpty }) else {
                model.error = "This conversation contains attachments. Add a Messages agent to share the full context."
                session.updateState { $0.selected = false }
                return false
            }
            guard await session.openComparison(comparisonID) else { return false }
            // Save membership before sending so an interrupted join is never automatically repeated.
            model.state.comparisons[i].webProviders = (saved.webProviders ?? []) + [session.provider]
            try model.save()
            let attempt = await session.send(saved.joiningPrompt(), comparisonID: comparisonID)
            if attempt == nil || attempt?.status == .notSent {
                model.state.comparisons[i].webProviders?.removeAll { $0 == session.provider }
                try model.save()
            }
            return attempt?.status == .observed
        } catch { model.error = error.localizedDescription; return false }
    }

    private func toggle(_ id: UUID) {
        if model.state.selection.contains(id) { model.state.selection.remove(id) }
        else { model.state.selection.insert(id) }
        model.persist()
    }

    private func send() {
        guard canSend else { return }
        if !showingComparison && web.selected.isEmpty {
            Task { await model.start() }
            return
        }
        let originalDraft = model.state.draft
        let sentAttachments = attachments
        let broadcastCreated = Date()
        let recipients = Set(nativeRecipients.map(\.id))
        let model = model
        let sessions = web.selected
        let existingID = showingComparison ? nativeComparison?.id : nil
        model.webBroadcastBusy = true
        showingComparison = true
        Task { @MainActor in
            defer { model.webBroadcastBusy = false }
            let needsSignIn = await web.signInRequired(for: sessions)
            if !needsSignIn.isEmpty {
                signInProviders = needsSignIn
                showingConnectionIntro = true
                return
            }
            guard await web.prepareComparison(existingID, for: sessions) else { return }
            let comparisonID: UUID
            if let existingID { comparisonID = existingID }
            else {
                guard let id = await model.prepareWebComparison(originalDraft.trimmingCharacters(in: .whitespacesAndNewlines), recipientIDs: recipients, providers: sessions.map(\.provider)) else { return }
                comparisonID = id
            }
            if existingID != nil {
                for session in sessions where model.comparison(comparisonID)?.webProviders?.contains(session.provider) != true {
                    guard await join(session, comparisonID: comparisonID) else { return }
                }
            }
            if let i = model.index(comparisonID) {
                let previous = model.state.comparisons[i].webProviders ?? []
                model.state.comparisons[i].webProviders = WebProvider.allCases.filter { previous.contains($0) || sessions.map(\.provider).contains($0) }
                do { try model.save() } catch { model.error = error.localizedDescription; return }
            }
            do { try model.freezeSharedContext(comparisonID) } catch { model.error = error.localizedDescription; return }
            let allRecipients = model.comparison(comparisonID).map { comparison in
                Set(comparison.webProviders ?? []) == Set(sessions.map(\.provider)) && Set(comparison.members.map(\.id)) == recipients
            } ?? false
            let followUpID = UUID()
            let result = await AgentBroadcast.send(draft: originalDraft, currentDraft: { model.state.draft }, clearDraft: {
                model.state.draft = ""; model.persist()
            }, web: { text in
                await WebAgents.send(text, to: sessions, comparisonID: comparisonID)
            }, messages: { text in
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
        guard !busy, session.isEnabled, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let existingID = nativeComparison?.id
        model.webBroadcastBusy = true
        Task { @MainActor in
            defer { model.webBroadcastBusy = false }
            let id: UUID
            if let existingID { id = existingID }
            else {
                guard let created = await model.prepareWebComparison(text, recipientIDs: [], providers: [session.provider]) else { return }
                id = created
            }
            do { try model.freezeSharedContext(id) } catch { model.error = error.localizedDescription; return }
            guard let i = model.index(id) else { return }
            if model.state.comparisons[i].webProviders?.contains(session.provider) != true {
                model.state.comparisons[i].webProviders = (model.state.comparisons[i].webProviders ?? []) + [session.provider]
            }
            do { try model.save() } catch { model.error = error.localizedDescription; return }
            showingComparison = true
            _ = await session.send(text, comparisonID: id)
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
            Text("ChatGPT and Claude use their websites by default. Enable a CLI below to add it as a separate agent.")
                .font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
            ForEach(WebProvider.optionalProviders) { webProvider in
                let provider = webProvider.personalAgentProvider!
                Toggle("Enable \(webProvider.name)", isOn: Binding(
                    get: { web.sessions.first(where: { $0.provider == webProvider })?.isEnabled == true },
                    set: { web.setEnabled($0, for: webProvider) }
                )).toggleStyle(.switch).disabled(isBusy).padding(.top, 8)
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
                           status: agent.detectingLocalAgents ? "Checking installation…" : installed ? "Installed on this Mac" : "Not installed") {
                    if installed {
                        Button("Set up \(runtime.name)") { setupRuntime = runtime }.disabled(isBusy)
                    } else {
                        Link("Install \(runtime.name)", destination: runtime.documentation)
                    }
                }
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

private struct LocalAgentSetupView: View {
    @ObservedObject var agent: PersonalAgentController
    let runtime: LocalAgentRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var showingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Set up \(runtime.name)").font(.title2.bold())
            Text("Continue in Terminal to choose your provider and finish \(runtime.name)’s setup. Return here when you’re done.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(runtime == .openclaw
                 ? "OpenClaw is detected. Conversations in msgblast are not connected yet."
                 : "Hermes is detected. After setup, select it in a comparison report to use it.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            if agent.demo {
                Label("Simulated installation · Terminal setup is disabled", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Installation details", isExpanded: $showingDetails) {
                VStack(alignment: .leading, spacing: 8) {
                    if let installation = agent.detectedLocalAgents.first(where: { $0.runtime == runtime }), !agent.demo {
                        Text(installation.executableURL.path).font(.caption).textSelection(.enabled)
                    }
                    Text(runtime.setup).font(.caption.monospaced()).textSelection(.enabled)
                    Link("\(runtime.name) setup guide", destination: runtime.documentation)
                }.padding(.top, 8)
            }.font(.callout)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Continue in Terminal") {
                    agent.setUp(runtime)
                    dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(agent.demo)
            }
        }.padding(24).frame(width: 420)
    }
}

private struct WebAgentPane: View {
    @ObservedObject var session: WebAgentSession
    @ObservedObject var account: PersonalAgentController
    let busy: Bool
    let sendNative: (String) -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                AgentAvatar(agent: AgentArtwork.agent(for: session), name: session.provider.name, size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.provider.name).font(.headline)
                    Text(session.locationLabel).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if session.loading { ProgressView().controlSize(.small) }
                if session.provider == .grokbot {
                    SettingsLink { Image(systemName: "gearshape") }
                        .help("Grok Bot settings").accessibilityLabel("Grok Bot settings")
                } else {
                    Button { session.reload() } label: { Image(systemName: "arrow.clockwise") }.help("Reload \(session.provider.name)").accessibilityLabel("Reload \(session.provider.name)").disabled(busy)
                }
            }.padding(14).background(.bar)
            if session.needsConversationLink {
                HStack {
                    Text(session.canLinkCurrentConversation ? "Continue in this conversation." : "Open the original chat to continue this comparison.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Use this conversation") { Task { await session.linkCurrentConversation() } }
                        .disabled(busy || !session.canLinkCurrentConversation)
                }.padding(10)
            }
            if let latest = session.latestComparisonAttempt, latest.status.showsAttemptBanner(for: session.provider) {
                VStack(alignment: .leading, spacing: 3) {
                    Label(latest.status.label(for: session.provider), systemImage: "info.circle")
                        .font(.caption.weight(.semibold))
                    Text(latest.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let detail = latest.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .contain)
            }
            if let error = session.error { Text(error).font(.caption).foregroundStyle(.orange).padding(10).frame(maxWidth: .infinity, alignment: .leading) }
            if session.provider.usesNativeConversation {
                nativeConversation(session.provider.personalAgentProvider)
            } else if session.connected {
                if !session.snapshot.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !session.isSending {
                    Text("\(session.provider.name) has a draft. Send or clear it in the page before using the shared composer.").font(.caption).foregroundStyle(.orange).padding(8)
                }
                if session.provider == .dots {
                    Text("Blasts continue your ongoing dot conversation.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
                }
                EmbeddedServicePage(webView: session.webView)
            } else {
                VStack(spacing: 18) {
                    AgentAvatar(agent: AgentArtwork.agent(for: session), name: session.provider.name, size: 80)
                    Text("\(session.provider.name), inside MsgBlast").font(.title2.weight(.semibold))
                    Text("Sign in here once, then send from the shared composer. Your \(session.provider.name) conversation and replies stay in this window.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                    Button("Connect \(session.provider.name)") { session.connect() }.buttonStyle(.borderedProminent).controlSize(.large)
                    Text("Safari’s login is separate. MsgBlast remembers its own web session.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(28)
            }
        }
        .task { if session.provider.personalAgentProvider != nil { await account.discover() } }
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

    private func nativeConversation(_ provider: PersonalAgentProvider?) -> some View {
        VStack(spacing: 12) {
            let connected = session.provider == .grokbot ? session.grokBotIsConfigured : [.subscription, .apiKey, .other].contains(session.accountStatus)
            if !session.isEnabled {
                Text("Enable \(session.provider.name) in Settings to send. Your saved conversation is still available here.")
                    .font(.caption).foregroundStyle(.secondary)
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
                        if session.snapshot.messages.isEmpty {
                            Text(connected ? "Ready to chat. Send a message below, or use the shared message box to ask your selected agents." : "Sign in to \(session.provider.name) to start chatting. Your request stays in the message box until you send it.")
                                .foregroundStyle(.secondary).padding(.vertical, 20)
                        }
                        ForEach(session.snapshot.messages) { message in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(message.role == "user" ? "You" : session.provider.name).font(.caption.bold()).foregroundStyle(.secondary)
                                Text((try? AttributedString(markdown: message.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(message.text))
                                    .textSelection(.enabled)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(message.role == "user" ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                                .id(message.id)
                        }
                        if session.isSending { ProgressView(session.provider == .grokbot ? "Sending to Grok Bot…" : "\(session.provider.name) is replying…").id("replying") }
                    }
                }.onChange(of: session.snapshot.messages.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            if session.isSending, provider != nil { Button("Cancel \(session.provider.name) reply") { session.cancelNativeRequest() } }
            if session.latestComparisonAttempt?.status == .uncertain {
                Text("The last request was incomplete. Continuing may consume provider usage again.").font(.caption).foregroundStyle(.orange)
                Button("Acknowledge incomplete request") { session.acknowledgeIncompleteRequest() }.disabled(busy)
            }
            if session.provider == .grokbot, session.latestComparisonAttempt?.status == .waiting {
                Text("Grok Bot may continue working if you stop waiting.").font(.caption).foregroundStyle(.secondary)
                Button("Stop waiting for this reply") { session.acknowledgeIncompleteRequest() }.disabled(busy)
            }
            MessageInput(text: Binding(get: { session.state.draft }, set: { text in session.updateState { $0.draft = text } }),
                attachments: [], addAttachments: { _ in }, removeAttachment: { _ in }, placeholder: "Message \(session.provider.name)",
                accessibilityName: "Message \(session.provider.name)", sendLabel: "Send to \(session.provider.name)",
                disabled: busy || !session.snapshot.ready, attachmentsEnabled: false) {
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
    func makeNSView(context: Context) -> ChatWindowSizingView { ChatWindowSizingView() }
    func updateNSView(_ view: ChatWindowSizingView, context: Context) {
        guard view.chatCount != chatCount else { return }
        view.chatCount = chatCount
        view.needsLayout = true
    }
}

private final class ChatWindowSizingView: NSView {
    var chatCount = -1
    private var appliedCount: Int?
    override func layout() {
        super.layout()
        guard let window, bounds.width > 0, appliedCount != chatCount else { return }
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
