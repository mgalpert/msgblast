import SwiftUI
import VisionKit
import msgblastMobileKit
import msgblastRemoteProtocol

/// Scan the QR code from msgblast › Settings › Remote on the Mac (or paste its link),
/// confirm the Mac's name and key fingerprint, then pair.
struct PairingView: View {
    @ObservedObject var app: MobileApp
    @Binding var incomingLink: String?
    /// Set when shown as a sheet over a paired Mac: closes it (Cancel, or after a pairing whose inbox is ready).
    var close: (() -> Void)? = nil
    @State private var link = ""
    @State private var offer: RemotePairingOffer?
    @State private var error: String?
    /// The last Pair attempt could not reach any of the Mac's addresses.
    @State private var unreachable = false
    @State private var pairing = false
    @State private var scanning = false
    @State private var pasting = false
    /// Opens with the Paste Link field shown.
    var startPasting = false

    var body: some View {
        Form {
            if let offer {
                Section {
                    LabeledContent("Mac", value: offer.macName)
                    LabeledContent("Key") {
                        Text(PairedMac.fingerprint(offer.identityKeySHA256)).font(.callout.monospaced()).foregroundStyle(.secondary)
                    }
                    if offer.variant == .demo { LabeledContent("Mode", value: "Demo") }
                } footer: {
                    Text("Expires in \(Self.minutesLeft(offer.expiresAt)) min")
                }
                Section {
                    Button { pair(offer) } label: {
                        HStack { Spacer(); if pairing { ProgressView() } else { Text("Pair").bold() }; Spacer() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .disabled(pairing)
                    errorRows
                    Button("Use Another Code") { self.offer = nil; link = ""; error = nil; unreachable = false }
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .disabled(pairing)
                }
            } else {
                Section {
                    VStack(spacing: Space.section) {
                        AppIconImage(size: Space.hero)
                        Text("Open msgblast › Settings › Remote on your Mac")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                Section {
                    Button { scanning = true } label: { Label("Scan Code", systemImage: "camera").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(!DataScannerViewController.isSupported)
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
                    if !pasting {
                        Button("Paste Link") { pasting = true }
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                    }
                }
                if pasting {
                    Section {
                        TextField("msgblast://pair…", text: $link)
                            .lineLimit(1)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .submitLabel(.continue)
                            .onSubmit { if !link.isEmpty { read(link) } }
                    }
                    Section {
                        // Same edges as Scan Code above.
                        Button { read(link) } label: { Text("Continue").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(link.isEmpty)
                            .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                }
                if error != nil { Section { errorRows } }
            }
        }
        .listSectionSpacing(Space.section)
        .safeAreaInset(edge: .bottom) {
            Label("Encrypted, device to device. Keys stay on your Mac.", systemImage: "lock.fill")
                .font(.footnote).foregroundStyle(.secondary)
                .padding(.bottom, Space.gap)
        }
        .navigationTitle("Pair Your Mac")
        .toolbar {
            if let close { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { close() }.disabled(pairing) } }
        }
        .sheet(isPresented: $scanning) { ScannerView { code in scanning = false; read(code) } }
        .onAppear {
            if startPasting { pasting = true }
            if let incomingLink { read(incomingLink); self.incomingLink = nil }
        }
        .onChange(of: incomingLink) { _, value in if let value { read(value); incomingLink = nil } }
    }

    @ViewBuilder private var errorRows: some View {
        if let error {
            VStack(alignment: .leading, spacing: Space.tight) {
                Text(error).foregroundStyle(.red)
                if unreachable { Text("Check Tailscale or Wi‑Fi").font(.caption).foregroundStyle(.secondary) }
            }
            .listRowBackground(Color.clear)
        }
    }

    static func minutesLeft(_ expiry: Date, now: Date = Date()) -> Int { max(1, Int((expiry.timeIntervalSince(now) / 60).rounded(.up))) }

    private func read(_ text: String) {
        error = nil
        unreachable = false
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let parsed = try? RemotePairingOffer(url: url) else {
            error = "Not a msgblast pairing code"; return
        }
        guard parsed.expiresAt > Date() else { error = "Code expired. Show a new one on your Mac"; return }
        link = url.absoluteString
        offer = parsed
    }

    private func pair(_ offer: RemotePairingOffer) {
        pairing = true
        error = nil
        unreachable = false
        Task {
            do {
                // As a sheet, close onto the new Mac's filled inbox. At the root, RootView
                // swaps to the inbox by itself once a Mac is paired.
                _ = try await app.pairAndWaitForInbox(offer: offer, deviceName: UIDevice.current.name)
                close?()
            } catch {
                // Stay on this screen so Pair can be tapped again; each try is a fresh race.
                self.unreachable = (error as? RaceFailure) != nil
                self.error = error.localizedDescription
            }
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
