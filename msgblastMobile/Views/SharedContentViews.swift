import QuickLook
import SafariServices
import SwiftUI
import UniformTypeIdentifiers
import msgblastMobileKit

/// Something shared in a conversation that the phone opens: a link in Safari, a photo in
/// the viewer, a document in Quick Look.
enum SharedOpen: Identifiable, Equatable {
    case link(URL)
    case photo(SharedAttachment)
    case document(SharedAttachment)
    var id: String {
        switch self {
        case .link(let url): "link:\(url.absoluteString)"
        case .photo(let file): "photo:\(file.id)"
        case .document(let file): "document:\(file.id)"
        }
    }
}

/// Presents links, photos and documents opened from a thread or its Details.
struct SharedContentPresentation: ViewModifier {
    @ObservedObject var app: MobileApp
    @Binding var opening: SharedOpen?
    @State private var link: URL?
    @State private var photo: SharedAttachment?
    @State private var document: URL?
    @State private var problem: String?

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return .systemAction }
                opening = .link(url)
                return .handled
            })
            .onChange(of: opening) { _, value in
                guard let value else { return }
                opening = nil
                switch value {
                case .link(let url): link = url
                case .photo(let file): photo = file
                case .document(let file): Task { await open(file) }
                }
            }
            .sheet(item: Binding(get: { link.map(IdentifiedURL.init) }, set: { link = $0?.url })) { SafariView(url: $0.url).ignoresSafeArea() }
            .fullScreenCover(item: $photo) { PhotoViewer(app: app, file: $0) }
            .sheet(item: Binding(get: { document.map(IdentifiedURL.init) }, set: { document = $0?.url })) { QuickLookView(url: $0.url).ignoresSafeArea() }
            .alert(problem ?? "", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) { Button("OK", role: .cancel) {} }
    }

    /// Fetches a document within the cap to a temporary file, then previews it.
    private func open(_ file: SharedAttachment) async {
        switch await app.fetchAttachment(turnID: file.turnID, index: file.index, thumbnail: false) {
        case .data(let data, _):
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shared-\(abs(file.id.hashValue))", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent((file.filename as NSString).lastPathComponent)
            do { try data.write(to: url, options: .atomic); document = url } catch { problem = "Couldn't open this file" }
        case .unsupported: problem = "Open on your Mac"
        case .unavailable(let reason): problem = reason
        case .notConnected: problem = "Not connected"
        }
    }
}

private struct IdentifiedURL: Identifiable { var url: URL; var id: String { url.absoluteString } }

extension View {
    func sharedContentPresentation(_ app: MobileApp, opening: Binding<SharedOpen?>) -> some View {
        modifier(SharedContentPresentation(app: app, opening: opening))
    }
}

struct SafariView: UIViewControllerRepresentable {
    var url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

struct QuickLookView: UIViewControllerRepresentable {
    var url: URL
    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        return UINavigationController(rootViewController: preview)
    }
    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

/// A photo's thumbnail, fetched from the Mac on demand and cached; a symbol when the Mac
/// cannot send it.
struct AttachmentThumbnail: View {
    @ObservedObject var app: MobileApp
    var file: SharedAttachment
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        ZStack {
            Rectangle().fill(Color(.secondarySystemFill))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if failed {
                Image(systemName: "photo").foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .clipped()
        .task(id: file.id) {
            if case .data(let data, _) = await app.fetchAttachment(turnID: file.turnID, index: file.index, thumbnail: true), let decoded = UIImage(data: data) {
                image = decoded
            } else {
                failed = true
            }
        }
        .accessibilityLabel(file.filename)
    }
}

/// A full-screen photo with pinch zoom and a share sheet.
struct PhotoViewer: View {
    @ObservedObject var app: MobileApp
    var file: SharedAttachment
    @State private var image: UIImage?
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image { ZoomableImage(image: image).ignoresSafeArea() }
                else if let problem { Text(problem).foregroundStyle(.white.opacity(0.8)) }
                else { ProgressView().tint(.white) }
            }
            .navigationTitle(file.filename)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if let image {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: Image(uiImage: image), preview: SharePreview(file.filename, image: Image(uiImage: image)))
                    }
                }
            }
        }
        .task {
            switch await app.fetchAttachment(turnID: file.turnID, index: file.index, thumbnail: false) {
            case .data(let data, _): image = UIImage(data: data); if image == nil { problem = "This photo can't be shown" }
            case .unsupported: problem = "Open on your Mac"
            case .unavailable(let reason): problem = reason
            case .notConnected: problem = "Not connected"
            }
        }
    }
}

/// UIScrollView zoom for one image: pinch, double-tap and pan.
struct ZoomableImage: UIViewRepresentable {
    var image: UIImage
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.delegate = context.coordinator
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        view.frame = scroll.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.addSubview(view)
        context.coordinator.imageView = view
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.zoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }
    func updateUIView(_ scroll: UIScrollView, context: Context) { context.coordinator.imageView?.image = image }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        @objc func zoom(_ tap: UITapGestureRecognizer) {
            guard let scroll = tap.view as? UIScrollView else { return }
            scroll.setZoomScale(scroll.zoomScale > 1 ? 1 : 2.5, animated: true)
        }
    }
}

/// Links in message text become tappable, in the bubble's own color.
enum LinkedText {
    static func attributed(_ text: String, mine: Bool) -> AttributedString {
        var result = AttributedString(text)
        for link in SharedContent.links(in: text) {
            guard let lower = AttributedString.Index(link.range.lowerBound, within: result),
                  let upper = AttributedString.Index(link.range.upperBound, within: result) else { continue }
            result[lower..<upper].link = link.url
            result[lower..<upper].underlineStyle = .single
            if mine { result[lower..<upper].foregroundColor = .white }
        }
        return result
    }
}
