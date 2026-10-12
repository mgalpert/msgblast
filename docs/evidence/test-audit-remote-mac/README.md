# Test audit and remote Mac workflow evidence

## Current native workflow capture

Captured source: `1a5634ef1bef3aaedb664aaf1b0b2a62a30fabda`.
Base: `1d8d2ac158dfc5aed529d187e334d6d48a7e0786`.
[Exact-source GitHub run](https://github.com/mgalpert/msgblast/actions/runs/38298390935).

`native-grid.png` is the retained XCTest screenshot after reordering Claude ahead
of ChatGPT while keeping the unsent draft. `native-drafts.png` is frame 98 from the
seven-chat recording, showing all three native private draft fields after the
real outer scrollbar moved them into view. The test then narrows seven chats to
three and restores seven, checking each draft remains unchanged.

`native-workflows.mp4` contains the complete 30.98-second grid recording followed
by seconds 68–110.23 of the seven-chat recording. It shows actual mouse reordering,
scrollbar dragging, typing, resizing, and the resulting retained drafts. Clips
were trimmed and concatenated at normal playback speed, encoded at 30 fps; no
interaction was reconstructed. The 73.23-second video has no audio.

This is the isolated native UI test build (`com.msgblast.ui-validation-tests`),
with Demo artwork and explicit `--demo --isolated-demo` data. Cedar, Lumen and Orbit
and their replies are synthetic. It is not a live account session, a production
app build, or evidence that a personal SSH/Fleet Mac has run the tests.

The run passed 357 core tests and 35 UI tests with no UI failures, skips or expected
failures. Core/updater/permissions/controller, Linux and preview jobs all passed.
The Linux tooling run had 99 passes and one optional installer-serialization skip;
both Workers passed 25 tests. Every one of the 35 UI cases retained its automatic
MP4. The result bundle is the authoritative assertion record; capture provenance
and media hashes are in `native-capture.json`.

The following commit adds only evidence. Its PR `Evidence-SHA` identifies the
reviewed branch head; the tested app and test sources remain those captured above.

## Historical terminal fixture capture

These older files retain their original revision and limits. They are not the
current native workflow evidence or proof of personal runner enrollment.


Captured code revision: `4e6f77083af8b0b46ba0e5e0b4744d93ca62b817`.
Base revision: `1d8d4763fbc388cd3c6244057d3c97b00ddf1dd5`.

`remote-runner.png`, `workflow.png`, and `workflow.mp4` render actual recorded
subprocess output from that committed source. `terminal-events.json` retains the
commands, output, elapsed event timestamps, and fixture limits. Playback pauses
were added for readability; the video is a terminal transcript, not a desktop
screen recording or a real remote Mac test run.

The recording shows remote-runner dry-run selection with explicit Xcode/Python,
twelve SSH/worker orchestration
tests, 21 preview tests, and 13 download tests passing. SSH is substituted with
local transport fixtures; the worker uses fake native commands. Preview codesign
commands are intercepted against synthetic Mach-O files. The download tests use
local signed feeds and injected fetch/timeout responses. No native Mac tests,
real signing, production requests, or deployments are shown or implied.

The full lightweight baseline also passed: 95 Python tests with one installer
serialization test skipped for missing optional installer libraries, plus 25
Node tests. Native core/controller/updater results belong to the linked GitHub
validation run in the PR; they must not be inferred from these fixture captures.

A first live SSH preflight stopped because Apple's Python was older than 3.11.
The user then authorized the other MacBook: its Homebrew Python 3.14 is ready,
and a subsequent Xcode cache transfer was stopped at the user’s request. The
user is handling the macOS/Xcode update. A full personal SSH native run is not
shown in these fixture captures. No native tests
ran on the initiating user's desktop. See `docs/remote-mac-testing.md` for the
dedicated host prerequisites and result format.

The first GitHub run on `8440e7fcaacad044d59e936032ac545bdfb07128` passed 344
native core tests, updater fixtures, and simulated permission checks. Its
controller step failed because `rg` was absent. The captured revision repairs
source discovery with Python; its regression failed before that fix and passes
after it. The PR records fresh GitHub/native results separately.

The evidence-only commit adds these media and notes; it changes none of the
demonstrated code. PR `Evidence-SHA` identifies the current reviewed branch head.
