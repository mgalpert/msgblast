# Testing and evidence

Run checks that exercise the changed behavior. Use local fixtures first; record
the tested revision, command, result, and limits. Building/testing is separate
from releasing an app or deploying a Worker. See [Build from source](build-from-source.md)
for prerequisites and [Contributing](../CONTRIBUTING.md) for PR evidence.

## Choose checks by change

| Change | Relevant checks |
| --- | --- |
| Documentation only | Verify paths/links/anchors and commands against scripts/workflows; demonstrate any newly documented setup command when feasible |
| Models, routing, persistence, provider behavior | Native `msgblastTests`; add/update a meaningful regression when behavior changes |
| Windows, menus, composers, or attachments | Native tests plus affected fixture UI tests/manual Demo interaction, screenshots, and video |
| Web/CLI orchestration and cancellation | Native tests and relevant web/configured-CLI/report controller fixtures |
| Updater or distribution | Native tests, `test_updates.py`, Python tooling tests, and relevant preview/packaging checks |
| Download Worker | `npm test --prefix download` and its dry-run check |
| Feedback schema/handler | Native diagnostic/submission tests, Python diagnostics tests, and Node feedback fixtures |
| Project, helper, or icons | Regenerate/review project; build previews and verify packaged metadata, compiled icons, helper, and signatures |

Pure documentation changes do not require new application unit tests. Verification
should check the actual instructions and affected workflow rather than mirror prose
in a test. Broaden testing only when changes or failures justify it.

## Native core tests

From the repository root on a Mac with Xcode 27:

```sh
xcodebuild -project msgblast.xcodeproj -scheme msgblast \
  -configuration Debug -derivedDataPath build/contributor-tests \
  -destination 'platform=macOS,arch=arm64' \
  MSGBLAST_APP_BUNDLE_IDENTIFIER=com.msgblast.contributor-tests \
  ASSETCATALOG_COMPILER_APPICON_NAME=AppIconDemo \
  -only-testing:msgblastTests test
```

This runs the unit target, not the UI suite. Existing tests use controlled data,
SQLite databases, transports, and executable fixtures. Inspect a test's setup
before running it. A selected blue icon by itself is not Demo mode.
For a focused regression, append the test class or method to `-only-testing:`.
Use a unique `-resultBundlePath` when retaining an `.xcresult`; Xcode refuses an
existing destination. Do not remove someone else's results to reuse a name.

Useful targets include routing/state in `CoreTests`, `MessagesDatabaseTests`, and
`AttachmentTests`; provider/chat behavior in `WebServiceTests` and
`MultiWebAgentTests`; permissions/installation, CLI detection/reports, Grok Bot,
diagnostics/feedback, and updates in their named test files.

## Controller and executable fixtures

These require a built Debug `msgblastCore.framework` in the selected derived-data
directory. The native test command above builds it. Web fixtures also need its
Sparkle package artifact. From the repository root:

```sh
bash scripts/test_web_comparisons.sh build/contributor-tests
bash scripts/test_configured_cli_conversations.sh build/contributor-tests
bash scripts/test_personal_agent_shutdown.sh build/contributor-tests
bash scripts/test_crash_reporting.sh build/contributor-tests
```

- Web fixtures compile actual app/controller code with local website/Messages
  substitutes, checking comparison and broadcast lifecycle. They also verify
  that feedback is sent only on explicit submission, unchanged retries reuse
  their request ID, and failures retain the form and workspace draft. A matching
  receipt closes feedback and restores the workspace. All feedback transport is
  intercepted by a local URLProtocol fixture; no report is uploaded.
  Native CI also runs these fixtures, including same-store app restarts that
  check all five permissions, retain setup and drafts, remember Skip for now,
  and resume Allow access after a Settings handoff. Injected grants do not
  prove real macOS consent.
- Configured CLI fixtures invoke the real adapter with a deterministic local
  executable and temporary configuration. They test new/resumed sessions,
  configuration transport, denied writes, restricted reports, and legacy history.
- Report fixtures exercise the actual controller with lifecycle/storage
  substitutes, including delayed discovery, shutdown, and persistence.

The crash fixture also needs Node.js 22. It runs the actual review session and
intake handler over loopback with synthetic reports, including an uncertain
acknowledgement after storage and an identical retry after reopening.

No installed provider CLI, credential, paid request, real Messages send, or live
connector is used. These do not prove current service authentication, provider
configuration interpretation, or live resumption. The configured CLI script can
export fixture `requests.jsonl` to an optional second directory for evidence;
label it as fixture input/output.

`bash scripts/test_app_permissions.sh` needs only the macOS Swift SDK. It compiles
the actual Settings permission controller with injected native responses and a
minimal model substitute. It verifies checks without consent, explicit Enable
requests, denied recovery, changed access, Messages launch failure, and demo
isolation without reading user data or requesting a real OS grant.

The six shipping integrations (Muse, Grok Bot, Wabi, ChatGPT, Dots, and
Claude) use `DesktopNativeWindowLookup`. Its tests in `DesktopAppConversationTests`
simulate an empty macOS `AXWindows` list, verify exact process/window identity,
reject wrong-window/control candidates, and bound fallback discovery. Each app
has a named `FindsOtherDesktopAndRejectsAmbiguousMainWindows` regression in
`DesktopAppDriverTests`: an off-screen main window is accepted, helper/login
windows are ignored, and a second main window on either desktop blocks selection.
The native adapter executable fixtures also enumerate windows on another Space,
covering connection checks, saved chat identity, drafts, and submission receipts.
Run both desktop classes plus the ChatGPT, Gemini, and Claude conversation/driver
classes (including `ChatGPTAppSubmissionTests`) when changing this shared path.

These fixtures do not create or switch real macOS Spaces and inject native
observations; they cannot prove every installed app's current AX implementation.
For an authorized live check, leave an app on another desktop and connect it from
msgblast; verify readiness while the active desktop and existing draft stay
unchanged. Do not send a prompt solely to validate window discovery.

`OnboardingTests.testOnboardingOffersNativeAppsAndRetainsLegacyWebCheckpoints`
covers the offered catalog and resumable older setup state. `WebAgentInstanceTests`
covers new-user website opt-in, disabled sends, Settings toggles across reload,
and preservation of existing website identity/history. The Demo UI regression
`OnboardingWorkflowTests.testNativeChoicesReplaceWebAlternativesInOnboarding`
checks the actual chooser.

For manual Demo capture without command-line launch arguments, Debug Demo builds
also recognize `msgblastOnboardingPreview`, `msgblastIsolatedDemo`, and
`msgblastOnboardingPermissionsPreview` Boolean bundle settings. The last setting
starts simulated app-control and capture access off. Combined with the existing
`msgblastPermissionGuidePreview`, Messages history is also simulated unavailable,
so Continue stays blocked until a complete permission group is enabled. These
settings never change macOS access and are ignored for live app-control grants.
Label captures as simulated and retain the compiled source revision.

## Remote control

`msgblastRemoteProtocolTests` (encode/decode round trips, framing limits, the
encryption envelope with known-answer vectors checked against OpenSSL and Python)
runs in the native command above, or alone with
`-only-testing:msgblastRemoteProtocolTests`. The Mac side is in `msgblastTests`:
`RemoteIdentityTests`, `RemotePairingTests`, `RemoteAvailabilityTests` (every
provider form and readiness state from fixture sessions, without connecting or
launching), `RemoteProjectionTests`, `RemoteCommandExecutorTests`, and
`RemoteServerTests` (handshake, pairing, resume, lock, and replacement over the
in-memory transport). None opens a port.

`bash scripts/test_web_comparisons.sh <derived-data>` also runs the remote fixture:
commands through the actual AppModel send paths and the real `RemoteService` with an
in-memory phone, in the isolated Demo profile. Set `MSGBLAST_REMOTE_EVIDENCE_DIR` to
render the actual Settings → Remote pane off-screen into PNGs.

`bash scripts/test_remote_client.sh <derived-data> [evidence-dir]` is the end-to-end
check over real TLS: the Demo profile listens on this Mac's Tailscale or LAN
address for that run only, and `scripts/remote_client` pairs with the pinned key,
reads the snapshot, sends to a simulated Messages agent, and resumes. It needs a
Tailscale or private LAN address and opens a port while it runs; it sends nothing
real. It does not prove reachability from a phone on another network.

### Phone app

The phone's logic tests (`msgblastMobileTests`: connection state machine against a
fake Mac over an in-memory transport, the reducer against fixtures recorded from
the Demo Mac, the store, and presenters) run without a simulator:

```sh
xcodebuild -project msgblast.xcodeproj -scheme msgblastMobileKit -configuration Debug \
  -derivedDataPath build/mobile-macos -destination 'platform=macOS,arch=arm64' test
```

The same bundle runs in a simulator with `-scheme msgblastMobile -destination
'platform=iOS Simulator,name=iPhone 17' test`. Re-record its fixtures with
`bash scripts/record_mobile_fixtures.sh <derived-data>` (Demo profile, simulated
lock; the Mac's name is replaced with "Demo Mac"). There are no phone UI tests yet;
[Remote control](remote-control.md#ux-iteration-against-the-demo-mac) lists the
manual simulator check.

#### Design review fixtures

Debug builds of the phone app open on simulated screens without pairing or any
network when `MSGBLAST_FIXTURE` is set: `inbox`, `conversation`, `conversation-short`, `conversation-pinned`,
`conversation-many`, `typing`, `incomplete`,
`blocked`, `new`, `settings`, `reconnecting`, `locked`, `pairing` or `pairing-paste`. The fake Mac is
named "Studio Mac"; the data is built in `msgblastMobile/Debug/DesignFixtures.swift`
and compiles out of Release. `MSGBLAST_FIXTURE_CONVERSATION=<uuid>` opens a
particular conversation, and `MSGBLAST_FIXTURE_DRAFT=<text>` pre-fills its composer so
Send shows (simctl cannot type); `MSGBLAST_FIXTURE_FOCUS=1` focuses the field so the
keyboard opens, `MSGBLAST_FIXTURE_EMOJI=1` opens the emoji keyboard,
`MSGBLAST_FIXTURE_DICTATION=1` shows the dictation glyph even without a microphone, and
`MSGBLAST_FIXTURE_DETAILS=1` opens a conversation's Details sheet,
`MSGBLAST_FIXTURE_FILTER=claude,museApp` selects agents in the header, and
`MSGBLAST_FIXTURE_REPLY=1` starts a reply. Further fixtures: `conversation-pinned` (the
pinned prompt row) and `conversation-many` (six agents). Build the Debug app for a simulator, install it, then:

```sh
SIMCTL_CHILD_MSGBLAST_FIXTURE=conversation xcrun simctl launch --terminate-running-process <udid> com.msgblast.ios
xcrun simctl io <udid> screenshot build/design-review/conversation.png
```

The reconnecting subtitle explains itself only after 20 seconds, so wait that long
before capturing `reconnecting`. Scan Code is disabled in the simulator, which has
no camera scanner.

## Shared native app engine

`DesktopAccessibilityTests` covers exact draft/URL metadata, bounded incomplete
reads, Gemini virtualized sidebar references, and isolation from embedded foreign
ChatGPT web content. Raw attribute fixtures exercise the production conversion,
including string-valued URLs, native AX error slots, and exact text/geometry.
A test-owned local WebKit editor also exercises native capture when the test host
already has Accessibility access. It skips without requesting or changing access
when that grant is absent; record that skip separately from fixture passes.
`DesktopAppWorkflowTests` covers multiline/Unicode entry,
foreign draft refusal, stopping after failed readback, read-only transition
recovery, nonzero reply-stability intervals, and single submission through reply recovery. Existing per-profile
adapter fixtures retain destination, sender, nonce, draft and uncertain-send
assertions. They exercise the common workflow, not copies of its implementation.
Muse's cold-start connection regression supplies multiple inconsistent native
composer reads before a stable result. Recovery is read-only and bounded to five
seconds; a readable unsent draft still blocks connection immediately.

The seven retained `FindsOtherDesktopAndRejectsAmbiguousMainWindows` cases also include
Claude's layer-1000 full-display overlay with membership in multiple Spaces. The
same fixture still rejects a second real layer-zero window on either desktop.

## Embedded app-control runtime

`EmbeddedCuaDriverTests` exercises private daemon startup, shared concurrent
connections, observed host identity rejection, shutdown during startup, socket
cleanup, host-grant generation changes, startup grant races, and missing-helper/
timeout failures without using a global driver.
`CuaPermissionsTests` checks host-only grants and revocation without requesting
real OS access; `OnboardingTests` covers complete permission-group readiness.

After a Debug build, this read-only integration check uses the actual bundled
helper and a temporary ad-hoc signed host app:

```sh
bash scripts/test_embedded_cua_runtime.sh build/contributor-tests
```

It verifies the driver's observed parent application and PID, exercises the default
native adapter's private-socket routing and permission-response decoding, and checks
shutdown cleanup. A second, explicitly simulated run verifies that the default
adapter requests `tree_format=elements` and decodes its structured snapshot.
Neither run requests permissions, starts provider apps, or sends messages.
It proves runtime attribution metadata, not approval retention across signed
updates or live provider delivery. Packaging/release checks are available with
`python3 -m unittest scripts.tests.test_bundle_cua_driver scripts.tests.test_release`.

## Native UI tests and manual checks

Use an authorized Mac with an interactive desktop and native runner permissions.
The UI tests explicitly pass `--demo` and `--isolated-demo`; inspect the test when
selecting a case. This example runs the existing menu fixture:

```sh
xcodebuild -project msgblast.xcodeproj -scheme msgblast \
  -configuration Debug -derivedDataPath build/contributor-ui-tests \
  -destination 'platform=macOS,arch=arm64' \
  MSGBLAST_APP_BUNDLE_IDENTIFIER=com.msgblast.contributor-ui-tests \
  ASSETCATALOG_COMPILER_APPICON_NAME=AppIconDemo \
  -only-testing:msgblastUITests/WorkflowTests/testApplicationMenuProvidesStandardActions test
```

Select affected cases in `WorkflowTests` or `WebServiceWorkflowTests`. A compiled
UI target, a locked desktop, or an automation-permission failure is not a passing
interaction test. Do not bypass permissions or reset system grants for evidence.

Inspect the actual changed workflow in packaged **msgblast Demo**: keyboard
navigation, focus, resizing/narrow windows, relevant light/dark appearance, draft
retention, reopen/relaunch when persistence changes, and meaningful error states.
Capture screenshots and a short playable video from the reviewed revision. For
responsive web changes, also inspect desktop/mobile sizes. See the contribution
guide for upload/access requirements. Fixture evidence does not establish live
Messages, website, account, or permission behavior; record deliberate live checks
separately when authorized.

## Isolated updater tests

For updater changes, run:

```sh
python3 scripts/test_updates.py --derived-data build/contributor-tests
```

The harness uses isolated apps, temporary feeds/archives, signatures, and update
probes. It does not publish to the production host or replace the installed app.
It does not prove production Apple signing/notarization, R2 configuration, or real
TCC permission retention. Read [Updates](updates.md) before changing its behavior.

## Python and backend checks

Python tooling tests use the standard library and controlled temporary fixtures:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -p 'test_*.py' -v
```

For the download Worker, install its pinned npm dependencies once, then run:

```sh
npm ci --prefix download
npm test --prefix download
npm run check --prefix download
```

`check` runs `wrangler deploy --dry-run`; it builds/validates the Worker and does
not deploy. See the [Wrangler command reference](https://developers.cloudflare.com/workers/wrangler/commands/)
and the installed version's `deploy --help`. No production publishing credential is needed for the documented
local checks. These tests do not measure completed downloads or installs.

Feedback fixtures need Node.js but no npm dependency install:

```sh
node --test feedback/worker.test.mjs
```

They use in-memory R2 and rate-limit substitutes. They prove validation/retry/error
behavior, not live bindings or production storage. Keep private feedback out of PR
media. A handler/schema change also needs coordination with the separate landing
Worker; see [feedback operations](../feedback/README.md).

## Ubuntu and cloud agents

Ubuntu can run the Python and Node checks, but cannot build or inspect the native
Mac app, exercise its OS permissions, or record its UI. The cloud install command
is `bash scripts/cloud-agent-install.sh`; it installs a pinned installer virtualenv
and the download Worker dependencies. On a Mac, ordinary preview builds do not
need that Linux installer command. See [Cloud agents](cloud-agent.md).

## What GitHub Actions checks

`.github/workflows/validate.yml` runs on PRs, pushes to main, and manual dispatch:

- **Linux:** installer/dependency setup, Python tooling tests, feedback/crash intake tests, download Worker
  tests, and Wrangler dry-run.
- **Native (`xcode-27`):** core tests, crash consent/retry controller fixtures, and isolated Sparkle update fixtures. It checks
  out the PR branch head and retains test logs/results for 14 days.
- **Preview:** same-repository `cursor/*` PR branches or manual dispatch build
  signed Dev/Demo ZIPs and a manifest; artifacts last 14 days. Ordinary fork PRs
  do not automatically get preview ZIPs.

The workflow does not run native UI tests or capture PR interaction video.
`pr-evidence.yml` separately checks remote media structure and Evidence-SHA.
It cannot judge what the media actually shows. Fork CI can require approval or
the maintainers' configured runner; pending/unavailable checks are not passes.
Do not dispatch `release-adhoc.yml` as a test.

Record the source SHA, tool versions when relevant, exact command, pass/fail result,
and fixture/live limits in the PR. For documentation workflows, a link check and
verified build command are more useful than a screenshot of an unrelated app.

The [October 9 documentation validation record](evidence/contributor-documentation/README.md)
includes verified commands and an intermittent web-editor test failure: the full
native suite failed one test, which passed unchanged on a focused rerun. This is
dated evidence, not a current suite-pass guarantee.

## Named agent checks

`WebAgentInstanceTests` covers copies with shared and separate browser sign-in
stores, independent bot receipts and private follow-ups, saved names and
comparison membership, legacy selection, and preservation of a malformed
instance registry. Its cookie test uses newly created isolated WebKit stores,
not browser cookies from an installed account. Bot responses are simulated;
no live routine, provider request, or tunnel is started.

`AgentGridWorkflowTests/testDuplicateWebAgentCreatesIndependentRecipientAndCanBeRenamed`
checks the actual Duplicate/Rename sheets and independently selected tiles in
an isolated Demo session. Change reasoning in the embedded website manually;
this feature does not automate or verify provider model settings.

## Business choice fixtures

`BusinessChoiceTests` and `MessagesDatabaseTests` cover archived quick replies/list pickers, read-only database access, source identity, stale cards, exact conversation/question matching, native control grouping, and durable no-repeat attempts. The web comparison controller fixture also exercises simulated selection and persistence through the real app model.

For manual evidence, launch the packaged blue Demo with `--isolated-demo --business-choices-preview`, select Poke and send the sample prompt. Its reply includes **Find Plumbers** and **Not Now**. Choosing one creates a simulated response and disables further selection; it never invokes Apple Messages.

Live native action requires the exact app's Accessibility permission. Inspecting native controls without pressing them verifies only their availability; Demo and matcher fixtures do not establish real Business submission or delivery. Preserve the user's active Business choices unless they authorize that live selection.

For private-send scrolling evidence, launch the blue Demo with `--isolated-demo --no-demo-replies`. This keeps automatic simulated replies from moving the transcript after submission. The native UI regression sends a long reply through Cedar's own composer and checks that its end is visible without manual scrolling. The AppKit controller fixture covers overflowing joined panes and a late tapback; it does not reproduce the real composer timing failure by itself.

Gemini is deferred: its compatibility fixtures remain, but public session tests
prove saved state survives while connection, configuration and sending stay blocked.
