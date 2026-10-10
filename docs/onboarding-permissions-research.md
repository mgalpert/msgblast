# Codex-style permission onboarding research

Historical design research, preserved with its original source revisions and
validation limits. For current permission behavior and contributor setup, use
[the README](../README.md#get-started), [Build from source](build-from-source.md),
and [Testing](testing.md). Recommendations below are not new permission grants.

Researched October 1, 2026. Source inspection only; no permissions were changed and no live drag-to-Settings test was performed. The Mac was locked during this research.

## Identified repository

[riko2chen/AskForPermission](https://github.com/riko2chen/AskForPermission) is a strong match for the project described by the user. Its README explicitly compares its flow to Codex Computer Use onboarding: a card moves from the triggering button to beside System Settings, offers the host app as a draggable row, and follows the Settings window. This verifies the repository's stated inspiration; it cannot prove which repository the user previously saw.

Inspected revision: `91f4dde33f9f5dd58a89d72f3f05aa4b149a1f0e`.

The [MIT license](https://github.com/riko2chen/AskForPermission/blob/91f4dde33f9f5dd58a89d72f3f05aa4b149a1f0e/LICENSE) permits adaptation, including commercial use, with the copyright and permission notice retained in copied code or substantial portions. The package targets macOS 13 or later and Swift 5.9, according to its README.

## Verified mechanism

| Element | Exact source | What it does |
| --- | --- | --- |
| Real app drag | [DraggableAppIconView.swift](https://github.com/riko2chen/AskForPermission/blob/91f4dde33f9f5dd58a89d72f3f05aa4b149a1f0e/Sources/AskForPermission/Drag/DraggableAppIconView.swift) | AppKit `NSDraggingSource`; creates `NSDraggingItem(pasteboardWriter: bundleURL as NSURL)` and a row snapshot preview. The payload is the actual app bundle URL, rather than an image or text. Offers `.copy`, and reports drag completion separately from permission status. |
| Settings destination | [PermissionKind.swift](https://github.com/riko2chen/AskForPermission/blob/91f4dde33f9f5dd58a89d72f3f05aa4b149a1f0e/Sources/AskForPermission/API/PermissionKind.swift), [SystemSettingsOpener.swift](https://github.com/riko2chen/AskForPermission/blob/91f4dde33f9f5dd58a89d72f3f05aa4b149a1f0e/Sources/AskForPermission/SystemSettings/SystemSettingsOpener.swift) | `.fullDiskAccess` opens `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles` via `NSWorkspace`. This pane URL is an implementation convention, not a stable documented Apple permission-grant API. |
| Adjacent guide | [SystemSettingsWindowTracker.swift](https://github.com/riko2chen/AskForPermission/blob/91f4dde33f9f5dd58a89d72f3f05aa4b149a1f0e/Sources/AskForPermission/SystemSettings/SystemSettingsWindowTracker.swift), [flow controller](https://github.com/riko2chen/AskForPermission/blob/91f4dde33f9f5dd58a89d72f3f05aa4b149a1f0e/Sources/AskForPermission/Flow/PermissionRequestFlowController.swift) | Tracks Settings window metadata with `CGWindowListCopyWindowInfo`, waits for the frame to settle, and positions an `NSPanel` beside it. No Accessibility automation is involved in this mechanism. The tracker matches English owner names, so localized macOS needs verification. |
| Public integration | [API documentation](https://github.com/riko2chen/AskForPermission/blob/91f4dde33f9f5dd58a89d72f3f05aa4b149a1f0e/docs/api.md) | SwiftUI `.requestsPermission(.fullDiskAccess)` / `.askForPermission(item:)`, or AppKit `AskForPermission.request(.fullDiskAccess, from: view)`. Results distinguish authorized, cancelled, timeout, and unavailable. |

## Caveats that matter for msgblast

The [status model](https://github.com/riko2chen/AskForPermission/blob/91f4dde33f9f5dd58a89d72f3f05aa4b149a1f0e/Sources/AskForPermission/Status/PermissionStatusModel.swift) checks `~/Library/Safari/Bookmarks.plist` first, then `~/Library/Application Support/com.apple.TCC/TCC.db`, by opening read-only and closing. It returns true after the first successful open; permission errors fail early. This is a heuristic, and the public API does not expose a custom probe. A successful generic probe does not establish that msgblast can query Messages history.

The same model polls all six supported kinds every 0.75 seconds, even for a single Full Disk Access request. Developer Tools and App Management checks dynamically load [private TCC SPI](https://github.com/riko2chen/AskForPermission/blob/91f4dde33f9f5dd58a89d72f3f05aa4b149a1f0e/Sources/AskForPermission/Status/TCCPrivateSPI.swift). Those permissions and checks are unnecessary for msgblast. Merely requesting `.fullDiskAccess` does not prevent those other status checks from running.

[Apple's Privacy & Security guide](https://support.apple.com/guide/mac-help/mchl211c911f/mac) describes Full Disk Access as broad access, including other apps' data, and documents the **+ → select app → Open** fallback. The proposed drag is a convenience for adding the app. The user must still authorize it in System Settings, including any authentication or restart macOS requests. Dropping a file is not proof of authorization. Keep the manual fallback available if the pane deep link, drag target, tracking, or window positioning fails.

The project's [architecture document](https://github.com/riko2chen/AskForPermission/blob/91f4dde33f9f5dd58a89d72f3f05aa4b149a1f0e/docs/architecture.md) correctly excludes Contacts and Photos request-style prompts and per-target Automation from the app-drag pattern. Contacts should use `CNContactStore`; msgblast's first real send triggers Automation consent for Messages. Neither requires this draggable icon flow.

## Recommended msgblast adaptation

Adapt the MIT app drag and adjacent guide into a small Full Disk Access-only helper, with msgblast's existing native styling. Avoid importing the built-in six-permission checklist/status engine unchanged. An upstream custom capability probe and permission scope could also make a narrow package integration viable.

Use the running `Bundle.main.bundleURL` and `NSWorkspace.shared.icon(forFile:)`, rather than hardcoding `/Applications/msgblast.app` or dragging the executable, build folder, or mock image. Validate that it is a real `.app`; a command-line development launch needs a reveal/manual fallback. Stable app installation and signing identity matter for retained grants, especially because msgblast's current rebuilt ad-hoc app has previously required reauthorization.

After the user returns, call msgblast's existing `AppModel.refresh()`. Mark the step ready only after `MessagesDatabase` successfully opens `~/Library/Messages/chat.db` with `SQLITE_OPEN_READONLY` and queries the expected schema/chats. A failure must retain the user's draft and offer Check Again / Quit & Reopen as appropriate. Do not infer success from the drag callback, a timer, a screenshot of a switch, or the library's Safari probe.

The onboarding contact sheet is a proposed UI, not evidence of this workflow running. Before shipping, test an initially absent app entry, present-but-disabled entry, successful grant, cancellation, denied access, post-restart success, revocation, relocated app, localized Settings, Reduce Motion, Stage Manager, and multiple displays on the supported macOS versions.

An alternative public-API reference is MIT [PermissionPilot](https://github.com/arpitagarwal1301/PermissionPilot), whose [AppBundleDragSource.swift](https://github.com/arpitagarwal1301/PermissionPilot/blob/baaaff837052e3f8bec357a8a0dee48fa0364993/Sources/PermissionPilotUI/AppBundleDragSource.swift) also writes the bundle `NSURL` directly and explicitly distinguishes real file URLs from file promises. It is a useful fallback implementation reference, but its README does not establish the specific Codex-copy identification.
