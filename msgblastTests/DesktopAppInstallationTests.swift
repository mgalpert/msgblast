import XCTest
@testable import msgblastCore

@MainActor
final class DesktopAppInstallationTests: XCTestCase {
    @MainActor private final class Apps {
        var installation = DesktopAppInstallation(url: nil, processID: nil)
        var opened: [URL] = []
        var onOpen: (() async throws -> Void)?
        var client: DesktopAppInstallationClient {
            .init(inspect: { _ in self.installation }, open: { self.opened.append($0); try await self.onOpen?() })
        }
    }

    func testStartingConversationsLaunchesClosedInstalledAppsButChecksAndRunningAppsDoNot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for provider in WebProvider.desktopProviders {
            let apps = Apps(), url = URL(fileURLWithPath: "/Fixture/" + provider.rawValue + ".app")
            apps.installation = .init(url: url, processID: nil)
            apps.onOpen = { apps.installation = .init(url: url, processID: 123) }
            let session = WebAgentSession(provider: provider, storageURL: directory.appendingPathComponent(provider.storageFilename), fixture: true, museApp: .shared, desktopApps: apps.client)
            session.setEnabled(true)
            session.updateState { $0.desktopConversation = .init(name: provider == .grokBotApp ? "Demo Bot" : provider.name) }
            await session.refresh()
            XCTAssertTrue(apps.opened.isEmpty, "A background check must not launch an app")
            let ready = await session.openComparison(nil)
            XCTAssertTrue(ready, provider.name)
            XCTAssertEqual(apps.opened, [url])
            XCTAssertTrue(session.state.attempts.isEmpty, "Opening a conversation never sends a probe")
            XCTAssertTrue(session.state.localConversations.isEmpty)
            _ = await session.openComparison(UUID())
            XCTAssertEqual(apps.opened, [url], "A running app should not be activated again")
            session.beginShutdown()
        }
    }

    func testFirstDirectPromptLaunchesItsAppAndKeepsTheComparisonAndReceipt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let apps = Apps(), url = URL(fileURLWithPath: "/Fixture/Wabi.app"), id = UUID()
        apps.installation = .init(url: url, processID: nil)
        apps.onOpen = { apps.installation = .init(url: url, processID: 123) }
        let session = WebAgentSession(provider: .wabi, storageURL: directory.appendingPathComponent("state.json"), fixture: true, museApp: .shared, desktopApps: apps.client)
        session.setEnabled(true)
        session.updateState { $0.desktopConversation = .init(name: "Wabi"); $0.draft = "Hello" }
        XCTAssertTrue(session.canSubmitNativePrompt, "A closed installed app must not disable the direct composer")
        let attempt = await session.send("Hello", comparisonID: id)
        XCTAssertEqual(apps.opened, [url])
        XCTAssertEqual(attempt?.status, .observed)
        XCTAssertEqual(attempt?.comparisonID, id)
        XCTAssertNotNil(try session.state.wabiConversation(for: id))
        XCTAssertEqual(session.state.localConversations[id.uuidString]?.first?.text, "Hello")
        session.beginShutdown()
    }

    func testFailedLaunchPreservesDraftAndDoesNotCreateASendAttempt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let apps = Apps(), url = URL(fileURLWithPath: "/Fixture/Wabi.app")
        apps.installation = .init(url: url, processID: nil)
        apps.onOpen = { throw CocoaError(.executableNotLoadable) }
        let session = WebAgentSession(provider: .wabi, storageURL: directory.appendingPathComponent("state.json"), fixture: true, museApp: .shared, desktopApps: apps.client)
        session.setEnabled(true)
        session.updateState { $0.desktopConversation = .init(name: "Wabi"); $0.draft = "Keep me" }
        let attempt = await session.send("Keep me", comparisonID: UUID())
        XCTAssertNil(attempt)
        XCTAssertEqual(apps.opened, [url])
        XCTAssertEqual(session.state.draft, "Keep me")
        XCTAssertTrue(session.state.attempts.isEmpty)
        XCTAssertFalse(session.snapshot.ready)
        XCTAssertNotNil(session.error)
        session.beginShutdown()
    }

    func testChangingComparisonDuringLaunchStopsTheOriginalStartBeforePreparingOrSending() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let apps = Apps(), url = URL(fileURLWithPath: "/Fixture/Wabi.app"), first = UUID(), second = UUID()
        apps.installation = .init(url: url, processID: nil)
        let (launchRelease, releaseLaunch) = AsyncStream<Void>.makeStream()
        apps.onOpen = {
            for await _ in launchRelease { break }
            apps.installation = .init(url: url, processID: 123)
        }
        let session = WebAgentSession(provider: .wabi, storageURL: directory.appendingPathComponent("state.json"), fixture: true, museApp: .shared, desktopApps: apps.client)
        session.setEnabled(true)
        session.updateState { $0.desktopConversation = .init(name: "Wabi") }
        let opening = Task { await session.openComparison(first) }
        while apps.opened.isEmpty { await Task.yield() }
        XCTAssertTrue(session.loading, "Both composers can observe the in-progress launch")
        XCTAssertFalse(session.canSubmitNativePrompt)
        let concurrentPreparation = await session.openComparison(first)
        XCTAssertFalse(concurrentPreparation, "Preparation must not race an existing launch")
        XCTAssertEqual(apps.opened, [url], "Concurrent preparation cannot launch twice")
        session.updateState { $0.comparisonID = second }
        session.updateState { $0.draft = "Second conversation draft" }
        releaseLaunch.yield(())
        releaseLaunch.finish()
        let ready = await opening.value
        XCTAssertFalse(ready)
        XCTAssertEqual(session.state.comparisonID, second)
        XCTAssertEqual(session.state.draft, "Second conversation draft")
        XCTAssertTrue(session.state.conversationURLs.isEmpty)
        XCTAssertTrue(session.state.attempts.isEmpty)
        session.beginShutdown()
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
            _ = await session.openComparison(UUID())
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
