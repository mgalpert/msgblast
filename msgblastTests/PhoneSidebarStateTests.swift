import XCTest
@testable import msgblastCore

final class PhoneSidebarStateTests: XCTestCase {
    func testAutomaticCollapsesOnlyForAConnectedPairedPhone() {
        XCTAssertTrue(PhoneSidebarState.isCollapsed(preference: .automatic, enabled: true, paired: true, connected: true))
        XCTAssertFalse(PhoneSidebarState.isCollapsed(preference: .automatic, enabled: false, paired: true, connected: true), "Off shows the switch")
        XCTAssertFalse(PhoneSidebarState.isCollapsed(preference: .automatic, enabled: true, paired: false, connected: false), "Unpaired shows the QR code")
        XCTAssertFalse(PhoneSidebarState.isCollapsed(preference: .automatic, enabled: true, paired: true, connected: false), "A paired phone that is away stays visible")
    }

    func testExplicitPreferenceWinsOverTheAutomaticRule() {
        XCTAssertTrue(PhoneSidebarState.isCollapsed(preference: .collapsed, enabled: false, paired: false, connected: false))
        XCTAssertTrue(PhoneSidebarState.isCollapsed(preference: .collapsed, enabled: true, paired: false, connected: false))
        XCTAssertFalse(PhoneSidebarState.isCollapsed(preference: .expanded, enabled: true, paired: true, connected: true))
        XCTAssertFalse(PhoneSidebarState.isCollapsed(preference: .expanded, enabled: false, paired: false, connected: false))
    }

    func testPreferenceStorageValuesAreStable() {
        XCTAssertEqual(PhoneSidebarPreference.automatic.rawValue, 0)
        XCTAssertEqual(PhoneSidebarPreference.expanded.rawValue, 1)
        XCTAssertEqual(PhoneSidebarPreference.collapsed.rawValue, 2)
        XCTAssertEqual(PhoneSidebarState.preferenceKey, "sidebarPhoneCollapsed")
    }

    private func wantsOffer(collapsed: Bool = false, enabled: Bool = true, running: Bool = true, paired: Bool = false, locked: Bool = false, loadError: Bool = false) -> Bool {
        PhoneSidebarState.wantsOffer(collapsed: collapsed, enabled: enabled, running: running, paired: paired, locked: locked, loadError: loadError)
    }

    func testWantsOfferOnlyWhileAnUnpairedExpandedSectionCanShowIt() {
        XCTAssertTrue(wantsOffer())
        XCTAssertFalse(wantsOffer(collapsed: true))
        XCTAssertFalse(wantsOffer(enabled: false))
        XCTAssertFalse(wantsOffer(running: false))
        XCTAssertFalse(wantsOffer(paired: true), "A paired phone never gets an automatic offer")
        XCTAssertFalse(wantsOffer(locked: true))
        XCTAssertFalse(wantsOffer(loadError: true))
    }

    func testStatusMapping() {
        XCTAssertEqual(PhoneSidebarState.status(enabled: false, connected: false), .off)
        XCTAssertEqual(PhoneSidebarState.status(enabled: false, connected: true), .off)
        XCTAssertEqual(PhoneSidebarState.status(enabled: true, connected: false), .on)
        XCTAssertEqual(PhoneSidebarState.status(enabled: true, connected: true), .connected)
    }
}
