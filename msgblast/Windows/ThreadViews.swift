import SwiftUI
import AppKit
import msgblastCore

/// Messages' thread conventions shared by the Messages transcript and the app-agent transcript.
enum ThreadFormat {
    /// A time header separates messages more than five minutes apart, and opens the thread.
    static func showsTimeHeader(_ date: Date, previous: Date?) -> Bool {
        guard let previous else { return true }
        return date.timeIntervalSince(previous) > 300
    }
    static func timeHeader(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "Today \(time)" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday \(time)" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + " at " + time
    }
}

/// A centered time header with Messages' 12 pt above and below; the first one has none above.
struct ThreadTimeHeader: View {
    let date: Date
    let first: Bool
    var body: some View {
        Text(ThreadFormat.timeHeader(date))
            .font(.system(size: Space.threadCaption, weight: .semibold)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, first ? 0 : Space.separator).padding(.bottom, Space.separator)
    }
}

/// Messages' bubble around any content: 12 by 7 inside, blue for yours, gray for replies,
/// the tail on the last bubble of a run.
struct ThreadBubble<Content: View>: View {
    let mine: Bool
    let tail: Bool
    let maxWidth: CGFloat
    private let content: Content
    init(mine: Bool, tail: Bool, maxWidth: CGFloat, @ViewBuilder content: () -> Content) {
        self.mine = mine; self.tail = tail; self.maxWidth = maxWidth; self.content = content()
    }
    var body: some View {
        MaxWidth(width: maxWidth) { content }
            .padding(.horizontal, Space.bubbleH).padding(.vertical, Space.bubbleV)
            .background(BubbleShape(mine: mine, tail: tail).fill(mine ? MessageAppearance.outgoingBubbleColor : MessageAppearance.incomingBubbleColor))
            .foregroundStyle(mine ? Color.white : Color.primary)
            // macOS has no context-menu preview shape; the interaction shape bounds clicks to the bubble.
            .contentShape(BubbleShape(mine: mine, tail: false))
    }
}

/// The Messages row around a bubble: a reply is indented past a 28 pt avatar that sits beside
/// the last bubble of its run, and the run starts with the sender's name; a status caption
/// sits 2 pt under the bubble. Rows set their own side insets.
struct ThreadRow<Bubble: View>: View {
    let mine: Bool
    let firstOfRun: Bool
    let lastOfRun: Bool
    var sender: (name: String, avatar: AnyView)? = nil
    var status: (text: String, color: Color)? = nil
    private let bubble: Bubble
    init(mine: Bool, firstOfRun: Bool, lastOfRun: Bool, sender: (name: String, avatar: AnyView)? = nil,
         status: (text: String, color: Color)? = nil, @ViewBuilder bubble: () -> Bubble) {
        self.mine = mine; self.firstOfRun = firstOfRun; self.lastOfRun = lastOfRun
        self.sender = sender; self.status = status; self.bubble = bubble()
    }
    private var avatarColumn: CGFloat { sender != nil ? Space.avatarThread + Space.beside : 0 }
    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 0) {
            if !mine, firstOfRun, let sender {
                // Aligned with the bubble's text, 2 pt above the bubble.
                Text(sender.name).font(.system(size: Space.threadCaption, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.leading, avatarColumn + Space.bubbleH)
                    .padding(.bottom, Space.attached)
            }
            HStack(alignment: .bottom, spacing: Space.beside) {
                if !mine, let sender {
                    if lastOfRun { sender.avatar } else { Color.clear.frame(width: Space.avatarThread) }
                }
                bubble
            }
            if let status {
                Text(status.text).font(.system(size: Space.threadCaption, weight: .medium)).foregroundStyle(status.color)
                    .padding(.top, Space.attached)
            }
        }
        .padding(.leading, sender != nil ? Space.threadAvatarEdge : Space.screen)
        .padding(.trailing, Space.screen)
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }
}

/// Messages' typing bubble: the agent's avatar and three dots that pulse in turn.
struct TypingBubble: View {
    let agent: Agent?
    let name: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(alignment: .bottom, spacing: Space.beside) {
            AgentAvatar(agent: agent, name: name, size: Space.avatarThread)
            TimelineView(.animation(minimumInterval: 0.15, paused: reduceMotion)) { timeline in
                // Reduce Motion freezes the dots at one even weight.
                let phase = reduceMotion ? -1 : Int(timeline.date.timeIntervalSinceReferenceDate / 0.3) % 3
                HStack(spacing: Space.tight) {
                    ForEach(0..<3, id: \.self) { dot in
                        Circle().fill(Color.secondary).frame(width: Space.typingDot, height: Space.typingDot).opacity(phase == dot ? 0.9 : 0.35)
                    }
                }
                .padding(.horizontal, Space.bubbleH)
                .frame(height: Space.typingHeight)
                .background(BubbleShape(mine: false, tail: true).fill(MessageAppearance.incomingBubbleColor))
            }
        }
        .padding(.leading, Space.threadAvatarEdge)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) is replying")
    }
}

/// The prompt that formed a group, pinned under the header while its bubble is off screen.
struct PinnedPromptRow: View {
    let text: String
    @Binding var expanded: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: Space.gap) {
                Image(systemName: "pin.fill").font(.footnote).foregroundStyle(.tint).padding(.top, Space.hairline)
                VStack(alignment: .leading, spacing: Space.hairline) {
                    Text("Prompt").font(.system(size: Space.threadCaption, weight: .semibold)).foregroundStyle(.secondary)
                    Text(text).font(.system(size: Space.pinnedText)).lineLimit(expanded ? nil : 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(expanded ? "Shows two lines" : "Shows the whole prompt")
            }
            .padding(.horizontal, Space.screen).padding(.vertical, Space.pinnedV)
            // Opaque: nothing shows through the prompt's text.
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
        }
    }
}

/// The small check on a header avatar: filled with the tint when selected, a hollow ring
/// otherwise, ringed in the window background so it reads over the artwork.
struct CheckBadge: View {
    let checked: Bool
    var body: some View {
        ZStack {
            if checked {
                Circle().fill(.tint)
                Image(systemName: "checkmark").resizable().scaledToFit().fontWeight(.bold)
                    .foregroundStyle(.white).padding(Space.tight)
            } else {
                Circle().strokeBorder(Color.secondary, lineWidth: Space.checkRing)
            }
        }
        .frame(width: Space.badge, height: Space.badge)
        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-Space.hairline))
        .accessibilityHidden(true)
    }
}

/// A column's header, as Messages shows a thread's identity: the avatar with a check badge
/// (this agent receives the next message) and the name under it. Click to toggle.
struct ColumnHeader<MenuItems: View>: View {
    let agent: Agent?
    let name: String
    var included: Bool
    var enabled = true
    var busy = false            // a mini ProgressView beside the name
    var detail: String? = nil   // tooltip: destination handle or location label
    let toggle: () -> Void
    @ViewBuilder let menu: () -> MenuItems
    var body: some View {
        VStack(spacing: Space.tight) {
            Button(action: toggle) {
                AgentAvatar(agent: agent, name: name, size: Space.avatarHeader)
                    .overlay(alignment: .bottomTrailing) {
                        CheckBadge(checked: included).offset(x: Space.hairline, y: Space.hairline)
                    }
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .accessibilityLabel("Recipient \(name)")
            .accessibilityValue(included ? "Selected" : "Not selected")
            HStack(spacing: Space.tight) {
                Text(name).font(.system(size: Space.threadCaption, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                if busy { ProgressView().controlSize(.mini) }
            }
        }
        .padding(.top, Space.gap).padding(.bottom, Space.tight)
        .frame(maxWidth: .infinity).contentShape(Rectangle())
        .contextMenu { menu() }
        .help(detail ?? name)
        .accessibilityIdentifier("Agent header \(name)")
    }
}

/// An ⓘ that shows the full text of a one-line notice in a popover.
struct DetailButton: View {
    let detail: String
    @State private var showing = false
    var body: some View {
        Button { showing.toggle() } label: { Image(systemName: "info.circle") }
            .buttonStyle(.borderless)
            .accessibilityLabel("Details")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                Text(detail).textSelection(.enabled)
                    .frame(maxWidth: Space.popoverWidth)
                    .padding(Space.screen)
            }
    }
}

/// A one-line notice under a column header: an optional symbol, one short clause, the full
/// text behind an ⓘ when there is more to say, and at most one small button. Orange only
/// when the user must act.
struct NoticeRow<Action: View>: View {
    let text: String
    var systemImage: String? = nil
    var detail: String? = nil
    var attention = false
    var progress = false
    @ViewBuilder let action: () -> Action
    var body: some View {
        HStack(spacing: Space.gap) {
            if progress { ProgressView().controlSize(.mini) }
            if let systemImage { Image(systemName: systemImage) }
            Text(text).font(.caption).lineLimit(1).truncationMode(.tail)
            if let detail { DetailButton(detail: detail) }
            Spacer()
            action().controlSize(.small)
        }
        .padding(.horizontal, Space.screen).padding(.vertical, Space.tight)
        .foregroundStyle(attention ? Color.orange : Color.secondary)
    }
}

extension NoticeRow where Action == EmptyView {
    init(_ text: String, systemImage: String? = nil, detail: String? = nil, attention: Bool = false, progress: Bool = false) {
        self.init(text: text, systemImage: systemImage, detail: detail, attention: attention, progress: progress) { EmptyView() }
    }
}

/// The app-agent thread in Messages' layout: your prompts as blue bubbles with a status
/// caption, the agent's replies as gray bubbles named and signed with its avatar, a time
/// header before a prompt sent more than five minutes after the previous one, and a typing
/// bubble while the agent replies.
struct NativeTranscriptView: View {
    let agent: Agent?
    let name: String
    let messages: [WebPageMessage]
    /// Status captions by message id.
    var statuses: [String: (text: String, color: Color)] = [:]
    /// Send times by message id; only your messages have one.
    var dates: [String: Date] = [:]
    var typing = false
    let emptyText: String
    /// A stable id for the bottom anchor.
    let bottomID: String
    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    // A plain stack, not a lazy one, so row heights are exact while scrolling to the
                    // newest message. Bottom-aligned so a short thread sits at the bottom like Messages.
                    VStack(alignment: .leading, spacing: 0) {
                        if messages.isEmpty && !typing {
                            Text(emptyText).font(.system(size: Space.bodyText)).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.top, Space.section)
                        }
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            let previous = index == 0 ? nil : messages[index - 1]
                            let header = showsHeader(at: index)
                            let continues = !header && previous.map { $0.role == message.role } == true
                            let endsRun = index + 1 == messages.count || showsHeader(at: index + 1) || messages[index + 1].role != message.role
                            if header, let date = dates[message.id] { ThreadTimeHeader(date: date, first: index == 0) }
                            row(message, firstOfRun: !continues, lastOfRun: endsRun, maxWidth: geometry.size.width * Space.bubbleMax)
                                .padding(.top, header || previous == nil ? 0 : continues ? Space.run : Space.runGap)
                                .id(message.id)
                        }
                        if typing {
                            TypingBubble(agent: agent, name: name).padding(.top, Space.runGap)
                        }
                        Color.clear.frame(height: 0).id(bottomID)
                    }
                    .padding(.vertical, Space.gap)
                    .frame(minHeight: geometry.size.height, alignment: .bottom)
                }
                .onAppear {
                    Task { @MainActor in
                        await Task.yield()
                        proxy.scrollTo(bottomID, anchor: .bottom)
                    }
                }
                .onChange(of: messages.last?.id) { _, _ in
                    withAnimation { proxy.scrollTo(bottomID, anchor: .bottom) }
                }
                .onChange(of: typing) { _, _ in
                    withAnimation { proxy.scrollTo(bottomID, anchor: .bottom) }
                }
            }
        }
    }

    /// A time header precedes a dated message sent well after the previous dated one.
    private func showsHeader(at index: Int) -> Bool {
        guard index < messages.count, let date = dates[messages[index].id] else { return false }
        let previous = messages[..<index].reversed().lazy.compactMap { dates[$0.id] }.first
        return ThreadFormat.showsTimeHeader(date, previous: previous)
    }

    private func row(_ message: WebPageMessage, firstOfRun: Bool, lastOfRun: Bool, maxWidth: CGFloat) -> some View {
        let mine = message.role == "user"
        let sender: (name: String, avatar: AnyView)? = mine ? nil : (name, AnyView(AgentAvatar(agent: agent, name: name, size: Space.avatarThread)))
        return ThreadRow(mine: mine, firstOfRun: firstOfRun, lastOfRun: lastOfRun, sender: sender, status: statuses[message.id]) {
            ThreadBubble(mine: mine, tail: lastOfRun, maxWidth: maxWidth) {
                Text(Self.attributed(message.text))
                    .font(.system(size: Space.bodyText))
                    .textSelection(.enabled)
            }
            .contextMenu {
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.text, forType: .string)
                }
            }
        }
    }

    /// Inline Markdown in app-agent replies; plain text when it does not parse.
    private static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
