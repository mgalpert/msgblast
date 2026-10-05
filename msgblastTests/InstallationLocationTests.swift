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
