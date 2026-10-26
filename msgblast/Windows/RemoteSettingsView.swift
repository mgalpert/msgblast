import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import msgblastCore
import msgblastRemoteProtocol

/// Settings → Remote: turn phone control on, pair one phone with a QR code, and
/// choose the network, keep-awake and iMessage options.
struct RemoteSettingsView: View {
    @ObservedObject var service: RemoteService
    @ObservedObject private var pairing: RemotePairing
    @ObservedObject private var power: MacPowerState
    @State private var pairingError: String?
    @State private var confirmingReplacement = false
    @State private var confirmingForget = false
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(service: RemoteService) {
        self.service = service
        pairing = service.pairing
        power = service.power
    }

    var body: some View {
        content.onReceive(tick) { now = $0 }
    }

    @ViewBuilder private var content: some View {
        Toggle("Allow a paired phone to use msgblast on this Mac", isOn: Binding(get: { service.settings.enabled }, set: { service.setEnabled($0) }))
            .toggleStyle(.switch).accessibilityIdentifier("remote-enabled")
        LabeledContent("Status") { Text(service.statusText).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
        if service.settings.enabled {
            pairedPhone
            pairingSection
            Picker("Network", selection: Binding(get: { service.settings.bindPolicy }, set: { service.setBindPolicy($0) })) {
                ForEach(RemoteBindPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Keep this Mac awake while the phone is connected and during sends", isOn: Binding(get: { service.settings.keepAwake }, set: { service.setKeepAwake($0) }))
                .toggleStyle(.switch)
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Send iMessages from the phone", isOn: Binding(get: { service.settings.allowMessagesSends }, set: { service.setAllowMessagesSends($0) }))
                    .toggleStyle(.switch).accessibilityIdentifier("remote-allow-messages")
                Text("Off by default. An iMessage cannot be unsent, and your phone already has Messages.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if service.variant == .demo {
                Toggle("Listen on the network (Demo)", isOn: Binding(get: { service.demoNetworkAllowed }, set: { service.setDemoNetworkAllowed($0) }))
                    .toggleStyle(.switch)
                Text("Demo serves simulated agents. Without this, it opens no network port.").font(.caption).foregroundStyle(.secondary)
            }
            if let storage = service.identityStorage {
                LabeledContent("Mac identity") { Text(storage.label).foregroundStyle(storage == .sessionOnly ? .orange : .secondary) }
            }
            Text("Websites, apps and Messages stay on this Mac. The phone sees replies and sends through msgblast here; sign-in, permissions and keys never leave the Mac. Connections are encrypted end to end and work over Tailscale or your local network. A locked Mac shows as disconnected.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var pairedPhone: some View {
        if let device = pairing.device {
            LabeledContent("Paired phone") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(device.name)
                    Text(service.connectedDeviceID == device.id ? "Connected now" : device.lastSeen.map { "Last seen \($0.formatted(.relative(presentation: .named)))" } ?? "Not seen yet")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("Forget \(device.name)…", role: .destructive) { confirmingForget = true }
                .confirmationDialog("Forget \(device.name)?", isPresented: $confirmingForget) {
                    Button("Forget", role: .destructive) { service.forget() }
                } message: { Text("The phone disconnects and must be paired again.") }
        } else if let error = pairing.loadError {
            Text(error).foregroundStyle(.orange)
            Button("Forget the saved phone", role: .destructive) { service.forget() }
        }
    }

    @ViewBuilder private var pairingSection: some View {
        if let offer = pairing.offer, offer.expiresAt > now {
            HStack(alignment: .top, spacing: 16) {
                if let image = Self.qrImage(offer.url.absoluteString) {
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 168, height: 168)
                        .accessibilityLabel("Pairing QR code")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Scan with msgblast on your phone").font(.headline)
                    Text("Expires in \(Int(offer.expiresAt.timeIntervalSince(now)))s · works once").font(.caption).foregroundStyle(.secondary)
                    Text(offer.endpoints.isEmpty ? "No network address yet" : offer.endpoints.map { "\($0.host) (\($0.kind == .tailscale ? "Tailscale" : "local network"))" }.joined(separator: "\n"))
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Button("Copy pairing link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(offer.url.absoluteString, forType: .string)
                    }
                    Button("Cancel") { pairing.closeOffer() }
                }
            }
        } else {
            Button(pairing.device == nil ? "Pair a phone…" : "Pair a different phone…") {
                if pairing.device != nil { confirmingReplacement = true } else { open(confirm: false) }
            }
            .disabled(pairing.loadError != nil || power.locked)
            .confirmationDialog("Replace \(pairing.device?.name ?? "the paired phone")?", isPresented: $confirmingReplacement) {
                Button("Replace") { open(confirm: true) }
            } message: { Text("This Mac works with one phone. The current phone disconnects after the new one pairs.") }
            if let pairingError { Text(pairingError).font(.caption).foregroundStyle(.orange) }
        }
    }

    private func open(confirm: Bool) {
        do { try service.showPairingCode(confirmReplacement: confirm); pairingError = nil; now = Date() }
        catch { pairingError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    static func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
