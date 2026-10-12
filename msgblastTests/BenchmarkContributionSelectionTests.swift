import XCTest
@testable import msgblastCore

final class BenchmarkContributionSelectionTests: XCTestCase {
    func testNewSnapshotRetryAndWithdrawalUseVerifiedLineageHistory() throws {
        let initial = try BenchmarkContributionSelection.revision(sessionID: "session", snapshotID: "head-one", history: [])
        XCTAssertEqual(initial, 1)
        let one = BenchmarkContributionHistoryEntry(session: "session", revision: 1, snapshotID: "head-one", status: "accepted")
        XCTAssertEqual(try BenchmarkContributionSelection.revision(sessionID: "session", snapshotID: "head-one", history: [one]), 1)
        XCTAssertEqual(try BenchmarkContributionSelection.revision(sessionID: "session", snapshotID: "head-two", history: [one]), 2)
        let two = BenchmarkContributionHistoryEntry(session: "session", revision: 2, snapshotID: "head-two", status: "pending")
        XCTAssertEqual(try BenchmarkContributionSelection.revision(sessionID: "session", snapshotID: "head-two", history: [one, two]), 2)
        let withdrawn = BenchmarkContributionHistoryEntry(session: "session", revision: 2, snapshotID: "head-two", status: "withdrawn")
        XCTAssertEqual(try BenchmarkContributionSelection.revision(sessionID: "session", snapshotID: "head-two", history: [withdrawn]), 3)
        XCTAssertEqual(try BenchmarkContributionSelection.revision(sessionID: "different-session", snapshotID: "head-two", history: [withdrawn]), 1)
    }
    func testMalformedOrExhaustedHistoryCannotGenerateInvalidRevision() throws {
        let malformed = BenchmarkContributionHistoryEntry(session: "s", revision: Int.max, snapshotID: "one", status: "accepted")
        XCTAssertThrowsError(try BenchmarkContributionSelection.revision(sessionID: "s", snapshotID: "two", history: [malformed]))
        let exhausted = BenchmarkContributionHistoryEntry(session: "s", revision: 10000, snapshotID: "one", status: "accepted")
        XCTAssertEqual(try BenchmarkContributionSelection.revision(sessionID: "s", snapshotID: "one", history: [exhausted]), 10000)
        XCTAssertThrowsError(try BenchmarkContributionSelection.revision(sessionID: "s", snapshotID: "two", history: [exhausted]))
    }
}
