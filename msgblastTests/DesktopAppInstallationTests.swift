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

    private final class HeldMuseRead: @unchecked Sendable {
        private let condition = NSCondition()
        private var released = false
        private var reads = 0
        let started: XCTestExpectation
        let observation: MuseAppObservation
        let failFollowingRead: Bool
        init(started: XCTestExpectation, failFollowingRead: Bool = false) throws {
            self.started = started
            self.failFollowingRead = failFollowingRead
            observation = MuseAppObservation(url: URL(string: "https://muse.ai/")!, draft: "", composerFocused: true, messages: [])
        }
        var count: Int { condition.lock(); defer { condition.unlock() }; return reads }
        func capture() throws -> MuseAppObservation {
            condition.lock()
            reads += 1
            let first = reads == 1
            if first {
                started.fulfill()
                let deadline = Date().addingTimeInterval(5)
                while !released {
                    guard condition.wait(until: deadline) else {
                        condition.unlock()
                        throw DesktopAppError.unavailable("Fixture read was not released")
                    }
                }
            }
            condition.unlock()
            if !first, failFollowingRead { throw DesktopAppError.unavailable("Fixture replacement requires sign-in") }
            return observation
        }
        func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    }

    private func readOnlyMuseDriver(in directory: URL) throws -> URL {
        let executable = directory.appendingPathComponent("driver")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("""
        #!/usr/bin/env python3
        import sys,json,pathlib,time
        tool=sys.argv[2];args=json.loads(sys.argv[3])
        with (pathlib.Path(__file__).parent/'calls').open('a') as f:f.write(tool+'\\n')
        if tool=='list_apps':
            assert args=={}
            print(json.dumps({'apps':[{'bundle_id':'com.meta.endo','pid':42,'running':True}]}))
        elif tool=='list_windows':
            assert args=={'pid':42}
            print(json.dumps({'windows':[{'window_id':21,'title':'Muse','is_on_screen':True,'bounds':{'width':1000,'height':900}}]}))
        elif tool=='get_window_state':
            print(json.dumps({'elements':[{'role':'AXWindow'}]}))
        else: raise AssertionError('Unexpected mutation: '+tool)
        sys.stdout.flush();time.sleep(.02)
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    func testReadinessRefreshCannotMarkReplacementComparisonReady() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try readOnlyMuseDriver(in: directory)
        let held = try HeldMuseRead(started: expectation(description: "Old comparison availability read held"))
        defer { held.release() }
        let apps = Apps()
        apps.installation = .init(url: URL(fileURLWithPath: "/Fixture/Muse.app"), processID: 42)
        let session = WebAgentSession(provider: .museApp, storageURL: directory.appendingPathComponent("state.json"), fixture: false,
                                      museApp: MuseAppConversation(executable: executable, readNative: { _ in try held.capture() }),
                                      desktopApps: apps.client, desktopDriver: DesktopAppConversation(executable: executable))
        defer { session.beginShutdown() }
        session.setEnabled(true)
        session.updateState { $0.desktopConversation = .init(name: "Muse"); $0.comparisonID = UUID() }
        session.connect(automaticallyRefresh: false)
        let refresh = Task { await session.refresh() }
        await fulfillment(of: [held.started], timeout: 2)
        let replacement = UUID()
        session.updateState { $0.comparisonID = replacement }
        session.updateState { $0.draft = "Replacement draft" }
        held.release()
        await refresh.value
        XCTAssertEqual(held.count, 1)
        XCTAssertEqual(session.state.comparisonID, replacement)
        XCTAssertFalse(session.desktopReady, "A successful read from the previous comparison cannot authorize its replacement")
        XCTAssertFalse(session.snapshot.ready)
        XCTAssertEqual(session.state.draft, "Replacement draft")
        XCTAssertTrue(session.state.attempts.isEmpty)
        XCTAssertTrue(apps.opened.isEmpty)
    }

    func testExplicitConversationStartWaitsForRefreshThenMakesItsOwnAvailabilityCheck() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try readOnlyMuseDriver(in: directory)
        let held = try HeldMuseRead(started: expectation(description: "Background availability read held"), failFollowingRead: true)
        defer { held.release() }
        let apps = Apps()
        apps.installation = .init(url: URL(fileURLWithPath: "/Fixture/Muse.app"), processID: 42)
        let session = WebAgentSession(provider: .museApp, storageURL: directory.appendingPathComponent("state.json"), fixture: false,
                                      museApp: MuseAppConversation(executable: executable, readNative: { _ in try held.capture() }),
                                      desktopApps: apps.client, desktopDriver: DesktopAppConversation(executable: executable))
        defer { session.beginShutdown() }
        session.setEnabled(true)
        session.updateState { $0.desktopConversation = .init(name: "Muse") }
        session.connect(automaticallyRefresh: false)
        let refresh = Task { await session.refresh() }
        await fulfillment(of: [held.started], timeout: 2)
        let comparison = UUID()
        var openingFinished = false
        let opening = Task {
            let ready = await session.openComparison(comparison)
            openingFinished = true
            return ready
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var passedLaunchCheck = false
        while ContinuousClock.now < deadline {
            let calls = (try? String(contentsOf: directory.appendingPathComponent("calls"), encoding: .utf8)) ?? ""
            if calls.split(separator: "\n").count >= 4, !session.loading {
                passedLaunchCheck = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(passedLaunchCheck, "The explicit start must reach the post-launch refresh boundary before releasing the old read")
        XCTAssertFalse(openingFinished, "An in-flight availability read should delay preparation rather than falsely failing it")
        XCTAssertEqual(held.count, 1, "The explicit start must not race the occupied native reader")
        held.release()
        await refresh.value
        let ready = await opening.value
        XCTAssertFalse(ready, "The new check intentionally reports that sign-in is required")
        XCTAssertEqual(held.count, 3, "The explicit start must wait and make a fresh check; Muse may repeat that failed read once")
        XCTAssertTrue(session.desktopStatus.contains("Fixture replacement requires sign-in"), session.desktopStatus)
        XCTAssertEqual(session.state.comparisonID, comparison)
        XCTAssertFalse(session.snapshot.ready)
        XCTAssertTrue(session.state.attempts.isEmpty)
        XCTAssertTrue(apps.opened.isEmpty)
    }

    func testExplicitFirstPromptCanPrepareClosedAndRunningNativeAppsBeforeComparisonExists() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let web = WebAgents(directory: directory.appendingPathComponent("agents"), fixture: true)
        defer { web.beginShutdown() }
        for running in [false, true] {
            for provider in WebProvider.desktopProviders {
                let apps = Apps(), url = URL(fileURLWithPath: "/Fixture/" + provider.rawValue + ".app")
                apps.installation = .init(url: url, processID: running ? 42 : nil)
                apps.openAction = { _ in apps.installation = .init(url: url, processID: 42) }
                let session = WebAgentSession(provider: provider, storageURL: directory.appendingPathComponent(UUID().uuidString), fixture: true, museApp: .shared, desktopApps: apps.client)
                defer { session.beginShutdown() }
                session.setEnabled(true)
                session.updateState { $0.desktopConversation = .init(name: provider == .grokBotApp ? "Demo Bot" : provider.name) }
                XCTAssertFalse(session.snapshot.ready)
                XCTAssertTrue(session.canSubmitNativePrompt, "A configured app must allow an explicit connection attempt after restart, even if already running")
                let ready = await web.prepareComparison(nil, for: [session], startNativeApps: true)
                XCTAssertTrue(ready, provider.name)
                XCTAssertEqual(apps.opened, running ? [] : [url])
                XCTAssertNil(session.state.comparisonID)
                XCTAssertTrue(session.state.attempts.isEmpty, "Preparing the explicit first prompt must not submit it")
                XCTAssertTrue(session.state.localConversations.isEmpty)
                var pending = WebSendAttempt(text: "Prior unresolved prompt", status: .uncertain)
                pending.comparisonID = UUID()
                session.updateState { $0.attempts = [pending] }
                XCTAssertFalse(session.canSubmitNativePrompt, "Restart recovery must retain the no-resend guard")
            }
        }
    }

    func testEveryNativeProviderLaunchesOnceFromAnExplicitConversationStart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for provider in WebProvider.desktopProviders {
            let apps = Apps(), url = URL(fileURLWithPath: "/Fixture/" + provider.rawValue + ".app")
            apps.installation = .init(url: url, processID: nil)
            apps.openAction = { _ in apps.installation = .init(url: url, processID: 42) }
            let session = WebAgentSession(provider: provider, storageURL: directory.appendingPathComponent(provider.storageFilename), fixture: true, museApp: .shared, desktopApps: apps.client)
            session.setEnabled(true)
            session.updateState { $0.desktopConversation = .init(name: provider == .grokBotApp ? "Demo Bot" : provider.name) }
            XCTAssertTrue(session.canSubmitNativePrompt, "A configured closed app must keep its direct composer available")
            await session.refresh()
            XCTAssertTrue(apps.opened.isEmpty, "A background check must never open an app")
            let id = UUID()
            let ready = await session.openComparison(id)
            XCTAssertTrue(ready, provider.name)
            XCTAssertEqual(apps.opened, [url])
            XCTAssertTrue(session.state.attempts.isEmpty)
            XCTAssertTrue(session.state.localConversations.isEmpty)
            _ = await session.openComparison(UUID())
            XCTAssertEqual(apps.opened, [url], "Reuse an existing running app")
            session.beginShutdown()
            XCTAssertFalse(session.canSubmitNativePrompt)
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
            print(json.dumps({'apps':[{'bundle_id':'com.meta.endo','pid':42,'running':True}]}))
        elif tool=='list_windows':
            assert args=={'pid':42}
            windows=[{'window_id':21,'title':'Muse','is_on_screen':True,'bounds':{'width':1000,'height':900}}] if (p/'opened').exists() else []
            print(json.dumps({'windows':windows}))
        else: raise AssertionError('Unexpected action: '+tool)
        sys.stdout.flush();time.sleep(.02)
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let apps = Apps(), appURL = URL(fileURLWithPath: "/Fixture/Muse.app")
        apps.installation = .init(url: appURL, processID: 42)
        apps.openAction = { _ in try Data().write(to: directory.appendingPathComponent("opened")) }
        let driver = DesktopAppConversation(executable: executable)
        let muse = MuseAppConversation(executable: executable, readNative: { _ in
            throw DesktopAppError.unavailable("Fixture sign-in required")
        })
        let session = WebAgentSession(provider: .museApp, storageURL: directory.appendingPathComponent("state.json"), fixture: false,
                                      museApp: muse, desktopApps: apps.client, desktopDriver: driver)
        defer { session.beginShutdown() }
        session.setEnabled(true)
        session.updateState { $0.desktopConversation = .init(name: "Muse"); $0.draft = "Retain my prompt" }
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

    func testExplicitOnboardingConnectReopensShippingAppsAndWaitsForTheirWindow() async throws {
        for provider in WebProvider.desktopProviders {
            let app = try XCTUnwrap(provider.desktopApp)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let executable = directory.appendingPathComponent("driver")
            try Data(app.bundleIDs[0].utf8).write(to: directory.appendingPathComponent("bundle"))
            try Data("""
            #!/usr/bin/env python3
            import sys,json,pathlib,time
            p=pathlib.Path(__file__).parent
            tool=sys.argv[2];args=json.loads(sys.argv[3])
            with (p/'calls').open('a') as f:f.write(tool+'\\n')
            if tool=='list_apps':
                print(json.dumps({'apps':[{'bundle_id':(p/'bundle').read_text(),'pid':42,'running':True}]}))
            elif tool=='list_windows':
                assert args=={'pid':42}
                ready=(p/'opened').exists() and (p/'warming').exists()
                if (p/'opened').exists(): (p/'warming').touch()
                print(json.dumps({'windows':[{'window_id':21,'title':'Main','is_on_screen':True,'bounds':{'width':1000,'height':900}}] if ready else []}))
            else: raise AssertionError('Unexpected action: '+tool)
            sys.stdout.flush();time.sleep(.02)
            """.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let apps = Apps(), url = URL(fileURLWithPath: "/Fixture/" + app.name + ".app")
            apps.installation = .init(url: url, processID: 42)
            apps.openAction = { _ in try Data().write(to: directory.appendingPathComponent("opened")) }
            let session = WebAgentSession(provider: provider, storageURL: directory.appendingPathComponent("state.json"),
                                          fixture: false, museApp: .shared, desktopApps: apps.client,
                                          desktopDriver: DesktopAppConversation(executable: executable))
            defer { session.beginShutdown() }
            session.setEnabled(true)
            session.updateState { $0.draft = "Keep my prompt" }
            let prepared = await session.prepareDesktopConnection()
            XCTAssertTrue(prepared, provider.name)
            XCTAssertEqual(apps.opened, [url], "Reopen the window even when its process is already running")
            XCTAssertFalse(session.loading)
            XCTAssertFalse(session.desktopReady, "Window readiness must not substitute for the conversation check")
            XCTAssertEqual(session.state.draft, "Keep my prompt")
            XCTAssertTrue(session.state.attempts.isEmpty)
            let calls = try String(contentsOf: directory.appendingPathComponent("calls"), encoding: .utf8).split(separator: "\n")
            XCTAssertEqual(calls.filter { $0 == "list_windows" }.count, 3, "Wait for delayed window creation on the first attempt")
            XCTAssertTrue(calls.allSatisfy { $0 == "list_apps" || $0 == "list_windows" })
        }
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
        XCTAssertTrue(session.loading)
        XCTAssertFalse(session.canSubmitNativePrompt)
        let duplicateOpen = await session.openComparison(abandoned)
        XCTAssertFalse(duplicateOpen)
        XCTAssertEqual(apps.opened, [appURL])
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
        let firstPreparation = agents.preparationID
        agents.toggle(sessions[1])
        for _ in 0..<100 where agents.preparationID == firstPreparation { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotEqual(agents.preparationID, firstPreparation, "The second request must enter the preparation queue before the launch is released")
        XCTAssertNotNil(agents.preparationID)
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
