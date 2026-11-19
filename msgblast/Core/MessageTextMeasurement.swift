import AppKit

public enum MessageTextMeasurement {
    /// With a `maxHeight`, growing prefixes are measured first: a prefix taller than the cap proves the whole draft is, without typesetting all of it.
    public static func size(_ text: String, width: CGFloat, maxHeight: CGFloat = .greatestFiniteMagnitude) -> CGSize {
        if maxHeight < .greatestFiniteMagnitude {
            let length = text.count
            var prefix = 512
            while prefix < length {
                let size = layoutSize(String(text.prefix(prefix)), width: width)
                if size.height > maxHeight { return size }
                prefix *= 4
            }
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
