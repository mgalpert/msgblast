# PR 75 publisher verification, 2026-10-25

Implementation/Evidence-SHA: cd5237b0a1de969a2400e7e73f84861a23fa194f
Base-SHA: 7676362e87e1097fa2cf933a045da8d724923bf8

The loopback report button runs the real publisher regression module from the
clean implementation checkout. Eleven checks passed. The full Python suite
passed 114 tests with one skipped (113 executed). Actionlint 1.7.12 passed using
the repository runner-label configuration; git diff --check passed.

Synthetic archives and substituted signing/notarization, lipo and GitHub calls
exercise deterministic rejection and orchestration contracts. This is tooling
evidence, not an application packaging/signing/notarization success claim.
The video is a sequence of 24 actual browser captures spanning the run button,
execution result, and scrolling; replayed at 3 fps with edited timing, 8 seconds,
H.264, 1280x720. No audio. Screenshots are unedited browser captures.

On the authorized dedicated Studio Mac, scripts/test_app_permissions.sh compiled
the real Settings controller and passed nine boundary regressions with simulated
OS responses. Full Xcode is absent: xcodebuild -version reports that the selected
CommandLineTools directory is not Xcode. No native app package or UI interaction
was validated there; production apps, drafts, and grants were not changed. The
shared Studio lock was acquired for that check and released afterward. No
signing secrets, production release, permission grants, live sends, feedback
uploads, or paid calls were used. Native Actions validation is tracked in the PR.

The first hosted approved testing prerelease remains a post-merge activation
check, documented in docs/testing-builds.md. It cannot be replaced by these
fixtures. Real universal packaging and Studio interaction remain required before
claiming that validation complete.
