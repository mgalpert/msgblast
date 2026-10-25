import XCTest
@testable import msgblastCore

@MainActor
final class DesktopAppWorkflowTests: XCTestCase {
    private enum Failure: Error { case changed, refused }

    func testTextEntryPreservesBlankLinesAndUnicodeWithoutOverlappingChunks() async throws {
        let prompt = "\nA\n\n" + String(repeating: "🧑🏽‍💻", count: 270) + "\n"
        var draft = ""
        var checks = 0
        try await DesktopAppWorkflow.enterText(prompt, before: { step in
            XCTAssertEqual(draft, step.before)
        }, perform: { step in
            switch step.input {
            case .text(let text): XCTAssertLessThanOrEqual(text.count, 256); draft += text
            case .newline: draft += "\n"
            }
        }, after: { step in
            XCTAssertEqual(draft, step.after); checks += 1
        })
        XCTAssertEqual(draft, prompt)
        XCTAssertGreaterThan(checks, 4)
    }

    func testChangedDraftPreventsAnyInput() async {
        var inputs = 0
        do {
            try await DesktopAppWorkflow.enterText("Our prompt", before: { _ in throw Failure.changed }, perform: { _ in inputs += 1 }, after: { _ in })
            XCTFail("Expected refusal")
        } catch { XCTAssertTrue(error is Failure) }
        XCTAssertEqual(inputs, 0)
    }

    func testUnverifiedInputIsNeverReplayedOrFollowedByAnotherChunk() async {
        var inputs = 0
        do {
            try await DesktopAppWorkflow.enterText("First\nSecond", before: { _ in }, perform: { _ in inputs += 1 }, after: { _ in throw Failure.changed })
            XCTFail("Expected refusal")
        } catch { XCTAssertTrue(error is Failure) }
        XCTAssertEqual(inputs, 1)
    }

    func testUnsafeControlCharactersFailBeforeAnyInput() async {
        var inputs = 0
        do {
            try await DesktopAppWorkflow.enterText("A\tB", before: { _ in }, perform: { _ in inputs += 1 }, after: { _ in })
            XCTFail("Expected refusal")
        } catch { XCTAssertEqual(inputs, 0) }
    }

    func testNavigationWaitOnlyRepeatsObservations() async throws {
        var reads = 0
        let value = try await DesktopAppWorkflow.wait(timeout: .seconds(1), interval: .milliseconds(1), failure: "Not ready", clock: AdvancingClock(), read: {
            reads += 1
            if reads == 1 { throw DesktopAccessibilityError.incomplete }
            return reads
        }, ready: { $0 == 3 })
        XCTAssertEqual(value, 3)
        XCTAssertEqual(reads, 3)
    }

    func testCustomReadRecoveryStopsAtItsDeadlineAndPropagatesCancellation() async {
        for cancelled in [false, true] {
            var reads = 0
            let clock = AdvancingClock()
            let started = clock.now
            do {
                let _: Bool = try await DesktopAppWorkflow.wait(timeout: .milliseconds(25), interval: .milliseconds(5),
                    failure: "Not ready", retry: { !($0 is CancellationError) }, clock: clock, read: {
                        reads += 1
                        if cancelled { throw CancellationError() }
                        throw Failure.changed
                    }, ready: { $0 })
                XCTFail("Unreadable state must never become ready")
            } catch {
                if cancelled {
                    XCTAssertTrue(error is CancellationError)
                    XCTAssertEqual(reads, 1)
                    XCTAssertEqual(clock.now - started, .zero)
                    XCTAssertTrue(clock.sleeps.isEmpty)
                } else {
                    XCTAssertTrue(error is Failure, "Keep the last native failure at the deadline")
                    XCTAssertEqual(reads, 5)
                    XCTAssertEqual(clock.now - started, .milliseconds(25))
                    XCTAssertEqual(clock.sleeps, Array(repeating: .milliseconds(5), count: 5))
                }
            }
        }
    }

    func testReadRecoveryRejectsLateSuccessAndDoesNotStartAnotherReadAfterExpiry() async {
        for lateFirstResult in [false, true] {
            var reads = 0
            let clock = AdvancingClock(oversleep: .seconds(2))
            do {
                let _: Bool = try await DesktopAppWorkflow.wait(timeout: .milliseconds(100), interval: .milliseconds(300),
                    failure: "Recovery deadline", retry: { _ in true }, clock: clock, read: {
                        reads += 1
                        if lateFirstResult { clock.advance(by: .milliseconds(300)) }
                        else if reads == 1 { throw Failure.changed }
                        return true
                    }, ready: { $0 })
                XCTFail("Expired observation cannot authorize readiness")
            } catch {
                if lateFirstResult { XCTAssertEqual(error.localizedDescription, "Recovery deadline") }
                else { XCTAssertTrue(error is Failure, "Retain the native failure instead of reading past expiry") }
            }
            XCTAssertEqual(reads, 1, "An expired recovery window must not start another native read")
            XCTAssertEqual(clock.sleeps, lateFirstResult ? [] : [.milliseconds(100)], "Sleep must be capped to the remaining budget, even when the wake-up is late")
        }
    }

    func testReplyReadRecoveryDoesNotSubmitAgain() async throws {
        var submissions = 0, reads = 0
        let answer = try await DesktopAppWorkflow.reply(app: "Fixture", timing: .init(pollInterval: .milliseconds(1), stableDuration: .zero, replyTimeout: .seconds(1)), clock: AdvancingClock(), submit: {
            submissions += 1
        }, observe: {
            reads += 1
            if reads == 1 { throw DesktopAccessibilityError.incomplete }
            return reads == 2 ? nil : "Observed reply"
        })
        XCTAssertEqual(answer, "Observed reply")
        XCTAssertEqual(submissions, 1)
        XCTAssertEqual(reads, 3)
    }

    func testUncertainSubmitNeverObservesOrRetries() async {
        var submissions = 0, reads = 0
        do {
            _ = try await DesktopAppWorkflow.reply(app: "Fixture", timing: .init(), submit: {
                submissions += 1; throw Failure.refused
            }, observe: { reads += 1; return "Reply" })
            XCTFail("Expected refusal")
        } catch { XCTAssertTrue(error is Failure) }
        XCTAssertEqual(submissions, 1)
        XCTAssertEqual(reads, 0)
    }
}

extension DesktopAppWorkflowTests {
    func testTransientReadResetsNonzeroReplyStabilityWithoutResubmitting() async throws {
        for completed in ["Early answer", "Completed answer"] {
            let clock = AdvancingClock()
            let started = clock.now
            var submissions = 0, reads = 0
            let answer = try await DesktopAppWorkflow.reply(app: "Fixture", timing: .init(pollInterval: .milliseconds(15), stableDuration: .milliseconds(90), replyTimeout: .seconds(2)), clock: clock, submit: {
                submissions += 1
            }, observe: {
                reads += 1
                if reads <= 2 { return "Early answer" }
                if reads == 3 { throw DesktopAccessibilityError.incomplete }
                return completed
            })
            XCTAssertEqual(answer, completed)
            XCTAssertEqual(submissions, 1)
            // The first valid read after the error is at 60 ms. Even unchanged
            // text needs a fresh 90 ms stability window, ending at 150 ms.
            XCTAssertEqual(clock.now - started, .milliseconds(150))
            XCTAssertGreaterThan(reads, 4)
        }
    }
}

// Sleeps advance virtual time immediately; runner scheduling never advances it.
private final class AdvancingClock: Clock, @unchecked Sendable {
    typealias Instant = ContinuousClock.Instant
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    private var recordedSleeps: [Duration] = []
    private let oversleep: Duration

    init(oversleep: Duration = .zero) { self.oversleep = oversleep }
    var now: Instant { lock.withLock { instant } }
    var minimumResolution: Duration { .nanoseconds(1) }
    var sleeps: [Duration] { lock.withLock { recordedSleeps } }
    func advance(by duration: Duration) { lock.withLock { instant = instant.advanced(by: duration) } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        lock.withLock {
            guard deadline > instant else { return }
            recordedSleeps.append(instant.duration(to: deadline))
            instant = deadline.advanced(by: oversleep)
        }
        try Task.checkCancellation()
    }
}
