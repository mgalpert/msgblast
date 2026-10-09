# Build a New Feature evidence

Source revision: `40b6a9703ebb51f2bd5394e0d42fbc74df159bf6`.
Base revision: `aab8857b99967936b36c7b609ed67883e3c81fbf`.

Captured October 9, 2026 on Apple Silicon macOS from a clean committed source
build. `scripts/build_preview_apps.py` built, signed, packaged, extracted, and
verified both preview variants. Only the blue **msgblast Demo** was launched,
with `--demo --isolated-demo`; the green production artwork remained unchanged.
The manifest records a local run, not an Actions run or distributed release.

## Screenshots

- `01-invitation.png`: the new native invitation opened from the app menu.
- `02-idea.png`: a sample idea appears in the generated coding-agent prompt.
- `03-copied.png`: Copy Prompt confirms success with the idea retained.
- `04-pasted-prompt.png`: the actual clipboard pasted into the idea field to
  verify the full string; this is a test technique, not a recommended user flow.
- `05-help-reuse.png`: Help → Build a New Feature reuses the window and idea
  after editing resets the copy confirmation.
- `06-contribution-instructions.png`: the prompt scrolled to its final build,
  validation, screenshots/video, and PR instructions.
- `07-reopened-keyboard-copy.png`: closing and reopening clears the idea;
  Return copies the placeholder prompt.
- `08-build-guide.png`: the updated source build guide rendered on GitHub at
  the exact source revision above.

`clipboard-verification.txt` is the native accessibility result for the fixture
paste. No pre-existing clipboard text was read. The browser capture contains the
changed guide, not an unrelated tab. Mobile screenshots do not apply to this
native macOS window. These captures use dark appearance at the default size;
light appearance and minimum-size layout were not established by this run.

## Video

`workflow.mp4` is a playable H.264 video assembled from actual native interaction
screenshots. Timing is edited: each state is held for 3–4 seconds. It is a sampled
walkthrough, not continuous screen recording. It follows screenshots 01–07 in
order, showing entering an idea, copying, pasting the full clipboard content,
editing/resetting, Help-menu reuse, scrolling the instructions, and fresh-window
keyboard copy. The menu popups themselves are outside these window captures;
their entries and actions were verified through native accessibility.

## Validation

- Native core: 242 tests passed on the feature implementation.
- Python tooling: 79 tests passed.
- Final `build-for-testing` passed after the copy-state simplification and
  Help-menu test coverage change.
- Final committed Dev/Demo packaging, signatures, extracted archives, source
  metadata, and icon checks passed; see `preview-manifest.json`.
- Manual committed Demo checks passed for idea inclusion, full clipboard paste,
  editing resets Copied, Help reuses one window and preserves the idea,
  close/reopen clears it, Return copies, and the prompt scrolls to its final text.
- The Build guide link opened the exact expected public GitHub URL in Aside.
- The new XCTest UI regression compiled but did not execute: XCTest timed out
  enabling macOS automation mode. Compilation and manual checks are reported
  separately; no passing automated UI suite is claimed.

The documentation phase additionally checked local links/anchors and 28 shell
blocks, Worker tests and deployment dry runs, and configured CLI/report/web
fixtures. Its dated verification record retains an earlier intermittent native
failure and unchanged focused pass; that older run is not called a full pass.

No real Messages, Contacts writes, provider requests, production permission
changes, or app release were used to capture this evidence. The local preview
displays development defaults `0.4.3 (1)`; source identity is the revision above.
