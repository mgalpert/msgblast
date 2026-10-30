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
    /// Agent artwork from the paired Mac, by content reference (`sha256:<hex>`). Each image
    /// is its own row in the cache database, which is excluded from backups.
    @Published public private(set) var avatars: [String: Data]
    private let database: LocalDatabase
    private var saveTask: Task<Void, Never>?

    public init(database: LocalDatabase) {
        self.database = database
        projection = database.value(ProjectionState.self, "projection") ?? ProjectionState()
        commands = database.value([UUID: CommandRecord].self, "commands") ?? [:]
        drafts = database.value([String: String].self, "drafts") ?? [:]
        let refs = database.value([String].self, "avatarRefs") ?? []
        avatars = Dictionary(uniqueKeysWithValues: refs.compactMap { ref in database.data(Self.avatarKey(ref)).map { (ref, $0) } })
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

    // MARK: Avatars

    static func avatarKey(_ ref: String) -> String { "avatar:\(ref)" }
    public func avatar(_ ref: String?) -> Data? { ref.flatMap { avatars[$0] } }
    public func storeAvatar(_ data: Data, for ref: String) {
        guard avatars[ref] != data else { return }
        avatars[ref] = data
        database.set(data, for: Self.avatarKey(ref))
        database.setValue(avatars.keys.sorted(), "avatarRefs")
    }
    /// Content references the projection names that are not cached yet.
    public var missingAvatarRefs: [String] {
        Set(projection.agents.values.compactMap(\.avatarRef)).filter { $0.hasPrefix("sha256:") && avatars[$0] == nil }.sorted()
    }

    public func forgetMac() {
        projection = ProjectionState()
        commands = [:]
        drafts = [:]
        avatars = [:]
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
