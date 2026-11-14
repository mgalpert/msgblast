import Foundation

/// The block Settings copies into Grok Bot, and the three readiness lines on that card.
public enum AgentControlTailnetSetup {
    /// One block: title, server URL, and bearer header. No trailing newline.
    public static func text(url: String, key: String, client: String = AgentControlTailnet.grokBotClient) -> String {
        let name = client.hasSuffix(" (Tailscale)") ? String(client.dropLast(" (Tailscale)".count)) : client
        return ["msgblast MCP server for \(name)", "Server URL: \(url)", "Header: Authorization: Bearer \(key)"].joined(separator: "\n")
    }

    /// Tailscale, HTTPS certificates, then whether Grok Bot has called. Each line starts with ✓ or ⚠︎,
    /// except certificates off, which is information only (ℹ︎): msgblast serves http:// either way.
    public static func lines(magicName: String?, httpsEnabled: Bool, grokBotPeer: Bool, lastCalled: Date?, now: Date = Date()) -> [String] {
        let tailscale = mark(magicName.map { !$0.isEmpty } ?? false, magicName.flatMap { $0.isEmpty ? nil : "Connected as \($0)" } ?? "Tailscale isn't connected on this Mac.")
        let https = httpsEnabled
            ? mark(true, "HTTPS certificates are on for this tailnet.")
            : "\u{2139}\u{FE0E} HTTPS certificates are off for this tailnet. Nothing to change: msgblast uses http://, and Tailscale encrypts the connection."
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

/// Read-only macOS Application Firewall state. msgblast never changes firewall settings.
public enum AgentControlFirewall {
    public enum State: Equatable, Sendable {
        case off, onAllowed, onBlocked, onUnknown, blockAll
    }

    /// `globalState` is `socketfilterfw --getglobalstate`. `appBlocked` is `--getappblocked`, or nil when that query failed.
    /// State 2 is block-all. Any other app text, including nil, is unknown while the firewall is on.
    public static func parse(globalState: String, appBlocked: String?) -> State {
        if globalState.contains("State = 2") { return .blockAll }
        if globalState.contains("State = 0") { return .off }
        guard globalState.contains("State = 1") else { return .onUnknown }
        guard let appBlocked else { return .onUnknown }
        if appBlocked.contains("is blocked") { return .onBlocked }
        if appBlocked.contains("is permitted") { return .onAllowed }
        return .onUnknown
    }

    /// Nil when the firewall is off. Marks match the other Tailscale readiness lines.
    public static func line(_ state: State) -> String? {
        switch state {
        case .off:
            return nil
        case .onAllowed:
            return "\u{2713} The macOS firewall allows msgblast incoming connections."
        case .onBlocked:
            return "\u{26A0}\u{FE0E} The macOS firewall blocks msgblast, so agents on other devices can't reach it. Allow msgblast in System Settings → Network → Firewall → Options."
        case .onUnknown:
            return "\u{26A0}\u{FE0E} The macOS firewall is on. If agents on other devices can't connect, allow msgblast in System Settings → Network → Firewall → Options."
        case .blockAll:
            return "\u{26A0}\u{FE0E} The macOS firewall blocks all incoming connections, so agents on other devices can't reach msgblast. Turn off \"Block all incoming connections\" in System Settings → Network → Firewall → Options."
        }
    }
}
