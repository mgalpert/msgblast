import AppKit

/// The lifecycle fixture compiles `AppUpdater.swift` without the rest of the app. Its Debug-only
/// launch hook asks the design fixture for an appearance; this binary never takes those arguments.
@MainActor enum DesignFixture {
    static func appearance() -> NSAppearance? { nil }
}
