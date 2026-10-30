import SwiftUI
import msgblastMobileKit
import msgblastRemoteProtocol

struct InboxView: View {
    @ObservedObject var app: MobileApp
    @State private var composing = false
    @State private var settings = false
    var launchScreen: LaunchScreen = .inbox

    private var presenter: ProjectionPresenter { ProjectionPresenter(state: app.store.projection, commands: app.store.commands) }

    var body: some View {
        let rows = presenter.inbox
        List {
            let group = rows.filter { !$0.isDirect }
            if !group.isEmpty {
                Section("Conversations") { ForEach(group) { row in link(row) } }
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

    private func link(_ row: InboxRow) -> some View {
        NavigationLink(value: row.id) {
            HStack(alignment: .top, spacing: 12) {
                HStack(spacing: -12) {
                    ForEach(Array(row.agentIDs.prefix(3).enumerated()), id: \.offset) { index, id in
                        AgentAvatar(name: presenter.shortName(id), product: app.store.projection.agents[id]?.product.rawValue ?? id, size: 30)
                            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                            .zIndex(Double(3 - index))
                    }
                }.frame(width: 66, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(row.isDirect ? presenter.name(row.agentIDs[0]) : row.title).font(.headline).lineLimit(1)
                        Spacer()
                        Text(ProjectionPresenter.inboxTimestamp(row.lastActivity)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(row.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        Spacer(minLength: 0)
                        if row.unconfirmed > 0 { UnconfirmedBadge(count: row.unconfirmed) }
                    }
                    if row.ended { Text("Ended").font(.caption).foregroundStyle(.tertiary) }
                }
            }
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
                Section("Mac") {
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
                }
            }
            Section {
                Toggle("Keep Mac Awake", isOn: $app.keepAwake)
                if let status = app.store.projection.macStatus {
                    LabeledContent("Awake now", value: status.keepAwakeHeld ? "Yes" : "No")
                        .accessibilityIdentifier("mac-kept-awake")
                }
            } footer: {
                Text(app.store.projection.macStatus?.keepAwakeHeld == true ? "Your Mac is awake for this phone" : "While this phone is connected")
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
