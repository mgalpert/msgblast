import SwiftUI
import msgblastMobileKit
import msgblastRemoteProtocol

struct InboxView: View {
    @ObservedObject var app: MobileApp
    @State private var composing = false
    @State private var settings = false

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
                ContentUnavailableView("No conversations yet", systemImage: "bubble.left.and.bubble.right",
                                       description: Text(app.connection.state.canSend ? "Start one with the compose button." : app.connection.state.bannerText))
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
                }.frame(width: 54, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(row.isDirect ? presenter.name(row.agentIDs[0]) : row.title).font(.headline).lineLimit(1)
                        Spacer()
                        Text(row.lastActivity, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(row.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    HStack(spacing: 6) {
                        if row.unconfirmed > 0 { Label("\(row.unconfirmed) unconfirmed", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
                        if row.ended { Text("Ended").font(.caption).foregroundStyle(.secondary) }
                    }
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
                    LabeledContent("Status", value: app.connection.state.bannerText)
                }
            }
            Section {
                Toggle("Keep my Mac awake while connected", isOn: $app.keepAwake)
                Text("Your Mac can turn this off in msgblast Settings → Remote.").font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button("Forget this Mac", role: .destructive) { confirmForget = true }
            }
            Section("About") {
                Text("msgblast on your phone controls msgblast on your Mac. Drafts stay on this phone. A send that loses its connection is shown as unconfirmed and is never resent.")
                    .font(.footnote).foregroundStyle(.secondary)
                LabeledContent("Protocol", value: "\(MobileKit.protocolVersion)")
            }
        }
        .navigationTitle("Settings")
        .toolbar { Button("Done") { dismiss() } }
        .confirmationDialog("Forget this Mac?", isPresented: $confirmForget) {
            Button("Forget", role: .destructive) { app.forgetMac(); dismiss() }
        } message: { Text("Cached conversations and drafts on this phone are deleted. Pair again to reconnect.") }
    }
}
