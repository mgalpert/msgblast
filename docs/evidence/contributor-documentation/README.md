# Contributor documentation verification — October 9, 2026

Documentation was upgraded on `codex/contributor-documentation`, starting from
upstream main at `aab8857b99967936b36c7b609ed67883e3c81fbf`. The application,
scripts, workflow configuration, and generated project were unchanged. The
documentation changes were working-tree edits during these checks.

Environment: Apple Silicon macOS, Xcode 27.0 (27A5218g), Python 3.14.7,
Node.js 22.23.0, and the lockfile's Wrangler 4.147.0. These are observations of
this verification environment, not new exact tool-version pins.

## Results

| Check | Result and scope |
| --- | --- |
| Local Markdown links/anchors | All checked contributor, integration, operations, and historical entry documents resolved |
| Shell examples | 28 shell blocks passed syntax checks; destructive/publishing examples were not executed |
| Project generation | Temporary regeneration matched both committed project/scheme files byte for byte; the checkout was unchanged |
| Dev/Demo preview packaging | Passed; both variants built, ad-hoc signed, packaged, extracted, and passed strict signature/icon checks |
| Python tooling suite | 79 tests passed |
| Download Worker | 7 Node tests passed; Wrangler deployment dry run passed |
| Feedback handler | 12 Node tests passed; pinned Wrangler dry run passed |
| Configured CLI fixtures | Passed: new/resumed sessions, denied action, restricted report policy, and retained legacy sessions |
| Report controller fixtures | Passed: shutdown race and final-save/persistence cases |
| Web controller fixtures | Passed: model comparisons, draft-flush quit behavior, broadcast/update lifecycle, and controlled request shutdown |
| Native core suite | 242 tests executed; one test failed with six assertions; see below |
| Focused native rerun | The failed test passed unchanged in isolation |

The preview script used source SHA metadata and the explicit run label
`Local documentation verification (no Actions run)`, writing to
`build/documentation-preview`. This is a local build, not an Actions artifact or
release. No app was launched, installed, or published by the packaging check.
The canonical source icons remained unchanged. Worker checks were dry runs and
did not deploy either service. Controller/CLI fixtures used deterministic local
inputs rather than provider accounts or paid requests.

## Intermittent native failure

The full native unit command used `build/documentation-tests`,
`MSGBLAST_APP_BUNDLE_IDENTIFIER=com.msgblast.contributor-tests`, and `AppIconDemo`.
The failure was:

`MultiWebAgentTests/testContentEditableSpacingDoesNotStopSharedSubmission`

For Claude, Grok, and ChatGPT fixtures, submission returned `notSent` rather than
`observed`, with no recorded user message. Each provider produced two failed
assertions. The other unit cases passed. The same test then passed unchanged
when rerun alone using the same derived data and build settings.

The full run is **not** recorded as a passing suite. A focused pass does not
establish that the whole suite is reliable. The failure's cause remains
unresolved; investigation belongs to web-fixture/test behavior, not a documentation
rewrite. Application/test source was unchanged during both runs.

No native UI tests or live account/permission flows were run for this documentation
change. Textual validation is not screenshot/video PR evidence; a documentation
PR should show the actual updated guides and relevant setup/terminal workflow
following [Contributing](../../../CONTRIBUTING.md#screenshots-and-video).
