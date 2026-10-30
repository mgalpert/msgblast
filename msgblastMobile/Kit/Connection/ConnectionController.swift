import Combine
import Foundation
import Network
import msgblastRemoteProtocol

/// What the Mac banner shows.
public enum MacConnectionState: Equatable, Sendable {
    case unpaired
    case pairing
    case connecting
    case connected
    /// The Mac is locked: treated as disconnected as a whole, with its own text.
    case macLocked
    case reconnecting(attempt: Int, retryAt: Date)
    /// The Mac no longer knows this phone (forgotten or replaced). Pair again.
    case pairingLost(String)
    case stopped
    /// The banner's title: at most three words, Title Case.
    public var title: String {
        switch self {
        case .unpaired, .pairingLost: "Not Paired"
        case .pairing: "Pairing…"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .macLocked: "Mac Locked"
        case .reconnecting: "Reconnecting…"
        case .stopped: "Disconnected"
        }
    }
    /// A short sentence-case status for inline lines and Settings ("Mac locked", "Not connected").
    public var statusText: String {
        switch self {
        case .unpaired, .pairingLost: "Not paired"
        case .pairing: "Pairing…"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .macLocked: "Mac locked"
        case .reconnecting: "Reconnecting…"
        case .stopped: "Not connected"
        }
    }
    /// The explanation, shown on demand (the banner shows a reconnecting one after a while).
    public var detail: String? {
        switch self {
        case .macLocked: "Unlock your Mac to send"
        case .reconnecting: "Mac asleep, offline, or msgblast closed"
        case .pairingLost(let reason): reason
        default: nil
        }
    }
    public var isReconnecting: Bool { if case .reconnecting = self { true } else { false } }
    public var canSend: Bool { self == .connected }
}

public struct ConnectionTiming: Sendable {
    public var heartbeat: Duration = .seconds(20)
    public var silenceLimit: Duration = .seconds(45)
    public var backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)]
    /// How long the endpoint race may run before it gives up on every address.
    public var raceTimeout: Duration = .seconds(15)
    public init() {}
}

/// Keeps one encrypted session to the paired Mac: endpoint racing (QR addresses plus
/// Bonjour on the LAN), pinned TLS, the shared client driver, resume from the stored seq,
/// keep-awake request, heartbeat, and reconnect with backoff. It never queues a send.
@MainActor
public final class MacConnection: ObservableObject {
    @Published public private(set) var state: MacConnectionState
    @Published public private(set) var lastHeard: Date?
    @Published public private(set) var lastError: String?
    /// The candidate that won the last race (for example "100.101.102.103:52000" or a Bonjour name).
    @Published public private(set) var connectedVia: String?
    /// Time from starting the race to an authenticated session, for the last connection.
    @Published public private(set) var lastConnectSeconds: Double?
    private var raceStarted: Date?
    @Published public private(set) var pairedMac: PairedMac?
    /// Every decoded event, for the store's reducer.
    public var onEvent: ((RemoteClientDriver.Event) -> Void)?
    /// Called after (re)authentication with the ids of commands still waiting for a result.
    public var pendingCommandIDs: () -> [UUID] = { [] }
    public var sinceSeq: () -> UInt64? = { nil }
    /// Called when a new pairing succeeded, before its first snapshot, so the app can drop
    /// data from the previous Mac. Never called for a failed attempt.
    public var willReplacePairing: ((PairedMac) -> Void)?
    public var keepAwakeRequested = true
    public var timing = ConnectionTiming()

    private let keys: DeviceKeyStore
    private let makeTransport: (MacEndpoint, Data) -> ClientTransport
    private let savePaired: (PairedMac?) -> Void
    private let now: () -> Date
    private let racer = EndpointRacer()
    private var transport: ClientTransport?
    private var driver: RemoteClientDriver?
    private var attempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var bonjour: [MacEndpoint] = []
    private var browser: NWBrowser?
    private var pairing: (offer: RemotePairingOffer, name: String, completion: (Result<PairedMac, Error>) -> Void)?
    private var pairingCandidate: DeviceKeyCandidate?
    /// The previous Mac was connected when this pairing attempt started; reconnect if it fails.
    private var resumeAfterFailedPairing = false
    private var nonce: UInt64 = 0

    public init(paired: PairedMac?, keys: DeviceKeyStore, savePaired: @escaping (PairedMac?) -> Void, now: @escaping () -> Date = Date.init,
                makeTransport: @escaping (MacEndpoint, Data) -> ClientTransport = { NetworkClientTransport(endpoint: $0, pinnedSPKI: $1) }) {
        pairedMac = paired
        state = paired == nil ? .unpaired : .stopped
        self.keys = keys; self.savePaired = savePaired; self.now = now; self.makeTransport = makeTransport
    }

    // MARK: Pairing

    /// Pairs from a scanned or pasted `msgblast://pair` offer. Replaces any previous Mac.
    public func pair(offer: RemotePairingOffer, deviceName: String, completion: @escaping (Result<PairedMac, Error>) -> Void) {
        guard offer.expiresAt > now() else { completion(.failure(MobileConnectionError.offerExpired)); return }
        // The current pairing (key, Mac record, cache) stays untouched until the new one succeeds.
        let candidate: DeviceKeyCandidate
        do { candidate = try keys.makeCandidate() } catch { completion(.failure(error)); return }
        resumeAfterFailedPairing = pairedMac != nil && [.connected, .connecting, .macLocked].contains(state)
        reconnectTask?.cancel(); reconnectTask = nil
        stopTransport()
        let key = candidate.key
        pairingCandidate = candidate
        pairing = (offer, deviceName, completion)
        state = .pairing
        let endpoints = offer.endpoints.map { MacEndpoint.host($0.host, port: offer.port) } + bonjour
        open(endpoints, spki: offer.spkiSHA256, driver: RemoteClientDriver(mode: .pair(offer: offer, deviceName: deviceName, deviceKey: key)))
    }

    // MARK: Lifecycle

    public func connect() {
        guard let mac = pairedMac else { state = .unpaired; return }
        reconnectTask?.cancel()
        guard let key = try? keys.loadOrCreate() else { state = .pairingLost("This phone's key is missing. Pair again."); return }
        state = .connecting
        let driver = RemoteClientDriver(mode: .resume(deviceID: mac.deviceID, deviceKey: key, macIdentityKey: mac.identityKey), sinceSeq: sinceSeq())
        open(mac.endpoints + bonjour, spki: mac.spkiSHA256, driver: driver)
    }

    /// Going to the background or the user disconnecting. No reconnect until `connect()`.
    public func stop() {
        reconnectTask?.cancel(); reconnectTask = nil
        stopTransport()
        state = pairedMac == nil ? .unpaired : .stopped
    }

    public func forget() {
        stop()
        keys.delete()
        pairedMac = nil
        savePaired(nil)
        state = .unpaired
    }

    /// LAN discovery. The phone browses `_msgblast._tcp` and adds results as candidates.
    public func startBrowsing() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: RemoteProtocol.bonjourServiceType, domain: nil), using: NWParameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> MacEndpoint? in
                if case .service(let name, let type, let domain, _) = result.endpoint { return .bonjour(name: name, type: type, domain: domain) }
                return nil
            }
            MainActor.assumeIsolated { self?.bonjour = found }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    // MARK: Sending

    /// Sends a command now, or throws: commands are never queued while disconnected.
    public func send(_ command: RemoteCommand) throws {
        guard state.canSend, let transport, let driver else { throw MobileConnectionError.notConnected }
        transport.send(try driver.frame(.command(command)))
    }

    /// Asks the Mac for a full snapshot (after an unknown change kind or a gap).
    public func requestSnapshot() {
        guard state.canSend, let transport, let driver, let frame = try? driver.frame(.subscribe(sinceSeq: nil)) else { return }
        transport.send(frame)
    }

    // MARK: Internals

    private func open(_ endpoints: [MacEndpoint], spki: Data, driver: RemoteClientDriver) {
        stopTransport()
        raceStarted = now()
        self.driver = driver
        racer.race(endpoints, timeout: timing.raceTimeout, make: { [makeTransport] in makeTransport($0, spki) }) { [weak self] result in
            guard let self, self.driver === driver else { return }
            switch result {
            case .success(let transport):
                self.connectedVia = transport.label
                self.transport = transport
                transport.onReceive = { [weak self] bytes in self?.receive(bytes) }
                transport.onState = { [weak self] state in if state != .ready { self?.lost("The connection closed.") } }
                do { transport.send(try driver.start()) } catch { self.lost(error.localizedDescription) }
            case .failure(let failure):
                if self.pairing != nil {
                    // Keep the race failure itself so the pairing screen can tell an unreachable Mac apart.
                    self.lastError = failure.errorDescription
                    self.pairingFailed(failure)
                } else {
                    self.lost(failure.errorDescription ?? "Your Mac could not be reached.")
                }
            }
        }
    }

    private func receive(_ bytes: Data) {
        guard let driver, let transport else { return }
        lastHeard = now()
        do {
            let (outgoing, events) = try driver.receive(bytes)
            outgoing.forEach(transport.send)
            for event in events { handle(event) }
        } catch {
            let reason = (error as? RemoteProtocolError) == .authenticationFailed
                ? "Your Mac's identity did not match."
                : "The connection to your Mac failed: \(error.localizedDescription)"
            if pairing != nil { pairingFailed(RemotePairingError(message: reason)) }
            else { lost(reason, retry: pairedMac != nil) }
        }
    }

    private func handle(_ event: RemoteClientDriver.Event) {
        switch event {
        case .paired(let complete, let identityKey):
            guard let pending = pairing, let candidate = pairingCandidate else { break }
            let mac = PairedMac(macName: complete.macName, variant: pending.offer.variant, deviceID: complete.deviceID, identityKey: identityKey,
                                spkiSHA256: pending.offer.spkiSHA256, addresses: pending.offer.endpoints, port: pending.offer.port, pairedAt: now())
            do { try keys.store(candidate) } catch { pairingFailed(error); return }
            pairingCandidate = nil
            willReplacePairing?(mac)
            pairedMac = mac
            savePaired(mac)
            finishPairing(.success(mac))
            authenticated()
        case .authenticated:
            authenticated()
        case .error(let error):
            switch error.code {
            case .macLocked: state = .macLocked
            case .notPaired, .authenticationFailed, .forgotten:
                lastError = error.message
                stopTransport()
                state = .pairingLost(error.message)
            case .pairingClosed, .pairingFailed, .pairingReplaceNeedsConfirmation:
                lastError = error.message
                pairingFailed(RemotePairingError(message: error.message))
            case .anotherClientConnected:
                stopTransport()   // A newer connection of this phone took over.
            default:
                lastError = error.message
                lost(error.message)
            }
        case .snapshot, .events:
            if state == .macLocked { state = .connected }
        default: break
        }
        onEvent?(event)
    }

    private func authenticated() {
        if let started = raceStarted { lastConnectSeconds = now().timeIntervalSince(started); raceStarted = nil }
        attempt = 0
        state = .connected
        lastError = nil
        if keepAwakeRequested { try? send(RemoteCommand(action: .setKeepAwake(enabled: true))) }
        for id in pendingCommandIDs() { try? send(RemoteCommand(action: .queryCommand(clientCommandID: id))) }
        startHeartbeat()
    }

    /// A failed attempt returns to the previous Mac, reconnecting if it was connected.
    private func pairingFailed(_ error: Error) {
        guard pairing != nil else { return }
        stopTransport()
        pairingCandidate = nil
        finishPairing(.failure(error))
        state = pairedMac == nil ? .unpaired : .stopped
        if pairedMac != nil && resumeAfterFailedPairing { resumeAfterFailedPairing = false; connect() }
    }

    private func finishPairing(_ result: Result<PairedMac, Error>) {
        guard let pending = pairing else { return }
        pairing = nil
        pending.completion(result)
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.timing.heartbeat else { return }
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled, let transport = self.transport, let driver = self.driver else { return }
                let silence = self.lastHeard.map { self.now().timeIntervalSince($0) } ?? 0
                if silence > self.timing.silenceLimit.seconds {
                    self.lost("Your Mac stopped answering.")
                    return
                }
                self.nonce += 1
                if let frame = try? driver.frame(.ping(nonce: self.nonce)) { transport.send(frame) }
            }
        }
    }

    private func stopTransport() {
        heartbeat?.cancel(); heartbeat = nil
        racer.cancel()
        transport?.onReceive = nil; transport?.onState = nil
        transport?.cancel()
        transport = nil
        driver = nil
    }

    private func lost(_ reason: String, retry: Bool = true) {
        stopTransport()
        lastError = reason
        if pairing != nil { pairingFailed(RemotePairingError(message: reason)); return }
        guard retry, pairedMac != nil else { state = pairedMac == nil ? .unpaired : .stopped; return }
        let delay = timing.backoff[min(attempt, timing.backoff.count - 1)]
        attempt += 1
        let retryAt = now().addingTimeInterval(delay.seconds)
        state = .reconnecting(attempt: attempt, retryAt: retryAt)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }
}

public struct RemotePairingError: LocalizedError, Equatable, Sendable {
    public var message: String
    public var errorDescription: String? { message }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
