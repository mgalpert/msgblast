import XCTest

final class CrashReportWorkflowTests: XCTestCase {
    @MainActor
    func testCrashOfferRequiresReviewAndExplicitSendAndCanBeReopenedFromHelp() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo", "--crash-report-preview"]
        app.launch()
        defer { app.terminate() }
        let review = app.buttons["Review report"]
        XCTAssertTrue(review.waitForExistence(timeout: 15))
        review.click()
        let window = app.windows["Review Crash Report"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertTrue(window.buttons["Send crash report"].isEnabled)
        XCTAssertFalse(window.staticTexts["Crash submission status"].exists, "Opening the review must not submit")
        window.buttons["Dismiss"].click()
        XCTAssertTrue(window.staticTexts["Dismissed. You can review this report later from Help."].exists)
        window.buttons[XCUIIdentifierCloseWindow].click()
        app.menuBars.menuBarItems["Help"].click()
        app.menuItems["Review Crash Reports…"].click()
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertTrue(window.buttons["Send crash report"].isEnabled)
    }
}
