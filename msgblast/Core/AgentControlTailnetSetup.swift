import Foundation

/// The block Settings copies into Grok Bot, and the three readiness lines on that card.
public enum AgentControlTailnetSetup {
    /// One block: title, server URL, and bearer header. No trailing newline.
    public static func text(url: String, key: String) -> String {
        ["msgblast MCP server for Grok Bot", "Server URL: \(url)", "Header: Authorization: Bearer \(key)"].joined(separator: "\n")
    }

    /// Tailscale, HTTPS certificates, then whether Grok Bot has called. Each line starts with ✓ or ⚠︎.
    public static func lines(magicName: String?, httpsEnabled: Bool, grokBotPeer: Bool, lastCalled: Date?, now: Date = Date()) -> [String] {
        let tailscale = mark(magicName.map { !$0.isEmpty } ?? false, magicName.flatMap { $0.isEmpty ? nil : "Connected as \($0)" } ?? "Tailscale isn't connected on this Mac.")
        let https = mark(httpsEnabled, httpsEnabled
            ? "HTTPS certificates are on for this tailnet."
            : "HTTPS certificates are off for this tailnet. If Grok Bot asks for an https:// address, an admin can turn them on in the Tailscale admin console under DNS.")
        let seen: String
        if let lastCalled {
            seen = mark(true, "Grok Bot last called \(relative(lastCalled, now: now)).")
        } else if grokBotPeer {
            seen = mark(false, "Grok Bot hasn't called msgblast yet. A Grok Bot device is on your tailnet.")
        } else {
            seen = mark(false, "Grok Bot hasn't called msgblast yet. No Grok Bot device on your tailnet yet — connect it in Grok Bot: Connect apps → Your plugins → Tailscale → Authenticate.")
        }
        return [tailscale, https, seen]
    }

    private static func mark(_ ok: Bool, _ text: String) -> String {
        (ok ? "\u{2713} " : "\u{26A0}\u{FE0E} ") + text
    }

    private static func relative(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date).rounded(.down))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago" }
        let hours = minutes / 60
        if hours < 24 { return hours == 1 ? "1 hour ago" : "\(hours) hours ago" }
        let days = hours / 24
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }
}

/// `tailscale status --json`: this Mac's MagicDNS name, whether HTTPS certificates are on, and whether a Grok Bot device is a peer.
public enum AgentControlTailnetStatus {
    /// Nil when `data` is not a JSON object. A trailing dot on `Self.DNSName` is removed. `CertDomains` must be a non-empty array.
    public static func parse(_ data: Data) -> (magicName: String?, httpsEnabled: Bool, grokBotPeer: Bool)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (magicName(root["Self"]), httpsEnabled(root["CertDomains"]), grokBotPeer(root["Peer"]))
    }

    private static func magicName(_ value: Any?) -> String? {
        guard let node = value as? [String: Any], var name = node["DNSName"] as? String else { return nil }
        if name.hasSuffix(".") { name.removeLast() }
        return name.isEmpty ? nil : name
    }

    private static func httpsEnabled(_ value: Any?) -> Bool {
        guard let domains = value as? [Any] else { return false }
        return !domains.isEmpty
    }

    private static func grokBotPeer(_ value: Any?) -> Bool {
        guard let peers = value as? [String: Any] else { return false }
        for peer in peers.values {
            guard let node = peer as? [String: Any] else { continue }
            let names = [node["HostName"] as? String, node["DNSName"] as? String].compactMap { $0 }
            if names.contains(where: { $0.range(of: "grokbot", options: .caseInsensitive) != nil }) { return true }
        }
        return false
    }
}
