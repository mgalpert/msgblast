import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import msgblastMobileKit
import msgblastRemoteProtocol

/// The compose bar. Recipients come from the conversation's header selection (all members =
/// shared, one = private, several = a subset); a per-device draft, attachments for Messages
/// agents, a quote bar while replying, and at most one status line: what blocks Send, then preparing,
/// then the last result, then a launch note. A longer Mac reason is behind ⓘ.
struct ComposeBar: View {
    @ObservedObject var app: MobileApp
    let conversationID: UUID?
    @Binding var recipients: [String]
    /// The response being replied to; the conversation narrows recipients to its agent.
    var replyTo: Binding<RemoteTurn?> = .constant(nil)
    /// A group's header selection (empty is everyone). The badge in the field opens a strip to
    /// change it next to the keyboard; nil in direct threads and New Conversation.
    var selection: Binding<Set<String>>? = nil
    /// Focus requests from the conversation, such as starting a reply.
    var focusRequest = 0
    var onSent: (UUID?) -> Void
    @State private var text = ""
    @State private var preparing = false
    @State private var prepareReasons: [String: String] = [:]
    /// Each prepare's number; a newer one (the recipients changed) makes older answers stale.
    @State private var prepareGeneration = 0
    /// How long the phone waits for the Mac's readiness answer (the Mac bounds it at 20 s).
    static let prepareTimeout: Duration = .seconds(25)
    @State private var sending = false
    @State private var message: String?
    @State private var attachments: [(id: String, name: String)] = []
    @State private var photo: PhotosPickerItem?
    @State private var importing = false
    @State private var uploading = false
    /// Counters for haptics: a confirmed send, and one the Mac refused or did not confirm.
    @State private var sentCount = 0
    @State private var refusedCount = 0
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var fieldFocused = false
    /// The recipient strip above the field, opened from the badge.
    @State private var recipientsOpen = false
    private var choosesRecipients: Bool { selection != nil && conversationID != nil && members.count > 1 }
    @StateObject private var dictation = Dictation()
    /// Debug design review forces the dictation glyph, which the simulator would hide.
    private var showsDictation: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MSGBLAST_FIXTURE_DICTATION"] != nil { return true }
        #endif
        return Dictation.hasInput
    }

    private var presenter: ProjectionPresenter { ProjectionPresenter(state: app.store.projection, commands: app.store.commands) }
    private var members: [String] { conversationID.flatMap { app.store.projection.conversations[$0]?.agentIDs } ?? [] }
    private var draftKey: String { MobileStore.draftKey(conversation: conversationID, agentID: recipients.count == 1 && conversationID != nil ? recipients[0] : nil) }
    /// The plus shows only when a recipient takes attachments (Messages contacts today).
    private var takesAttachments: Bool {
        recipients.contains { id in app.store.projection.agents[id].map { $0.form == .messages || $0.capabilities.attachments } ?? false }
    }
    @State private var capturing = false
    private var block: ComposeBlock? {
        presenter.composeBlock(canSend: app.connection.state.canSend, connectionText: app.connection.state == .macLocked ? app.connection.state.statusText : "Not connected",
                               agentIDs: recipients, conversation: conversationID, prepareReasons: prepareReasons)
    }

    /// Send fills with the tint once there is something to send and someone to send it to.
    private var canSend: Bool { hasContent && !recipients.isEmpty && !sending && !preparing && block?.allowsSend != false }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.gap) {
            Group {
            if let quoted = replyTo.wrappedValue, let agent = quoted.agentID {
                // Messages-style quote bar while replying to one response.
                HStack(spacing: Space.gap) {
                    AgentAvatar(app: app, agentID: agent, name: presenter.shortName(agent), size: Space.avatarChip)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Replying to \(presenter.shortName(agent))").font(.caption.weight(.semibold))
                        Text(quoted.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button { replyTo.wrappedValue = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("Cancel Reply")
                }
            }
            if let status { statusLine(status) }
            if recipientsOpen, let selection, choosesRecipients {
                RecipientStrip(app: app, members: members, selection: selection)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !attachments.isEmpty {
                ScrollView(.horizontal) { HStack { ForEach(attachments, id: \.id) { Label($0.name, systemImage: "paperclip").font(.caption) } } }
            }
            if let note = dictation.note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            // The rows above the field keep the 16 pt screen margin (applied to each; an empty
            // group adds no spacing); the field row is wider.
            .padding(.horizontal, Space.screen - Space.barEdge)
            // Telegram's bar: a plain plus circle, one quiet capsule (an agent badge when one is
            // chosen, the text, then the dictation glyph inside), and a round Send outside.
            HStack(alignment: .bottom, spacing: Space.gap) {
                // Only for recipients that take attachments; otherwise the field starts at the edge.
                if takesAttachments {
                Menu {
                    // Messages' order: Camera (on a device with one), Photo, File.
                    if CameraPicker.isAvailable { Button { capturing = true } label: { Label("Camera", systemImage: "camera") } }
                    PhotosPicker(selection: $photo, matching: .images) { Label("Photo", systemImage: "photo") }
                    Button { importing = true } label: { Label("File", systemImage: "doc") }
                } label: {
                    Image(systemName: "plus").font(.system(size: Space.glyph + 2, weight: .regular))
                        .foregroundStyle(Color(.label).opacity(0.7))
                        .frame(width: Space.fieldHeight, height: Space.fieldHeight)
                        .background(Circle().fill(Color(.secondarySystemBackground)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add Photo or File")
                .transition(.opacity)
                }
                HStack(alignment: .bottom, spacing: 0) {
                    if choosesRecipients {
                        // Who this goes to; tap to choose next to the keyboard.
                        Button { withAnimation(.snappy) { recipientsOpen.toggle() } } label: {
                            RecipientBadge(app: app, recipients: recipients)
                                .frame(height: Space.fieldHeight)
                                .padding(.leading, Space.fieldBadgeInset)
                                // At least 44 pt to tap.
                                .contentShape(Rectangle().inset(by: -Space.fieldBadgeInset))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Recipients, \(recipients.count == members.count ? "everyone" : recipients.map(presenter.shortName).formatted(.list(type: .and)))")
                        .accessibilityHint(recipientsOpen ? "Hides the agents" : "Shows the agents to choose from")
                    } else if !recipients.isEmpty {
                        // Who this goes to: one agent, or a pair in New Conversation.
                        RecipientBadge(app: app, recipients: recipients)
                            .padding(.leading, Space.fieldBadgeInset)
                            .padding(.bottom, (Space.fieldHeight - (recipients.count == 1 ? Space.badge : Space.avatarChip)) / 2)
                            .accessibilityHidden(true)
                    }
                    MessageField(text: $text, placeholder: placeholder, focused: $fieldFocused,
                                 leadingInset: choosesRecipients || !recipients.isEmpty ? Space.gap : Space.fieldTextInset)
                    if !hasContent && showsDictation {
                        DictationGlyph(listening: dictation.state == .listening) { dictation.toggle(base: text) { text = $0 } }
                    }
                    Color.clear.frame(width: Space.inset - Space.tight, height: 1)
                }
                .frame(minHeight: Space.fieldHeight)
                .background(RoundedRectangle(cornerRadius: Space.fieldHeight / 2, style: .continuous).fill(Color(.secondarySystemBackground)))
                .animation(.snappy(duration: 0.2), value: hasContent)
                Button { send() } label: {
                    Image(systemName: "arrow.up").font(.system(size: Space.glyph * 0.85, weight: .semibold))
                        .foregroundStyle(canSend ? Color.white : Color.secondary)
                        .frame(width: Space.fieldHeight, height: Space.fieldHeight)
                        .background(Circle().fill(canSend ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.tertiarySystemFill))))
                        .animation(.easeOut(duration: 0.15), value: canSend)
                }
                .buttonStyle(.plain)
                // Looks exactly as enabled as it is: disabled while getting ready or sending.
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, Space.barEdge).padding(.vertical, Space.barV)
        .background(.bar)
        .sensoryFeedback(.success, trigger: sentCount)
        .sensoryFeedback(.error, trigger: refusedCount)
        .onChange(of: focusRequest) { _, _ in fieldFocused = true }
        // The strip goes with the keyboard.
        .onChange(of: fieldFocused) { _, focused in if !focused { withAnimation(.snappy) { recipientsOpen = false } } }
        .sensoryFeedback(.selection, trigger: selection?.wrappedValue)
        .onAppear {
            text = app.store.draft(draftKey); prepare()
            #if DEBUG
            // Design review: `MSGBLAST_FIXTURE_FOCUS` opens the keyboard, which simctl cannot tap.
            if ProcessInfo.processInfo.environment["MSGBLAST_FIXTURE_FOCUS"] != nil { fieldFocused = true }
            if ProcessInfo.processInfo.environment["MSGBLAST_FIXTURE_RECIPIENTS"] != nil { fieldFocused = true; recipientsOpen = true }
            #endif
        }
        .onChange(of: recipients) { _, _ in text = app.store.draft(draftKey); attachments = []; prepare() }
        .onChange(of: text) { _, value in app.store.setDraft(value, for: draftKey) }
        // A refused prepare runs again once the agents it named can accept a send.
        .onChange(of: presenter.readiness(agentIDs: recipients)) { _, _ in
            if !preparing && presenter.shouldRetryPrepare(prepareReasons: prepareReasons, agentIDs: recipients) { prepare() }
        }
        .onChange(of: photo) { _, item in if let item { Task { await upload(item) } } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { Task { await upload(url) } }
        }
        .fullScreenCover(isPresented: $capturing) {
            CameraPicker { image in
                capturing = false
                guard let image, let data = image.jpegData(compressionQuality: 0.9) else { return }
                Task { await upload(data, name: CameraPicker.filename()) }
            }
            .ignoresSafeArea()
        }
    }

    private var hasContent: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }
    /// "Message" for a group, "Message Muse" for one agent.
    private var placeholder: String { presenter.placeholder(recipients: recipients) }

    private struct Status {
        var text: String
        var detail: String?
        var symbol: String?
        /// Orange: Send is disabled until this changes.
        var blocks = false
        var retry = false
        var progress = false
    }

    /// At most one line: block > preparing > the last result > launch note.
    private var status: Status? {
        // With nobody chosen, Send is simply disabled; there is nothing to explain.
        if recipients.isEmpty { return nil }
        if let block {
            // Quiet for a passing state (checking, handling a request); orange only to fix something.
            if !block.warns { return Status(text: block.text, detail: block.detail, progress: true) }
            return Status(text: block.text, detail: block.detail, symbol: block.allowsSend ? "exclamationmark.circle" : "exclamationmark.triangle.fill",
                          blocks: !block.allowsSend, retry: block.allowsSend)
        }
        if preparing { return Status(text: "Getting ready…", progress: true) }
        if let message { return Status(text: message, progress: uploading) }
        // A launch note matters only once there is something to send.
        let drafting = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
        let notes = drafting ? presenter.launchNotes(agentIDs: recipients) : []
        if notes.count == 1 { return Status(text: notes[0], symbol: "macwindow") }
        if notes.count > 1 { return Status(text: "Opens \(notes.count) apps on your Mac", detail: notes.joined(separator: "\n"), symbol: "macwindow") }
        return nil
    }

    private func statusLine(_ status: Status) -> some View {
        // A line too long to read at a glance shows its start; ⓘ has the rest.
        let long = status.text.count > 44
        let detail = status.detail ?? (long ? status.text : nil)
        return HStack(spacing: Space.tight) {
            if status.progress { ProgressView().controlSize(.mini) }
            else if let symbol = status.symbol { Image(systemName: symbol) }
            // Wraps at accessibility sizes rather than cutting the meaning.
            Text(status.text).lineLimit(typeSize.isAccessibilitySize ? 3 : 1).truncationMode(.tail)
            if let detail { DetailButton(detail: detail) }
            Spacer(minLength: 0)
            if status.retry { Button("Try Again") { prepare() }.buttonStyle(.borderless).disabled(preparing || sending) }
        }
        .font(.caption)
        .foregroundStyle(status.blocks ? Color.orange : Color.secondary)
    }

    /// Tells the Mac which agents are coming so their pages are ready before Send.
    private func prepare() { Task { await runPrepare() } }

    private enum PrepareAnswer: Sendable { case result(RemoteCommandResult), lost, timedOut }

    /// Returns false when the Mac refused or did not answer; the reason stays on screen with
    /// Try Again until the next try. Only website agents need preparing (Messages contacts,
    /// Mac apps and CLIs do not). A newer prepare makes this one's answer irrelevant.
    @discardableResult
    private func runPrepare() async -> Bool {
        prepareGeneration += 1
        let generation = prepareGeneration
        prepareReasons = [:]
        guard app.connection.state.canSend, !recipients.isEmpty, presenter.disabledReason(agentIDs: recipients, conversation: conversationID) == nil else {
            preparing = false
            return true
        }
        let needs = recipients.filter { app.store.projection.agents[$0]?.form == .website }
        guard !needs.isEmpty else { preparing = false; return true }
        preparing = true
        let action = RemoteAction.prepareConversation(conversationID: conversationID, agentIDs: needs)
        // Whichever comes first: the Mac's answer or the phone's own deadline.
        let (answers, race) = AsyncStream<PrepareAnswer>.makeStream()
        let app = app
        Task { @MainActor in
            do { race.yield(.result(try await app.perform(action))) } catch { race.yield(.lost) }
        }
        Task {
            try? await Task.sleep(for: Self.prepareTimeout)
            race.yield(.timedOut)
        }
        var first = answers.makeAsyncIterator()
        let answer = await first.next() ?? .lost
        race.finish()
        guard generation == prepareGeneration else { return false }
        preparing = false
        switch answer {
        case .result(let result) where result.outcome == .rejected:
            prepareReasons = result.agentReasons.isEmpty ? ["": result.message ?? "Not ready"] : result.agentReasons
            return false
        case .timedOut:
            prepareReasons = ["": "Mac did not answer"]
            return false
        case .result, .lost:
            // A lost connection shows in the bar's connection line; Send decides then.
            return true
        }
    }

    private func send() {
        dictation.stop()
        guard !prepareReasons.isEmpty else { submit(); return }
        // The last prepare was refused: prepare again, and send only if it now succeeds.
        sending = true
        Task {
            let ready = await runPrepare()
            sending = false
            if ready { submit() }
        }
    }

    private func submit() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments.map(\.id)
        let action = ProjectionPresenter.sendAction(conversationID: conversationID, members: conversationID == nil ? recipients : members,
                                                    recipients: recipients, text: body, attachmentIDs: files)
        sending = true
        message = nil
        Task {
            defer { sending = false }
            do {
                let result = try await app.perform(action)
                if result.outcome == .rejected { message = result.message; refusedCount += 1; return }
                sentCount += 1
                text = ""; attachments = []
                withAnimation(.snappy) { recipientsOpen = false }
                // The reply link stays on this phone; the Mac only gets a private send.
                if let quoted = replyTo.wrappedValue { app.store.recordReply(result.clientCommandID, quoting: quoted.id); replyTo.wrappedValue = nil }
                onSent(result.conversationID)
            } catch {
                // Keep the text and files: the Mac may never have received them. An unconfirmed
                // command is recorded and never resent; the user checks before sending again.
                message = (error as? LocalizedError)?.errorDescription ?? MobileConnectionError.unconfirmed.errorDescription
                refusedCount += 1
            }
        }
    }

    private func upload(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { message = "Couldn't read that photo"; return }
        let type = item.supportedContentTypes.first
        await upload(data, name: "Photo.\(type?.preferredFilenameExtension ?? "jpg")")
        photo = nil
    }
    private func upload(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { message = "Couldn't read that file"; return }
        await upload(data, name: url.lastPathComponent)
    }
    private func upload(_ data: Data, name: String) async {
        message = "Uploading…"
        uploading = true
        defer { uploading = false }
        do { attachments.append((try await app.upload(data, filename: name), name)); message = nil }
        catch { message = error.localizedDescription }
    }
}

/// The badge inside the field: the chosen agent's avatar, or a pair for everyone or a subset.
struct RecipientBadge: View {
    @ObservedObject var app: MobileApp
    var recipients: [String]
    private var presenter: ProjectionPresenter { ProjectionPresenter(state: app.store.projection, commands: app.store.commands) }
    var body: some View {
        if recipients.count == 1, let agent = recipients.first {
            AgentAvatar(app: app, agentID: agent, name: presenter.shortName(agent), size: Space.badge)
        } else {
            ZStack(alignment: .topLeading) {
                ForEach(Array(recipients.prefix(2).enumerated()), id: \.offset) { index, agent in
                    AgentAvatar(app: app, agentID: agent, name: presenter.shortName(agent), size: Space.avatarChip)
                        .background(Circle().fill(Color(.secondarySystemBackground)).padding(-1))
                        .offset(x: CGFloat(index) * Space.gap)
                }
            }
            .frame(width: Space.section, height: Space.avatarChip, alignment: .leading)
        }
    }
}

/// The agents above the field, as the Mac's agent grid shows them: each avatar with a check
/// badge on its corner. Tapping toggles with the Details sheet's rules.
struct RecipientStrip: View {
    @ObservedObject var app: MobileApp
    var members: [String]
    @Binding var selection: Set<String>
    private var presenter: ProjectionPresenter { ProjectionPresenter(state: app.store.projection, commands: app.store.commands) }
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.inset) {
                ForEach(members, id: \.self) { agent in
                    let checked = ProjectionPresenter.isChecked(agent, selection: selection)
                    Button { withAnimation(.snappy) { selection = ProjectionPresenter.toggling(agent, selection: selection, members: members) } } label: {
                        AgentAvatar(app: app, agentID: agent, name: presenter.shortName(agent), size: Space.avatarRow)
                            .opacity(checked ? 1 : 0.6)
                            .overlay(alignment: .bottomTrailing) { CheckBadge(checked: checked).offset(x: Space.tight, y: Space.tight) }
                            .padding(Space.tight)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(presenter.shortName(agent)), \(checked ? "selected" : "not selected")")
                    .accessibilityAddTraits(checked ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.vertical, Space.tight)
        }
    }
}

/// The Mac agent grid's check: filled tint with a white checkmark, or a hollow circle.
struct CheckBadge: View {
    var checked: Bool
    var body: some View {
        ZStack {
            Circle().fill(checked ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.systemBackground)))
            if checked {
                Image(systemName: "checkmark").font(.system(size: Space.badge * 0.5, weight: .bold)).foregroundStyle(.white)
            } else {
                Circle().strokeBorder(Color.secondary, lineWidth: 1.5)
            }
        }
        .frame(width: Space.badge, height: Space.badge)
        .background(Circle().fill(Color(.systemBackground)).padding(-Space.hairline))
        .accessibilityHidden(true)
    }
}

/// The system camera, photos only, rear camera, no editing. Device-only: the simulator has none.
struct CameraPicker: UIViewControllerRepresentable {
    var done: (UIImage?) -> Void
    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }
    /// "Photo 2026-10-30 at 01.58.jpg", as Messages names a captured photo.
    static func filename(_ date: Date = Date()) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd 'at' HH.mm"
        return "Photo \(format.string(from: date)).jpg"
    }
    func makeCoordinator() -> Coordinator { Coordinator(done: done) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = ["public.image"]
        picker.cameraCaptureMode = .photo
        picker.cameraDevice = .rear
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void
        init(done: @escaping (UIImage?) -> Void) { self.done = done }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    }
}
