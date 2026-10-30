import Foundation

/// Wire contract between the Mac (executor, source of truth) and a paired phone.
/// These types are a projection, not the persisted `state.json` models: they
/// evolve with `RemoteProtocol.version`, independently of Mac storage migrations.
public enum RemoteProtocol {
    /// Bumped for incompatible wire changes. Additive optional fields do not bump it.
    public static let version = 1
    /// The oldest client version the Mac still accepts.
    public static let minimumSupportedVersion = 1
    /// Largest framed payload either side accepts. Larger length prefixes close the stream.
    public static let maximumFrameBytes = 8 * 1024 * 1024
    /// Attachment uploads are split into chunks no larger than this.
    public static let maximumAttachmentChunkBytes = 256 * 1024
    /// Upper bound for one staged attachment.
    public static let maximumAttachmentBytes = 25 * 1024 * 1024
    /// Upper bound for one agent's artwork sent with `fetchAvatar` (256 × 256 PNG or JPEG).
    public static let maximumAvatarBytes = 64 * 1024
    /// Upper bound for one fetched attachment, so its base64 form fits in one frame.
    public static let maximumAttachmentFetchBytes = 5 * 1024 * 1024
    /// Bonjour service type advertised on the LAN listener only.
    public static let bonjourServiceType = "_msgblast._tcp"
    /// The one-time pairing code is valid for this long.
    public static let pairingCodeLifetime: TimeInterval = 120

    /// Shared encoder settings so both ends produce identical bytes for tests and signatures.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.dataEncodingStrategy = .base64
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        decoder.dataDecodingStrategy = .base64
        return decoder
    }
}

/// A string-backed value that tolerates values added by a newer peer.
public protocol RemoteOpenValue: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral where RawValue == String {
    init(rawValue: String)
}
public extension RemoteOpenValue {
    init(stringLiteral value: String) { self.init(rawValue: value) }
    init(from decoder: Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}
