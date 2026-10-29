import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import msgblastMobileKit
import msgblastRemoteProtocol

/// Recipient chips (all members = shared, one = private), a per-device draft, attachments
/// for Messages agents, the Mac's reason when a send is not possible, and launch notes.
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

    private var presenter: ProjectionPresenter { ProjectionPresenter(state: app.store.projection, commands: app.store.commands) }
    private var members: [String] { conversationID.flatMap { app.store.projection.conversations[$0]?.agentIDs } ?? [] }
    private var draftKey: String { MobileStore.draftKey(conversation: conversationID, agentID: recipients.count == 1 && conversationID != nil ? recipients[0] : nil) }
    private var onlyMessages: Bool { !recipients.isEmpty && recipients.allSatisfy { app.store.projection.agents[$0]?.form == .messages } }
    private var block: ComposeBlock? {
        presenter.composeBlock(canSend: app.connection.state.canSend, connectionText: app.connection.state.bannerText,
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
                                .buttonStyle(.bordered).tint(on ? .accentColor : .secondary)
                                .accessibilityValue(on ? "Selected" : "Not selected")
                        }
                    }
                }
                Text(recipients.count == members.count ? "Shared with everyone" : recipients.count == 1 ? "Private to \(presenter.shortName(recipients[0]))" : "Shared with \(recipients.count) agents")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if preparing { Label("Getting ready…", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary) }
            ForEach(presenter.launchNotes(agentIDs: recipients), id: \.self) { Label($0, systemImage: "macwindow").font(.caption).foregroundStyle(.secondary) }
            if let block {
                HStack(alignment: .firstTextBaseline) {
                    Label(block.text, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                    if block.allowsSend { Button("Try again") { prepare() }.font(.caption).disabled(preparing || sending) }
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
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
        guard let data = try? await item.loadTransferable(type: Data.self) else { message = "That photo could not be read."; return }
        let type = item.supportedContentTypes.first
        await upload(data, name: "Photo.\(type?.preferredFilenameExtension ?? "jpg")")
        photo = nil
    }
    private func upload(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { message = "That file could not be read."; return }
        await upload(data, name: url.lastPathComponent)
    }
    private func upload(_ data: Data, name: String) async {
        message = "Uploading \(name)…"
        do { attachments.append((try await app.upload(data, filename: name), name)); message = nil }
        catch { message = error.localizedDescription }
    }
}
