import SwiftUI
import msgblastCore
import msgblastRemoteProtocol

/// Sidebar footer: update card, What's New, then the Phone section at the bottom. The Phone
/// section is one panel that stays in place: its header row is the closed state, and opening it
/// slides the rest up out of that row; closing slides it back down.
struct SidebarFooter: View {
    @ObservedObject var service: RemoteService
    @ObservedObject private var pairing: RemotePairing
    let updater: AppUpdater
    @AppStorage(PhoneSidebarState.preferenceKey) private var preference = PhoneSidebarPreference.automatic.rawValue

    init(service: RemoteService, updater: AppUpdater) {
        self.service = service
        pairing = service.pairing
        self.updater = updater
    }

    private var collapsed: Bool {
        PhoneSidebarState.isCollapsed(preference: PhoneSidebarPreference(rawValue: preference) ?? .automatic,
                                      enabled: service.settings.enabled, paired: pairing.device != nil,
                                      connected: pairing.device.map { service.connectedDeviceID == $0.id } ?? false)
    }

    var body: some View {
        VStack(spacing: 8) {
            UpdateSidebar(updater: updater)
            WhatsNewSidebar()
            PhoneSidebarSection(service: service, collapsed: collapsed) {
                preference = (collapsed ? PhoneSidebarPreference.expanded : .collapsed).rawValue
            }
        }
        .animation(PhoneSidebarSection.motion, value: collapsed)
    }
}

/// The Phone panel: one header row that is always shown, and the pairing content under it while open.
struct PhoneSidebarSection: View {
    /// One curve for opening and closing, so both directions move the same way.
    static let motion = Animation.easeInOut(duration: 0.25)

    @ObservedObject var service: RemoteService
    @ObservedObject private var pairing: RemotePairing
    @ObservedObject private var power: MacPowerState
    let collapsed: Bool
    let toggle: () -> Void

    init(service: RemoteService, collapsed: Bool, toggle: @escaping () -> Void) {
        self.service = service
        pairing = service.pairing
        power = service.power
        self.collapsed = collapsed
        self.toggle = toggle
    }

    private var statusLine: String { phoneStatusLine(service, offerShowing: !collapsed && pairing.isOfferValid) }
    private var dot: Color {
        switch PhoneSidebarState.status(enabled: service.settings.enabled,
                                        connected: pairing.device.map { service.connectedDeviceID == $0.id } ?? false) {
        case .connected: .green
        case .on: .orange
        case .off: Color.secondary.opacity(0.5)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !collapsed {
                PhoneSidebarPanel(service: service)
                    .padding(.top, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        Button { withAnimation(Self.motion) { toggle() } } label: {
            HStack(spacing: 10) {
                Image(systemName: "iphone").font(.title3)
                    .foregroundStyle(service.settings.enabled ? Color.accentColor : .secondary)
                    .overlay(alignment: .bottomTrailing) {
                        Circle().fill(dot).frame(width: 7, height: 7).accessibilityHidden(true)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Phone").font(.headline)
                    Text(statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up").font(.caption).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? 0 : 180))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Phone")
        .accessibilityLabel("Phone")
        .accessibilityValue(statusLine)
        .accessibilityHint(collapsed ? "Shows pairing and phone settings" : "Closes the phone section")
        .accessibilityIdentifier("sidebar-phone-toggle")
    }
}

/// One short clause for the header caption and accessibility value.
@MainActor private func phoneStatusLine(_ service: RemoteService, offerShowing: Bool) -> String {
    if !service.settings.enabled { return "Off" }
    if let device = service.pairing.device {
        return service.connectedDeviceID == device.id ? "\(device.name) connected" : "\(device.name) paired"
    }
    if offerShowing { return "Scan to pair your iPhone" }
    if let problem = service.problem { return problem }
    if service.power.locked { return "Mac locked" }
    return service.running ? "Ready to pair" : "Starting…"
}

/// The open Phone panel's content: Remote switch, live pairing QR code or the paired phone, and options.
struct PhoneSidebarPanel: View {
    @ObservedObject var service: RemoteService
    @ObservedObject private var pairing: RemotePairing
    @ObservedObject private var power: MacPowerState
    @State private var now = Date()
    @State private var confirmingForget = false
    /// The code minted here. The panel closes only that code, so a code opened from
    /// Settings → Remote → Pair a phone… (or one that replaced ours) outlives the panel.
    @State private var ownedCode: String?
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(service: RemoteService) {
        self.service = service
        pairing = service.pairing
        power = service.power
    }

    private var enabled: Bool { service.settings.enabled }
    private var offer: RemotePairingOffer? { pairing.offer.flatMap { $0.expiresAt > now ? $0 : nil } }
    private var wantsOffer: Bool {
        PhoneSidebarState.wantsOffer(collapsed: false, enabled: enabled, running: service.running, paired: pairing.device != nil,
                                     locked: power.locked, loadError: pairing.loadError != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Remote", isOn: Binding(get: { service.settings.enabled }, set: { service.setEnabled($0) }))
                .toggleStyle(.switch).controlSize(.small)
                .accessibilityIdentifier("sidebar-remote-enabled")
            if !enabled {
                Text("Turn on to pair your iPhone").font(.caption).foregroundStyle(.secondary)
            } else {
                if let error = pairing.loadError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                    Button("Forget the saved phone", role: .destructive) { service.forget() }.controlSize(.small)
                } else if let device = pairing.device {
                    pairedRow(device)
                } else if power.locked {
                    Text("Unlock to pair").font(.caption).foregroundStyle(.secondary)
                } else {
                    qrBlock
                }
                RemoteOptionControls(service: service, compact: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(tick) { now = $0; replaceExpiredOffer() }
        .onAppear { refreshOffer() }
        .onChange(of: wantsOffer) { _, wants in
            if wants { refreshOffer() } else { closeOwnOffer() }
        }
        .onDisappear(perform: closeOwnOffer)
    }

    @ViewBuilder private var qrBlock: some View {
        VStack(spacing: 6) {
            if let offer, let image = RemoteSettingsView.qrImage(offer.url.absoluteString) {
                Image(nsImage: image).interpolation(.none).resizable().aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: 168)
                    .padding(6).background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Pairing QR code")
                Text("Expires in \(Int(offer.expiresAt.timeIntervalSince(now)))s").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if let fingerprint = service.identityFingerprint {
                    // Not selectable: on macOS 27.2 a selectable Text with its own accessibility label sends
                    // SwiftUI into endless recursion when an accessibility client reads the label.
                    Text("Key \(fingerprint)").font(.caption.monospaced())
                        .accessibilityLabel("Mac key fingerprint \(fingerprint). The phone shows the same before pairing.")
                }
            } else if pairing.offer == nil || !NSApplication.shared.isActive {
                // Closed elsewhere (Settings › Cancel, Forget), or expired while msgblast is in
                // the background: wait to be asked again.
                Button("Show pairing code") { refreshOffer() }.controlSize(.small)
                    .accessibilityIdentifier("sidebar-show-pairing-code")
            } else {
                Color.clear.aspectRatio(1, contentMode: .fit).frame(maxWidth: 168).padding(6)
                    .overlay { ProgressView().controlSize(.small) }
                    .accessibilityLabel("Preparing pairing code")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func pairedRow(_ device: RemotePairedDevice) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).fontWeight(.semibold).lineLimit(1)
                Text(service.connectedDeviceID == device.id ? "Connected now" : device.lastSeen.map { "Last seen \($0.formatted(.relative(presentation: .named)))" } ?? "Not seen yet")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Forget…", role: .destructive) { confirmingForget = true }.controlSize(.small)
                .confirmationDialog("Forget \(device.name)?", isPresented: $confirmingForget) {
                    Button("Forget", role: .destructive) { service.forget() }
                } message: { Text("The phone disconnects and must be paired again.") }
        }
    }

    /// Opens a code when one is wanted and none is valid.
    private func refreshOffer() {
        guard wantsOffer, !pairing.isOfferValid else { return }
        if (try? service.showPairingCode()) != nil { ownedCode = pairing.offer?.code }
    }

    private func closeOwnOffer() {
        if let ownedCode, pairing.offer?.code == ownedCode { pairing.closeOffer() }
        ownedCode = nil
    }

    /// Replaces an expired code, but only while msgblast is the active app, so a hidden or
    /// background window does not keep minting codes. A code closed on purpose stays closed.
    private func replaceExpiredOffer() {
        guard pairing.offer != nil, NSApplication.shared.isActive else { return }
        refreshOffer()
    }
}
