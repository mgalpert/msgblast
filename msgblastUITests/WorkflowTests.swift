import XCTest
import AppKit
final class WorkflowTests: XCTestCase {
    @MainActor
    func testSettingsCanEnableContactsWhileMessagesAccessIsOff() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo", "--permission-guide-preview", "--contacts-access-preview"]
        app.launch()
        defer { app.terminate() }
        app.typeKey(",", modifierFlags: .command)
        let history = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Messages access")).firstMatch
        guard history.waitForExistence(timeout: 5) else { return XCTFail("Settings must show the permissions table") }
        XCTAssertTrue(history.label.contains("Not connected"))
        let contacts = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Contacts")).firstMatch
        XCTAssertTrue(contacts.label.contains("Not requested"))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Sending Messages")).firstMatch.label.contains("Allowed"))
        XCTAssertTrue(app.staticTexts["Demo permissions are simulated. No system access is changed."].exists)
        let before = XCTAttachment(screenshot: app.windows["com_apple_SwiftUI_Settings_window"].screenshot())
        before.name = "Permissions — simulated Contacts not requested"
        before.lifetime = .keepAlways
        add(before)
        app.buttons["enable-contacts-permission"].click()
        let allowed = NSPredicate(format: "label CONTAINS %@", "Allowed")
        expectation(for: allowed, evaluatedWith: contacts)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(history.label.contains("Not connected"), "Contacts must be manageable independently of Messages access")
        XCTAssertEqual(app.sheets.count, 0, "The fixture must never ask for real system access")
        let screenshot = XCTAttachment(screenshot: app.windows["com_apple_SwiftUI_Settings_window"].screenshot())
        screenshot.name = "Permissions — simulated Contacts enabled independently"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testShareFeedbackMenuIsAvailableAnytime() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        defer { app.terminate() }
        app.menuBars.menuBarItems["Help"].click()
        let feedback = app.menuBars.menuBarItems["Help"].menuItems["Share Feedback…"]
        XCTAssertTrue(feedback.waitForExistence(timeout: 5))
        feedback.hover()
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "share-feedback-menu"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testStandardShortcutsNavigateAndStartBlastWithoutLosingDraft() {
        let app = launchFixture(separateWindows: false)
        defer { app.terminate() }
        let editor = app.textViews["Shared prompt"]
        editor.click(); editor.typeKey("a", modifierFlags: .command)
        editor.typeText("Saved keyboard shortcut draft")
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.textFields["Search Discover"].waitForExistence(timeout: 5))
        app.typeKey("f", modifierFlags: .command)
        app.typeText("nonexistent keyboard fixture")
        XCTAssertEqual(app.textFields["Search Discover"].value as? String, "nonexistent keyboard fixture")
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "Saved keyboard shortcut draft")
        app.typeText(" preserved")
        XCTAssertEqual(editor.value as? String, "Saved keyboard shortcut draft preserved")
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.textFields["Search Discover"].waitForExistence(timeout: 5))
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "Saved keyboard shortcut draft preserved")
    }

    @MainActor
    func testPersonalAgentOpensComparisonReportWithBestNextAction() {
        let app = launchFixture(separateWindows: false)
        defer { app.terminate() }
        let prompt = "Personal agent comparison fixture"
        let editor = app.textViews["Shared prompt"]
        editor.click(); editor.typeKey("a", modifierFlags: .command); editor.typeText(prompt)
        app.buttons["Send & compare"].click()
        let workspace = app.windows["\(prompt) [Demo]"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        let summarize = workspace.toolbars.buttons["Summarize"]
        guard summarize.waitForExistence(timeout: 5) else { return XCTFail("Summarize must be in the window toolbar") }
        XCTAssertGreaterThan(summarize.frame.midX, workspace.frame.midX)
        XCTAssertLessThan(summarize.frame.minY, workspace.frame.minY + 100)
        XCTAssertTrue(workspace.staticTexts.matching(identifier: "Recipient reacted ✅").element(boundBy: 2).waitForExistence(timeout: 10))
        let before = XCTAttachment(screenshot: workspace.screenshot())
        before.name = "Summarize toolbar — synthetic comparison"
        before.lifetime = .keepAlways; add(before)
        summarize.click()
        let report = app.windows["Comparison report · \(prompt) [Demo]"]
        XCTAssertTrue(report.waitForExistence(timeout: 5))
        XCTAssertFalse(report.staticTexts["Your local accounts (simulated)"].exists)
        XCTAssertFalse(report.buttons["Sign in with ChatGPT"].exists)
        XCTAssertFalse(report.buttons["Sign in with Claude"].exists)
        XCTAssertEqual(app.sheets.count, 0, "The report must be a separate window")
        XCTAssertTrue(workspace.exists)
        let action = report.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Choose one representative example", "Choose one representative example")).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 10), "One toolbar click must generate the report")
        XCTAssertTrue((action.label + (action.value as? String ?? "")).contains("representative example"))
        XCTAssertTrue(report.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Cedar emphasizes clarity", "Cedar emphasizes clarity")).firstMatch.exists)
        XCTAssertTrue(report.staticTexts["Demo analyst (simulated) · 3 of 3 participants · 6 responses"].exists)
        let after = XCTAttachment(screenshot: report.screenshot())
        after.name = "Comparison report — best next action — simulated output"
        after.lifetime = .keepAlways; add(after)
        // Keep the report open while continuing the source conversation.
        let input = workspace.textViews["Universal message"]
        input.click(); input.typeText("Compare the tradeoffs too")
        workspace.buttons["Send to Cedar, Lumen, Orbit"].click()
        let stale = report.staticTexts["Conversation changed · update the report to include the latest replies."]
        XCTAssertTrue(stale.waitForExistence(timeout: 5))
        XCTAssertTrue(workspace.staticTexts.matching(identifier: "Recipient reacted ✅").element(boundBy: 5).waitForExistence(timeout: 10))
        workspace.toolbars.buttons["Summarize"].click()
        XCTAssertEqual(app.windows.matching(identifier: "Comparison report · \(prompt) [Demo]").count, 1)
        XCTAssertTrue(report.staticTexts["Demo analyst (simulated) · 3 of 3 participants · 12 responses"].waitForExistence(timeout: 10))
        XCTAssertFalse(stale.exists)
        XCTAssertTrue(action.waitForExistence(timeout: 10))
        report.buttons[XCUIIdentifierCloseWindow].click()
        workspace.toolbars.buttons["Summarize"].click()
        XCTAssertTrue(report.waitForExistence(timeout: 5))
        XCTAssertTrue(action.waitForExistence(timeout: 10))
    }

    @MainActor
    func testSeparateConversationWindowsShareOneComparisonReport() {
        let app = launchFixture(separateWindows: true)
        defer { app.terminate() }
        let prompt = "Separate report fixture"
        let editor = app.textViews["Shared prompt"]
        editor.click(); editor.typeKey("a", modifierFlags: .command); editor.typeText(prompt)
        app.buttons["Send & compare"].click()
        let cedar = app.windows["Cedar · \(prompt)"]
        XCTAssertTrue(cedar.waitForExistence(timeout: 10))
        XCTAssertTrue(cedar.staticTexts["Recipient reacted ✅"].firstMatch.waitForExistence(timeout: 10))
        cedar.toolbars.buttons["Summarize"].click()
        let report = app.windows["Comparison report · \(prompt) [Demo]"]
        XCTAssertTrue(report.waitForExistence(timeout: 5))
        XCTAssertTrue(report.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Choose one representative example", "Choose one representative example")).firstMatch.waitForExistence(timeout: 10))
        app.windows["Lumen · \(prompt)"].toolbars.buttons["Summarize"].click()
        XCTAssertEqual(app.windows.matching(identifier: "Comparison report · \(prompt) [Demo]").count, 1)
        XCTAssertEqual(app.sheets.count, 0)
    }

    @MainActor
    func testApplicationMenuProvidesStandardActions() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        defer { app.terminate() }
        let applicationMenu = app.menuBars.menuBarItems["msgblast"]
        applicationMenu.click()
        for title in ["About msgblast", "Check for Updates…", "Settings…", "Hide msgblast", "Quit msgblast"] {
            XCTAssertTrue(app.menuItems[title].exists, "Missing application menu action: \(title)")
        }
        let menu = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        menu.name = "msgblast application menu — isolated demo"
        menu.lifetime = .keepAlways
        add(menu)
        guard app.menuItems["Check for Updates…"].exists else { return }
        app.menuItems["Check for Updates…"].click()
        XCTAssertTrue(app.dialogs.staticTexts["Updates unavailable"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.dialogs.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "Version ")).firstMatch.exists)
    }
    @MainActor
    func testSentAttachmentQuickLookKeepsItsSelectedFileInJoinedColumns() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("msgblast-preview-\(UUID()).png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 180, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        for y in 0..<180 { for x in 0..<320 {
            let offset = y * bitmap.bytesPerRow + x * 4
            bytes[offset] = 26
            bytes[offset + 1] = x < 160 ? 115 : 204
            bytes[offset + 2] = x < 160 ? 255 : 77
            bytes[offset + 3] = 255
        } }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
        let app = launchFixture(separateWindows: false)
        defer { app.terminate(); try? FileManager.default.removeItem(at: file) }
        let prompt = "Quick Look joined attachment fixture"
        let editor = app.textViews["Shared prompt"]
        editor.click(); editor.typeKey("a", modifierFlags: .command); editor.typeText(prompt)
        app.menuButtons["Add photo or file"].click()
        app.menuItems["Choose File…"].click()
        let picker = app.sheets["open-panel"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        app.typeKey("g", modifierFlags: [.command, .shift])
        let path = app.textFields["PathTextField"]
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        path.click(); path.typeKey("a", modifierFlags: .command); path.typeText(file.path)
        app.typeKey(.return, modifierFlags: [])
        picker.buttons["Open"].click()
        let previewName = "Preview \(file.lastPathComponent)"
        XCTAssertTrue(app.buttons[previewName].waitForExistence(timeout: 5))
        app.buttons["Send & compare"].click()
        let workspace = app.windows["\(prompt) [Demo]"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        let images = workspace.buttons.matching(identifier: previewName)
        XCTAssertTrue(images.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(images.count, 3)
        images.firstMatch.click()
        XCTAssertTrue(app.scrollViews["Image Preview: \(file.lastPathComponent)"].waitForExistence(timeout: 5), "Quick Look must retain the selected attachment when the transcript selects its recipient")
        XCTAssertFalse(app.staticTexts["No items selected"].exists)
        let panel = app.windows["Quick Look"]
        var rendered = panel.screenshot()
        let deadline = Date().addingTimeInterval(5)
        while !previewContainsFixtureColors(rendered), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            rendered = panel.screenshot()
        }
        XCTAssertTrue(previewContainsFixtureColors(rendered), "The preview must render the image, not just expose its filename")
        let screenshot = XCTAttachment(screenshot: rendered)
        screenshot.name = "Joined Quick Look — synthetic demo image"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.typeKey(.escape, modifierFlags: [])
        let conversation = XCTAttachment(screenshot: workspace.screenshot())
        conversation.name = "Joined photo cards — synthetic demo image"
        conversation.lifetime = .keepAlways
        add(conversation)
        images.firstMatch.click()
        XCTAssertTrue(app.scrollViews["Image Preview: \(file.lastPathComponent)"].waitForExistence(timeout: 5), "Closing a preview must allow the same image to be opened again")
        app.typeKey(.escape, modifierFlags: [])
        workspace.buttons[XCUIIdentifierCloseWindow].click()
        app.menuBars.menuBarItems["Comparisons"].click()
        app.menuItems[prompt].click()
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        XCTAssertEqual(workspace.buttons.matching(identifier: previewName).count, 3, "Reopening must preserve all three attachment receipts")
        workspace.buttons.matching(identifier: previewName).element(boundBy: 1).click()
        XCTAssertTrue(app.scrollViews["Image Preview: \(file.lastPathComponent)"].waitForExistence(timeout: 5))
        var reopened = panel.screenshot()
        let reopenDeadline = Date().addingTimeInterval(5)
        while !previewContainsFixtureColors(reopened), Date() < reopenDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            reopened = panel.screenshot()
        }
        XCTAssertTrue(previewContainsFixtureColors(reopened), "A reopened conversation must supply the selected file to Quick Look")
    }
    @MainActor
    private func previewContainsFixtureColors(_ screenshot: XCUIScreenshot) -> Bool {
        guard let pixels = NSBitmapImageRep(data: screenshot.pngRepresentation) else { return false }
        var blue = false, green = false
        for x in stride(from: pixels.pixelsWide / 2 - 60, through: pixels.pixelsWide / 2 + 60, by: 20) {
            for y in stride(from: pixels.pixelsHigh / 2 - 20, through: pixels.pixelsHigh / 2 + 20, by: 10) {
                guard let color = pixels.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                blue = blue || (color.blueComponent > color.redComponent + 0.2 && color.blueComponent > color.greenComponent + 0.1)
                green = green || (color.greenComponent > color.redComponent + 0.2 && color.greenComponent > color.blueComponent + 0.1)
            }
        }
        return blue && green
    }
    @MainActor
    func testPermissionGuideReturnsToItsSourceWithoutClaimingAccess() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo", "--permission-guide-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Permission guide preview · simulated history denial"].waitForExistence(timeout: 5))
        app.buttons["Open Settings"].click()
        let guide = app.dialogs["Messages access guide"]
        guard guide.waitForExistence(timeout: 10) else { XCTFail("Permission guide did not appear"); return }
        let drag = guide.buttons["Drag msgblast into Full Disk Access"]
        XCTAssertTrue(drag.exists)
        XCTAssertTrue(drag.isEnabled)
        let image = XCTAttachment(screenshot: guide.screenshot())
        image.name = "Permission guide — simulated history denial"
        image.lifetime = .keepAlways
        add(image)
        drag.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1, thenDragTo: guide.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.1)))
        XCTAssertTrue(guide.exists)
        XCTAssertFalse(app.staticTexts["Done"].exists)
        guide.buttons["Back to msgblast"].click()
        XCTAssertTrue(app.buttons["Open Settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Done"].exists)
        XCTAssertFalse(guide.exists)
    }
    @MainActor
    func testManualAccountWithoutChatIsSavedButCannotReceiveTheSharedPrompt() {
        let app = launchFixture(separateWindows: false)
        app.buttons["Add agent"].click()
        let search = app.textFields["Name, email or phone number"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click(); search.typeText("pending@example.com")
        app.buttons["Search"].click()
        let add = app.buttons["Add pending@example.com"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertTrue(add.isEnabled)
        add.click()
        XCTAssertTrue(app.staticTexts["Saved"].exists)
        app.buttons["Done"].click()
        let pending = app.buttons["pending@example.com"]
        XCTAssertTrue(pending.waitForExistence(timeout: 5))
        XCTAssertFalse(pending.isEnabled)
        XCTAssertEqual(pending.value as? String, "Not selected")
        let prompt = app.textViews["Shared prompt"]
        prompt.click(); prompt.typeKey("a", modifierFlags: .command); prompt.typeText("Pending contact regression fixture")
        app.buttons["Send & compare"].click()
        let workspace = app.windows["Pending contact regression fixture [Demo]"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        for name in ["Cedar", "Lumen", "Orbit"] { XCTAssertTrue(workspace.buttons["Recipient \(name)"].exists) }
        XCTAssertFalse(workspace.buttons["Recipient pending@example.com"].exists)
    }
    @MainActor
    func launchFixture(threeAgentsOnly: Bool = true, separateWindows: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        // A fresh isolated store must use the joined layout by default.
        if separateWindows {
            app.menuBars.menuBarItems["msgblast"].click()
            app.menuItems["Settings…"].click()
            let layout = app.radioButtons["Separate windows"]
            XCTAssertTrue(layout.waitForExistence(timeout: 5))
            layout.click()
            app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch.buttons[XCUIIdentifierCloseWindow].click()
        }
        let reset = app.buttons["Reset sample data"]
        XCTAssertTrue(reset.waitForExistence(timeout: 10))
        reset.click()
        for name in ["Muse", "ChatGPT", "Claude", "Grok"] { app.buttons[name].click() }
        if threeAgentsOnly {
            for name in ["Maple", "Echo", "Flint"] { app.buttons[name].click() }
        }
        return app
    }
    @MainActor
    func testJoinedInputRoutesSelectedAndExcludedConversationsAndPreservesItsDraft() {
        let app = launchFixture(separateWindows: false)
        let prompt = app.textViews["Shared prompt"]
        prompt.click(); prompt.typeKey("a", modifierFlags: .command); prompt.typeText("Connected workspace fixture")
        app.buttons["Send & compare"].click()
        let workspace = app.windows["Connected workspace fixture [Demo]"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        for name in ["Cedar", "Lumen", "Orbit"] { XCTAssertTrue(workspace.textViews["Private reply to \(name)"].exists) }
        let cedarInput = workspace.textViews["Private reply to Cedar"]
        let lumenInput = workspace.textViews["Private reply to Lumen"]
        lumenInput.click(); lumenInput.typeText("Lumen retained private draft")
        cedarInput.click(); cedarInput.typeText("Cedar pane reply fixture")
        cedarInput.typeKey(.return, modifierFlags: [])
        let paneReplies = workspace.textViews.matching(NSPredicate(format: "value == %@", "Cedar pane reply fixture"))
        XCTAssertTrue(paneReplies.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(paneReplies.count, 1, "A pane reply must reach only its own agent")
        XCTAssertEqual(cedarInput.value as? String, "")
        XCTAssertEqual(lumenInput.value as? String, "Lumen retained private draft")
        let input = workspace.textViews["Universal message"]
        XCTAssertTrue(input.exists)
        for name in ["Cedar", "Lumen", "Orbit"] {
            XCTAssertEqual(workspace.buttons["Recipient \(name)"].value as? String, "Selected")
        }
        input.click(); input.typeText("Cedar private fixture")
        workspace.buttons["Select Cedar conversation"].click()
        XCTAssertEqual(input.value as? String, "Cedar private fixture")
        workspace.buttons["Send to Cedar"].click()
        XCTAssertTrue(workspace.textViews.matching(NSPredicate(format: "value == %@", "Cedar private fixture")).firstMatch.waitForExistence(timeout: 5))
        workspace.buttons["Recipient Lumen"].click()
        workspace.buttons["Recipient Orbit"].click()
        workspace.buttons["Recipient Cedar"].click()
        XCTAssertEqual(workspace.buttons["Shared recipient Cedar"].value as? String, "Excluded")
        XCTAssertEqual(workspace.buttons["Recipient Cedar"].value as? String, "Not selected")
        XCTAssertEqual(workspace.buttons["Recipient Lumen"].value as? String, "Selected")
        XCTAssertEqual(workspace.buttons["Recipient Orbit"].value as? String, "Selected")
        input.click(); input.typeText("Remaining recipients fixture")
        workspace.buttons["Send to Lumen, Orbit"].click()
        let copies = workspace.textViews.matching(NSPredicate(format: "value == %@", "Remaining recipients fixture"))
        XCTAssertTrue(copies.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(copies.count, 2)
        input.click(); input.typeText("one retained draft")
        workspace.buttons["Select Orbit conversation"].click()
        XCTAssertEqual(input.value as? String, "one retained draft")
        app.typeKey(",", modifierFlags: .command)
        app.radioButtons["Separate windows"].click()
        XCTAssertTrue(app.windows["Cedar · Connected workspace fixture"].waitForExistence(timeout: 5))
        XCTAssertFalse(workspace.exists)
        XCTAssertTrue(app.textViews["Private reply to Cedar"].exists)
        XCTAssertEqual(app.textViews["Follow-up to all agents"].value as? String, "one retained draft")
        app.radioButtons["One window"].click()
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        XCTAssertEqual(workspace.textViews["Universal message"].value as? String, "one retained draft")
    }
    @MainActor
    func testPinnedComposerSelectsEveryoneAndAvatarTogglesSelection() {
        let app = launchFixture(threeAgentsOnly: false)
        for name in ["Cedar", "Lumen", "Orbit", "Maple", "Echo", "Flint"] {
            XCTAssertEqual(app.buttons[name].value as? String, "Selected")
        }
        let cedar = app.buttons["Cedar"]
        cedar.click()
        XCTAssertEqual(cedar.value as? String, "Not selected")
        cedar.click()
        XCTAssertEqual(cedar.value as? String, "Selected")
        XCTAssertTrue(app.textViews["Shared prompt"].exists)
    }
    @MainActor
    func testSharedPrivateAndAllScopes() {
        let app = launchFixture()
        let prompt = app.textViews["Shared prompt"]
        prompt.click(); prompt.typeKey("a", modifierFlags: .command); prompt.typeText("UI fixture: compare three approaches")
        app.buttons["Send & compare"].click()
        let cedar = app.windows["Cedar · UI fixture: compare three approaches"]
        XCTAssertTrue(cedar.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Show Cedar's conversation"].waitForExistence(timeout: 10))
        app.buttons["Show Cedar's conversation"].click()
        let privateField = app.textViews["Private reply to Cedar"]
        XCTAssertTrue(privateField.waitForExistence(timeout: 5))
        privateField.click(); privateField.typeText("Cedar only fixture follow-up")
        cedar.buttons["Send privately"].click()
        XCTAssertTrue(cedar.textViews.matching(NSPredicate(format: "value CONTAINS %@", "Cedar only fixture follow-up")).firstMatch.waitForExistence(timeout: 5))
        let lumen = app.windows["Lumen · UI fixture: compare three approaches"]
        XCTAssertFalse(lumen.textViews.matching(NSPredicate(format: "value CONTAINS %@", "Cedar only fixture follow-up")).firstMatch.exists)
        // Reopen through the app's own comparison menu, exercising saved prompt navigation.
        app.menuBars.menuBarItems["Comparisons"].click()
        app.menuItems["UI fixture: compare three approaches"].click()
        let all = app.textViews["Follow-up to all agents"]
        XCTAssertTrue(all.waitForExistence(timeout: 5)); all.click(); all.typeText("All recipients fixture follow-up")
        app.buttons["Send to all"].click()
        for name in ["Cedar", "Lumen", "Orbit"] {
            let window = app.windows["\(name) · UI fixture: compare three approaches"]
            XCTAssertTrue(window.textViews.matching(NSPredicate(format: "value CONTAINS %@", "All recipients fixture follow-up")).firstMatch.waitForExistence(timeout: 5))
        }
        let attachment = XCTAttachment(screenshot: cedar.screenshot()); attachment.name = "Fixture Cedar private and shared replies"; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor
    func testPartialFailureRetriesOnlyFailedRecipient() {
        let app = launchFixture()
        let prompt = app.textViews["Shared prompt"].value as! String
        app.checkBoxes["Simulate one failure"].click()
        app.buttons["Send & compare"].click()
        let cedar = app.windows["Cedar · \(String(prompt.prefix(65)))"]
        let lumen = app.windows["Lumen · \(String(prompt.prefix(65)))"]
        let orbit = app.windows["Orbit · \(String(prompt.prefix(65)))"]
        func copies(in window: XCUIElement) -> Int {
            return window.textViews.matching(NSPredicate(format: "value == %@", prompt)).count
        }
        XCTAssertTrue(cedar.waitForExistence(timeout: 10))
        XCTAssertEqual(copies(in: cedar), 1)
        XCTAssertEqual(copies(in: lumen), 1)
        XCTAssertEqual(copies(in: orbit), 0)
        app.buttons["Show Orbit's conversation"].click()
        let retry = app.buttons["Retry only failed recipients"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        retry.click()
        XCTAssertTrue(orbit.textViews.matching(NSPredicate(format: "value CONTAINS %@", prompt)).firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(copies(in: orbit), 1)
        XCTAssertEqual(copies(in: cedar), 1)
        XCTAssertEqual(copies(in: lumen), 1)
        XCTAssertFalse(retry.exists)
    }
    @MainActor
    func testTranscriptSurvivesRepeatedPrivateSendsAndAccessibilityReads() {
        let app = launchFixture()
        app.buttons["Send & compare"].click()
        XCTAssertTrue(app.buttons["Show Cedar's conversation"].waitForExistence(timeout: 10))
        app.buttons["Show Cedar's conversation"].click()
        let input = app.textViews["Private reply to Cedar"]
        for index in 1...3 {
            let text = "Accessibility crash regression \(index)"
            input.click(); input.typeText(text)
            app.buttons["Send privately"].click()
            XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS %@", text)).firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(app.state, .runningForeground)
        }
    }

    @MainActor
    func testFeedbackDiagnosticsDefaultOnAndCanBeExcluded() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        defer { app.terminate() }
        app.menuBars.menuBarItems["Help"].click()
        XCTAssertTrue(app.menuBars.menuBarItems["Help"].menuItems["Share Feedback…"].waitForExistence(timeout: 5))
        app.menuBars.menuBarItems["Help"].menuItems["Share Feedback…"].click()
        let feedback = app.windows["Send Feedback"]
        XCTAssertTrue(feedback.waitForExistence(timeout: 5))
        XCTAssertTrue(feedback.staticTexts["Send feedback to msgblast"].exists)
        XCTAssertTrue(feedback.staticTexts["Describe what happened, what you expected, and the steps to reproduce it."].exists)
        XCTAssertFalse(feedback.segmentedControls["Kind"].exists)
        let diagnostics = feedback.checkBoxes["Include a diagnostic report"]
        XCTAssertTrue(diagnostics.exists)
        XCTAssertEqual(diagnostics.value as? Int, 1)
        XCTAssertTrue(feedback.buttons["Save Report with Diagnostics…"].exists)
        diagnostics.click()
        XCTAssertEqual(diagnostics.value as? Int, 0)
        XCTAssertTrue(feedback.staticTexts["A diagnostic report is not included."].exists)
        XCTAssertTrue(feedback.buttons["Save Report…"].exists)
        diagnostics.click()
        XCTAssertEqual(diagnostics.value as? Int, 1)
        XCTAssertTrue(feedback.staticTexts["This is the entire diagnostic file."].waitForExistence(timeout: 5))
        let preview = feedback.staticTexts["Diagnostic preview"].exists ? feedback.staticTexts["Diagnostic preview"] : feedback.textViews["Diagnostic preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        let previewText = (preview.value as? String) ?? preview.label
        XCTAssertTrue(previewText.contains("\"messagesStatus\""))
        XCTAssertFalse(previewText.contains("chat.db"))
        XCTAssertFalse(previewText.contains("@"))
        XCTAssertTrue(feedback.buttons["Save Report with Diagnostics…"].exists)
        let shot = XCTAttachment(screenshot: feedback.screenshot())
        shot.name = "Send Feedback — diagnostic preview enabled by default — isolated demo"
        shot.lifetime = .keepAlways
        add(shot)
        feedback.buttons[XCUIIdentifierCloseWindow].click()
    }
}
