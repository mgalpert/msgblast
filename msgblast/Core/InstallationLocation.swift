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

public enum AppBundleIdentity {
    public static let production = "com.msgblast.mac"
    public static let development = "com.msgblast.development"

    /// Development previews use `com.msgblast.development` or a named sibling such as
    /// `com.msgblast.development.remote`. They all count as development builds.
    public static func isDevelopment(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier == development || bundleIdentifier.hasPrefix(development + ".")
    }
}

public enum SupportDirectory {
    /// Production stays `msgblast`. Demo stays `msgblast-Demo`. A preview may set
    /// `msgblastSupportDirectory` to another `msgblast-…` folder; anything else is ignored.
    /// Live web previews keep their existing `MsgBlast-WebPreview` folder unless that override is set.
    public static func folderName(demo: Bool, override: String?, webPreview: Bool = false, bundleIdentifier: String? = nil) -> String {
        if let override, let safe = sanitized(override) { return safe }
        if webPreview {
            return bundleIdentifier == "com.msgblast.web-preview"
                ? "MsgBlast-WebPreview"
                : "MsgBlast-WebPreview-" + (bundleIdentifier ?? "local")
        }
        return demo ? "msgblast-Demo" : "msgblast"
    }

    public static func sanitized(_ raw: String) -> String? {
        guard raw.range(of: #"^msgblast-[A-Za-z0-9][A-Za-z0-9-]{0,40}$"#, options: .regularExpression) != nil else { return nil }
        return raw
    }
}
