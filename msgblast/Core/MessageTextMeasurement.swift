import AppKit

public enum MessageTextMeasurement {
    /// Lays out only as much text as fits in `maxHeight`, so a capped composer stays cheap however long its draft is.
    public static func size(_ text: String, width: CGFloat, maxHeight: CGFloat = .greatestFiniteMagnitude) -> CGSize {
        let storage = NSTextStorage(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container); storage.addLayoutManager(layout)
        if maxHeight < .greatestFiniteMagnitude {
            layout.ensureLayout(forBoundingRect: NSRect(x: 0, y: 0, width: container.size.width, height: maxHeight + 1), in: container)
        } else {
            layout.ensureLayout(for: container)
        }
        let size = layout.usedRect(for: container).size
        return CGSize(width: max(1, ceil(size.width)), height: max(17, ceil(size.height)))
    }
}
