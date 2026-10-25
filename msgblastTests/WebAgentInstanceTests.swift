import XCTest
import CryptoKit
@testable import msgblastCore

@MainActor
final class WebAgentInstanceTests: XCTestCase {
    func testNewAppWebAgentsRequireSettingsOptInAndRememberItAcrossRestart() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let agents = WebAgents(directory: directory, fixture: true, websiteOptInRequired: true)
        defer { agents.beginShutdown() }
        for provider in WebProvider.settingsOnlyWebProviders {
            let session = try XCTUnwrap(agents.session(for: .init(provider: provider)))
            XCTAssertFalse(session.isEnabled)
            XCTAssertFalse(agents.availableSessions.contains { $0.id == session.id })
            let result = await session.send("Must remain local")
            XCTAssertNil(result)
            XCTAssertTrue(session.state.attempts.isEmpty)
        }
        XCTAssertTrue(try XCTUnwrap(agents.session(for: .init(provider: .hark))).isEnabled)
        XCTAssertTrue(try XCTUnwrap(agents.session(for: .init(provider: .os3))).isEnabled)
        agents.setEnabled(true, for: .chatgpt)
        let chatgpt = try XCTUnwrap(agents.session(for: .chatgpt))
        XCTAssertTrue(chatgpt.isEnabled)
        let id = chatgpt.state.sessionID
        chatgpt.updateState { $0.draft = "Keep this draft" }
        let reopened = WebAgents(directory: directory, fixture: true, websiteOptInRequired: true)
        defer { reopened.beginShutdown() }
        let restored = try XCTUnwrap(reopened.session(for: .chatgpt))
        XCTAssertTrue(restored.isEnabled)
        XCTAssertEqual(restored.state.sessionID, id)
        XCTAssertEqual(restored.state.draft, "Keep this draft")
        restored.setEnabled(false)
        XCTAssertFalse(restored.isEnabled)
        XCTAssertEqual(restored.state.draft, "Keep this draft")
        let disabled = WebAgents(directory: directory, fixture: true, websiteOptInRequired: true)
        defer { disabled.beginShutdown() }
        XCTAssertFalse(try XCTUnwrap(disabled.session(for: .chatgpt)).isEnabled)
    }

    func testExistingWebAccountWithNoEnableFlagKeepsIdentityAndHistory() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var saved = WebWorkspaceState()
        saved.enabled = false // Old CLI enablement must not disable a website.
        saved.draft = "Existing draft"
        saved.conversationURLs["existing"] = URL(string: "https://chatgpt.com/c/existing")!
        try JSONEncoder().encode(saved).write(to: directory.appendingPathComponent(WebProvider.chatgpt.storageFilename))
        let agents = WebAgents(directory: directory, fixture: true, websiteOptInRequired: true)
        defer { agents.beginShutdown() }
        let restored = try XCTUnwrap(agents.session(for: .chatgpt))
        XCTAssertTrue(restored.isEnabled, "Do not disable existing users during the transition")
        XCTAssertEqual(restored.state.sessionID, saved.sessionID)
        XCTAssertEqual(restored.state.draft, saved.draft)
        XCTAssertEqual(restored.state.conversationURLs, saved.conversationURLs)
    }

    func testCopiesKeepLoginIdentityAndStartWithEmptyHistory() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let agents = WebAgents(directory: directory, fixture: true)
        let original = try XCTUnwrap(agents.session(for: WebAgentID.chatgpt))
        let comparison = UUID()
        original.updateState {
            $0.comparisonID = comparison
            $0.draft = "Original draft"
            $0.conversationURLs[comparison.uuidString] = URL(string: "https://chatgpt.com/c/original")!
        }
        let copy = try agents.duplicate(original, name: "ChatGPT — deep")
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.state.sessionID, original.state.sessionID)
        XCTAssertTrue(copy.state.conversationURLs.isEmpty)
        XCTAssertTrue(copy.state.attempts.isEmpty)
        XCTAssertEqual(copy.state.draft, "")
        XCTAssertFalse(copy.state.selected)
        XCTAssertEqual(original.state.draft, "Original draft")
        let otherAccount = try agents.duplicate(copy, name: "ChatGPT — work", separateAccount: true)
        XCTAssertNotEqual(otherAccount.state.sessionID, copy.state.sessionID)
        XCTAssertNotEqual(copy.id.gridID, original.id.gridID)
        let reopened = WebAgents(directory: directory, fixture: true)
        let restored = try XCTUnwrap(reopened.session(for: copy.id))
        XCTAssertEqual(restored.name, "ChatGPT — deep")
        XCTAssertEqual(restored.state.sessionID, original.state.sessionID)
        XCTAssertEqual(reopened.session(for: otherAccount.id)?.state.sessionID, otherAccount.state.sessionID)
    }

    func testSharedSignInUsesSameCookieStoreAndOtherAccountIsIsolated() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let agents = WebAgents(directory: directory, fixture: false)
        let original = try XCTUnwrap(agents.session(for: WebAgentID.chatgpt))
        let shared = try agents.duplicate(original, name: "Shared account")
        let isolated = try agents.duplicate(original, name: "Other account", separateAccount: true)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "chatgpt.com", .path: "/", .name: "msgblast-isolated-copy-test", .value: UUID().uuidString, .secure: "TRUE"]))
        let originalStore = original.webView.configuration.websiteDataStore.httpCookieStore
        await withCheckedContinuation { continuation in
            originalStore.setCookie(cookie) { continuation.resume() }
        }
        let sharedCookies = await shared.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let isolatedCookies = await isolated.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        XCTAssertTrue(sharedCookies.contains { $0.name == cookie.name && $0.value == cookie.value })
        XCTAssertFalse(isolatedCookies.contains { $0.name == cookie.name })
        await withCheckedContinuation { continuation in
            originalStore.delete(cookie) { continuation.resume() }
        }
        agents.beginShutdown()
        await agents.cancelAndWait()
    }

    func testSelectionRenameAndComparisonIdentitySurviveReload() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let agents = WebAgents(directory: directory, fixture: true)
        let original = try XCTUnwrap(agents.session(for: WebAgentID.claude))
        let first = try agents.duplicate(original, name: "Claude — first")
        let second = try agents.duplicate(original, name: "Claude — second")
        try first.rename("Claude — reasoning")
        agents.restoreSelection(forAgentIDs: [second.id])
        XCTAssertEqual(agents.selected.map(\.id), [second.id])
        var comparison = Comparison(prompt: "Compare", members: [])
        comparison.setWebAgents([original.id, first.id, second.id])
        let restoredComparison = try JSONDecoder().decode(Comparison.self, from: JSONEncoder().encode(comparison))
        let reopened = WebAgents(directory: directory, fixture: true)
        reopened.restoreSelection(forAgentIDs: restoredComparison.resolvedWebAgentIDs)
        XCTAssertEqual(Set(reopened.selected.map(\.id)), Set([original.id, first.id, second.id]))
        XCTAssertEqual(reopened.session(for: first.id)?.name, "Claude — reasoning")
        XCTAssertEqual(comparison.webProviders, [.claude], "Legacy diagnostics retain provider coverage without replacing instance membership")
    }

    func testLegacyComparisonAndGridStillSelectOnlyDefaultAgent() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let agents = WebAgents(directory: directory, fixture: true)
        let original = try XCTUnwrap(agents.session(for: WebAgentID.grok))
        _ = try agents.duplicate(original, name: "Grok — copy")
        var comparison = Comparison(prompt: "Legacy", members: [])
        comparison.webProviders = [.grok]
        let saved = try JSONDecoder().decode(Comparison.self, from: JSONEncoder().encode(comparison))
        agents.restoreSelection(forAgentIDs: saved.resolvedWebAgentIDs)
        XCTAssertEqual(agents.selected.map(\.id), [.grok])
        let grid = AgentGridLayout(visibleIDs: [.web(.grok)])
        XCTAssertEqual(try JSONDecoder().decode(AgentGridLayout.self, from: JSONEncoder().encode(grid)), grid)
    }

    func testTwoBotBroadcastResultsAndPrivateFollowUpsStaySeparate() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let agents = WebAgents(directory: directory, fixture: true)
        let first = try agents.addGrokBot(name: "Research Bot")
        let second = try agents.addGrokBot(name: "Work Bot")
        first.setEnabled(true); second.setEnabled(true)
        let comparison = UUID()
        let results = await WebAgents.send("Shared fixture request", to: [first, second], comparisonID: comparison)
        XCTAssertEqual(Set(results.keys), Set([first.id, second.id]))
        XCTAssertNotEqual(results[first.id]?.id, results[second.id]?.id)
        try await waitFor { first.state.attempts.first?.status == .observed && second.state.attempts.first?.status == .observed }
        _ = await first.send("Only Research Bot", comparisonID: comparison)
        try await waitFor { first.state.attempts.first?.status == .observed }
        XCTAssertEqual(first.state.localConversations[comparison.uuidString]?.filter { $0.role == "user" }.map(\.text), ["Shared fixture request", "Only Research Bot"])
        XCTAssertEqual(second.state.localConversations[comparison.uuidString]?.filter { $0.role == "user" }.map(\.text), ["Shared fixture request"])
        let reopened = WebAgents(directory: directory, fixture: true)
        XCTAssertEqual(reopened.session(for: first.id)?.state.localConversations[comparison.uuidString], first.state.localConversations[comparison.uuidString])
        XCTAssertEqual(reopened.session(for: second.id)?.name, "Work Bot")
    }

    func testMalformedRegistryIsPreservedAndCannotBeOverwritten() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("web-agent-instances.json")
        let original = Data("unreadable agent registry".utf8)
        try original.write(to: url)
        let agents = WebAgents(directory: directory, fixture: true)
        XCTAssertNotNil(agents.configurationError)
        XCTAssertThrowsError(try agents.addGrokBot(name: "New Bot"))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(agents.sessions.count, WebProvider.allCases.count)
    }

    func testBotCredentialsRestoreIntoCorrectNamedSessions() async throws {
        guard SecureEnclave.isAvailable else { throw XCTSkip("Actual secure restoration needs a Secure Enclave") }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let agents = WebAgents(directory: directory, fixture: true)
        let bots = try ["First Bot", "Second Bot", "Third Bot"].map { try agents.addGrokBot(name: $0) }
        var expected: [WebAgentID: String] = [:]
        for (index, bot) in bots.enumerated() {
            let address = "https://webhook.example/isolated-bot-\(index)"
            let credentials = try GrokBotCredentials(webhookURL: address, webhookKey: "fixture-restore-key-\(index)-" + String(repeating: "x", count: 32))
            let profile = directory.appendingPathComponent("web-instance-\(bot.id.instance!.uuidString).json")
            let saved = try await GrokBotCredentialStore.save(credentials, at: profile)
            XCTAssertTrue(saved)
            bot.updateState { $0.grokBotRememberedConnection = true }
            expected[bot.id] = address
        }
        agents.beginShutdown()
        let reopened = WebAgents(directory: directory, fixture: false)
        defer { reopened.beginShutdown() }
        let restored = try bots.map { try XCTUnwrap(reopened.session(for: $0.id)) }
        try await waitFor { restored.allSatisfy { !$0.configuringGrokBot } }
        for session in restored {
            XCTAssertEqual(session.grokBotWebhookURL, expected[session.id])
            XCTAssertTrue(session.grokBotRemembersConnection)
            XCTAssertFalse(session.grokBotNeedsKeychainRetry)
            XCTAssertFalse(session.connected, "Checking stored credentials must not start a tunnel or contact a live bot")
        }
    }

    private func temporaryDirectory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-instances-" + UUID().uuidString) }
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<60 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Fixture reply did not arrive")
    }
}
