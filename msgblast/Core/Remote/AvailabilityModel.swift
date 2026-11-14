import Combine
import Foundation
import msgblastRemoteProtocol

public enum RemotePermissionState: String, Sendable, Equatable {
    case allowed, notRequested, denied, needsMessages, unknown
}

/// Mac-wide signals the availability model reads. The app fills these from the
/// existing prompt-free probes; nothing here requests access.
public struct MacAvailabilityInputs: Sendable, Equatable {
    public var accessibility: RemotePermissionState = .unknown
    public var screenRecording: RemotePermissionState = .unknown
    public var driverInstalled: Bool?
    public var fullDiskAccess: RemotePermissionState = .unknown
    public var contacts: RemotePermissionState = .unknown
    public var automation: RemotePermissionState = .unknown
    public var databaseAvailable = false
    public var databaseStatus = ""
    public var messagesBusy = false
    public var messagesSendsAllowed = false
    public var visibleGridIDs: [AgentGridID] = []
    public var messagesAgents: [MessagesAgentSignal] = []
    public init() {}
}

public struct MessagesAgentSignal: Sendable, Equatable {
    public var agentID: UUID
    public var gridID: AgentGridID
    public var name: String
    public var routable: Bool
    public var routeStatus: String
    public var selected: Bool
    public init(agentID: UUID, gridID: AgentGridID, name: String, routable: Bool, routeStatus: String, selected: Bool) {
        self.agentID = agentID; self.gridID = gridID; self.name = name; self.routable = routable; self.routeStatus = routeStatus; self.selected = selected
    }
    public var remoteID: String { RemoteAgentIDs.messages(agentID) }
}

public enum RemoteAgentIDs {
    public static func messages(_ id: UUID) -> String { "messages:\(id.uuidString)" }
    public static func messagesAgent(_ remoteID: String) -> UUID? {
        guard remoteID.hasPrefix("messages:") else { return nil }
        return UUID(uuidString: String(remoteID.dropFirst("messages:".count)))
    }
}

/// A read of one session's published state. Building it never calls a session method
/// that loads a page, launches an app, refreshes a desktop binding, or prompts.
public struct AgentSessionSignals: Sendable, Equatable {
    public var agentID: String
    public var gridID: AgentGridID
    public var provider: WebProvider
    public var name: String
    public var isEnabled: Bool
    public var isStorageAvailable: Bool
    public var selected: Bool
    public var connected: Bool
    public var isSending: Bool
    public var loading: Bool
    public var snapshotReady: Bool
    public var snapshotReason: String
    public var signedIn: Bool?
    public var signedOut: Bool?
    public var desktopInstalled = false
    public var desktopRunning = false
    public var desktopReady = false
    public var hasDesktopBinding = false
    public var desktopError: String?
    public var unresolvedAttemptIDs: [String] = []
    /// Native requests still inside their normal reply window: the agent is working, not stuck.
    public var replyingAttemptIDs: [String] = []
    /// Another agent that uses the same Mac app is sending or has an unfinished request.
    /// The Mac composer then shows this agent as Busy and keeps it out of new sends.
    public var sameAppBusyWith: String?
    /// The Mac composer would still try this app: a send prepares it first
    /// (`WebAgentSession.canSubmitNativePrompt`).
    public var canSubmitNativePrompt = false
    public var accountStatus: PersonalAgentAccountStatus = .unknown
    public var grokBotConfigured = false
    public var grokBotActivity: String?

    public init(agentID: String, gridID: AgentGridID, provider: WebProvider, name: String, isEnabled: Bool, isStorageAvailable: Bool, selected: Bool,
                connected: Bool, isSending: Bool, loading: Bool, snapshotReady: Bool, snapshotReason: String, signedIn: Bool?, signedOut: Bool?) {
        self.agentID = agentID; self.gridID = gridID; self.provider = provider; self.name = name; self.isEnabled = isEnabled
        self.isStorageAvailable = isStorageAvailable; self.selected = selected; self.connected = connected; self.isSending = isSending
        self.loading = loading; self.snapshotReady = snapshotReady; self.snapshotReason = snapshotReason; self.signedIn = signedIn; self.signedOut = signedOut
    }

    /// Unfinished requests block only once they are past the reply window (or the Mac marked
    /// them uncertain); younger ones read as the agent handling a request.
    private mutating func sortAttempts(_ attempts: [WebSendAttempt], now: Date = Date()) {
        unresolvedAttemptIDs = attempts.filter { $0.blocksAsIncomplete(now: now) }.map(\.id.uuidString)
        replyingAttemptIDs = attempts.filter { $0.isAwaitingReply(now: now) }.map(\.id.uuidString)
    }

    @MainActor public init(_ session: WebAgentSession) {
        self.init(agentID: session.id.id, gridID: session.id.gridID, provider: session.provider, name: session.name, isEnabled: session.isEnabled,
                  isStorageAvailable: session.isStorageAvailable, selected: session.state.selected, connected: session.connected,
                  isSending: session.isSending, loading: session.loading, snapshotReady: session.snapshot.ready, snapshotReason: session.snapshot.reason,
                  signedIn: session.snapshot.signedIn, signedOut: session.snapshot.signedOut)
        if session.provider.desktopApp != nil {
            desktopInstalled = session.desktopInstallation.isInstalled
            desktopRunning = session.desktopInstallation.isRunning
            desktopReady = session.desktopReady
            hasDesktopBinding = session.state.desktopConversation != nil
            desktopError = session.desktopRecoveryMessage
            sortAttempts(session.state.attempts)
            canSubmitNativePrompt = session.canSubmitNativePrompt
        } else if session.provider.usesNativeConversation {
            sortAttempts(session.state.attempts)
        }
        accountStatus = session.accountStatus
        if session.provider == .grokbot {
            grokBotConfigured = session.grokBotIsConfigured
            grokBotActivity = session.grokBotConnectionActivity?.title
        }
    }
}

/// The readiness, source and reasons collected while mapping one agent's signals.
private struct AvailabilityDraft {
    let name: String
    var reasons: [AvailabilityReason] = []
    var readiness: AgentReadiness = .ready
    var source: AvailabilitySource = .live

    init(name: String) { self.name = name }

    mutating func add(_ code: AvailabilityReasonCode, _ text: String, _ fix: FixLocation, permission: MacPermission? = nil, attempt: String? = nil, detail: String? = nil) {
        // One short line for the phone; the Mac's full reason stays as the detail.
        let line = RemotePhoneText.split(text, agentName: name)
        reasons.append(AvailabilityReason(code: code, userText: line.text, fixOn: fix, permission: permission, attemptID: attempt, detail: detail ?? line.detail))
    }
}

/// Pure mapping from existing signals to `AgentAvailability` (architecture §2.7).
public enum AvailabilityCalculator {
    public static func product(_ provider: WebProvider) -> AgentProduct {
        switch provider {
        case .muse, .museApp: .muse
        case .chatgpt, .chatgptApp, .codexCLI: .chatgpt
        case .claude, .claudeApp, .claudeCode: .claude
        case .grokbot, .grokBotApp: .grokBot
        case .dots, .dotsApp: .dots
        // These providers share their product's raw value: .grok, .os3, .hark, .alexaShopping and .wabi.
        case .grok, .os3, .hark, .alexaShopping, .wabi: AgentProduct(rawValue: provider.rawValue)
        case .geminiApp: .gemini
        }
    }
    public static func form(_ provider: WebProvider) -> AgentForm {
        if provider.desktopApp != nil { return .macApp }
        if provider.personalAgentProvider != nil { return .cli }
        if provider == .grokbot { return .webhookBot }
        return .website
    }

    public static func availability(_ s: AgentSessionSignals, inputs m: MacAvailabilityInputs, otherDesktopSending: Bool, now: Date) -> AgentAvailability {
        let provider = s.provider, form = form(provider)
        var d = AvailabilityDraft(name: s.name)
        if !provider.isAvailableInBuild {
            d.readiness = .unavailable; d.add(.notOfferedInBuild, "\(s.name) isn't in this version", .none, detail: "\(s.name) is not offered in this version of msgblast.")
        } else if !s.isEnabled {
            d.readiness = .unavailable; d.add(.disabled, "Turn on \(s.name) on your Mac", .mac)
        } else if !s.isStorageAvailable {
            d.readiness = .unavailable; d.add(.storageFailed, "Repair \(s.name) on your Mac", .mac, detail: "\(s.name)'s saved state could not be read on your Mac. Nothing will be sent until it is repaired.")
        } else {
            switch form {
            case .website: websiteAvailability(s, into: &d)
            case .macApp: macAppAvailability(s, inputs: m, otherDesktopSending: otherDesktopSending, into: &d)
            case .cli: cliAvailability(s, into: &d)
            case .webhookBot: webhookBotAvailability(s, into: &d)
            case .messages:
                break
            }
        }
        let shared = provider.supportsSharedSubmissions && provider.isAvailableInBuild
        return AgentAvailability(agentID: s.agentID, product: product(provider), form: form, displayName: s.name, avatarRef: nil,
            visibleInGrid: m.visibleGridIDs.contains(s.gridID), selectedForSharedSend: s.isEnabled && s.selected && shared,
            capabilities: AgentCapabilities(sharedSend: shared, privateSend: shared, attachments: false, namedCopies: provider.supportsCopies,
                                            endConversation: true, sharesOneConversation: provider.sharesOneConversation),
            readiness: d.readiness, reasons: d.reasons, observedAt: now, source: d.source)
    }

    private static func websiteAvailability(_ s: AgentSessionSignals, into d: inout AvailabilityDraft) {
        d.source = s.connected ? .live : .lastKnown
        if !s.provider.supportsSharedSubmissions {
            d.readiness = .unavailable; d.add(.noSharedSends, "Use \(s.name) on your Mac", .mac, detail: "msgblast does not send to \(s.name) yet.")
        } else if s.isSending {
            d.readiness = .busy(detail: "Sending to \(s.name)…"); d.add(.sendInFlight, "Sending to \(s.name)…", .none)
        } else if s.signedIn == false || s.signedOut == true {
            d.readiness = .blocked; d.add(.signedOut, "Sign in to \(s.name) on your Mac", .mac)
        } else if s.connected && s.snapshotReason.hasPrefix("Finish the open dialog") {
            d.readiness = .blocked; d.add(.dialogOpen, s.snapshotReason, .mac)
        } else if s.connected && s.snapshotReason.hasPrefix("Wait for") && s.snapshotReason.hasSuffix("current reply.") {
            d.readiness = .busy(detail: RemotePhoneText.split(s.snapshotReason, agentName: s.name).text); d.add(.sendInFlight, s.snapshotReason, .none)
        } else if s.signedIn == nil {
            d.add(.signInUnknown, "Sign-in is checked when you send", .none)
        }
    }

    private static func macAppAvailability(_ s: AgentSessionSignals, inputs m: MacAvailabilityInputs, otherDesktopSending: Bool, into d: inout AvailabilityDraft) {
        d.source = .lastKnown
        if !s.desktopInstalled {
            d.readiness = .unavailable; d.source = .live; d.add(.notInstalled, "Install \(s.name) on your Mac", .mac)
            return
        }
        addMacAppBlockers(s, inputs: m, into: &d)
        guard d.readiness == .ready else { return }
        if let other = s.sameAppBusyWith {
            d.readiness = .busy(detail: "\(other) is using this app")
            d.add(.sendInFlight, "\(other) is using this app", .none, detail: "\(other) is using the same app on your Mac. \(s.name) is busy until it finishes.")
            return
        }
        addMacAppState(s, into: &d)
        if d.readiness.acceptsSend && otherDesktopSending {
            d.add(.queuedBehindDesktopSend, "Waits for the current Mac app request", .none, detail: "Mac app requests run one at a time. This one will wait for the current one.")
        }
    }

    private static func addMacAppBlockers(_ s: AgentSessionSignals, inputs m: MacAvailabilityInputs, into d: inout AvailabilityDraft) {
        if m.driverInstalled == false { d.readiness = .blocked; d.add(.driverUnavailable, "Reinstall msgblast on your Mac", .mac, detail: "App control is missing from this copy of msgblast. Update or reinstall it on your Mac.") }
        if m.accessibility == .denied { d.readiness = .blocked; d.add(.permissionMissing, "Allow Accessibility on your Mac", .mac, permission: .accessibility, detail: "Allow Accessibility for msgblast in System Settings on your Mac.") }
        if m.screenRecording == .denied { d.readiness = .blocked; d.add(.permissionMissing, "Allow Screen Recording on your Mac", .mac, permission: .screenRecording, detail: "Allow Screen & System Audio Recording for msgblast in System Settings on your Mac.") }
        for id in s.unresolvedAttemptIDs {
            d.readiness = .blocked
            d.add(.incompleteRequestBlocking, "Finish the \(s.name) request first", .phone, attempt: id,
                  detail: "An earlier request to \(s.name) did not complete. Review it before sending again; usage may have been consumed.")
        }
    }

    private static func addMacAppState(_ s: AgentSessionSignals, into d: inout AvailabilityDraft) {
        if s.isSending || !s.replyingAttemptIDs.isEmpty { d.readiness = .busy(detail: "Sending to \(s.name)…"); d.add(.sendInFlight, "\(s.name) is handling a request", .none) }
        else if s.loading { d.readiness = .busy(detail: "Checking \(s.name)…"); d.add(.sendInFlight, "Checking \(s.name) on your Mac", .none) }
        else if !s.desktopReady && s.canSubmitNativePrompt { addMacAppPreparesOnSend(s, into: &d) }
        else if !s.hasDesktopBinding && !s.desktopReady { d.readiness = .blocked; d.add(.notConnected, "Connect \(s.name) on your Mac first", .mac) }
        else if let error = s.desktopError, !error.isEmpty { addMacAppDesktopError(error, s, into: &d) }
        else if !s.desktopRunning {
            d.readiness = .readyWillLaunch; d.source = .live
            d.add(.appNotRunning, "Opens \(s.name) on your Mac", .none)
        }
    }

    private static func addMacAppPreparesOnSend(_ s: AgentSessionSignals, into d: inout AvailabilityDraft) {
        // As on the Mac, the first explicit prompt prepares the app; a failure is
        // recorded as not sent and never blocks the other recipients.
        d.readiness = s.desktopRunning ? .ready : .readyWillLaunch; d.source = .live
        if let error = s.desktopError, !error.isEmpty {
            d.add(.preparesOnSend, "Connects \(s.name) on your Mac first", .none, detail: error)
        } else if !s.hasDesktopBinding {
            d.add(.preparesOnSend, "Connects \(s.name) on your Mac first", .none)
        } else if !s.desktopRunning {
            d.add(.appNotRunning, "Opens \(s.name) on your Mac", .none)
        }
    }

    private static func addMacAppDesktopError(_ error: String, _ s: AgentSessionSignals, into d: inout AvailabilityDraft) {
        // The Mac composer would not try this app either; its pane shows Reconnect.
        d.readiness = .blocked
        switch desktopCode(error) {
        case .controlsUpdating:
            d.add(.controlsUpdating, "\(s.name) is still loading", .mac, detail: "\(RemotePhoneText.phrase(error)) If this stays, reconnect \(s.name) on your Mac.")
        case .reconnectNeeded:
            d.add(.reconnectNeeded, "Reconnect \(s.name) on your Mac", .mac, detail: error)
        case let code:
            d.add(code, error, .mac)
        }
    }

    private static func cliAvailability(_ s: AgentSessionSignals, into d: inout AvailabilityDraft) {
        d.source = s.connected ? .live : .lastKnown
        if s.isSending || !s.replyingAttemptIDs.isEmpty { d.readiness = .busy(detail: "\(s.name) is working…"); d.add(.sendInFlight, "\(s.name) is handling a request", .none) }
        else if s.snapshotReady { }
        else if s.accountStatus == .signedOut { d.readiness = .blocked; d.add(.cliSignedOut, "Sign in to \(s.name) on your Mac", .mac) }
        else if s.snapshotReason.hasPrefix("Install ") { d.readiness = .unavailable; d.add(.notInstalled, "Install \(s.name) on your Mac", .mac, detail: RemotePhoneText.phrase(s.snapshotReason, agentName: s.name)) }
        else { d.add(.signInUnknown, "Account is checked when you send", .none) }
        for id in s.unresolvedAttemptIDs {
            d.add(.incompleteRequestBlocking, "Finish the \(s.name) request first", .phone, attempt: id,
                  detail: "An earlier request to \(s.name) did not complete in one conversation. Review it there before sending again.")
        }
    }

    private static func webhookBotAvailability(_ s: AgentSessionSignals, into d: inout AvailabilityDraft) {
        if !s.grokBotConfigured { d.readiness = .blocked; d.add(.webhookNotConfigured, "Set up \(s.name)'s webhook on your Mac", .mac) }
        // While the key is read or the reply tunnel starts, the bot is blocked; it becomes ready by itself.
        else if let activity = s.grokBotActivity { d.readiness = .blocked; d.add(.tunnelStarting, activity, .none) }
        else if s.isSending || !s.replyingAttemptIDs.isEmpty { d.readiness = .busy(detail: "Sending to \(s.name)…"); d.add(.sendInFlight, "\(s.name) is handling a request", .none) }
        else if !s.snapshotReady && s.unresolvedAttemptIDs.isEmpty { d.add(.tunnelStarting, "Replies need your Mac awake", .none, detail: "The reply connection starts on your Mac with your first send. Keep it awake for replies.") }
        for id in s.unresolvedAttemptIDs {
            d.add(.incompleteRequestBlocking, "Finish the \(s.name) request first", .phone, attempt: id,
                  detail: "\(s.name) has not replied to an earlier request in one conversation. Stop waiting there before sending again.")
        }
    }

    static func desktopCode(_ message: String) -> AvailabilityReasonCode {
        let text = message.lowercased()
        if text.contains("still updating its controls") || text.contains("controls are still updating") { return .controlsUpdating }
        if text.contains("not supported yet") { return .appVersionUnsupported }
        if text.contains("dialog") { return .dialogOpen }
        if text.contains("main window") || text.contains("extra copies") || text.contains("one main window") { return .windowMissingOrAmbiguous }
        return .reconnectNeeded
    }

    public static func availability(_ agent: MessagesAgentSignal, inputs m: MacAvailabilityInputs, now: Date) -> AgentAvailability {
        var reasons: [AvailabilityReason] = []
        var readiness: AgentReadiness = .ready
        func block(_ code: AvailabilityReasonCode, _ text: String, permission: MacPermission? = nil, detail: String? = nil) {
            readiness = .blocked
            let line = RemotePhoneText.split(text, agentName: agent.name)
            reasons.append(AvailabilityReason(code: code, userText: line.text, fixOn: .mac, permission: permission, detail: detail ?? line.detail))
        }
        if !m.messagesSendsAllowed { block(.remoteMessagesOff, "Turn on iMessage sends on your Mac", detail: "iMessage sends from your phone are off. Turn them on in Settings › Remote on your Mac.") }
        if m.fullDiskAccess == .denied { block(.permissionMissing, "Allow Full Disk Access on your Mac", permission: .fullDiskAccess) }
        else if !m.databaseAvailable { block(.messagesDatabaseUnavailable, "Messages history is unavailable", detail: m.databaseStatus.isEmpty ? nil : m.databaseStatus) }
        if m.contacts != .allowed && m.contacts != .unknown { block(.permissionMissing, "Allow Contacts on your Mac", permission: .contacts) }
        switch m.automation {
        case .denied, .notRequested: block(.permissionMissing, "Allow Messages automation on your Mac", permission: .automation)
        case .needsMessages: reasons.append(AvailabilityReason(code: .automationNeedsMessagesOpen, userText: "Opens Messages on your Mac", fixOn: .none))
        default: break
        }
        if !agent.routable { block(.conversationUnroutable, "No Messages chat for \(agent.name)", detail: agent.routeStatus) }
        if readiness == .ready && m.messagesBusy {
            readiness = .busy(detail: "Sending in Messages…")
            reasons.append(AvailabilityReason(code: .sendInFlight, userText: "Messages is sending on your Mac", fixOn: .none))
        }
        return AgentAvailability(agentID: agent.remoteID, product: .messages, form: .messages, displayName: agent.name, avatarRef: nil,
            visibleInGrid: m.visibleGridIDs.contains(agent.gridID), selectedForSharedSend: agent.selected,
            capabilities: AgentCapabilities(sharedSend: true, privateSend: true, attachments: true, namedCopies: false, endConversation: true, sharesOneConversation: false),
            readiness: readiness, reasons: reasons, observedAt: now, source: .live)
    }
}

/// Main-actor availability for every agent, recomputed from existing signals.
/// The probe loop runs only while a remote client is connected.
@MainActor
public final class AvailabilityModel: ObservableObject {
    @Published public private(set) var agents: [AgentAvailability] = []
    public var interval: Duration = .seconds(5)
    public var slowInterval: Duration = .seconds(60)
    private let sessions: @MainActor () -> [WebAgentSession]
    private let inputs: @MainActor () -> MacAvailabilityInputs
    private let probe: @MainActor (_ slow: Bool) async -> Void
    private let now: () -> Date
    private var loop: Task<Void, Never>?
    /// The content reference (`sha256:<hex>`) of the artwork the Mac shows for an agent;
    /// the app fills it from its own artwork. Nil leaves the phone on initials.
    public var avatarRef: @MainActor (String) -> String? = { _ in nil }

    /// `probe` refreshes Mac signals without side effects (permission preflights,
    /// `refreshDesktopInstallation`, account status at the slow cadence).
    public init(sessions: @escaping @MainActor () -> [WebAgentSession], inputs: @escaping @MainActor () -> MacAvailabilityInputs,
                probe: @escaping @MainActor (_ slow: Bool) async -> Void = { _ in }, now: @escaping () -> Date = Date.init) {
        self.sessions = sessions; self.inputs = inputs; self.probe = probe; self.now = now
    }

    public var isRunning: Bool { loop != nil }

    @discardableResult
    public func recompute() -> [AgentAvailability] {
        let inputs = inputs(), now = now()
        var signals = sessions().map(AgentSessionSignals.init)
        for i in signals.indices {
            guard let app = signals[i].provider.desktopApp else { continue }
            signals[i].sameAppBusyWith = signals.first { other in
                other.agentID != signals[i].agentID && other.provider.desktopApp?.bundleID == app.bundleID &&
                    (other.isSending || !other.unresolvedAttemptIDs.isEmpty || !other.replyingAttemptIDs.isEmpty)
            }?.name
        }
        let sendingDesktop = Set(signals.filter { $0.provider.desktopApp != nil && $0.isSending }.map(\.agentID))
        var result = signals.map { s in
            AvailabilityCalculator.availability(s, inputs: inputs, otherDesktopSending: !sendingDesktop.subtracting([s.agentID]).isEmpty, now: now)
        }
        result += inputs.messagesAgents.map { AvailabilityCalculator.availability($0, inputs: inputs, now: now) }
        for index in result.indices { result[index].avatarRef = avatarRef(result[index].agentID) }
        let changed = result.count != agents.count || zip(result, agents).contains { !$0.sameContent(as: $1) }
        if changed { agents = result }
        return agents
    }

    public func availability(for agentID: String) -> AgentAvailability? { recompute().first { $0.agentID == agentID } }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            var lastSlow = ContinuousClock.now - .seconds(3600)
            while !Task.isCancelled {
                guard let self else { return }
                let slow = ContinuousClock.now - lastSlow >= self.slowInterval
                if slow { lastSlow = .now }
                await self.probe(slow)
                self.recompute()
                do { try await Task.sleep(for: self.interval) } catch { return }
            }
        }
    }

    public func stop() { loop?.cancel(); loop = nil }
}

extension WebSendAttempt {
    /// How long a native request (Mac app, CLI, bot) may wait for its reply before it counts
    /// as incomplete: the Mac app reply timeout (`DesktopAppConversation.Timing.replyTimeout`).
    public static let replyWindow: TimeInterval = 360
    /// Submitted or being submitted, and still within the reply window.
    public func isAwaitingReply(now: Date) -> Bool {
        [.attempting, .waiting].contains(status) && now.timeIntervalSince(created) < Self.replyWindow
    }
    /// Unfinished and either marked uncertain by the Mac or older than the reply window.
    public func blocksAsIncomplete(now: Date) -> Bool { status.isUnresolved && !isAwaitingReply(now: now) }
}
