# Browser login onboarding evidence

Captured application source: `b3e4a297956066f90fe3848e8ddf2061970a4d15`.
Initial task base: `5cd8a394f28f37eab71359645810421da2fa19d5`.
Integrated upstream main: `9d9b978435717dd38b32a30c3c5ab4b219e5706d`.
The following evidence-only commit changes no application code or build settings.

The native captures use the blue **msgblast Browser Import Demo** app, copied
from the packaged Demo preview and given a unique identity so other running Demo
builds cannot receive its UI actions. Its bundle ID is
`com.msgblast.browser-login.demo`, its support directory is
`msgblast-BrowserLogin-Demo`, Demo and onboarding preview are enabled, and
production updates are disabled. Its source revision and source file hashes are
recorded in `capture-manifest.json`. Ad-hoc strict signature verification passed.

The actual CUA interactions selected ChatGPT and Claude, opened browser import,
chose Chrome's synthetic Demo profile, verified the ready ChatGPT fixture,
returned to setup, chose Safari's synthetic signed-out profile, verified the
manual sign-in pane with Continue disabled, and clicked the local fixture
sign-in button to reach Ready. The two removed controls/copy lines are absent.
These are native macOS screenshots, not generated mockups. No mobile UI changed.

`workflow.mp4` is a playable 24-second H.264 sequence assembled from the native
screenshot samples captured around those interactions. It scales and pads the
images, repeats frames, omits the Back/chooser interval, and edits playback
timing. It is not a continuous real-time recording. No interface text or pixels
were drawn into the captures. It has no audio.

All accounts and cookies in the screenshots/video are synthetic. No live browser
store, Keychain prompt, OS permission grant, provider sign-in, Messages send,
Contacts write, paid model request, or production app update was exercised.
The Dev preview was built and signed but was not launched. Actual provider
acceptance of Chrome/Safari sessions in WebKit remains unverified. The pinned
Safari parser does not expose SameSite or partition metadata.

## Validation

- The first full native core run passed 280 tests. The expanded full run executed
  283 tests; one existing Dots sprite/colour test failed and passed unchanged on
  a focused rerun. No assertion was weakened.
- The final integrated run passed 71 native core tests (including browser import,
  onboarding, report integration and the repaired session cases) and both new
  onboarding UI workflows.
- The broader onboarding UI run passed 11 of 12 tests. The existing unchecked
  Szn assertion also fails on the unmodified initial base in a separate archived
  checkout. It is not a browser import regression.
- The encrypted Chromium fixture exercises the pinned reader with a synthetic
  cached key and validates version24 host binding, without browser/Keychain
  access. WebKit registration retains HttpOnly, domain scope and SameSite.
- All 79 Python fixture/tooling tests passed. Web comparison/broadcast,
  configured CLI and personal-agent shutdown/controller fixtures passed.
- Default Debug, explicit universal Debug and isolated Dev/Demo packaging passed.
  Debug targets now match SwiftPM's active-architecture default; Release retains
  universal settings. Production icon resources were preserved.
- Completed code review: `20261010-101704-c4d100f9`, with no open actionable
  findings. The draft/reload and profile replacement findings were fixed and
  proved with tests that failed before the repairs and passed afterward.

The local test logs and review receipt remain outside the repository. This
record describes those observed runs; it is not a claim about future CI or live
provider authentication.
