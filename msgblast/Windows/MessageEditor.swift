import AppKit
import SwiftUI
import msgblastCore

struct MessageEditor: NSViewRepresentable {
    @Binding var text: String
    let accessibilityName: String
    let attachmentsEnabled: Bool
    let importAttachment: (AttachmentImport) -> Void
    let send: () -> Void
    var focusRequest: UUID? = nil
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MessageEditor
        var lastFocusRequest: UUID?
        private var measurements: [(text: String, width: CGFloat, size: CGSize)] = []
        init(_ parent: MessageEditor) { self.parent = parent }
        func measure(_ text: String, width: CGFloat) -> CGSize {
            if let cached = measurements.first(where: { $0.text == text && $0.width == width }) { return cached.size }
            let size = MessageTextMeasurement.size(text, width: width)
            if measurements.count == 2 { measurements.removeFirst() }
            measurements.append((text, width, size))
            return size
        }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            view.scrollRangeToVisible(view.selectedRange())
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        let view = AttachmentTextView()
        view.isRichText = false; view.drawsBackground = false; view.allowsUndo = true
        view.isHorizontallyResizable = false; view.isVerticallyResizable = true
        view.autoresizingMask = [.width]; view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.registerForDraggedTypes([.fileURL, .png, .tiff, .string])
        view.font = .systemFont(ofSize: 14); view.textColor = .labelColor
        view.insertionPointColor = .labelColor
        view.delegate = context.coordinator
        view.setAccessibilityLabel(accessibilityName)
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? AttachmentTextView else { return }
        if view.string != text { view.string = text }
        view.importAttachment = importAttachment; view.sendMessage = send; view.attachmentsEnabled = attachmentsEnabled
        if let focusRequest, context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { [weak view] in
                guard let view, let window = view.window else { return }
                window.makeFirstResponder(view)
                view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
            }
        }
        let size = NSSize(width: scroll.contentSize.width, height: max(22, context.coordinator.measure(text, width: scroll.contentSize.width).height))
        if view.frame.size != size { view.frame.size = size }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = max(1, proposal.width ?? 320)
        // SwiftUI also probes zero and infinite widths; a capped measurement keeps a long draft from typesetting one glyph per line.
        return CGSize(width: width, height: min(100, max(22, MessageTextMeasurement.size(text, width: width, maxHeight: 100).height)))
    }
}
