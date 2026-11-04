import Combine
import Foundation
import msgblastRemoteProtocol

/// A byte stream to one client: a TLS connection on a direct route, or memory in
/// Demo and tests. Framing and encryption are the same on every route.
@MainActor
public protocol RemoteConnection: AnyObject {
    var onReceive: ((Data) -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    var peer: String { get }
    func start()
    func send(_ data: Data)
    func close()
}

/// Two linked in-memory ends. Delivery is asynchronous and in order, like a socket.
@MainActor
public final class InMemoryRemoteConnection: RemoteConnection {
    public var onReceive: ((Data) -> Void)?
    public var onClose: (() -> Void)?
    public let peer: String
    private weak var other: InMemoryRemoteConnection?
    private var inbox: [Data] = []
    private var draining = false
    public private(set) var closed = false
    private init(peer: String) { self.peer = peer }
    public static func pair() -> (server: InMemoryRemoteConnection, client: InMemoryRemoteConnection) {
        let server = InMemoryRemoteConnection(peer: "in-memory client"), client = InMemoryRemoteConnection(peer: "in-memory Mac")
        server.other = client; client.other = server
        return (server, client)
    }
    public func start() {}
    public func send(_ data: Data) {
        guard !closed, let other, !other.closed else { return }
        other.inbox.append(data)
        other.scheduleDrain()
    }
    private func scheduleDrain() {
        guard !draining else { return }
        draining = true
        Task { @MainActor in
            // Remove before delivering: optional chaining would skip the argument when nobody listens.
            while !self.inbox.isEmpty, !self.closed {
                let data = self.inbox.removeFirst()
                self.onReceive?(data)
            }
            self.draining = false
        }
    }
    public func close() {
        guard !closed else { return }
        closed = true
        let other = other
        Task { @MainActor in self.onClose?(); other?.close() }
    }
}

/// One client session: plaintext hello, signed server hello, then encrypted pairing or
/// authentication, subscription, events, commands and pings.
@MainActor
final class RemoteServerSession {
    enum Phase { case awaitingHello, awaitingPairing(challenge: Data), awaitingAuthentication, authenticated(UUID), closed }
    let connection: RemoteConnection
    private unowned let server: RemoteServer
    private(set) var phase: Phase = .awaitingHello
    private var decoder = RemoteFrameDecoder()
    private var channel: RemoteSecureChannel?
    private var subscribed = false
    private var deliveredSeq: UInt64?
    private var lockNoticeSent = false
    private var timeout: Task<Void, Never>?

    init(connection: RemoteConnection, server: RemoteServer) {
        self.connection = connection; self.server = server
    }

    var deviceID: UUID? { if case .authenticated(let id) = phase { id } else { nil } }

    func start() {
        connection.onReceive = { [weak self] bytes in self?.receive(bytes) }
        connection.onClose = { [weak self] in self?.closed() }
        connection.start()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: self?.server.handshakeTimeout ?? .seconds(15))
            guard let self, !Task.isCancelled, self.deviceID == nil else { return }
            self.fail(.handshakeTimeout, "The connection did not finish pairing or signing in.")
        }
    }

    private func closed() {
        guard case .closed = phase else {
            phase = .closed
            timeout?.cancel()
            server.sessionEnded(self)
            return
        }
    }

    func close() {
        guard !isClosed else { return }
        phase = .closed
        timeout?.cancel()
        connection.close()
        server.sessionEnded(self)
    }
    private var isClosed: Bool { if case .closed = phase { true } else { false } }

    private func sendPlain(_ message: RemoteHandshakeMessage) {
        guard let data = try? RemoteProtocol.encoder().encode(message), let frame = try? RemoteFraming.frame(data) else { return }
        connection.send(frame)
    }

    func send(_ message: RemoteMessage) {
        guard !isClosed, var channel else { return }
        do {
            let frame = try RemoteFraming.frame(try channel.seal(message))
            self.channel = channel
            connection.send(frame)
        } catch { close() }
    }

    func fail(_ code: RemoteErrorMessage.Code, _ message: String) {
        let error = RemoteErrorMessage(code: code, message: message)
        if channel != nil { send(.error(error)) } else { sendPlain(.error(error)) }
        close()
    }

    private func receive(_ bytes: Data) {
        guard !isClosed else { return }
        do {
            for payload in try decoder.append(bytes) {
                guard !isClosed else { return }
                if channel == nil { try handshake(payload) }
                else {
                    var channel = channel!
                    let message = try channel.open(payload)
                    self.channel = channel
                    handle(message)
                }
            }
        } catch {
            fail(.protocolViolation, "The connection sent data msgblast could not verify.")
        }
    }

    private func handshake(_ payload: Data) throws {
        guard case .awaitingHello = phase, case .hello(let hello) = try RemoteProtocol.decoder().decode(RemoteHandshakeMessage.self, from: payload) else {
            throw RemoteProtocolError.unexpectedMessage("hello")
        }
        guard hello.protocolVersion >= RemoteProtocol.minimumSupportedVersion else {
            return fail(.unsupportedVersion, "Update msgblast on your phone to connect to this Mac.")
        }
        let (reply, channel) = try RemoteServerHandshake.respond(to: hello, identity: server.identity.signingKey, macName: server.macName(), variant: server.variant)
        sendPlain(.serverHello(reply))
        self.channel = channel
        switch hello.intent {
        case .pair:
            guard server.pairing.isOfferValid, let offer = server.pairing.offer else {
                return fail(.pairingClosed, "Pairing is not open on this Mac. Show a new code in msgblast Settings → Remote.")
            }
            let challenge = RemoteHandshake.randomNonce()
            phase = .awaitingPairing(challenge: challenge)
            send(.pairChallenge(RemotePairChallenge(challenge: challenge, expiresAt: offer.expiresAt)))
        case .resume:
            phase = .awaitingAuthentication
        }
    }

    private func handle(_ message: RemoteMessage) {
        switch (phase, message) {
        case (.awaitingPairing(let challenge), .pairResponse(let response)):
            switch server.pairing.complete(response, challenge: challenge, transcript: channel!.transcript) {
            case .success(let device):
                send(.pairComplete(RemotePairComplete(deviceID: device.id, macName: server.macName())))
                authenticated(device.id)
            case .failure(let failure):
                fail(failure.errorCode, failure.errorDescription ?? "Pairing failed.")
            }
        case (.awaitingAuthentication, .authenticate(let auth)):
            guard server.pairing.device != nil else { return fail(.notPaired, "This phone is not paired with this Mac. Pair it again from msgblast Settings → Remote.") }
            guard let device = server.pairing.verify(auth, transcript: channel!.transcript) else {
                return fail(.authenticationFailed, "This phone is not the one paired with this Mac.")
            }
            send(.authenticated(deviceID: device.id))
            authenticated(device.id)
        case (.authenticated, .subscribe(let since)):
            subscribed = true
            deliveredSeq = since
            deliverBacklog()
        case (.authenticated, .command(let command)):
            server.executor.submit(command) { [weak self] result in self?.send(.commandResult(result)) }
        case (.authenticated, .ping(let nonce)):
            send(.pong(nonce: nonce, seq: server.currentSeq))
        case (.authenticated, .pong), (.authenticated, .unknown):
            break
        default:
            fail(.protocolViolation, "Unexpected \(message.kind) message.")
        }
    }

    private func authenticated(_ id: UUID) {
        phase = .authenticated(id)
        timeout?.cancel()
        server.sessionAuthenticated(self)
    }

    /// Events after the client's cursor, or a full snapshot when the cursor is too old.
    func deliverBacklog() {
        guard subscribed, deviceID != nil else { return }
        if server.isLocked() { return noteLocked() }
        lockNoticeSent = false
        server.prepareJournal()
        if let since = deliveredSeq, let events = server.journal.events(since: since) {
            send(.events(events: events, latestSeq: server.journal.seq))
        } else if let snapshot = server.journal.snapshot() {
            for part in snapshot.parts() { send(.snapshot(part)) }
        }
        deliveredSeq = server.journal.seq
    }

    func push(_ events: [RemoteEvent]) {
        guard subscribed, deviceID != nil, !events.isEmpty else { return }
        if server.isLocked() { return noteLocked() }
        if lockNoticeSent { return deliverBacklog() }
        send(.events(events: events, latestSeq: server.journal.seq))
        deliveredSeq = server.journal.seq
    }

    /// A locked Mac is disconnected as a whole: one notice, then nothing until unlock.
    private func noteLocked() {
        guard !lockNoticeSent else { return }
        lockNoticeSent = true
        send(.error(RemoteErrorMessage(code: .macLocked, message: "Disconnected: your Mac is locked.")))
    }
}

/// Accepts connections, enforces one paired phone at a time, and fans projection
/// events out to it. The same server runs over TLS listeners or in-memory pairs.
@MainActor
public final class RemoteServer: ObservableObject {
    @Published public private(set) var connectedDeviceID: UUID?
    public let identity: RemoteIdentity
    public let pairing: RemotePairing
    public let executor: RemoteCommandExecutor
    public let journal: RemoteChangeJournal
    public let variant: MacVariant
    public var handshakeTimeout: Duration = .seconds(15)
    public var maximumPendingConnections = 3
    let macName: () -> String
    let isLocked: () -> Bool
    private let refreshJournal: () -> Void
    private var sessions: [RemoteServerSession] = []
    public var onClientChange: ((Bool) -> Void)?

    public init(identity: RemoteIdentity, pairing: RemotePairing, executor: RemoteCommandExecutor, journal: RemoteChangeJournal, variant: MacVariant,
                macName: @escaping () -> String, isLocked: @escaping () -> Bool, refreshJournal: @escaping () -> Void) {
        self.identity = identity; self.pairing = pairing; self.executor = executor; self.journal = journal; self.variant = variant
        self.macName = macName; self.isLocked = isLocked; self.refreshJournal = refreshJournal
    }

    public var currentSeq: UInt64 { journal.seq }
    public var hasClient: Bool { connectedDeviceID != nil }
    func prepareJournal() { if journal.state == nil { refreshJournal() } }

    public func accept(_ connection: RemoteConnection) {
        let pending = sessions.filter { $0.deviceID == nil }.count
        let session = RemoteServerSession(connection: connection, server: self)
        guard pending < maximumPendingConnections else {
            connection.close()
            return
        }
        sessions.append(session)
        session.start()
    }

    func sessionAuthenticated(_ session: RemoteServerSession) {
        // One paired phone: a newer authenticated connection (a reconnect) replaces the older one.
        for other in sessions where other !== session && other.deviceID != nil {
            other.fail(.anotherClientConnected, "This phone connected again from another network.")
        }
        pairing.markSeen()
        let wasConnected = connectedDeviceID != nil
        connectedDeviceID = session.deviceID
        if !wasConnected { onClientChange?(true) }
    }

    func sessionEnded(_ session: RemoteServerSession) {
        sessions.removeAll { $0 === session }
        let id = sessions.first { $0.deviceID != nil }?.deviceID
        if connectedDeviceID != nil && id == nil {
            connectedDeviceID = nil
            executor.discardUploads()
            onClientChange?(false)
        } else { connectedDeviceID = id }
    }

    public func broadcast(_ events: [RemoteEvent]) { for session in sessions { session.push(events) } }

    /// Called when the lock state changes; unlocking resumes from each client's cursor.
    public func lockStateChanged() { for session in sessions { session.deliverBacklog() } }

    public func disconnectAll(_ code: RemoteErrorMessage.Code, _ message: String) {
        for session in sessions { session.fail(code, message) }
    }
}
