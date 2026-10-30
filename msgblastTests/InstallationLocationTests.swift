import XCTest
@testable import msgblastCore

final class InstallationLocationTests: XCTestCase {
    func testInstalledCopiesCanStart() {
        for path in ["/Applications/msgblast.app", "/Users/test/Applications/msgblast.app"] {
            XCTAssertFalse(needsInstallation(path, development: false))
        }
    }
    func testDownloadedCopiesCannotStartPermissionSetup() {
        for path in ["/Users/test/Downloads/msgblast.app", "/Volumes/msgblast/msgblast.app",
                     "/private/var/folders/example/AppTranslocation/id/d/msgblast.app"] {
            XCTAssertTrue(needsInstallation(path, development: true))
            XCTAssertTrue(needsInstallation(path, development: false))
        }
    }
    func testPreviewSupportDirectoriesStayOutOfProductionStorage() {
        XCTAssertEqual(SupportDirectory.folderName(demo: false, override: nil), "msgblast")
        XCTAssertEqual(SupportDirectory.folderName(demo: true, override: nil), "msgblast-Demo")
        XCTAssertEqual(SupportDirectory.folderName(demo: false, override: "msgblast-Dev"), "msgblast-Dev")
        XCTAssertEqual(SupportDirectory.folderName(demo: false, override: "../msgblast"), "msgblast")
        XCTAssertEqual(SupportDirectory.folderName(demo: true, override: "msgblast"), "msgblast-Demo")
        XCTAssertEqual(SupportDirectory.folderName(demo: true, override: nil, webPreview: true, bundleIdentifier: "com.msgblast.web-preview"), "MsgBlast-WebPreview")
        XCTAssertEqual(SupportDirectory.folderName(demo: true, override: "msgblast-Dev", webPreview: true, bundleIdentifier: "com.msgblast.web-preview"), "msgblast-Dev")
        XCTAssertNil(SupportDirectory.sanitized("msgblast"))
    }
    func testDevelopmentBundleIdentityAcceptsNamedDevelopmentSiblings() {
        XCTAssertTrue(AppBundleIdentity.isDevelopment("com.msgblast.development"))
        XCTAssertTrue(AppBundleIdentity.isDevelopment("com.msgblast.development.remote"))
        XCTAssertFalse(AppBundleIdentity.isDevelopment("com.msgblast.developmentremote"))
        XCTAssertFalse(AppBundleIdentity.isDevelopment("com.msgblast.mac"))
        XCTAssertFalse(AppBundleIdentity.isDevelopment("com.msgblast.demo"))
        XCTAssertFalse(AppBundleIdentity.isDevelopment(nil))
    }
    func testDevelopmentBuildsCanStartButUninstalledReleaseCannot() {
        XCTAssertFalse(needsInstallation("/Users/test/projects/build/msgblast.app", development: true))
        XCTAssertTrue(needsInstallation("/Users/test/projects/build/msgblast.app", development: false))
        XCTAssertTrue(needsInstallation("/Applications-copy/msgblast.app", development: false))
    }
    private func needsInstallation(_ path: String, development: Bool) -> Bool {
        InstallationLocation.needsInstallation(bundleURL: URL(fileURLWithPath: path),
            homeURL: URL(fileURLWithPath: "/Users/test"), development: development)
    }
}
