# GPTLive local development build

GPTLive is an app-wide OpenAI assistant with typed and live voice requests.
It can discover configured agents and saved conversations, read requested history,
navigate the app, select agents for a new conversation, manage drafts, switch
window layout, prepare multi-recipient messages and request conversation closure.
Sending and ending a conversation require explicit native review. Uncertain sends
are never automatically retried.

## Build and open

Use full Xcode 27, Python 3.11 or newer, and an Apple Silicon Mac. The first build
needs network access for the existing pinned Sparkle, cloudflared, and CuaDriver
dependencies. No API key or Apple signing credential is needed to build.

From the checkout, run:

```sh
DEVELOPER_DIR=/Users/pal/Applications/Xcode.app/Contents/Developer \
  python3 scripts/build_gptlive.py --variant development --output ..
# Open the timestamped .app path printed by the command.
```

The output is a runnable app, a ZIP, and a manifest, all named with the build’s
local date, time, and time zone. App and menu names include that timestamp.
The manifest records the checkout's HEAD as metadata; the build also includes current working
tree edits. `--sha FULL_COMMIT_ID` can supply metadata for source ZIP checkouts.
This is a local ad-hoc signed app, without notarization or publication.

The packager copies source to a temporary workspace, selects saved native icon
artwork there, reuses the standard helper checksum verification and signing
workflow, and verifies the packaged identity, compiled icon, helpers, and
signature. Production artwork stays unchanged. Existing output is preserved
unless `--replace` is passed, and the packager refuses to replace a running app.
Each normal invocation creates a new timestamped build; it does not overwrite
an older build. The bundle identifier and support folder stay stable, so updates
retain saved accounts, conversations, and the API key.

| App | Mode and icon | Bundle identifier | Application Support folder |
| --- | --- | --- | --- |
| `dev - gptlive - TIMESTAMP.app` | Live, blue-green | `com.msgblast.gptlive` | `msgblast-GPTLive` |
| `gptlive Demo - TIMESTAMP.app` | Simulated fixtures, blue | `com.msgblast.gptlive-demo` | `msgblast-GPTLive-Demo` |

Both apps disable production updates and telemetry uploads. Each has separate
preferences and saved state under `~/Library/Application Support`. The live app
uses real accounts and Messages when configured. Open it normally, without
`--demo` or `--isolated-demo`. Connect accounts and grant only the permissions
needed for your workflow to this app's identity; permissions can need renewed
approval after an ad-hoc rebuild.

For fixture interaction and simulated-send checks:

```sh
DEVELOPER_DIR=/Users/pal/Applications/Xcode.app/Contents/Developer \
  python3 scripts/build_gptlive.py --variant demo --output ..
# Open the timestamped Demo .app path printed by the command.
```

## Use GPTLive

Open **GPT-Live** from the toolbar or the app menu (⌘⇧L). Expand **OpenAI API key**,
enter your key, and use **Save key** to store it in macOS Keychain. The live and
Demo variants have separate Keychain services; timestamped rebuilds reuse their
variant’s service. Turn off **Remember in Keychain** for session-only use;
**Forget key** removes the saved key.
Keep the key out of source files, build arguments, screenshots, and logs. OpenAI
usage is billed to the key's account independently of any ChatGPT subscription.

No conversation needs to be selected before connecting. **Preview app state**
shows the current workspace, selected agents and draft state. After connecting,
try “Show my agents”, “Compare my recent conversations”, “Open Settings”, or
“Prepare a new message to Cedar and Lumen”. GPTLive discovers exact IDs through
structured tools and can work across conversations during the same session.

The 12 app tools cover state, agent and conversation discovery, verified history,
navigation, selection, workspace draft editing, prepared-message creation/editing/
discarding, window layout, and requesting conversation closure. Workspace edits
check the workspace identity, revision and prior text. Prepared-message edits
check their draft ID and revision so delayed actions cannot overwrite human edits.
Selection rejects unavailable, busy or conflicting agents before changing state.

Review the exact message, conversation and recipient list, then click **Send**.
Submission receipts do not prove delivery. Existing drafts and attachments are
preserved; conflicting drafts block sending. Browser history must be loaded at
the saved conversation address before it can be read. History is bounded by
encoded size, with truncation reported. Attachment contents are excluded.

### Debug mode

Click **Debug activity** at the top of GPT-Live. Summaries show connection events,
requests, tool calls, completion times, native actions and approvals, submission
receipts, errors, cancellation and usage. Microphone configuration records the
input format and whether Apple voice processing is enabled. Turn on **Debug mode**
to capture future
tool arguments and results as expandable details. Newest events appear first. Matching call IDs connect each request to its result. **Copy JSON**, **Export JSON…** and **Clear** act on the same
redacted log shown in the panel.

Activity stays in memory until the app exits: at most 500 entries / 512 KB, with
older entries evicted and oversized details marked as truncated. Details may
contain conversation text. Keys, authorization fields, credentials and raw audio
are redacted. Nothing is automatically saved to disk or uploaded. Enable Debug
mode before reproducing a problem; earlier details cannot be recovered.

The Demo app defaults to a fully simulated session. To exercise OpenAI with sample
data, turn off **Simulate GPT-Live** and supply a key. OpenAI requests are then real;
destination sends in the Demo app remain simulated.

The implementation uses [GPT-Live 1](https://developers.openai.com/api/docs/models/gpt-live-1),
the [Live WebSocket API](https://developers.openai.com/api/reference/resources/live/primary-websocket),
and [managed Responses delegation](https://developers.openai.com/api/docs/guides/live-delegation)
with GPT-6 Luna, following the official documentation checked on October 28, 2026.
Audio is mono PCM16 at 24 kHz; microphone input starts muted. Ending the session
closes the socket, releases audio resources, and displays final usage when supplied
by OpenAI. Failed or uncertain sends are never automatically retried.

GPTLive's OpenAI session and the destination accounts remain separate. OpenAI
reads requested app context and proposes actions and text; msgblast's existing account and
Messages permissions determine which destinations can actually receive it.

## Validation

The packaging regression checks use temporary fixtures and do not build an app:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.tests.test_gptlive_build -v
```

The controller integration fixture compiles the actual app sources and uses only
sample data:

```sh
DEVELOPER_DIR=/Users/pal/Applications/Xcode.app/Contents/Developer \
  bash scripts/test_gptlive.sh /absolute/path/to/DerivedData
```

Verification on this Mac:

- Native Xcode 27 build and 25 focused XCTest cases passed: Live protocol,
  tool continuations, redacted errors, audio framing, context limits, revision
  protection, debug retention/export/redaction and verified WebKit history.
- The full Python 3.11 script suite passed: 126 tests, 1 skipped, including all
  original 5 packaging regression tests. The microphone fix also passed all
  6 packaging checks, including timestamped names with stable data identity.
  Use full Xcode via DEVELOPER_DIR for the native architecture fixture.
- Production audio converter checks passed for stereo 48 kHz to mono PCM16
  24 kHz, byte order, mute, shutdown and bounded capture queue. No audio devices
  are opened by the default test. `bash scripts/test_gptlive_audio.sh --hardware`
  additionally exercised this Mac’s Jump Desktop virtual input/output, captured
  57,472 converted PCM bytes, played silence, stopped cleanly and restarted.
  It requires existing microphone authorization and saves/uploads no audio.
  The observed input was silent; human speech recognition requires a spoken check.
- The actual AppModel integration fixture passed app-wide tools, optimistic
  workspace/draft revisions, multi-recipient Messages and mixed browser/native
  simulated submissions, desktop-native planned broadcasts, receipts,
  draft/attachment preservation and teardown.
  `scripts/test_gptlive.sh` is the reproducible entry point.
- Native Demo GUI verification used real OpenAI calls to discover agents and
  conversations and stage a new Cedar + Lumen message. Only the native Send
  (simulated) action produced receipts. Debug Copy JSON produced 48 events with
  matching tool IDs, arguments and results, and no API key.
- Real OpenAI typed and synthetic spoken requests exercised the production Live
  transport, function calls and clean shutdown with final usage. The synthetic
  voice check returned 446,400 bytes of audio.

Xcode's testmanager-based launcher stalled on this machine; the compiled XCTest
bundle passed using Xcode's direct `xctest` runner. Native GUI checks use the running
app through Cua. Permission-dialog races, device changes, audible playback,
and delivery to real recipients are not covered by the microphone fixture. Account setup and macOS permissions belong to the
live app's separate identity.

The API returned `expired` after approximately 30 seconds during the native
checks. The app preserves prepared messages and exposes Connect again; it does
not automatically reconnect or resubmit. The official [session lifecycle guide](https://developers.openai.com/api/docs/guides/live-conversations) identifies
`expired` as a server session duration limit, without promising a fixed duration.

## Virtual audio devices

Apple voice processing failed to initialize with `com.apple.coreaudio.avfaudio
-10875` on this Mac’s eight-channel Jump Desktop microphone/output. Enabling it
succeeded, but starting the engine failed; rebuilding the graph in that process
did not recover the route. Virtual, aggregate and remote routes now bypass voice
processing before it is enabled. Ordinary capture still converts input to mono
24 kHz PCM16. Use headphones to avoid speaker echo on these routes.

Audio taps and playback callbacks explicitly use `@Sendable` so Swift 6 does not
incorrectly require Apple’s audio callback thread to be the main actor. The
hardware check reproduced the initialization failure and subsequent callback
assertion before these fixes, then passed capture, playback and restart afterward.
