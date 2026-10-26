import Foundation
import CryptoKit

public enum RemoteEndpointKind: String, Codable, Hashable, Sendable {
    case tailscale, lan
}

public struct RemoteEndpoint: Codable, Hashable, Sendable {
    public var host: String
    public var kind: RemoteEndpointKind
    public var interface: String?
    public init(host: String, kind: RemoteEndpointKind, interface: String? = nil) { self.host = host; self.kind = kind; self.interface = interface }
}

/// Shown by the Mac as a QR code. Contains no secret beyond the one-time code,
/// which expires after `RemoteProtocol.pairingCodeLifetime` and works once.
public struct RemotePairingOffer: Codable, Hashable, Sendable {
    public var version: Int
    public var macName: String
    public var variant: MacVariant
    public var endpoints: [RemoteEndpoint]
    public var port: UInt16
    /// SHA-256 of the TLS certificate's SubjectPublicKeyInfo, pinned by the phone.
    public var spkiSHA256: Data
    /// SHA-256 of the Mac identity key (x9.63), checked against the signed handshake.
    public var identityKeySHA256: Data
    public var code: String
    public var expiresAt: Date
    public init(version: Int = RemoteProtocol.version, macName: String, variant: MacVariant, endpoints: [RemoteEndpoint], port: UInt16, spkiSHA256: Data, identityKeySHA256: Data, code: String, expiresAt: Date) {
        self.version = version; self.macName = macName; self.variant = variant; self.endpoints = endpoints; self.port = port
        self.spkiSHA256 = spkiSHA256; self.identityKeySHA256 = identityKeySHA256; self.code = code; self.expiresAt = expiresAt
    }
    public static let scheme = "msgblast"
    /// `msgblast://pair?offer=<base64url JSON>`
    public var url: URL {
        let data = (try? RemoteProtocol.encoder().encode(self)) ?? Data()
        var components = URLComponents()
        components.scheme = Self.scheme; components.host = "pair"
        components.queryItems = [URLQueryItem(name: "offer", value: data.base64URLEncodedString())]
        return components.url!
    }
    public init(url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.scheme == Self.scheme, components.host == "pair",
              let value = components.queryItems?.first(where: { $0.name == "offer" })?.value, let data = Data(base64URLEncoded: value) else {
            throw RemoteProtocolError.invalidPairingOffer
        }
        self = try RemoteProtocol.decoder().decode(Self.self, from: data)
    }
    /// 128 random bits, base64url without padding.
    public static func makeCode() -> String {
        SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }.base64URLEncodedString()
    }
}

public extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    init?(base64URLEncoded value: String) {
        var text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        self.init(base64Encoded: text)
    }
}

public enum RemoteProtocolError: Error, Equatable, Sendable {
    case invalidPairingOffer
    case frameTooLarge(Int)
    case emptyFrame
    case unexpectedMessage(String)
    case authenticationFailed
    case replayOrReorder
    case unsupportedVersion(Int)
    case invalidKey
}
