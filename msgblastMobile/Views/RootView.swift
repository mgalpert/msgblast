import SwiftUI
import msgblastMobileKit

struct RootView: View {
    @ObservedObject var app: MobileApp
    @Binding var incomingLink: String?
    /// The pairing sheet over an already paired Mac. Its own state, so consuming the link
    /// never closes it; only a successful pairing or Cancel does.
    @State private var showingRepair = false
    /// Where to open; production opens on the inbox.
    var launchScreen: LaunchScreen = .inbox
    @State private var path: [UUID] = []

    var body: some View {
        Group {
            if app.connection.pairedMac == nil {
                NavigationStack { PairingView(app: app, incomingLink: $incomingLink) }
            } else {
                // The banner sits above the navigation bar so it never covers its buttons.
                VStack(spacing: 0) {
                    MacBanner(app: app)
                    NavigationStack(path: $path) { InboxView(app: app, launchScreen: launchScreen) }
                }
            }
        }
        .sheet(isPresented: $showingRepair) {
            NavigationStack { PairingView(app: app, incomingLink: $incomingLink, close: { showingRepair = false }) }
                .interactiveDismissDisabled()  // Closes only on success or Cancel.
        }
        .onAppear {
            presentRepairIfNeeded()
            if case .conversation(let id) = launchScreen, path.isEmpty { path = [id] }
        }
        .onChange(of: incomingLink) { _, _ in presentRepairIfNeeded() }
    }
}

extension RootView {
    /// A link that arrives while a Mac is paired opens the pairing sheet. When no Mac is
    /// paired the root pairing screen reads it instead.
    fileprivate func presentRepairIfNeeded() {
        if incomingLink != nil && app.connection.pairedMac != nil { showingRepair = true }
    }
}

/// Where the app opens. Production always opens on the inbox (or pairing).
enum LaunchScreen: Equatable {
    case inbox, conversation(UUID), newConversation, settings
}

/// Reconnecting / Mac Locked / Not Paired / Disconnected, with when the Mac was last heard.
/// Why it may be reconnecting shows only once that has lasted a while.
struct MacBanner: View {
    @ObservedObject var app: MobileApp
    /// When the current reconnecting stretch began.
    @State private var reconnectingSince: Date?
    static let explainAfter: TimeInterval = 20

    var body: some View {
        let state = app.store.projection.macLocked && app.connection.state.canSend ? MacConnectionState.macLocked : app.connection.state
        VStack(spacing: 0) {
            if state != .connected {
                TimelineView(.periodic(from: .now, by: 5)) { timeline in
                    HStack(spacing: 10) {
                        Image(systemName: icon(state)).foregroundStyle(.secondary).imageScale(.medium)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(state.title).font(.subheadline.weight(.semibold))
                            if let caption = caption(state, now: timeline.date) {
                                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        if case .pairingLost = state {
                            Button("Pair Again") { app.forgetMac() }.font(.subheadline).buttonStyle(.bordered).controlSize(.small)
                        } else if state == .stopped {
                            Button("Connect") { app.connection.connect() }.font(.subheadline).buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                    .padding(.horizontal).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .onAppear { track(state) }
        .onChange(of: state.isReconnecting) { _, _ in track(state) }
    }

    private func track(_ state: MacConnectionState) {
        if state.isReconnecting { if reconnectingSince == nil { reconnectingSince = Date() } } else { reconnectingSince = nil }
    }

    private func caption(_ state: MacConnectionState, now: Date) -> String? {
        if state.isReconnecting, let since = reconnectingSince, now.timeIntervalSince(since) >= Self.explainAfter { return state.detail }
        if case .pairingLost = state { return state.detail }
        guard let heard = app.connection.lastHeard else { return nil }
        return "Last heard \(heard.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))"
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

/// A small ⓘ that shows the Mac's full reason in a popover, also on iPhone.
struct DetailButton: View {
    var title: String = "Details"
    var detail: String
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: { Image(systemName: "info.circle") }
            .buttonStyle(.borderless)
            .accessibilityLabel(title)
            .popover(isPresented: $showing) { DetailPopover(text: detail) }
    }
}

struct DetailPopover: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 300, alignment: .leading)
            .padding()
            .presentationCompactAdaptation(.popover)
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
        // Stable across launches (String.hashValue is seeded per process).
        return palette[product.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % palette.count]
    }
}
