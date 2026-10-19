# Gemini website and saved model validation

Validated on October 18, 2026. Final native captures use app source
`f2b0997caaa5099a490a0f8381314d787546cba1`, packaged as the blue **msgblast Demo
fixture** in an isolated macOS guest on the dedicated test Mac. The subsequent
commit changes evidence only. Production was not updated.

## Behavior demonstrated

- Apps onboarding includes Gemini, independently of Gemini CLI.
- **Model settings…** saves a model for the original Gemini agent.
- **Duplicate agent…** creates a separate Gemini agent with a different saved
  model while offering shared or separate sign-in.
- Agent tiles show saved model names, retain selection badges, and expose both
  selection and model to accessibility clients.
- One shared prompt reaches Flash and Thinking in different conversation pages.
- A fresh comparison reapplies both model choices; reopening the first comparison
  restores its original chats.

Models are discovered from the signed-in account's visible Gemini picker. The
saved ID and full label must match an available option. Selection is verified
through the menu's selected item; the observed button label is then checked
again before insertion and Send. This handles both full labels such as
`3.6 Thinking` and the observed abbreviated button label `Thinking`.
An unavailable or changed model stops that agent without silently falling back.
**Use website setting** explicitly leaves model selection to the website.

## Verification

- A saved-model regression failed before implementation: the old code ignored the
  saved choice and sent using the page's Flash model. It passed after selection
  was implemented.
- The final `WebServiceTests` and `WebAgentInstanceTests` run passed **40/40**
  tests on Xcode 27. All six Gemini tests passed. They exercise actual WebKit
  scripts and session persistence with local DOM fixtures: independent models
  and conversation URLs, reload of saved choices, new chats, unavailable models,
  model changes before Send, and preservation of private/prepared drafts.
- Earlier, four affected suites ran **170 tests**, with 169 passing. The new
  model-change test incorrectly read the snapshot from before insertion. An
  explicit refresh fixed that assertion; the final 40-test run above passed.
  The other 130 tests were not rerun after the last Gemini picker compatibility
  changes. This is not a claim of a final full-suite run.
- The final UI correction was compiled and packaged on the test Mac. Native
  interaction then repeated onboarding, model settings, duplication, two-model
  sending, a fresh comparison, and restoration of the first comparison.
- Final build inputs were compared against **276 committed source, test,
  resource and script files**, with no mismatches. Demo icon verification and
  strict ad-hoc signature verification passed.
- Final Demo ZIP SHA-256:
  `651deddd7df8ceef5ea0f24d6cd7ae2e8eb2930346b19472397a8ee8bdbf7031`.
- Independent code review found and fixed a reload edge case that could clear a
  newly chosen model, and verified the final selection-badge/accessibility
  correction. No actionable findings remain.

The focused native command used the project's Debug scheme and isolated test
bundle identity:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project msgblast.xcodeproj -scheme msgblast -configuration Debug \
  -derivedDataPath /tmp/gemini-validation-tests \
  -destination 'platform=macOS,arch=arm64' \
  MSGBLAST_APP_BUNDLE_IDENTIFIER=com.msgblast.gemini-tests \
  ASSETCATALOG_COMPILER_APPICON_NAME=AppIconDemo \
  -only-testing:msgblastTests/WebServiceTests \
  -only-testing:msgblastTests/WebAgentInstanceTests test
```

## Screenshots and video

[Onboarding](onboarding.png), [saved model settings](models/model-settings.png),
[duplicate with another model](models/duplicate-model.png),
[selected agent tiles](models/agents.png),
[two-model comparison](models/comparison.png), and
[fresh comparison](models/new-comparison.png) were captured from the final app
source named above. There is no mobile target.

[Play the 62-second native workflow](models/workflow.mp4). Actual macOS screen
recordings, with six chronological excerpts joined and pauses removed. Playback
speed is unchanged. The excerpts are seconds 10–24, 35–49, 70–78 and 137–148 of the
setup/comparison recording, then seconds 28–38 and 47–52 of the new-comparison
recording. This shows model setup, the independently configured copy, shared
submission, a fresh comparison and restoration. It is not one continuous take.

## Fixture and live limits

All native accounts, model-picker options, outgoing prompts, replies and thread
IDs in the evidence are **simulated**. A fixture reply naming a model is not
proof that a live model generated it. No real Messages, Contacts writes, paid
provider calls, permission resets or production-app replacement were used.

The authenticated in-app browser was used to inspect the current Gemini picker:
`3.6 Flash`, `3.6 Thinking` and `3.1 Pro`, their mode IDs and selected-item markup.
Two browser tabs retained different selected models. The original tab was
returned to its original Flash setting afterward. Earlier browser validation
also submitted small test prompts, started two different live thread URLs and
reopened the first.

**Still unverified:** authenticated Gemini model selection and prompt submission
inside the app's live WKWebViews, Google sign-in/cookie import there, and live
account-level preference propagation across simultaneous WKWebViews. Fixtures
and browser inspection do not establish those flows; the PR remains a draft.

The older `separate-thread.png`, `restored-thread.png` and `shared-prompt.mp4`
files retain the previous onboarding-only implementation's evidence. They are
historical and are not used as proof of the saved-model change.
