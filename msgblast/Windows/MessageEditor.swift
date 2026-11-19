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
    static let maxHeight: CGFloat = 100
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MessageEditor
        var lastFocusRequest: UUID?
        init(_ parent: MessageEditor) { self.parent = parent }
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
        // The text view grows to fit its own incremental layout, so the draft is never re-typeset from scratch per keystroke.
        view.isHorizontallyResizable = false; view.isVerticallyResizable = true
        view.minSize = NSSize(width: 0, height: 22); view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
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
        if view.frame.width != scroll.contentSize.width { view.frame.size.width = scroll.contentSize.width }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = max(1, proposal.width ?? 320)
        // SwiftUI also probes zero and infinite widths; a capped measurement keeps a long draft from typesetting one glyph per line.
        return CGSize(width: width, height: min(Self.maxHeight, max(22, MessageTextMeasurement.size(text, width: width, maxHeight: Self.maxHeight).height)))
    }
}
