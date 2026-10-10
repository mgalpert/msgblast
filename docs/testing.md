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
```

- Web fixtures compile actual app/controller code with local website/Messages
  substitutes, checking comparison and broadcast lifecycle.
- Configured CLI fixtures invoke the real adapter with a deterministic local
  executable and temporary configuration. They test new/resumed sessions,
  configuration transport, denied writes, restricted reports, and legacy history.
- Report fixtures exercise the actual controller with lifecycle/storage
  substitutes, including delayed discovery, shutdown, and persistence.

No installed provider CLI, credential, paid request, real Messages send, or live
connector is used. These do not prove current service authentication, provider
configuration interpretation, or live resumption. The configured CLI script can
export fixture `requests.jsonl` to an optional second directory for evidence;
label it as fixture input/output.

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

- **Linux:** installer/dependency setup, Python tooling tests, download Worker
  tests, and Wrangler dry-run.
- **Native (`xcode-27`):** core tests and isolated Sparkle update fixtures. It checks
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
