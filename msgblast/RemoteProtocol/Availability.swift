import Foundation

/// The product a user recognizes, independent of how msgblast reaches it.
public struct AgentProduct: RemoteOpenValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let chatgpt: Self = "chatgpt"
    public static let claude: Self = "claude"
    public static let muse: Self = "muse"
    public static let grok: Self = "grok"
    public static let grokBot: Self = "grokBot"
    public static let dots: Self = "dots"
    public static let os3: Self = "os3"
    public static let hark: Self = "hark"
    public static let wabi: Self = "wabi"
    public static let gemini: Self = "gemini"
    public static let messages: Self = "messages"
}

/// How msgblast reaches the product. Histories are never merged across forms.
public enum AgentForm: String, Codable, Hashable, Sendable, CaseIterable {
    case website, macApp, cli, webhookBot, messages
    public var label: String {
        switch self {
        case .website: "Web"
        case .macApp: "Mac app"
        case .cli: "CLI"
        case .webhookBot: "Webhook"
        case .messages: "Messages"
        }
    }
}

public struct AgentCapabilities: Codable, Hashable, Sendable {
    public var sharedSend: Bool
    public var privateSend: Bool
    public var attachments: Bool
    public var namedCopies: Bool
    public var endConversation: Bool
    public var sharesOneConversation: Bool
    public init(sharedSend: Bool, privateSend: Bool, attachments: Bool, namedCopies: Bool, endConversation: Bool, sharesOneConversation: Bool) {
        self.sharedSend = sharedSend; self.privateSend = privateSend; self.attachments = attachments
        self.namedCopies = namedCopies; self.endConversation = endConversation; self.sharesOneConversation = sharesOneConversation
    }
}

/// One answer to "can this agent take a message now?".
public enum AgentReadiness: Codable, Hashable, Sendable {
    /// A send will run without changing anything else on the Mac.
    case ready
    /// A send will open (and activate) the Mac app first. The phone says so before sending.
    case readyWillLaunch
    /// Temporarily occupied; `detail` is user-facing.
    case busy(detail: String)
    /// Configured but a condition must be fixed first (see `reasons`).
    case blocked
    /// Not offered, disabled, or not installed (see `reasons`).
    case unavailable

    public var state: String {
        switch self { case .ready: "ready"; case .readyWillLaunch: "readyWillLaunch"; case .busy: "busy"; case .blocked: "blocked"; case .unavailable: "unavailable" }
    }
    public var acceptsSend: Bool { self == .ready || self == .readyWillLaunch }
    private enum CodingKeys: String, CodingKey { case state, detail }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .state) {
        case "ready": self = .ready
        case "readyWillLaunch": self = .readyWillLaunch
        case "busy": self = .busy(detail: try c.decodeIfPresent(String.self, forKey: .detail) ?? "")
        case "blocked": self = .blocked
        // A newer state is never treated as sendable by an older peer.
        default: self = .unavailable
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(state, forKey: .state)
        if case .busy(let detail) = self { try c.encode(detail, forKey: .detail) }
    }
}

/// Typed reason codes. Each one is traceable to an existing Mac signal.
public struct AvailabilityReasonCode: RemoteOpenValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let notInstalled: Self = "notInstalled"
    public static let appNotRunning: Self = "appNotRunning"
    public static let appVersionUnsupported: Self = "appVersionUnsupported"
    public static let windowMissingOrAmbiguous: Self = "windowMissingOrAmbiguous"
    public static let dialogOpen: Self = "dialogOpen"
    public static let signedOut: Self = "signedOut"
    public static let signInUnknown: Self = "signInUnknown"
    public static let disabled: Self = "disabled"
    public static let notOfferedInBuild: Self = "notOfferedInBuild"
    public static let noSharedSends: Self = "noSharedSends"
    public static let permissionMissing: Self = "permissionMissing"
    public static let automationNeedsMessagesOpen: Self = "automationNeedsMessagesOpen"
    public static let driverUnavailable: Self = "driverUnavailable"
    public static let storageFailed: Self = "storageFailed"
    public static let incompleteRequestBlocking: Self = "incompleteRequestBlocking"
    public static let sendInFlight: Self = "sendInFlight"
    public static let queuedBehindDesktopSend: Self = "queuedBehindDesktopSend"
    public static let cliSignedOut: Self = "cliSignedOut"
    public static let cliVersionUnsupported: Self = "cliVersionUnsupported"
    public static let webhookNotConfigured: Self = "webhookNotConfigured"
    public static let tunnelStarting: Self = "tunnelStarting"
    public static let messagesDatabaseUnavailable: Self = "messagesDatabaseUnavailable"
    public static let conversationUnroutable: Self = "conversationUnroutable"
    public static let macLocked: Self = "macLocked"
    public static let macDisplayAsleep: Self = "macDisplayAsleep"
    /// Added in phase 1: a Mac app agent has no saved conversation binding yet (Connect on the Mac).
    public static let notConnected: Self = "notConnected"
    /// Added in phase 1: iMessage sends from the phone are turned off in Settings → Remote.
    public static let remoteMessagesOff: Self = "remoteMessagesOff"
    /// Added in phase 3: a Mac app agent's last connection check failed; the Mac's pane offers Reconnect.
    public static let reconnectNeeded: Self = "reconnectNeeded"
    /// Added in phase 3: a Mac app's accessibility tree could not be read completely, so no input was sent.
    public static let controlsUpdating: Self = "controlsUpdating"
    /// Added in phase 3: a Mac app is not connected or its last check failed, and a send prepares it first.
    public static let preparesOnSend: Self = "preparesOnSend"
}

public enum MacPermission: String, Codable, Hashable, Sendable, CaseIterable {
    case fullDiskAccess, contacts, automation, accessibility, screenRecording
}

public enum FixLocation: String, Codable, Hashable, Sendable {
    case mac, phone, none
}

public struct AvailabilityReason: Codable, Hashable, Sendable {
    public var code: AvailabilityReasonCode
    public var userText: String
    public var fixOn: FixLocation
    public var permission: MacPermission?
    public var attemptID: String?
    public var detail: String?
    public init(code: AvailabilityReasonCode, userText: String, fixOn: FixLocation, permission: MacPermission? = nil, attemptID: String? = nil, detail: String? = nil) {
        self.code = code; self.userText = userText; self.fixOn = fixOn; self.permission = permission; self.attemptID = attemptID; self.detail = detail
    }
}

public enum AvailabilitySource: String, Codable, Hashable, Sendable {
    /// Read from a probe in the current availability pass.
    case live
    /// Last value an explicit Mac path recorded; not re-checked without side effects.
    case lastKnown
}

public struct AgentAvailability: Codable, Hashable, Sendable, Identifiable {
    public var id: String { agentID }
    /// `WebAgentID.id` for website/app/CLI/bot agents, `messages:<uuid>` for Messages agents.
    public var agentID: String
    public var product: AgentProduct
    public var form: AgentForm
    public var displayName: String
    /// `sha256:<hex>` of the artwork the Mac shows for this agent; fetch it with `fetchAvatar`.
    /// Older Macs sent other strings here; phones only fetch `sha256:` references.
    public var avatarRef: String?
    public var visibleInGrid: Bool
    public var selectedForSharedSend: Bool
    public var capabilities: AgentCapabilities
    public var readiness: AgentReadiness
    public var reasons: [AvailabilityReason]
    public var observedAt: Date
    public var source: AvailabilitySource
    public init(agentID: String, product: AgentProduct, form: AgentForm, displayName: String, avatarRef: String? = nil, visibleInGrid: Bool, selectedForSharedSend: Bool, capabilities: AgentCapabilities, readiness: AgentReadiness, reasons: [AvailabilityReason], observedAt: Date, source: AvailabilitySource) {
        self.agentID = agentID; self.product = product; self.form = form; self.displayName = displayName; self.avatarRef = avatarRef
        self.visibleInGrid = visibleInGrid; self.selectedForSharedSend = selectedForSharedSend; self.capabilities = capabilities
        self.readiness = readiness; self.reasons = reasons; self.observedAt = observedAt; self.source = source
    }
    /// "ChatGPT · Mac app". Messages agents show their contact name alone.
    public var formLabel: String { form == .messages || displayName.hasSuffix(form.label) ? displayName : "\(displayName) · \(form.label)" }
    /// Equality ignoring `observedAt`, so a repeated probe does not emit an event.
    public func sameContent(as other: AgentAvailability) -> Bool {
        var a = self, b = other
        a.observedAt = .distantPast; b.observedAt = .distantPast
        return a == b
    }
}
