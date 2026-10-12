import XCTest
@testable import msgblastCore

@MainActor
final class OutgoingDeliveryTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    private var payload: OutgoingPayload {
        OutgoingPayload(text: "Read the report", attachments: [
            MessageAttachment(id: "draft-file", filename: "report.pdf", path: "/fixture/report.pdf", byteCount: 100)
        ])
    }

    private enum FixtureError: LocalizedError {
        case storage
        var errorDescription: String? { "Fixture disk unavailable" }
    }

    /// Uses encoded snapshots so recovery assertions inspect the last successful
    /// durable write, rather than only the value returned by the delivery loop.
    @MainActor private final class Harness {
        var records: [Message] = []
        var sends: [OutgoingPart] = []
        var saved: Data?
        var writes = 0
        var waits = 0
        var reportedErrors = 0
        var observedHistories = 0
        var historyReads = 0
        var failingHistoryReads = Set<Int>()
        var excluded = Set<String>()
        var validationError: Error?
        var sendError: Error?
        var waitError: Error?
        var failingWrites = Set<Int>()
        var onWait: (() -> Void)?
        var onSend: ((OutgoingPart) -> Void)?
        let date: Date

        init(date: Date) { self.date = date }

        func run(_ payload: OutgoingPayload) async -> OutgoingPayload {
            await OutgoingDelivery.deliver(payload,
                history: {
                    self.historyReads += 1
                    if self.failingHistoryReads.contains(self.historyReads) { throw FixtureError.storage }
                    return self.records
                },
                claimedAnchors: { _ in self.excluded },
                validate: { _ in if let error = self.validationError { throw error } },
                persist: {
                    self.writes += 1
                    if self.failingWrites.contains(self.writes) { throw FixtureError.storage }
                    self.saved = try JSONEncoder().encode($0)
                },
                submit: {
                    self.sends.append($0)
                    self.onSend?($0)
                    if let error = self.sendError { throw error }
                },
                didReadHistory: { _ in self.observedHistories += 1 },
                reportError: { _ in self.reportedErrors += 1 },
                now: { self.date },
                waitForReceipt: {
                    self.waits += 1
                    self.onWait?()
                    if let error = self.waitError { throw error }
                })
        }

        func restored() throws -> OutgoingPayload {
            try JSONDecoder().decode(OutgoingPayload.self, from: XCTUnwrap(saved)).recoveringInFlight()
        }
    }

    private func receipt(_ id: Int64, text: String = "Read the report", attachments: [MessageAttachment] = []) -> Message {
        Message(id: id, guid: "receipt-\(id)", chatID: "fixture-chat", text: text,
                outgoing: true, date: date, attachments: attachments, delivery: .unknown)
    }

    func testPermissionDeniedBeforeSubmissionRetainsUnsentParts() async throws {
        let harness = Harness(date: date)
        harness.validationError = SendFailure.notSubmitted("Fixture automation permission denied")
        let result = await harness.run(payload)
        XCTAssertTrue(harness.sends.isEmpty)
        XCTAssertEqual(result.parts.map(\.state), [.failed, .ready])
        XCTAssertNil(result.parts[0].attemptedAt)
        XCTAssertEqual(try harness.restored().pendingIndices, [0, 1])
        XCTAssertEqual(try harness.restored().parts[1].attachment, payload.parts[1].attachment)
    }

    func testDefinitiveTransportPermissionDenialCanRetryOnlyUnsentParts() async throws {
        let harness = Harness(date: date)
        harness.sendError = SendFailure.notSubmitted("Fixture Messages automation denied")
        let original = payload
        let denied = await harness.run(original)
        XCTAssertEqual(denied.parts.map(\.state), [.failed, .ready])
        XCTAssertEqual(harness.sends.count, 1)
        XCTAssertEqual(try harness.restored().pendingIndices, [0, 1])
        harness.sendError = nil
        let textReceipt = receipt(1)
        let fileReceipt = receipt(2, text: "", attachments: [try XCTUnwrap(original.parts[1].attachment)])
        harness.onSend = { part in
            harness.records = part.attachment == nil ? [textReceipt] : [textReceipt, fileReceipt]
        }
        let retried = await harness.run(try harness.restored())
        XCTAssertEqual(retried.parts.map(\.state), [.submitted, .submitted])
        XCTAssertEqual(harness.sends.map(\.id), [original.parts[0].id, original.parts[0].id, original.parts[1].id])
        _ = await harness.run(try harness.restored())
        XCTAssertEqual(harness.sends.count, 3, "A completed payload cannot submit either part again")
    }

    func testTimeoutAfterTransportAcceptanceIsQuarantinedAcrossRestartAndRetry() async throws {
        let harness = Harness(date: date)
        harness.sendError = SendFailure.ambiguous("Fixture Apple Event timed out after acceptance")
        let result = await harness.run(payload)
        XCTAssertEqual(harness.sends.count, 1)
        XCTAssertEqual(result.parts.map(\.state), [.uncertain, .ready])
        XCTAssertEqual(result.parts[0].baseline, 0)
        XCTAssertEqual(result.parts[0].attemptedAt, date)
        let restored = try harness.restored()
        XCTAssertEqual(restored.parts[0].state, .uncertain)
        _ = await harness.run(restored)
        XCTAssertEqual(harness.sends.count, 1, "Neither the ambiguous part nor later parts may be sent on retry")
    }

    func testMissingReceiptBlocksNextPartAndNeverRepeatsAcceptedPart() async throws {
        let harness = Harness(date: date)
        let result = await harness.run(payload)
        XCTAssertEqual(result.parts.map(\.state), [.submitted, .ready])
        XCTAssertNil(result.parts[0].anchor)
        XCTAssertEqual(harness.sends.count, 1)
        XCTAssertEqual(harness.waits, 6)
        XCTAssertEqual(harness.observedHistories, 6)
        _ = await harness.run(try harness.restored())
        XCTAssertEqual(harness.sends.count, 1)
        XCTAssertEqual(harness.waits, 6, "A retry with no receipt must stop before submitting the next part")
    }

    func testDelayedReceiptAllowsNextPartOnlyAfterReconciliation() async throws {
        let harness = Harness(date: date)
        let original = payload
        let textReceipt = receipt(1)
        let fileReceipt = receipt(2, text: "", attachments: [try XCTUnwrap(original.parts[1].attachment)])
        harness.onWait = {
            if harness.waits == 2 { harness.records = [textReceipt] }
        }
        harness.onSend = { part in
            if part.attachment != nil {
                XCTAssertEqual(harness.waits, 2, "The attachment must wait for the text receipt")
                harness.records = [textReceipt, fileReceipt]
            }
        }
        let result = await harness.run(original)
        XCTAssertEqual(harness.sends.map(\.id), original.parts.map(\.id))
        XCTAssertEqual(result.parts.map(\.state), [.submitted, .submitted])
        XCTAssertEqual(result.parts.map(\.anchor?.guid), ["receipt-1", "receipt-2"])
        XCTAssertEqual(try harness.restored().parts.map(\.anchor?.rowID), [1, 2])
        XCTAssertEqual(fileReceipt.delivery, .unknown, "A history receipt does not assert delivery")
    }

    func testReceiptClaimedByAnotherAttemptCannotReleaseNextPart() async {
        let harness = Harness(date: date)
        let claimed = receipt(1)
        harness.excluded = [claimed.guid]
        harness.onSend = { _ in harness.records = [claimed] }
        let result = await harness.run(payload)
        XCTAssertEqual(harness.sends.count, 1)
        XCTAssertNil(result.parts[0].anchor)
        XCTAssertEqual(result.parts[1].state, .ready)
    }

    func testPersistenceFailureBeforeSendMakesNoTransportCall() async throws {
        // Cover both initial reconciliation write and durable attempt write.
        for failingWrite in [1, 2] {
            let harness = Harness(date: date)
            harness.failingWrites = [failingWrite]
            let result = await harness.run(payload)
            XCTAssertTrue(harness.sends.isEmpty)
            XCTAssertEqual(result.parts[1].state, .ready)
            if failingWrite == 1 {
                XCTAssertNil(harness.saved)
                XCTAssertEqual(result.parts[0].state, .ready)
                XCTAssertEqual(harness.reportedErrors, 1)
            } else {
                XCTAssertEqual(try harness.restored().pendingIndices, [0, 1])
                XCTAssertEqual(try harness.restored().parts[0].state, .failed)
            }
        }
    }

    func testPersistenceFailureAfterSendQuarantinesAcceptedAttemptWithoutRetry() async throws {
        let harness = Harness(date: date)
        harness.failingWrites = [3] // Initial state, sending, then accepted submission.
        let result = await harness.run(payload)
        XCTAssertEqual(harness.sends.count, 1)
        XCTAssertEqual(result.parts.map(\.state), [.uncertain, .ready])
        XCTAssertEqual(try harness.restored().parts.map(\.state), [.uncertain, .ready])
        _ = await harness.run(try harness.restored())
        XCTAssertEqual(harness.sends.count, 1)
    }
    func testFailureSavingQuarantineLeavesDurableInFlightAttemptSafeOnRecovery() async throws {
        let harness = Harness(date: date)
        harness.failingWrites = [3, 4] // Both acceptance and quarantine writes fail.
        let result = await harness.run(payload)
        XCTAssertEqual(harness.sends.count, 1)
        XCTAssertEqual(result.parts[0].state, .uncertain)
        let saved = try JSONDecoder().decode(OutgoingPayload.self, from: XCTUnwrap(harness.saved))
        XCTAssertEqual(saved.parts[0].state, .sending)
        XCTAssertEqual(harness.reportedErrors, 1)
        let recovered = saved.recoveringInFlight()
        XCTAssertEqual(recovered.parts[0].state, .uncertain)
        _ = await harness.run(recovered)
        XCTAssertEqual(harness.sends.count, 1)
    }

    func testHistoryReadFailureAfterAcceptanceQuarantinesTheAttemptAcrossRetry() async throws {
        let harness = Harness(date: date)
        // Initial reconciliation and baseline succeed; polling fails after acceptance.
        harness.failingHistoryReads = [3]
        let result = await harness.run(payload)
        XCTAssertEqual(harness.sends.count, 1)
        XCTAssertEqual(result.parts.map(\.state), [.uncertain, .ready])
        XCTAssertEqual(try harness.restored().parts.map(\.state), [.uncertain, .ready])
        _ = await harness.run(try harness.restored())
        XCTAssertEqual(harness.sends.count, 1, "Unavailable history cannot authorize another send")
    }

    func testInitialHistoryReadFailurePreservesTheDurableDraftWithoutSubmission() async throws {
        let harness = Harness(date: date)
        let original = payload
        let savedDraft = try JSONEncoder().encode(original)
        harness.saved = savedDraft
        harness.failingHistoryReads = [1]
        let result = await harness.run(original)
        XCTAssertTrue(harness.sends.isEmpty)
        XCTAssertEqual(result.parts.map(\.id), original.parts.map(\.id))
        XCTAssertEqual(result.parts.map(\.state), [.ready, .ready])
        XCTAssertEqual(result.parts[1].attachment, original.parts[1].attachment)
        XCTAssertEqual(try XCTUnwrap(harness.saved), savedDraft, "Unreadable history must not replace the persisted draft")
        XCTAssertEqual(harness.reportedErrors, 1)
    }

    func testCanceledReceiptWaitDurablyQuarantinesAcceptanceAndPreventsDuplicateSubmission() async throws {
        let harness = Harness(date: date)
        let original = payload
        harness.waitError = CancellationError()
        let result = await harness.run(original)
        XCTAssertEqual(harness.sends.map(\.id), [original.parts[0].id])
        XCTAssertEqual(result.parts.map(\.state), [.uncertain, .ready])
        XCTAssertNil(result.parts[0].anchor)
        XCTAssertEqual(result.parts[0].attemptedAt, date)
        let restored = try harness.restored()
        XCTAssertEqual(restored.parts.map(\.state), [.uncertain, .ready])
        XCTAssertEqual(restored.parts[1].attachment, original.parts[1].attachment)
        _ = await harness.run(restored)
        XCTAssertEqual(harness.sends.map(\.id), [original.parts[0].id], "Cancellation cannot authorize repeating an accepted part or sending the next part")
    }
}
