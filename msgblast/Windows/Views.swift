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

struct ConversationHeaderControls {
    var enabled = true
    let selected: Bool
    let included: Bool
    let selectConversation: () -> Void
    let toggleRecipient: () -> Void
}

struct ContactHeader: View {
    let agent: Agent?
    let name: String
    let destination: String
    var controls: ConversationHeaderControls?
    var removeFromView: (() -> Void)?
    var body: some View {
        VStack(spacing: 2) {
            if let controls {
                Button(action: controls.selectConversation) {
                    AgentAvatar(agent: agent, name: name, size: 38)
                        .overlay { if controls.selected { Circle().stroke(.blue, lineWidth: 2).padding(-3) } }
                }.buttonStyle(.plain).disabled(!controls.enabled).accessibilityLabel("Select \(agent?.name ?? name) conversation")
                    .accessibilityValue(controls.selected ? "Selected" : "Not selected")
                Button(action: controls.toggleRecipient) {
                    Text(name).font(.system(size: 13, weight: .semibold)).padding(.horizontal, 11).padding(.vertical, 5)
                }.buttonStyle(.plain).disabled(!controls.enabled)
                    .background(controls.included ? Color.blue.opacity(0.25) : Color.clear, in: Capsule())
                    .accessibilityLabel("Shared recipient \(agent?.name ?? name)")
                    .accessibilityValue(controls.included ? "Included" : "Excluded")
                    .help(controls.included ? "Exclude from shared sends" : "Include in shared sends")
            } else {
                AgentAvatar(agent: agent, name: name, size: 38)
                Text(name).font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
            }
        }.frame(height: 78).help(destination)
            .frame(maxWidth: .infinity).contentShape(Rectangle())
            .contextMenu {
                if let removeFromView { Button("Remove from view", action: removeFromView) }
            }
    }
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
        view.font = .systemFont(ofSize: 14)
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
    var body: some View {
        VStack(spacing: 4) {
            if !attachments.isEmpty { AttachmentDraftStrip(attachments: attachments, disabled: unavailable, remove: removeAttachment) }
            HStack(alignment: .bottom, spacing: 9) {
                if attachmentsEnabled { AttachmentComposer(disabled: unavailable, add: addAttachments, importing: $importing) }
                HStack(alignment: .bottom, spacing: 8) {
                    MessageEditor(text: $text, accessibilityName: accessibilityName, attachmentsEnabled: attachmentsEnabled && !unavailable, importAttachment: { selection in
                        importing = true
                        Task { await addAttachments(selection); importing = false }
                    }, send: { if !unavailable && hasContent { send() } }, focusRequest: focusRequest)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty { Text(placeholder).font(.system(size: 14)).foregroundStyle(Color(nsColor: .placeholderTextColor)).padding(.top, 2).allowsHitTesting(false).accessibilityHidden(true) }
                        }
                    if hasContent {
                        Button(action: send) { Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold)).frame(width: 22, height: 22) }
                            .buttonStyle(.plain).foregroundStyle(.white)
                            .background(unavailable ? Color.gray : Color.blue, in: Circle())
                            .accessibilityLabel(sendLabel)
                            .accessibilityHint(sendDisabledReason ?? "")
                            .help(sendDisabledReason ?? "\(sendLabel) (Return or ⌘Return; ⇧Return for a new line)")
                            .disabled(unavailable)
                    }
                }
                .padding(.leading, 14).padding(.trailing, 7).padding(.vertical, 5)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 23))
            }
        }
        .overlay { if dropTarget { RoundedRectangle(cornerRadius: 18).stroke(.blue, lineWidth: 2) } }
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
    @State private var showingComparison = false
    private var sidebarSelectionColor: Color { Color.primary.opacity(controlActiveState == .inactive ? 0.06 : 0.10) }
    private var sidebarIconColor: Color { controlActiveState == .inactive ? .secondary : .accentColor }
    private var showingAgents: Bool { selection == .agents && !showingComparison }
    private var selectedComparisonID: UUID? { selection == .agents && showingComparison ? web.comparisonID : nil }

    init(model: AppModel, updater: AppUpdater) {
        self.model = model
        self.web = model.webAgents
        self.updater = updater
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $captureLayout.sidebarVisibility) {
            List {
                Section {
                    Button { selection = .agents; showingComparison = false } label: {
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
            showAgents: { selection = .agents; showingComparison = false },
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
                    .disabled(model.busy || model.webBroadcastBusy || web.sessions.contains { $0.isSending })
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
    var headerControls: ConversationHeaderControls?
    var removeFromView: (() -> Void)?
    var body: some View {
        if let comparison = model.comparison(comparisonID), let member = comparison.members.first(where: { $0.id == memberID }) {
            VStack(spacing: 0) {
                ContactHeader(agent: model.state.agents.first { $0.id == member.id }, name: member.name + (model.demo ? " (Demo)" : ""), destination: member.chat.handle, controls: headerControls, removeFromView: removeFromView)
                    .frame(maxWidth: .infinity).background(.bar)
                    .disabled(model.busy || model.webBroadcastBusy)
                if let error = member.error { Text(error).font(.caption).foregroundStyle(.orange).padding(12) }
                if member.submission == .ready && !model.busy {
                    Button("Submit unsent recipients") { Task { await model.submit(comparisonID, retry: false) } }.disabled(comparison.endedAt != nil || model.busy).padding(8)
                }
                if member.submission.canRetry {
                    Button("Retry only failed recipients") { Task { await model.submit(comparisonID, retry: true) } }.disabled(comparison.endedAt != nil || model.busy).padding(8)
                }
                if !model.databaseAvailable { Text(model.databaseStatus).font(.caption).foregroundStyle(.orange).padding(12) }
                if let headerControls {
                    TranscriptView(model: model, comparison: comparison, member: member).disabled(comparison.endedAt != nil)
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture().onEnded { if !model.busy { headerControls.selectConversation() } })
                } else {
                    TranscriptView(model: model, comparison: comparison, member: member).disabled(comparison.endedAt != nil)
                }
                MessageInput(text: privateDraft, attachments: model.attachmentDraft(comparisonID: comparisonID, memberID: memberID), addAttachments: { await model.addAttachments($0, comparisonID: comparisonID, memberID: memberID) }, removeAttachment: { id in model.setAttachmentDraft(model.attachmentDraft(comparisonID: comparisonID, memberID: memberID).filter { $0.id != id }, comparisonID: comparisonID, memberID: memberID) }, placeholder: "Message", accessibilityName: "Private reply to \(member.name)", sendLabel: "Send privately", disabled: comparison.endedAt != nil || model.busy || model.webBroadcastBusy || member.anchor == nil) {
                    Task { await model.followUp(comparisonID, only: memberID) }
                }.padding(12)
                FollowUpStatus(model: model, comparison: comparison, only: memberID).disabled(comparison.endedAt != nil)
            }.frame(minWidth: 320, minHeight: 320).background(Color(nsColor: .textBackgroundColor))
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
                LazyVStack(alignment: .leading, spacing: 3) {
                    if transcript.isEmpty {
                        Text(member.anchor == nil ? "Waiting for Messages…" : "History unavailable").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 30)
                    }
                    ForEach(Array(transcript.enumerated()), id: \.element.id) { offset, message in
                        if offset == 0 || message.date.timeIntervalSince(transcript[offset - 1].date) > 300 {
                            Text(timestamp(message.date))
                                .font(.caption2.weight(.medium)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 10)
                        }
                        VStack(alignment: .trailing, spacing: 3) {
                            HStack(alignment: .bottom, spacing: 0) {
                                if message.outgoing { Spacer(minLength: geometry.size.width * 0.25) }
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(message.attachments) { file in AttachmentView(attachment: file) }
                                    if let payload = message.businessPayload {
                                        BusinessChoicesView(model: model, message: message, member: member, payload: payload)
                                    } else if let preview = message.linkPreview {
                                        if !preview.remainingText.isEmpty {
                                            textBubble(message, text: preview.remainingText, tail: false)
                                        }
                                        RichLinkView(store: model.linkPreviews, url: preview.url)
                                    } else if !message.text.isEmpty {
                                        textBubble(message, text: message.text, tail: offset == transcript.count - 1 || transcript[offset + 1].outgoing != message.outgoing || transcript[offset + 1].date.timeIntervalSince(message.date) > 300 || transcript[offset + 1].replyTo != message.replyTo)
                                    }
                                }
                                .overlay(alignment: message.outgoing ? .topLeading : .topTrailing) {
                                    if !message.reactions.isEmpty {
                                        ReactionBadge(reactions: message.reactions).offset(x: message.outgoing ? -12 : 12, y: -23)
                                    }
                                }
                                .padding(.top, message.reactions.isEmpty ? 0 : 23)
                                if !message.outgoing { Spacer(minLength: geometry.size.width * 0.25) }
                            }
                            if message.outgoing, message.delivery == .failed {
                                Text("Not Delivered").font(.caption2.weight(.medium)).foregroundStyle(.red)
                                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.bottom, 4)
                            } else if message.outgoing, message.delivery == .delivered, message.id == transcript.last(where: { $0.outgoing })?.id {
                                Text("Delivered").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.bottom, 4)
                            }
                        }.padding(.top, offset > 0 && transcript[offset - 1].outgoing != message.outgoing ? 6 : 0).id(message.id)
                    }
                }.padding(.horizontal, 20).padding(.bottom, 10)
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
    private func textBubble(_ message: Message, text: String, tail: Bool) -> some View {
        MessageText(text: text, outgoing: message.outgoing).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 6.5)
            .foregroundStyle(message.outgoing ? Color.white : Color.primary)
            .background(message.outgoing ? Color(nsColor: .systemBlue) : MessageAppearance.incomingBubbleColor, in: MessageBubble(outgoing: message.outgoing, tail: tail))
    }
    private func timestamp(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "Today \(time)" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday \(time)" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + " at " + time
    }
}

struct MessageBubble: Shape {
    let outgoing: Bool
    let tail: Bool
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height, r = min(15.0, rect.height / 2), c = r * 0.55228475
        guard tail else { return Path(roundedRect: rect, cornerRadius: r) }
        var bubble = Path()
        bubble.move(to: CGPoint(x: r, y: 0))
        bubble.addLine(to: CGPoint(x: w - r, y: 0))
        bubble.addCurve(to: CGPoint(x: w, y: r), control1: CGPoint(x: w - r + c, y: 0), control2: CGPoint(x: w, y: r - c))
        bubble.addLine(to: CGPoint(x: w, y: h - r))
        bubble.addCurve(to: CGPoint(x: w - 8, y: h), control1: CGPoint(x: w, y: h - 7), control2: CGPoint(x: w - 8, y: h - 6))
        bubble.addCurve(to: CGPoint(x: w - 6.5, y: h + 4), control1: CGPoint(x: w - 8, y: h + 1), control2: CGPoint(x: w - 7, y: h + 3))
        bubble.addCurve(to: CGPoint(x: w - 15, y: h), control1: CGPoint(x: w - 6.5, y: h + 5), control2: CGPoint(x: w - 13, y: h + 2))
        bubble.addLine(to: CGPoint(x: r, y: h))
        bubble.addCurve(to: CGPoint(x: 0, y: h - r), control1: CGPoint(x: r - c, y: h), control2: CGPoint(x: 0, y: h - r + c))
        bubble.addLine(to: CGPoint(x: 0, y: r))
        bubble.addCurve(to: CGPoint(x: r, y: 0), control1: CGPoint(x: 0, y: r - c), control2: CGPoint(x: r - c, y: 0))
        bubble.closeSubpath()
        return outgoing ? bubble : bubble.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.width, ty: 0))
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
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(failures) { member in
                        Text("\(member.name): \(attempt.errors[member.id.uuidString] ?? attempt.states[member.id.uuidString]?.label ?? "Pending")").font(.caption).foregroundStyle(.orange)
                    }
                    if attempt.states.values.contains(.failed) {
                        Button("Retry failed follow-up recipients") { Task { await model.followUp(comparison.id, only: only, retry: attempt.id) } }.disabled(model.busy)
                    }
                    if attempt.states.values.contains(.ready) && !model.busy {
                        Button("Resume unsent follow-up recipients") { Task { await model.followUp(comparison.id, only: only, retry: attempt.id, resumeUnsent: true) } }.disabled(model.busy)
                    }
                }.padding(.horizontal, 12).padding(.bottom, 8)
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
                        session.updateState { $0.selected = true }
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
