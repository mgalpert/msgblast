import AppKit
import msgblastCore
import msgblastRemoteProtocol

/// Prepares a turn's recorded attachment for the phone: images as JPEG scaled to the size
/// asked for, other files whole when they fit.
enum RemoteAttachmentFiles {
    /// Thumbnail requests (up to this many bytes) get 320 px images; larger ones 1600 px.
    static let thumbnailBytes = 256 * 1024

    static func prepare(_ file: MessageAttachment, maxBytes: Int) -> RemoteAttachmentFetch {
        guard FileManager.default.isReadableFile(atPath: file.url.path) else { return .unavailable("This file is no longer on your Mac") }
        if file.isImage {
            guard let image = NSImage(contentsOf: file.url), let data = jpeg(image, longEdge: maxBytes <= thumbnailBytes ? 320 : 1600, maxBytes: maxBytes) else {
                return .unavailable("This image can't be read on your Mac")
            }
            return .data(data, type: "image/jpeg")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? Int) ?? Int(file.byteCount ?? 0)
        guard size <= maxBytes else { return .unavailable("Too large to open on the phone. Open it on your Mac") }
        guard let data = try? Data(contentsOf: file.url) else { return .unavailable("This file can't be read on your Mac") }
        return .data(data, type: file.mimeType ?? "application/octet-stream")
    }

    static func jpeg(_ image: NSImage, longEdge: CGFloat, maxBytes: Int) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, longEdge / CGFloat(max(cg.width, cg.height)))
        let width = max(1, Int(CGFloat(cg.width) * scale)), height = max(1, Int(CGFloat(cg.height) * scale))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.current?.cgContext.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        for quality in [0.8, 0.65, 0.5, 0.35, 0.2] {
            if let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]), data.count <= maxBytes { return data }
        }
        return nil
    }
}
