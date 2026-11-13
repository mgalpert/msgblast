import SwiftUI
import msgblastCore
import msgblastRemoteProtocol

/// Sidebar footer: update card, the Phone section (expanded above What's New, or its icon docked
/// below it), What's New.
struct SidebarFooter: View {
    @ObservedObject var service: RemoteService
    @ObservedObject private var pairing: RemotePairing
    @ObservedObject private var power: MacPowerState
    let updater: AppUpdater
    @AppStorage(PhoneSidebarState.preferenceKey) private var preference = PhoneSidebarPreference.automatic.rawValue

    init(service: RemoteService, updater: AppUpdater) {
        self.service = service
        pairing = service.pairing
        power = service.power
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
            if !collapsed {
                PhoneSidebarCard(service: service) { setCollapsed(true) }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            WhatsNewSidebar()
            if collapsed {
                PhoneSidebarDock(service: service) { setCollapsed(false) }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: collapsed)
    }

    private func setCollapsed(_ collapsed: Bool) {
        withAnimation(.easeInOut(duration: 0.25)) {
            preference = (collapsed ? PhoneSidebarPreference.collapsed : .expanded).rawValue
        }
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

/// The expanded Phone section: Remote switch, live pairing QR code or the paired phone, and options.
struct PhoneSidebarCard: View {
    @ObservedObject var service: RemoteService
    @ObservedObject private var pairing: RemotePairing
    @ObservedObject private var power: MacPowerState
    let collapse: () -> Void
    @State private var now = Date()
    @State private var confirmingForget = false
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(service: RemoteService, collapse: @escaping () -> Void) {
        self.service = service
        pairing = service.pairing
        power = service.power
        self.collapse = collapse
    }

    private var enabled: Bool { service.settings.enabled }
    private var offer: RemotePairingOffer? { pairing.offer.flatMap { $0.expiresAt > now ? $0 : nil } }
    private var wantsOffer: Bool {
        PhoneSidebarState.wantsOffer(collapsed: false, enabled: enabled, running: service.running, paired: pairing.device != nil,
                                     locked: power.locked, loadError: pairing.loadError != nil)
    }
    private var statusLine: String { phoneStatusLine(service, offerShowing: offer != nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
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
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .onReceive(tick) { now = $0; replaceExpiredOffer() }
        .onAppear { refreshOffer() }
        .onChange(of: wantsOffer) { _, wants in
            if wants { refreshOffer() } else if pairing.offer != nil { pairing.closeOffer() }
        }
        .onDisappear { if wantsOffer, pairing.offer != nil { pairing.closeOffer() } }
    }

    private var header: some View {
        Button(action: collapse) {
            HStack(spacing: 10) {
                Image(systemName: "iphone").font(.title3).foregroundStyle(enabled ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Phone").font(.headline)
                    Text(statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Phone")
        .accessibilityValue(statusLine)
        .accessibilityHint("Collapses to the bottom of the sidebar")
        .accessibilityIdentifier("sidebar-phone-toggle")
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
                    Text("Key \(fingerprint)").font(.caption.monospaced()).textSelection(.enabled)
                        .accessibilityLabel("Mac key fingerprint \(fingerprint). The phone shows the same before pairing.")
                }
            } else if pairing.offer == nil {
                // Closed elsewhere (Settings › Cancel, Forget): wait to be asked again.
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
        _ = try? service.showPairingCode()
    }

    /// Replaces an expired code, but only while msgblast is the active app, so a hidden or
    /// background window does not keep minting codes. A code closed on purpose stays closed.
    private func replaceExpiredOffer() {
        guard pairing.offer != nil, NSApplication.shared.isActive else { return }
        refreshOffer()
    }
}

/// The collapsed Phone section: the icon with a status dot, docked below What's New.
struct PhoneSidebarDock: View {
    @ObservedObject var service: RemoteService
    @ObservedObject private var pairing: RemotePairing
    @ObservedObject private var power: MacPowerState
    let expand: () -> Void

    init(service: RemoteService, expand: @escaping () -> Void) {
        self.service = service
        pairing = service.pairing
        power = service.power
        self.expand = expand
    }

    private var status: PhoneSidebarStatus {
        PhoneSidebarState.status(enabled: service.settings.enabled, connected: pairing.device.map { service.connectedDeviceID == $0.id } ?? false)
    }
    private var dot: Color {
        switch status {
        case .connected: .green
        case .on: .orange
        case .off: Color.secondary.opacity(0.5)
        }
    }
    private var statusLine: String { phoneStatusLine(service, offerShowing: false) }

    var body: some View {
        Button(action: expand) {
            HStack(spacing: 10) {
                Image(systemName: "iphone").font(.title3).foregroundStyle(.secondary)
                    .overlay(alignment: .bottomTrailing) { Circle().fill(dot).frame(width: 7, height: 7).accessibilityHidden(true) }
                Text("Phone").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Phone")
        .accessibilityLabel("Phone")
        .accessibilityValue(statusLine)
        .accessibilityHint("Shows pairing and phone settings")
        .accessibilityIdentifier("sidebar-phone-dock")
    }
}
