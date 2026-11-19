import AppKit

public enum MessageTextMeasurement {
    /// With a `maxHeight`, growing prefixes are measured first: a prefix taller than the cap proves the whole draft is, without typesetting all of it.
    public static func size(_ text: String, width: CGFloat, maxHeight: CGFloat = .greatestFiniteMagnitude) -> CGSize {
        guard maxHeight < .greatestFiniteMagnitude else { return layoutSize(text, width: width) }
        // An unbounded probe width would set a long paragraph as one line; no composer is wider than this.
        let width = min(width, 4096)
        var prefix = 512
        while true {
            let head = text.prefix(prefix)
            if head.endIndex == text.endIndex { break }
            let size = layoutSize(String(head), width: width)
            if size.height > maxHeight { return size }
            prefix *= 4
        }
        return layoutSize(text, width: width)
    }

    private static func layoutSize(_ text: String, width: CGFloat) -> CGSize {
        let storage = NSTextStorage(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container); storage.addLayoutManager(layout); layout.ensureLayout(for: container)
        let size = layout.usedRect(for: container).size
        return CGSize(width: max(1, ceil(size.width)), height: max(17, ceil(size.height)))
    }
}
