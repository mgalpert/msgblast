import AppKit
import CryptoKit
import msgblastCore
import msgblastRemoteProtocol

/// The artwork the Mac shows for each agent (`AgentArtwork`), normalized for the phone
/// and addressed by content: `sha256:<hex>` of the normalized bytes. Bytes leave the Mac
/// only through `fetchAvatar` on the paired, encrypted channel.
@MainActor
final class RemoteAvatars {
    static let side: CGFloat = 256
    private unowned let model: AppModel
    /// The last source each agent had and the reference it normalized to.
    private var bySource: [String: (source: Data, ref: String?)] = [:]
    private var images: [String: Data] = [:]

    init(model: AppModel) { self.model = model }

    /// The reference for an agent's current artwork, or nil when it has none.
    func ref(for agentID: String) -> String? {
        guard let source = source(agentID) else { return nil }
        if let cached = bySource[agentID], cached.source == source { return cached.ref }
        let ref = Self.normalize(source).map { data -> String in
            let ref = Self.ref(data)
            images[ref] = data
            return ref
        }
        bySource[agentID] = (source, ref)
        return ref
    }

    func data(for ref: String) -> Data? { images[ref] }

    private func source(_ agentID: String) -> Data? {
        if let member = RemoteAgentIDs.messagesAgent(agentID) {
            guard let agent = model.state.agents.first(where: { $0.id == member }) else { return nil }
            return AgentArtwork.avatar(for: agent, name: agent.name)
        }
        guard let session = model.webAgents.sessions.first(where: { $0.id.id == agentID }) else { return nil }
        return AgentArtwork.agent(for: session).avatar
    }

    static func ref(_ data: Data) -> String { "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// The phone's avatar for this artwork, under `maximumAvatarBytes`:
    /// - Artwork with transparency (PDF marks, transparent PNGs, app icons with their margins)
    ///   keeps its alpha: transparent margins are trimmed and the mark is fitted into the
    ///   256 px box with at most 8 % padding, never masked and never placed on a color.
    /// - Opaque full-bleed artwork (contact photos, square app-store icons, Muse's photo)
    ///   is center-cropped to a 256 px square; the phone clips it to a circle.
    /// The reference is a hash of these bytes, so a change in treatment is a new reference.
    static func normalize(_ data: Data) -> Data? {
        guard let source = NSImage(data: data), source.size.width > 0, source.size.height > 0,
              let probe = rgba(source, width: 256, height: Int(max(1, (256 * source.size.height / source.size.width).rounded()))) else { return nil }
        if let bounds = opaqueBounds(probe) {
            // Transparent artwork: trim to the visible mark, fit with up to 8 % padding.
            let scaleX = source.size.width / CGFloat(probe.pixelsWide), scaleY = source.size.height / CGFloat(probe.pixelsHigh)
            let crop = NSRect(x: CGFloat(bounds.minX) * scaleX, y: source.size.height - CGFloat(bounds.maxY) * scaleY,
                              width: CGFloat(bounds.width) * scaleX, height: CGFloat(bounds.height) * scaleY)
            for pixels in [256, 192, 128] {
                let box = CGFloat(pixels) * 0.84, scale = box / max(crop.width, crop.height)
                let target = NSRect(x: (CGFloat(pixels) - crop.width * scale) / 2, y: (CGFloat(pixels) - crop.height * scale) / 2,
                                    width: crop.width * scale, height: crop.height * scale)
                guard let bitmap = draw(source, from: crop, into: target, pixels: pixels) else { return nil }
                if let png = bitmap.representation(using: .png, properties: [:]), png.count <= RemoteProtocol.maximumAvatarBytes { return png }
            }
            return nil
        }
        // Opaque artwork: a full square, no mask and no backing.
        let size = source.size, edge = min(size.width, size.height)
        let crop = NSRect(x: (size.width - edge) / 2, y: (size.height - edge) / 2, width: edge, height: edge)
        guard let bitmap = draw(source, from: crop, into: NSRect(x: 0, y: 0, width: side, height: side), pixels: Int(side)) else { return nil }
        for quality in [0.85, 0.7, 0.5, 0.35] {
            if let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]), jpeg.count <= RemoteProtocol.maximumAvatarBytes { return jpeg }
        }
        return nil
    }

    private static func draw(_ source: NSImage, from crop: NSRect, into target: NSRect, pixels: Int) -> NSBitmapImageRep? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: target, from: crop, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    private static func rgba(_ source: NSImage, width: Int, height: Int) -> NSBitmapImageRep? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        source.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    /// The box around pixels that are not (nearly) transparent, in top-left pixel
    /// coordinates; nil when the artwork has no transparency to speak of (opaque art).
    static func opaqueBounds(_ bitmap: NSBitmapImageRep) -> (minX: Int, minY: Int, maxX: Int, maxY: Int, width: Int, height: Int)? {
        guard let data = bitmap.bitmapData else { return nil }
        let width = bitmap.pixelsWide, height = bitmap.pixelsHigh, row = bitmap.bytesPerRow
        var minX = width, minY = height, maxX = -1, maxY = -1, transparent = 0
        for y in 0..<height {
            for x in 0..<width {
                let alpha = data[y * row + x * 4 + 3]
                if alpha < 250 { transparent += 1 }
                if alpha > 8 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
            }
        }
        // Under 1 % transparent pixels (antialiased edges) still counts as opaque artwork.
        guard maxX >= 0, transparent * 100 > width * height else { return nil }
        return (minX, minY, maxX + 1, maxY + 1, maxX + 1 - minX, maxY + 1 - minY)
    }
}
