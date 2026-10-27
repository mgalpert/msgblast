import SwiftUI
import msgblastMobileKit

struct RootView: View {
    @ObservedObject var app: MobileApp
    @Binding var incomingLink: String?

    var body: some View {
        Group {
            if app.connection.pairedMac == nil {
                NavigationStack { PairingView(app: app, incomingLink: $incomingLink) }
            } else {
                NavigationStack { InboxView(app: app) }
                    .safeAreaInset(edge: .top, spacing: 0) { MacBanner(app: app) }
            }
        }
        .sheet(isPresented: Binding(get: { incomingLink != nil && app.connection.pairedMac != nil }, set: { if !$0 { incomingLink = nil } })) {
            NavigationStack { PairingView(app: app, incomingLink: $incomingLink) }
        }
    }
}

/// Connected / reconnecting / Mac locked / msgblast not running, with when the Mac was last heard.
struct MacBanner: View {
    @ObservedObject var app: MobileApp
    var body: some View {
        let state = app.connection.state
        if state != .connected || app.store.projection.macLocked {
            HStack(spacing: 8) {
                Image(systemName: icon(state)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.store.projection.macLocked ? MacConnectionState.macLocked.bannerText : state.bannerText).font(.footnote.weight(.semibold))
                    if let heard = app.connection.lastHeard {
                        Text("Last heard \(heard.formatted(.relative(presentation: .named)))").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if case .pairingLost = state {
                    Button("Pair again") { app.forgetMac() }.font(.footnote)
                } else if state == .stopped {
                    Button("Connect") { app.connection.connect() }.font(.footnote)
                }
            }
            .padding(.horizontal).padding(.vertical, 8)
            .background(.bar)
            .accessibilityElement(children: .combine)
        }
    }
    private func icon(_ state: MacConnectionState) -> String {
        switch state {
        case .macLocked: "lock.fill"
        case .connecting, .reconnecting: "arrow.triangle.2.circlepath"
        case .pairingLost: "exclamationmark.triangle"
        default: "desktopcomputer"
        }
    }
}

/// Initials in a circle, tinted by product so forms of one product read as related.
struct AgentAvatar: View {
    var name: String
    var product: String
    var size: CGFloat = 28
    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Self.color(product)))
            .accessibilityHidden(true)
    }
    static func color(_ product: String) -> Color {
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .brown, .cyan, .mint]
        return palette[abs(product.hashValue) % palette.count]
    }
}
