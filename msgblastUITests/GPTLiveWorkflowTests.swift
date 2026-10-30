import XCTest

final class GPTLiveWorkflowTests: XCTestCase {
    @MainActor
    func testReviewDraftAndSendOnlyAfterReviewInDemo() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        defer { app.terminate() }
        let launch = app.buttons["Open GPTLive"]
        XCTAssertTrue(launch.waitForExistence(timeout: 15))
        launch.click()
        XCTAssertTrue(app.staticTexts["Demo conversation"].waitForExistence(timeout: 5), "The toolbar icon starts the session")
        XCTAssertFalse(app.buttons["GPTLive connect"].exists, "Voice does not need a second Connect action")
        app.menuButtons["GPTLive options"].click()
        app.menuItems["Activity…"].click()
        let debug = app.checkBoxes["GPTLive debug mode"]
        XCTAssertTrue(debug.waitForExistence(timeout: 5))
        XCTAssertEqual(debug.value as? String, "0", "Debug mode starts off")
        debug.click()
        app.buttons["Done"].click()
        app.buttons["GPTLive keyboard"].click()
        let request = app.textFields["GPTLive request"]
        request.click()
        request.typeText("Draft a follow-up")
        app.buttons["GPTLive ask"].click()
        let editor = app.textViews["GPTLive reviewed draft"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue((editor.value as? String)?.contains("pilot") == true)
        XCTAssertTrue(app.staticTexts["Nothing is sent until you click Send."].exists)
        let send = app.buttons["GPTLive send draft"]
        XCTAssertTrue(send.isEnabled)
        send.click()
        let status = app.staticTexts["GPTLive status"]
        let submitted = NSPredicate(format: "label CONTAINS %@", "Submitted")
        expectation(for: submitted, evaluatedWith: status)
        waitForExpectations(timeout: 8)
        XCTAssertFalse(app.buttons["GPTLive send draft"].exists)
        app.buttons["GPTLive end"].click()
        XCTAssertFalse(app.windows["GPT-Live"].exists)
        launch.click()
        XCTAssertTrue(app.staticTexts["Demo conversation"].waitForExistence(timeout: 5))
    }
}
