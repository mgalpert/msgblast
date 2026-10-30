import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import msgblastMobileKit
import msgblastRemoteProtocol

/// Recipient chips (all members = shared, one = private), a per-device draft, attachments
/// for Messages agents, and at most one status line: what blocks Send, then preparing,
/// then the last result, then a launch note. A longer Mac reason is behind ⓘ.
struct ComposeBar: View {
    @ObservedObject var app: MobileApp
    let conversationID: UUID?
    @Binding var recipients: [String]
    var onSent: (UUID?) -> Void
    @State private var text = ""
    @State private var preparing = false
    @State private var prepareReasons: [String: String] = [:]
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

    private var presenter: ProjectionPresenter { ProjectionPresenter(state: app.store.projection, commands: app.store.commands) }
    private var members: [String] { conversationID.flatMap { app.store.projection.conversations[$0]?.agentIDs } ?? [] }
    private var draftKey: String { MobileStore.draftKey(conversation: conversationID, agentID: recipients.count == 1 && conversationID != nil ? recipients[0] : nil) }
    private var onlyMessages: Bool { !recipients.isEmpty && recipients.allSatisfy { app.store.projection.agents[$0]?.form == .messages } }
    private var block: ComposeBlock? {
        presenter.composeBlock(canSend: app.connection.state.canSend, connectionText: app.connection.state == .macLocked ? app.connection.state.statusText : "Not connected",
                               agentIDs: recipients, conversation: conversationID, prepareReasons: prepareReasons)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.gap) {
            if conversationID != nil && members.count > 1 {
                // Recipients wrap like Mail's, with the summary always the last item.
                FlowLayout(spacing: Space.gap) {
                    ForEach(members, id: \.self) { id in
                        let on = recipients.contains(id)
                        Button { if on { recipients.removeAll { $0 == id } } else { recipients.append(id) } } label: {
                            HStack(spacing: Space.tight) {
                                AgentAvatar(app: app, agentID: id, name: presenter.shortName(id), size: Space.avatarChip)
                                Text(presenter.shortName(id)).font(.subheadline)
                                    .foregroundStyle(on ? Color.primary : Color.secondary)
                            }
                            .padding(.leading, Space.tight).padding(.trailing, Space.gap).padding(.vertical, Space.tight)
                            .opacity(on ? 1 : 0.6)
                        }
                        .buttonStyle(.plain)
                        // Liquid Glass chips; a chosen recipient takes the accent tint.
                        .glassEffect(on ? .regular.tint(Color.accentColor.opacity(0.35)).interactive() : .regular.interactive(), in: .capsule)
                        .accessibilityValue(on ? "Selected" : "Not selected")
                    }
                    Text(presenter.recipientSummary(recipients, members: members)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let status { statusLine(status) }
            if !attachments.isEmpty {
                ScrollView(.horizontal) { HStack { ForEach(attachments, id: \.id) { Label($0.name, systemImage: "paperclip").font(.caption) } } }
            }
            HStack(alignment: .bottom, spacing: Space.gap) {
                if onlyMessages {
                    Menu {
                        PhotosPicker(selection: $photo, matching: .images) { Label("Photo", systemImage: "photo") }
                        Button { importing = true } label: { Label("File", systemImage: "doc") }
                    } label: {
                        Image(systemName: "plus").font(.body.weight(.semibold))
                            .frame(width: Space.fieldButton, height: Space.fieldButton)
                    }
                    .buttonStyle(.glass).buttonBorderShape(.circle)
                    .padding(.bottom, (Space.fieldHeight - Space.fieldButton) / 2)
                    .accessibilityLabel("Add Photo or File")
                }
                // Messages on iOS 26: a glass capsule, text inset 12 × 8, growing to five lines,
                // with Send inside its trailing edge once there is something to send.
                HStack(alignment: .bottom, spacing: Space.tight) {
                    TextField(placeholder, text: $text, axis: .vertical)
                        .lineLimit(1...5)
                        .padding(.horizontal, Space.inset).padding(.vertical, Space.gap)
                    if hasContent {
                        Button { send() } label: {
                            Image(systemName: "arrow.up").font(.subheadline.weight(.bold))
                                .frame(width: Space.fieldButton, height: Space.fieldButton)
                        }
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.circle)
                        .disabled(sending || preparing || block?.allowsSend == false)
                        .accessibilityLabel("Send")
                        .padding(.trailing, (Space.fieldHeight - Space.fieldButton) / 2)
                        .padding(.bottom, (Space.fieldHeight - Space.fieldButton) / 2)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(minHeight: Space.fieldHeight)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Space.fieldHeight / 2))
                .animation(.snappy(duration: 0.2), value: hasContent)
            }
        }
        .padding(.horizontal, Space.screen).padding(.vertical, Space.gap)
        .background(.bar)
        .sensoryFeedback(.success, trigger: sentCount)
        .sensoryFeedback(.error, trigger: refusedCount)
        .onAppear { text = app.store.draft(draftKey); prepare() }
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
    }

    private var hasContent: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }
    /// "Message" for a group, "Message Muse" for one agent.
    private var placeholder: String { recipients.count == 1 ? "Message \(presenter.shortName(recipients[0]))" : "Message" }

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

    /// Returns false when the Mac refused; the reason stays on screen until the next try.
    @discardableResult
    private func runPrepare() async -> Bool {
        prepareReasons = [:]
        guard app.connection.state.canSend, !recipients.isEmpty, presenter.disabledReason(agentIDs: recipients, conversation: conversationID) == nil else { return true }
        let needs = recipients.filter { app.store.projection.agents[$0]?.form == .website }
        guard !needs.isEmpty else { return true }
        preparing = true
        defer { preparing = false }
        guard let result = try? await app.perform(.prepareConversation(conversationID: conversationID, agentIDs: recipients)) else { return true }
        if result.outcome == .rejected {
            prepareReasons = result.agentReasons.isEmpty ? ["": result.message ?? "Not ready"] : result.agentReasons
            return false
        }
        return true
    }

    private func send() {
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
        let action: RemoteAction
        if let conversationID {
            if recipients.count == 1 && members.count > 1 { action = .sendPrivate(conversationID: conversationID, agentID: recipients[0], text: body, attachmentIDs: files) }
            else if Set(recipients) == Set(members) { action = .sendShared(conversationID: conversationID, text: body, agentIDs: [], attachmentIDs: files) }
            else { action = .sendShared(conversationID: conversationID, text: body, agentIDs: recipients, attachmentIDs: files) }
        } else if recipients.count == 1 {
            action = .sendPrivate(conversationID: nil, agentID: recipients[0], text: body, attachmentIDs: files)
        } else {
            action = .createConversation(text: body, agentIDs: recipients, attachmentIDs: files)
        }
        sending = true
        message = nil
        Task {
            defer { sending = false }
            do {
                let result = try await app.perform(action)
                if result.outcome == .rejected { message = result.message; refusedCount += 1; return }
                sentCount += 1
                text = ""; attachments = []
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

/// Lays out subviews left to right, wrapping onto new lines; each line is centered vertically.
struct FlowLayout: Layout {
    var spacing: CGFloat = Space.gap

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            if !rows[rows.count - 1].indices.isEmpty && rows[rows.count - 1].width + spacing + size.width > width { rows.append(Row()) }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + min(size.width, width)
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
