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
    /// When each conversation was last opened on this phone, for the unread dot.
    @Published public private(set) var lastOpened: [UUID: Date]
    /// Undated replies (Mac apps, websites, CLIs, bots) have no time to compare: each agent's
    /// transcript position when the conversation was last opened. Kept under its own key, so
    /// saved state from before it decodes unchanged.
    @Published public private(set) var readPositions: [UUID: [String: Int]]
    /// When this phone first heard from the paired Mac; older replies are not unread.
    public private(set) var unreadSince: Date?
    /// Replies made from this phone: command id → the quoted turn. Local only; the Mac
    /// never sees the link.
    @Published public private(set) var replyTo: [UUID: String]
    private let database: LocalDatabase
    private var saveTask: Task<Void, Never>?

    /// Throws when saved state cannot be read or decoded, so it is never replaced with an
    /// empty store. Only a value that was never saved starts empty.
    public init(database: LocalDatabase) throws {
        self.database = database
        projection = try database.value(ProjectionState.self, "projection") ?? ProjectionState()
        commands = try database.value([UUID: CommandRecord].self, "commands") ?? [:]
        drafts = try database.value([String: String].self, "drafts") ?? [:]
        lastOpened = try database.value([UUID: Date].self, "lastOpened") ?? [:]
        readPositions = try database.value([UUID: [String: Int]].self, "readPositions") ?? [:]
        unreadSince = try database.value(Date.self, "unreadSince")
        replyTo = try database.value([UUID: String].self, "replyTo") ?? [:]
        let refs = try database.value([String].self, "avatarRefs") ?? []
        avatars = Dictionary(uniqueKeysWithValues: try refs.compactMap { ref in try database.data(Self.avatarKey(ref)).map { (ref, $0) } })
        // A previous run may have ended mid-command: those are unconfirmed until the Mac says otherwise.
        CommandLedger.connectionLost(&commands)
    }

    public func handle(_ event: RemoteClientDriver.Event) {
        if case .commandResult(let result) = event {
            let wasFinal = commands[result.clientCommandID]?.isFinal ?? true
            CommandLedger.apply(result, to: &commands)
            if !wasFinal, let record = commands[result.clientCommandID], record.status == .applied { clearDraft(sentBy: record) }
        } else {
            projection = ProjectionReducer.reduce(projection, event)
            if case .snapshot = event, unreadSince == nil { unreadSince = Date(); database.setValue(unreadSince, "unreadSince") }
        }
        scheduleSave()
    }

    public func recordSent(_ command: RemoteCommand, at date: Date = Date()) {
        commands[command.clientCommandID] = CommandLedger.record(command, at: date)
        trimCommands()
        scheduleSave()
    }

    /// `perform` gave up waiting and told the user so; the ledger says the same until a
    /// reconnect's query answers.
    public func markUnconfirmed(_ id: UUID) {
        guard let record = commands[id], !record.isFinal else { return }
        commands[id]?.status = .unconfirmed
        scheduleSave()
    }

    public var unresolvedCommandIDs: [UUID] { CommandLedger.unresolved(commands) }

    // MARK: Drafts (per device)

    public static func draftKey(conversation: UUID?, agentID: String?) -> String {
        "\(conversation?.uuidString ?? "new")|\(agentID ?? "all")"
    }
    public func draft(_ key: String) -> String { drafts[key] ?? "" }
    /// A send reached the Mac (now, or by a late query answer): its field's draft goes, unless
    /// edited since. Keyed as `ComposeBar` keys it: the agent only for one recipient in an
    /// existing conversation (a private send, or a direct thread's only member).
    private func clearDraft(sentBy record: CommandRecord) {
        guard ["createConversation", "sendShared", "sendPrivate"].contains(record.kind), let text = record.text else { return }
        let recipients = record.agentIDs.isEmpty ? record.conversationID.flatMap { projection.conversations[$0]?.agentIDs } ?? [] : record.agentIDs
        let key = Self.draftKey(conversation: record.conversationID, agentID: recipients.count == 1 && record.conversationID != nil ? recipients[0] : nil)
        if drafts[key]?.trimmingCharacters(in: .whitespacesAndNewlines) == text { setDraft("", for: key) }
    }
    public func setDraft(_ text: String, for key: String) {
        guard drafts[key] != text else { return }
        drafts[key] = text.isEmpty ? nil : text
        scheduleSave()
    }

    // MARK: Attachments fetched from the Mac (thumbnails and full files), cached on the phone.

    static func fileKey(_ turnID: String, _ index: Int, thumbnail: Bool) -> String { "file:\(thumbnail ? "thumb" : "full"):\(turnID):\(index)" }
    public func attachment(turnID: String, index: Int, thumbnail: Bool) -> (data: Data, type: String)? {
        let key = Self.fileKey(turnID, index, thumbnail: thumbnail)
        // A cached copy that cannot be read is fetched from the Mac again.
        guard let data = try? database.data(key) else { return nil }
        return (data, (try? database.value(String.self, key + ":type")) ?? "application/octet-stream")
    }
    public func storeAttachment(_ data: Data, type: String, turnID: String, index: Int, thumbnail: Bool) {
        let key = Self.fileKey(turnID, index, thumbnail: thumbnail)
        database.set(data, for: key)
        database.setValue(type, key + ":type")
    }

    // MARK: Replies

    public func recordReply(_ command: UUID, quoting turnID: String) {
        replyTo[command] = turnID
        database.setValue(replyTo, "replyTo")
    }

    // MARK: Unread

    public func markOpened(_ conversation: UUID, at date: Date = Date()) {
        let positions = (readPositions[conversation] ?? [:]).merging(projection.transcriptPositions(in: conversation), uniquingKeysWith: max)
        if readPositions[conversation] != positions {
            readPositions[conversation] = positions
            database.setValue(readPositions, "readPositions")
        }
        guard (lastOpened[conversation] ?? .distantPast) < date else { return }
        lastOpened[conversation] = date
        database.setValue(lastOpened, "lastOpened")
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
        lastOpened = [:]
        readPositions = [:]
        unreadSince = nil
        replyTo = [:]
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
