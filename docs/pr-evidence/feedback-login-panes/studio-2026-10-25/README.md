# Studio validation for PR #78

Base merged: `7676362e87e1097fa2cf933a045da8d724923bf8`.
Application runtime source: `fd1d4212b807ae01968de0f5b48ad111191cd234`.
Reviewed test source: `610e5bbd37e814c8256602dd477efe5db625e56a`.
The application, project, and build inputs are unchanged between those revisions;
the later commits strengthen controller and UI fixtures. This evidence commit
adds media/documentation only.

## Build and isolation

[Actions build](https://github.com/mgalpert/msgblast/actions/runs/40163878556)
completed its **preview** job successfully using Xcode 27.0. Both downloaded
archives matched their manifest hashes:

- Dev: `cf74607785b569652679232a4b195433ee234703bbf52d302629bc1cea6d9324`
- Demo: `8b8d2e563f654e3fd3bc01878d95a81d100fb0669a433faf0366528084807f6c`

Installed separate **msgblast PR78 Dev** (`com.msgblast.pr78.dev`) and blue
**msgblast PR78 Demo** (`com.msgblast.pr78.demo`) copies on the authorized Studio.
Only preview metadata was changed: distinct names, bundle identities, and support
folders. Demo alone adds a loopback feedback endpoint. Both were re-signed ad hoc
with the original entitlements retained, and passed `codesign --verify --deep
--strict`. CI also verified the compiled blue-green Dev and blue Demo artwork.
No installed production/Dev/Demo app or its profile was replaced. Dev fixture
mode is false; Demo fixture mode is true; updates and telemetry are disabled.
Demo launched with `--isolated-demo`; Dev received no fixture arguments.

All native GUI activity used CuaDriver 0.23.2 on Studio, serialized under the
PR78/PR75 lock. No permission was granted/reset, no real Messages were sent,
no paid/provider requests were made, and no production feedback was submitted.

## Observed Demo workflows

1. Enable Muse's website alternative in Settings, select Muse plus Cedar, Lumen,
   and Orbit, then sign out of the local Muse fixture.
2. Press Send & compare, dismiss the sign-in explanation, then sign in. The three
   selected Messages panes and original shared prompt remain present. There is
   no saved comparison or outgoing message before the explicit second Send.
3. Press Send & compare explicitly. Muse and the three Messages recipients each
   receive the simulated prompt, with native private reply composers present.
4. Open feedback, enter the synthetic note, and disable diagnostics. The local
   HTTP fixture receives **no request** from opening/editing/previewing the form.
5. Explicit Send receives HTTP 503. The feedback window, unchanged note, and
   diagnostic opt-out remain available. Retry receives a matching HTTP 201,
   closes the feedback window, and restores the conversation workspace.
6. The loopback server observed exactly two equal JSON payloads, with UUID
   `A8C69084-EF64-4520-AF1F-589F94914A3D`, kind `feedback`, and only the synthetic
   note. No contact or diagnostics were uploaded. The local server was stopped
   after this check.

All accounts, names, prompts, replies, submissions, and feedback responses shown
in Demo are fixtures. This does not establish live Messages delivery, provider
sign-in, or production feedback storage.

## Dev check and environment limits

The distinct live-mode Dev app starts at Allow access with all five grants
unavailable in its fresh profile. Without requesting permissions, opened Help →
Share Feedback, entered `PR78 Dev UI check. Local note only; do not submit.`,
disabled diagnostics, and manually dismissed feedback. The original Allow access
window remained available. No Send was pressed. `dev-feedback.png` records this
limited live-mode check; it does not prove the success callback against production.

Studio has Command Line Tools selected, Python 3.9.6 by default (3.13 also
available), and no full Xcode discoverable in Applications, common alternate
locations, or Spotlight. Therefore Studio-native builds and XCTest unit/controller/
UI execution could not run. Native CI is separate validation; no native/UI suite
was run on the user's active local desktop. The PR remains draft pending required
native validation and resolution of this environment limit.

## Media

- `signed-out.png`: Messages panes, recipients, and draft retained during sign-in.
- `signed-in-unsent.png`: signing in does not send the draft.
- `explicit-send.png`: explicit simulated submission into all four conversations.
- `feedback-failure.png`: failure retains the note and available retry.
- `feedback-success.png`: restored workspace after a matching receipt.
- `sign-in-short.mp4`: 27.97 seconds, actual sign-in and explicit send.
- `feedback-short.mp4`: 11.65 seconds, actual local failure/retry/window closure.

Screenshots are direct window captures. Videos are native screen recordings
cropped to the main Demo window; idle gaps are cut, playback speed is unchanged,
and audio is omitted. The edit JSON files record exact retained time intervals
and crop. Both videos were decoded without error and visually inspected.
