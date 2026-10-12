import SwiftUI
import ScreenCaptureKit
import UniformTypeIdentifiers
import msgblastCore

@MainActor final class ChatCaptureLayout: ObservableObject {
    @Published var sidebarVisibility = NavigationSplitViewVisibility.all
    func setSidebar(_ visibility: NavigationSplitViewVisibility) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { sidebarVisibility = visibility }
    }
}

/// WindowServer captures the complete composited window, including SwiftUI and
/// out-of-process website surfaces. Enumerate only content available to this
/// process without screen-recording consent, then bind the exact app window.
@MainActor enum ChatWindowCapture {
    static func capture(_ window: NSWindow, title: String, layout: ChatCaptureLayout?) async throws -> NSImage {
        let sidebar = layout?.sidebarVisibility
        let originalFrame = window.frame
        let originalTitle = window.title
        let originalTitleVisibility = window.titleVisibility
        defer {
            window.title = originalTitle
            window.titleVisibility = originalTitleVisibility
            if let sidebar { layout?.setSidebar(sidebar) }
            window.setFrame(originalFrame, display: true)
        }
        layout?.setSidebar(.detailOnly)
        // Let SwiftUI commit the sidebar layout before capturing WindowServer.
        try await Task.sleep(for: .milliseconds(150))
        window.contentView?.layoutSubtreeIfNeeded()
        window.title = "msgblast · " + title
        window.titleVisibility = .visible
        window.displayIfNeeded()
        let content = try await SCShareableContent.currentProcess
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw CaptureError.unavailable
        }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let captured: CGImage
        if #available(macOS 26.0, *) {
            let configuration = SCScreenshotConfiguration()
            configuration.showsCursor = false
            configuration.ignoreShadows = false
            configuration.includeChildWindows = false
            configuration.dynamicRange = .sdr
            let output = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: configuration)
            guard let image = output.sdrImage else { throw CaptureError.unavailable }
            captured = image
        } else {
            let configuration = SCStreamConfiguration()
            configuration.width = Int(target.frame.width * window.backingScaleFactor)
            configuration.height = Int(target.frame.height * window.backingScaleFactor)
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = false
            configuration.captureResolution = .best
            captured = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        }
        return NSImage(cgImage: captured, size: NSSize(width: CGFloat(captured.width) / window.backingScaleFactor,
                                                     height: CGFloat(captured.height) / window.backingScaleFactor))
    }
    enum CaptureError: LocalizedError {
        case unavailable
        var errorDescription: String? { "The chat window could not be captured. Try again when it is visible." }
    }
}

private struct ChatWindowAnchor: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct ChatShareButton: View {
    @ObservedObject var model: AppModel
    var comparisonID: UUID?
    var captureLayout: ChatCaptureLayout? = nil
    @State private var anchor = NSView()
    @State private var image: NSImage?
    @State private var capturing = false
    @State private var error: String?
    @State private var showingPreview = false
    var body: some View {
        Button {
            guard let window = anchor.window else { error = ChatWindowCapture.CaptureError.unavailable.localizedDescription; return }
            capturing = true
            Task { @MainActor in
                defer { capturing = false }
                do {
                    let title = comparisonID.flatMap { model.comparison($0)?.title } ?? "Chat"
                    image = try await ChatWindowCapture.capture(window, title: title, layout: captureLayout)
                    showingPreview = true
                }
                catch { self.error = error.localizedDescription }
            }
        } label: { Label("Capture chat", systemImage: "camera").labelStyle(.iconOnly) }
        .accessibilityLabel("Capture chat")
        .help("Preview and share an image of this chat window")
        .disabled(capturing)
        .background(ChatWindowAnchor(view: anchor).frame(width: 0, height: 0))
        .sheet(isPresented: $showingPreview, onDismiss: { image = nil }) {
            if let image { ChatSharePreview(model: model, comparisonID: comparisonID, image: image) }
        }
        .alert("Capture chat", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
}

private struct ChatSharePreview: View {
    @ObservedObject var model: AppModel
    let comparisonID: UUID?
    let image: NSImage
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var copied = false
    private var hasRecording: Bool {
        guard let comparisonID else { return false }
        return model.performance.events.contains { $0.comparisonID == comparisonID.uuidString }
    }
    var body: some View {
        let recorded = hasRecording
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Share chat").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Visible chat window").font(.headline)
            Text("Review the image before sharing. It includes visible drafts and private conversations.")
                .font(.callout).foregroundStyle(.secondary)
            Image(nsImage: image).resizable().scaledToFit()
                .accessibilityLabel("Captured chat window preview")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
            HStack {
                Button(copied ? "Copied image" : "Copy image") {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.writeObjects([image])
                }
                Button("Save image…") { save() }
                ImageSharePicker(image: image)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("More than fits on screen?").font(.headline)
                    Text("Review the recorded conversation and create a scrollable link.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if let comparisonID {
                    ComparisonShareButton(model: model, comparisonID: comparisonID, title: "Share full chat by URL…")
                }
            }
            if !recorded {
                Text("URL sharing needs a recorded comparison. Enable recording in My Stats before starting a chat. Image sharing works without recording or an account.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .padding(24).frame(minWidth: 600, idealWidth: 800, minHeight: 540, idealHeight: 700)

    }
    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "msgblast-chat.png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else { throw ChatWindowCapture.CaptureError.unavailable }
                try png.write(to: url, options: .atomic)
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct ImageSharePicker: NSViewRepresentable {
    let image: NSImage
    func makeCoordinator() -> Coordinator { Coordinator(image: image) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "Share image…", target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.bezelStyle = .rounded
        return button
    }
    func updateNSView(_ nsView: NSButton, context: Context) {}
    @MainActor final class Coordinator: NSObject {
        let image: NSImage
        init(image: NSImage) { self.image = image }
        @objc func share(_ sender: NSButton) {
            NSSharingServicePicker(items: [image]).show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}
