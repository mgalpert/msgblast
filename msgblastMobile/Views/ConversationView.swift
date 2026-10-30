import SwiftUI
import msgblastMobileKit
import msgblastRemoteProtocol

struct ConversationView: View {
    @ObservedObject var app: MobileApp
    let conversationID: UUID
    /// nil = All; otherwise one agent's private thread.
    @State private var filter: String?
    @State private var recipients: [String] = []
    @State private var actionError: String?
    @State private var showingDetails = false
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

    var body: some View {
        if let conversation {
            content(conversation)
        } else {
            ContentUnavailableView("Not on Your Mac", systemImage: "questionmark.bubble")
        }
    }

    private func content(_ conversation: RemoteConversation) -> some View {
        let turns = presenter.turns(in: conversationID, agentID: filter)
        return ScrollViewReader { proxy in
            ScrollView {
                // Messages anchors the thread to the bottom: a short thread sits just above the
                // compose bar (the spacer takes the slack), a long one scrolls as usual.
                VStack(alignment: .leading, spacing: 0) {
                    if conversation.agentIDs.count > 1 {
                        Picker("Show", selection: $filter) {
                            Text("All").tag(String?.none)
                            ForEach(conversation.agentIDs, id: \.self) { Text(presenter.shortName($0)).tag(String?.some($0)) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.bottom, Space.gap)
                    }
                    // A submitted request shows as typing below; the row is for Stop or review.
                    ForEach(conversation.incompleteAttempts.filter { ![.waiting, .submitted].contains(app.store.projection.attempts[$0.attemptID]?.status) }, id: \.attemptID) { incomplete in
                        incompleteRow(incomplete).padding(.bottom, Space.gap)
                    }
                    Spacer(minLength: 0)
                // Spacing is explicit per row: 2 pt within one sender's run, 8 pt between
                // senders, a time header 24 pt above and 8 pt below (Messages' rhythm).
                LazyVStack(alignment: .leading, spacing: 0) {
                    let latestMine = turns.last { $0.role == .user }?.id
                    ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                        let previous = index == 0 ? nil : turns[index - 1]
                        let header = turn.created.flatMap { ProjectionPresenter.timeHeader($0, previous: previous?.created) }
                        if let header {
                            Text(header).font(.caption2.weight(.medium)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                                .padding(.top, index == 0 ? 0 : Space.section).padding(.bottom, Space.gap)
                        }
                        let sameSender = previous.map { $0.role == turn.role && $0.agentID == turn.agentID } ?? false
                        bubble(turn, showsName: turn.role != .user && !sameSender, isLatest: turn.id == latestMine)
                            .padding(.top, header != nil || previous == nil ? 0 : sameSender ? Space.hairline : Space.gap)
                            .id(turn.id)
                    }
                    ForEach(presenter.typingAgents(in: conversationID, agentID: filter), id: \.self) { agent in
                        TypingBubble(app: app, agentID: agent, name: presenter.shortName(agent)).padding(.top, Space.gap).id("typing-\(agent)")
                    }
                    if let actionError { Text(actionError).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity).padding(.top, Space.gap) }
                    if conversation.endedAt != nil { Text("Ended").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, Space.section) }
                }
                Color.clear.frame(height: 0).id(Self.bottomID)
                }
                .padding(.horizontal, Space.screen).padding(.vertical, Space.gap)
                .frame(minHeight: visibleHeight, alignment: .bottom)
            }
            .scrollDismissesKeyboard(.interactively)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onScrollGeometryChange(for: ThreadGeometry.self) { geometry in
                // `containerSize` is the area between the bars; `visibleRect` spans the insets too,
                // so the distance to the end counts the bottom inset. The navigation bar's inset
                // arrives last, so the first settled pass is the one that decides the opening.
                ThreadGeometry(visible: geometry.containerSize.height, content: geometry.contentSize.height,
                               distanceFromBottom: geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY,
                               settled: geometry.contentInsets.top > 0)
            } action: { old, new in
                visibleHeight = max(0, new.visible)
                guard new.settled else { return }
                // Open on the newest message: a short thread is already bottom-aligned by the
                // spacer; a long one scrolls to its end once.
                if !openedAtBottom {
                    openedAtBottom = true
                    atBottom = true
                    if new.content > new.visible + 1 { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
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
            .onChange(of: presenter.typingAgents(in: conversationID, agentID: filter)) { _, _ in
                if atBottom { withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) } }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if conversation.endedAt == nil {
                ComposeBar(app: app, conversationID: conversationID, recipients: $recipients, onSent: { _ in })
            }
        }
        .navigationTitle(filter.map(presenter.name) ?? conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            recipients = filter.map { [$0] } ?? conversation.agentIDs; app.store.markOpened(conversationID)
            #if DEBUG
            // Design review: `MSGBLAST_FIXTURE_DETAILS` opens the Details sheet.
            if ProcessInfo.processInfo.environment["MSGBLAST_FIXTURE_DETAILS"] != nil { showingDetails = true }
            #endif
        }
        .onChange(of: filter) { _, value in recipients = value.map { [$0] } ?? conversation.agentIDs }
        .toolbar {
            // Messages' header: avatars over a pill that opens Details (agents, report, end).
            ToolbarItem(placement: .principal) {
                ThreadHeader(app: app, agentIDs: conversation.agentIDs) { showingDetails = true }
            }
        }
        .sheet(isPresented: $showingDetails) { ThreadDetailsSheet(app: app, conversationID: conversationID, run: run) }
        .sheet(item: $details) { summary in RequestDetailsSheet(summary: summary, name: presenter.name(summary.agentID)) }
    }

    private static let bottomID = "thread-bottom"

    private func bubble(_ turn: RemoteTurn, showsName: Bool, isLatest: Bool) -> some View {
        let mine = turn.role == .user
        let text = turn.text.isEmpty ? turn.attachments.map(\.filename).joined(separator: ", ") : turn.text
        let all = mine ? presenter.chips(for: turn, agentID: filter) : []
        let notSent = all.first { $0.state == .notSent }
        return VStack(alignment: mine ? .trailing : .leading, spacing: Space.tight) {
            if showsName, let agent = turn.agentID {
                HStack(spacing: Space.gap) {
                    AgentAvatar(app: app, agentID: agent, name: presenter.shortName(agent), size: Space.avatarInline)
                    Text(presenter.name(agent)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .center, spacing: Space.gap) {
                // Messages' Not Delivered mark sits at the bubble's leading edge.
                if let notSent { ChipView(chip: notSent, showsName: false, iconOnly: true, retry: retry(turn, notSent)) }
                MaxWidth(width: (width - 2 * Space.screen) * Space.bubbleWidth) {
                Text(text)
                    .textSelection(.enabled)
                    .padding(.horizontal, Space.inset).padding(.vertical, Space.gap)
                    .background(mine ? Color("Bubble") : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: Space.corner, style: .continuous))
                    .foregroundStyle(mine ? .white : .primary)
                    .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Space.corner, style: .continuous))
                    .contextMenu {
                        // Copy only: resending your own message is never offered, so nothing is sent twice by accident.
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
                    }
                    .onTapGesture {
                        guard mine else { return }
                        withAnimation(.snappy) { if expanded.contains(turn.id) { expanded.remove(turn.id) } else { expanded.insert(turn.id) } }
                    }
                }
            }
            if !turn.attachments.isEmpty && !turn.text.isEmpty {
                Label(turn.attachments.map(\.filename).joined(separator: ", "), systemImage: "paperclip").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if mine {
                let visible = presenter.visibleChips(for: turn, agentID: filter, isLatest: isLatest, expanded: expanded.contains(turn.id))
                if !visible.isEmpty {
                    StatusGlyphRow(app: app, chips: visible, retry: { chip in chip.state == .notSent ? retry(turn, chip) : nil })
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
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

/// What the conversation tracks about its scroll view to stay anchored at the bottom.
struct ThreadGeometry: Equatable {
    var visible: CGFloat
    var content: CGFloat
    var distanceFromBottom: CGFloat
    var settled: Bool
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
        HStack(spacing: Space.gap) {
            ForEach(chips) { chip in StatusGlyph(app: app, chip: chip, retry: retry(chip)) }
        }
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
        let label = content.font(iconOnly ? .title3 : .caption2).foregroundStyle(color)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(alignment: .bottom, spacing: Space.gap) {
            AgentAvatar(app: app, agentID: agentID, name: name, size: Space.avatarInline)
            TimelineView(.animation(minimumInterval: 0.15, paused: reduceMotion)) { timeline in
                let phase = reduceMotion ? -1 : Int(timeline.date.timeIntervalSinceReferenceDate / 0.3) % 3
                HStack(spacing: Space.tight) {
                    ForEach(0..<3, id: \.self) { dot in
                        Circle().fill(Color.secondary).frame(width: Space.dot, height: Space.dot).opacity(phase == dot ? 0.9 : 0.35)
                    }
                }
                .padding(.horizontal, Space.inset).padding(.vertical, Space.inset)
                .background(Color(.secondarySystemBackground), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) is replying")
    }
}
