import XCTest
@testable import msgblastCore

@MainActor
final class DesktopAppInstallationTests: XCTestCase {
    @MainActor private final class Apps {
        var installation = DesktopAppInstallation(url: nil, processID: nil)
        var opened: [URL] = []
        var activations: [Bool] = []
        var hidden = false
        var openAction: (@MainActor (URL, Bool) async throws -> Void)?
        var client: DesktopAppInstallationClient {
            .init(inspect: { _ in self.installation }, open: { url, activates in
                self.opened.append(url)
                self.activations.append(activates)
                try await self.openAction?(url, activates)
            }, isHidden: { _ in self.hidden })
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
        XCTAssertGreaterThan(held.count, 1, "After the old read finishes, the explicit start must make its own check rather than reuse the old successful result")
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
                apps.openAction = { _, _ in apps.installation = .init(url: url, processID: 42) }
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

    private typealias Client = DesktopAppInstallationClient

    @MainActor private final class BackgroundRecorder {
        var calls: [String] = []
        var reads: [Bool]
        var readCount = 0
        var cancelOnRead = false
        init(reads: [Bool]) { self.reads = reads }
        func steps(running: Bool, hidden: Bool) -> Client.BackgroundOpenSteps {
            .init(running: running, hidden: hidden, unhide: { self.calls.append("unhide") }, readWindow: { _ in
                defer { self.readCount += 1 }
                self.calls.append("read")
                if self.cancelOnRead { withUnsafeCurrentTask { $0?.cancel() } }
                return self.reads.isEmpty ? false : self.reads[min(self.readCount, self.reads.count - 1)]
            }, open: { self.calls.append("open") }, afterOpen: { self.calls.append("handBack") })
        }
        var withoutReads: [String] { calls.filter { $0 != "read" } }
    }

    func testBackgroundOpenOfHiddenAppWithAWindowOnlyUnhides() async throws {
        let recorder = BackgroundRecorder(reads: [true])
        try await Client.openInBackground(recorder.steps(running: true, hidden: true), clock: AdvancingClock())
        XCTAssertEqual(recorder.calls, ["unhide", "read"])
    }

    func testBackgroundOpenOfVisibleAppWithAWindowDoesNothing() async throws {
        let recorder = BackgroundRecorder(reads: [true])
        try await Client.openInBackground(recorder.steps(running: true, hidden: false), clock: AdvancingClock())
        XCTAssertEqual(recorder.calls, ["read"])
    }

    func testBackgroundOpenWhoseFirstWindowCheckIsEmptyWaitsForTheWindowAfterUnhiding() async throws {
        let recorder = BackgroundRecorder(reads: [false, false, true])
        try await Client.openInBackground(recorder.steps(running: true, hidden: true), clock: AdvancingClock())
        XCTAssertEqual(recorder.withoutReads, ["unhide"])
        XCTAssertEqual(recorder.readCount, 3)
    }

    func testBackgroundOpenThatNeverFindsAWindowReopensAndHandsBack() async throws {
        let clock = AdvancingClock()
        let recorder = BackgroundRecorder(reads: [false])
        try await Client.openInBackground(recorder.steps(running: true, hidden: true), clock: clock)
        XCTAssertEqual(recorder.withoutReads, ["unhide", "open", "handBack"])
        XCTAssertEqual(clock.sleeps.reduce(.zero, +), .seconds(1))
        XCTAssertEqual(recorder.readCount, 11)
    }

    func testBackgroundOpenOfAClosedAppOpensAndHandsBackWithoutCheckingWindows() async throws {
        let recorder = BackgroundRecorder(reads: [true])
        try await Client.openInBackground(recorder.steps(running: false, hidden: false), clock: AdvancingClock())
        XCTAssertEqual(recorder.calls, ["open", "handBack"])
    }

    func testWindowPollStopsAtTheDeadlineEvenWhenReadsAreSlow() async throws {
        let clock = AdvancingClock()
        var reads = 0
        let found = try await Client.windowAppeared(within: .seconds(1), clock: clock) { _ in
            reads += 1
            clock.advance(by: .milliseconds(700))
            return false
        }
        XCTAssertFalse(found)
        XCTAssertEqual(reads, 2)
    }

    func testWindowPollPropagatesCancellationAfterAnAccessibilityRead() async {
        let recorder = BackgroundRecorder(reads: [true])
        recorder.cancelOnRead = true
        let task = Task { @MainActor in
            try await Client.openInBackground(recorder.steps(running: true, hidden: true), clock: AdvancingClock())
        }
        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(recorder.calls, ["unhide", "read"])
    }

    func testCancelledBackgroundOpenNeitherUnhidesNorOpens() async {
        let recorder = BackgroundRecorder(reads: [false])
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await Client.openInBackground(recorder.steps(running: true, hidden: true), clock: AdvancingClock())
        }
        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(recorder.calls, [])
    }

    private func watchState(_ activations: [Int32], front: Int32? = 2, targetWasActive: Bool = false, previousRunning: Bool = true,
                            previous: Int32? = 1, target: Int32? = 2) -> Client.FrontWatchState {
        .init(previousPID: previous, targetWasActive: targetWasActive, activations: activations, frontmostPID: front,
              targetPID: target, previousRunning: previousRunning)
    }

    func testHandBackDecisionFollowsEveryActivationSinceTheStart() {
        // A → B during launch → ChatGPT: the user moved on, so leave the front alone.
        XCTAssertEqual(Client.handBackDecision(watchState([3, 2])), .cancel)
        // A → ChatGPT: hand back.
        XCTAssertEqual(Client.handBackDecision(watchState([2])), .handBack)
        // ChatGPT activated but isn't frontmost yet, or nothing happened yet.
        XCTAssertEqual(Client.handBackDecision(watchState([2], front: 1)), .wait)
        XCTAssertEqual(Client.handBackDecision(watchState([], front: 1)), .wait)
        XCTAssertEqual(Client.handBackDecision(watchState([], front: 1, target: nil)), .wait)
        // A non-target activation before the target is known still cancels.
        XCTAssertEqual(Client.handBackDecision(watchState([3], front: 3, target: nil)), .cancel)
        XCTAssertEqual(Client.handBackDecision(watchState([2], targetWasActive: true)), .cancel)
        XCTAssertEqual(Client.handBackDecision(watchState([2], previousRunning: false)), .cancel)
        XCTAssertEqual(Client.handBackDecision(watchState([2], previous: 2)), .cancel)
        XCTAssertEqual(Client.handBackDecision(watchState([2], previous: nil)), .cancel)
    }

    func testHandBackRestoresOnceWhenOnlyTheTargetActivates() async throws {
        let handBacks = try await handBackResult([watchState([], front: 1), watchState([2]), watchState([2])])
        XCTAssertEqual(handBacks, [1])
    }

    func testHandBackSkipsASwitchToAnotherAppDuringLaunch() async throws {
        let handBacks = try await handBackResult([watchState([3], front: 3), watchState([3, 2])])
        XCTAssertEqual(handBacks, [])
    }

    func testHandBackSkipsWhenNothingActivatesBeforeTheDeadline() async throws {
        let late = Array(repeating: watchState([], front: 1), count: 101) + [watchState([2])]
        let handBacks = try await handBackResult(late)
        XCTAssertEqual(handBacks, [])
    }

    func testHandBackSkipsWhenTheTargetWasAlreadyActive() async throws {
        let handBacks = try await handBackResult([watchState([2], targetWasActive: true)])
        XCTAssertEqual(handBacks, [])
    }

    func testHandBackSkipsWhenThePreviousAppTerminated() async throws {
        let handBacks = try await handBackResult([watchState([2], previousRunning: false)])
        XCTAssertEqual(handBacks, [])
    }

    func testHandBackDecisionAllowsTheBurstButNotAThirdApp() {
        var retake = watchState([2, 1, 2])
        retake.handBacks = 1
        XCTAssertEqual(Client.handBackDecision(retake), .handBack)
        var quiet = watchState([2, 1], front: 1)
        quiet.handBacks = 1
        quiet.sinceLastHandBack = .seconds(1)
        XCTAssertEqual(Client.handBackDecision(quiet), .wait)
        quiet.sinceLastHandBack = .milliseconds(1500)
        XCTAssertEqual(Client.handBackDecision(quiet), .done)
        var third = watchState([2, 1, 3], front: 3)
        third.handBacks = 1
        XCTAssertEqual(Client.handBackDecision(third), .cancel)
        var capped = watchState([2, 1, 2, 1, 2, 1, 2])
        capped.handBacks = 3
        XCTAssertEqual(Client.handBackDecision(capped), .done)
    }

    func testHandBackRepeatsWhenTheTargetRetakesTheFrontDuringALaunch() async throws {
        // A → ChatGPT → A → ChatGPT, then A stays in front.
        let handBacks = try await handBackResult([watchState([], front: 1), watchState([2]), watchState([2, 1], front: 1),
                                                  watchState([2, 1, 2]), watchState([2, 1, 2, 1], front: 1)])
        XCTAssertEqual(handBacks, [1, 1])
    }

    func testHandBackStopsForGoodWhenAThirdAppActivatesAfterAHandBack() async throws {
        // A → ChatGPT → A → B.
        let handBacks = try await handBackResult([watchState([2]), watchState([2, 1], front: 1), watchState([2, 1, 3], front: 3),
                                                  watchState([2, 1, 3, 2])])
        XCTAssertEqual(handBacks, [1])
    }

    func testHandBackIsCappedAtThreePerOpen() async throws {
        var states: [Client.FrontWatchState] = []
        var events: [Int32] = []
        for _ in 0..<6 {
            events.append(2); states.append(watchState(events))
            events.append(1); states.append(watchState(events, front: 1))
        }
        let handBacks = try await handBackResult(states)
        XCTAssertEqual(handBacks, [1, 1, 1])
    }

    func testHandBackEndsAfterTheQuietGapWithThePreviousAppInFront() async throws {
        let clock = AdvancingClock(), checks = Counter()
        try await Client.awaitHandBack(after: .seconds(5), clock: clock, state: {
            checks.next() == 0 ? self.watchState([2]) : self.watchState([2, 1], front: 1)
        }, handBack: { _, _ in })
        XCTAssertEqual(clock.sleeps.reduce(.zero, +), .milliseconds(1500))
    }

    private final class DriverCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [(tool: String, payload: [String: Any])] = []
        var all: [(tool: String, payload: [String: Any])] { lock.withLock { recorded } }
        func record(_ tool: String, _ payload: [String: Any]) { lock.withLock { recorded.append((tool, payload)) } }
    }

    private func handBackDriver(_ calls: DriverCalls) -> DesktopAppConversation {
        DesktopAppConversation(executable: URL(fileURLWithPath: "/fixture/cua-driver"), runProcess: { _, arguments, _, _, _ in
            let payload = try JSONSerialization.jsonObject(with: Data(arguments[2].utf8)) as? [String: Any] ?? [:]
            calls.record(arguments[1], payload)
            guard arguments[1] == "bring_to_front" else { return .init(status: 0, stdout: "{}") }
            return .init(status: 0, stdout: #"{"activated":true,"pid":42,"window_id":101,"exact_window_effect":{"verified":true}}"#)
        }, captureHostWindow: { .init(pid: 42, window: 101) })
    }

    func testHandBackToMsgblastBringsItsCapturedWindowToTheFront() async throws {
        let calls = DriverCalls()
        final class Fallbacks: @unchecked Sendable { var pids: [Int32] = [] }
        let fallbacks = Fallbacks()
        let host = DesktopHandBackHost(ownPID: 42, fallback: { pid, _ in fallbacks.pids.append(pid) })
        host.driver = handBackDriver(calls)
        try await host.whileOpening { await host.handBack(previousPID: 42) { true } }
        XCTAssertEqual(calls.all.map(\.tool), ["bring_to_front", "end_session"])
        XCTAssertEqual(calls.all.first?.payload["window_id"] as? Int, 101)
        XCTAssertEqual(calls.all.first?.payload["pid"] as? Int, 42)
        XCTAssertEqual(calls.all.first?.payload["session"] as? String, calls.all.last?.payload["session"] as? String)
        XCTAssertEqual(fallbacks.pids, [])
    }

    func testHandBackToAnotherAppDoesNotUseTheDriver() async throws {
        let calls = DriverCalls()
        final class Fallbacks: @unchecked Sendable { var pids: [Int32] = [] }
        let fallbacks = Fallbacks()
        let host = DesktopHandBackHost(ownPID: 42, fallback: { pid, _ in fallbacks.pids.append(pid) })
        host.driver = handBackDriver(calls)
        try await host.whileOpening { await host.handBack(previousPID: 7) { true } }
        XCTAssertTrue(calls.all.isEmpty)
        XCTAssertEqual(fallbacks.pids, [7])
    }

    func testHandBackHostIsClearedAfterTheOpenReturnsOrThrows() async throws {
        let host = DesktopHandBackHost(ownPID: 42, fallback: { _, _ in })
        host.driver = handBackDriver(DriverCalls())
        var seen: DesktopAppConversation.Target?
        try await host.whileOpening { seen = host.target }
        XCTAssertEqual(seen, .init(pid: 42, window: 101))
        XCTAssertNil(host.target)
        struct OpenFailed: Error {}
        do { try await host.whileOpening { throw OpenFailed() } } catch {}
        XCTAssertNil(host.target)
    }

    func testWindowScanStopsAtItsDeadlineWhenEachElementReadIsSlow() {
        let clock = AdvancingClock()
        let start = clock.now, budget = Duration.seconds(1), perRead = Duration.milliseconds(500)
        var reads = 0
        let found = Client.scanWindows(Array(repeating: 0, count: 10), until: start.advanced(by: budget), clock: clock) { _ in
            reads += 1
            clock.advance(by: perRead)
            return false
        }
        XCTAssertFalse(found)
        XCTAssertLessThanOrEqual(start.duration(to: clock.now), budget + perRead)
        XCTAssertEqual(reads, 2)
        XCTAssertFalse(Client.scanWindows([1], until: clock.now, clock: clock) { _ in true }, "No read once the deadline has passed")
        XCTAssertTrue(Client.scanWindows([0, 1], until: clock.now.advanced(by: budget), clock: clock) { $0 == 1 })
    }

    func testWindowPollPassesItsRemainingBudgetToEachRead() async throws {
        let clock = AdvancingClock()
        var budgets: [Duration] = []
        _ = try await Client.windowAppeared(within: .seconds(1), clock: clock) { budget in
            budgets.append(budget)
            clock.advance(by: .milliseconds(450))
            return false
        }
        XCTAssertEqual(budgets, [.seconds(1), .milliseconds(450)])
    }

    func testHandBackValidityNeedsTheTargetInFrontAndNoThirdApp() {
        XCTAssertTrue(Client.handBackStillValid(watchState([2])))
        XCTAssertFalse(Client.handBackStillValid(watchState([2, 3], front: 3)))
        XCTAssertFalse(Client.handBackStillValid(watchState([2, 3])))
        XCTAssertFalse(Client.handBackStillValid(watchState([2, 1], front: 1)))
        XCTAssertFalse(Client.handBackStillValid(watchState([2], previousRunning: false)))
    }

    /// Returns 0, 1, 2, ... on successive calls.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
    }

    /// The world the suspended hand-back sees: activations and the front app, changed by the test.
    private final class FrontWorld: @unchecked Sendable {
        private let lock = NSLock()
        private var activations: [Int32] = [2], front: Int32 = 2
        var fallbacks: [Int32] { lock.withLock { recordedFallbacks } }
        private var recordedFallbacks: [Int32] = []
        func activate(_ pid: Int32) { lock.withLock { activations.append(pid); front = pid } }
        func fellBack(_ pid: Int32) { lock.withLock { recordedFallbacks.append(pid) } }
        var state: Client.FrontWatchState {
            lock.withLock { .init(previousPID: 1, targetWasActive: false, activations: activations, frontmostPID: front, targetPID: 2, previousRunning: true) }
        }
    }

    /// Holds the driver's bring_to_front call until the test releases it.
    private actor DriverGate {
        private var entered = false, released: Bool?
        private var enteredWaiter: CheckedContinuation<Void, Never>?
        private var releaseWaiter: CheckedContinuation<Bool, Never>?
        func enter() async -> Bool {
            entered = true
            enteredWaiter?.resume(); enteredWaiter = nil
            if let released { return released }
            return await withCheckedContinuation { releaseWaiter = $0 }
        }
        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { enteredWaiter = $0 }
        }
        func release(succeeding: Bool) {
            released = succeeding
            releaseWaiter?.resume(returning: succeeding); releaseWaiter = nil
        }
    }

    /// Where the fake driver holds the hand-back: in the bring_to_front process, or in the
    /// connection the driver awaits before dispatching it.
    private enum DriverDelay { case dispatch, connection }

    private func suspendedHandBack(_ during: @escaping @Sendable (FrontWorld, AdvancingClock) -> Void, succeeding: Bool,
                                   delay: DriverDelay = .dispatch) async throws -> (calls: [String], world: FrontWorld) {
        let world = FrontWorld(), clock = AdvancingClock(), gate = DriverGate(), calls = DriverCalls(), connects = Counter()
        let driver = DesktopAppConversation(executable: URL(fileURLWithPath: "/fixture/cua-driver"), runProcess: { _, arguments, _, _, _ in
            calls.record(arguments[1], [:])
            guard arguments[1] == "bring_to_front" else { return .init(status: 0, stdout: "{}") }
            if delay == .dispatch { guard await gate.enter() else { return .init(status: 1, stdout: "") } }
            world.activate(1)
            return .init(status: 0, stdout: #"{"activated":true,"pid":42,"window_id":101,"exact_window_effect":{"verified":true}}"#)
        }, connect: {
            // The first connection is the warm-up before the open; the second is the hand-back's.
            if delay == .connection, connects.next() == 1 { _ = await gate.enter() }
            return nil
        }, captureHostWindow: { .init(pid: 42, window: 101) })
        let host = DesktopHandBackHost(ownPID: 1, fallback: { pid, _ in world.fellBack(pid) })
        host.driver = driver
        let watch = Task { @MainActor in
            try await host.whileOpening {
                try await Client.awaitHandBack(after: .seconds(5), clock: clock, state: { world.state }, handBack: { pid, stillValid in
                    await host.handBack(previousPID: pid, stillValid: stillValid)
                })
            }
        }
        await gate.waitUntilEntered()
        during(world, clock)
        await gate.release(succeeding: succeeding)
        try await watch.value
        return (calls.all.map(\.tool), world)
    }

    func testSwitchToAnotherAppDuringAFailedDriverHandBackSkipsTheFallback() async throws {
        let result = try await suspendedHandBack({ world, _ in world.activate(3) }, succeeding: false)
        XCTAssertEqual(result.calls, ["bring_to_front", "end_session"])
        XCTAssertEqual(result.world.fallbacks, [])
    }

    func testDeadlinePassingDuringAFailedDriverHandBackSkipsTheFallback() async throws {
        let result = try await suspendedHandBack({ _, clock in clock.advance(by: .seconds(6)) }, succeeding: false)
        XCTAssertEqual(result.calls, ["bring_to_front", "end_session"])
        XCTAssertEqual(result.world.fallbacks, [])
    }

    func testSuspendedDriverHandBackThatSucceedsHandsBackOnce() async throws {
        let result = try await suspendedHandBack({ _, _ in }, succeeding: true)
        XCTAssertEqual(result.calls, ["bring_to_front", "end_session"])
        XCTAssertEqual(result.world.fallbacks, [])
    }

    func testFailedDriverHandBackFallsBackWhileTheWatchIsStillValid() async throws {
        let result = try await suspendedHandBack({ _, _ in }, succeeding: false)
        XCTAssertEqual(result.calls, ["bring_to_front", "end_session"])
        XCTAssertEqual(result.world.fallbacks, [1])
    }

    func testSwitchToAnotherAppWhileTheDriverConnectsDispatchesNothing() async throws {
        let result = try await suspendedHandBack({ world, _ in world.activate(3) }, succeeding: true, delay: .connection)
        XCTAssertEqual(result.calls, ["end_session"])
        XCTAssertEqual(result.world.fallbacks, [])
    }

    func testDeadlinePassingWhileTheDriverConnectsDispatchesNothing() async throws {
        let result = try await suspendedHandBack({ _, clock in clock.advance(by: .seconds(6)) }, succeeding: true, delay: .connection)
        XCTAssertEqual(result.calls, ["end_session"])
        XCTAssertEqual(result.world.fallbacks, [])
    }

    func testDelayedDriverConnectionThatSucceedsDispatchesOnce() async throws {
        let result = try await suspendedHandBack({ _, _ in }, succeeding: true, delay: .connection)
        XCTAssertEqual(result.calls, ["bring_to_front", "end_session"])
        XCTAssertEqual(result.world.fallbacks, [])
    }

    private func handBackResult(_ states: [Client.FrontWatchState]) async throws -> [Int32] {
        final class Box: @unchecked Sendable { var pids: [Int32] = [] }
        let box = Box()
        let checks = Counter()
        try await Client.awaitHandBack(after: .seconds(5), clock: AdvancingClock(), state: {
            states[min(checks.next(), states.count - 1)]
        }, handBack: { pid, _ in box.pids.append(pid) })
        return box.pids
    }

    func testNativePreparationUsesProviderForegroundRequirementWhenAppIsClosedOrHidden() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for hidden in [false, true] {
            for provider in [WebProvider.chatgptApp, .dotsApp, .claudeApp] {
                let apps = Apps(), url = URL(fileURLWithPath: "/Fixture/\(provider.rawValue).app")
                apps.installation = .init(url: url, processID: hidden ? 42 : nil)
                apps.hidden = hidden
                apps.openAction = { _, _ in apps.installation = .init(url: url, processID: 42) }
                let session = WebAgentSession(provider: provider, storageURL: directory.appendingPathComponent(UUID().uuidString),
                                              fixture: true, museApp: .shared, desktopApps: apps.client)
                defer { session.beginShutdown() }
                session.setEnabled(true)
                let ready = await session.prepareDesktopConnection()
                XCTAssertTrue(ready, provider.name)
                XCTAssertEqual(apps.activations, [provider == .claudeApp], provider.name)
            }
        }
    }

    func testEveryNativeProviderLaunchesOnceFromAnExplicitConversationStart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for provider in WebProvider.desktopProviders {
            let apps = Apps(), url = URL(fileURLWithPath: "/Fixture/" + provider.rawValue + ".app")
            apps.installation = .init(url: url, processID: nil)
            apps.openAction = { _, _ in apps.installation = .init(url: url, processID: 42) }
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
        apps.openAction = { _, _ in apps.installation = .init(url: appURL, processID: 123) }
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
        XCTAssertNil(session.state.museAppConversations[comparison.uuidString]?.threadID, "Opening a comparison records intent; its native side chat is created only when sending")
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
        apps.openAction = { _, _ in try Data().write(to: directory.appendingPathComponent("opened")) }
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

    func testExplicitConnectReopensHiddenAppEvenWhenWindowServerListsItsMainWindow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try readOnlyMuseDriver(in: directory)
        let apps = Apps(), url = URL(fileURLWithPath: "/Fixture/Muse.app")
        apps.installation = .init(url: url, processID: 42)
        apps.hidden = true
        apps.openAction = { _, _ in apps.hidden = false }
        let session = WebAgentSession(provider: .museApp, storageURL: directory.appendingPathComponent("state.json"),
                                      fixture: false, museApp: .shared, desktopApps: apps.client,
                                      desktopDriver: DesktopAppConversation(executable: executable))
        defer { session.beginShutdown() }
        session.setEnabled(true)
        session.updateState { $0.draft = "Keep my prompt" }
        await session.refresh()
        XCTAssertTrue(apps.opened.isEmpty, "Passive refresh must leave a hidden app alone")
        let prepared = await session.prepareDesktopConnection()
        XCTAssertTrue(prepared)
        XCTAssertEqual(apps.opened, [url], "An existing WindowServer entry does not make a hidden app readable")
        XCTAssertFalse(apps.hidden)
        XCTAssertEqual(session.state.draft, "Keep my prompt")
        XCTAssertTrue(session.state.attempts.isEmpty)
        XCTAssertTrue(session.state.localConversations.isEmpty)
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
            apps.openAction = { _, _ in try Data().write(to: directory.appendingPathComponent("opened")) }
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
        apps.openAction = { _, _ in throw DesktopAppError.unavailable("Fixture launch refused") }
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
        apps.openAction = { _, _ in apps.installation = .init(url: appURL, processID: 123) }
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
        apps.openAction = { _, _ in
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
        apps.openAction = { _, _ in
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
        apps.openAction = { _, _ in
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
        apps.openAction = { _, _ in
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
