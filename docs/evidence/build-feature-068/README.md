# Build a New Feature: 0.6.8 release preflight

Source-SHA: `90694d90b5002395ca98b2bb5f4241734be64220`
Base-SHA: `b0559167c53b9a9f004923ceb8ce8a8cc7dd6f80`

Captured October 9, 2026 on Apple Silicon macOS 27.2. The source includes the
published 0.6.7 onboarding/chat updates, the feature invitation, expanded guides,
active Developer ID release instructions, and 0.6.8 release notes. Latest main
merged without conflicts. The canonical green production artwork was preserved.

## Functional Dev preflight

The blue-green `msgblast Dev.app` was built and packaged from the committed source
above. It uses `com.msgblast.development`, `msgblast-Dev` support data,
`msgblastDemo=false`, and no production update feed. It ran without demo arguments.
Its ad-hoc signature has hardened runtime and the app's Address Book, Automation,
network-client and development library-validation entitlements. See the recorded
metadata, effective entitlements, signing checks and preview manifest.

Native computer use verified both menu entries, full prompt copying through an
actual paste assertion, idea inclusion, edit reset, Help reuse of one window,
prompt scrolling, close/reopen draft reset, and Return-to-copy. The idea is local
test text. No provider question, real message, Contacts write, new permission grant,
or production app replacement was used. No account/conversation content appears
in the captures. This verifies the changed invitation flow; it does not prove
production permission retention or runtime compatibility on older macOS versions.

## Screenshots and video

- `dev-01` through `dev-07`: functional Dev invitation, idea, copy, actual clipboard
  paste verification, Help reuse, contribution instructions, and fresh-window
  keyboard copy. Pasting into the idea field is a test technique.
- `demo-01` through `demo-03`: blue Demo invitation, fixture idea, and Copied.
  Demo ran with `--demo --isolated-demo` and simulated application state.
- `dev-workflow.mp4`: 25-second sampled Dev interaction walkthrough.
- `demo-workflow.mp4`: 9-second sampled Demo idea/copy walkthrough.

Both videos are playable H.264 assembled from actual native interaction captures,
with edited timing (3–4 seconds per state). They are not continuous recordings;
menu popups are outside the captured window and were checked through accessibility.
All captures use dark appearance at the default size. Mobile screenshots do not
apply to this native macOS feature. `0.4.3 (1)` is the preview's development default,
not the planned production release version. Source identity is the SHA above.

## Validation

- 264 native core tests passed; the test build also compiled the UI regressions.
- 79 Python tooling tests passed.
- 45 links/anchors in the changed release documentation resolved.
- Dev and Demo packaging, extracted signatures, source metadata and icon checks
  passed; their compiled icons differ as intended.
- Functional Dev computer-use preflight and fresh Demo idea/copy capture passed.
- Automated UI interaction tests were not run for this revision after the earlier
  XCTest automation startup timeout. Native compilation and manual checks are
  reported separately.

The production release uses the existing Developer ID/Apple notarization pipeline;
these local ad-hoc previews do not prove production signing or publication.
