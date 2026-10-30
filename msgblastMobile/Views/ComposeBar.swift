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
        VStack(alignment: .leading, spacing: 6) {
            if conversationID != nil && members.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(members, id: \.self) { id in
                            let on = recipients.contains(id)
                            Button(presenter.shortName(id)) { if on { recipients.removeAll { $0 == id } } else { recipients.append(id) } }
                                .buttonStyle(.bordered).controlSize(.small).tint(on ? .accentColor : .secondary)
                                .accessibilityValue(on ? "Selected" : "Not selected")
                        }
                        Text(presenter.recipientSummary(recipients, members: members)).font(.caption).foregroundStyle(.secondary).padding(.leading, 4)
                    }
                }
            }
            if let status { statusLine(status) }
            if !attachments.isEmpty {
                ScrollView(.horizontal) { HStack { ForEach(attachments, id: \.id) { Label($0.name, systemImage: "paperclip").font(.caption) } } }
            }
            HStack(alignment: .bottom, spacing: 8) {
                if onlyMessages {
                    Menu {
                        PhotosPicker(selection: $photo, matching: .images) { Label("Photo", systemImage: "photo") }
                        Button { importing = true } label: { Label("File", systemImage: "doc") }
                    } label: { Image(systemName: "plus.circle").font(.title2) }
                }
                TextField("Message", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .padding(8).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                    .disabled(sending || preparing || block?.allowsSend == false || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty))
                    .accessibilityLabel("Send")
            }
        }
        .padding(10)
        .background(.bar)
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
        return HStack(spacing: 6) {
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
        .padding(.horizontal, 4)
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
                if result.outcome == .rejected { message = result.message; return }
                text = ""; attachments = []
                onSent(result.conversationID)
            } catch {
                // Keep the text and files: the Mac may never have received them. An unconfirmed
                // command is recorded and never resent; the user checks before sending again.
                message = (error as? LocalizedError)?.errorDescription ?? MobileConnectionError.unconfirmed.errorDescription
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
