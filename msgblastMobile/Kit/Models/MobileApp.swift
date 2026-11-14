import Combine
import CryptoKit
import Foundation
import msgblastRemoteProtocol

/// The phone app's root model: one paired Mac, its connection, and the local store.
@MainActor
public final class MobileApp: ObservableObject {
    public let store: MobileStore
    public let connection: MacConnection
    @Published public var keepAwake: Bool { didSet { defaults.set(keepAwake, forKey: "keepAwake"); connection.keepAwakeRequested = keepAwake; sendKeepAwake() } }
    private let database: LocalDatabase
    private let defaults: UserDefaults
    private var waiting: [UUID: CheckedContinuation<RemoteCommandResult, Error>] = [:]
    /// Callers of `perform` that want the Mac's `accepted` progress (queued, started).
    private var progress: [UUID: (RemoteCommandResult) -> Void] = [:]
    private var subscriptions: Set<AnyCancellable> = []
    public var commandTimeout: Duration = .seconds(90)
    /// Waits before asking again about a send the Mac says is still running (a replayed
    /// `accepted` after a reconnect), one per answer; the last repeats. Tests shorten them.
    public var requeryDelays: [Duration] = [.seconds(2), .seconds(4), .seconds(8), .seconds(10)]
    /// The scheduled follow-up query per command still waiting, and how many preceded it.
    private var requeries: [UUID: (task: Task<Void, Never>, attempt: Int)] = [:]
    /// The state before the current one, to tell a fresh race from a live session apart.
    private var lastConnectionState: MacConnectionState
    /// Command kinds the paired Mac answered `unsupported`: their controls hide until it is updated.
    @Published public var unsupportedActions: Set<String> = []
    private var snapshotRequested = false
    /// `fetchAvatar` commands in flight, by command id. Never recorded in the command ledger.
    private var avatarRequests: [UUID: String] = [:]
    /// References the Mac could not serve this session (for example an older Mac); not asked again.
    private var avatarsUnavailable: Set<String> = []

    public init(database: LocalDatabase, keys: DeviceKeyStore, defaults: UserDefaults = .standard,
                makeTransport: ((MacEndpoint, Data) -> ClientTransport)? = nil) throws {
        self.database = database
        self.defaults = defaults
        store = try MobileStore(database: database)
        let saved = try database.value(PairedMac.self, "pairedMac")
        if let makeTransport {
            connection = MacConnection(paired: saved, keys: keys, savePaired: { try? database.setValue($0, "pairedMac") }, makeTransport: makeTransport)
        } else {
            connection = MacConnection(paired: saved, keys: keys, savePaired: { try? database.setValue($0, "pairedMac") })
        }
        keepAwake = defaults.object(forKey: "keepAwake") as? Bool ?? true
        lastConnectionState = connection.state
        connection.keepAwakeRequested = keepAwake
        connection.onEvent = { [weak self] event in self?.handle(event) }
        connection.pendingCommandIDs = { [weak self] in self?.store.unresolvedCommandIDs ?? [] }
        connection.willReplacePairing = { [weak self] _ in self?.failWaiting(); self?.store.forgetMac() }
        connection.sinceSeq = { [weak self] in self?.store.projection.needsSnapshot == true ? nil : self?.store.projection.seq }
        connection.$state.removeDuplicates().sink { [weak self] state in
            guard let self else { return }
            let previous = self.lastConnectionState
            self.lastConnectionState = state
            // A new race started from a live session (pull to refresh) ends that session too.
            guard Self.sessionGone(state) || (state == .connecting && [.connected, .macLocked].contains(previous)) else { return }
            self.sessionLost()
        }.store(in: &subscriptions)
        connection.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        store.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
    }

    /// States with no session at all. Connecting has nothing to lose yet; a locked Mac keeps
    /// the session open and still answers (sends it refuses come back `rejected`).
    private static func sessionGone(_ state: MacConnectionState) -> Bool {
        switch state {
        case .stopped, .reconnecting, .pairingLost, .unpaired, .pairing: true
        case .connecting, .connected, .macLocked: false
        }
    }

    /// The session ended. Recorded commands keep waiting: the Mac may still finish them and
    /// answers the reconnect's query; only `commandTimeout` gives up on them. Read-only
    /// requests are never replayed, so theirs fail now.
    private func sessionLost() {
        for (_, requery) in requeries { requery.task.cancel() }
        requeries = [:]
        for (id, continuation) in waiting where store.commands[id] == nil {
            waiting[id] = nil
            continuation.resume(throwing: MobileConnectionError.unconfirmed)
        }
        // Artwork requests that got no answer are asked again after reconnecting.
        avatarRequests = [:]
    }

    /// Nothing can answer these any more: the pairing goes, and its records with it.
    private func failWaiting() {
        for (_, requery) in requeries { requery.task.cancel() }
        requeries = [:]
        for (_, continuation) in waiting { continuation.resume(throwing: MobileConnectionError.unconfirmed) }
        waiting = [:]
    }

    /// A send made through `perform` still waits on the Mac, whose result comes only to this session.
    public var hasPendingSends: Bool { waiting.keys.contains { store.commands[$0] != nil } }

    private func handle(_ event: RemoteClientDriver.Event) {
        if case .commandResult(let result) = event, let ref = avatarRequests.removeValue(forKey: result.clientCommandID) {
            receiveAvatar(result, ref: ref)
            return
        }
        store.handle(event)
        if case .commandResult(let result) = event, awaitsResult(result.clientCommandID) || requeries[result.clientCommandID] != nil {
            if result.outcome == .accepted { progress[result.clientCommandID]?(result) }
            if result.outcome != .accepted {
                requeries.removeValue(forKey: result.clientCommandID)?.task.cancel()
                waiting.removeValue(forKey: result.clientCommandID)?.resume(returning: result)
            } else if result.replayed {
                // Still running on the Mac after a reconnect: its final result goes only to the
                // session that submitted it, so this session asks again until it is final. This
                // includes a send restored after a relaunch, which has no waiter. Only queried, never resent.
                scheduleRequery(result.clientCommandID)
            }
        }
        if store.projection.needsSnapshot && !snapshotRequested { snapshotRequested = true; connection.requestSnapshot() }
        if case .snapshot = event { snapshotRequested = false }
        switch event { case .snapshot, .events: requestAvatars(); default: break }
    }

    /// Asks the Mac once for each artwork reference the projection names and the cache
    /// lacks: one request per reference in flight, none repeated after a refusal.
    public func requestAvatars() {
        guard connection.state.canSend else { return }
        let pending = Set(avatarRequests.values)
        for ref in store.missingAvatarRefs where !pending.contains(ref) && !avatarsUnavailable.contains(ref) {
            let command = RemoteCommand(action: .fetchAvatar(ref: ref))
            guard (try? connection.send(command)) != nil else { return }
            avatarRequests[command.clientCommandID] = ref
        }
    }

    /// Keeps the bytes only when they are what the reference names. An older Mac answers
    /// `unsupported`, and any refusal leaves the agent on initials.
    private func receiveAvatar(_ result: RemoteCommandResult, ref: String) {
        guard result.outcome == .applied, let data = result.avatar, data.count <= RemoteProtocol.maximumAvatarBytes,
              ref == "sha256:" + SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() else {
            if result.outcome != .accepted { avatarsUnavailable.insert(ref) }
            return
        }
        store.storeAvatar(data, for: ref)
    }

    /// Records it (saved before it leaves, so a relaunch can still ask about it) and sends now,
    /// or throws without queueing when disconnected. A record that cannot be written throws
    /// before anything is sent.
    @discardableResult
    public func send(_ action: RemoteAction) throws -> RemoteCommand {
        let command = RemoteCommand(action: action)
        try store.recordSent(command)
        do { try connection.send(command) } catch { store.discardUnsent(command.clientCommandID); throw error }
        return command
    }

    /// Sends and waits for the final result; `onSent` gets the command before the wait, so a
    /// caller can recognise a late result, and `onProgress` each `accepted` the Mac reports
    /// (waiting its turn, started). A lost connection does not end the wait: the Mac may
    /// still finish it and answers the reconnect's query. Only the timeout gives up, leaving the
    /// command unconfirmed in the store. It is never resent.
    public func perform(_ action: RemoteAction, onSent: ((RemoteCommand) -> Void)? = nil,
                        onProgress: ((RemoteCommandResult) -> Void)? = nil) async throws -> RemoteCommandResult {
        let command = try send(action)
        onSent?(command)
        progress[command.clientCommandID] = onProgress
        defer { progress[command.clientCommandID] = nil }
        let timeout = commandTimeout
        return try await withCheckedThrowingContinuation { continuation in
            waiting[command.clientCommandID] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, let pending = self.waiting.removeValue(forKey: command.clientCommandID) else { return }
                self.requeries.removeValue(forKey: command.clientCommandID)?.task.cancel()
                self.store.markUnconfirmed(command.clientCommandID)
                pending.resume(throwing: MobileConnectionError.unconfirmed)
            }
        }
    }

    /// A waiter in this run, or a recorded command (for example restored after a relaunch) not yet final.
    private func awaitsResult(_ id: UUID) -> Bool { waiting[id] != nil || store.commands[id]?.isFinal == false }

    private func scheduleRequery(_ id: UUID) {
        guard !requeryDelays.isEmpty else { return }
        let attempt = requeries[id]?.attempt ?? 0
        requeries[id]?.task.cancel()
        let delay = requeryDelays[min(attempt, requeryDelays.count - 1)]
        let task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.awaitsResult(id), self.connection.state.canSend else { return }
            try? self.connection.send(RemoteCommand(action: .queryCommand(clientCommandID: id)))
        }
        requeries[id] = (task, attempt + 1)
    }

    private func sendKeepAwake() {
        guard connection.state.canSend else { return }
        _ = try? send(.setKeepAwake(enabled: keepAwake))
    }

    public func pair(link: String, deviceName: String) async throws -> PairedMac {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)), let offer = try? RemotePairingOffer(url: url) else {
            throw RemotePairingError(message: "Not a msgblast pairing link")
        }
        return try await pair(offer: offer, deviceName: deviceName)
    }

    /// The current Mac and its cache are replaced only when the new pairing succeeds.
    public func pair(offer: RemotePairingOffer, deviceName: String) async throws -> PairedMac {
        return try await withCheckedThrowingContinuation { continuation in
            connection.pair(offer: offer, deviceName: deviceName) { continuation.resume(with: $0) }
        }
    }

    /// The inbox has the paired Mac's first snapshot.
    public var inboxReady: Bool { store.projection.seq != nil }

    /// Pairs, then waits (up to `inboxTimeout`) for the new Mac's first snapshot, so a
    /// pairing sheet closes onto a filled inbox. A failed pairing throws as `pair` does.
    public func pairAndWaitForInbox(offer: RemotePairingOffer, deviceName: String, inboxTimeout: Duration = .seconds(10)) async throws -> PairedMac {
        let mac = try await pair(offer: offer, deviceName: deviceName)
        let deadline = ContinuousClock.now + inboxTimeout
        while !inboxReady && ContinuousClock.now < deadline && connection.pairedMac == mac {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return mac
    }

    public func forgetMac() {
        avatarRequests = [:]
        avatarsUnavailable = []
        failWaiting()
        connection.forget()
        store.forgetMac()
    }

    /// What fetching an attachment gave: its bytes, or why there are none.
    public enum AttachmentFetch: Equatable, Sendable {
        case data(Data, type: String)
        /// The Mac refused (missing, too large); its short reason.
        case unavailable(String)
        /// This Mac cannot send attachments; open it on the Mac.
        case unsupported
        case notConnected
    }
    /// Thumbnails are asked for up to this size, full files up to the protocol's cap.
    public static let thumbnailBytes = 200_000

    /// One attachment from the cache, or from the Mac (then cached). Never recorded in the
    /// command ledger: a fetch has no effect to confirm.
    public func fetchAttachment(turnID: String, index: Int, thumbnail: Bool) async -> AttachmentFetch {
        if let cached = store.attachment(turnID: turnID, index: index, thumbnail: thumbnail) { return .data(cached.data, type: cached.type) }
        if unsupportedActions.contains("fetchAttachment") { return .unsupported }
        let maxBytes = thumbnail ? Self.thumbnailBytes : RemoteProtocol.maximumAttachmentFetchBytes
        guard let result = try? await request(.fetchAttachment(turnID: turnID, index: index, maxBytes: maxBytes)) else { return .notConnected }
        if result.outcome == .applied, let data = result.attachment {
            let type = result.attachmentType ?? "application/octet-stream"
            store.storeAttachment(data, type: type, turnID: turnID, index: index, thumbnail: thumbnail)
            return .data(data, type: type)
        }
        if result.code == .unsupported { unsupportedActions.insert("fetchAttachment"); return .unsupported }
        return .unavailable(result.message ?? "Open it on your Mac")
    }

    /// Sends a read-only request and waits for its result without recording it.
    private func request(_ action: RemoteAction) async throws -> RemoteCommandResult {
        let command = RemoteCommand(action: action)
        try connection.send(command)
        let timeout = commandTimeout
        return try await withCheckedThrowingContinuation { continuation in
            waiting[command.clientCommandID] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, let pending = self.waiting.removeValue(forKey: command.clientCommandID) else { return }
                pending.resume(throwing: MobileConnectionError.unconfirmed)
            }
        }
    }

    /// Splits a file into protocol-sized chunks, uploads it, and returns the Mac's attachment id.
    public func upload(_ data: Data, filename: String) async throws -> String {
        guard data.count <= RemoteProtocol.maximumAttachmentBytes else { throw RemotePairingError(message: "Files are limited to 25 MB") }
        let id = UUID()
        let chunks = stride(from: 0, to: data.count, by: RemoteProtocol.maximumAttachmentChunkBytes).map { data[$0..<min($0 + RemoteProtocol.maximumAttachmentChunkBytes, data.count)] }
        for (index, chunk) in chunks.enumerated() {
            let result = try await perform(.uploadAttachmentChunk(uploadID: id, filename: filename, index: index, count: chunks.count, data: Data(chunk)))
            guard result.outcome == .applied else { throw RemotePairingError(message: result.message ?? "Your Mac refused the file") }
        }
        let staged = try await perform(.attachStaged(uploadID: id, sha256: Data(SHA256.hash(data: data))))
        guard staged.outcome == .applied, let attachment = staged.attachmentID else { throw RemotePairingError(message: staged.message ?? "Your Mac refused the file") }
        return attachment
    }
}

/// Opening the phone's saved state. A file that cannot be read or decoded is a distinct
/// failure, left untouched for a retry; only a missing file starts empty.
public enum MobileLaunch {
    case ready(MobileApp)
    case loadFailed(String)

    @MainActor public static func open(databaseURL: URL, keys: DeviceKeyStore, defaults: UserDefaults = .standard) -> MobileLaunch {
        do { return .ready(try MobileApp(database: try LocalDatabase(url: databaseURL), keys: keys, defaults: defaults)) }
        catch { return .loadFailed(String(describing: error)) }
    }
}
