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
            if let data = agent?.avatar, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(colors[abs(agent?.colorIndex ?? 0) % colors.count].gradient)
                    Text(String(name.prefix(1))).font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(.white)
                }
            }
        }.frame(width: size, height: size).clipShape(Circle())
    }
}

struct ConversationHeaderControls {
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
    var body: some View {
        VStack(spacing: 2) {
            if let controls {
                Button(action: controls.selectConversation) {
                    AgentAvatar(agent: agent, name: name, size: 38)
                        .overlay { if controls.selected { Circle().stroke(.blue, lineWidth: 2).padding(-3) } }
                }.buttonStyle(.plain).accessibilityLabel("Select \(agent?.name ?? name) conversation")
                    .accessibilityValue(controls.selected ? "Selected" : "Not selected")
                Button(action: controls.toggleRecipient) {
                    Text(name).font(.system(size: 13, weight: .semibold)).padding(.horizontal, 11).padding(.vertical, 5)
                }.buttonStyle(.plain)
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

struct PinnedAgentTile: View {
    let agent: Agent
    let selected: Bool
    let size: CGFloat
    let toggle: () -> Void
    var body: some View {
        Button(action: toggle) {
            VStack(spacing: 9) {
                AgentAvatar(agent: agent, name: agent.name, size: size)
                    .overlay(alignment: .bottomTrailing) {
                        ZStack {
                            Circle().fill(selected ? Color.blue : Color(nsColor: .windowBackgroundColor))
                            if selected {
                                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                            } else {
                                Circle().stroke(.secondary, lineWidth: 1)
                            }
                        }.frame(width: 24, height: 24)
                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                            .offset(x: 2, y: 2)
                    }
                Text(agent.name).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(agent.name)
            .accessibilityValue(selected ? "Selected" : "Not selected")
    }
}

struct MainView: View {
    @Environment(\.controlActiveState) private var controlActiveState
    @ObservedObject var model: AppModel
    @ObservedObject private var web: WebAgents
    private let updater: AppUpdater
    private enum DetailSelection { case agents, discover }
    @State private var selection = DetailSelection.agents
    @State private var showingComparison = false
    @State private var newBlastRequest: UUID? = UUID()
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
        NavigationSplitView {
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
                                Text((comparison.members.map(\.name) + (comparison.webProviders ?? []).map(\.name)).joined(separator: ", ")).fontWeight(.semibold).lineLimit(1)
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
                if let setup = model.state.onboarding, !setup.skipped.isEmpty {
                    HStack {
                        Text("\(setup.skipped.count) \(setup.skipped.count == 1 ? "agent" : "agents") still need setup.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Finish setup") { model.onboarding.resume() }
                    }.padding(18).background(.bar)
                }
                if model.usesMessages { MessagesAccessBanner(model: model) }
                AgentsWorkspaceView(model: model, web: model.webAgents, showingComparison: $showingComparison, newBlastRequest: newBlastRequest)
            }.navigationTitle("")
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .tint(.blue)
        .focusedSceneValue(\.mainWindowActions, model.error != nil ? nil : MainWindowActions(
            newBlast: {
                selection = .agents; showingComparison = false
                model.selectWorkspace(nil); newBlastRequest = UUID()
            },
            showAgents: { selection = .agents; showingComparison = false },
            showDiscover: { selection = .discover },
            canStartBlast: !model.busy && !model.webBroadcastBusy && !web.sessions.contains { $0.isSending }))
        .onChange(of: model.webComparisonRequest) { _, _ in selection = .agents; showingComparison = true }
        .alert("msgblast", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .toolbar {
            if selection == .discover {
                ToolbarItem(placement: .navigation) {
                    Button {
                        showingComparison = false
                        model.selectWorkspace(nil)
                        selection = .agents
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
            MessagesAccessRow(guide: guide, check: { model.refresh() }).padding(18).help(model.databaseStatus)
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
    var body: some View {
        if let comparison = model.comparison(comparisonID), let member = comparison.members.first(where: { $0.id == memberID }) {
            VStack(spacing: 0) {
                ContactHeader(agent: model.state.agents.first { $0.id == member.id }, name: member.name + (model.demo ? " (Demo)" : ""), destination: member.chat.handle, controls: headerControls)
                    .frame(maxWidth: .infinity).background(.bar)
                    .disabled(model.busy)
                if let error = member.error { Text(error).font(.caption).foregroundStyle(.orange).padding(12) }
                if member.submission == .ready && !model.busy {
                    Button("Submit unsent recipients") { Task { await model.submit(comparisonID, retry: false) } }.disabled(model.busy).padding(8)
                }
                if member.submission.canRetry {
                    Button("Retry only failed recipients") { Task { await model.submit(comparisonID, retry: true) } }.disabled(model.busy).padding(8)
                }
                if !model.databaseAvailable { Text(model.databaseStatus).font(.caption).foregroundStyle(.orange).padding(12) }
                if let headerControls {
                    TranscriptView(model: model, comparison: comparison, member: member)
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture().onEnded { if !model.busy { headerControls.selectConversation() } })
                } else {
                    TranscriptView(model: model, comparison: comparison, member: member)
                }
                MessageInput(text: privateDraft, attachments: model.attachmentDraft(comparisonID: comparisonID, memberID: memberID), addAttachments: { await model.addAttachments($0, comparisonID: comparisonID, memberID: memberID) }, removeAttachment: { id in model.setAttachmentDraft(model.attachmentDraft(comparisonID: comparisonID, memberID: memberID).filter { $0.id != id }, comparisonID: comparisonID, memberID: memberID) }, placeholder: "Message", accessibilityName: "Private reply to \(member.name)", sendLabel: "Send privately", disabled: model.busy || model.webBroadcastBusy || member.anchor == nil) {
                    Task { await model.followUp(comparisonID, only: memberID) }
                }.padding(12)
                FollowUpStatus(model: model, comparison: comparison, only: memberID)
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
    var body: some View {
        let transcript = model.transcript(comparison, member: member)
        GeometryReader { geometry in
        ScrollViewReader { proxy in
            ScrollView {
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
                                    if let preview = message.linkPreview {
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
            }
            .onChange(of: transcript.last?.id) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
            }
            .onAppear { if let id = transcript.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
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
                }), attachments: model.attachmentDraft(comparisonID: comparisonID), addAttachments: { await model.addAttachments($0, comparisonID: comparisonID) }, removeAttachment: { id in model.setAttachmentDraft(model.attachmentDraft(comparisonID: comparisonID).filter { $0.id != id }, comparisonID: comparisonID) }, placeholder: recipientIDs == nil ? "Message all \(targets.count) agents" : targets.isEmpty ? "Message" : "Message \(scope)", accessibilityName: recipientIDs == nil ? "Follow-up to all agents" : "Universal message", sendLabel: recipientIDs == nil ? "Send to all" : "Send to \(scope)", disabled: model.busy || targets.isEmpty || targets.contains { $0.anchor == nil }) {
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
    var body: some View {
        if let comparison = model.comparison(comparisonID) {
            let selection = comparison.recipientSelection ?? ConversationRecipients()
            let recipients = selection.recipientIDs(in: comparison.members)
            GeometryReader { geometry in
                let columnWidth = max(320, geometry.size.width / CGFloat(max(1, comparison.members.count)))
                ScrollViewReader { proxy in
                    VStack(spacing: 0) {
                        GeometryReader { columns in
                            ScrollView(.horizontal) {
                                HStack(spacing: 0) {
                                    ForEach(comparison.members) { member in
                                        ConversationView(model: model, comparisonID: comparisonID, memberID: member.id, headerControls: ConversationHeaderControls(selected: selection.selectedConversation == member.id, included: recipients.contains(member.id), selectConversation: {
                                            var updated = selection
                                            updated.selectConversation(member.id)
                                            model.setRecipients(updated, for: comparisonID)
                                        }, toggleRecipient: {
                                            var updated = selection
                                            updated.toggleRecipient(member.id, in: comparison.members)
                                            model.setRecipients(updated, for: comparisonID)
                                        }))
                                            .frame(width: columnWidth, height: columns.size.height)
                                            .overlay(alignment: .trailing) {
                                                if member.id != comparison.members.last?.id {
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
                            RecipientPills(model: model, comparison: comparison)
                            SharedComposer(model: model, comparisonID: comparisonID, recipientIDs: recipients)
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
                    } label: {
                        Text(member.name).font(.system(size: 13, weight: .medium)).fixedSize()
                            .padding(.horizontal, 12).padding(.vertical, 6)
                    }.buttonStyle(.plain)
                        .background(included ? Color.blue.opacity(0.25) : Color.clear, in: Capsule())
                        .accessibilityLabel("Recipient \(member.name)")
                        .accessibilityValue(included ? "Selected" : "Not selected")
                        .help(included ? "Exclude \(member.name) from this message" : "Include \(member.name) in this message")
                        .disabled(model.busy)
                }
                ForEach(model.state.agents.filter { agent in !comparison.members.contains(where: { $0.id == agent.id }) }) { agent in
                    Button {
                        Task { await model.addAgent(agent, to: comparison.id); model.coordinator?.open(comparison.id) }
                    } label: {
                        Label(agent.name, systemImage: "plus.circle").font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                    }.buttonStyle(.plain)
                        .accessibilityLabel("Add \(agent.name) to conversation")
                        .help("Add \(agent.name) with the original ask and shared follow-ups")
                        .disabled(model.busy || model.route(agent) == nil)
                }
            }
        }.scrollIndicators(.hidden).frame(height: 36)
    }
}

struct AppSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: AppUpdater
    var body: some View {
        Form {
            Section("Permissions") {
                PermissionsSettingsView(model: model)
            }
            Picker("Conversations", selection: Binding(get: { model.state.effectiveWindowStyle }, set: { model.setWindowStyle($0) })) {
                Text("One window").tag(ComparisonWindowStyle.connected)
                Text("Separate windows").tag(ComparisonWindowStyle.separate)
            }.pickerStyle(.radioGroup)
            Section {
                LocalAgentSettingsView(agent: model.personalAgent, web: model.webAgents, busy: model.busy || model.webBroadcastBusy)
            }
            Section("Grok Bot") {
                if let session = model.webAgents.sessions.first(where: { $0.provider == .grokbot }) {
                    GrokBotSettingsView(session: session, busy: model.busy || model.webBroadcastBusy)
                }
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
        }.formStyle(.grouped).padding(20).frame(width: 640, height: 650)
    }
}
