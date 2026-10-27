import CryptoKit
import XCTest
import msgblastRemoteProtocol
@testable import msgblastMobileKit

@MainActor
final class ConnectionTests: XCTestCase {
    private func settle(_ until: () -> Bool) async {
        for _ in 0..<200 { if until() { return }; try? await Task.sleep(for: .milliseconds(5)) }
    }
    private func make(_ mac: FakeMac, paired: PairedMac? = nil) -> (MacConnection, () -> [RemoteClientDriver.Event], () -> PairedMac?) {
        var saved: PairedMac? = paired
        var events: [RemoteClientDriver.Event] = []
        let connection = MacConnection(paired: paired, keys: MemoryDeviceKeyStore(), savePaired: { saved = $0 },
                                       makeTransport: { [mac] in mac.transport(for: $0, spki: $1) })
        connection.timing.backoff = [.milliseconds(10)]
        connection.onEvent = { events.append($0) }
        return (connection, { events }, { saved })
    }

    func testPairingRacesEndpointsSavesTheMacAndRequestsKeepAwake() async throws {
        let mac = FakeMac()
        mac.reachable = ["192.168.1.2:4000"]  // The Tailscale address fails; the LAN address wins.
        let (connection, events, saved) = make(mac)
        var result: Result<PairedMac, Error>?
        connection.pair(offer: mac.offer(), deviceName: "Test Phone") { result = $0 }
        XCTAssertEqual(connection.state, .pairing)
        await settle { connection.state == .connected && !events().isEmpty }
        let paired = try XCTUnwrap(try result?.get())
        XCTAssertEqual(paired.identityKey, mac.identity.publicKey.x963Representation)
        XCTAssertEqual(saved(), paired)
        XCTAssertEqual(paired.fingerprint.split(separator: " ").count, 6)
        XCTAssertEqual(connection.connectedVia, "192.168.1.2:4000", "The winning route is recorded")
        XCTAssertNotNil(connection.lastConnectSeconds)
        await settle { !mac.commands.isEmpty }
        XCTAssertEqual(mac.commands.first?.action, .setKeepAwake(enabled: true), "The phone asks for keep-awake on connect")
        XCTAssertTrue(events().contains { if case .snapshot = $0 { true } else { false } })
    }

    func testWrongCodeExpiredOfferAndImpostorNeverConnect() async throws {
        let mac = FakeMac()
        let (connection, _, saved) = make(mac)
        var wrong = mac.offer(); wrong.code = "guess"
        var failure: Error?
        connection.pair(offer: wrong, deviceName: "Phone") { if case .failure(let e) = $0 { failure = e } }
        await settle { failure != nil }
        XCTAssertNotNil(failure); XCTAssertNil(saved()); XCTAssertEqual(connection.state, .unpaired)

        var expired: Error?
        connection.pair(offer: mac.offer(expires: Date().addingTimeInterval(-1)), deviceName: "Phone") { if case .failure(let e) = $0 { expired = e } }
        XCTAssertEqual(expired as? MobileConnectionError, .offerExpired)

        // An offer whose identity hash belongs to another Mac fails the signed handshake.
        var impostor = mac.offer(); impostor.identityKeySHA256 = RemoteHandshake.keyHash(P256.Signing.PrivateKey().publicKey.x963Representation)
        var refused: Error?
        connection.pair(offer: impostor, deviceName: "Phone") { if case .failure(let e) = $0 { refused = e } }
        await settle { refused != nil }
        XCTAssertNotNil(refused); XCTAssertNil(saved())
    }

    func testSendsAreNeverQueuedWhileDisconnected() async throws {
        let mac = FakeMac()
        let (connection, _, _) = make(mac)
        XCTAssertThrowsError(try connection.send(RemoteCommand(action: .setKeepAwake(enabled: true)))) {
            XCTAssertEqual($0 as? MobileConnectionError, .notConnected)
        }
        XCTAssertTrue(mac.commands.isEmpty)
    }

    func testReconnectResumesFromSeqAndQueriesUnconfirmedCommands() async throws {
        let mac = FakeMac()
        let (connection, events, _) = make(mac)
        connection.pair(offer: mac.offer(), deviceName: "Phone") { _ in }
        await settle { connection.state == .connected && !events().isEmpty }
        let pending = UUID()
        connection.pendingCommandIDs = { [pending] }
        connection.sinceSeq = { 10 }
        let before = mac.sessions.count
        mac.sessions.forEach { $0.transport.drop() }
        await settle { if case .reconnecting = connection.state { true } else { false } }
        // Both QR addresses race, so each attempt may open more than one session.
        await settle { mac.sessions.dropFirst(before).contains { $0.sinceSeq == 10 } && connection.state == .connected }
        XCTAssertTrue(mac.sessions.dropFirst(before).contains { $0.sinceSeq == 10 }, "Resume from the stored seq")
        await settle { mac.commands.contains { $0.action == .queryCommand(clientCommandID: pending) } }
        XCTAssertTrue(mac.commands.contains { $0.action == .queryCommand(clientCommandID: pending) }, "Unconfirmed commands are queried, never resent")
        XCTAssertTrue(events().contains { if case .events = $0 { true } else { false } })
    }

    func testLockedMacAndForgottenPhone() async throws {
        let mac = FakeMac()
        let (connection, events, _) = make(mac)
        connection.pair(offer: mac.offer(), deviceName: "Phone") { _ in }
        await settle { connection.state == .connected && !events().isEmpty }
        mac.lockedOnConnect = true
        mac.sessions.forEach { $0.transport.drop() }
        await settle { connection.state == .macLocked }
        XCTAssertEqual(connection.state.bannerText, "Disconnected: your Mac is locked")
        XCTAssertFalse(connection.state.canSend)

        mac.lockedOnConnect = false
        mac.forgetOnResume = true
        mac.sessions.forEach { $0.transport.drop() }
        await settle { if case .pairingLost = connection.state { true } else { false } }
        guard case .pairingLost = connection.state else { return XCTFail("\(connection.state)") }
        let count = mac.connections
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(mac.connections, count, "A forgotten phone stops reconnecting")
        connection.forget()
        XCTAssertEqual(connection.state, .unpaired)
        XCTAssertNil(connection.pairedMac)
    }

    func testAFailedPairingKeepsTheExistingPairingKeyAndCache() async throws {
        let mac = FakeMac()
        let keys = MemoryDeviceKeyStore()
        let app = MobileApp(database: try LocalDatabase(url: nil), keys: keys, defaults: UserDefaults(suiteName: "pair-\(UUID().uuidString)")!,
                            makeTransport: { [mac] in mac.transport(for: $0, spki: $1) })
        let paired = try await app.pair(offer: mac.offer(), deviceName: "Phone")
        for _ in 0..<200 where app.store.projection.seq == nil { try await Task.sleep(for: .milliseconds(5)) }
        app.store.setDraft("Keep me", for: "new|all")
        let cached = app.store.projection
        let key = try XCTUnwrap(keys.storedPublicKey)
        XCTAssertEqual(app.connection.state, .connected)

        var wrong = mac.offer(); wrong.code = "wrong"
        do { _ = try await app.pair(offer: wrong, deviceName: "Phone"); XCTFail("A wrong code must not pair") } catch {}
        XCTAssertEqual(app.connection.pairedMac, paired, "The previous Mac record stays")
        XCTAssertEqual(keys.storedPublicKey, key, "The previous device key stays")
        XCTAssertEqual(app.store.projection.seq, cached.seq)
        XCTAssertEqual(app.store.projection.agents, cached.agents, "The cache is intact")
        XCTAssertEqual(app.store.draft("new|all"), "Keep me")
        for _ in 0..<200 where app.connection.state != .connected { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(app.connection.state, .connected, "The previous Mac reconnects and still authenticates")
        for _ in 0..<200 where !mac.sessions.contains(where: { $0.sinceSeq == cached.seq && $0.sinceSeq != nil }) { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(mac.sessions.contains { $0.sinceSeq == cached.seq }, "Resumed with the old pairing")

        // An unreachable Mac during a new pairing also leaves everything in place.
        mac.reachable = []
        do { _ = try await app.pair(offer: mac.offer(), deviceName: "Phone"); XCTFail("Unreachable") } catch {}
        XCTAssertEqual(keys.storedPublicKey, key)
        XCTAssertEqual(app.connection.pairedMac, paired)

        // A successful new pairing replaces the key and clears the old cache.
        mac.reachable = ["100.64.0.1:4000", "192.168.1.2:4000"]
        _ = try await app.pair(offer: mac.offer(), deviceName: "Phone")
        XCTAssertNotEqual(keys.storedPublicKey, key)
        XCTAssertEqual(app.store.draft("new|all"), "", "Drafts for the previous Mac are dropped only on success")
    }

    func testUnconfirmedIsNotNotConnected() {
        XCTAssertTrue(MobileConnectionError.notConnected.errorDescription!.contains("Nothing was sent"))
        XCTAssertFalse(MobileConnectionError.unconfirmed.errorDescription!.contains("Nothing was sent"))
    }
}
