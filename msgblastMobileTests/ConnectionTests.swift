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
                                       makeTransport: { [unowned mac] in mac.transport(for: $0, spki: $1) })
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
        (mac.sessions.last!.transport).drop()
        await settle { if case .reconnecting = connection.state { true } else { false } }
        await settle { mac.connections == 2 && connection.state == .connected }
        XCTAssertEqual(mac.sessions.last?.sinceSeq, 10, "Resume from the stored seq")
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
        mac.sessions.last!.transport.drop()
        await settle { connection.state == .macLocked }
        XCTAssertEqual(connection.state.bannerText, "Disconnected: your Mac is locked")
        XCTAssertFalse(connection.state.canSend)

        mac.lockedOnConnect = false
        mac.forgetOnResume = true
        mac.sessions.last!.transport.drop()
        await settle { if case .pairingLost = connection.state { true } else { false } }
        guard case .pairingLost = connection.state else { return XCTFail("\(connection.state)") }
        let count = mac.connections
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(mac.connections, count, "A forgotten phone stops reconnecting")
        connection.forget()
        XCTAssertEqual(connection.state, .unpaired)
        XCTAssertNil(connection.pairedMac)
    }

    func testUnconfirmedIsNotNotConnected() {
        XCTAssertTrue(MobileConnectionError.notConnected.errorDescription!.contains("Nothing was sent"))
        XCTAssertFalse(MobileConnectionError.unconfirmed.errorDescription!.contains("Nothing was sent"))
    }
}
