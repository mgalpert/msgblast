# Grok Bot through Agent Desktop

The optional Grok transport uses [agent-desktop 1.0.2](https://github.com/vercel-labs/agent-desktop)
for app/window discovery, accessibility snapshots, ref clicks, text entry,
Shift-Return, and focus. It calls the existing `DesktopAppConversation` workflow:
unique bot selection, independent native draft/focus checks, foreign-draft refusal,
per-chunk readback, single submission, history hashes, reply stability, and saved
receipt recovery are shared with Cua. The direct Grok webhook integration and
other native apps retain their existing transports.

This is a **Debug-only opt-in**, not a production runtime migration. Release
builds ignore the environment switch. The standard bundled Cua helper remains
available. There is no automatic fallback between drivers after an uncertain
operation. Agent Desktop errors stop the action; the workflow never replays it.

## Try the alternate transport

Install the pinned CLI in a local build directory (the npm package includes the
native executable and macOS helper):

```sh
npm install --prefix build/agent-desktop-tool agent-desktop@1.0.2
build/agent-desktop-tool/node_modules/.bin/agent-desktop version
```

Build `msgblast Dev` using [the preview guide](build-from-source.md). Quit only
that preview if it is already running, then launch its executable with:

```sh
MSGBLAST_AGENT_DESKTOP_PATH="$PWD/build/agent-desktop-tool/node_modules/.bin/agent-desktop" \
  "build/contributor-preview/msgblast Dev.app/Contents/MacOS/msgblast"
```

Choose **Grok Bot App**, open the Bot menu, and choose the bot. This Dev app uses
live accounts; sending a prompt is a real request. Use the fixture benchmark
below for simulated sends. Demo remains simulated and does not invoke either
native transport. Removing the variable restores Cua on the next Dev launch.

The app still checks its own Accessibility and Screen Recording permissions.
Agent Desktop's host attribution and grant retention across signed updates need
separate validation before production adoption; a CLI launched from Codex does
not prove that packaged-app permission behavior.

## Reproduce the comparison

Run the native tests in [Testing](testing.md) to build `msgblastCore.framework`.
Include `AgentDesktopTransportTests`, `DesktopAppConversationTests`,
`DesktopAppDriverTests`, and `DesktopAppWorkflowTests`.

Install the Electron fixture runtime:

```sh
npm install --prefix build/grok-electron-fixture electron@45.2.1
node build/grok-electron-fixture/node_modules/electron/install.js
```

Run the fixture on an authorized interactive Mac. Pass a new output directory:

```sh
python3 scripts/benchmark_grok_transports.py \
  --agent-desktop build/agent-desktop-tool/node_modules/.bin/agent-desktop \
  --cua-driver build/contributor-tests/Build/Products/Debug/msgblast.app/Contents/Helpers/cua-driver \
  --electron-app build/grok-electron-fixture/node_modules/electron/dist/Electron.app \
  --products build/contributor-tests/Build/Products/Debug \
  --output build/grok-driver-comparison
```

For a separate recording, use a new output directory with
`--driver agent-desktop --record`. Keep recorded runs separate from latency
measurements: on this Mac, ScreenCaptureKit's title-bar recording indicator made
Cua 0.38.0 refuse exact-window focus (the 66 × 20 indicator was considered the
frontmost ordinary window). The failed run is not a latency sample.

The runner packages a separate **Grok Transport Fixture**, gives it a distinct
bundle ID and temporary profile, blocks network requests, and starts a private
Cua runtime. It refuses an already-running fixture rather than replacing it.
Only discovery is injected to point the real production Grok workflow at the
fixture. Both drivers perform real OS accessibility reads and native input.
The recorder captures only this fixture window, without audio. All subprocesses
owned by the runner are stopped when it finishes.

The scenarios cover bot discovery and switching; repeated prompts with distinct
simulated timestamps; Unicode, blank lines, leading newline and chunked text;
single submission and exact reply readback; serialized receipt recovery;
read-only setup with a foreign draft; refusing to overwrite that draft; and
sending to another bot while preserving it. Results include individual timings,
a summary, screenshots, and optionally a playable MP4. A failed scenario makes
the runner exit nonzero. Timings use a 100 ms poll and 300 ms stable-reply interval
for both drivers, rather than the production one/three seconds. Replies are
local simulations, so this does not measure provider latency or delivery.

For read-only timing on the installed Grok window:

```sh
python3 scripts/benchmark_desktop_observation.py \
  --agent-desktop build/agent-desktop-tool/node_modules/.bin/agent-desktop \
  --cua-driver build/contributor-tests/Build/Products/Debug/msgblast.app/Contents/Helpers/cua-driver \
  --samples 15 --output build/grok-observation.json
```

This alternates drivers on one exact window, excludes one warm-up per driver,
and saves timings/counts only. It does not save conversation text or screenshots.
Both observations request depth 40 and a ten-second deadline without screenshots.
Cua returns a compact tree; Agent Desktop returns more containers. Element counts
are not equivalent work. The acceptance check follows each driver's completeness
contract; Cua's `elements_complete: false` alone is not a truncation signal.

## Embedding and fork considerations

No fork is needed for this CLI experiment. The adapter translates the upstream
JSON tree while preserving ref tokens and hierarchy, and normalizes Grok's extra
trailing AX newline before draft comparison. It keeps the independent native
reader for exact bot identity, DOM metadata, focus, and draft preservation.

Each transport has a private 0700 temporary state root and one snapshot namespace,
separate from the user's Agent Desktop CLI state. It does not create a command
host per poll/send. Upstream command hosts currently idle out after 15 minutes;
they are not tied to msgblast's lifetime. A normal transport teardown removes its
own temporary files; abrupt app termination can leave temporary state behind.
The public CLI has no owned-host shutdown command. This differs from the current
Cua runtime's parent-lifetime pipe and is a production migration limitation.

Before making this the default, either integrate the upstream C library in the
app's process or add owned-host lifecycle/cleanup to a focused fork. Validate
signed helper packaging, host-only TCC attribution, revocation, cancellation,
and across-update grant retention. Keep the independent draft and no-resend
checks. Do not infer live delivery, all-Spaces behavior, or signed update behavior
from the local fixture. Offscreen accessible windows and ambiguity are covered
by transport fixtures; actual Spaces need an additional native test.

Agent Desktop is Apache-2.0. Electron is MIT with Chromium third-party notices.
Neither dependency is added to production app packaging by this experiment;
the fixture keeps Electron's shipped licenses in its copied app.
