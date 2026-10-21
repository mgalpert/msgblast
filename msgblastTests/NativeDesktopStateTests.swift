import XCTest
@testable import msgblastCore

@MainActor
final class NativeDesktopStateTests: XCTestCase {
    func testNativeBindingsMigrateAndKeepImmutableOwnership() throws {
        var old = WebWorkspaceState()
        old.draft = "Keep this draft"
        let bytes = try JSONEncoder().encode(old)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        json.removeValue(forKey: "claudeConversations")
        json.removeValue(forKey: "chatgptConversations")
        var state = try JSONDecoder().decode(WebWorkspaceState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(state.claudeConversations.isEmpty)
        XCTAssertTrue(state.chatgptConversations.isEmpty)
        XCTAssertEqual(state.sessionID, old.sessionID)
        XCTAssertEqual(state.draft, "Keep this draft")
        let id = UUID()
        var claude = ClaudeConversationBinding(comparisonID: id)
        claude.firstPrompt = claude.firstMessage("One")
        claude.url = URL(string: "https://claude.ai/chat/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        try state.recordClaudeBinding(claude)
        var changed = claude
        changed.url = URL(string: "https://claude.ai/chat/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        XCTAssertThrowsError(try state.recordClaudeBinding(changed))
        var other = ClaudeConversationBinding(comparisonID: UUID(), url: claude.url)
        other.firstPrompt = other.firstMessage("Other")
        XCTAssertThrowsError(try state.recordClaudeBinding(other))
        XCTAssertEqual(try state.claudeBinding(for: id), claude)
        var gpt = ChatGPTConversationBinding(comparisonID: id, kind: .chatgpt)
        gpt.firstPrompt = gpt.firstMessage("Two")
        gpt.title = gpt.dedicatedTitle
        try state.recordChatGPTBinding(gpt)
        var wrong = gpt
        wrong.firstPrompt = wrong.firstMessage("Replacement")
        XCTAssertThrowsError(try state.recordChatGPTBinding(wrong))
        XCTAssertThrowsError(try state.chatgptBinding(for: id, kind: .dots))
        let restored = try JSONDecoder().decode(WebWorkspaceState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(try restored.claudeBinding(for: id), claude)
        XCTAssertEqual(try restored.chatgptBinding(for: id, kind: .chatgpt), gpt)
    }


    func testConfirmedChatGPTFallbackMigratesAndCannotBeReassignedOrRemoved() throws {
        let id = UUID()
        var state = WebWorkspaceState()
        var pending = ChatGPTConversationBinding(comparisonID: id, kind: .chatgpt)
        pending.firstPrompt = pending.firstMessage("One confirmed prompt")
        try state.recordChatGPTBinding(pending)
        var confirmed = pending
        confirmed.title = confirmed.dedicatedTitle
        confirmed.fallbackTitle = "Native automatic title"
        try state.recordChatGPTBinding(confirmed)
        let restored = try JSONDecoder().decode(WebWorkspaceState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(try restored.chatgptBinding(for: id, kind: .chatgpt), confirmed)
        var changed = confirmed
        changed.fallbackTitle = "Unrelated native title"
        XCTAssertThrowsError(try state.recordChatGPTBinding(changed))
        changed.fallbackTitle = nil
        XCTAssertThrowsError(try state.recordChatGPTBinding(changed))
        XCTAssertEqual(try state.chatgptBinding(for: id, kind: .chatgpt), confirmed)
        var legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(confirmed)) as? [String: Any])
        legacyJSON.removeValue(forKey: "fallbackTitle")
        let oldBinding = try JSONDecoder().decode(ChatGPTConversationBinding.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        XCTAssertNil(oldBinding.fallbackTitle)
        var oldState = WebWorkspaceState()
        try oldState.recordChatGPTBinding(oldBinding)
        XCTAssertThrowsError(try oldState.recordChatGPTBinding(confirmed))
    }
    func testFallbackRequiresConfirmedChatGPTIdentityAndNonce() throws {
        let id = UUID()
        for kind in [ChatGPTAppKind.chatgpt, .dots] {
            var state = WebWorkspaceState()
            var invalid = ChatGPTConversationBinding(comparisonID: id, kind: kind, fallbackTitle: "Native title")
            XCTAssertThrowsError(try state.recordChatGPTBinding(invalid))
            invalid.title = invalid.dedicatedTitle
            XCTAssertThrowsError(try state.recordChatGPTBinding(invalid))
            invalid.firstPrompt = invalid.firstMessage("Prompt")
            if kind == .dots { XCTAssertThrowsError(try state.recordChatGPTBinding(invalid)) }
            else {
                invalid.fallbackTitle = ""
                XCTAssertThrowsError(try state.recordChatGPTBinding(invalid))
            }
            XCTAssertTrue(state.chatgptConversations.isEmpty)
        }
    }

    func testNativeFixtureConversationsResumeWithoutReplacingTheirBindings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for provider in [WebProvider.chatgptApp, .dotsApp, .claudeApp] {
            let url = directory.appendingPathComponent(provider.storageFilename)
            let id = UUID()
            let session = WebAgentSession(provider: provider, storageURL: url, fixture: true)
            session.setEnabled(true)
            await session.connectDesktopConversation()
            XCTAssertTrue(session.isReadyForOnboarding)
            let opened = await session.openComparison(id)
            XCTAssertTrue(opened)
            let first = await session.send("First", comparisonID: id)
            XCTAssertEqual(first?.status, .observed)
            XCTAssertEqual(session.state.localConversations[id.uuidString]?.map(\.role), ["user", "assistant"])
            let chatgptBinding = session.state.chatgptConversations[id.uuidString]
            let claudeBinding = session.state.claudeConversations[id.uuidString]
            session.beginShutdown()
            let restored = WebAgentSession(provider: provider, storageURL: url, fixture: true)
            let reopened = await restored.openComparison(id)
            XCTAssertTrue(reopened)
            let followUp = await restored.send("Follow-up", comparisonID: id)
            XCTAssertEqual(followUp?.status, .observed)
            XCTAssertEqual(restored.state.chatgptConversations[id.uuidString], chatgptBinding)
            XCTAssertEqual(restored.state.claudeConversations[id.uuidString], claudeBinding)
            XCTAssertTrue(restored.state.localSessionIDs.isEmpty)
            XCTAssertEqual(restored.state.localConversations[id.uuidString]?.count, 4)
            restored.beginShutdown()
        }
    }

    func testChatGPTAndDotsShareOneAppLaunchDuringBroadcastPreparation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var running = false, launches = 0
        let client = DesktopAppInstallationClient(inspect: { _ in
            .init(url: URL(fileURLWithPath: "/Fixture/ChatGPT.app"), processID: running ? 42 : nil)
        }, open: { _ in
            launches += 1
            try await Task.sleep(for: .milliseconds(30))
            running = true
        })
        let sessions = [WebProvider.chatgptApp, .dotsApp].map { provider in
            let session = WebAgentSession(provider: provider, storageURL: directory.appendingPathComponent(provider.storageFilename), fixture: true, museApp: .shared, desktopApps: client)
            session.setEnabled(true)
            session.updateState { $0.desktopConversation = .init(name: provider.name) }
            return session
        }
        let agents = WebAgents(directory: directory.appendingPathComponent("workspace"), fixture: true)
        let id = UUID()
        let ready = await agents.prepareComparison(id, for: sessions)
        XCTAssertTrue(ready)
        XCTAssertEqual(launches, 1, "Both providers use the same installed application")
        let replies = await WebAgents.send("Compare", to: sessions, comparisonID: id)
        XCTAssertEqual(replies.count, 2)
        XCTAssertTrue(replies.values.allSatisfy { $0.status == .observed })
        for session in sessions { session.beginShutdown() }
        agents.beginShutdown()
    }
    func testNativeAppPreparationDoesNotRaceWindowLaunchesAcrossProviders() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var running: Set<URL> = [], activeLaunches = 0, maximumLaunches = 0
        let client = DesktopAppInstallationClient(inspect: { app in
            let url = URL(fileURLWithPath: "/Fixture/\(app.name).app")
            return .init(url: url, processID: running.contains(url) ? 42 : nil)
        }, open: { url in
            activeLaunches += 1
            maximumLaunches = max(maximumLaunches, activeLaunches)
            try await Task.sleep(for: .milliseconds(30))
            running.insert(url)
            activeLaunches -= 1
        })
        let sessions = [WebProvider.chatgptApp, .claudeApp].map { provider in
            let session = WebAgentSession(provider: provider, storageURL: directory.appendingPathComponent(provider.storageFilename), fixture: true, museApp: .shared, desktopApps: client)
            session.setEnabled(true)
            session.updateState { $0.desktopConversation = .init(name: provider.name) }
            return session
        }
        let agents = WebAgents(directory: directory.appendingPathComponent("workspace"), fixture: true)
        let ready = await agents.prepareComparison(UUID(), for: sessions)
        XCTAssertTrue(ready)
        XCTAssertEqual(running.count, 2)
        XCTAssertEqual(maximumLaunches, 1, "Window launches must not compete for the active Space")
        sessions.forEach { $0.beginShutdown() }
        agents.beginShutdown()
    }

}
