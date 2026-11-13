import XCTest
@testable import msgblastCore

final class SettingsNavigationTests: XCTestCase {
    func testBackAndForwardRetraceVisitedPages() {
        var history = PageHistory("general")
        XCTAssertFalse(history.canGoBack)
        history.go(to: "apps"); history.go(to: "updates")
        history.goBack()
        XCTAssertEqual(history.current, "apps")
        history.goBack()
        XCTAssertEqual(history.current, "general")
        XCTAssertFalse(history.canGoBack)
        history.goForward(); history.goForward()
        XCTAssertEqual(history.current, "updates")
        XCTAssertFalse(history.canGoForward)
    }

    func testVisitingANewPageClearsForwardAndSamePageIsIgnored() {
        var history = PageHistory("general")
        history.go(to: "apps"); history.goBack()
        history.go(to: "general")
        XCTAssertTrue(history.canGoForward)
        history.go(to: "remote")
        XCTAssertFalse(history.canGoForward)
        history.goBack()
        XCTAssertEqual(history.current, "general")
    }

    func testSavedAppearanceDefaultsToSystem() {
        let defaults = UserDefaults(suiteName: "msgblast.appearance.\(UUID().uuidString)")!
        XCTAssertEqual(AppAppearance.saved(in: defaults), .system)
        XCTAssertNil(AppAppearance.system.nsAppearance)
        defaults.set("dark", forKey: AppAppearance.defaultsKey)
        XCTAssertEqual(AppAppearance.saved(in: defaults), .dark)
        XCTAssertEqual(AppAppearance.dark.nsAppearance?.name, .darkAqua)
        defaults.set("bogus", forKey: AppAppearance.defaultsKey)
        XCTAssertEqual(AppAppearance.saved(in: defaults), .system)
    }
}
