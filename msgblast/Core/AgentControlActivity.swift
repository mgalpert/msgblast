import Foundation
import msgblastRemoteProtocol

public extension RemoteRejectionCode {
    /// The person stopped agent sends in msgblast. Nothing was sent.
    static let agentSendsStopped: Self = "agentSendsStopped"
}

/// One send an outside agent asked for. It never holds the message text.
public struct AgentControlActivityEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let client: String
    /// "Started a blast", "Followed up", "Messaged one agent" or "Ended a comparison".
    public let action: String
    /// How many agents it named; nil when it goes to the whole comparison.
    public let agentCount: Int?
    public let started: Date
    /// nil while it runs, then "Done", "Not confirmed" or "Refused: <why>".
    public var result: String?

    public var summary: String {
        guard let agentCount else { return "\(client) · \(action)" }
        return "\(client) · \(action) · \(agentCount == 1 ? "1 agent" : "\(agentCount) agents")"
    }
}

/// Agent sends since msgblast opened, newest first. Kept in memory only.
public struct AgentControlActivityLog: Equatable, Sendable {
    public static let limit = 50
    public private(set) var entries: [AgentControlActivityEntry] = []

    public init() {}

    /// The send now running, if any. Agent sends run one at a time.
    public var running: AgentControlActivityEntry? { entries.first { $0.result == nil } }

    public mutating func begin(_ command: RemoteCommand, client: String, now: Date = Date()) {
        guard let described = Self.describe(command.action) else { return }
        let entry = AgentControlActivityEntry(id: command.clientCommandID, client: client, action: described.name,
                                              agentCount: described.agents, started: now)
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    public mutating func finish(_ result: RemoteCommandResult) {
        guard let index = entries.firstIndex(where: { $0.id == result.clientCommandID && $0.result == nil }) else { return }
        entries[index].result = Self.describe(result)
    }

    static func describe(_ action: RemoteAction) -> (name: String, agents: Int?)? {
        switch action {
        case .createConversation(_, let agents, _): ("Started a blast", agents.count)
        case .sendShared(_, _, let agents, _): ("Followed up", agents.isEmpty ? nil : agents.count)
        case .sendPrivate: ("Messaged one agent", 1)
        case .endConversation: ("Ended a comparison", nil)
        default: nil
        }
    }

    static func describe(_ result: RemoteCommandResult) -> String {
        switch result.outcome {
        case .applied: "Done"
        case .accepted: "Still running"
        case .rejected where result.code == .unknownCommand: "Not confirmed"
        case .rejected: "Refused: \(result.message ?? "msgblast did not send it")"
        }
    }
}

/// What outside agents asked msgblast to send, and the person's switch that stops them.
@MainActor public final class AgentControlActivity: ObservableObject {
    public static let stoppedKey = "AgentSendsStopped"
    @Published public private(set) var log = AgentControlActivityLog()
    /// While true, every new agent send is refused. Saved, so quitting msgblast doesn't turn sends back on.
    @Published public var stopped: Bool { didSet { defaults.set(stopped, forKey: Self.stoppedKey) } }
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        _stopped = Published(initialValue: defaults.bool(forKey: Self.stoppedKey))
    }

    /// Records a new send and runs it, or refuses it while sends are stopped.
    /// A repeat of a known request (`known`) runs as-is and adds no entry.
    public func run(_ command: RemoteCommand, client: String, known: Bool,
                    send: @MainActor (RemoteCommand) async -> RemoteCommandResult) async -> RemoteCommandResult {
        guard !known else { return await send(command) }
        log.begin(command, client: client)
        let result: RemoteCommandResult
        if stopped {
            result = .rejected(command.clientCommandID, .agentSendsStopped,
                               "Agent sends are stopped in msgblast. The person can allow them again in msgblast")
        } else {
            result = await send(command)
        }
        log.finish(result)
        return result
    }
}
