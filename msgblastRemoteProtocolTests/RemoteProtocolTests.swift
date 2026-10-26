import XCTest
import CryptoKit
@testable import msgblastRemoteProtocol

final class RemoteProtocolCodingTests: XCTestCase {
    private func roundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try RemoteProtocol.encoder().encode(value)
        XCTAssertEqual(try RemoteProtocol.decoder().decode(T.self, from: data), value, file: file, line: line)
    }
    private let date = Date(timeIntervalSince1970: 1_790_000_000.123)

    private func availability(_ readiness: AgentReadiness) -> AgentAvailability {
        AgentAvailability(agentID: "chatgptApp", product: .chatgpt, form: .macApp, displayName: "ChatGPT", visibleInGrid: true, selectedForSharedSend: false,
            capabilities: AgentCapabilities(sharedSend: true, privateSend: true, attachments: false, namedCopies: false, endConversation: true, sharesOneConversation: false),
            readiness: readiness, reasons: [AvailabilityReason(code: .permissionMissing, userText: "Allow Accessibility on the Mac.", fixOn: .mac, permission: .accessibility),
                                            AvailabilityReason(code: .incompleteRequestBlocking, userText: "Review the request.", fixOn: .phone, attemptID: UUID().uuidString)],
            observedAt: date, source: .lastKnown)
    }
    private func status() -> MacStatus {
        MacStatus(macName: "Studio", variant: .demo, locked: false, awake: true, databaseAvailable: true, databaseStatus: "ok", messagesBusy: false,
                  broadcastBusy: true, sendingAgentIDs: ["claude"], keepAwakeEnabled: true, keepAwakeHeld: true, messagesSendsAllowed: false, observedAt: date)
    }

    func testEveryReadinessStateRoundTrips() throws {
        for readiness in [AgentReadiness.ready, .readyWillLaunch, .busy(detail: "Sending"), .blocked, .unavailable] {
            try roundTrip(availability(readiness))
        }
        XCTAssertEqual(availability(.ready).formLabel, "ChatGPT · Mac app")
    }

    func testUnknownValuesFromANewerPeerDecodeSafely() throws {
        let readiness = try RemoteProtocol.decoder().decode(AgentReadiness.self, from: Data(#"{"state":"warpSpeed"}"#.utf8))
        XCTAssertEqual(readiness, .unavailable, "An unknown state must never look sendable")
        XCTAssertFalse(readiness.acceptsSend)
        let code = try RemoteProtocol.decoder().decode(AvailabilityReasonCode.self, from: Data(#""brandNewReason""#.utf8))
        XCTAssertEqual(code.rawValue, "brandNewReason")
        let change = try RemoteProtocol.decoder().decode(RemoteChange.self, from: Data(#"{"kind":"hologram","payload":{}}"#.utf8))
        XCTAssertEqual(change, .unknown(kind: "hologram"))
        let action = try RemoteProtocol.decoder().decode(RemoteAction.self, from: Data(#"{"kind":"teleport"}"#.utf8))
        XCTAssertEqual(action, .unknown(kind: "teleport"))
        XCTAssertFalse(action.isSend)
        let status = try RemoteProtocol.decoder().decode(RemoteAttemptStatus.self, from: Data(#""quantum""#.utf8))
        XCTAssertEqual(status, .uncertain, "Unknown attempt status is treated as unresolved, never as sent")
    }

    func testEventsCommandsAndMessagesRoundTrip() throws {
        let conversation = UUID()
        let turn = RemoteTurn(id: "w:claude:\(conversation):0", conversationID: conversation, agentID: "claude", role: .assistant, origin: .agentTranscript,
                              text: "Hello", created: date, ordinal: 0, attachments: [RemoteAttachmentRef(id: "a", filename: "a.png", mimeType: "image/png", byteCount: 3)], contentHash: "abc")
        let attempt = RemoteAttempt(id: "wa:1", conversationID: conversation, agentID: "claude", text: "Hi", status: .waiting, detail: nil, created: date)
        let changes: [RemoteChange] = [.macStatus(status()), .grid(RemoteGrid(visibleAgentIDs: ["claude", "messages:x"])), .agentUpsert(availability(.ready)),
            .agentRemove(id: "claude"), .conversationUpsert(RemoteConversation(id: conversation, title: "T", prompt: "P", created: date, endedAt: nil, agentIDs: ["claude"], canEnd: false, unresolvedAttemptCount: 1, lastActivity: date,
                report: RemoteReport(provider: "Codex", overview: "o", comparison: nil, uncertainties: ["u"], running: false, error: nil))),
            .conversationRemove(id: conversation), .turnUpsert(turn), .turnRemove(id: turn.id), .attemptUpsert(attempt), .attemptRemove(id: attempt.id)]
        for (index, change) in changes.enumerated() { try roundTrip(RemoteEvent(seq: UInt64(index + 1), change: change)) }

        let actions: [RemoteAction] = [.createConversation(text: "Compare", agentIDs: ["claude", "messages:1"], attachmentIDs: []),
            .sendShared(conversationID: conversation, text: "More", agentIDs: [], attachmentIDs: ["x"]),
            .sendPrivate(conversationID: nil, agentID: "codexCLI", text: "Only you", attachmentIDs: []),
            .endConversation(conversationID: conversation), .acknowledgeIncomplete(agentID: "chatgptApp", attemptID: nil),
            .cancelNative(agentID: "claudeApp"), .setKeepAwake(enabled: true),
            .uploadAttachmentChunk(uploadID: UUID(), filename: "a.txt", index: 0, count: 2, data: Data([1, 2, 3])),
            .attachStaged(uploadID: UUID(), sha256: Data(SHA256.hash(data: Data([1])))), .requestReport(conversationID: conversation)]
        for action in actions { try roundTrip(RemoteCommand(action: action)) }
        XCTAssertEqual(actions.filter(\.isSend).count, 3)

        let snapshot = RemoteSnapshot(seq: 9, macStatus: status(), grid: RemoteGrid(visibleAgentIDs: []), agents: [availability(.blocked)], conversations: [], turns: [turn], attempts: [attempt])
        let messages: [RemoteMessage] = [.pairChallenge(RemotePairChallenge(challenge: Data(repeating: 1, count: 32), expiresAt: date)),
            .pairResponse(RemotePairResponse(deviceName: "iPhone", devicePublicKey: Data([4]), proof: Data([1]), signature: Data([2]))),
            .pairComplete(RemotePairComplete(deviceID: UUID(), macName: "Studio")), .authenticate(RemoteAuthenticate(deviceID: UUID(), signature: Data([3]))),
            .authenticated(deviceID: UUID()), .subscribe(sinceSeq: nil), .subscribe(sinceSeq: 4), .snapshot(snapshot),
            .events(events: [RemoteEvent(seq: 10, change: .turnRemove(id: "t"))], latestSeq: 10), .command(RemoteCommand(action: .setKeepAwake(enabled: false))),
            .commandResult(RemoteCommandResult(clientCommandID: UUID(), outcome: .applied, conversationID: conversation, agentStatuses: ["claude": .observed], replayed: true)),
            .commandResult(.rejected(UUID(), .macLocked, "Your Mac is locked.")),
            .ping(nonce: 7), .pong(nonce: 7, seq: 10), .error(RemoteErrorMessage(code: .notPaired, message: "Pair first."))]
        for message in messages { try roundTrip(message) }
    }

    func testSnapshotSplitsLargeTurnListsIntoOrderedParts() {
        let conversation = UUID()
        let turns = (0..<950).map { RemoteTurn(id: "\($0)", conversationID: conversation, agentID: nil, role: .user, origin: .followUp, text: "t", created: nil, ordinal: $0, contentHash: "h") }
        let snapshot = RemoteSnapshot(seq: 3, macStatus: status(), grid: RemoteGrid(visibleAgentIDs: []), agents: [availability(.ready)], conversations: [], turns: turns, attempts: [])
        let parts = snapshot.parts(maximumTurnsPerPart: 400)
        XCTAssertEqual(parts.map(\.partIndex), [0, 1, 2])
        XCTAssertTrue(parts.allSatisfy { $0.partCount == 3 && $0.seq == 3 })
        XCTAssertEqual(parts.flatMap(\.turns).map(\.id), turns.map(\.id))
        XCTAssertEqual(parts[0].agents.count, 1)
        XCTAssertTrue(parts[1].agents.isEmpty, "Only the first part repeats agents and conversations")
    }

    func testPairingOfferURLRoundTripsAndRejectsForeignURLs() throws {
        let offer = RemotePairingOffer(macName: "Studio", variant: .demo, endpoints: [RemoteEndpoint(host: "100.64.1.2", kind: .tailscale, interface: "utun3"), RemoteEndpoint(host: "192.168.1.2", kind: .lan)],
                                       port: 50123, spkiSHA256: Data(repeating: 1, count: 32), identityKeySHA256: Data(repeating: 2, count: 32), code: RemotePairingOffer.makeCode(), expiresAt: date)
        XCTAssertEqual(try RemotePairingOffer(url: offer.url), offer)
        XCTAssertEqual(offer.code.count, 22, "128 bits, base64url without padding")
        XCTAssertNotEqual(RemotePairingOffer.makeCode(), RemotePairingOffer.makeCode())
        XCTAssertThrowsError(try RemotePairingOffer(url: URL(string: "https://example.com/pair?offer=abc")!))
        XCTAssertThrowsError(try RemotePairingOffer(url: URL(string: "msgblast://pair?offer=%%%")!))
    }
}

final class RemoteFramingTests: XCTestCase {
    func testFramesSurvivePartialAndCoalescedDelivery() throws {
        let payloads = [Data("a".utf8), Data(repeating: 7, count: 70_000), Data("{\"kind\":\"ping\"}".utf8)]
        let stream = try payloads.map { try RemoteFraming.frame($0) }.reduce(Data(), +)
        var decoder = RemoteFrameDecoder()
        var received: [Data] = []
        // One byte at a time exercises every split point of the header and body.
        for byte in stream { received += try decoder.append(Data([byte])) }
        XCTAssertEqual(received, payloads)
        XCTAssertEqual(decoder.bufferedByteCount, 0)

        var coalesced = RemoteFrameDecoder()
        XCTAssertEqual(try coalesced.append(stream), payloads)
    }

    func testOversizeLengthIsRejectedBeforeThePayloadArrives() {
        var decoder = RemoteFrameDecoder(maximum: 1024)
        var header = UInt32(1025).bigEndian
        XCTAssertThrowsError(try decoder.append(Data(bytes: &header, count: 4))) { error in
            XCTAssertEqual(error as? RemoteProtocolError, .frameTooLarge(1025))
        }
        XCTAssertThrowsError(try RemoteFraming.frame(Data(count: 1025), maximum: 1024))
        var huge = RemoteFrameDecoder()
        XCTAssertThrowsError(try huge.append(Data([0xFF, 0xFF, 0xFF, 0xFF])), "A 4 GiB claim fails without buffering")
    }

    func testEmptyFramesAreRejected() {
        XCTAssertThrowsError(try RemoteFraming.frame(Data()))
        var decoder = RemoteFrameDecoder()
        XCTAssertThrowsError(try decoder.append(Data([0, 0, 0, 0])))
    }
}

final class RemoteSecureChannelTests: XCTestCase {
    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    private func bytes(_ hex: String) -> Data {
        var data = Data(); var index = hex.startIndex
        while index < hex.endIndex { let next = hex.index(index, offsetBy: 2); data.append(UInt8(hex[index..<next], radix: 16)!); index = next }
        return data
    }

    /// Fixed inputs. Transcript, HKDF keys and the pairing proof were checked independently
    /// with OpenSSL 3.6 (X25519 derive) and Python hashlib/hmac (SHA-256, HKDF, HMAC).
    func testKnownAnswerVectors() throws {
        let client = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(0..<32))
        let server = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(32..<64))
        let identity = try P256.Signing.PrivateKey(rawRepresentation: Data(1...32))
        XCTAssertEqual(hex(client.publicKey.rawRepresentation), "8f40c5adb68f25624ae5b214ea767a6ec94d829d3d7b5e1ad1ba6f3e2138285f")
        XCTAssertEqual(hex(server.publicKey.rawRepresentation), "358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254")
        let transcript = RemoteHandshake.transcript(version: 1, intent: .resume, clientEphemeral: client.publicKey.rawRepresentation, clientNonce: Data(repeating: 0xAA, count: 32),
            serverEphemeral: server.publicKey.rawRepresentation, serverNonce: Data(repeating: 0xBB, count: 32), identityKey: identity.publicKey.x963Representation)
        XCTAssertEqual(hex(transcript), "b190518c222cc86bacdd85e515e0e5c356181879dc32688c2c665487c3eba9df")
        let keys = try RemoteHandshake.sessionKeys(ephemeral: client, peerEphemeral: server.publicKey.rawRepresentation, transcript: transcript)
        XCTAssertEqual(keys.clientToServer.withUnsafeBytes { hex(Data($0)) }, "35f6076872b5ca85181e9e70a4c364f876ce13cf61be2696feba308bfb9d4852")
        XCTAssertEqual(keys.serverToClient.withUnsafeBytes { hex(Data($0)) }, "45963e25f284f9180984b718db1457fed60a48299da4f190b1caed80802539eb")
        let serverSide = try RemoteHandshake.sessionKeys(ephemeral: server, peerEphemeral: client.publicKey.rawRepresentation, transcript: transcript)
        XCTAssertEqual(serverSide.clientToServer, keys.clientToServer)

        var sender = RemoteCipher(key: keys.clientToServer, direction: .clientToServer, transcript: transcript)
        XCTAssertEqual(hex(try sender.seal(Data("hello mac".utf8))), "00000000000000008d2423dc99dac060b9fe5485a24c82c17b1965070a9019f3df")
        XCTAssertEqual(hex(try sender.seal(Data("second".utf8))), "000000000000000102c96774fe4dcb01e9601349ad9e2d812e266bf6db75")
        var receiver = RemoteCipher(key: keys.clientToServer, direction: .clientToServer, transcript: transcript)
        XCTAssertEqual(try receiver.open(bytes("00000000000000008d2423dc99dac060b9fe5485a24c82c17b1965070a9019f3df")), Data("hello mac".utf8))

        XCTAssertEqual(hex(RemoteHandshake.pairingProof(code: "test-code", challenge: Data(repeating: 0xCC, count: 32), transcript: transcript, devicePublicKey: identity.publicKey.x963Representation)),
                       "a5e896f4514713ab71c45e724fb70a52651c643f0ea30590b27fc0a8cf3ac7be")
    }

    func testHandshakeAuthenticatesTheMacAndEncryptsBothDirections() throws {
        let identity = P256.Signing.PrivateKey()
        let client = RemoteClientHandshake(intent: .pair)
        let (reply, serverChannel) = try RemoteServerHandshake.respond(to: client.hello, identity: identity, macName: "Studio", variant: .demo)
        var server = serverChannel
        var phone = try client.complete(with: reply, pinnedIdentityKeyHash: RemoteHandshake.keyHash(identity.publicKey.x963Representation))
        XCTAssertEqual(phone.transcript, server.transcript)

        let ping = try phone.seal(.ping(nonce: 1))
        XCTAssertFalse(String(decoding: ping, as: UTF8.self).contains("ping"), "Frames are ciphertext")
        XCTAssertEqual(try server.open(ping), .ping(nonce: 1))
        XCTAssertEqual(try phone.open(try server.seal(.pong(nonce: 1, seq: 4))), .pong(nonce: 1, seq: 4))

        // Replay, reorder, and tampering all fail closed.
        XCTAssertThrowsError(try server.open(ping)) { XCTAssertEqual($0 as? RemoteProtocolError, .replayOrReorder) }
        var tampered = try phone.seal(.ping(nonce: 2)); tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try server.open(tampered)) { XCTAssertEqual($0 as? RemoteProtocolError, .authenticationFailed) }
        // A server frame cannot be reflected back to the server.
        var reflected = server
        XCTAssertThrowsError(try reflected.open(try server.seal(.ping(nonce: 3))))
    }

    func testPhoneRejectsAnImpostorMac() throws {
        let real = P256.Signing.PrivateKey(), impostor = P256.Signing.PrivateKey()
        let client = RemoteClientHandshake(intent: .resume)
        let (reply, _) = try RemoteServerHandshake.respond(to: client.hello, identity: impostor, macName: "Evil", variant: .production)
        XCTAssertThrowsError(try client.complete(with: reply, pinnedIdentityKey: real.publicKey.x963Representation))
        XCTAssertThrowsError(try client.complete(with: reply, pinnedIdentityKeyHash: RemoteHandshake.keyHash(real.publicKey.x963Representation)))
        XCTAssertThrowsError(try client.complete(with: reply), "Nothing pinned is never trusted")
        // An impostor that copies the real key cannot produce its signature.
        var forged = reply; forged.identityKey = real.publicKey.x963Representation
        XCTAssertThrowsError(try client.complete(with: forged, pinnedIdentityKey: real.publicKey.x963Representation))
    }

    func testPairingProofDependsOnCodeSessionAndDeviceKey() {
        let transcript = Data(repeating: 1, count: 32), challenge = Data(repeating: 2, count: 32), key = Data(repeating: 4, count: 65)
        let proof = RemoteHandshake.pairingProof(code: "abc", challenge: challenge, transcript: transcript, devicePublicKey: key)
        XCTAssertNotEqual(proof, RemoteHandshake.pairingProof(code: "abd", challenge: challenge, transcript: transcript, devicePublicKey: key))
        XCTAssertNotEqual(proof, RemoteHandshake.pairingProof(code: "abc", challenge: challenge, transcript: Data(repeating: 9, count: 32), devicePublicKey: key))
        XCTAssertNotEqual(proof, RemoteHandshake.pairingProof(code: "abc", challenge: challenge, transcript: transcript, devicePublicKey: Data(repeating: 5, count: 65)))
    }
}
