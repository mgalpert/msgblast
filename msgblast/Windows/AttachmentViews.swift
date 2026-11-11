import SwiftUI
import AppKit
import PhotosUI
@preconcurrency import QuickLookThumbnailing
import QuickLookUI
import UniformTypeIdentifiers
import msgblastCore

struct AttachmentView: View {
    let attachment: MessageAttachment
    var compact = false
    @State private var thumbnail: NSImage?
    @State private var preview: URL?
    private var imageSize: CGSize {
        guard !compact, let thumbnail, thumbnail.size.width > 0, thumbnail.size.height > 0 else {
            return CGSize(width: compact ? 76 : 220, height: compact ? 76 : 180)
        }
        let scale = min(220 / thumbnail.size.width, 180 / thumbnail.size.height)
        return CGSize(width: thumbnail.size.width * scale, height: thumbnail.size.height * scale)
    }
    var body: some View {
        Button { preview = attachment.url } label: {
            if attachment.isImage {
                Group {
                    if let thumbnail { Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: compact ? .fill : .fit) }
                    else { Image(systemName: "photo").font(.system(size: compact ? 24 : 48)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
                }
                .frame(width: imageSize.width, height: imageSize.height)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: compact ? 12 : 18))
                .clipShape(RoundedRectangle(cornerRadius: compact ? 12 : 18))
            } else {
                HStack(spacing: 10) {
                    Group {
                        if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit() }
                        else { Image(nsImage: NSWorkspace.shared.icon(forFile: attachment.url.path)).resizable().scaledToFit() }
                    }.frame(width: compact ? 30 : 42, height: compact ? 36 : 50)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(attachment.filename).font(.system(size: 13, weight: .medium)).lineLimit(2)
                        if let bytes = attachment.byteCount { Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                    }
                }.padding(12).frame(maxWidth: compact ? 190 : 240, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
            }
        }.buttonStyle(.plain)
        .accessibilityLabel("Preview \(attachment.filename)")
        .background(AttachmentPreviewPresenter(selection: $preview).frame(width: 0, height: 0))
        .task(id: attachment.id) {
            let request = QLThumbnailGenerator.Request(fileAt: attachment.url, size: CGSize(width: 440, height: 360), scale: 2, representationTypes: .all)
            if let result = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail = result.nsImage }
        }
    }
}

// Custom AppKit conversation windows need a responder that owns Quick Look's
// selected item. Keep that ownership independent of the current text selection.
private struct AttachmentPreviewPresenter: NSViewRepresentable {
    @Binding var selection: URL?
    func makeNSView(context: Context) -> PreviewAnchor { PreviewAnchor() }
    func updateNSView(_ view: PreviewAnchor, context: Context) {
        view.didEnd = { selection = nil }
        if let selection, view.item != selection { view.present(selection) }
    }
    static func dismantleNSView(_ view: PreviewAnchor, coordinator: ()) {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.currentController as AnyObject? === view else { return }
        panel.orderOut(nil)
    }

    final class PreviewAnchor: NSView, @preconcurrency QLPreviewPanelDataSource {
        var item: URL?
        var didEnd: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        func present(_ url: URL) {
            guard let window, let panel = QLPreviewPanel.shared() else { return }
            item = url
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(self)
            panel.makeKeyAndOrderFront(nil)
        }
        override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
            MainActor.assumeIsolated { item != nil }
        }
        override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
            MainActor.assumeIsolated {
                panel.dataSource = self
                panel.reloadData()
                panel.currentPreviewItemIndex = 0
            }
        }
        override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
            MainActor.assumeIsolated {
                panel.dataSource = nil
                item = nil
                let completion = didEnd
                DispatchQueue.main.async { completion?() }
            }
        }
        func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { item == nil ? 0 : 1 }
        func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { item.map { $0 as NSURL } }
    }
}

struct AttachmentComposer: View {
    var disabled: Bool
    let add: (AttachmentImport) async -> Void
    @Binding var importing: Bool
    @State private var filesPresented = false
    @State private var photosPresented = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var failure: String?
    var body: some View {
        Menu {
            Button { photosPresented = true } label: { Label("Photos", systemImage: "photo") }
            Button { filesPresented = true } label: { Label("Choose File…", systemImage: "doc") }
        } label: {
            Image(systemName: "plus").font(.system(size: Space.glyph, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: Space.fieldHeight, height: Space.fieldHeight)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .accessibilityLabel("Add photo or file").help("Add photo or file").disabled(disabled)
        .fileImporter(isPresented: $filesPresented, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                importing = true
                Task { await add(.files(urls)); importing = false }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { failure = error.localizedDescription }
            }
        }
        .photosPicker(isPresented: $photosPresented, selection: $photos, matching: .images)
        .onChange(of: photos) { _, selected in
            guard !selected.isEmpty else { return }
            importing = true
            Task {
                for item in selected {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { throw AppFailure.blocked("This photo could not be loaded.") }
                        let type = item.supportedContentTypes.first(where: { $0.conforms(to: .image) }) ?? .jpeg
                        await add(.image(data, filename: "Photo-\(UUID().uuidString).\(type.preferredFilenameExtension ?? "jpg")"))
                    } catch { failure = error.localizedDescription }
                }
                photos = []
                importing = false
            }
        }
        .alert("Attachment", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK") { failure = nil } } message: { Text(failure ?? "") }
    }
}

struct AttachmentDraftStrip: View {
    let attachments: [MessageAttachment]
    let disabled: Bool
    let remove: (String) -> Void
    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .center, spacing: 12) {
                ForEach(attachments) { file in
                    AttachmentView(attachment: file, compact: true)
                        .overlay(alignment: .topTrailing) {
                            Button { remove(file.id) } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 19, height: 19)
                            }.buttonStyle(.plain).background(.regularMaterial, in: Circle())
                                .offset(x: 5, y: -5).disabled(disabled).accessibilityLabel("Remove \(file.filename)")
                        }
                }
            }.padding(7)
        }.scrollIndicators(.hidden).frame(height: 90)
    }
}
