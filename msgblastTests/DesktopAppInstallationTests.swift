import XCTest
@testable import msgblastCore

@MainActor
final class DesktopAppInstallationTests: XCTestCase {
    @MainActor private final class Apps {
        var installation = DesktopAppInstallation(url: nil, processID: nil)
        var opened: [URL] = []
        var openAction: (@MainActor (URL) async throws -> Void)?
        var client: DesktopAppInstallationClient {
            .init(inspect: { _ in self.installation }, open: {
                self.opened.append($0)
                try await self.openAction?($0)
            })
        }
    }

    func testStartingComparisonLaunchesInstalledAppOnceButReadOnlyChecksAndBlankSelectionDoNot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-auto-open-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let apps = Apps(), appURL = URL(fileURLWithPath: "/Fixture/Muse.app")
        apps.installation = .init(url: appURL, processID: nil)
        apps.openAction = { _ in apps.installation = .init(url: appURL, processID: 123) }
        let session = WebAgentSession(provider: .museApp, storageURL: directory.appendingPathComponent("state.json"), fixture: true,
                                      museApp: .shared, desktopApps: apps.client)
        defer { session.beginShutdown() }
        session.setEnabled(true)
        session.updateState { $0.desktopConversation = .init(name: "Muse") }
        await session.connectDesktopConversation()
        _ = await session.openComparison(nil)
        await session.refresh()
        XCTAssertTrue(apps.opened.isEmpty, "Read-only checks and a blank selection must not launch apps")
        let comparison = UUID()
        let ready = await session.openComparison(comparison)
        XCTAssertTrue(ready)
        XCTAssertEqual(apps.opened, [appURL])
        XCTAssertEqual(session.state.museAppConversations[comparison.uuidString]?.comparisonID, comparison)
        XCTAssertTrue(session.state.attempts.isEmpty, "Opening a conversation must not submit a probe")
        _ = await session.openComparison(UUID())
        XCTAssertEqual(apps.opened, [appURL], "Reuse an already running app")
    }

    func testStartingConversationReopensRunningAppWithNoMainWindowWithoutSending() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-reopen-window-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("driver")
        try Data("""
        #!/usr/bin/env python3
        import sys,json,pathlib,time
        p=pathlib.Path(__file__).parent
        assert sys.argv[1]=='call'
        tool=sys.argv[2];args=json.loads(sys.argv[3])
        with (p/'calls.jsonl').open('a') as f:f.write(tool+'\\n')
        if tool=='list_apps':
            print(json.dumps({'apps':[{'bundle_id':'com.google.GeminiMacOS','pid':42,'running':True}]}))
        elif tool=='list_windows':
            assert args=={'pid':42}
            windows=[{'window_id':21,'title':'','is_on_screen':True,'bounds':{'width':1000,'height':900}}] if (p/'opened').exists() else []
            print(json.dumps({'windows':windows}))
        else: raise AssertionError('Unexpected action: '+tool)
        sys.stdout.flush();time.sleep(.02)
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let apps = Apps(), appURL = URL(fileURLWithPath: "/Fixture/Gemini.app")
        apps.installation = .init(url: appURL, processID: 42)
        apps.openAction = { _ in try Data().write(to: directory.appendingPathComponent("opened")) }
        let driver = DesktopAppConversation(executable: executable)
        let gemini = GeminiAppConversation(executable: executable, readNative: { _, _ in
            throw DesktopAppError.unavailable("Fixture sign-in required")
        })
        let session = WebAgentSession(provider: .geminiApp, storageURL: directory.appendingPathComponent("state.json"), fixture: false,
                                      museApp: .shared, desktopApps: apps.client, desktopDriver: driver, geminiApp: gemini)
        defer { session.beginShutdown() }
        session.setEnabled(true)
        session.updateState { $0.desktopConversation = .init(name: "Gemini"); $0.draft = "Retain my prompt" }
        let ready = await session.openComparison(UUID())
        XCTAssertFalse(ready, "The window reopened, but sign-in was not completed")
        XCTAssertEqual(apps.opened, [appURL], "A running process without a window still needs an explicit open")
        XCTAssertEqual(session.state.draft, "Retain my prompt")
        XCTAssertTrue(session.state.attempts.isEmpty)
        XCTAssertFalse(session.loading)
        let tools = try String(contentsOf: directory.appendingPathComponent("calls.jsonl"), encoding: .utf8).split(separator: "\n")
        XCTAssertTrue(tools.contains("list_windows"))
        XCTAssertTrue(tools.allSatisfy { $0 == "list_apps" || $0 == "list_windows" }, "Readiness must use only metadata, never input or a probe send")
    }

    func testDirectFirstSendLaunchesAppAndLaunchFailurePreservesDraftWithoutAttempt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-send-auto-open-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let apps = Apps(), appURL = URL(fileURLWithPath: "/Fixture/Muse.app")
        apps.installation = .init(url: appURL, processID: nil)
        apps.openAction = { _ in throw DesktopAppError.unavailable("Fixture launch refused") }
        let session = WebAgentSession(provider: .museApp, storageURL: directory.appendingPathComponent("state.json"), fixture: true,
                                      museApp: .shared, desktopApps: apps.client)
        defer { session.beginShutdown() }
        session.setEnabled(true)
        session.updateState { $0.desktopConversation = .init(name: "Muse"); $0.draft = "Keep this prompt" }
        let comparison = UUID()
        let failed = await session.send("Keep this prompt", comparisonID: comparison)
        XCTAssertNil(failed)
        XCTAssertEqual(apps.opened, [appURL])
        XCTAssertEqual(session.state.draft, "Keep this prompt")
        XCTAssertTrue(session.state.attempts.isEmpty)
        XCTAssertTrue(session.error?.contains("Fixture launch refused") == true)
        apps.openAction = { _ in apps.installation = .init(url: appURL, processID: 123) }
        let sent = await session.send("Keep this prompt", comparisonID: comparison)
        XCTAssertEqual(sent?.status, .observed)
        XCTAssertEqual(apps.opened, [appURL, appURL])
        XCTAssertEqual(session.state.localConversations[comparison.uuidString]?.last?.role, "assistant")
    }

    func testChangingComparisonDuringLaunchDoesNotPrepareTheAbandonedConversation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-abandoned-open-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let apps = Apps(), appURL = URL(fileURLWithPath: "/Fixture/Muse.app")
        apps.installation = .init(url: appURL, processID: nil)
        var release: CheckedContinuation<Void, Never>?
        let launched = expectation(description: "Launch started")
        apps.openAction = { _ in
            await withCheckedContinuation { release = $0; launched.fulfill() }
            apps.installation = .init(url: appURL, processID: 123)
        }
        let session = WebAgentSession(provider: .museApp, storageURL: directory.appendingPathComponent("state.json"), fixture: true,
                                      museApp: .shared, desktopApps: apps.client)
        defer { session.beginShutdown() }
        session.setEnabled(true)
        session.updateState { $0.desktopConversation = .init(name: "Muse") }
        let abandoned = UUID()
        let opening = Task { await session.openComparison(abandoned) }
        await fulfillment(of: [launched], timeout: 1)
        let replacement = UUID()
        session.updateState { $0.comparisonID = replacement }
        session.updateState { $0.draft = "Replacement draft" }
        release?.resume()
        let ready = await opening.value
        XCTAssertFalse(ready)
        XCTAssertEqual(session.state.comparisonID, replacement)
        XCTAssertEqual(session.state.draft, "Replacement draft")
        XCTAssertTrue(session.state.museAppConversations.isEmpty)
        XCTAssertTrue(session.state.attempts.isEmpty)
        XCTAssertFalse(session.loading)
    }

    func testQuickNativeSelectionWaitsForExistingPreparationAndReusesSharedApp() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let apps = Apps(), url = URL(fileURLWithPath: "/Fixture/ChatGPT.app")
        apps.installation = .init(url: url, processID: nil)
        var release: CheckedContinuation<Void, Never>?
        let started = expectation(description: "First app launch held")
        apps.openAction = { _ in
            if apps.opened.count == 1 { await withCheckedContinuation { release = $0; started.fulfill() } }
            apps.installation = .init(url: url, processID: 42)
        }
        let sessions = [WebProvider.chatgptApp, .dotsApp].map { provider in
            let session = WebAgentSession(provider: provider, storageURL: directory.appendingPathComponent(provider.storageFilename), fixture: true, museApp: .shared, desktopApps: apps.client)
            session.setEnabled(true)
            session.updateState { $0.desktopConversation = .init(name: provider.name) }
            return session
        }
        let agents = WebAgents(directory: directory.appendingPathComponent("workspace"), fixture: true)
        defer { sessions.forEach { $0.beginShutdown() }; agents.beginShutdown() }
        let id = UUID()
        let first = Task { await agents.prepareComparison(id, for: [sessions[0]]) }
        await fulfillment(of: [started], timeout: 1)
        agents.toggle(sessions[1])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(apps.opened.count, 1, "A quick second selection must wait for the existing shared-app preparation")
        release?.resume(); release = nil
        let ready = await first.value
        XCTAssertTrue(ready)
        for _ in 0..<100 where !sessions[1].snapshot.ready { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(sessions[1].snapshot.ready)
        XCTAssertEqual(apps.opened, [url])
        XCTAssertTrue(sessions.allSatisfy { $0.state.attempts.isEmpty })
    }

    func testQueuedPreparationDoesNotReopenAnAbandonedComparison() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let apps = Apps(), url = URL(fileURLWithPath: "/Fixture/ChatGPT.app")
        apps.installation = .init(url: url, processID: nil)
        var release: CheckedContinuation<Void, Never>?
        let started = expectation(description: "App launch held before comparison changed")
        apps.openAction = { _ in
            await withCheckedContinuation { release = $0; started.fulfill() }
            apps.installation = .init(url: url, processID: 42)
        }
        let sessions = [WebProvider.chatgptApp, .dotsApp].map { provider in
            let session = WebAgentSession(provider: provider, storageURL: directory.appendingPathComponent(provider.storageFilename), fixture: true, museApp: .shared, desktopApps: apps.client)
            session.setEnabled(true)
            session.updateState { $0.desktopConversation = .init(name: provider.name) }
            return session
        }
        let agents = WebAgents(directory: directory.appendingPathComponent("workspace"), fixture: true)
        defer { sessions.forEach { $0.beginShutdown() }; agents.beginShutdown() }
        let abandoned = UUID(), replacement = UUID()
        let preparing = Task { await agents.prepareComparison(abandoned, for: sessions) }
        await fulfillment(of: [started], timeout: 1)
        agents.setComparison(replacement)
        sessions.forEach { $0.updateState { $0.comparisonID = replacement } }
        release?.resume(); release = nil
        let ready = await preparing.value
        XCTAssertFalse(ready)
        XCTAssertEqual(agents.comparisonID, replacement)
        XCTAssertTrue(sessions.allSatisfy { $0.state.comparisonID == replacement && $0.state.attempts.isEmpty })
        XCTAssertNil(sessions[1].state.chatgptConversations[abandoned.uuidString])
    }

    func testDirectSendAbandonedDuringLaunchPreservesReplacementDraftWithoutAttempt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let apps = Apps(), url = URL(fileURLWithPath: "/Fixture/Claude.app")
        apps.installation = .init(url: url, processID: nil)
        var release: CheckedContinuation<Void, Never>?
        let started = expectation(description: "Direct send app launch held")
        apps.openAction = { _ in
            await withCheckedContinuation { release = $0; started.fulfill() }
            apps.installation = .init(url: url, processID: 42)
        }
        let session = WebAgentSession(provider: .claudeApp, storageURL: directory.appendingPathComponent("state.json"), fixture: true, museApp: .shared, desktopApps: apps.client)
        defer { session.beginShutdown() }
        session.setEnabled(true)
        session.updateState { $0.desktopConversation = .init(name: "Claude") }
        let sending = Task { await session.send("Abandoned prompt", comparisonID: UUID()) }
        await fulfillment(of: [started], timeout: 1)
        let replacement = UUID()
        session.updateState { $0.comparisonID = replacement }
        session.updateState { $0.draft = "Replacement draft" }
        release?.resume(); release = nil
        let attempt = await sending.value
        XCTAssertNil(attempt)
        XCTAssertTrue(session.state.attempts.isEmpty)
        XCTAssertTrue(session.state.claudeConversations.isEmpty)
        XCTAssertEqual(session.state.comparisonID, replacement)
        XCTAssertEqual(session.state.draft, "Replacement draft")
        XCTAssertFalse(session.isSending)
    }

    func testDiscoveryRequiresTheMatchingBundleAndAnExecutableThatStillExists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-installed-app-\(UUID()).app")
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let executable = contents.appendingPathComponent("MacOS/TestApp")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.meta.endo", "CFBundleExecutable": "TestApp", "CFBundlePackageType": "APPL"], format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        XCTAssertEqual(DesktopAppInstallation.validatedURL(root, for: .muse), root)
        XCTAssertNil(DesktopAppInstallation.validatedURL(root, for: .wabi))
        try FileManager.default.removeItem(at: executable)
        XCTAssertNil(DesktopAppInstallation.validatedURL(root, for: .muse), "A stale LaunchServices URL is not an installed app")
    }

    func testMissingAppsCannotEnableConnectOrSendEvenWithALegacyBinding() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-missing-desktop-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        for provider in WebProvider.desktopProviders {
            let apps = Apps()
            let session = WebAgentSession(provider: provider, storageURL: directory.appendingPathComponent(provider.storageFilename), fixture: true,
                                          museApp: .shared, desktopApps: apps.client)
            session.setEnabled(true)
            XCTAssertFalse(session.isEnabled)
            session.updateState {
                $0.enabled = true
                $0.desktopConversation = .init(name: "Saved conversation")
                $0.draft = "Keep this draft"
            }
            await session.connectDesktopConversation()
            let sent = await session.send("Keep this draft", comparisonID: UUID())
            XCTAssertNil(sent)
            XCTAssertFalse(session.desktopReady)
            XCTAssertFalse(session.snapshot.ready)
            XCTAssertNil(session.desktopConnectionConfirmation)
            XCTAssertEqual(session.state.desktopConversation?.name, "Saved conversation")
            XCTAssertEqual(session.state.draft, "Keep this draft")
            XCTAssertTrue(session.state.attempts.isEmpty)
            XCTAssertTrue(session.state.museAppConversations.isEmpty)
            XCTAssertTrue(session.state.geminiConversations.isEmpty)
            XCTAssertTrue(apps.opened.isEmpty)
            session.beginShutdown()
        }
    }

    func testDiscoveryPrefersAValidRunningCopyAndNeverBorrowsItsPIDForAnotherBundle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-desktop-copies-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        func makeApp(_ name: String) throws -> URL {
            let app = directory.appendingPathComponent(name + ".app")
            let contents = app.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            let executable = contents.appendingPathComponent("MacOS/Muse")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.meta.endo", "CFBundleExecutable": "Muse", "CFBundlePackageType": "APPL"], format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            return app
        }
        let running = try makeApp("Running"), registered = try makeApp("Registered")
        var found = DesktopAppInstallation.resolve(for: .muse, registeredURL: registered, runningURL: running, processID: 4242)
        XCTAssertEqual(found.url, running)
        XCTAssertEqual(found.processID, 4242)
        try FileManager.default.removeItem(at: registered)
        found = DesktopAppInstallation.resolve(for: .muse, registeredURL: registered, runningURL: running, processID: 4242)
        XCTAssertEqual(found.url, running, "A stale registry entry cannot hide the valid running app")
        XCTAssertTrue(found.isRunning)
        _ = try makeApp("Registered")
        try FileManager.default.removeItem(at: running)
        found = DesktopAppInstallation.resolve(for: .muse, registeredURL: registered, runningURL: running, processID: 4242)
        XCTAssertEqual(found.url, registered)
        XCTAssertNil(found.processID, "An installed copy cannot borrow the removed copy's PID")
        XCTAssertTrue(found.isInstalled)
        XCTAssertFalse(found.isRunning)
    }

    func testOpeningAnInstalledAppDoesNotClaimAConversationCheck() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-open-desktop-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let apps = Apps(), appURL = URL(fileURLWithPath: "/Fixture/Muse.app")
        apps.installation = .init(url: appURL, processID: nil)
        let session = WebAgentSession(provider: .museApp, storageURL: directory.appendingPathComponent("state.json"), fixture: true,
                                      museApp: .shared, desktopApps: apps.client)
        session.setEnabled(true)
        await session.openDesktopApp()
        XCTAssertEqual(apps.opened, [appURL])
        XCTAssertFalse(session.desktopReady)
        XCTAssertNil(session.desktopConnectionConfirmation)
        XCTAssertTrue(session.state.attempts.isEmpty)
        session.beginShutdown()
    }

    func testReadOnlyCheckConfirmsFirstPromptAndAppRestartInvalidatesItWithoutLosingHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-desktop-ready-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let apps = Apps(), appURL = URL(fileURLWithPath: "/Fixture/Muse.app")
        apps.installation = .init(url: appURL, processID: 123)
        let session = WebAgentSession(provider: .museApp, storageURL: directory.appendingPathComponent("state.json"), fixture: true,
                                      museApp: .shared, desktopApps: apps.client)
        session.setEnabled(true)
        await session.connectDesktopConversation()
        XCTAssertTrue(session.desktopReady)
        XCTAssertTrue(session.isReadyForOnboarding)
        XCTAssertTrue(session.desktopConnectionConfirmation?.contains("new side chat") == true)
        XCTAssertTrue(session.state.attempts.isEmpty, "A connection check must not send a test prompt")
        XCTAssertTrue(session.state.localConversations.isEmpty)
        XCTAssertTrue(session.state.museAppConversations.isEmpty, "The first real prompt owns side-chat creation")
        let saved = session.state.desktopConversation
        apps.installation = .init(url: appURL, processID: 456)
        session.refreshDesktopInstallation()
        XCTAssertFalse(session.desktopReady)
        XCTAssertFalse(session.snapshot.ready)
        XCTAssertNil(session.desktopConnectionConfirmation)
        XCTAssertEqual(session.state.desktopConversation, saved)
        await session.connectDesktopConversation()
        XCTAssertTrue(session.desktopReady)
        session.setEnabled(false)
        XCTAssertNil(session.desktopConnectionConfirmation, "A disabled agent must not claim it is ready for the first prompt")
        session.setEnabled(true)
        apps.installation = .init(url: nil, processID: nil)
        session.refreshDesktopInstallation()
        XCTAssertFalse(session.desktopReady)
        XCTAssertFalse(session.snapshot.ready)
        XCTAssertEqual(session.state.desktopConversation, saved)
        session.beginShutdown()
    }
}
