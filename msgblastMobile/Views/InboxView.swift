import SwiftUI
import msgblastMobileKit
import msgblastRemoteProtocol

struct InboxView: View {
    @ObservedObject var app: MobileApp
    @State private var composing = false
    @State private var settings = false
    @State private var query = ""
    var launchScreen: LaunchScreen = .inbox

    private var presenter: ProjectionPresenter {
        ProjectionPresenter(state: app.store.projection, commands: app.store.commands, lastOpened: app.store.lastOpened, unreadSince: app.store.unreadSince)
    }

    /// The row's title as shown: a direct row is named for its agent or contact.
    private func title(_ row: InboxRow) -> String { row.isDirect ? presenter.name(row.agentIDs[0]) : row.title }

    var body: some View {
        let all = presenter.inbox
        let needle = query.trimmingCharacters(in: .whitespaces)
        let rows = needle.isEmpty ? all : all.filter { title($0).localizedStandardContains(needle) || $0.preview.localizedStandardContains(needle) }
        // Messages' list: plain and full-bleed, one list newest first, separators from the text column.
        List {
            if let action = connectionAction {
                Button(action.title, action: action.run)
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
            }
            ForEach(rows) { row in link(row) }
        }
        .listStyle(.plain)
        .overlay {
            if all.isEmpty {
                ContentUnavailableView("No Conversations", systemImage: "bubble.left.and.bubble.right",
                                       description: Text(app.connection.state.canSend ? "Tap compose to start one" : app.connection.state.statusText))
            } else if rows.isEmpty {
                ContentUnavailableView.search(text: needle)
            }
        }
        .navigationTitle(app.connection.pairedMac?.macName ?? "msgblast")
        .navigationBarTitleDisplayMode(.inline)
        .macStatusSubtitle(app)
        .navigationDestination(for: UUID.self) { ConversationView(app: app, conversationID: $0) }
        // Settings is a screen of its own, pushed from the gear; compose stays a sheet.
        .navigationDestination(isPresented: $settings) { SettingsView(app: app) }
        // iOS 26: search and compose share the bottom toolbar, search minimized to a button.
        .searchable(text: $query, prompt: "Search")
        .searchToolbarBehavior(.minimize)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button { settings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings") }
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button { composing = true } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("New conversation")
            }
        }
        .sheet(isPresented: $composing) { NavigationStack { NewBlastView(app: app) } }
        .refreshable { app.connection.connect() }
        .onAppear {
            if launchScreen == .newConversation { composing = true }
            if launchScreen == .settings { settings = true }
        }
    }

    /// The one action a disconnected state needs, shown as a capsule at the top of the list.
    private var connectionAction: (title: String, run: () -> Void)? {
        switch app.connection.state {
        case .pairingLost: ("Pair Again", { app.forgetMac() })
        case .stopped: ("Connect", { app.connection.connect() })
        default: nil
        }
    }

    /// Messages' row on iOS 26: the unread dot 6 pt from the edge, a 50 pt avatar 20 pt in,
    /// then the text column 14 pt after it. The title line carries the time and a chevron; the
    /// badge or Ended sits under the time, so a row's height depends only on its preview.
    private func link(_ row: InboxRow) -> some View {
        HStack(alignment: .center, spacing: 0) {
            Circle().fill(row.unread ? Color.accentColor : Color.clear)
                .frame(width: Space.unreadDot, height: Space.unreadDot)
                .padding(.leading, Space.unreadEdge)
                .frame(width: Space.inboxAvatarEdge, alignment: .leading)
                .accessibilityHidden(true)
            RowAvatar(app: app, agentIDs: row.agentIDs, names: row.agentIDs.map(presenter.shortName))
            VStack(alignment: .leading, spacing: Space.attached) {
                HStack(alignment: .firstTextBaseline, spacing: Space.tight) {
                    Text(title(row)).font(.headline).lineLimit(1)
                    Spacer(minLength: Space.gap)
                    Text(ProjectionPresenter.inboxTimestamp(row.lastActivity)).font(.subheadline).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.tertiary)
                }
                HStack(alignment: .top, spacing: Space.gap) {
                    (row.fromYou ? Text(Image(systemName: "arrowshape.turn.up.left")).font(.footnote) + Text(" ") + Text(row.preview) : Text(row.preview))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                    // The accessory keeps its full size; the preview wraps beside it.
                    if row.unconfirmed > 0 { UnconfirmedBadge(count: row.unconfirmed).fixedSize() }
                    else if row.ended { Text("Ended").font(.caption).foregroundStyle(.secondary).fixedSize() }
                }
            }
            .padding(.leading, Space.inboxTextGap)
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
        .padding(.vertical, Space.inboxRowV)
        .padding(.trailing, Space.screen)
        .contentShape(Rectangle())
        // The link is the whole row without the system chevron, which Messages puts after the time.
        .background { NavigationLink(value: row.id) { EmptyView() }.opacity(0) }
        .listRowInsets(EdgeInsets())
        .accessibilityElement(children: .combine)
        .accessibilityValue(row.unread ? "Unread" : "")
        .accessibilityAddTraits(.isButton)
    }
}

struct SettingsView: View {
    @ObservedObject var app: MobileApp
    @State private var confirmForget = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form {
            if let mac = app.connection.pairedMac {
                Section {
                    LabeledContent("Name", value: mac.macName)
                    LabeledContent("Key", value: mac.fingerprint).font(.callout.monospaced())
                    LabeledContent("Paired", value: mac.pairedAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent {
                        VStack(alignment: .trailing, spacing: Space.hairline) {
                            Text(app.connection.state.statusText)
                            if let route = app.connection.connectedVia { Text(route).font(.caption.monospaced()).foregroundStyle(.secondary) }
                        }
                    } label: { Text("Status") }
                    if let seconds = app.connection.lastConnectSeconds { LabeledContent("Connect time", value: String(format: "%.1f s", seconds)) }
                } header: {
                    HStack(spacing: Space.gap) {
                        AppIconImage(size: Space.section)
                        Text("Mac")
                    }
                }
            }
            Section {
                Toggle("Keep Mac Awake", isOn: $app.keepAwake)
            } footer: {
                let held = app.store.projection.macStatus?.keepAwakeHeld == true
                Text(held ? "Your Mac is awake for this phone" : "While this phone is connected")
                    .accessibilityIdentifier("mac-kept-awake")
                    .accessibilityValue(held ? "Yes" : "No")
            }
            Section {
                Button("Forget This Mac", role: .destructive) { confirmForget = true }
            }
            Section {
                LabeledContent("Protocol", value: "\(MobileKit.protocolVersion)")
            } header: { Text("About") } footer: {
                Text("Controls msgblast on your Mac. Drafts stay on this phone. Interrupted sends are never resent.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Forget This Mac?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget This Mac", role: .destructive) { app.forgetMac(); dismiss() }
        } message: { Text("Deletes conversations and drafts on this phone") }
    }
}

/// An unconfirmed count, like an unread badge: the number with a symbol, no word.
struct UnconfirmedBadge: View {
    var count: Int
    var body: some View {
        HStack(spacing: Space.hairline) {
            Image(systemName: "exclamationmark.circle.fill")
            Text("\(count)")
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, Space.gap).padding(.vertical, Space.hairline)
        .background(.orange, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) unconfirmed")
    }
}

/// A 50 pt avatar for a direct row, or a pair of 28 pt circles for a group.
struct RowAvatar: View {
    @ObservedObject var app: MobileApp
    var agentIDs: [String]
    var names: [String]
    static let side = Space.avatarInbox
    var body: some View {
        if agentIDs.count == 1 {
            AgentAvatar(app: app, agentID: agentIDs[0], name: names[0], size: Self.side)
        } else {
            // Messages' group avatar: the first member top-left behind, the second
            // bottom-right in front with a 2 pt ring in the row color, all inside 50 pt.
            ZStack(alignment: .topLeading) {
                AgentAvatar(app: app, agentID: agentIDs[0], name: names[0], size: Space.avatarGroup)
                AgentAvatar(app: app, agentID: agentIDs[1], name: names[1], size: Space.avatarGroup)
                    .padding(Space.hairline)
                    .background(Circle().fill(Color(.systemBackground)))
                    .offset(x: Self.side - Space.avatarGroup - 2 * Space.hairline, y: Self.side - Space.avatarGroup - 2 * Space.hairline)
            }
            .frame(width: Self.side, height: Self.side, alignment: .topLeading)
        }
    }
}
