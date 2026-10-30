import SwiftUI
import AppKit
import msgblastCore
import UniformTypeIdentifiers

struct AgentAvatar: View {
    let agent: Agent?
    let name: String
    var size: CGFloat = 38
    private let colors: [Color] = [.gray, .indigo, .orange, .pink, .purple, .blue]
    var body: some View {
        Group {
            if let data = AgentArtwork.avatar(for: agent, name: name), let image = NSImage(data: data) {
                if data.starts(with: [0x69, 0x63, 0x6e, 0x73]) {
                    // Native app icons include their own shape and transparent margins.
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: size, height: size).clipShape(Circle())
                }
            } else {
                ZStack {
                    Circle().fill(colors[abs(agent?.colorIndex ?? 0) % colors.count].gradient)
                    Text(String(name.prefix(1))).font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(.white)
                }
            }
        }.frame(width: size, height: size)
    }
}

/// `ComparisonWorkspace`'s header input (separate conversation windows). The agents
/// workspace passes `ConversationView.recipient` instead; phase 2b retires this.
struct ConversationHeaderControls {
    var enabled = true
    let selected: Bool
    let included: Bool
    let selectConversation: () -> Void
    let toggleRecipient: () -> Void
}

struct MessageText: NSViewRepresentable {
    let text: String
    let outgoing: Bool
    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.font = .systemFont(ofSize: Space.bodyText)
        return view
    }
    func updateNSView(_ view: NSTextView, context: Context) {
        if view.string != text { view.string = text }
        view.textColor = outgoing ? .white : .labelColor
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        // Measure independently: NSTextView's width-tracking container follows its old frame during SwiftUI sizing.
        return MessageTextMeasurement.size(text, width: proposal.width ?? 560)
    }
}

struct MessageInput: View {
    @Binding var text: String
    var attachments: [MessageAttachment]
    var addAttachments: (AttachmentImport) async -> Void
    var removeAttachment: (String) -> Void
    let placeholder: String
    let accessibilityName: String
    let sendLabel: String
    var disabled: Bool
    var attachmentsEnabled = true
    var sendDisabledReason: String? = nil
    var send: () -> Void
    var focusRequest: UUID? = nil
    @State private var dropTarget = false
    @State private var importing = false
    @State private var attachmentError: String?
    private var unavailable: Bool { disabled || importing }
    private var hasContent: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }
    /// Messages' field: a capsule in the text background with a hairline edge.
    private var fieldShape: RoundedRectangle { RoundedRectangle(cornerRadius: Space.fieldHeight / 2, style: .continuous) }
    var body: some View {
        VStack(spacing: Space.tight) {
            if !attachments.isEmpty { AttachmentDraftStrip(attachments: attachments, disabled: unavailable, remove: removeAttachment) }
            HStack(alignment: .bottom, spacing: Space.gap) {
                if attachmentsEnabled { AttachmentComposer(disabled: unavailable, add: addAttachments, importing: $importing) }
                HStack(alignment: .bottom, spacing: 0) {
                    MessageEditor(text: $text, accessibilityName: accessibilityName, attachmentsEnabled: attachmentsEnabled && !unavailable, importAttachment: { selection in
                        importing = true
                        Task { await addAttachments(selection); importing = false }
                    }, send: { if !unavailable && hasContent { send() } }, focusRequest: focusRequest)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty { Text(placeholder).font(.system(size: 14)).foregroundStyle(Color(nsColor: .placeholderTextColor)).padding(.top, 2).allowsHitTesting(false).accessibilityHidden(true) }
                        }
                    if hasContent {
                        Button(action: send) {
                            Image(systemName: "arrow.up.circle.fill").font(.system(size: Space.fieldHeight - Space.gap))
                                .foregroundStyle(unavailable ? Color.secondary : Color.accentColor)
                        }
                            .buttonStyle(.plain)
                            .accessibilityLabel(sendLabel)
                            .accessibilityHint(sendDisabledReason ?? "")
                            .help(sendDisabledReason ?? "\(sendLabel) (Return or ⌘Return; ⇧Return for a new line)")
                            .disabled(unavailable)
                    }
                }
                .padding(.leading, Space.fieldTextInset).padding(.trailing, Space.tight).padding(.vertical, Space.tight)
                .frame(minHeight: Space.fieldHeight)
                .background(fieldShape.fill(Color(nsColor: .textBackgroundColor)))
                .overlay(fieldShape.stroke(Color(nsColor: .separatorColor), lineWidth: 1))
            }
        }
        .overlay { if dropTarget { fieldShape.stroke(.blue, lineWidth: 2) } }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTarget) { providers in
            guard attachmentsEnabled, !unavailable else { return false }
            importProviders(providers); return true
        }
        .alert("Attachment", isPresented: Binding(get: { attachmentError != nil }, set: { if !$0 { attachmentError = nil } })) { Button("OK") { attachmentError = nil } } message: { Text(attachmentError ?? "") }
    }
    private func importProviders(_ providers: [NSItemProvider]) {
        importing = true
        Task { @MainActor in
            defer { importing = false }
            for provider in providers {
                let isFile = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                let type = isFile ? UTType.fileURL.identifier : provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true })
                guard let type else { continue }
                do {
                    let data: Data = try await withCheckedThrowingContinuation { continuation in
                        provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                            if let data { continuation.resume(returning: data) }
                            else { continuation.resume(throwing: error ?? AppFailure.blocked("The attachment could not be loaded.")) }
                        }
                    }
                    if isFile {
                        guard let url = URL(dataRepresentation: data, relativeTo: nil) else { throw AppFailure.blocked("The file location is unavailable.") }
                        await addAttachments(.files([url]))
                    } else {
                        let ext = UTType(type)?.preferredFilenameExtension ?? "png"
                        await addAttachments(.image(data, filename: "Image-\(UUID().uuidString).\(ext)"))
                    }
                } catch { attachmentError = error.localizedDescription }
            }
        }
    }
}

struct MainView: View {
    @Environment(\.controlActiveState) private var controlActiveState
    @ObservedObject var model: AppModel
    @ObservedObject private var web: WebAgents
    private let updater: AppUpdater
    private enum DetailSelection { case agents, discover }
    @StateObject private var captureLayout = ChatCaptureLayout()
    @State private var selection = DetailSelection.agents
    @State private var showingComparison: Bool
    private var sidebarSelectionColor: Color { Color.primary.opacity(controlActiveState == .inactive ? 0.06 : 0.10) }
    private var sidebarIconColor: Color { controlActiveState == .inactive ? .secondary : .accentColor }
    private var showingAgents: Bool { selection == .agents && !showingComparison }
    private var selectedComparisonID: UUID? { selection == .agents && showingComparison ? web.comparisonID : nil }

    init(model: AppModel, updater: AppUpdater) {
        self.model = model
        self.web = model.webAgents
        self.updater = updater
        _showingComparison = State(initialValue: model.webAgents.comparisonID.flatMap { model.comparison($0) } != nil)
    }

    private func showAgentGrid() {
        if !showingComparison && web.comparisonID == nil {
            selection = .agents
        } else if model.requestNewBlast() {
            selection = .agents
            showingComparison = false
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $captureLayout.sidebarVisibility) {
            List {
                Section {
                    Button { showAgentGrid() } label: {
                        sidebarLabel("Agents", systemImage: "person.2.fill", selected: showingAgents)
                    }.buttonStyle(.plain).accessibilityLabel("Agents")
                        .accessibilityValue(showingAgents ? "Selected" : "Not selected")
                    Button { selection = .discover } label: {
                        sidebarLabel("Discover", systemImage: "safari", selected: selection == .discover)
                    }.buttonStyle(.plain).accessibilityLabel("Discover")
                        .accessibilityValue(selection == .discover ? "Selected" : "Not selected")
                }
                Section("Comparisons") {
                ForEach(model.state.comparisons) { comparison in
                    Button { model.coordinator?.open(comparison.id) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "bubble.left.and.bubble.right.fill").font(.title3).foregroundStyle(.secondary).frame(width: 32)
                            VStack(alignment: .leading, spacing: 4) {
                                Text((comparison.members.map(\.name) + comparison.resolvedWebAgentIDs.map { model.webAgents.name(for: $0) }).joined(separator: ", ")).fontWeight(.semibold).lineLimit(1)
                                Text(comparison.prompt).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }.padding(.horizontal, 10).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(selectedComparisonID == comparison.id ? sidebarSelectionColor : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .foregroundStyle(Color.primary)
                        .listRowBackground(Color.clear)
                        .accessibilityValue(selectedComparisonID == comparison.id ? "Selected" : "Not selected")
                }
                    if model.state.comparisons.isEmpty { Text("No comparisons").foregroundStyle(.secondary) }
                }
            }.listStyle(.sidebar).navigationTitle("msgblast")
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 8) {
                        UpdateSidebar(updater: updater)
                        WhatsNewSidebar()
                    }.padding(12)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .overlay(alignment: .top) { Divider() }
                }
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 330)
        } detail: {
            if selection == .discover {
                DiscoverView(model: model).navigationTitle("")
            } else {
            VStack(spacing: 0) {
                if model.demo { demoControls }
                if model.state.onboarding != nil {
                    let unresolved = model.onboarding.setupReminderNames
                    if !unresolved.isEmpty {
                    HStack {
                        Text("Finish connecting \(unresolved.joined(separator: ", ")).").foregroundStyle(.secondary)
                        Spacer()
                        Button("Connect agents") {
                            if !model.onboarding.unresolvedMessageAgents.isEmpty { model.onboarding.reviewMessagesAgents() }
                            else { model.onboarding.resume() }
                        }
                    }.padding(18).background(.bar)
                    }
                }
                if model.usesMessages { MessagesAccessBanner(model: model) }
                AgentsWorkspaceView(model: model, web: model.webAgents, showingComparison: $showingComparison, newBlastRequest: model.newBlastRequest, captureLayout: captureLayout)
            }.navigationTitle("")
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(ConversationCloseBridge(model: model, comparisonID: selection == .agents && showingComparison ? web.comparisonID : nil))
        .tint(.blue)
        .focusedSceneValue(\.mainWindowActions, model.error != nil ? nil : MainWindowActions(
            newBlast: { model.requestNewBlast() },
            showAgents: { showAgentGrid() },
            showDiscover: { selection = .discover },
            canStartBlast: model.canStartNewBlast))
        .onChange(of: model.newBlastRequest) { _, _ in selection = .agents; showingComparison = model.newBlastShowsChat }
        .onChange(of: model.webComparisonRequest) { _, _ in selection = .agents; showingComparison = true }
        .alert("msgblast", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .toolbar {
            if selection == .discover {
                ToolbarItem(placement: .navigation) {
                    Button {
                        model.requestNewBlast()
                    } label: {
                        Label("New Blast", systemImage: "square.and.pencil")
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                    }
                    .help("New Blast").accessibilityLabel("New Blast")
                    .disabled(!model.canStartNewBlast)
                }
            }
        }
    }
    private func sidebarLabel(_ title: String, systemImage: String, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(sidebarIconColor).frame(width: 22)
            Text(title).foregroundStyle(Color.primary)
                .opacity(controlActiveState == .inactive ? 0.5 : 1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 14, weight: .semibold))
        .padding(.horizontal, 10).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? sidebarSelectionColor : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    private var demoControls: some View {
        HStack(spacing: 14) {
            Label(model.webAgents.fixture ? "Local fixture · no real sends" : "Live web agents · simulated Messages", systemImage: "testtube.2").foregroundStyle(.orange)
            Toggle("Simulate one failure", isOn: $model.demoFailureOnce).toggleStyle(.checkbox)
            Spacer()
            Button("Reset sample data") { model.resetDemo() }
        }.font(.caption).padding(12).disabled(model.busy)
    }
}

private struct MessagesAccessBanner: View {
    @ObservedObject var model: AppModel
    @ObservedObject var guide: MessagesAccessGuide
    init(model: AppModel) { self.model = model; guide = model.accessGuide }
    var body: some View {
        if !model.databaseAvailable || guide.flow.isActive || guide.flow.stage == .verified {
            MessagesAccessRow(guide: guide, check: { model.refresh() }, accessAllowed: model.databaseAvailable).padding(18).help(model.databaseStatus)
            if model.permissionGuidePreview {
                Text("Permission guide preview · simulated history denial").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ConversationView: View {
    @ObservedObject var model: AppModel
    let comparisonID: UUID
    let memberID: UUID
    /// Separate-window input from `ComparisonWorkspace`; the agents workspace passes `recipient`.
    var headerControls: ConversationHeaderControls? = nil
    /// Whether this member receives the workspace's next message, and the click that toggles it.
    var recipient: (included: Bool, toggle: () -> Void)? = nil
    /// False when the workspace owns the one compose bar.
    var showsComposer = true
    var removeFromView: (() -> Void)?
    var body: some View {
        if let comparison = model.comparison(comparisonID), let member = comparison.members.first(where: { $0.id == memberID }) {
            let recipient = recipient ?? headerControls.map { (included: $0.included, toggle: $0.toggleRecipient) }
            VStack(spacing: 0) {
                ColumnHeader(agent: model.state.agents.first { $0.id == member.id }, name: member.name + (model.demo ? " (Demo)" : ""),
                             included: recipient?.included ?? true,
                             enabled: recipient != nil && (headerControls?.enabled ?? true) && !(model.busy || model.webBroadcastBusy),
                             detail: member.chat.handle, toggle: { recipient?.toggle() }) {
                    Button("Open in Messages") { model.openMessages(member) }
                    if let removeFromView { Button("Remove from View", action: removeFromView) }
                }
                if let error = member.error { NoticeRow(error, systemImage: "exclamationmark.circle", detail: error, attention: true) }
                if member.submission == .ready && !model.busy {
                    NoticeRow(text: "Not sent yet", attention: true) {
                        Button("Submit unsent recipients") { Task { await model.submit(comparisonID, retry: false) } }.disabled(comparison.endedAt != nil || model.busy)
                    }
                }
                if member.submission.canRetry {
                    NoticeRow(text: "Not sent to every recipient", systemImage: "exclamationmark.circle", attention: true) {
                        Button("Retry only failed recipients") { Task { await model.submit(comparisonID, retry: true) } }.disabled(comparison.endedAt != nil || model.busy)
                    }
                }
                if !model.databaseAvailable { NoticeRow(model.databaseStatus, detail: model.databaseStatus, attention: true) }
                if let headerControls {
                    // Separate windows still choose the conversation the floating composer follows.
                    TranscriptView(model: model, comparison: comparison, member: member).disabled(comparison.endedAt != nil)
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture().onEnded { if !model.busy { headerControls.selectConversation() } })
                } else {
                    TranscriptView(model: model, comparison: comparison, member: member).disabled(comparison.endedAt != nil)
                }
                if showsComposer {
                    MessageInput(text: privateDraft, attachments: model.attachmentDraft(comparisonID: comparisonID, memberID: memberID), addAttachments: { await model.addAttachments($0, comparisonID: comparisonID, memberID: memberID) }, removeAttachment: { id in model.setAttachmentDraft(model.attachmentDraft(comparisonID: comparisonID, memberID: memberID).filter { $0.id != id }, comparisonID: comparisonID, memberID: memberID) }, placeholder: "Message", accessibilityName: "Private reply to \(member.name)", sendLabel: "Send privately", disabled: comparison.endedAt != nil || model.busy || (model.webBroadcastBusy && !model.webBroadcastInputsFinished) || member.anchor == nil) {
                        Task { await model.followUp(comparisonID, only: memberID) }
                    }.padding(.horizontal, Space.barEdge).padding(.vertical, Space.barV)
                    FollowUpStatus(model: model, comparison: comparison, only: memberID).disabled(comparison.endedAt != nil)
                        .padding(.horizontal, Space.barEdge).padding(.bottom, Space.barV)
                }
            }.frame(minWidth: Space.columnMin, minHeight: Space.columnMin).background(Color(nsColor: .textBackgroundColor))
        }
    }
    private var privateDraft: Binding<String> {
        Binding(get: { model.comparison(comparisonID)?.privateDrafts[memberID.uuidString] ?? "" }, set: { value in
            if let i = model.index(comparisonID) { model.state.comparisons[i].privateDrafts[memberID.uuidString] = value; model.persist() }
        })
    }
}

struct TranscriptView: View {
    @ObservedObject var model: AppModel
    let comparison: Comparison
    let member: Member
    @State private var followingBottom = true
    @State private var atBottom = true
    @State private var userIsScrolling = false
    private var bottomID: String { "transcript-bottom-" + comparison.id.uuidString + member.id.uuidString }
    var body: some View {
        let transcript = model.transcript(comparison, member: member)
        GeometryReader { geometry in
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                // Messages' rhythm: a sender's run is 2 pt apart and ends in a tail, runs are 8 pt
                // apart, and a time header has 12 pt above and below. Rows set their own side
                // insets. A plain stack, not a lazy one, so row heights are exact while following
                // the newest message.
                VStack(alignment: .leading, spacing: 0) {
                    if transcript.isEmpty {
                        Text(member.anchor == nil ? "Waiting for Messages…" : "History unavailable")
                            .font(.system(size: Space.bodyText)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, Space.section)
                    }
                    let lastOutgoingID = transcript.last(where: { $0.outgoing })?.id
                    ForEach(Array(transcript.enumerated()), id: \.element.id) { offset, message in
                        let previous = offset == 0 ? nil : transcript[offset - 1]
                        let next = offset + 1 < transcript.count ? transcript[offset + 1] : nil
                        let header = ThreadFormat.showsTimeHeader(message.date, previous: previous?.date)
                        let continues = !header && previous.map { $0.outgoing == message.outgoing && $0.replyTo == message.replyTo } == true
                        let endsRun = next.map { ThreadFormat.showsTimeHeader($0.date, previous: message.date) || $0.outgoing != message.outgoing || $0.replyTo != message.replyTo } ?? true
                        if header { ThreadTimeHeader(date: message.date, first: offset == 0) }
                        ThreadRow(mine: message.outgoing, firstOfRun: !continues, lastOfRun: endsRun,
                                  sender: sender(for: message), status: status(for: message, lastOutgoingID: lastOutgoingID)) {
                            bubbleColumn(message, tail: endsRun, maxWidth: geometry.size.width * Space.bubbleMax)
                        }
                        .padding(.top, header || previous == nil ? 0 : continues ? Space.run : Space.runGap)
                        .id(message.id)
                    }
                }.padding(.vertical, Space.gap)
                Color.clear.frame(height: 1).id(bottomID)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in
                    if followingBottom { proxy.scrollTo(bottomID, anchor: .bottom) }
                }
            }
            .onScrollGeometryChange(for: Bool.self) { info in
                info.contentOffset.y + info.containerSize.height >= info.contentSize.height - 2
            } action: { _, value in
                atBottom = value
                if userIsScrolling { followingBottom = value }
            }
            .onScrollPhaseChange { _, phase in
                userIsScrolling = phase == .interacting || phase == .decelerating
                if userIsScrolling { followingBottom = atBottom }
            }
            .onChange(of: transcript.last?.id) { _, _ in
                followingBottom = true
                Task { @MainActor in
                    await Task.yield()
                    if followingBottom { proxy.scrollTo(bottomID, anchor: .bottom) }
                }
            }
            .onChange(of: geometry.size.height) { _, _ in
                if followingBottom { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo(bottomID, anchor: .bottom) }
        }
        }
    }
    /// Replies are named and signed with the member's avatar; your own rows carry neither.
    private func sender(for message: Message) -> (name: String, avatar: AnyView)? {
        guard !message.outgoing else { return nil }
        return (member.name, AnyView(AgentAvatar(agent: model.state.agents.first { $0.id == member.id }, name: member.name, size: Space.avatarThread)))
    }
    private func status(for message: Message, lastOutgoingID: Int64?) -> (text: String, color: Color)? {
        guard message.outgoing else { return nil }
        if message.delivery == .failed { return ("Not Delivered", .red) }
        if message.delivery == .delivered, message.id == lastOutgoingID { return ("Delivered", .secondary) }
        return nil
    }
    /// The bubble column: attachments, business choices, a link preview with its remaining
    /// text, or the text bubble; reactions overlap the top corner away from the tail.
    private func bubbleColumn(_ message: Message, tail: Bool, maxWidth: CGFloat) -> some View {
        VStack(alignment: message.outgoing ? .trailing : .leading, spacing: Space.tight) {
            ForEach(message.attachments) { file in AttachmentView(attachment: file) }
            if let payload = message.businessPayload {
                BusinessChoicesView(model: model, message: message, member: member, payload: payload)
            } else if let preview = message.linkPreview {
                if !preview.remainingText.isEmpty {
                    ThreadBubble(mine: message.outgoing, tail: false, maxWidth: maxWidth) {
                        MessageText(text: preview.remainingText, outgoing: message.outgoing).fixedSize(horizontal: false, vertical: true)
                    }
                }
                RichLinkView(store: model.linkPreviews, url: preview.url)
            } else if !message.text.isEmpty {
                ThreadBubble(mine: message.outgoing, tail: tail, maxWidth: maxWidth) {
                    MessageText(text: message.text, outgoing: message.outgoing).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .overlay(alignment: message.outgoing ? .topLeading : .topTrailing) {
            if !message.reactions.isEmpty {
                // It dips only into the bubble's top inset, so it never covers the first line.
                ReactionBadge(reactions: message.reactions)
                    .offset(x: message.outgoing ? -Space.bubbleH : Space.bubbleH, y: -(Space.reactionPill - Space.bubbleV))
            }
        }
        // Room for the part of a reaction pill above the bubble.
        .padding(.top, message.reactions.isEmpty ? 0 : Space.reactionPill - Space.bubbleV)
    }
}

struct FollowUpStatus: View {
    @ObservedObject var model: AppModel
    let comparison: Comparison
    var only: UUID?
    var universal = false
    var body: some View {
        if let attempt = comparison.followUps.last(where: { universal || (only == nil ? $0.memberIDs.count == comparison.members.count : $0.memberIDs == [only!]) }) {
            let failures = comparison.members.filter { member in
                guard attempt.memberIDs.contains(member.id) else { return false }
                switch attempt.states[member.id.uuidString] {
                case .failed, .uncertain: return true
                case .ready, nil: return !model.busy
                case .sending, .submitted: return false
                }
            }
            if !failures.isEmpty {
                // One line: who was not reached; each reason behind the ⓘ. The bar spaces it.
                HStack(spacing: Space.tight) {
                    Image(systemName: "exclamationmark.circle")
                    Text("Not sent to \(failures.map(\.name).formatted(.list(type: .and)))").lineLimit(1)
                    DetailButton(detail: failures.map { member in
                        "\(member.name): \(attempt.errors[member.id.uuidString] ?? attempt.states[member.id.uuidString]?.label ?? "Pending")"
                    }.joined(separator: "\n"))
                    Spacer()
                    if attempt.states.values.contains(.failed) {
                        Button("Retry") { Task { await model.followUp(comparison.id, only: only, retry: attempt.id) } }.disabled(model.busy)
                    }
                    if attempt.states.values.contains(.ready) && !model.busy {
                        Button("Resume") { Task { await model.followUp(comparison.id, only: only, retry: attempt.id, resumeUnsent: true) } }.disabled(model.busy)
                    }
                }
                .font(.caption).foregroundStyle(.orange)
                .buttonStyle(.borderless).controlSize(.small)
            }
        }
    }
}

struct FloatingComposer: View {
    @ObservedObject var model: AppModel
    let comparisonID: UUID
    var body: some View {
        if let comparison = model.comparison(comparisonID) {
            VStack(spacing: 12) {
                HStack(spacing: 6) {
                    ConversationNavigation(comparison: comparison) { memberID in model.coordinator?.focus(comparisonID, memberID: memberID) }
                    Button { model.coordinator?.tile(comparisonID) } label: { Image(systemName: "rectangle.split.3x1") }
                        .buttonStyle(.bordered).help("Tile conversation windows").accessibilityLabel("Tile windows")
                }
                SharedComposer(model: model, comparisonID: comparisonID)
            }.padding(16).frame(minWidth: 440, idealWidth: 520, maxWidth: .infinity)
                .onChange(of: comparison.allAttachmentsDraft?.count ?? 0) { _, count in model.coordinator?.fitComposer(comparisonID, hasAttachments: count > 0) }
                .onAppear { model.coordinator?.fitComposer(comparisonID, hasAttachments: !(comparison.allAttachmentsDraft ?? []).isEmpty) }
        }
    }
}

struct ConversationNavigation: View {
    let comparison: Comparison
    let focus: (UUID) -> Void
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(comparison.members) { member in
                    Button(member.name) { focus(member.id) }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule)
                        .help("Show \(member.name)'s conversation")
                        .accessibilityLabel("Show \(member.name)'s conversation")
                }
            }
        }.scrollIndicators(.hidden)
    }
}

struct SharedComposer: View {
    @ObservedObject var model: AppModel
    let comparisonID: UUID
    var recipientIDs: [UUID]?
    var body: some View {
        if let comparison = model.comparison(comparisonID) {
            let recipientSet = recipientIDs.map(Set.init)
            let targets = comparison.members.filter { recipientSet?.contains($0.id) ?? true }
            let scope = targets.isEmpty ? "No recipients" : targets.map(\.name).joined(separator: ", ")
            VStack(spacing: 8) {
                MessageInput(text: Binding(get: { model.comparison(comparisonID)?.allDraft ?? "" }, set: { value in
                    if let i = model.index(comparisonID) { model.state.comparisons[i].allDraft = value; model.persist() }
                }), attachments: model.attachmentDraft(comparisonID: comparisonID), addAttachments: { await model.addAttachments($0, comparisonID: comparisonID) }, removeAttachment: { id in model.setAttachmentDraft(model.attachmentDraft(comparisonID: comparisonID).filter { $0.id != id }, comparisonID: comparisonID) }, placeholder: recipientIDs == nil ? "Message all \(targets.count) agents" : targets.isEmpty ? "Message" : "Message \(scope)", accessibilityName: recipientIDs == nil ? "Follow-up to all agents" : "Universal message", sendLabel: recipientIDs == nil ? "Send to all" : "Send to \(scope)", disabled: comparison.endedAt != nil || model.busy || targets.isEmpty || targets.contains { $0.anchor == nil }) {
                    Task { await model.followUp(comparisonID, recipients: recipientIDs) }
                }
                FollowUpStatus(model: model, comparison: comparison, universal: recipientIDs != nil)
            }
        }
    }
}

struct ComparisonWorkspace: View {
    @ObservedObject var model: AppModel
    let comparisonID: UUID
    @State private var hiddenMembers: Set<UUID> = []
    var body: some View {
        if let comparison = model.comparison(comparisonID) {
            let shownMembers = comparison.members.filter { !hiddenMembers.contains($0.id) }
            let selection = comparison.recipientSelection ?? ConversationRecipients()
            let recipients = selection.recipientIDs(in: comparison.members)
            GeometryReader { geometry in
                let columnWidth = max(320, geometry.size.width / CGFloat(max(1, shownMembers.count)))
                ScrollViewReader { proxy in
                    VStack(spacing: 0) {
                        GeometryReader { columns in
                            ScrollView(.horizontal) {
                                HStack(spacing: 0) {
                                    ForEach(shownMembers) { member in
                                        ConversationView(model: model, comparisonID: comparisonID, memberID: member.id, headerControls: ConversationHeaderControls(enabled: comparison.endedAt == nil, selected: selection.selectedConversation == member.id, included: recipients.contains(member.id), selectConversation: {
                                            var updated = selection
                                            updated.selectConversation(member.id)
                                            model.setRecipients(updated, for: comparisonID)
                                        }, toggleRecipient: {
                                            var updated = selection
                                            updated.toggleRecipient(member.id, in: comparison.members)
                                            model.setRecipients(updated, for: comparisonID)
                                        }), removeFromView: {
                                            var updated = selection
                                            if recipients.contains(member.id) { updated.toggleRecipient(member.id, in: comparison.members) }
                                            model.setRecipients(updated, for: comparisonID)
                                            hiddenMembers.insert(member.id)
                                        })
                                            .frame(width: columnWidth, height: columns.size.height)
                                            .overlay(alignment: .trailing) {
                                                if member.id != shownMembers.last?.id {
                                                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
                                                }
                                            }
                                            .overlay {
                                                if selection.selectedConversation == member.id {
                                                    Rectangle().stroke(.blue.opacity(0.5), lineWidth: 1).allowsHitTesting(false)
                                                }
                                            }
                                            .id(member.id)
                                    }
                                }
                            }
                        }
                        Divider()
                        VStack(spacing: 12) {
                            RecipientPills(model: model, comparison: comparison, showMember: { hiddenMembers.remove($0) }).disabled(comparison.endedAt != nil)
                            SharedComposer(model: model, comparisonID: comparisonID, recipientIDs: recipients)
                                .disabled(model.webBroadcastBusy)
                        }.padding(16).frame(maxWidth: .infinity).background(.bar)
                    }
                    .onChange(of: selection.selectedConversation) { _, memberID in
                        if let memberID { withAnimation { proxy.scrollTo(memberID, anchor: .center) } }
                    }
                }
            }.background(Color(nsColor: .textBackgroundColor))
        }
    }
}

struct RecipientPills: View {
    @ObservedObject var model: AppModel
    let comparison: Comparison
    var showMember: (UUID) -> Void = { _ in }
    var body: some View {
        let selection = comparison.recipientSelection ?? ConversationRecipients()
        let recipientSet = Set(selection.recipientIDs(in: comparison.members))
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Text("Send to").font(.caption).foregroundStyle(.secondary)
                ForEach(comparison.members) { member in
                    let included = recipientSet.contains(member.id)
                    Button {
                        var updated = selection
                        updated.toggleRecipient(member.id, in: comparison.members)
                        model.setRecipients(updated, for: comparison.id)
                        showMember(member.id)
                    } label: {
                        Text(member.name).font(.system(size: 13, weight: .medium)).fixedSize()
                            .padding(.horizontal, 12).padding(.vertical, 6)
                    }.buttonStyle(.plain)
                        .background(included ? Color.blue.opacity(0.25) : Color.clear, in: Capsule())
                        .accessibilityLabel("Recipient \(member.name)")
                        .accessibilityValue(included ? "Selected" : "Not selected")
                        .help(included ? "Exclude \(member.name) from this message" : "Include \(member.name) in this message")
                        .disabled(model.busy || model.webBroadcastBusy)
                }
                ForEach(model.recipientWebSessions(for: comparison), id: \.id) { session in
                    let joined = comparison.resolvedWebAgentIDs.contains(session.id)
                    Button {
                        model.coordinator?.prepareJoiningWebAgent(comparison.id)
                        if joined { return }
                        model.webBroadcastBusy = true
                        model.webAgents.select(session, selected: true)
                        session.connect()
                        Task { @MainActor in
                            _ = await model.joinWebAgent(session, comparisonID: comparison.id)
                            model.webBroadcastBusy = false
                        }
                    } label: {
                        Label(session.name, systemImage: joined ? "bubble.left" : "plus.circle").font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                    }.buttonStyle(.plain)
                        .accessibilityLabel(joined ? "Open \(session.name) conversation" : "Add \(session.name) to conversation")
                        .help(joined ? "Open this conversation" : "Add \(session.name) with the original ask and shared follow-ups")
                        .disabled(model.busy || model.webBroadcastBusy || !session.isEnabled)
                }
                ForEach(model.showcaseMessageAgents.filter { agent in !comparison.members.contains(where: { $0.id == agent.id }) }) { agent in
                    Button {
                        Task { await model.addAgent(agent, to: comparison.id); model.coordinator?.open(comparison.id) }
                    } label: {
                        Label(agent.name, systemImage: "plus.circle").font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                    }.buttonStyle(.plain)
                        .accessibilityLabel("Add \(agent.name) to conversation")
                        .help("Add \(agent.name) with the original ask and shared follow-ups")
                        .disabled(model.busy || model.webBroadcastBusy || model.route(agent) == nil)
                }
            }
        }.scrollIndicators(.hidden).frame(height: 36)
    }
}

struct AppSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: AppUpdater
    @ObservedObject var shortcut: NewBlastShortcut
    var body: some View {
        Form {
            Section("Quick Access") { NewBlastShortcutSettings(shortcut: shortcut) }
            Section("Permissions") {
                PermissionsSettingsView(model: model)
            }
            Section("App Agents") {
                AppAgentsSettingsView(model: model, web: model.webAgents, permissions: model.onboarding.appPermissions)
            }
            Picker("Conversations", selection: Binding(get: { model.state.effectiveWindowStyle }, set: { model.setWindowStyle($0) })) {
                Text("One window").tag(ComparisonWindowStyle.connected)
                Text("Separate windows").tag(ComparisonWindowStyle.separate)
            }.pickerStyle(.radioGroup)
            Section {
                LocalAgentSettingsView(agent: model.personalAgent, web: model.webAgents, busy: model.busy || model.webBroadcastBusy)
            }
            Section("Web agents") {
                WebAgentSettingsView(model: model, web: model.webAgents)
            }
            Section("Grok Bot") {
                GrokBotConnectionsView(model: model, web: model.webAgents, busy: model.busy || model.webBroadcastBusy)
            }
            Section("Updates") {
                Text(updater.version).foregroundStyle(.secondary)
                if updater.configuration.isEnabled {
                    Toggle("Automatically check for updates", isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 }))
                    Toggle("Automatically download and install on quit", isOn: Binding(get: { updater.automaticallyInstalls }, set: { updater.automaticallyInstalls = $0 }))
                        .disabled(!updater.automaticallyChecks)
                    Button("Check for Updates…") { updater.checkForUpdates() }.disabled(!updater.canCheckForUpdates)
                } else {
                    Text(updater.configuration.unavailableReason).foregroundStyle(.secondary)
                }
            }
            Section("Sharing") { SharingSettingsView(model: model) }
        }.formStyle(.grouped).padding(20).frame(width: 640, height: 650)
    }
}

private struct WebAgentSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var web: WebAgents
    @State private var configuration: AgentConfigurationAction?
    @State private var signIn: WebAgentID?
    private var busy: Bool { model.busy || model.webBroadcastBusy }

    var body: some View {
        Text("Use separate website profiles for work and personal accounts. Mac app connections use the account selected in that app.")
            .font(.caption).foregroundStyle(.secondary)
        ForEach(WebProvider.settingsOnlyWebProviders) { provider in
            VStack(alignment: .leading, spacing: 8) {
                ForEach(web.sessions.filter { $0.provider == provider }, id: \.id) { session in
                    HStack {
                        Toggle(session.name, isOn: Binding(
                            get: { session.isEnabled },
                            set: { enabled in
                                session.setEnabled(enabled)
                                if enabled {
                                    var grid = model.agentGridLayout
                                    grid.add(session.id.gridID)
                                    _ = model.setAgentGrid(grid)
                                }
                            }
                        )).toggleStyle(.switch)
                            .accessibilityIdentifier(session.id.instance == nil ? "enable-web-\(provider.rawValue)" : "enable-web-\(session.id.id)")
                        if provider.supportsCopies {
                            Button("Sign in…") { signIn = session.id }
                                .accessibilityLabel("Sign in to \(session.name)")
                                .disabled(!session.isEnabled)
                            if session.id.instance != nil {
                                Button("Rename…") { configuration = .rename(session.id) }
                                    .accessibilityLabel("Rename \(session.name)")
                            }
                        }
                    }
                }
                if provider.supportsCopies {
                    Button("Add \(provider.name) account…") { configuration = .addAccount(WebAgentID(provider: provider)) }
                        .accessibilityIdentifier("add-account-\(provider.rawValue)")
                }
            }.disabled(busy)
        }
        .sheet(item: $configuration) { action in
            AgentConfigurationSheet(action: action, web: web, busy: busy) { session in
                var grid = model.agentGridLayout
                grid.add(session.id.gridID)
                guard model.setAgentGrid(grid) else { throw AppFailure.blocked(model.error ?? "Could not add the account to your grid.") }
            }
        }
        .sheet(item: $signIn) { id in
            if let session = web.session(for: id) {
                VStack(alignment: .trailing, spacing: 12) {
                    Button("Done") { signIn = nil }.keyboardShortcut(.cancelAction)
                    WebAccountSignInView(session: session)
                }.padding(20).frame(width: 600, height: 550)
            }
        }
    }
}
