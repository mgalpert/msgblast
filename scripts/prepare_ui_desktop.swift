// Prepare only an explicitly authorized test worker. Never run on a working desktop.
import AppKit
import CoreGraphics
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let environment = ProcessInfo.processInfo.environment
let checkOnly = CommandLine.arguments.dropFirst().contains("--check-only")
guard environment["CI"] == "true" || environment["MSGBLAST_REMOTE_TEST_WORKER"] == "1" else {
    fail("Use the explicit remote UI-test runner; no desktop settings were changed.")
}
let display = CGMainDisplayID()
guard display != 0 else { fail("Native UI tests need a desktop display.") }
let minimumWidth = 1440
let minimumHeight = 900
let bounds = CGDisplayBounds(display)
if bounds.width < CGFloat(minimumWidth) || bounds.height < CGFloat(minimumHeight) {
    guard !checkOnly else {
        fail("UI display mode did not survive preparation: \(Int(bounds.width)) × \(Int(bounds.height)).")
    }
    let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
    guard let modes = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode],
          let mode = modes.filter({ $0.width >= minimumWidth && $0.height >= minimumHeight })
            .min(by: { $0.width * $0.height < $1.width * $1.height }) else {
        fail("UI worker needs a display mode of at least 1440 × 900; current display is \(Int(bounds.width)) × \(Int(bounds.height)).")
    }
    // CGDisplaySetDisplayMode reverts when this helper exits. Retain the mode
    // for this dedicated worker's login session, without changing saved settings.
    var configuration: CGDisplayConfigRef?
    let begin = CGBeginDisplayConfiguration(&configuration)
    guard begin == .success, let configuration else {
        fail("Could not begin UI display configuration (error \(begin.rawValue)).")
    }
    let configure = CGConfigureDisplayWithDisplayMode(configuration, display, mode, nil)
    guard configure == .success else {
        CGCancelDisplayConfiguration(configuration)
        fail("Could not prepare the UI display mode (error \(configure.rawValue)).")
    }
    let complete = CGCompleteDisplayConfiguration(configuration, .forSession)
    guard complete == .success else {
        fail("Could not retain the UI display mode for the worker session (error \(complete.rawValue)).")
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
}
let visible = NSScreen.main?.visibleFrame.size ?? .zero
guard visible.width >= 1000, visible.height >= 780 else {
    fail("UI worker's usable desktop is too small: \(Int(visible.width)) × \(Int(visible.height)).")
}
print("UI desktop geometry: usable \(Int(visible.width)) × \(Int(visible.height)); interactive access still requires a passing UI run.")
