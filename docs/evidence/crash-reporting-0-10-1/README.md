# Crash reporting validation after 0.10.1

App source: `27ef612cdc6c08b2be045cac39a6f8d2c19d1cc6`. Base:
`132d964f4977f5acd7533e9e81447035ed9b73e9`. Later evidence commits do not change
the native app source. The previous `crash-reporting/` evidence is historical.

Built with full Xcode 27 in an isolated derived-data directory. Packaged the
final Debug product as blue Demo with a task-specific bundle ID, name, support
profile and loopback endpoint; re-signed all nested code and verified the complete
bundle. The compiled AppIconDemo artwork was inspected. Production, Dev, their
profiles, and OS permissions were left intact.

Pal’s Studio ran `com.msgblast.pr80-current-demo`, using only the synthetic
`--crash-report-preview` and a local Node server around the actual Worker handler.
The 0.9.0 (40), stack and incident are fixture values. No installed app was
deliberately crashed; no production feedback was submitted. Zero requests before
Send; two identical requests and one stored object after Retry. The server holds
acknowledgements to make closing during a send deterministic, and returns a
simulated 503 after the first durable write.

Actual screenshots show review, sending, reopened frozen retry and confirmation.
`workflow.mp4` is continuous ScreenCaptureKit footage of Send, close, Help reopen,
retry and receipt. It is cropped to the Demo windows and shown at 2x speed
(82 seconds become 41 seconds), with no audio. The menu bar itself lies outside
the crop. This is not a screenshot sequence. Final-frame and full decode checks
passed; unrelated desktop content is excluded.

Native core: 706 passed, one Accessibility-dependent skip, no failures. An earlier
quiet run was interrupted before completion; the verbose complete run passed.
All 15 Worker tests and all 121 Python tooling tests passed with the existing
pinned installer environment. Five isolated Sparkle updater scenarios passed. The controller fixture compiles the real app-view
source and exercises the actual handler over loopback, including preserved
confirmation after closing and refresh/draft isolation. New closure coverage
failed against the old close behavior before the repair. Release phase tests
exercise the actual command entry point with synthetic build/signing/storage;
the workflow ordering guard failed against the prior publication order.

The native XCTest UI runner failed to initialize automation mode before test
assertions. No permission changes were made to force it; manual native Cua
inspection on Pal’s Studio and controller coverage are reported separately.

The compatible handler was bundled against the authoritative landing site’s
existing routes in an isolated dry-run. That dirty website checkout was not
modified. Deployment remains required before releasing the native feature.
The production publisher, Actions symbol upload and a real OS-generated app or
helper crash were not executed for this validation.
