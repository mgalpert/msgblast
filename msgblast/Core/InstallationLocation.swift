import Foundation

public enum InstallationLocation {
    /// Development builds remain runnable from Xcode. Downloaded and translocated
    /// copies must be installed before the app starts accessing Messages history.
    public static func needsInstallation(bundleURL: URL, homeURL: URL, development: Bool) -> Bool {
        let app = bundleURL.standardizedFileURL.resolvingSymlinksInPath().path
        let home = homeURL.standardizedFileURL.resolvingSymlinksInPath().path
        func inside(_ directory: String) -> Bool { app.hasPrefix(directory + "/") }
        if inside("/Applications") || inside(home + "/Applications") { return false }
        if !development { return true }
        return inside(home + "/Downloads") || inside("/Volumes") || app.contains("/AppTranslocation/")
    }
}
