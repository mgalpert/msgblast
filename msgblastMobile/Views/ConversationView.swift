import SwiftUI
import msgblastMobileKit
import msgblastRemoteProtocol

struct ConversationView: View {
    @ObservedObject var app: MobileApp
    let conversationID: UUID
    /// The keyboard stays up when a new conversation becomes this thread.
    var startFocused = false
    /// The header cluster's selection, both the thread's filter and its recipients: empty is
    /// All, one agent is that agent's private thread, several are their union.
    @State private var selection: Set<String> = []
    @State private var actionError: String?
    @State private var showingDetails = false
    /// The pinned prompt row: whether the prompt's own bubble is visible, and expanded text.
    @State private var pinnedFrame: CGRect?
    /// The visible part of the thread in content coordinates, below the navigation bar.
    @State private var visibleSpan: ClosedRange<CGFloat> = 0...0
    @State private var pinnedRowHeight: CGFloat = 0
    /// The prompt's text is fully on screen (measured as if the pinned row were not there,
    /// so showing the row never hides the prompt it stands for).
    private var pinnedOnScreen: Bool {
        guard let frame = pinnedFrame else { return false }
        let top = visibleSpan.lowerBound - (showsPinnedRow ? pinnedRowHeight : 0)
        // The whole text must be in view: a prompt half under the bar still needs the row.
        return frame.minY >= top && frame.minY < visibleSpan.upperBound
    }
    @State private var showsPinnedRow = false
    @State private var pinnedExpanded = false
    /// Reply mode: the response being replied to, and the selection to restore after.
    @State private var replyTo: RemoteTurn?
    @State private var savedSelection: Set<String>?
    @State private var focusRequest = 0
    @State private var scrollTarget: String?
    /// A link, photo or document being opened from the thread.
    @State private var opening: SharedOpen?
    @State private var details: IncompleteSummary?
    /// Your messages whose full chip row was revealed by a tap, as Messages reveals times.
    @State private var expanded: Set<String> = []
    /// The scroll view's width, for the 78 percent bubble limit.
    /// Starts at a phone's width until the first layout measures it.
    @State private var width: CGFloat = 390
    /// The visible height between the navigation bar and the compose bar.
    @State private var visibleHeight: CGFloat = 0
    /// Within 40 pt of the newest message; only then does the thread follow new content.
    @State private var atBottom = true
    @State private var openedAtBottom = false

    private var presenter: ProjectionPresenter { ProjectionPresenter(state: app.store.projection, commands: app.store.commands) }
    private var conversation: RemoteConversation? { app.store.projection.conversations[conversationID] }
    private var replyPresenter: ProjectionPresenter {
        ProjectionPresenter(state: app.store.projection, commands: app.store.commands, replyTo: app.store.replyTo)
    }

    var body: some View {
        if let conversation {
            content(conversation)
        } else {
            ContentUnavailableView("Not on Your Mac", systemImage: "questionmark.bubble")
        }
    }

    private func content(_ conversation: RemoteConversation) -> some View {
        let turns = presenter.turns(in: conversationID, selection: selection)
        let pinned = presenter.pinnedPrompt(for: conversationID, selection: selection)
        return ScrollViewReader { proxy in
            ScrollView {
                // Messages anchors the thread to the bottom: a short thread sits just above the
                // compose bar (the spacer takes the slack), a long one scrolls as usual.
                VStack(alignment: .leading, spacing: 0) {
                    // A submitted request shows as typing below; the row is for Stop or review.
                    ForEach(conversation.incompleteAttempts.filter { ![.waiting, .submitted].contains(app.store.projection.attempts[$0.attemptID]?.status) }, id: \.attemptID) { incomplete in
                        incompleteRow(incomplete).padding(.bottom, Space.gap).padding(.horizontal, Space.screen)
                    }
                    Spacer(minLength: 0)
                // Messages' rhythm: a sender's run is 2 pt apart and ends in a tail, runs (and
                // anything after a status row) are 8 pt apart, and a time header has 12 pt
                // above and below. Rows set their own edges: bubbles sit 16 pt from the screen,
                // a group's incoming avatar 8 pt.
                LazyVStack(alignment: .leading, spacing: 0) {
                    let latestMine = turns.last { $0.role == .user }?.id
                    let isGroup = conversation.agentIDs.count > 1 && selection.count != 1
                    ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                        let previous = index == 0 ? nil : turns[index - 1]
                        let next = index + 1 < turns.count ? turns[index + 1] : nil
                        let header = turn.created.flatMap { ProjectionPresenter.timeHeader($0, previous: previous?.created) }
                        let nextHeader = next?.created.flatMap { ProjectionPresenter.timeHeader($0, previous: turn.created) }
                        if let header {
                            Text(header).font(.scaled(Space.threadCaption, weight: .semibold, relativeTo: .caption2)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                                .padding(.top, index == 0 ? 0 : Space.separator).padding(.bottom, Space.separator)
                        }
                        let afterStatus = previous.map { $0.role == .user && !presenter.visibleChips(for: $0, selection: selection, isLatest: $0.id == latestMine, expanded: expanded.contains($0.id)).isEmpty } == true
                        let continues = header == nil && !afterStatus && previous.map { Self.sameSender($0, turn) } == true
                        let endsRun = nextHeader != nil || next.map { Self.sameSender(turn, $0) } != true
                        bubble(turn, firstOfRun: !continues, lastOfRun: endsRun, isGroup: isGroup, isLatest: turn.id == latestMine, isPinned: turn.id == pinned?.id)
                            .padding(.top, header != nil || previous == nil ? 0 : continues ? Space.run : Space.runGap)
                            .id(turn.id)
                    }
                    ForEach(presenter.typingAgents(in: conversationID, selection: selection), id: \.self) { agent in
                        TypingBubble(app: app, agentID: agent, name: presenter.shortName(agent), showsAvatar: isGroup)
                            .padding(.leading, isGroup ? Space.threadAvatarEdge : Space.screen)
                            .padding(.top, Space.runGap).id("typing-\(agent)")
                    }
                    if let actionError { Text(actionError).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity).padding(.top, Space.gap).padding(.horizontal, Space.screen) }
                    if conversation.endedAt != nil { Text("Ended").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, Space.section) }
                }
                Color.clear.frame(height: 0).id(Self.bottomID)
                }
                .padding(.vertical, Space.gap)
                .frame(minHeight: visibleHeight, alignment: .bottom)
                .coordinateSpace(.named(Self.threadSpace))
            }
            .scrollDismissesKeyboard(.interactively)
            // Groups: the prompt that formed the group, pinned while it is scrolled away, in a
            // safe-area bar so the thread fades under it like under the navigation bar.
            .safeAreaBar(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    if let pinned, showsPinnedRow {
                        PinnedPromptRow(text: pinned.text, expanded: $pinnedExpanded)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pinnedRowHeight = $0 }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: showsPinnedRow)
                .onChange(of: pinned != nil && !pinnedOnScreen, initial: true) { _, value in showsPinnedRow = value }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onScrollGeometryChange(for: ThreadGeometry.self) { geometry in
                // `containerSize` is the area between the bars; `visibleRect` spans the insets too,
                // so the distance to the end counts the bottom inset. The navigation bar's inset
                // arrives last, so the first settled pass is the one that decides the opening.
                ThreadGeometry(visible: geometry.containerSize.height, content: geometry.contentSize.height,
                               distanceFromBottom: geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY,
                               settled: geometry.contentInsets.top > 0,
                               visibleTop: geometry.visibleRect.minY + geometry.contentInsets.top,
                               visibleBottom: geometry.visibleRect.maxY - geometry.contentInsets.bottom)
            } action: { old, new in
                visibleHeight = max(0, new.visible)
                visibleSpan = new.visibleTop...max(new.visibleTop, new.visibleBottom)
                guard new.settled else { return }
                // Open on the newest message: a short thread is already bottom-aligned by the
                // spacer; a long one scrolls to its end once.
                if !openedAtBottom {
                    openedAtBottom = true
                    atBottom = true
                    if new.content > new.visible + 1 { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    return
                }
                // Rows measured late (the list is lazy) grew the thread: stay on the newest one.
                if old.content != new.content, atBottom {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    return
                }
                // The keyboard or the compose bar changed the visible height: keep the newest
                // message in view, but only if the reader was already there.
                if old.visible != new.visible, atBottom {
                    withAnimation(.snappy) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    return
                }
                atBottom = new.distanceFromBottom <= 40
            }
            .onChange(of: turns.last?.id) { _, _ in
                if atBottom { withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) } }
                app.store.markOpened(conversationID)
            }
            .onChange(of: scrollTarget) { _, id in
                guard let id else { return }
                withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
                scrollTarget = nil
            }
            .onChange(of: presenter.typingAgents(in: conversationID, selection: selection)) { _, _ in
                if atBottom { withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) } }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if conversation.endedAt == nil {
                ComposeBar(app: app, conversationID: conversationID,
                           recipients: .constant(ProjectionPresenter.recipients(selection: selection, members: conversation.agentIDs)), replyTo: $replyTo,
                           selection: conversation.agentIDs.count > 1 ? $selection : nil, focusRequest: focusRequest, onSent: { _ in })
            }
        }
        .navigationTitle(conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            app.store.markOpened(conversationID)
            if startFocused { focusRequest += 1 }
            #if DEBUG
            // Design review: `MSGBLAST_FIXTURE_DETAILS` opens the Details sheet.
            if ProcessInfo.processInfo.environment["MSGBLAST_FIXTURE_DETAILS"] != nil { showingDetails = true }
            // `MSGBLAST_FIXTURE_REPLY` starts a reply to the first Claude response;
            // `MSGBLAST_FIXTURE_FILTER=<id>,<id>` selects agents in the header.
            if ProcessInfo.processInfo.environment["MSGBLAST_FIXTURE_REPLY"] != nil {
                replyTo = presenter.turns(in: conversationID, agentID: nil).first { $0.role == .assistant && $0.agentID == "claude" }
            }
            // `MSGBLAST_FIXTURE_PHOTO` opens the first shared photo in the viewer.
            if ProcessInfo.processInfo.environment["MSGBLAST_FIXTURE_PHOTO"] != nil, let first = presenter.sharedContent(in: conversationID).photos.first {
                opening = .photo(first)
            }
            if let agents = ProcessInfo.processInfo.environment["MSGBLAST_FIXTURE_FILTER"] { selection = Set(agents.split(separator: ",").map(String.init)) }
            #endif
        }
        // Reply mode narrows the selection to that agent and restores it after.
        .onChange(of: replyTo) { old, value in
            if let agent = value?.agentID {
                if old == nil { savedSelection = selection }
                selection = [agent]
                focusRequest += 1
            } else if old != nil {
                selection = savedSelection ?? []
                savedSelection = nil
            }
        }
        .toolbar {
            // Messages' header: avatars over a pill that opens Details (agents, report, end).
            ToolbarItem(placement: .principal) {
                ThreadHeader(app: app, agentIDs: conversation.agentIDs, selection: $selection) { showingDetails = true }
            }
        }
        .sharedContentPresentation(app, opening: $opening)
        .sheet(isPresented: $showingDetails) { ThreadDetailsSheet(app: app, conversationID: conversationID, selection: $selection, run: run) }
        .sheet(item: $details) { summary in RequestDetailsSheet(summary: summary, name: presenter.name(summary.agentID)) }
    }

    private static let bottomID = "thread-bottom"
    private static let threadSpace = "thread"

    static func sameSender(_ a: RemoteTurn, _ b: RemoteTurn) -> Bool { a.role == b.role && (a.role == .user || a.agentID == b.agentID) }

    /// One bubble in Messages' layout. In a group, replies are indented past a 28 pt avatar that
    /// sits beside the last bubble of the run, and the run starts with the sender's name.
    private func bubble(_ turn: RemoteTurn, firstOfRun: Bool, lastOfRun: Bool, isGroup: Bool, isLatest: Bool, isPinned: Bool = false) -> some View {
        let mine = turn.role == .user
        let text = turn.text.isEmpty ? turn.attachments.map(\.filename).joined(separator: ", ") : turn.text
        let all = mine ? presenter.chips(for: turn, selection: selection) : []
        let notSent = all.first { $0.state == .notSent }
        let showsAvatar = isGroup && !mine
        let maxBubble = width * Space.bubbleMax
        let avatarColumn = showsAvatar ? Space.avatarThread + Space.beside : 0
        return VStack(alignment: mine ? .trailing : .leading, spacing: 0) {
            if showsAvatar && firstOfRun, let agent = turn.agentID {
                // Aligned with the bubble's text, 2 pt above the bubble.
                Text(presenter.senderLabel(agent, in: conversationID)).font(.scaled(Space.threadCaption, weight: .medium, relativeTo: .caption2)).foregroundStyle(.secondary)
                    .padding(.leading, avatarColumn + Space.bubbleH)
                    .padding(.bottom, Space.attached)
            }
            if mine, let quoted = replyPresenter.quotedTurn(for: turn), let agent = quoted.agentID {
                // The response this message replied to, as Messages shows a quote.
                Button { scrollTarget = quoted.id } label: {
                    HStack(spacing: Space.gap) {
                        RoundedRectangle(cornerRadius: 1).fill(.tint).frame(width: Space.hairline)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(presenter.shortName(agent)).font(.scaled(Space.quoteText, weight: .semibold, relativeTo: .caption2))
                            Text(quoted.text.components(separatedBy: .newlines).first ?? "").font(.scaled(Space.quoteText, relativeTo: .caption2)).lineLimit(1)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: maxBubble, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.bottom, Space.quoteGap)
                .accessibilityLabel("Reply to \(presenter.shortName(agent)): \(quoted.text)")
            }
            HStack(alignment: mine ? .center : .bottom, spacing: Space.beside) {
                if showsAvatar {
                    if lastOfRun, let agent = turn.agentID {
                        AgentAvatar(app: app, agentID: agent, name: presenter.shortName(agent), size: Space.avatarThread)
                    } else {
                        Color.clear.frame(width: Space.avatarThread, height: 1)
                    }
                }
                // Messages' Not Delivered mark sits at the bubble's leading edge.
                if let notSent { ChipView(chip: notSent, showsName: false, iconOnly: true, retry: retry(turn, notSent)) }
                if SharedContent.isEmojiOnly(text) {
                    // Messages: one to three emoji, nothing else, large and without a bubble.
                    Text(text).font(.largeTitle).textSelection(.enabled)
                        .contextMenu { emojiMenu(turn: turn, mine: mine, text: text) }
                } else {
                MaxWidth(width: maxBubble) {
                    Text(LinkedText.attributed(text, mine: mine))
                        // Where the prompt's text sits in the thread (not its photos), so the
                        // pinned row shows while the text is away. Content coordinates stay valid
                        // after the row unloads.
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.threadSpace)) } action: { frame in
                            if isPinned { pinnedFrame = frame }
                        }
                        .font(.body)
                        .textSelection(.enabled)
                        .padding(.horizontal, Space.bubbleH).padding(.vertical, Space.bubbleV)
                        .background(BubbleShape(mine: mine, tail: lastOfRun).fill(mine ? Color("Bubble") : Color(.secondarySystemBackground)))
                        .foregroundStyle(mine ? .white : .primary)
                        .contentShape(.contextMenuPreview, BubbleShape(mine: mine, tail: false))
                        .contextMenu {
                            // Replies to a response; your own messages offer Copy only, so nothing is sent twice by accident.
                            if !mine, turn.agentID != nil, app.store.projection.conversations[conversationID]?.endedAt == nil {
                                Button("Reply", systemImage: "arrowshape.turn.up.left") { replyTo = turn }
                            }
                            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
                        }
                        .onTapGesture {
                            guard mine else { return }
                            withAnimation(.snappy) { if expanded.contains(turn.id) { expanded.remove(turn.id) } else { expanded.insert(turn.id) } }
                        }
                }
                // Tapbacks overlap the top corner away from the tail: top-left on yours,
                // top-right on a reply. They are never messages of their own.
                .overlay(alignment: mine ? .topLeading : .topTrailing) {
                    if let reactions = presenter.reactionSummary(for: turn) {
                        ReactionStack(summary: reactions).offset(x: mine ? -Space.gap : Space.gap, y: -Space.inset - Space.tight)
                    }
                }
                }
            }
            if !turn.attachments.isEmpty {
                // Photos inline (up to 240 pt), other files as a row; both open on tap.
                let files = turn.attachments.enumerated().map { index, file in
                    SharedAttachment(turnID: turn.id, index: index, filename: file.filename, mimeType: file.mimeType, byteCount: file.byteCount,
                                     agentID: mine ? nil : turn.agentID, date: turn.created)
                }
                VStack(alignment: mine ? .trailing : .leading, spacing: Space.tight) {
                    ForEach(files) { file in
                        if file.isImage {
                            Button { opening = .photo(file) } label: {
                                AttachmentThumbnail(app: app, file: file)
                                    .frame(width: Space.inlinePhoto, height: Space.inlinePhoto * 3 / 4)
                                    .clipShape(RoundedRectangle(cornerRadius: Space.cornerBubble, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button { opening = .document(file) } label: {
                                Label(file.filename, systemImage: "doc").font(.caption).lineLimit(1)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .padding(.leading, avatarColumn)
                .padding(.top, Space.tight)
            }
            if mine {
                let visible = presenter.visibleChips(for: turn, selection: selection, isLatest: isLatest, expanded: expanded.contains(turn.id))
                if !visible.isEmpty {
                    StatusGlyphRow(app: app, chips: visible, retry: { chip in chip.state == .notSent ? retry(turn, chip) : nil })
                        .padding(.top, Space.attached)
                }
            }
        }
        .padding(.top, turn.reactions?.isEmpty == false ? Space.inset + Space.tight : 0)
        .padding(.leading, showsAvatar ? Space.threadAvatarEdge : Space.screen)
        .padding(.trailing, Space.screen)
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    /// The long-press menu for a large emoji message: Reply to a response, Copy.
    @ViewBuilder private func emojiMenu(turn: RemoteTurn, mine: Bool, text: String) -> some View {
        if !mine, turn.agentID != nil, app.store.projection.conversations[conversationID]?.endedAt == nil {
            Button("Reply", systemImage: "arrowshape.turn.up.left") { replyTo = turn }
        }
        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
    }

    /// Try Again for a Not sent chip: a new private send of the same text to that agent.
    /// Never offered for Unconfirmed, which may have reached the Mac.
    private func retry(_ turn: RemoteTurn, _ chip: StatusChip) -> (() -> Void)? {
        guard chip.state == .notSent, !turn.text.isEmpty, app.store.projection.conversations[conversationID]?.endedAt == nil else { return nil }
        return { run(.sendPrivate(conversationID: conversationID, agentID: chip.agentID, text: turn.text, attachmentIDs: [])) }
    }

    /// One compact row: what is happening, and the one action that fits. Tap for the Mac's full text.
    private func incompleteRow(_ incomplete: RemoteIncompleteAttempt) -> some View {
        let summary = presenter.incompleteSummary(incomplete)
        return HStack(spacing: Space.gap) {
            Button { details = summary } label: {
                HStack(spacing: Space.gap) {
                    Image(systemName: summary.running ? "hourglass" : "exclamationmark.circle")
                        .foregroundStyle(summary.running ? Color.secondary : Color.orange)
                    Text(summary.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows request details")
            if summary.running {
                Button("Stop") { run(.cancelNative(agentID: incomplete.agentID)) }.buttonStyle(.bordered).controlSize(.small)
            } else {
                Button("Dismiss") { run(.acknowledgeIncomplete(agentID: incomplete.agentID, attemptID: String(incomplete.attemptID.dropFirst("wa:".count)))) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(Space.inset)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: Space.cornerCard, style: .continuous))
    }

    private func run(_ action: RemoteAction) {
        actionError = nil
        Task {
            do {
                let result = try await app.perform(action)
                if result.outcome == .rejected { actionError = result.message }
            } catch { actionError = (error as? LocalizedError)?.errorDescription ?? MobileConnectionError.unconfirmed.errorDescription }
        }
    }
}

/// The prompt that formed a group, pinned under the tabs while its bubble is off screen.
struct PinnedPromptRow: View {
    var text: String
    @Binding var expanded: Bool
    var body: some View {
        HStack(alignment: .top, spacing: Space.gap) {
            Image(systemName: "pin.fill").font(.footnote).foregroundStyle(.tint).padding(.top, Space.hairline)
            VStack(alignment: .leading, spacing: Space.hairline) {
                Text("Prompt").font(.scaled(Space.threadCaption, weight: .semibold, relativeTo: .caption2)).foregroundStyle(.secondary)
                Text(text).font(.scaled(Space.pinnedText, relativeTo: .subheadline)).lineLimit(expanded ? nil : 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(expanded ? "Shows two lines" : "Shows the whole prompt")
        }
        .padding(.horizontal, Space.screen).padding(.vertical, Space.pinnedV)
        .background(.bar)
    }
}

/// Messages' tapback bubble: the emoji in a small rounded pill ringed in the background
/// color, with a count when more reactions were made than it shows.
struct ReactionStack: View {
    var summary: ReactionSummary
    var body: some View {
        HStack(spacing: -Space.tight) {
            ForEach(Array(summary.emoji.enumerated()), id: \.offset) { _, emoji in Text(emoji).font(.callout) }
            if let count = summary.countLabel { Text(count).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, Space.tight + Space.hairline) }
        }
        .padding(.horizontal, Space.gap).padding(.vertical, Space.tight)
        .background(Capsule().fill(Color(.secondarySystemBackground)))
        .background(Capsule().stroke(Color(.systemBackground), lineWidth: Space.hairline))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reactions: \(summary.emoji.joined(separator: " "))\(summary.countLabel.map { ", \($0) in all" } ?? "")")
    }
}

/// What the conversation tracks about its scroll view to stay anchored at the bottom.
struct ThreadGeometry: Equatable {
    var visible: CGFloat
    var content: CGFloat
    var distanceFromBottom: CGFloat
    var settled: Bool
    var visibleTop: CGFloat
    var visibleBottom: CGFloat
}

/// The Mac's full text for an unfinished request, and when it started.
struct RequestDetailsSheet: View {
    var summary: IncompleteSummary
    var name: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Agent", value: name)
                    LabeledContent("Status", value: summary.running ? "Running on your Mac" : "Needs review")
                    if let started = summary.started { LabeledContent("Started", value: started.formatted(date: .abbreviated, time: .shortened)) }
                }
                if !summary.details.isEmpty {
                    Section("From your Mac") { ForEach(summary.details, id: \.self) { Text($0).font(.callout) } }
                }
            }
            .navigationTitle("Request Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Sending → Sent → Replied / Not sent / Unconfirmed, per agent. Tap a chip for the Mac's reason.
/// Send status as glyphs on one trailing line: each agent's avatar with a small status
/// badge, no words. Tap a glyph for the agent, the state and the Mac's reason.
struct StatusGlyphRow: View {
    @ObservedObject var app: MobileApp
    var chips: [StatusChip]
    var retry: (StatusChip) -> (() -> Void)? = { _ in nil }
    var body: some View {
        HStack(spacing: Space.attached) {
            ForEach(chips) { chip in StatusGlyph(app: app, chip: chip, retry: retry(chip)) }
        }
        .frame(minHeight: Space.avatarChip)
        .fixedSize()
        // Scales with the caption, capped so the row always stays on one line.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .combine)
    }
}

struct StatusGlyph: View {
    @ObservedObject var app: MobileApp
    var chip: StatusChip
    var retry: (() -> Void)?
    @ScaledMetric(relativeTo: .caption) private var avatar: CGFloat = Space.avatarChip
    @ScaledMetric(relativeTo: .caption) private var badge: CGFloat = Space.statusBadge
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: {
            AgentAvatar(app: app, agentID: chip.agentID, name: chip.agentName, size: avatar)
                .overlay(alignment: .bottomTrailing) {
                    StatusBadge(state: chip.state, size: badge).offset(x: badge * 0.35, y: badge * 0.25)
                }
                .padding(.trailing, badge * 0.35)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(chip.agentName), \(chip.state.rawValue.lowercased())")
        .accessibilityHint("Shows details")
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: Space.gap) {
                Text(chip.agentName).font(.headline)
                Label(chip.state.rawValue, systemImage: chip.state.symbol).font(.subheadline).foregroundStyle(StatusBadge.color(chip.state))
                if let reason = chip.reason, !reason.isEmpty { Text(reason).font(.callout).fixedSize(horizontal: false, vertical: true) }
                if let retry { Button("Try Again") { showing = false; retry() }.buttonStyle(.borderedProminent).padding(.top, Space.tight) }
            }
            .frame(maxWidth: Space.popoverWidth, alignment: .leading)
            .padding(Space.screen)
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// The small badge on a status glyph: a symbol in a circle ringed with the background color.
struct StatusBadge: View {
    var state: ChipState
    var size: CGFloat
    var body: some View {
        Image(systemName: Self.symbol(state))
            .resizable().scaledToFit()
            .fontWeight(.bold)
            .foregroundStyle(Self.color(state))
            .frame(width: size, height: size)
            .background(Circle().fill(Color(.systemBackground)).padding(-Space.hairline))
    }
    static func symbol(_ state: ChipState) -> String {
        switch state {
        case .sending: "clock.fill"
        case .sent: "checkmark.circle.fill"
        case .replied: "checkmark.bubble.fill"
        case .notSent: "xmark.circle.fill"
        case .unconfirmed: "questionmark.circle.fill"
        }
    }
    static func color(_ state: ChipState) -> Color {
        switch state { case .notSent: .red; case .unconfirmed: .orange; default: .secondary }
    }
}

struct ChipView: View {
    var chip: StatusChip
    var showsName: Bool
    /// The red mark beside a bubble rather than a labeled chip.
    var iconOnly = false
    var retry: (() -> Void)? = nil
    @State private var showingReason = false
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        let label = content.font(iconOnly ? .system(size: Space.notSentMark) : .caption2).foregroundStyle(color)
        if chip.reason?.isEmpty == false || retry != nil {
            Button { showingReason = true } label: { label }
                .buttonStyle(.plain)
                .accessibilityLabel(iconOnly ? "Not sent to \(chip.agentName)" : chip.label(showsName: true))
                .accessibilityHint("Shows why")
                .popover(isPresented: $showingReason) {
                    VStack(alignment: .leading, spacing: Space.inset) {
                        if let reason = chip.reason, !reason.isEmpty { Text(reason).font(.callout).fixedSize(horizontal: false, vertical: true) }
                        else { Text("\(chip.agentName) didn't get this message").font(.callout) }
                        if let retry {
                            Button("Try Again") { showingReason = false; retry() }.buttonStyle(.borderedProminent)
                        }
                    }
                    .frame(maxWidth: Space.popoverWidth, alignment: .leading)
                    .padding(Space.screen)
                    .presentationCompactAdaptation(.popover)
                }
        } else {
            label
        }
    }
    /// One line, or at accessibility sizes the agent above its state, with no separator.
    @ViewBuilder private var content: some View {
        if iconOnly {
            Image(systemName: "exclamationmark.circle.fill")
        } else if showsName && typeSize.isAccessibilitySize {
            VStack(alignment: .trailing, spacing: 0) {
                Text(chip.agentName)
                Label(chip.state.rawValue, systemImage: chip.state.symbol)
            }
            .accessibilityElement(children: .combine)
        } else {
            Label(chip.label(showsName: showsName), systemImage: chip.state.symbol)
        }
    }
    private var color: Color {
        switch chip.state { case .notSent: .red; case .unconfirmed: .orange; default: .secondary }
    }
}

/// Messages' typing bubble: the agent's avatar and three dots that pulse in turn.
struct TypingBubble: View {
    @ObservedObject var app: MobileApp
    var agentID: String
    var name: String
    /// Groups show the 28 pt avatar beside it; direct threads show none.
    var showsAvatar = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(alignment: .bottom, spacing: Space.beside) {
            if showsAvatar { AgentAvatar(app: app, agentID: agentID, name: name, size: Space.avatarThread) }
            TimelineView(.animation(minimumInterval: 0.15, paused: reduceMotion)) { timeline in
                let phase = reduceMotion ? -1 : Int(timeline.date.timeIntervalSinceReferenceDate / 0.3) % 3
                HStack(spacing: Space.tight) {
                    ForEach(0..<3, id: \.self) { dot in
                        Circle().fill(Color.secondary).frame(width: Space.typingDot, height: Space.typingDot).opacity(phase == dot ? 0.9 : 0.35)
                    }
                }
                .padding(.horizontal, Space.bubbleH)
                .frame(height: Space.typingHeight)
                .background(BubbleShape(mine: false, tail: true).fill(Color(.secondarySystemBackground)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) is replying")
    }
}
