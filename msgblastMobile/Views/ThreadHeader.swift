import SwiftUI
import UniformTypeIdentifiers
import msgblastMobileKit
import msgblastRemoteProtocol

/// Messages' thread header, which is also the group's filter and recipient list. Tapping an
/// avatar adds or removes that agent, a long press keeps only it, and the unchosen dim; the
/// glass pill reads "3 Agents ›", "Claude ›", "Claude & Muse ›" or "3 of 5 ›" and opens Details.
struct ThreadHeader: View {
    @ObservedObject var app: MobileApp
    var agentIDs: [String]
    @Binding var selection: Set<String>
    var open: () -> Void
    private var presenter: ProjectionPresenter { ProjectionPresenter(state: app.store.projection, commands: app.store.commands) }

    var body: some View {
        VStack(spacing: Space.hairline) {
            if agentIDs.count == 1 {
                Button(action: open) { AgentAvatar(app: app, agentID: agentIDs[0], name: presenter.shortName(agentIDs[0]), size: Space.avatarHeaderDirect) }
                    .buttonStyle(PressScale()).accessibilityHidden(true)
            } else {
                cluster
            }
            Button(action: open) {
                HStack(spacing: Space.hairline) {
                    Text(title).lineLimit(1)
                    Image(systemName: "chevron.forward").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, Space.gap).padding(.vertical, Space.hairline)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
            .contextMenu {
                if agentIDs.count > 1 && !app.unsupportedActions.contains("renameConversation") {
                    Button("Rename", systemImage: "pencil") { open() }
                }
            }
            .accessibilityLabel("\(title), details")
            ConnectionCaption(app: app)
        }
    }

    private var title: String {
        if agentIDs.count == 1 { return presenter.name(agentIDs[0]) }
        return presenter.selectionTitle(selection, members: agentIDs)
    }

    /// Adds or removes an agent; choosing everyone, or no one, is All.
    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        if selection.count == agentIDs.count { selection = [] }
    }

    /// Up to three 36 pt avatars overlapping by 8 pt in 2 pt rings, then "+N". Each has a
    /// 44 pt hit target; where targets overlap, the one drawn in front takes the tap.
    private var cluster: some View {
        let ringed = Space.avatarHeader + 2 * Space.hairline
        return HStack(spacing: ringed - Space.gap - Space.control) {
            ForEach(Array(agentIDs.prefix(3).enumerated()), id: \.offset) { index, id in
                ClusterAvatar(app: app, agentID: id, name: presenter.shortName(id), chosen: selection.contains(id),
                              dimmed: !selection.isEmpty && !selection.contains(id),
                              toggle: { withAnimation(.snappy) { toggle(id) } },
                              only: { withAnimation(.snappy) { selection = [id] } })
                .zIndex(selection.contains(id) ? 10 : Double(3 - index))
            }
            if agentIDs.count > 3 {
                Button(action: open) {
                    Text("+\(agentIDs.count - 3)").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: Space.avatarHeader, height: Space.avatarHeader)
                        .background(Circle().fill(Color(.tertiarySystemFill)))
                        .padding(Space.hairline)
                        .background(Circle().fill(Color(.systemBackground)))
                        .frame(width: Space.control, height: Space.control)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScale())
                .accessibilityLabel("\(agentIDs.count - 3) more agents, details")
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// One avatar in the header cluster: a button that shows only that agent, or all again.
struct ClusterAvatar: View {
    @ObservedObject var app: MobileApp
    var agentID: String
    var name: String
    var chosen: Bool
    var dimmed: Bool
    var toggle: () -> Void
    var only: () -> Void
    var body: some View {
        Button(action: toggle) {
            AgentAvatar(app: app, agentID: agentID, name: name, size: Space.avatarHeader)
                .padding(Space.hairline)
                .background(Circle().fill(Color(.systemBackground)))
                .opacity(dimmed ? 0.4 : 1)
                .frame(width: Space.control, height: Space.control)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in only() })
        .accessibilityLabel(name)
        .accessibilityHint(chosen ? "Removes from the selection" : "Adds to the selection")
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Show Only") { only() }
    }
}

/// A subtle scale-down while pressed, so a tap on a header avatar registers visibly.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// The Mac's connection state as one caption; nothing while connected.
struct ConnectionCaption: View {
    @ObservedObject var app: MobileApp
    @State private var now = Date()
    var body: some View {
        let state = app.store.projection.macLocked && app.connection.state.canSend ? MacConnectionState.macLocked : app.connection.state
        Group {
            if let text = state.navigationSubtitle(lastHeard: app.connection.lastHeard, reconnectingSince: app.connection.reconnectingSince, now: now) {
                Text(text).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                now = Date()
            }
        }
    }
}

/// The thread's Details sheet: each agent with its form and short status, a report request,
/// and End Conversation with the existing confirmation.
struct ThreadDetailsSheet: View {
    @ObservedObject var app: MobileApp
    let conversationID: UUID
    @Binding var selection: Set<String>
    var run: (RemoteAction) -> Void
    @State private var confirmEnd = false
    /// The Name field: its text, a rename in flight, and the Mac's reason if it refused.
    @State private var name = ""
    @State private var renaming = false
    @State private var renameError: String?
    @State private var opening: SharedOpen?
    @State private var detent: PresentationDetent = .medium
    @Environment(\.dismiss) private var dismiss
    private var presenter: ProjectionPresenter { ProjectionPresenter(state: app.store.projection, commands: app.store.commands) }

    /// Photos, Links and Documents shared in the conversation; each hides when empty.
    @ViewBuilder private var sharedSections: some View {
        let shared = presenter.sharedContent(in: conversationID)
        if !shared.photos.isEmpty {
            Section("Photos") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.tight), count: 3), spacing: Space.tight) {
                    ForEach(shared.photos) { file in
                        Button { opening = .photo(file) } label: {
                            Color.clear.aspectRatio(1, contentMode: .fit)
                                .overlay { AttachmentThumbnail(app: app, file: file) }
                                .clipShape(RoundedRectangle(cornerRadius: Space.tight, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowInsets(EdgeInsets(top: Space.gap, leading: Space.gap, bottom: Space.gap, trailing: Space.gap))
            }
        }
        if !shared.links.isEmpty {
            Section("Links") {
                ForEach(shared.links) { link in
                    Button { opening = .link(link.url) } label: {
                        HStack(spacing: Space.inset) {
                            senderAvatar(link.agentID)
                            VStack(alignment: .leading, spacing: Space.hairline) {
                                Text(link.host).foregroundStyle(.primary).lineLimit(1)
                                Text(link.context).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: Space.gap)
                            if let date = link.date { Text(ProjectionPresenter.inboxTimestamp(date)).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .buttonStyle(.plain).contentShape(Rectangle())
                }
            }
        }
        if !shared.documents.isEmpty {
            Section("Documents") {
                ForEach(shared.documents) { file in
                    Button { opening = .document(file) } label: {
                        HStack(spacing: Space.inset) {
                            Image(systemName: Self.symbol(for: file.filename)).font(.title2).foregroundStyle(.tint).frame(width: Space.avatarList)
                            VStack(alignment: .leading, spacing: Space.hairline) {
                                Text(file.filename).foregroundStyle(.primary).lineLimit(1)
                                Text([file.byteCount.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) },
                                      file.agentID.map(presenter.shortName) ?? "You",
                                      file.date.map { ProjectionPresenter.inboxTimestamp($0) }].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain).contentShape(Rectangle())
                }
            }
        }
    }

    private func senderAvatar(_ agentID: String?) -> some View {
        Group {
            if let agentID { AgentAvatar(app: app, agentID: agentID, name: presenter.shortName(agentID), size: Space.avatarList) }
            else { Image(systemName: "link").frame(width: Space.avatarList, height: Space.avatarList).background(Circle().fill(Color(.tertiarySystemFill))) }
        }
    }

    static func symbol(for filename: String) -> String {
        let type = UTType(filenameExtension: (filename as NSString).pathExtension)
        if type?.conforms(to: .pdf) == true { return "doc.richtext" }
        if type?.conforms(to: .audio) == true { return "waveform" }
        if type?.conforms(to: .movie) == true { return "film" }
        return "doc"
    }

    /// Sends the new name; the title updates when the Mac's projection does.
    private func rename(_ conversation: RemoteConversation) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title != conversation.title else { return }
        renaming = true
        renameError = nil
        Task {
            defer { renaming = false }
            do {
                let result = try await app.perform(.renameConversation(conversationID: conversationID, title: title))
                if result.outcome == .rejected {
                    if result.code == .unsupported { app.unsupportedActions.insert("renameConversation") }
                    renameError = result.message
                }
            } catch { renameError = (error as? LocalizedError)?.errorDescription }
        }
    }

    var body: some View {
        NavigationStack {
            if let conversation = app.store.projection.conversations[conversationID] {
                List {
                    if conversation.agentIDs.count > 1 && !app.unsupportedActions.contains("renameConversation") {
                        Section {
                            HStack(spacing: Space.gap) {
                                TextField("Name", text: $name)
                                    .submitLabel(.done)
                                    .onSubmit { rename(conversation) }
                                    .disabled(renaming)
                                if renaming { ProgressView() }
                                else if name.trimmingCharacters(in: .whitespacesAndNewlines) != conversation.title {
                                    Button("Done") { rename(conversation) }.buttonStyle(.borderless).bold()
                                }
                            }
                        } header: { Text("Name") } footer: {
                            if let renameError { Text(renameError).foregroundStyle(.red) }
                        }
                    }
                    if !selection.isEmpty && conversation.agentIDs.count > 1 {
                        Section { Button("Show All", systemImage: "person.3") { selection = [] } }
                    }
                    Section {
                        ForEach(conversation.agentIDs, id: \.self) { id in
                            HStack(spacing: Space.inset) {
                                AgentAvatar(app: app, agentID: id, name: presenter.shortName(id), size: Space.avatarRow)
                                VStack(alignment: .leading, spacing: Space.hairline) {
                                    Text(presenter.shortName(id))
                                    if let agent = app.store.projection.agents[id] {
                                        Text([ProjectionPresenter.formLabel(agent.form), ProjectionPresenter.agentStatus(agent) ?? "Ready"].joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: Space.gap)
                                if conversation.agentIDs.count > 1 {
                                    // All means everyone: every row is checked until a subset is chosen.
                                    let checked = ProjectionPresenter.isChecked(id, selection: selection)
                                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(checked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                                        .font(.title3)
                                }
                            }
                            .listRowInsets(Space.row)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard conversation.agentIDs.count > 1 else { return }
                                selection = ProjectionPresenter.toggling(id, selection: selection, members: conversation.agentIDs)
                            }
                            .accessibilityAddTraits(ProjectionPresenter.isChecked(id, selection: selection) ? [.isButton, .isSelected] : .isButton)
                        }
                    }
                    sharedSections
                    Section {
                        Button("Request Report", systemImage: "doc.text.magnifyingglass") { run(.requestReport(conversationID: conversationID)); dismiss() }
                    }
                    if conversation.endedAt == nil {
                        Section {
                            Button("End Conversation", systemImage: "xmark.circle", role: .destructive) { confirmEnd = true }
                        }
                    }
                }
                .navigationTitle(conversation.agentIDs.count == 1 ? presenter.name(conversation.agentIDs[0]) : conversation.title)
                .onAppear { if name.isEmpty { name = conversation.title } }
                .sharedContentPresentation(app, opening: $opening)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { dismiss() } }
                .confirmationDialog(conversation.canEnd ? "End This Conversation?" : "Can't End Yet", isPresented: $confirmEnd, titleVisibility: .visible) {
                    if conversation.canEnd {
                        Button("End Conversation", role: .destructive) { run(.endConversation(conversationID: conversationID)); dismiss() }
                        Button("Keep Active", role: .cancel) {}
                    } else {
                        Button("OK", role: .cancel) {}
                    }
                } message: {
                    Text(conversation.canEnd ? "Later replies won't be added" : "Open it on your Mac first so its history loads")
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        #if DEBUG
        // Design review: `MSGBLAST_FIXTURE_DETAILS=large` opens the sheet full height.
        .onAppear { if ProcessInfo.processInfo.environment["MSGBLAST_FIXTURE_DETAILS"] == "large" { detent = .large } }
        #endif
    }
}
