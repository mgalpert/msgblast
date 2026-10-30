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

    /// A square 256 × 256 image under `maximumAvatarBytes`. Native app icons (icns) are
    /// cropped to their tile and masked to a circle, as the Mac's Grok Bot avatar is;
    /// other artwork is center-cropped to fill.
    static func normalize(_ data: Data) -> Data? {
        guard let source = NSImage(data: data), source.size.width > 0, source.size.height > 0 else { return nil }
        let isIcon = data.starts(with: [0x69, 0x63, 0x6e, 0x73])
        let pixels = Int(side)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        let bounds = NSRect(x: 0, y: 0, width: side, height: side)
        let size = source.size
        if isIcon {
            NSBezierPath(ovalIn: bounds).addClip()
            NSColor(calibratedWhite: 0.2, alpha: 1).setFill()
            bounds.fill()
            source.draw(in: bounds, from: NSRect(origin: .zero, size: size).insetBy(dx: size.width * 0.1, dy: size.height * 0.1), operation: .sourceOver, fraction: 1)
        } else {
            let edge = min(size.width, size.height)
            source.draw(in: bounds, from: NSRect(x: (size.width - edge) / 2, y: (size.height - edge) / 2, width: edge, height: edge), operation: .sourceOver, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()
        if let png = bitmap.representation(using: .png, properties: [:]), png.count <= RemoteProtocol.maximumAvatarBytes { return png }
        for quality in [0.85, 0.7, 0.5, 0.35] {
            if let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]), jpeg.count <= RemoteProtocol.maximumAvatarBytes { return jpeg }
        }
        return nil
    }
}
