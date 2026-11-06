import XCTest

final class GPTLiveWorkflowTests: XCTestCase {
    @MainActor
    func testVoiceSidebarStartsWithoutTextInputsAndKeepsDebugOptional() {
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
        XCTAssertFalse(app.buttons["GPTLive keyboard"].exists)
        XCTAssertFalse(app.textFields["GPTLive request"].exists)
        XCTAssertFalse(app.textViews["GPTLive reviewed draft"].exists)
        XCTAssertTrue(app.buttons["GPTLive microphone"].exists)
        XCTAssertFalse(app.buttons["GPTLive transcript toggle"].exists, "Only microphone and End belong in the main controls")
        app.typeKey("t", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.staticTexts["Your conversation will appear here."].waitForExistence(timeout: 5))
        app.buttons["Discover"].click()
        XCTAssertTrue(app.buttons["GPTLive end"].exists, "Voice stays available across the app")
        app.buttons["GPTLive end"].click()
        XCTAssertFalse(app.buttons["GPTLive end"].exists)
        XCTAssertFalse(app.windows["GPT-Live"].exists, "Voice is integrated in the workspace")
        launch.click()
        XCTAssertTrue(app.staticTexts["Demo conversation"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Your conversation will appear here."].exists, "Transcript choice survives reconnecting")
        app.typeKey("l", modifierFlags: [.command, .shift])
        XCTAssertFalse(app.buttons["GPTLive end"].exists)
        app.typeKey("l", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.staticTexts["Demo conversation"].waitForExistence(timeout: 5))
    }
}
