import XCTest

final class PerformanceWorkflowTests: XCTestCase {
    @MainActor func testLocalSettingsRecordingFeedbackAndFavorites() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        defer { app.terminate() }
        app.typeKey(",", modifierFlags: .command)
        let statsTab = app.buttons["My Stats"]
        XCTAssertTrue(statsTab.waitForExistence(timeout: 5))
        statsTab.click()
        let tracking = app.checkBoxes["performance-tracking"]
        XCTAssertTrue(tracking.waitForExistence(timeout: 5))
        XCTAssertEqual(tracking.value as? String, "0")
        XCTAssertTrue(app.staticTexts["stats-counts"].label.contains("0 recorded comparisons"))
        tracking.click()
        XCTAssertEqual(tracking.value as? String, "1")
        app.buttons["Benchmarks"].click()
        XCTAssertTrue(app.staticTexts["Local only · account not connected"].waitForExistence(timeout: 5))
        app.buttons["General"].click()
        XCTAssertTrue(app.descendants(matching: .any)["Permissions"].exists)
        app.windows["com_apple_SwiftUI_Settings_window"].buttons[XCUIIdentifierCloseWindow].click()
        let prompt = app.textViews["Shared prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        prompt.click(); prompt.typeKey("a", modifierFlags: .command); prompt.typeText("Synthetic performance UI fixture")
        app.buttons["Send & compare"].click()
        let favorite = app.buttons.matching(NSPredicate(format: "label == %@", "Favorite reply")).firstMatch
        XCTAssertTrue(favorite.waitForExistence(timeout: 10))
        favorite.click()
        let negative = app.buttons.matching(NSPredicate(format: "label == %@", "Thumbs down reply")).firstMatch
        negative.click()
        XCTAssertFalse(app.buttons["Clear favorite"].exists)
        XCTAssertTrue(app.buttons["Clear thumbs down"].exists)
        app.buttons["Clear thumbs down"].click()
        app.buttons["Favorite reply"].firstMatch.click()
        app.typeKey(",", modifierFlags: .command)
        statsTab.click()
        XCTAssertTrue(app.staticTexts["stats-counts"].label.contains("1 recorded comparison"))
        let saved = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Open recorded favorite from")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        saved.click()
        XCTAssertTrue(app.staticTexts["Saved local comparison · opens without contacting a provider"].waitForExistence(timeout: 5))
        app.buttons["Done"].click()
        tracking.click()
        XCTAssertEqual(tracking.value as? String, "0")
        XCTAssertTrue(app.staticTexts["Tracking is off. Existing records are retained; no historical activity is estimated."].exists)
    }
}
