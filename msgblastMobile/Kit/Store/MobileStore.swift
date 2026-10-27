import Combine
import Foundation
import msgblastRemoteProtocol

/// The phone's state: the cached projection, per-device drafts, and command records,
/// persisted in `LocalDatabase`. Drafts never leave the phone.
@MainActor
public final class MobileStore: ObservableObject {
    @Published public private(set) var projection: ProjectionState
    @Published public private(set) var commands: [UUID: CommandRecord]
    @Published public private(set) var drafts: [String: String]
    private let database: LocalDatabase
    private var saveTask: Task<Void, Never>?

    public init(database: LocalDatabase) {
        self.database = database
        projection = database.value(ProjectionState.self, "projection") ?? ProjectionState()
        commands = database.value([UUID: CommandRecord].self, "commands") ?? [:]
        drafts = database.value([String: String].self, "drafts") ?? [:]
        // A previous run may have ended mid-command: those are unconfirmed until the Mac says otherwise.
        CommandLedger.connectionLost(&commands)
    }

    public func handle(_ event: RemoteClientDriver.Event) {
        if case .commandResult(let result) = event {
            CommandLedger.apply(result, to: &commands)
        } else {
            projection = ProjectionReducer.reduce(projection, event)
        }
        scheduleSave()
    }

    public func recordSent(_ command: RemoteCommand, at date: Date = Date()) {
        commands[command.clientCommandID] = CommandLedger.record(command, at: date)
        trimCommands()
        scheduleSave()
    }

    public func connectionLost() {
        CommandLedger.connectionLost(&commands)
        scheduleSave()
    }

    public var unresolvedCommandIDs: [UUID] { CommandLedger.unresolved(commands) }

    // MARK: Drafts (per device)

    public static func draftKey(conversation: UUID?, agentID: String?) -> String {
        "\(conversation?.uuidString ?? "new")|\(agentID ?? "all")"
    }
    public func draft(_ key: String) -> String { drafts[key] ?? "" }
    public func setDraft(_ text: String, for key: String) {
        guard drafts[key] != text else { return }
        drafts[key] = text.isEmpty ? nil : text
        scheduleSave()
    }

    public func forgetMac() {
        projection = ProjectionState()
        commands = [:]
        drafts = [:]
        database.removeAll()
    }

    public func saveNow() {
        saveTask?.cancel(); saveTask = nil
        database.setValue(projection, "projection")
        database.setValue(commands, "commands")
        database.setValue(drafts, "drafts")
    }

    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.saveTask = nil
            self?.saveNow()
        }
    }

    private func trimCommands() {
        guard commands.count > 500 else { return }
        for record in commands.values.sorted(by: { $0.sentAt < $1.sentAt }).prefix(commands.count - 500) where record.isFinal { commands[record.id] = nil }
    }
}
