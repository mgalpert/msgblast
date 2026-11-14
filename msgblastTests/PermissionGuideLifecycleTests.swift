import XCTest
import Combine

@MainActor
final class PermissionGuideLifecycleTests: XCTestCase {
    func testClosingSettingsPreservesPendingCompletionButBackAbandonsIt() throws {
        let suite = "msgblastPermissionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: MessagesAccessGuide.pendingKey)
        let guide = MessagesAccessGuide(defaults: defaults)
        guide.cancel(abandonRequest: false)
        XCTAssertTrue(defaults.bool(forKey: MessagesAccessGuide.pendingKey))
        guide.observeHistory(available: false)
        XCTAssertEqual(guide.flow.stage, .idle)
        guide.observeHistory(available: true)
        XCTAssertEqual(guide.flow.stage, .verified)
        guide.cancel()
        XCTAssertFalse(defaults.bool(forKey: MessagesAccessGuide.pendingKey))
        guide.observeHistory(available: true)
        XCTAssertEqual(guide.flow.stage, .idle)
    }
    func testRestartFinishesOnlyAfterHistoryReadSucceeds() throws {
        let suite = "msgblastPermissionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: MessagesAccessGuide.pendingKey)
        let guide = MessagesAccessGuide(defaults: defaults)
        guide.observeHistory(available: false)
        XCTAssertEqual(guide.flow.stage, .idle)
        guide.observeHistory(available: true)
        XCTAssertEqual(guide.flow.stage, .verified)
        var publications = 0
        let subscription = guide.objectWillChange.sink { publications += 1 }
        for _ in 0..<10 { guide.observeHistory(available: true) }
        XCTAssertEqual(publications, 0)
        withExtendedLifetime(subscription) {}
        guide.dismissCompletion()
        XCTAssertFalse(defaults.bool(forKey: MessagesAccessGuide.pendingKey))
        let restarted = MessagesAccessGuide(defaults: defaults)
        restarted.observeHistory(available: true)
        XCTAssertEqual(restarted.flow.stage, .idle)
    }

    func testOnlyGrantsThatAskToReturnBringMsgblastForward() throws {
        let suite = "msgblastPermissionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var raised = 0
        let guide = MessagesAccessGuide(defaults: defaults, pendingKey: "appAccessHandoffPending") { _ in raised += 1 }
        guide.checkHistory = { true }
        guide.start(permissionName: "Screen Recording")
        XCTAssertEqual(guide.flow.stage, .verified)
        XCTAssertEqual(raised, 0)
        guide.cancel()
        guide.start(permissionName: "Accessibility", returnOnGrant: true)
        XCTAssertEqual(guide.flow.stage, .verified)
        XCTAssertEqual(raised, 1)
        guide.observeHistory(available: true)
        XCTAssertEqual(raised, 1)
    }
}
