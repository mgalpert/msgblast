import XCTest
import AppKit
final class WorkflowTests: XCTestCase {
    @MainActor
    func testSettingsNavigationRetainsSharingDraftAndCancelsShortcutRecording() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.textViews["Shared prompt"].waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        for name in ["General", "Connections", "Permissions", "Sharing", "Updates"] {
            XCTAssertTrue(settings.buttons[name].isHittable)
        }
        settings.buttons["Record Shortcut"].click()
        XCTAssertTrue(settings.buttons["Cancel Recording"].exists)
        settings.buttons["Sharing"].click()
        let usage = settings.checkBoxes.matching(NSPredicate(format: "label CONTAINS %@", "Share usage statistics")).firstMatch
        XCTAssertTrue(usage.waitForExistence(timeout: 5))
        usage.click()
        let unsavedValue = String(describing: usage.value ?? "")
        settings.buttons["Connections"].click()
        for name in ["Websites", "CLI tools", "Webhooks", "Mac apps"] {
            let category = settings.radioButtons[name]
            XCTAssertTrue(category.isHittable)
            category.click()
            if name == "CLI tools" {
                let codex = settings.switches["Enable Codex CLI"]
                XCTAssertTrue(codex.isHittable)
                codex.click()
                XCTAssertEqual(String(describing: codex.value ?? ""), "1")
            }
            if name == "Webhooks" {
                XCTAssertTrue(settings.buttons["Add Grok Bot…"].isHittable)
            }
        }
        settings.buttons["Manage permissions"].click()
        XCTAssertTrue(settings.switches["enable-cua-host-permission"].exists)
        settings.buttons["Updates"].click()
        XCTAssertTrue(settings.staticTexts["Software updates"].exists)
        settings.buttons["Sharing"].click()
        XCTAssertEqual(String(describing: usage.value ?? ""), unsavedValue, "Tab changes must retain unsaved choices")
        settings.buttons["Save choices"].click()
        XCTAssertTrue(settings.buttons["Choices saved"].waitForExistence(timeout: 5))
        settings.buttons["General"].click()
        XCTAssertTrue(settings.buttons["Record Shortcut"].exists, "Leaving General cancels recording")
        XCTAssertFalse(settings.buttons["Cancel Recording"].exists)
        settings.buttons[XCUIIdentifierCloseWindow].click()
        app.typeKey(",", modifierFlags: .command)
        settings.buttons["Sharing"].click()
        XCTAssertEqual(String(describing: usage.value ?? ""), unsavedValue, "Saved choices must survive reopening")
    }

    @MainActor
    func testGlobalNewBlastShortcutFromAnotherAppAndDisable() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Cedar"].waitForExistence(timeout: 10))
        app.buttons["Lumen"].click()
        app.typeKey(",", modifierFlags: .command)
        let record = app.buttons["Record Shortcut"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        record.click()
        app.typeKey("b", modifierFlags: [.control, .shift, .command])
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        let toggle = app.switches["Enable global New Blast shortcut"]
        XCTAssertEqual(String(describing: toggle.value ?? ""), "1")
        app.buttons["Record Shortcut"].click()
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        let settings = app.windows.containing(.button, identifier: "Record Shortcut").firstMatch
        settings.buttons[XCUIIdentifierCloseWindow].click()
        app.buttons["Discover"].click()
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        finder.typeKey("b", modifierFlags: [.control, .shift, .command])
        XCTAssertTrue(app.buttons["Cedar"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textViews["Shared prompt"].isHittable)
        app.typeText(" Shortcut focus fixture")
        XCTAssertTrue((app.textViews["Shared prompt"].value as? String)?.contains("Shortcut focus fixture") == true)
        XCTAssertEqual(app.buttons["Lumen"].value as? String, "Not selected")
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.click()
        XCTAssertEqual(String(describing: toggle.value ?? ""), "0")
        settings.buttons[XCUIIdentifierCloseWindow].click()
        app.buttons["Discover"].click()
        finder.activate()
        finder.typeKey("b", modifierFlags: [.control, .shift, .command])
        XCTAssertFalse(app.buttons["Cedar"].exists, "Disabled shortcut must leave Discover open")
    }

    @MainActor
    func testMenuBarNewBlastRetainsSelectionsAndReopensWorkspace() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Cedar"].waitForExistence(timeout: 10))
        app.buttons["Lumen"].click()
        app.buttons["Discover"].click()
        let menu = app.descendants(matching: .statusItem).matching(identifier: "msgblast Quick Access").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        guard menu.exists else { return }
        menu.click()
        menu.menuItems["New Blast"].click()
        XCTAssertTrue(app.buttons["Cedar"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["Cedar"].value as? String, "Selected")
        XCTAssertEqual(app.textViews.matching(identifier: "Shared prompt").count, 1, "Quick access must reuse the initial workspace")
        XCTAssertEqual(app.buttons["Lumen"].value as? String, "Not selected")
        app.windows.containing(.textView, identifier: "Shared prompt").firstMatch.buttons[XCUIIdentifierCloseWindow].click()
        menu.click()
        menu.menuItems["New Blast"].click()
        XCTAssertTrue(app.textViews["Shared prompt"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["Lumen"].value as? String, "Not selected")
        app.buttons["Discover"].click()
        app.windows.firstMatch.buttons[XCUIIdentifierCloseWindow].click()
        menu.click()
        menu.menuItems["New Blast"].click()
        XCTAssertTrue(app.textViews["Shared prompt"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textViews.matching(identifier: "Shared prompt").count, 1, "Closing Discover must retain one interactive workspace")
        menu.click()
        menu.menuItems["New Chat With"].click()
        menu.menuItems["Cedar"].click()
        for name in ["Lumen", "Orbit", "Maple", "Echo", "Flint"] {
            XCTAssertEqual(app.buttons[name].value as? String, "Not selected")
        }
        XCTAssertEqual(app.buttons["Cedar"].value as? String, "Selected")
        XCTAssertTrue(app.staticTexts["No comparisons"].exists,
                       "Opening a chat must not submit a message or create a comparison")
        app.buttons["Edit agents"].click()
        let search = app.textFields["Search available agents"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click(); search.typeText("ChatGPT")
        app.buttons["Add ChatGPT"].click()
        let setupDone = app.buttons["Done setting up ChatGPT"]
        if setupDone.waitForExistence(timeout: 3) { setupDone.click() }
        app.buttons["Done editing agents"].click()
        app.buttons["ChatGPT"].click()
        menu.click()
        menu.menuItems["New Chat With"].click()
        XCTAssertTrue(menu.menuItems["ChatGPT"].waitForExistence(timeout: 10))
        menu.menuItems["ChatGPT"].click()
        XCTAssertTrue(app.buttons["Recipient ChatGPT"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["Recipient ChatGPT"].value as? String, "Selected")
        XCTAssertEqual(app.buttons["Recipient Cedar"].value as? String, "Not selected")
        XCTAssertEqual(app.webViews.count, 1)
        XCTAssertTrue(app.staticTexts["No comparisons"].exists)
        app.buttons["Capture chat"].click()
        XCTAssertTrue(app.buttons["Copy image"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Save image…"].exists)
        XCTAssertTrue(app.buttons["Share image…"].exists)
        XCTAssertFalse(app.buttons["Share full chat by URL…"].exists)
        app.buttons["Done"].click()
        XCTAssertTrue(app.buttons["Agents"].exists, "Capture must restore the sidebar")
        let header = app.descendants(matching: .any).matching(identifier: "Agent header ChatGPT").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        header.rightClick()
        app.menuItems["Remove from view"].click()
        XCTAssertFalse(header.exists)
        menu.click()
        menu.menuItems["New Chat With"].click()
        menu.menuItems["ChatGPT"].click()
        XCTAssertTrue(header.waitForExistence(timeout: 5), "Opening a fresh unsent chat must restore its hidden pane")
        header.rightClick()
        app.menuItems["Remove from view"].click()
        app.buttons["Agents"].click()
        app.buttons["ChatGPT"].click()
        app.buttons["ChatGPT"].rightClick()
        app.menuItems["Open chat"].click()
        XCTAssertTrue(header.waitForExistence(timeout: 5), "Explicit grid reopening must restore its hidden pane")
        XCTAssertEqual(app.webViews.count, 1)
        XCTAssertTrue(app.staticTexts["No comparisons"].exists)
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Record Shortcut"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testDiscoverFindsInstinctBeforeContactsAreConnected() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo", "--contacts-access-preview"]
        app.launch()
        defer { app.terminate() }
        app.buttons["Discover"].click()
        let search = app.textFields["Search Discover"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click(); search.typeText("instinct")
        let setup = app.buttons["Set up Instinct"]
        XCTAssertTrue(setup.waitForExistence(timeout: 5))
        XCTAssertTrue(setup.isEnabled)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Instinct in Discover without Contacts — isolated fixture"
        screenshot.lifetime = .keepAlways; add(screenshot)
        setup.click()
        XCTAssertTrue(app.staticTexts["Connect an existing Messages conversation for Instinct."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Connect Contacts"].exists)
        app.buttons["Done"].click()
        XCTAssertEqual(app.alerts.count, 0, "Opening setup without Contacts access must show guidance without a deferred error alert")
    }

    @MainActor
    func testSettingsSharesOnboardingPermissionsAndEnablesContactsIndependently() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo", "--permission-guide-preview", "--contacts-access-preview", "--onboarding-permissions-preview"]
        app.launch()
        defer { app.terminate() }
        let skip = app.buttons["Skip for now"]
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        skip.click()
        let draft = app.textViews["Shared prompt"]
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        draft.click(); draft.typeKey("a", modifierFlags: .command); draft.typeText("Retain this permission settings draft")
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        app.buttons["Permissions"].click()
        let history = settings.switches["enable-messages-history-permission"]
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        for id in ["messages-history", "messages-contacts", "messages-automation", "cua-host", "cua-capture"] {
            XCTAssertTrue(settings.switches["enable-\(id)-permission"].exists, "Settings must expose the same five switches as onboarding")
        }
        XCTAssertFalse(app.buttons["Manage"].exists)
        XCTAssertFalse(app.buttons["Check again"].exists)
        XCTAssertFalse(settings.switches["enable-cua-driver-permission"].exists)
        XCTAssertEqual(String(describing: history.value ?? ""), "0")
        app.buttons["Connections"].click()
        let chatGPT = settings.switches["enable-app-chatgptApp"]
        for _ in 0..<12 where !chatGPT.isHittable { settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -180) }
        XCTAssertTrue(chatGPT.isHittable)
        if String(describing: chatGPT.value ?? "") != "1" { chatGPT.click() }
        XCTAssertEqual(String(describing: chatGPT.value ?? ""), "1")
        let setup = settings.buttons["setup-app-chatgptApp"]
        XCTAssertFalse(setup.isEnabled, "An enabled app still needs both app permissions before setup")
        app.buttons["Manage permissions"].click()
        let contacts = settings.switches["enable-messages-contacts-permission"]
        XCTAssertEqual(String(describing: contacts.value ?? ""), "0")
        contacts.click()
        expectation(for: NSPredicate(format: "value == 1"), evaluatedWith: contacts)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(String(describing: history.value ?? ""), "0")
        let host = settings.switches["enable-cua-host-permission"]
        host.click()
        XCTAssertEqual(String(describing: host.value ?? ""), "1")
        app.buttons["Connections"].click()
        XCTAssertFalse(setup.isEnabled, "Device Control alone must not allow setup")
        app.buttons["Manage permissions"].click()
        XCTAssertEqual(String(describing: settings.switches["enable-cua-capture-permission"].value ?? ""), "0")
        settings.switches["enable-cua-capture-permission"].click()
        XCTAssertEqual(String(describing: settings.switches["enable-cua-capture-permission"].value ?? ""), "1")
        app.buttons["Connections"].click()
        XCTAssertTrue(setup.isEnabled, "Setup must become available when both app permissions are enabled")
        app.buttons["Permissions"].click()
        XCTAssertEqual(app.sheets.count, 0, "Demo must never request real system access")
        let screenshot = XCTAttachment(screenshot: app.windows["com_apple_SwiftUI_Settings_window"].screenshot())
        screenshot.name = "Shared permission switches — simulated independent grants"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.windows["com_apple_SwiftUI_Settings_window"].buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(app.staticTexts["Allow access"].exists, "Changing access retains the required permission-review checkpoint")
        app.buttons["Skip for now"].click()
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        XCTAssertEqual(draft.value as? String, "Retain this permission settings draft", "Returning from permission review must retain the workspace")
    }

    @MainActor
    func testSettingsSetsUpEveryAvailableAppWithoutChangingDraftOrStartingOnboarding() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        defer { app.terminate() }
        let draft = app.textViews["Shared prompt"]
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        draft.click(); draft.typeKey("a", modifierFlags: .command); draft.typeText("Keep this unsent draft")
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        app.buttons["Connections"].click()
        for (provider, name) in [("chatgptApp", "ChatGPT"), ("dotsApp", "Dots"), ("claudeApp", "Claude"), ("museApp", "Muse"), ("grokBotApp", "Grok Bot"), ("wabi", "Wabi")] {
            let enable = settings.switches["enable-app-\(provider)"]
            XCTAssertTrue(enable.exists)
            settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: 10000)
            for _ in 0..<12 where !enable.isHittable { settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -180) }
            XCTAssertTrue(enable.isHittable)
            if String(describing: enable.value ?? "") != "1" { enable.click() }
            settings.buttons["setup-app-\(provider)"].click()
            let sheet = settings.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 5))
            let connect = sheet.buttons["Connect \(name)"].firstMatch
            XCTAssertTrue(connect.waitForExistence(timeout: 5))
            connect.click()
            if provider == "grokBotApp" {
                let picker = sheet.popUpButtons["grok-bot-picker"]
                XCTAssertTrue(picker.waitForExistence(timeout: 5))
                picker.click()
                app.menuItems["Research Bot"].click()
            }
            XCTAssertTrue(sheet.staticTexts["Ready for your first prompt"].waitForExistence(timeout: 5))
            XCTAssertTrue(sheet.staticTexts["Demo connections are simulated. No app is contacted."].exists)
            sheet.buttons["Done"].click()
            XCTAssertFalse(settings.sheets.firstMatch.exists)
        }
        XCTAssertTrue(settings.staticTexts["Unavailable in this build"].exists, "Deferred Gemini must remain visibly unavailable")
        settings.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertEqual(draft.value as? String, "Keep this unsent draft")
        XCTAssertFalse(app.staticTexts["Allow access"].exists, "Settings must not reopen onboarding")
        XCTAssertTrue(app.staticTexts["No comparisons"].exists, "Connecting must not send a prompt")
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
    func testPersonalAgentOpensComparisonReportWithTeamSynthesis() {
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
        let action = report.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "The conversations examine how to compare approaches", "The conversations examine how to compare approaches")).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 10), "One toolbar click must generate the report")
        XCTAssertTrue((action.label + (action.value as? String ?? "")).contains("consistent criteria"))
        XCTAssertTrue(report.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Shared findings", "Shared findings")).firstMatch.exists)
        XCTAssertTrue(report.staticTexts["3 of 3 participants · 6 responses"].exists)
        XCTAssertFalse(report.buttons["Refresh agents"].exists)
        XCTAssertFalse(report.popUpButtons["Personal agent"].exists)
        report.menuButtons["Report actions"].click()
        app.menuItems["Report options…"].click()
        XCTAssertTrue(app.buttons["Refresh agents"].waitForExistence(timeout: 5))
        report.typeKey(.escape, modifierFlags: [])
        let after = XCTAttachment(screenshot: report.screenshot())
        after.name = "Comparison report — team synthesis — simulated output"
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
        XCTAssertTrue(report.staticTexts["3 of 3 participants · 12 responses"].waitForExistence(timeout: 10))
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
        XCTAssertTrue(report.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "The conversations examine how to compare approaches", "The conversations examine how to compare approaches")).firstMatch.waitForExistence(timeout: 10))
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
        for title in ["About msgblast", "Build a New Feature…", "Check for Updates…", "Settings…", "Hide msgblast", "Quit msgblast"] {
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
    func testBuildFeatureInvitationCopiesIdeaAndReusesWindow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        defer { app.terminate() }
        app.menuBars.menuBarItems["msgblast"].click()
        let command = app.menuItems["Build a New Feature…"]
        XCTAssertTrue(command.waitForExistence(timeout: 5))
        guard command.exists else { return }
        command.click()
        let window = app.windows["Build a New Feature"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertTrue(window.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Excited to see what you build.", "Excited to see what you build.")).firstMatch.exists)
        let preview = window.staticTexts["Coding agent prompt"]
        XCTAssertTrue(preview.exists)
        let emptyPrompt = try XCTUnwrap(preview.value as? String)
        XCTAssertTrue(emptyPrompt.contains("[Describe the problem and the behavior you want.]"))
        XCTAssertTrue(emptyPrompt.contains("https://github.com/mgalpert/msgblast"))
        XCTAssertTrue(emptyPrompt.contains("AGENTS.md"))
        XCTAssertTrue(emptyPrompt.contains("Screenshots"))
        XCTAssertTrue(emptyPrompt.contains("Video"))
        let idea = window.textFields["Feature idea, optional"]
        XCTAssertTrue(idea.exists)
        idea.click()
        idea.typeText("Pin my favorite comparisons")
        let enteredPrompt = try XCTUnwrap(preview.value as? String)
        XCTAssertTrue(enteredPrompt.contains("My feature idea: Pin my favorite comparisons"))
        window.buttons["Copy Prompt"].click()
        XCTAssertTrue(window.buttons["Copied"].waitForExistence(timeout: 3))
        XCTAssertTrue(window.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Prompt copied. Paste it into your coding agent to get started.", "Prompt copied. Paste it into your coding agent to get started.")).firstMatch.exists)
        // Exercise the actual clipboard via the idea field, without reading any
        // pre-existing clipboard contents or importing live app data.
        idea.click()
        idea.typeKey("a", modifierFlags: .command)
        idea.typeKey("v", modifierFlags: .command)
        XCTAssertEqual(idea.value as? String, enteredPrompt)
        XCTAssertTrue(window.buttons["Copy Prompt"].exists, "Editing resets copy confirmation")
        idea.typeKey("a", modifierFlags: .command)
        idea.typeText("Pin my favorite comparisons")
        app.menuBars.menuBarItems["Help"].click()
        app.menuItems["Build a New Feature…"].click()
        XCTAssertEqual(app.windows.matching(identifier: "Build a New Feature").count, 1)
        XCTAssertEqual(idea.value as? String, "Pin my favorite comparisons")
        window.buttons[XCUIIdentifierCloseWindow].click()
        app.menuBars.menuBarItems["msgblast"].click()
        app.menuItems["Build a New Feature…"].click()
        XCTAssertTrue(window.waitForExistence(timeout: 3))
        XCTAssertEqual(window.textFields["Feature idea, optional"].value as? String, "")
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
    func launchFixture(threeAgentsOnly: Bool = true, separateWindows: Bool = true, automaticReplies: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        if !automaticReplies { app.launchArguments.append("--no-demo-replies") }
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
        for name in ["Muse", "ChatGPT", "Claude", "Grok"] where app.buttons[name].value as? String == "Selected" { app.buttons[name].click() }
        if threeAgentsOnly {
            for name in ["Maple", "Echo", "Flint"] { app.buttons[name].click() }
        }
        return app
    }
    @MainActor
    func testRemoveConversationFromViewPreservesDraftAndCanRestore() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--isolated-demo"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Reset sample data"].waitForExistence(timeout: 10))
        app.buttons["Reset sample data"].click()
        let prompt = app.textViews["Shared prompt"]
        prompt.click(); prompt.typeKey("a", modifierFlags: .command); prompt.typeText("Remove pane fixture")
        app.buttons["Send & compare"].click()
        let workspace = app.windows["Remove pane fixture [Demo]"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        let draft = workspace.textViews["Private reply to Lumen"]
        draft.click(); draft.typeText("Retained hidden draft")
        workspace.buttons["Select Lumen conversation"].rightClick()
        XCTAssertTrue(app.menuItems["Remove from view"].waitForExistence(timeout: 3))
        app.menuItems["Remove from view"].click()
        XCTAssertFalse(draft.exists)
        let hidden = XCTAttachment(screenshot: workspace.screenshot()); hidden.name = "Lumen removed — isolated Demo fixture"; hidden.lifetime = .keepAlways; add(hidden)
        XCTAssertTrue(workspace.textViews["Private reply to Cedar"].exists)
        XCTAssertEqual(workspace.buttons["Recipient Lumen"].value as? String, "Not selected")
        workspace.buttons["Recipient Lumen"].click()
        XCTAssertTrue(draft.waitForExistence(timeout: 3))
        XCTAssertEqual(draft.value as? String, "Retained hidden draft")
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
    func testPrivateComposerRevealsEndOfLongMessageWithoutManualScrolling() {
        let app = launchFixture(separateWindows: false, automaticReplies: false)
        let prompt = app.textViews["Shared prompt"]
        prompt.click(); prompt.typeKey("a", modifierFlags: .command); prompt.typeText("Private scroll regression")
        app.buttons["Send & compare"].click()
        let window = app.windows["Private scroll regression [Demo]"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let input = window.textViews["Private reply to Cedar"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let text = String(repeating: "Private sample content wraps across the pane. ", count: 30) + "END OF PRIVATE REPLY"
        input.click(); input.typeText(text); input.typeKey(.return, modifierFlags: [])
        let sent = window.textViews.matching(NSPredicate(format: "value == %@", text)).firstMatch
        let visible = NSPredicate { _, _ in
            guard input.value as? String == "", sent.exists else { return false }
            return sent.isHittable && sent.frame.maxY <= input.frame.minY && sent.frame.maxY > window.frame.minY
        }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: visible, object: nil)], timeout: 5)
        XCTAssertEqual(result, .completed, "The submitted message's end must be visible above the individual composer without scrolling")
        let image = XCTAttachment(screenshot: window.screenshot())
        image.name = "Private reply visible without scrolling"; image.lifetime = .keepAlways; add(image)
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
