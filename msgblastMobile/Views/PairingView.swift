import SwiftUI
import VisionKit
import msgblastMobileKit
import msgblastRemoteProtocol

/// Scan the QR code from msgblast Settings → Remote on the Mac (or paste its link),
/// confirm the Mac's name and key fingerprint, then pair.
struct PairingView: View {
    @ObservedObject var app: MobileApp
    @Binding var incomingLink: String?
    @State private var link = ""
    @State private var offer: RemotePairingOffer?
    @State private var error: String?
    @State private var pairing = false
    @State private var scanning = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Text("On your Mac, open msgblast Settings → Remote and choose Pair a phone.")
                if DataScannerViewController.isSupported {
                    Button { scanning = true } label: { Label("Scan the pairing code", systemImage: "qrcode.viewfinder") }
                }
                if offer == nil {
                    TextField("Or paste the msgblast://pair link", text: $link, axis: .vertical)
                        .lineLimit(1...3)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Continue") { read(link) }.disabled(link.isEmpty)
                } else {
                    Button("Use a different code") { offer = nil; link = "" }
                }
            }
            if let offer {
                Section("Pair with this Mac?") {
                    LabeledContent("Mac", value: offer.macName)
                    LabeledContent("Key", value: PairedMac.fingerprint(offer.identityKeySHA256)).font(.callout.monospaced())
                    if offer.variant == .demo { Text("Demo: simulated agents and messages.").font(.footnote).foregroundStyle(.secondary) }
                    Text("Check that the Mac shows the same name. The code works once and expires \(offer.expiresAt.formatted(.relative(presentation: .named))).")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button(pairing ? "Pairing…" : "Pair") { pair(offer) }.disabled(pairing)
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section {
                Text("Your phone talks only to your Mac, over your local network or Tailscale, encrypted end to end. Sign-ins, permissions and keys stay on the Mac.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Pair with your Mac")
        .sheet(isPresented: $scanning) { ScannerView { code in scanning = false; read(code) } }
        .onAppear { if let incomingLink { read(incomingLink); self.incomingLink = nil } }
        .onChange(of: incomingLink) { _, value in if let value { read(value); incomingLink = nil } }
    }

    private func read(_ text: String) {
        error = nil
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let parsed = try? RemotePairingOffer(url: url) else {
            error = "That is not a msgblast pairing code."; return
        }
        guard parsed.expiresAt > Date() else { error = "This code expired. Show a new one on your Mac."; return }
        link = url.absoluteString
        offer = parsed
    }

    private func pair(_ offer: RemotePairingOffer) {
        pairing = true
        Task {
            do {
                _ = try await app.pair(offer: offer, deviceName: UIDevice.current.name)
                dismiss()
            } catch { self.error = error.localizedDescription }
            pairing = false
        }
    }
}

/// VisionKit QR scanner. Unavailable in the simulator, where pasting the link works.
struct ScannerView: UIViewControllerRepresentable {
    var found: (String) -> Void
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }
    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(found: found) }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        init(found: @escaping (String) -> Void) { self.found = found }
        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let code) in items { if let value = code.payloadStringValue, value.hasPrefix("msgblast://") { scanner.stopScanning(); found(value); return } }
        }
    }
}
