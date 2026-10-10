# msgblast updates

Historical October 2 implementation plan and evidence. Current contributor
validation is in [Testing](../testing.md); current updater/publishing guidance is
in [Updates](../updates.md) and [Automated releases](../automated-releases.md).
This record is not a new release instruction or proof of the current branch.

## Goal Capsule
Use Sparkle 2.10.0 and its standard native UI to update installed msgblast bundles safely. Match the Flo State workflow: daily checks, automatic update preference, release notes, Install on Quit and Install and Relaunch. Preserve the live primary checkout and app.

## Product Contract
- Updates run only in configured application bundles. Ordinary demos, permission previews, unbundled SwiftPM runs and XCTest must never query or install production updates.
- Settings exposes automatic checks, automatic downloads/install-on-quit, current version/build and Check for Updates. Preferences belong to Sparkle, not a duplicate store.
- Production feeds/archives use HTTPS and archive Ed25519 verification. No invented production host/key; unconfigured development builds explain that updates are unavailable.
- Save app-owned drafts/attachment references before termination. Delay update-triggered termination while AppModel.busy, allowing existing submissions to finish without retrying them.
- Published releases require Developer ID Application signing, hardened runtime, notarization and stapling. Build numbers are explicitly increasing release counters, not Git counts.
- Release assets remain private until the user selects a distribution host. Private GitHub release URLs are not anonymously downloadable Sparkle feeds.

## Implementation Units
### U1. Native updater
Files: Package.swift, Package.resolved, scripts/generate_project.py, generated Xcode project/resolved packages, msgblast/Info.plist, msgblast/App/msgblastApp.swift, new updater/settings sources, msgblast/Core/UpdateConfiguration.swift, msgblastTests/UpdateTests.swift, narrowly scoped app termination support, existing menu UI regression.
Use SPUStandardUpdaterController with observed canCheckForUpdates and preference properties. Info.plist configuration uses SPARKLE_FEED_URL, SPARKLE_PUBLIC_ED_KEY, MARKETING_VERSION and CURRENT_PROJECT_VERSION build settings. Blank feed/key are the development default. Add a narrowly scoped DEBUG-only local updater fixture/probe for isolated real Sparkle installation tests. Verify policy and termination behavior through focused tests and actual runtime.

### U2. Release tooling
Files exclusively: scripts/release.py, scripts/tests/test_release.py, docs/updates.md, release-notes/0.1.0.md.
Build and export via xcodebuild archive/exportArchive using Developer ID, include explicit version/build/feed/key configuration, notarize/staple, package with ditto, run Sparkle sign_update/generate_appcast and verify artifacts. Prepare locally, without automatically deploying or making the private repo public. Have a dry-run and reject missing credentials/insecure URLs/nonincreasing counters. Document installing the first updater-enabled app in /Applications and credentials/static HTTPS hosting needed. Unit tests prove the actual command plan/configuration and failures. Do not build shared targets while U1 edits them.

### U3. Integration verification and evidence
Files: scripts/test_updates.py, focused native tests if needed, docs/evidence/updates/**, README.md.
Build in this worktree only. Exercise real signed old-to-new update, signature rejection, no-update and failed-download cases using temporary app bundles/data and a localhost feed. Preserve a draft and attachment through installation/relaunch. Verify the native settings and standard Sparkle prompt and capture actual screenshots/short video, labeling all local synthetic fixtures. macOS-only UI: mobile screenshot is not applicable. Run relevant core/controller and native regressions. Never send real messages, modify real Contacts, replace the primary app, or reset its permissions.

## Verification Contract
Policy tests reject ordinary previews/demo/invalid or absent production configuration; configured real apps accept HTTPS and valid public keys. Update lifecycle tests prove busy waits and failed save cancels termination. Release tests prove signing/notarization are required and explicit increasing build counters feed the bundled metadata. Real Sparkle local signed installation must advance the bundled build; invalid archive signatures must not install. Native controls reflect persisted preferences; actual standard update dialog and result have screenshot/video evidence.

## Definition of Done
U1/U2/U3 work complete and local checks/evidence recorded; simplify and independent code review applied; changes committed on codex/sparkle-updates and delivered via a private GitHub PR with Screenshots and Video sections. Production deployment is not authorized until signing credentials and distribution host are provided; clearly document that prerequisite rather than pretending a live update service exists.

## Execution evidence
- U1 and U2 implemented; Sparkle 2.10.0 resolves through Xcode and SwiftPM. Full Xcode suite passes 55 checks (46 core/controller and nine native workflows), zero failures/skips; 11 mocked release tests pass.
- Real signed localhost fixtures pass installation/relaunch to build 2, deterministic busy postponement, no-update, invalid archive signature and HTTP download failure. Draft and staged attachment references/content survive.
- Actual native Settings and standard Sparkle download/install/relaunch were captured under docs/evidence/updates. Version changes from 0.1.1 (1) to 0.1.2 (2); toggled update preferences, draft and attachment persist. Screenshot video uses condensed pauses and synthetic fixture data, labeled in evidence README.
- Simplification removed duplicate release validation, streamed release ZIP hashing and bounded discarded Xcode build output; updater reads Sparkle’s current availability directly.
- Production Developer ID credentials, notarization profile, long-lived Sparkle key and HTTPS distribution host remain operator prerequisites. No production upload, application replacement, real message send or Contacts write occurred.
- SwiftPM full tests encounter the pre-existing Xcode-only PermissionGuideLifecycleTests referencing MessagesAccessGuide outside the core target. Xcode is the authoritative full test runner; no test was disabled to hide this limitation.
