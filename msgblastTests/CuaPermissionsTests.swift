import XCTest
@testable import msgblastCore

@MainActor
final class CuaPermissionsTests: XCTestCase {
    final class Probe: @unchecked Sendable {
        var installed = true
        var control = false
        var capture = false
        var controlRequests: [Bool] = []
        var captureRequests: [Bool] = []
        var settings: [String] = []
        var opensSettings = true
        func client() -> CuaPermissionClient {
            CuaPermissionClient(installed: { self.installed }, hostAccessibility: { prompt in
                self.controlRequests.append(prompt); return self.control
            }, hostScreenCapture: { prompt in
                self.captureRequests.append(prompt); return self.capture
            }, openSettings: { pane in
                self.settings.append(pane); return self.opensSettings
            })
        }
    }

    func testRefreshChecksOnlyHostWithoutRequestingConsentOrOpeningSettings() async {
        let probe = Probe()
        XCTAssertTrue(probe.controlRequests.isEmpty)
        let checked = CuaPermissionsController(client: probe.client())
        XCTAssertEqual(checked.hostAccessibility, .checking)
        await checked.refresh(demo: false)
        await checked.refresh(demo: false)
        XCTAssertEqual(checked.hostAccessibility, .off)
        XCTAssertEqual(checked.windowCapture, .off)
        XCTAssertEqual(probe.controlRequests, [false, false])
        XCTAssertEqual(probe.captureRequests, [false, false])
        XCTAssertTrue(probe.settings.isEmpty)
    }

    func testIndependentHostConsentAndRevocationNeverInventGrants() async {
        let probe = Probe(), controller = CuaPermissionsController(client: probe.client())
        controller.enableHostAccessibility(demo: false)
        XCTAssertEqual(controller.hostAccessibility, .off)
        XCTAssertEqual(probe.controlRequests, [true])
        XCTAssertTrue(probe.captureRequests.isEmpty, "Device Control must not request Screen Recording")
        controller.enableScreenCapture(demo: false)
        XCTAssertEqual(controller.windowCapture, .off, "A returned request cannot invent an OS grant")
        XCTAssertEqual(probe.captureRequests, [true])
        XCTAssertEqual(probe.settings, ["Privacy_Accessibility", "Privacy_ScreenCapture"])
        probe.control = true
        await controller.refresh(demo: false)
        XCTAssertEqual(controller.hostAccessibility, .allowed)
        XCTAssertEqual(controller.windowCapture, .off)
        probe.capture = true
        await controller.refresh(demo: false)
        XCTAssertEqual(controller.windowCapture, .allowed)
        probe.control = false
        probe.capture = false
        await controller.refresh(demo: false)
        XCTAssertEqual(controller.hostAccessibility, .off)
        XCTAssertEqual(controller.windowCapture, .off)
        XCTAssertEqual(probe.controlRequests.filter { $0 }.count, 1)
        XCTAssertEqual(probe.captureRequests.filter { $0 }.count, 1)
    }

    func testMissingBundledHelperDoesNotConfuseHostGrantsOrOfferStandaloneInstall() async {
        let probe = Probe()
        probe.installed = false
        probe.control = true
        probe.capture = true
        let controller = CuaPermissionsController(client: probe.client())
        await controller.refresh(demo: false)
        XCTAssertFalse(controller.installed)
        XCTAssertEqual(controller.hostAccessibility, .allowed)
        XCTAssertEqual(controller.windowCapture, .allowed)
        XCTAssertTrue(controller.message?.contains("Update or reinstall msgblast") == true)
        let readiness = OnboardingPermissionReadiness(fullDiskAccess: false, contacts: false, automation: false,
            hostAccessibility: controller.hostAccessibility == .allowed, screenCapture: controller.windowCapture == .allowed,
            driverInstalled: controller.installed)
        XCTAssertFalse(readiness.canContinue, "Host grants cannot mask a broken app bundle")
        probe.installed = true
        await controller.refresh(demo: false)
        XCTAssertTrue(controller.installed)
        XCTAssertNil(controller.message)
    }

    func testDemoGrantsAreIndependentPersistAcrossRefreshAndNeverTouchSystem() async {
        let probe = Probe(), controller = CuaPermissionsController(client: probe.client(), demoInitiallyAllowed: false)
        await controller.refresh(demo: true)
        XCTAssertEqual(controller.hostAccessibility, .off)
        XCTAssertEqual(controller.windowCapture, .off)
        controller.enableHostAccessibility(demo: true)
        await controller.refresh(demo: true)
        XCTAssertEqual(controller.hostAccessibility, .allowed)
        XCTAssertEqual(controller.windowCapture, .off)
        controller.enableScreenCapture(demo: true)
        await controller.refresh(demo: true)
        XCTAssertEqual(controller.windowCapture, .allowed)
        controller.openSettings("Privacy_Accessibility", demo: true)
        XCTAssertTrue(probe.controlRequests.isEmpty)
        XCTAssertTrue(probe.captureRequests.isEmpty)
        XCTAssertTrue(probe.settings.isEmpty)
        XCTAssertTrue(controller.installed)
    }

    func testDemoCaptureDoesNotEnableControlOrContaminateLiveStatus() async {
        let probe = Probe(), controller = CuaPermissionsController(client: probe.client(), demoInitiallyAllowed: false)
        controller.enableScreenCapture(demo: true)
        await controller.refresh(demo: true)
        XCTAssertEqual(controller.windowCapture, .allowed)
        XCTAssertEqual(controller.hostAccessibility, .off)
        await controller.refresh(demo: false)
        XCTAssertEqual(controller.windowCapture, .off)
        XCTAssertEqual(controller.hostAccessibility, .off)
    }

    func testSettingsFailureProvidesHostRecoveryAndSuccessfulGrantDoesNotOpenSettings() async {
        let probe = Probe(), controller = CuaPermissionsController(client: probe.client())
        probe.opensSettings = false
        controller.enableScreenCapture(demo: false)
        XCTAssertTrue(controller.message?.contains("msgblast access") == true)
        probe.control = true
        probe.capture = true
        let settingsCount = probe.settings.count
        controller.enableHostAccessibility(demo: false)
        controller.enableScreenCapture(demo: false)
        XCTAssertEqual(probe.settings.count, settingsCount)
        XCTAssertEqual(controller.hostAccessibility, .allowed)
        XCTAssertEqual(controller.windowCapture, .allowed)
    }

    func testDesktopOnboardingUsesNativeConnectionsWithoutBrowserImportOrCLISetup() throws {
        var state = OnboardingState()
        state.chooseConnector(.apps)
        state.selected = [.museApp, .grokBotApp, .wabi, .geminiApp, .chatgptApp, .dotsApp, .claudeApp]
        XCTAssertTrue(state.selected.allSatisfy { OnboardingConnector.apps.includes($0) })
        XCTAssertTrue(state.selected.allSatisfy { !OnboardingConnector.clis.includes($0) })
        state.begin()
        XCTAssertEqual(state.stage, .connecting)
        XCTAssertTrue(state.pendingWebProviders.isEmpty)
        XCTAssertEqual(Set(state.pendingSteps), [.agent(.museApp), .agent(.grokBotApp), .agent(.wabi), .agent(.chatgptApp), .agent(.dotsApp), .agent(.claudeApp)])
        XCTAssertTrue(state.selected.contains(.geminiApp), "Preserve deferred saved choices without adding a connection step")
        let reopened = try JSONDecoder().decode(OnboardingState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(reopened.selected, state.selected)
        state.complete(.museApp); state.skip(.grokBotApp); state.skip(.wabi); state.skip(.geminiApp); state.skip(.chatgptApp); state.skip(.dotsApp); state.skip(.claudeApp)
        XCTAssertEqual(state.stage, .feedback)
        XCTAssertTrue(state.hasConnectedAgent)
    }
}
