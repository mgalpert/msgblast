import CryptoKit
import XCTest
@testable import msgblastCore
import msgblastRemoteProtocol

/// A phone over the in-memory transport, driven by the shared client state machine.
@MainActor
private final class TestPhone {
    let connection: InMemoryRemoteConnection
    let driver: RemoteClientDriver
    var events: [RemoteClientDriver.Event] = []
    var closed = false
    var failure: Error?
    init(connection: InMemoryRemoteConnection, mode: RemoteClientDriver.Mode, since: UInt64? = nil) {
        self.connection = connection
        driver = RemoteClientDriver(mode: mode, sinceSeq: since)
        connection.onReceive = { [weak self] bytes in
            guard let self else { return }
            do {
                let (outgoing, events) = try self.driver.receive(bytes)
                self.events += events
                outgoing.forEach(self.connection.send)
            } catch { self.failure = error }
        }
        connection.onClose = { [weak self] in self?.closed = true }
        connection.send(try! driver.start())
    }
    func send(_ message: RemoteMessage) { connection.send(try! driver.frame(message)) }
    var errors: [RemoteErrorMessage] { events.compactMap { if case .error(let e) = $0 { e } else { nil } } }
    var snapshots: [RemoteSnapshot] { events.compactMap { if case .snapshot(let s) = $0 { s } else { nil } } }
    var eventBatches: [[RemoteEvent]] { events.compactMap { if case .events(let e, _) = $0 { e } else { nil } } }
    var results: [RemoteCommandResult] { events.compactMap { if case .commandResult(let r) = $0 { r } else { nil } } }
    var paired: (RemotePairComplete, Data)? { events.lazy.compactMap { if case .paired(let p, let k) = $0 { (p, k) } else { nil } }.first }
    var authenticated: UUID? { events.lazy.compactMap { if case .authenticated(let id) = $0 { id } else { nil } }.first }
}

@MainActor
final class RemoteServerTests: XCTestCase {
    private var locked = false
    private var grid = ["claude"]
    private func status() -> MacStatus {
        MacStatus(macName: "Studio", variant: .demo, locked: locked, awake: true, databaseAvailable: true, databaseStatus: "ok", messagesBusy: false, broadcastBusy: false,
                  sendingAgentIDs: [], keepAwakeEnabled: true, keepAwakeHeld: false, messagesSendsAllowed: false, observedAt: Date())
    }
    private func state() -> RemoteProjectionState {
        RemoteProjectionState(macStatus: status(), grid: RemoteGrid(visibleAgentIDs: grid), agents: [FakeRemoteHost.agent("claude")], conversations: [], turns: [], attempts: [])
    }
    private func makeServer() throws -> (RemoteServer, RemoteChangeJournal, FakeRemoteHost) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-remote-server-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let host = FakeRemoteHost()
        host.agents["claude"] = FakeRemoteHost.agent("claude")
        let journal = RemoteChangeJournal(startingSeq: 500)
        let identity = try RemoteIdentity(signingKey: P256.Signing.PrivateKey(), storage: .sessionOnly)
        let server = RemoteServer(identity: identity, pairing: RemotePairing(directory: directory), executor: RemoteCommandExecutor(host: host), journal: journal,
                                  variant: .demo, macName: { "Studio" }, isLocked: { [unowned self] in self.locked }, refreshJournal: { [unowned self] in journal.apply(self.state()) })
        objc_setAssociatedObject(server, "host", host, .OBJC_ASSOCIATION_RETAIN)
        return (server, journal, host)
    }
    private func connect(_ server: RemoteServer, _ mode: RemoteClientDriver.Mode, since: UInt64? = nil) -> TestPhone {
        let (serverEnd, clientEnd) = InMemoryRemoteConnection.pair()
        server.accept(serverEnd)
        return TestPhone(connection: clientEnd, mode: mode, since: since)
    }
    private func settle(_ until: () -> Bool = { false }) async {
        for _ in 0..<100 { if until() { return }; try? await Task.sleep(for: .milliseconds(5)) }
    }

    func testPairSnapshotEventsCommandsAndResume() async throws {
        let (server, journal, host) = try makeServer()
        var changes: [Bool] = []
        server.onClientChange = { changes.append($0) }
        let offer = try server.pairing.openOffer(macName: "Studio", variant: .demo, endpoints: [], port: 1, identity: server.identity)
        let phoneKey = P256.Signing.PrivateKey()
        let phone = connect(server, .pair(offer: offer, deviceName: "Test iPhone", deviceKey: phoneKey))
        await settle { !phone.snapshots.isEmpty }
        let (paired, macKey) = try XCTUnwrap(phone.paired)
        XCTAssertEqual(macKey, server.identity.publicKeyX963)
        XCTAssertEqual(server.pairing.device?.id, paired.deviceID)
        XCTAssertEqual(server.connectedDeviceID, paired.deviceID)
        XCTAssertEqual(changes, [true])
        XCTAssertEqual(phone.snapshots.first?.grid.visibleAgentIDs, ["claude"])
        XCTAssertEqual(phone.snapshots.first?.seq, journal.seq)

        // Live events stream with their seq; commands return results; ping reports seq.
        grid = ["claude", "codexCLI"]
        server.broadcast(journal.apply(state()))
        await settle { !phone.eventBatches.isEmpty }
        XCTAssertEqual(phone.eventBatches.last?.map(\.change.kind), ["grid"])
        let command = RemoteCommand(action: .createConversation(text: "Hi", agentIDs: ["claude"], attachmentIDs: []))
        phone.send(.command(command))
        phone.send(.command(command))
        phone.send(.ping(nonce: 9))
        await settle { phone.results.count >= 2 && phone.events.contains { if case .pong = $0 { true } else { false } } }
        // The duplicate arrives while the first copy runs: it reports progress, not a second send.
        XCTAssertEqual(Set(phone.results.map(\.outcome)), [.accepted, .applied])
        XCTAssertEqual(phone.results.first { $0.outcome == .accepted }?.replayed, true)
        phone.send(.command(command))
        await settle { phone.results.count >= 3 }
        XCTAssertEqual(phone.results.last?.outcome, .applied)
        XCTAssertEqual(phone.results.last?.replayed, true)
        XCTAssertEqual(host.sends.count, 1, "The replayed command id did not send twice")
        let cursor = journal.seq

        // Reconnect with the paired key from a saved cursor: only the missed events arrive.
        phone.connection.close()
        await settle { server.connectedDeviceID == nil }
        XCTAssertEqual(changes, [true, false])
        grid = ["codexCLI"]
        _ = journal.apply(state())
        let resumed = connect(server, .resume(deviceID: paired.deviceID, deviceKey: phoneKey, macIdentityKey: macKey), since: cursor)
        await settle { !resumed.eventBatches.isEmpty }
        XCTAssertEqual(resumed.authenticated, paired.deviceID)
        XCTAssertTrue(resumed.snapshots.isEmpty, "A recent cursor resumes without a snapshot")
        XCTAssertEqual(resumed.eventBatches.first?.map(\.change.kind), ["grid"])

        // A too-old cursor gets a snapshot.
        resumed.connection.close()
        await settle { server.connectedDeviceID == nil }
        let stale = connect(server, .resume(deviceID: paired.deviceID, deviceKey: phoneKey, macIdentityKey: macKey), since: 3)
        await settle { !stale.snapshots.isEmpty }
        XCTAssertEqual(stale.snapshots.first?.grid.visibleAgentIDs, ["codexCLI"])
    }

    func testStrangersWrongCodesAndClosedPairingAreRefused() async throws {
        let (server, _, _) = try makeServer()
        let notOpen = try RemotePairingOffer(url: try server.pairing.openOffer(macName: "Studio", variant: .demo, endpoints: [], port: 1, identity: server.identity).url)
        server.pairing.closeOffer()
        let late = connect(server, .pair(offer: notOpen, deviceName: "Late", deviceKey: P256.Signing.PrivateKey()))
        await settle { late.closed }
        XCTAssertEqual(late.errors.first?.code, .pairingClosed)

        var wrong = try server.pairing.openOffer(macName: "Studio", variant: .demo, endpoints: [], port: 1, identity: server.identity)
        wrong.code = "not-the-code"
        let guesser = connect(server, .pair(offer: wrong, deviceName: "Guess", deviceKey: P256.Signing.PrivateKey()))
        await settle { guesser.closed }
        XCTAssertEqual(guesser.errors.first?.code, .pairingFailed)
        XCTAssertNil(server.pairing.device)

        let stranger = connect(server, .resume(deviceID: UUID(), deviceKey: P256.Signing.PrivateKey(), macIdentityKey: server.identity.publicKeyX963))
        await settle { stranger.closed }
        XCTAssertEqual(stranger.errors.first?.code, .notPaired)

        // A phone that pinned another Mac refuses this one before sending anything secret.
        let impostor = connect(server, .resume(deviceID: UUID(), deviceKey: P256.Signing.PrivateKey(), macIdentityKey: P256.Signing.PrivateKey().publicKey.x963Representation))
        await settle { impostor.failure != nil }
        XCTAssertEqual(impostor.failure as? RemoteProtocolError, .authenticationFailed)

        // Garbage before the handshake closes the connection.
        let (serverEnd, clientEnd) = InMemoryRemoteConnection.pair()
        var closed = false
        clientEnd.onClose = { closed = true }
        server.accept(serverEnd)
        clientEnd.send(try RemoteFraming.frame(Data("{\"kind\":\"command\"}".utf8)))
        await settle { closed }
        XCTAssertTrue(closed)
        XCTAssertNil(server.connectedDeviceID)
    }

    func testHandshakeTimeoutAndPendingLimit() async throws {
        let (server, _, _) = try makeServer()
        server.handshakeTimeout = .milliseconds(30)
        server.maximumPendingConnections = 1
        let (first, firstClient) = InMemoryRemoteConnection.pair()
        var firstClosed = false
        firstClient.onClose = { firstClosed = true }
        server.accept(first)
        let (second, secondClient) = InMemoryRemoteConnection.pair()
        var secondClosed = false
        secondClient.onClose = { secondClosed = true }
        server.accept(second)
        await settle { secondClosed }
        XCTAssertTrue(secondClosed, "Extra unauthenticated connections are refused")
        await settle { firstClosed }
        XCTAssertTrue(firstClosed, "A silent connection times out")
    }

    func testLockedMacIsDisconnectedAsAWholeAndResumesOnUnlock() async throws {
        let (server, journal, host) = try makeServer()
        let offer = try server.pairing.openOffer(macName: "Studio", variant: .demo, endpoints: [], port: 1, identity: server.identity)
        let phone = connect(server, .pair(offer: offer, deviceName: "Phone", deviceKey: P256.Signing.PrivateKey()))
        await settle { !phone.snapshots.isEmpty }
        locked = true
        host.isLocked = true
        server.broadcast(journal.apply(state()))
        grid = ["hidden while locked"]
        server.broadcast(journal.apply(state()))
        phone.send(.command(RemoteCommand(action: .createConversation(text: "Hi", agentIDs: ["claude"], attachmentIDs: []))))
        await settle { !phone.results.isEmpty }
        XCTAssertEqual(phone.errors.map(\.code), [.macLocked], "One notice, no data while locked")
        XCTAssertTrue(phone.eventBatches.isEmpty)
        XCTAssertEqual(phone.results.first?.code, .macLocked)
        XCTAssertTrue(host.sends.isEmpty)

        locked = false
        host.isLocked = false
        server.broadcast(journal.apply(state()))
        await settle { !phone.eventBatches.isEmpty }
        let kinds = phone.eventBatches.flatMap { $0.map(\.change.kind) }
        XCTAssertTrue(kinds.contains("grid"), "Changes made while locked arrive after unlock")
        XCTAssertEqual(kinds.filter { $0 == "macStatus" }.count, 2)
    }

    func testReconnectReplacesTheOlderConnection() async throws {
        let (server, _, _) = try makeServer()
        let key = P256.Signing.PrivateKey()
        let offer = try server.pairing.openOffer(macName: "Studio", variant: .demo, endpoints: [], port: 1, identity: server.identity)
        let first = connect(server, .pair(offer: offer, deviceName: "Phone", deviceKey: key))
        await settle { first.paired != nil }
        let (paired, macKey) = try XCTUnwrap(first.paired)
        let second = connect(server, .resume(deviceID: paired.deviceID, deviceKey: key, macIdentityKey: macKey))
        await settle { first.closed && second.authenticated != nil }
        XCTAssertEqual(first.errors.last?.code, .anotherClientConnected)
        XCTAssertEqual(server.connectedDeviceID, paired.deviceID)
    }
}

final class RemoteInterfaceTests: XCTestCase {
    private func ip(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 { a << 24 | b << 16 | c << 8 | d }

    func testOnlyTailscaleUtunAndPrivateLANAddressesQualify() {
        XCTAssertEqual(RemoteInterfaces.classify(interface: "utun3", ipv4: ip(100, 64, 0, 1)), .tailscale)
        XCTAssertEqual(RemoteInterfaces.classify(interface: "utun3", ipv4: ip(100, 127, 255, 254)), .tailscale)
        XCTAssertNil(RemoteInterfaces.classify(interface: "utun3", ipv4: ip(100, 128, 0, 1)), "Outside 100.64.0.0/10")
        XCTAssertNil(RemoteInterfaces.classify(interface: "en0", ipv4: ip(100, 64, 0, 1)), "CGNAT on a physical interface is a carrier address, not Tailscale")
        XCTAssertEqual(RemoteInterfaces.classify(interface: "en0", ipv4: ip(192, 168, 4, 25)), .lan)
        XCTAssertEqual(RemoteInterfaces.classify(interface: "en1", ipv4: ip(10, 0, 0, 2)), .lan)
        XCTAssertEqual(RemoteInterfaces.classify(interface: "en0", ipv4: ip(172, 20, 0, 2)), .lan)
        XCTAssertNil(RemoteInterfaces.classify(interface: "utun4", ipv4: ip(10, 8, 0, 2)), "Other VPN tunnels are not offered")
        XCTAssertNil(RemoteInterfaces.classify(interface: "lo0", ipv4: ip(127, 0, 0, 1)))
        XCTAssertNil(RemoteInterfaces.classify(interface: "en0", ipv4: ip(203, 0, 113, 9)), "Public addresses are never bound")
        XCTAssertNil(RemoteInterfaces.classify(interface: "bridge100", ipv4: ip(192, 168, 64, 1)))
    }

    func testBindPolicySelection() {
        let tailscale = [RemoteInterfaceAddress(interface: "utun0", address: "100.100.1.1", kind: .tailscale), RemoteInterfaceAddress(interface: "utun9", address: "100.68.0.2", kind: .tailscale)]
        let lan = [RemoteInterfaceAddress(interface: "en0", address: "192.168.1.5", kind: .lan)]
        XCTAssertEqual(RemoteInterfaces.select(tailscale + lan, policy: .automatic), tailscale, "Every Tailscale utun, and no LAN, when Tailscale is up")
        XCTAssertEqual(RemoteInterfaces.select(lan, policy: .automatic), lan)
        XCTAssertEqual(RemoteInterfaces.select(lan, policy: .tailscaleOnly), [])
        XCTAssertEqual(RemoteInterfaces.select(tailscale + lan, policy: .tailscaleAndLAN), tailscale + lan)
        XCTAssertEqual(RemoteInterfaces.select(tailscale + lan, policy: .lanOnly), lan)
        XCTAssertTrue(RemoteInterfaces.current().allSatisfy { !$0.address.hasPrefix("127.") && $0.address != "0.0.0.0" })
    }
}

@MainActor
private final class FakeBoundListener: RemoteBoundListener {
    let port: UInt16
    private(set) var cancelled = false
    init(port: UInt16) { self.port = port }
    func cancel() { cancelled = true }
}

/// The saved port is retried before a temporary one is used, and reclaimed afterwards.
@MainActor
final class RemoteListenerPortTests: XCTestCase {
    private let address = RemoteInterfaceAddress(interface: "utun4", address: "100.64.0.7", kind: .tailscale)
    private var attempts: [UInt16] = []
    private var savedPortFree: () -> Bool = { true }
    private var opened: [FakeBoundListener] = []

    private func listener(window: Duration = .milliseconds(200)) -> RemoteListener {
        RemoteListener(retry: .init(savedPortWindow: window, savedPortInterval: .milliseconds(10), reclaimInterval: .milliseconds(20), randomAttempts: 2),
                       addresses: { [address] _ in [address] }, randomPort: { 61_855 }) { [unowned self] _, port in
            self.attempts.append(port)
            guard port != 50_530 || self.savedPortFree() else { return nil }
            let bound = FakeBoundListener(port: port)
            self.opened.append(bound)
            return [bound]
        }
    }

    func testABusySavedPortIsRetriedUntilItIsFree() async {
        var failures = 3
        savedPortFree = { failures -= 1; return failures < 0 }
        let listener = listener()
        let port = await listener.start(policy: .automatic, port: 50_530)
        XCTAssertEqual(port, 50_530)
        XCTAssertEqual(attempts, [50_530, 50_530, 50_530, 50_530], "Three busy attempts, then the saved port")
        XCTAssertNil(listener.waitingForPort)
        XCTAssertEqual(listener.endpoints.map(\.host), ["100.64.0.7"])
    }

    func testATemporaryPortIsDroppedOnceTheSavedPortIsFree() async throws {
        var free = false
        savedPortFree = { free }
        let listener = listener(window: .milliseconds(50))
        let port = await listener.start(policy: .automatic, port: 50_530)
        XCTAssertEqual(port, 61_855, "After the retry window a temporary port is used")
        XCTAssertEqual(listener.waitingForPort, 50_530)
        XCTAssertGreaterThan(attempts.filter { $0 == 50_530 }.count, 1)
        free = true
        for _ in 0..<100 where listener.port != 50_530 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(listener.port, 50_530, "The saved port is reclaimed in the background")
        XCTAssertNil(listener.waitingForPort)
        XCTAssertTrue(opened.first { $0.port == 61_855 }?.cancelled == true, "The temporary listener is closed")
        XCTAssertFalse(opened.last?.cancelled ?? true)
        listener.shutdown()
    }

    func testNoReclaimWithoutAPairedPhone() async throws {
        savedPortFree = { false }
        let listener = listener(window: .milliseconds(30))
        _ = await listener.start(policy: .automatic, port: 50_530, reclaimSavedPort: { false })
        let tries = attempts.count
        savedPortFree = { true }
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(listener.port, 61_855)
        XCTAssertEqual(attempts.count, tries, "Without a paired phone the saved port is not retried")
        listener.shutdown()
    }
}
