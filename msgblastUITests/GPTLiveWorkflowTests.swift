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
        let sample = app.buttons["GPTLive create sample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 5))
        sample.click()
        let connect = app.buttons["GPTLive connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        XCTAssertTrue(connect.isEnabled)
        connect.click()
        app.buttons["GPTLive debug"].click()
        let debug = app.checkBoxes["GPTLive debug mode"]
        XCTAssertTrue(debug.waitForExistence(timeout: 5))
        debug.click()
        app.buttons["Done"].click()
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
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["GPTLive microphone"].isEnabled)
    }
}
