import Foundation

/// Which addresses the remote listener binds. Never loopback, never a wildcard.
public enum RemoteBindPolicy: String, Codable, CaseIterable, Sendable {
    /// Tailscale addresses when any exist, otherwise the LAN with Bonjour.
    case automatic
    case tailscaleOnly
    case tailscaleAndLAN
    case lanOnly
    public var title: String {
        switch self {
        case .automatic: "Tailscale if available, otherwise local network"
        case .tailscaleOnly: "Tailscale only"
        case .tailscaleAndLAN: "Tailscale and local network"
        case .lanOnly: "Local network only"
        }
    }
}

/// Mac-side remote control settings, `remote-settings.json` (0600). Off until the user turns it on.
public struct RemoteSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var bindPolicy = RemoteBindPolicy.automatic
    /// Lets a connected phone keep the Mac from idle-sleeping; sends always hold it while this is on.
    public var keepAwake = true
    /// Real iMessage sends are irreversible and the phone has Messages already: off by default.
    public var allowMessagesSends = false
    public var port: UInt16?
    public init() {}
    private enum CodingKeys: String, CodingKey { case enabled, bindPolicy, keepAwake, allowMessagesSends, port }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        bindPolicy = (try? c.decodeIfPresent(RemoteBindPolicy.self, forKey: .bindPolicy)) ?? .automatic
        keepAwake = try c.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? true
        allowMessagesSends = try c.decodeIfPresent(Bool.self, forKey: .allowMessagesSends) ?? false
        port = try c.decodeIfPresent(UInt16.self, forKey: .port)
    }

    public static func load(directory: URL) -> (RemoteSettings, String?) {
        let url = directory.appendingPathComponent("remote-settings.json")
        do {
            guard let data = try RemotePrivateFile.read(url) else { return (RemoteSettings(), nil) }
            return (try JSONDecoder().decode(RemoteSettings.self, from: data), nil)
        } catch {
            // Unreadable settings keep remote control off; the file is left in place.
            return (RemoteSettings(), RemoteStorageError.invalid(url.lastPathComponent).errorDescription)
        }
    }
    public func save(directory: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try RemotePrivateFile.write(try encoder.encode(self), to: directory.appendingPathComponent("remote-settings.json"))
    }
}
