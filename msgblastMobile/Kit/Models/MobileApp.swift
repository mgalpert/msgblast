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
    private var subscriptions: Set<AnyCancellable> = []
    public var commandTimeout: Duration = .seconds(90)
    private var snapshotRequested = false

    public init(database: LocalDatabase, keys: DeviceKeyStore, defaults: UserDefaults = .standard,
                makeTransport: ((MacEndpoint, Data) -> ClientTransport)? = nil) {
        self.database = database
        self.defaults = defaults
        store = MobileStore(database: database)
        let saved = database.value(PairedMac.self, "pairedMac")
        if let makeTransport {
            connection = MacConnection(paired: saved, keys: keys, savePaired: { database.setValue($0, "pairedMac") }, makeTransport: makeTransport)
        } else {
            connection = MacConnection(paired: saved, keys: keys, savePaired: { database.setValue($0, "pairedMac") })
        }
        keepAwake = defaults.object(forKey: "keepAwake") as? Bool ?? true
        connection.keepAwakeRequested = keepAwake
        connection.onEvent = { [weak self] event in self?.handle(event) }
        connection.pendingCommandIDs = { [weak self] in self?.store.unresolvedCommandIDs ?? [] }
        connection.willReplacePairing = { [weak self] _ in self?.store.forgetMac() }
        connection.sinceSeq = { [weak self] in self?.store.projection.needsSnapshot == true ? nil : self?.store.projection.seq }
        connection.$state.removeDuplicates().sink { [weak self] state in
            guard let self, !state.canSend else { return }
            self.store.connectionLost()
            // These commands were sent; the connection ended before their result.
            for (_, continuation) in self.waiting { continuation.resume(throwing: MobileConnectionError.unconfirmed) }
            self.waiting = [:]
        }.store(in: &subscriptions)
        connection.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        store.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
    }

    private func handle(_ event: RemoteClientDriver.Event) {
        store.handle(event)
        if case .commandResult(let result) = event, result.outcome != .accepted, let continuation = waiting.removeValue(forKey: result.clientCommandID) {
            continuation.resume(returning: result)
        }
        if store.projection.needsSnapshot && !snapshotRequested { snapshotRequested = true; connection.requestSnapshot() }
        if case .snapshot = event { snapshotRequested = false }
    }

    /// Sends now and records it, or throws without queueing when disconnected.
    @discardableResult
    public func send(_ action: RemoteAction) throws -> RemoteCommand {
        let command = RemoteCommand(action: action)
        try connection.send(command)
        store.recordSent(command)
        return command
    }

    /// Sends and waits for the final result. A lost connection or a timeout leaves the
    /// command unconfirmed in the store; it is never resent.
    public func perform(_ action: RemoteAction) async throws -> RemoteCommandResult {
        let command = try send(action)
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
        connection.forget()
        store.forgetMac()
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
