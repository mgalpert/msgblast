import XCTest
import CryptoKit
import Security
import LocalAuthentication
@testable import msgblastCore

@MainActor
final class GrokBotTests: XCTestCase {
    func testOnboardingConfigurationDoesNotSelectTheBotAsARecipient() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = WebAgentSession(provider: .grokbot, storageURL: directory.appendingPathComponent("state.json"), fixture: true)
        let success = await session.configureGrokBot(webhookURL: "https://example.invalid/fixture", webhookKey: String(repeating: "fixture", count: 8), selectAfterConnecting: false)
        XCTAssertTrue(success)
        XCTAssertTrue(session.isEnabled)
        XCTAssertFalse(session.state.selected)
        let reopened = WebAgentSession(provider: .grokbot, storageURL: directory.appendingPathComponent("state.json"), fixture: true)
        XCTAssertFalse(reopened.state.selected)
        XCTAssertTrue(reopened.isEnabled)
    }

    func testAdHocConnectionCredentialsSurviveStorageReload() async throws {
        guard SecureEnclave.isAvailable else { throw XCTSkip("This integration check needs a Secure Enclave") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        let credentials = try GrokBotCredentials(webhookURL: "https://webhook.example/persistence", webhookKey: "fixture-persisted-key-00000000000000000000")
        let saved = try await GrokBotCredentialStore.save(credentials, at: url)
        XCTAssertTrue(saved, "Ad-hoc builds must remember the webhook connection without interactive Keychain access")
        let restored = try await GrokBotCredentialStore.read(url)
        XCTAssertEqual(restored?.webhookURL, credentials.webhookURL)
        XCTAssertEqual(restored?.webhookKey, credentials.webhookKey)
    }
    func testPersistedCredentialsAreEncryptedAndOwnerOnly() throws {
        guard SecureEnclave.isAvailable else { throw XCTSkip("Hardware encryption needs a Secure Enclave") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        let credentials = try GrokBotCredentials(webhookURL: "https://webhook.example/private-address", webhookKey: "fixture-private-key-00000000000000000000")
        try GrokBotCredentialVault.save(credentials, at: url)
        let file = GrokBotCredentialVault.fileURL(for: url)
        let bytes = try Data(contentsOf: file)
        XCTAssertNil(bytes.range(of: Data(credentials.webhookKey.utf8)))
        XCTAssertNil(bytes.range(of: Data(credentials.webhookURL.absoluteString.utf8)))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let folderAttributes = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)
        XCTAssertEqual((folderAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }
    func testTamperedCredentialsArePreservedAndOnlyExplicitSetupReplacesThem() async throws {
        guard SecureEnclave.isAvailable else { throw XCTSkip("Hardware encryption needs a Secure Enclave") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        let old = try GrokBotCredentials(webhookURL: "https://webhook.example/old", webhookKey: "fixture-old-key-00000000000000000000000")
        try GrokBotCredentialVault.save(old, at: url)
        let file = GrokBotCredentialVault.fileURL(for: url)
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var ciphertext = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(envelope["ciphertext"] as? String)))
        ciphertext[ciphertext.count - 1] ^= 1
        envelope["ciphertext"] = ciphertext.base64EncodedString()
        let damaged = try JSONSerialization.data(withJSONObject: envelope)
        try damaged.write(to: file)
        do { _ = try await GrokBotCredentialStore.read(url); XCTFail("Tampering must fail authenticated decryption") }
        catch let error as GrokBotServiceError { XCTAssertEqual(error, .keychain) }
        XCTAssertEqual(try Data(contentsOf: file), damaged)
        let new = try GrokBotCredentials(webhookURL: "https://webhook.example/new", webhookKey: "fixture-new-key-00000000000000000000000")
        let saved = try await GrokBotCredentialStore.save(new, at: url)
        XCTAssertTrue(saved)
        let restored = try await GrokBotCredentialStore.read(url)
        XCTAssertEqual(restored?.webhookKey, new.webhookKey)
        XCTAssertEqual(restored?.webhookURL, new.webhookURL)
    }
    func testCredentialVaultCannotBeCopiedToAnotherProfile() throws {
        guard SecureEnclave.isAvailable else { throw XCTSkip("Hardware encryption needs a Secure Enclave") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.json"), second = directory.appendingPathComponent("second.json")
        let credentials = try GrokBotCredentials(webhookURL: "https://webhook.example/first", webhookKey: "fixture-first-key-000000000000000000000")
        try GrokBotCredentialVault.save(credentials, at: first)
        try FileManager.default.copyItem(at: GrokBotCredentialVault.fileURL(for: first), to: GrokBotCredentialVault.fileURL(for: second))
        XCTAssertThrowsError(try GrokBotCredentialVault.read(second))
        XCTAssertEqual(try GrokBotCredentialVault.read(first)?.webhookKey, credentials.webhookKey)
    }
    func testOversizedSymlinkedAndPublicCredentialFilesAreRejected() throws {
        guard SecureEnclave.isAvailable else { throw XCTSkip("Valid encrypted file fixtures need a Secure Enclave") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        let file = GrokBotCredentialVault.fileURL(for: url)
        let credentials = try GrokBotCredentials(webhookURL: "https://webhook.example/file-safety", webhookKey: "fixture-file-key-0000000000000000000000")
        try GrokBotCredentialVault.save(credentials, at: url)
        let original = try Data(contentsOf: file)
        XCTAssertEqual(try GrokBotCredentialVault.read(url)?.webhookKey, credentials.webhookKey)
        var oversized = original
        oversized.append(Data(repeating: 32, count: 33 * 1024))
        try oversized.write(to: file)
        XCTAssertThrowsError(try GrokBotCredentialVault.read(url))
        try original.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try GrokBotCredentialVault.read(url))
        try FileManager.default.removeItem(at: file)
        let target = directory.appendingPathComponent("target")
        try original.write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertThrowsError(try GrokBotCredentialVault.read(url))
        XCTAssertEqual(try Data(contentsOf: target), original)
    }
    func testKeychainBackendIgnoresAnUnusableHardwareVaultOnNonEnclaveMac() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        let file = GrokBotCredentialVault.fileURL(for: url)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let copied = Data("copied, unusable hardware vault".utf8)
        try copied.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let credentials = try GrokBotCredentials(webhookURL: "https://webhook.example/keychain", webhookKey: "fixture-keychain-key-000000000000000000")
        let restored = try GrokBotCredentialStore.readAvailableStorage(url, hardwareAvailable: false) { credentials }
        XCTAssertEqual(restored?.webhookKey, credentials.webhookKey)
        XCTAssertEqual(try Data(contentsOf: file), copied)
    }
    func testKeychainWorkRunsAwayFromTheUIThread() async throws {
        let worker = GrokBotCredentialWorker()
        let usedMainThread = try await worker.perform { Thread.isMainThread }
        XCTAssertFalse(usedMainThread, "Secure-storage work must not block the app's UI thread")
    }
    func testBlockedKeychainWorkTimesOutAndRejectsOverlappingOperations() async throws {
        let worker = GrokBotCredentialWorker()
        let release = DispatchSemaphore(value: 0)
        let lateReturn = expectation(description: "The original operation can return after its caller timed out")
        defer { release.signal() }
        let start = Date()
        do {
            _ = try await worker.perform(timeout: 0.03) {
                _ = release.wait(timeout: .now() + 2)
                lateReturn.fulfill()
                return "late result"
            }
            XCTFail("A blocked Keychain operation must have a deadline")
        } catch let error as GrokBotServiceError { XCTAssertEqual(error, .keychainWaiting) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        do {
            _ = try await worker.perform { "overlapping operation" }
            XCTFail("Retry must not queue more credential operations behind a blocked call")
        } catch let error as GrokBotServiceError { XCTAssertEqual(error, .keychainWaiting) }
        release.signal()
        await fulfillment(of: [lateReturn], timeout: 2)
    }
    func testKeychainWorkerPreservesOperationFailures() async throws {
        let worker = GrokBotCredentialWorker()
        do {
            let _: Bool = try await worker.perform { throw GrokBotServiceError.keychain }
            XCTFail("Keychain errors must remain errors")
        } catch let error as GrokBotServiceError { XCTAssertEqual(error, .keychain) }
    }
    func testCredentialQueriesNeverPermitInteractiveAuthentication() throws {
        let query = GrokBotCredentialStore.query(URL(fileURLWithPath: "/tmp/synthetic-profile/state.json"))
        XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
        XCTAssertEqual(query[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUIFail as String)
        let context = try XCTUnwrap(query[kSecUseAuthenticationContext as String] as? LAContext)
        XCTAssertTrue(context.interactionNotAllowed)
    }
    func testSavingConnectionImmediatelyDisablesSubmissionWithoutChangingComparison() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = WebAgentSession(provider: .grokbot, storageURL: directory.appendingPathComponent("state.json"), fixture: true)
        let configured = await session.configureGrokBot(webhookURL: "https://webhook.example/trigger", webhookKey: "fixture-webhook-key-000000000000000000000")
        XCTAssertTrue(configured)
        XCTAssertTrue(session.snapshot.ready)
        let before = session.state.comparisonID
        session.setGrokBotConnectionActivity(.savingKey)
        XCTAssertFalse(session.snapshot.ready)
        let sent = await session.send("Do not submit during key storage", comparisonID: UUID())
        XCTAssertNil(sent)
        XCTAssertEqual(session.state.comparisonID, before)
        XCTAssertTrue(session.state.attempts.isEmpty)
        session.setGrokBotConnectionActivity(nil)
        XCTAssertTrue(session.snapshot.ready)
        session.beginShutdown()
    }
    func testStorageFailureSkipsCredentialRestoreAndPreservesTheError() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("state.json")
        let original = Data("invalid saved state".utf8)
        try original.write(to: url)
        let session = WebAgentSession(provider: .grokbot, storageURL: url, fixture: false)
        let failure = try XCTUnwrap(session.error)
        XCTAssertFalse(session.configuringGrokBot)
        let retried = await session.retryGrokBotSavedConnection()
        XCTAssertFalse(retried)
        XCTAssertEqual(session.error, failure)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testSessionOnlyPolicyDoesNotRestoreAnOlderRememberedKey() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("state.json")
        var state = WebWorkspaceState()
        state.grokBotRememberedConnection = false
        try JSONEncoder().encode(state).write(to: url)
        let session = WebAgentSession(provider: .grokbot, storageURL: url, fixture: false)
        XCTAssertFalse(session.configuringGrokBot)
        XCTAssertFalse(session.grokBotIsConfigured)
        let restored = await session.retryGrokBotSavedConnection()
        XCTAssertFalse(restored)
        XCTAssertNil(session.error)
        XCTAssertEqual(try JSONDecoder().decode(WebWorkspaceState.self, from: Data(contentsOf: url)).grokBotRememberedConnection, false)
    }
    func testGrokBotIsASeparateOptionalAgentWithIndependentStorage() throws {
        let provider = try XCTUnwrap(WebProvider(rawValue: "grokbot"))
        XCTAssertEqual(provider.name, "Grok Bot")
        XCTAssertNotEqual(provider, .grok)
        XCTAssertNotEqual(provider.storageFilename, WebProvider.grok.storageFilename)
        XCTAssertFalse(WebProvider.webDefaults.contains(provider))
        XCTAssertNil(provider.personalAgentProvider)
        XCTAssertFalse(provider.isChatURL(URL(string: "https://grok.com/c/example")!))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let agents = WebAgents(directory: directory, fixture: true)
        let session = try XCTUnwrap(agents.sessions.first { $0.provider == provider })
        XCTAssertFalse(session.isEnabled)
        XCTAssertFalse(session.state.selected)
        XCTAssertEqual(agents.selected.map(\.provider), WebProvider.webDefaults)
    }
    func testGrokBotDoesNotInspectWebsiteSignInOrReceiptRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let agents = WebAgents(directory: directory, fixture: true)
        agents.setEnabled(true, for: .grokbot)
        let session = try XCTUnwrap(agents.sessions.first { $0.provider == .grokbot })
        XCTAssertFalse(agents.hasConnectedWebSessions, "The Bot's connection must not be treated as a browser session")
        session.updateState { $0.webDrafts["new"] = "Legacy browser draft" }
        XCTAssertNil(session.draftRecoveryText, "Browser draft recovery must not block native Bot requests")
        try await agents.saveBrowserDrafts()
        let signedOut = await agents.signInRequired(for: [session])
        XCTAssertTrue(signedOut.isEmpty)
        let signIn = await session.checkSignIn()
        XCTAssertNil(signIn)
        await session.linkCurrentConversation()
        XCTAssertFalse(session.needsConversationLink)
    }
    func testRequestCarriesComparisonHistoryAndCallbackWithoutWebhookKey() throws {
        let id = UUID(), comparison = UUID(), callback = URL(string: "https://fixture.trycloudflare.com/reply/\(id)")!
        let payload = try GrokBotService.encodeRequest(id: id, comparisonID: comparison, message: "Follow up", history: [WebPageMessage(role: "assistant", text: "Earlier answer")], callbackURL: callback, callbackToken: "per-request-fixture-token")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(body["request_id"] as? String, id.uuidString.lowercased())
        XCTAssertEqual(body["comparison_id"] as? String, comparison.uuidString.lowercased())
        XCTAssertEqual(body["message"] as? String, "Follow up")
        XCTAssertEqual(body["history"] as? [[String: String]], [["role": "assistant", "text": "Earlier answer"]])
        XCTAssertEqual(body["callback_url"] as? String, callback.absoluteString)
        XCTAssertNil(body["webhook_key"])
        XCTAssertThrowsError(try GrokBotService.encodeRequest(id: id, comparisonID: comparison, message: String(repeating: "x", count: 140_000), history: [], callbackURL: callback, callbackToken: "fixture"))
    }
    func testAcceptedBotRequestsQualifyAsSharedContextBeforeTheirReply() {
        XCTAssertTrue(WebSendStatus.waiting.confirmsSubmission)
        XCTAssertTrue(WebSendStatus.observed.confirmsSubmission)
        for status in [WebSendStatus.preparing, .attempting, .uncertain, .notSent, .dismissed] {
            XCTAssertFalse(status.confirmsSubmission)
        }
    }
    func testConnectionAndReceiptsRejectUnsafeOrUnrelatedResults() throws {
        for address in ["http://webhook.example/trigger", "https://user:pass@webhook.example/trigger", "https://webhook.example/#fragment"] {
            XCTAssertThrowsError(try GrokBotCredentials(webhookURL: address, webhookKey: "fixture-webhook-key-000000000000000000000"))
        }
        let id = UUID()
        XCTAssertThrowsError(try GrokBotService.decodeReceipt(Data("{\"request_id\":\"\(UUID())\",\"status\":\"answered\",\"answer\":\"Wrong comparison\"}".utf8), id: id))
        XCTAssertThrowsError(try GrokBotService.decodeReceipt(Data("{\"request_id\":\"\(id)\",\"status\":\"answered\",\"answer\":\"\"}".utf8), id: id))
    }
    func testSubmissionPostsDirectlyToAuthenticatedGrokBotWebhook() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GrokBotFixtureProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel() }
        let credentials = try GrokBotCredentials(webhookURL: "https://webhook.example/trigger", webhookKey: "fixture-webhook-key-000000000000000000000")
        let id = UUID()
        let body = try GrokBotService.encodeRequest(id: id, comparisonID: UUID(), message: "Transport check", history: [], callbackURL: URL(string: "https://fixture.trycloudflare.com/reply/\(id)")!, callbackToken: "fixture-callback")
        try await GrokBotService.submit(credentials, body: body, session: transport)
    }
    func testRejectedResponsesAreDefiniteButLostResponsesStayUncertain() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GrokBotFixtureProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel() }
        for code in [401, 403, 404, 429, 500] {
            let credentials = try GrokBotCredentials(webhookURL: "https://webhook.example/status/\(code)", webhookKey: "fixture-webhook-key-000000000000000000000")
            do { try await GrokBotService.submit(credentials, body: Data("{}".utf8), session: transport); XCTFail("Expected rejection") }
            catch let error as GrokBotServiceError { XCTAssertTrue(error.definitelyNotSubmitted, "HTTP \(code) must not be treated as an unknown send") }
        }
        let credentials = try GrokBotCredentials(webhookURL: "https://webhook.example/timeout", webhookKey: "fixture-webhook-key-000000000000000000000")
        do { try await GrokBotService.submit(credentials, body: Data("{}".utf8), session: transport); XCTFail("Expected timeout") }
        catch let error as GrokBotServiceError { XCTAssertFalse(error.definitelyNotSubmitted) }
    }
    func testConnectionLossMarksAnAttemptingRequestUncertainAndKeepsItsDraft() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = WebAgentSession(provider: .grokbot, storageURL: directory.appendingPathComponent("state.json"), fixture: true)
        var attempt = WebSendAttempt(text: "In flight", status: .attempting)
        attempt.comparisonID = UUID()
        session.updateState { $0.attempts = [attempt]; $0.draft = "Keep this draft" }
        session.beginShutdown()
        XCTAssertEqual(session.state.attempts.first?.status, .uncertain)
        XCTAssertEqual(session.state.draft, "Keep this draft")
    }
    func testLocalCallbackRequiresItsRequestTokenAndRecordsDuplicatesOnce() async throws {
        var received: [GrokBotReceipt] = []
        let receiver = GrokBotCallbackReceiver { received.append($0) }
        let address = try await receiver.start()
        defer { receiver.stop() }
        let id = UUID(), token = "fixture-callback-token"
        receiver.register(id: id, tokenHash: Data(SHA256.hash(data: Data(token.utf8))))
        let payload = try JSONEncoder().encode(GrokBotReceipt(request_id: id, status: .answered, answer: "Received on this Mac"))
        func call(_ key: String, body: Data = payload) async throws -> Int {
            var request = URLRequest(url: address.appendingPathComponent("reply/\(id.uuidString.lowercased())"))
            request.httpMethod = "POST"; request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as! HTTPURLResponse).statusCode
        }
        let rejected = try await call("wrong")
        XCTAssertEqual(rejected, 401); XCTAssertTrue(received.isEmpty)
        let accepted = try await call(token)
        XCTAssertEqual(accepted, 200); XCTAssertEqual(received.first?.answer, "Received on this Mac")
        let duplicate = try await call(token)
        XCTAssertEqual(duplicate, 200); XCTAssertEqual(received.count, 1)
        let changed = try await call(token, body: JSONEncoder().encode(GrokBotReceipt(request_id: id, status: .answered, answer: "Changed")))
        XCTAssertEqual(changed, 409); XCTAssertEqual(received.count, 1)
        let oversized = try await call(token, body: Data(repeating: 65, count: 140_000))
        XCTAssertEqual(oversized, 413)
    }
    func testCallbacksStayInTheirComparisonAndRestartDoesNotResend() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let agents = WebAgents(directory: directory, fixture: true)
        agents.setEnabled(true, for: .grokbot)
        let session = try XCTUnwrap(agents.sessions.first { $0.provider == .grokbot })
        let first = UUID(), second = UUID()
        let ready = await session.openComparison(first); XCTAssertTrue(ready)
        let sent = await session.send("First comparison", comparisonID: first)
        XCTAssertEqual(sent?.status, .waiting)
        let duplicate = await session.send("Do not duplicate", comparisonID: first); XCTAssertNil(duplicate)
        session.updateState { $0.comparisonID = second }
        _ = await session.send("Second comparison", comparisonID: second)
        await session.refresh()
        XCTAssertEqual(session.state.localConversations[first.uuidString]?.last?.text, "Grok Bot fixture reply: First comparison")
        XCTAssertEqual(session.snapshot.messages.last?.text, "Grok Bot fixture reply: Second comparison")
        _ = await session.send("Pending at exit", comparisonID: second)
        let restored = WebAgentSession(provider: .grokbot, storageURL: directory.appendingPathComponent(WebProvider.grokbot.storageFilename), fixture: true)
        XCTAssertEqual(restored.state.attempts.first?.status, .uncertain)
        let blocked = await restored.send("No automatic restart resend", comparisonID: second)
        XCTAssertNil(blocked)
        XCTAssertEqual(restored.state.attempts.count, 3)
    }
    func testCallbackRetriesAfterStorageFailureAndDrainsBeforeShutdown() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storageURL = directory.appendingPathComponent("state.json")
        let session = WebAgentSession(provider: .grokbot, storageURL: storageURL, fixture: true)
        let comparisonID = UUID(), token = "synthetic-retry-token"
        var attempt = WebSendAttempt(text: "Reply after storage recovers")
        attempt.comparisonID = comparisonID; attempt.status = .waiting
        attempt.callbackHash = Data(SHA256.hash(data: Data(token.utf8)))
        session.updateState {
            $0.enabled = true; $0.comparisonID = comparisonID; $0.attempts = [attempt]
            $0.localConversations[comparisonID.uuidString] = [WebPageMessage(id: attempt.id.uuidString, role: "user", text: attempt.text)]
        }
        let saved = try Data(contentsOf: storageURL)
        try FileManager.default.removeItem(at: storageURL)
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: false)
        let receiver = GrokBotCallbackReceiver { try session.receiveGrokBotReceipt($0) }
        receiver.onDrained = { if session.state.attempts.first?.status == .observed { receiver.stop() } }
        let address = try await receiver.start()
        defer { receiver.stop() }
        receiver.register(id: attempt.id, tokenHash: try XCTUnwrap(attempt.callbackHash))
        var request = URLRequest(url: address.appendingPathComponent("reply/\(attempt.id)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(GrokBotReceipt(request_id: attempt.id, status: .answered, answer: "Saved on retry"))
        let (_, first) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((first as? HTTPURLResponse)?.statusCode, 503)
        XCTAssertEqual(session.state.attempts.first?.status, .waiting)
        XCTAssertEqual(session.state.localConversations[comparisonID.uuidString]?.count, 1)
        let blocked = await session.send("Must not submit while storage is unavailable", comparisonID: UUID())
        XCTAssertNil(blocked)
        let (_, stillUnavailable) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((stillUnavailable as? HTTPURLResponse)?.statusCode, 503)
        XCTAssertEqual(session.state.localConversations[comparisonID.uuidString]?.count, 1)
        try FileManager.default.removeItem(at: storageURL)
        try saved.write(to: storageURL)
        let (_, second) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((second as? HTTPURLResponse)?.statusCode, 200, "Closing the listener must follow its acknowledgement write")
        let durable = try JSONDecoder().decode(WebWorkspaceState.self, from: Data(contentsOf: storageURL))
        XCTAssertEqual(durable.attempts.first?.status, .observed)
        XCTAssertEqual(durable.localConversations[comparisonID.uuidString]?.map(\.text), [attempt.text, "Saved on retry"])
        try session.receiveGrokBotReceipt(GrokBotReceipt(request_id: attempt.id, status: .answered, answer: "Saved on retry"))
        XCTAssertEqual(session.state.localConversations[comparisonID.uuidString]?.count, 2)
    }
}
private final class GrokBotFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "webhook.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.host, "webhook.example")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-webhook-key-000000000000000000000")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        if request.url?.path == "/timeout" { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
        let status = request.url?.path.hasPrefix("/status/") == true ? Int(request.url!.lastPathComponent)! : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"status\":\"queued\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
