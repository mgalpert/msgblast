import XCTest
import CryptoKit
@testable import msgblastCore
import msgblastRemoteProtocol

@MainActor
final class RemotePairingTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-remote-pairing-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func identity() throws -> RemoteIdentity { try RemoteIdentity(signingKey: P256.Signing.PrivateKey(), storage: .sessionOnly) }
    private func pairing(_ folder: URL) -> RemotePairing { RemotePairing(directory: folder, now: { [unowned self] in self.clock }) }
    private func response(code: String, challenge: Data, transcript: Data, key: P256.Signing.PrivateKey = .init(), name: String = "Test iPhone") throws -> RemotePairResponse {
        let publicKey = key.publicKey.x963Representation
        return RemotePairResponse(deviceName: name, devicePublicKey: publicKey,
            proof: RemoteHandshake.pairingProof(code: code, challenge: challenge, transcript: transcript, devicePublicKey: publicKey),
            signature: try key.signature(for: RemoteHandshake.pairingSignedData(transcript: transcript, challenge: challenge)).derRepresentation)
    }

    func testHappyPathPersistsOnlyTheDeviceRecordAndConsumesTheCode() throws {
        let folder = directory()
        let pairing = pairing(folder)
        let mac = try identity()
        let offer = try pairing.openOffer(macName: "Studio", variant: .demo, endpoints: [RemoteEndpoint(host: "100.64.0.9", kind: .tailscale)], port: 50000, identity: mac)
        XCTAssertEqual(offer.spkiSHA256, mac.spkiSHA256)
        XCTAssertEqual(offer.expiresAt, clock.addingTimeInterval(120))
        let challenge = RemoteHandshake.randomNonce(), transcript = RemoteHandshake.randomNonce()
        let phone = P256.Signing.PrivateKey()
        let paired = try pairing.complete(try response(code: offer.code, challenge: challenge, transcript: transcript, key: phone), challenge: challenge, transcript: transcript).get()
        XCTAssertEqual(paired.publicKey, phone.publicKey.x963Representation)
        XCTAssertNil(pairing.offer, "A used code cannot pair a second device")
        XCTAssertEqual(pairing.complete(try response(code: offer.code, challenge: challenge, transcript: transcript), challenge: challenge, transcript: transcript), .failure(.noOffer))

        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: pairing.url.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
        let reloaded = RemotePairing(directory: folder)
        XCTAssertEqual(reloaded.device, paired)

        // Resume: the phone signs the session transcript with the paired key.
        let session = RemoteHandshake.randomNonce()
        let auth = RemoteAuthenticate(deviceID: paired.id, signature: try phone.signature(for: session).derRepresentation)
        XCTAssertEqual(reloaded.verify(auth, transcript: session)?.id, paired.id)
        XCTAssertNil(reloaded.verify(auth, transcript: RemoteHandshake.randomNonce()), "A signature from another session is refused")
        XCTAssertNil(reloaded.verify(RemoteAuthenticate(deviceID: UUID(), signature: auth.signature), transcript: session))
        let stranger = RemoteAuthenticate(deviceID: paired.id, signature: try P256.Signing.PrivateKey().signature(for: session).derRepresentation)
        XCTAssertNil(reloaded.verify(stranger, transcript: session))
    }

    func testWrongCodesExpiryAndAttemptLimit() throws {
        let pairing = pairing(directory())
        let offer = try pairing.openOffer(macName: "Studio", variant: .demo, endpoints: [], port: 1, identity: try identity())
        let challenge = RemoteHandshake.randomNonce(), transcript = RemoteHandshake.randomNonce()
        for attempt in 1...RemotePairing.maximumFailedAttempts {
            XCTAssertEqual(pairing.complete(try response(code: "wrong-\(attempt)", challenge: challenge, transcript: transcript), challenge: challenge, transcript: transcript), .failure(.invalidProof))
        }
        XCTAssertNil(pairing.offer, "Five wrong codes close pairing")
        XCTAssertEqual(pairing.complete(try response(code: offer.code, challenge: challenge, transcript: transcript), challenge: challenge, transcript: transcript), .failure(.noOffer))

        let second = try pairing.openOffer(macName: "Studio", variant: .demo, endpoints: [], port: 1, identity: try identity())
        clock = clock.addingTimeInterval(121)
        XCTAssertFalse(pairing.isOfferValid)
        XCTAssertEqual(pairing.complete(try response(code: second.code, challenge: challenge, transcript: transcript), challenge: challenge, transcript: transcript), .failure(.expired))
        XCTAssertNil(pairing.device)

        // A proof bound to another session's transcript fails.
        let third = try pairing.openOffer(macName: "Studio", variant: .demo, endpoints: [], port: 1, identity: try identity())
        XCTAssertEqual(pairing.complete(try response(code: third.code, challenge: challenge, transcript: RemoteHandshake.randomNonce()), challenge: challenge, transcript: transcript), .failure(.invalidProof))
        // A device key that cannot sign the session is refused even with the right code.
        var forged = try response(code: third.code, challenge: challenge, transcript: transcript)
        forged.signature = try P256.Signing.PrivateKey().signature(for: transcript).derRepresentation
        XCTAssertEqual(pairing.complete(forged, challenge: challenge, transcript: transcript), .failure(.invalidDevice))
    }

    func testReplacingThePairedPhoneRequiresMacConfirmation() throws {
        let folder = directory()
        let pairing = pairing(folder)
        let mac = try identity()
        let challenge = RemoteHandshake.randomNonce(), transcript = RemoteHandshake.randomNonce()
        let first = try pairing.openOffer(macName: "Studio", variant: .demo, endpoints: [], port: 1, identity: mac)
        let old = try pairing.complete(try response(code: first.code, challenge: challenge, transcript: transcript, name: "Old"), challenge: challenge, transcript: transcript).get()

        XCTAssertThrowsError(try pairing.openOffer(macName: "Studio", variant: .demo, endpoints: [], port: 1, identity: mac)) {
            XCTAssertEqual($0 as? RemotePairingFailure, .replacementNeedsConfirmation("Old"))
        }
        XCTAssertEqual(pairing.device, old, "Refusing a replacement leaves the paired phone intact")

        let confirmed = try pairing.openOffer(macName: "Studio", variant: .demo, endpoints: [], port: 1, identity: mac, confirmReplacement: true)
        let new = try pairing.complete(try response(code: confirmed.code, challenge: challenge, transcript: transcript, name: "New"), challenge: challenge, transcript: transcript).get()
        XCTAssertNotEqual(new.id, old.id)
        XCTAssertEqual(RemotePairing(directory: folder).device?.name, "New", "One phone per Mac: the old record is replaced")

        try pairing.forget()
        XCTAssertNil(pairing.device)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pairing.url.path))
    }

    func testUnreadableDeviceRecordKeepsPairingClosedUntilForget() throws {
        let folder = directory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("remote-device.json")
        try Data("garbage".utf8).write(to: url); chmod(url.path, 0o600)
        let pairing = pairing(folder)
        XCTAssertNotNil(pairing.loadError)
        XCTAssertThrowsError(try pairing.openOffer(macName: "Studio", variant: .demo, endpoints: [], port: 1, identity: try identity()))
        XCTAssertEqual(try Data(contentsOf: url), Data("garbage".utf8), "The record is preserved")
        try pairing.forget()
        XCTAssertNil(pairing.loadError)
        XCTAssertNoThrow(try pairing.openOffer(macName: "Studio", variant: .demo, endpoints: [], port: 1, identity: try identity()))
    }
}
