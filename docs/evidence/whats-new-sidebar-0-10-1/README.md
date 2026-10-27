# Sidebar footer validation

Captured October 25, 2026 on Pal’s Mac Studio from source
`348edcc25e1e23ae25ce96bc7609381b8c6d2ec5`, after merging base
`132d964f4977f5acd7533e9e81447035ed9b73e9`. Subsequent evidence-only commits
do not change the rendered Swift source.

The preview packager built the committed source with full Xcode 27. The blue
Demo was copied with a task-specific bundle ID (`com.msgblast.pr82.demo`),
support directory (`msgblast-PR82-348edcc`), display name, and light-appearance
metadata, then ad-hoc re-signed and verified. Updates and telemetry stay disabled.
Production, Dev and their saved profiles were left intact.

Forty synthetic comparisons exercise the real overflowing native sidebar.
Verified scrolling to the final rows, the opaque footer and separator, opening
release history, closing with Done, the unread-to-viewed accessibility value,
and a compact window. No prompt was submitted. The displayed 0.9.0 version is
the preview’s project default, not a claim about the installed production release.
Current screenshots cover light appearance; older dark evidence is not reused
as proof of this revision.

`workflow.mp4` is a continuous 23-second ScreenCaptureKit recording at original
speed, cropped to the exact Demo window to exclude unrelated desktop content.
It shows scrolling both ways and opening/closing release history. It is not
a screenshot sequence. All screenshots are actual target-window captures.

The two-line styling change uses AppKit’s semantic window background. No
implementation-text or pixel-snapshot unit test was added. Existing release
history tests cover ordering, highlights and unread behavior; current PR CI
provides native core validation. Code review completed without findings
(lite path; no reviewer agents). No release or production deployment ran.
