import SwiftUI
import msgblastMobileKit
import msgblastRemoteProtocol

struct InboxView: View {
    @ObservedObject var app: MobileApp
    @State private var composing = false
    @State private var settings = false
    var launchScreen: LaunchScreen = .inbox

    private var presenter: ProjectionPresenter {
        ProjectionPresenter(state: app.store.projection, commands: app.store.commands, lastOpened: app.store.lastOpened, unreadSince: app.store.unreadSince)
    }

    var body: some View {
        let rows = presenter.inbox
        List {
            if let action = connectionAction {
                Section {
                    Button(action.title, action: action.run)
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            }
            let group = rows.filter { !$0.isDirect }
            if !group.isEmpty {
                Section("Groups") { ForEach(group) { row in link(row) } }
            }
            let direct = rows.filter(\.isDirect)
            if !direct.isEmpty {
                Section("Direct") { ForEach(direct) { row in link(row) } }
            }
            if rows.isEmpty {
                ContentUnavailableView("No Conversations", systemImage: "bubble.left.and.bubble.right",
                                       description: Text(app.connection.state.canSend ? "Tap compose to start one" : app.connection.state.statusText))
            }
        }
        .navigationTitle(app.connection.pairedMac?.macName ?? "msgblast")
        .macStatusSubtitle(app)
        .navigationDestination(for: UUID.self) { ConversationView(app: app, conversationID: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button { settings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings") }
            ToolbarItem(placement: .topBarTrailing) { Button { composing = true } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("New conversation") }
        }
        .sheet(isPresented: $composing) { NavigationStack { NewBlastView(app: app) } }
        .sheet(isPresented: $settings) { NavigationStack { SettingsView(app: app) } }
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

    private func link(_ row: InboxRow) -> some View {
        NavigationLink(value: row.id) {
            HStack(alignment: .top, spacing: 10) {
                // Messages' unread dot, left of the avatar.
                Circle().fill(row.unread ? Color.blue : Color.clear).frame(width: 10, height: 10).padding(.top, 15)
                    .accessibilityHidden(true)
                RowAvatar(app: app, agentIDs: row.agentIDs, names: row.agentIDs.map(presenter.shortName))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.isDirect ? presenter.name(row.agentIDs[0]) : row.title).font(.headline.weight(row.unread ? .bold : .semibold)).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(ProjectionPresenter.inboxTimestamp(row.lastActivity)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text(row.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    // The meta line sits right under the preview: Ended, then the unconfirmed badge.
                    if row.ended || row.unconfirmed > 0 {
                        HStack(spacing: 6) {
                            if row.ended { Text("Ended").font(.caption).foregroundStyle(.secondary) }
                            Spacer(minLength: 0)
                            if row.unconfirmed > 0 { UnconfirmedBadge(count: row.unconfirmed) }
                        }
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(row.unread ? "Unread" : "")
        }
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
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(app.connection.state.statusText)
                            if let route = app.connection.connectedVia { Text(route).font(.caption.monospaced()).foregroundStyle(.secondary) }
                        }
                    } label: { Text("Status") }
                    if let seconds = app.connection.lastConnectSeconds { LabeledContent("Connect time", value: String(format: "%.1f s", seconds)) }
                } header: {
                    HStack(spacing: 10) {
                        AppIconImage(size: 28)
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
        .toolbar { Button("Done") { dismiss() } }
        .confirmationDialog("Forget This Mac?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget This Mac", role: .destructive) { app.forgetMac(); dismiss() }
        } message: { Text("Deletes conversations and drafts on this phone") }
    }
}

/// An unconfirmed count, like an unread badge: the number with a symbol, no word.
struct UnconfirmedBadge: View {
    var count: Int
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "exclamationmark.circle.fill")
            Text("\(count)")
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(.orange, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) unconfirmed")
    }
}

/// A 40 pt avatar for a direct row, or a trio for a group, each ringed in the row's color.
struct RowAvatar: View {
    @ObservedObject var app: MobileApp
    var agentIDs: [String]
    var names: [String]
    static let side: CGFloat = 40
    var body: some View {
        if agentIDs.count == 1 {
            AgentAvatar(app: app, agentID: agentIDs[0], name: names[0], size: Self.side)
        } else {
            // Messages' group avatar: the first member top-left behind, the second
            // bottom-right in front with a 2 pt ring in the row color.
            ZStack(alignment: .topLeading) {
                AgentAvatar(app: app, agentID: agentIDs[0], name: names[0], size: 26)
                AgentAvatar(app: app, agentID: agentIDs[1], name: names[1], size: 26)
                    .padding(2)
                    .background(Circle().fill(Color(.secondarySystemGroupedBackground)))
                    .offset(x: Self.side - 26 - 2, y: Self.side - 26 - 2)
            }
            .frame(width: Self.side, height: Self.side, alignment: .topLeading)
        }
    }
}
