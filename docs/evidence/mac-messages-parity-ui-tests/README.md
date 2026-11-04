# msgblastUITests on the Messages-parity conversation window

Evidence for the test-only update that follows the macOS conversation window
redesign (`codex/mac-messages-parity`, PR #95). The branch head is named in the
PR's `Evidence-SHA` line; the base is `76970a9f55babb5fbfc9e63c6706d5534d573932`.

## How the pictures were made

The selected `msgblastUITests` cases ran unattended with `xcodebuild … test-without-building`
(Debug, derived data `build/contributor-ui-tests`, bundle ID
`com.msgblast.contributor-ui-tests`, Xcode 27.0) on a dedicated Mac Studio where
the XCTest automation permission is granted. The tests pass `--demo --isolated-demo`
themselves: sample agents (Cedar, Lumen, Orbit, Maple, Echo, Flint), a temporary
store, no Messages database read, nothing sent, no app or provider contacted.

`03`, `08` and `09` are the tests' own `XCTAttachment` window captures. The other
stills and the video frames are XCTest's automatic screenshots from the same run,
kept by setting `systemAttachmentLifetime="keepAlways"` on that Mac's local copy of
the scheme only, then cropped to the app's window band (menu bar and Dock removed).
Every file is a Debug build of the Evidence-SHA tree.

| File | Case | Shows |
| --- | --- | --- |
| `01-remove-from-view-menu.png` | `testRemoveConversationFromViewPreservesDraftAndCanRestore` | "Remove from View" in Lumen's column header context menu, the draft in the one compose bar |
| `02-details-after-removal.png` | same | The Details popover after removal: Lumen listed with its recipient check off |
| `03-lumen-removed-window.png` | same | The window without Lumen's column; the draft is still in the compose bar |
| `04-close-prompt.png` | same | The close prompt answered with Keep Active and Close before the comparison is reopened from the sidebar |
| `05-private-reply-one-checked.png` | `testJoinedInputRoutesSelectedAndExcludedConversationsAndPreservesItsDraft` | Lumen and Orbit unchecked on their headers: the compose bar reads "Message Cedar" and the two replies reached Cedar only |
| `06-send-to-remaining.png` | same | Cedar unchecked, Lumen and Orbit checked, "Remaining recipients fixture" typed |
| `07-remaining-delivered-draft-kept.png` | same | Two copies delivered, "one retained draft" kept in the compose bar before the window-style switch |
| `08-private-reply-visible-window.png` | `testPrivateComposerRevealsEndOfLongMessageWithoutManualScrolling` | A long message sent with one agent checked ends above the compose bar without scrolling |
| `09-separate-windows-scopes.png` | `testSharedPrivateAndAllScopes` | Separate windows: Cedar's own window keeps its private field; the floating composer sends to all (locators unchanged) |

## Video

`walkthrough.mp4` (57 s, 2 frames per second) is the automatic screenshot
sequence of the three rewritten one-window cases in run order, duplicate frames
dropped: remove from view (menu, Details, close prompt, reopen), the joined
input (private reply to one checked agent, send to the remaining two, retained
draft, switch to separate windows and back), then the long private reply.

## Log

`ui-tests-dedicated-mac.log` is the run's `Test Case` and `Executed` lines
with local paths removed. Six of eight cases pass. The two failures are not
part of this change: `testManualAccountWithoutChatIsSavedButCannotReceiveTheSharedPrompt`
clicks an "Add agent" button that exists in neither the base nor this branch,
and `testMenuBarNewBlastRetainsSelectionsAndReopensWorkspace` times out opening
the Quick Access status-item menu on that Mac before any changed line runs.

## Limits

- Three `WebServiceWorkflowTests` cases that were updated
  (`testRemoveWebAgentFromViewPreservesConversationAndCanRestore`,
  `testSignedOutAgentOpensSetupAndKeepsPromptUntilUserSubmitsAgain`,
  `testEmbeddedMuseAndMessagesReceiveOneSharedPrompt`) could not run: the
  dedicated Mac has the Muse desktop app installed, so the Demo routes "Muse"
  through app setup instead of the website fixture and the Muse tile the cases
  select never appears. Their new locators compile but are unverified.
- `OnboardingWorkflowTests` (two cases, both pass) and `AgentGridWorkflowTests`
  were not otherwise exercised.
- Fixture evidence only: no live Messages, website, account or permission
  behavior is shown.
