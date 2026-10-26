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
    public var accountStatus: PersonalAgentAccountStatus = .unknown
    public var grokBotConfigured = false
    public var grokBotActivity: String?

    public init(agentID: String, gridID: AgentGridID, provider: WebProvider, name: String, isEnabled: Bool, isStorageAvailable: Bool, selected: Bool,
                connected: Bool, isSending: Bool, loading: Bool, snapshotReady: Bool, snapshotReason: String, signedIn: Bool?, signedOut: Bool?) {
        self.agentID = agentID; self.gridID = gridID; self.provider = provider; self.name = name; self.isEnabled = isEnabled
        self.isStorageAvailable = isStorageAvailable; self.selected = selected; self.connected = connected; self.isSending = isSending
        self.loading = loading; self.snapshotReady = snapshotReady; self.snapshotReason = snapshotReason; self.signedIn = signedIn; self.signedOut = signedOut
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
            unresolvedAttemptIDs = session.state.attempts.filter { $0.status.isUnresolved }.map(\.id.uuidString)
        } else if session.provider.usesNativeConversation {
            unresolvedAttemptIDs = session.state.attempts.filter { $0.status.isUnresolved }.map(\.id.uuidString)
        }
        accountStatus = session.accountStatus
        if session.provider == .grokbot {
            grokBotConfigured = session.grokBotIsConfigured
            grokBotActivity = session.grokBotConnectionActivity?.title
        }
    }
}

/// Pure mapping from existing signals to `AgentAvailability` (architecture §2.7).
public enum AvailabilityCalculator {
    public static func product(_ provider: WebProvider) -> AgentProduct {
        switch provider {
        case .muse, .museApp: .muse
        case .chatgpt, .chatgptApp, .codexCLI: .chatgpt
        case .claude, .claudeApp, .claudeCode: .claude
        case .grok: .grok
        case .grokbot, .grokBotApp: .grokBot
        case .dots, .dotsApp: .dots
        case .os3: .os3
        case .hark: .hark
        case .wabi: .wabi
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
        var reasons: [AvailabilityReason] = []
        var readiness: AgentReadiness = .ready
        var source: AvailabilitySource = .live
        func add(_ code: AvailabilityReasonCode, _ text: String, _ fix: FixLocation, permission: MacPermission? = nil, attempt: String? = nil, detail: String? = nil) {
            reasons.append(AvailabilityReason(code: code, userText: text, fixOn: fix, permission: permission, attemptID: attempt, detail: detail))
        }
        if !provider.isAvailableInBuild {
            readiness = .unavailable; add(.notOfferedInBuild, "\(s.name) is not offered in this version of msgblast.", .none)
        } else if !s.isEnabled {
            readiness = .unavailable; add(.disabled, "Turn on \(s.name) in msgblast on your Mac.", .mac)
        } else if !s.isStorageAvailable {
            readiness = .unavailable; add(.storageFailed, "\(s.name)'s saved state could not be read on the Mac. Nothing will be sent until it is repaired.", .mac)
        } else {
            switch form {
            case .website:
                source = s.connected ? .live : .lastKnown
                if !provider.supportsSharedSubmissions {
                    readiness = .unavailable; add(.noSharedSends, "Use \(s.name) directly on the Mac. msgblast does not send to it yet.", .mac)
                } else if s.isSending {
                    readiness = .busy(detail: "Sending to \(s.name)…"); add(.sendInFlight, "A message to \(s.name) is being sent.", .none)
                } else if s.signedIn == false || s.signedOut == true {
                    readiness = .blocked; add(.signedOut, "Sign in to \(s.name) in msgblast on your Mac.", .mac)
                } else if s.connected && s.snapshotReason.hasPrefix("Finish the open dialog") {
                    readiness = .blocked; add(.dialogOpen, s.snapshotReason, .mac)
                } else if s.connected && s.snapshotReason.hasPrefix("Wait for") && s.snapshotReason.hasSuffix("current reply.") {
                    readiness = .busy(detail: s.snapshotReason); add(.sendInFlight, s.snapshotReason, .none)
                } else if s.signedIn == nil {
                    add(.signInUnknown, "Sign-in is checked on the Mac when you send.", .none)
                }
            case .macApp:
                source = .lastKnown
                if !s.desktopInstalled {
                    readiness = .unavailable; source = .live; add(.notInstalled, "Install \(s.name) on your Mac.", .mac)
                    break
                }
                if m.driverInstalled == false { readiness = .blocked; add(.driverUnavailable, "App control is missing from this copy of msgblast. Update or reinstall it on the Mac.", .mac) }
                if m.accessibility == .denied { readiness = .blocked; add(.permissionMissing, "Allow Accessibility for msgblast on your Mac.", .mac, permission: .accessibility) }
                if m.screenRecording == .denied { readiness = .blocked; add(.permissionMissing, "Allow Screen & System Audio Recording for msgblast on your Mac.", .mac, permission: .screenRecording) }
                for id in s.unresolvedAttemptIDs {
                    readiness = .blocked
                    add(.incompleteRequestBlocking, "An earlier request to \(s.name) did not complete. Review it before sending again; usage may have been consumed.", .phone, attempt: id)
                }
                guard readiness == .ready else { break }
                if s.isSending { readiness = .busy(detail: "Sending to \(s.name)…"); add(.sendInFlight, "\(s.name) is handling a request.", .none) }
                else if s.loading { readiness = .busy(detail: "Checking \(s.name) on the Mac…"); add(.sendInFlight, "msgblast is checking \(s.name).", .none) }
                else if !s.hasDesktopBinding && !s.desktopReady { readiness = .blocked; add(.notConnected, "Connect \(s.name) in msgblast on your Mac first.", .mac) }
                else if let error = s.desktopError, !error.isEmpty {
                    readiness = .blocked
                    add(desktopCode(error), error, .mac)
                } else if !s.desktopRunning {
                    readiness = .readyWillLaunch; source = .live
                    add(.appNotRunning, "Sending will open \(s.name) on your Mac.", .none)
                }
                if readiness.acceptsSend && otherDesktopSending {
                    add(.queuedBehindDesktopSend, "Mac app requests run one at a time. This one will wait for the current one.", .none)
                }
            case .cli:
                source = s.connected ? .live : .lastKnown
                if s.isSending { readiness = .busy(detail: "\(s.name) is working…"); add(.sendInFlight, "\(s.name) is handling a request.", .none) }
                else if s.snapshotReady { }
                else if s.accountStatus == .signedOut { readiness = .blocked; add(.cliSignedOut, "Sign in to \(s.name) on your Mac.", .mac) }
                else if s.snapshotReason.hasPrefix("Install ") { readiness = .unavailable; add(.notInstalled, s.snapshotReason, .mac) }
                else { add(.signInUnknown, "\(s.name)'s account is checked on the Mac when you send.", .none) }
                for id in s.unresolvedAttemptIDs {
                    add(.incompleteRequestBlocking, "An earlier request to \(s.name) did not complete in one conversation. Review it there before sending again.", .phone, attempt: id)
                }
            case .webhookBot:
                if !s.grokBotConfigured { readiness = .blocked; add(.webhookNotConfigured, "Connect \(s.name)'s webhook in msgblast Settings on your Mac.", .mac) }
                else if let activity = s.grokBotActivity { readiness = .busy(detail: activity); add(.tunnelStarting, activity, .none) }
                else if s.isSending { readiness = .busy(detail: "Sending to \(s.name)…"); add(.sendInFlight, "A request to \(s.name) is in progress.", .none) }
                else if !s.snapshotReady && s.unresolvedAttemptIDs.isEmpty { add(.tunnelStarting, "The reply connection starts on the Mac with your first send. Keep the Mac awake for replies.", .none) }
                for id in s.unresolvedAttemptIDs {
                    add(.incompleteRequestBlocking, "\(s.name) has not replied to an earlier request in one conversation. Stop waiting there before sending again.", .phone, attempt: id)
                }
            case .messages:
                break
            }
        }
        let shared = provider.supportsSharedSubmissions && provider.isAvailableInBuild
        return AgentAvailability(agentID: s.agentID, product: product(provider), form: form, displayName: s.name, avatarRef: "provider:\(provider.rawValue)",
            visibleInGrid: m.visibleGridIDs.contains(s.gridID), selectedForSharedSend: s.isEnabled && s.selected && shared,
            capabilities: AgentCapabilities(sharedSend: shared, privateSend: shared, attachments: false, namedCopies: provider.supportsCopies,
                                            endConversation: true, sharesOneConversation: provider.sharesOneConversation),
            readiness: readiness, reasons: reasons, observedAt: now, source: source)
    }

    static func desktopCode(_ message: String) -> AvailabilityReasonCode {
        let text = message.lowercased()
        if text.contains("not supported yet") { return .appVersionUnsupported }
        if text.contains("dialog") { return .dialogOpen }
        if text.contains("main window") || text.contains("extra copies") || text.contains("one main window") { return .windowMissingOrAmbiguous }
        return .notConnected
    }

    public static func availability(_ agent: MessagesAgentSignal, inputs m: MacAvailabilityInputs, now: Date) -> AgentAvailability {
        var reasons: [AvailabilityReason] = []
        var readiness: AgentReadiness = .ready
        func block(_ code: AvailabilityReasonCode, _ text: String, permission: MacPermission? = nil, detail: String? = nil) {
            readiness = .blocked
            reasons.append(AvailabilityReason(code: code, userText: text, fixOn: .mac, permission: permission, detail: detail))
        }
        if !m.messagesSendsAllowed { block(.remoteMessagesOff, "iMessage sends from your phone are off. Turn them on in msgblast Settings → Remote on your Mac.") }
        if m.fullDiskAccess == .denied { block(.permissionMissing, "Allow Full Disk Access for msgblast on your Mac.", permission: .fullDiskAccess) }
        else if !m.databaseAvailable { block(.messagesDatabaseUnavailable, m.databaseStatus.isEmpty ? "Messages history is unavailable on your Mac." : m.databaseStatus) }
        if m.contacts != .allowed && m.contacts != .unknown { block(.permissionMissing, "Allow Contacts for msgblast on your Mac.", permission: .contacts) }
        switch m.automation {
        case .denied, .notRequested: block(.permissionMissing, "Allow msgblast to control Messages on your Mac.", permission: .automation)
        case .needsMessages: reasons.append(AvailabilityReason(code: .automationNeedsMessagesOpen, userText: "Messages will open on your Mac to send.", fixOn: .none))
        default: break
        }
        if !agent.routable { block(.conversationUnroutable, "\(agent.name) has no matching Messages conversation on your Mac (\(agent.routeStatus)).", detail: agent.routeStatus) }
        if readiness == .ready && m.messagesBusy {
            readiness = .busy(detail: "Sending in Messages…")
            reasons.append(AvailabilityReason(code: .sendInFlight, userText: "A Messages send is in progress on your Mac.", fixOn: .none))
        }
        return AgentAvailability(agentID: agent.remoteID, product: .messages, form: .messages, displayName: agent.name, avatarRef: "contact:\(agent.agentID.uuidString)",
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
        let signals = sessions().map(AgentSessionSignals.init)
        let sendingDesktop = Set(signals.filter { $0.provider.desktopApp != nil && $0.isSending }.map(\.agentID))
        var result = signals.map { s in
            AvailabilityCalculator.availability(s, inputs: inputs, otherDesktopSending: !sendingDesktop.subtracting([s.agentID]).isEmpty, now: now)
        }
        result += inputs.messagesAgents.map { AvailabilityCalculator.availability($0, inputs: inputs, now: now) }
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
