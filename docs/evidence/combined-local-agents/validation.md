# Combined local agents validation

Captured October 5, 2026 from merged source `f12eb1b`, which contains both
`d852a0d` and `533e40a`. The evidence-only commit does not alter app source.

Built with Xcode in `build/combined-validation`, selecting the blue
`AppIconDemo` resource. Captures use the isolated
`com.msgblast.combined-fixture` bundle, temporary app state, simulated accounts,
and synthetic replies. No live CLI login, setup, inference, real Messages send,
Contacts write, update publication, or installed-app replacement occurred.

## Results

- 107 Xcode unit tests passed, zero failures or skips.
- AppModel/WindowCoordinator fixtures passed comparison reopening, attachment
  follow-ups, and retry isolation without resending Muse.
- AppLifecycle fixtures passed quit/update deferral and single resumption after
  web and native sends complete; no updater or download started.
- Manual UI checks passed account rows, OpenClaw setup sheet and expanded
  details, native ChatGPT/Claude replies, saved-comparison reopening, and
  follow-ups retaining earlier turns in the accessibility transcript.
- The focused native-conversation UI test failed with “Failed to synthesize
  event: Timed out while synthesizing event.” This automation run did not verify
  the workflow; the manual captures document the exercised behavior.

## Capture sequence

1. Shared ChatGPT, Claude, OpenClaw, and Hermes account rows.
2. OpenClaw setup sheet, with Terminal action disabled in the demo.
3. Expanded installation details.
4. Shared prompt with only ChatGPT and Claude selected.
5. Native replies from both simulated providers.
6. New-comparison screen with the saved comparison in the sidebar.
7. Saved comparison reopened with both original replies.
8. Follow-up prompt in the same comparison.
9. Follow-up results; earlier turns remain in the scrollable transcript.

`walkthrough.mp4` is a 20-second step-capture video assembled from these actual
UI screenshots, held for two seconds per state. Timing is edited; it is not a
continuous screen recording and does not demonstrate provider latency.
The setup sheet is captured on its own surface. Native macOS app only;
mobile screenshots are not applicable.

Live provider authentication/session creation/resumption and authenticated
Muse/Grok website behavior remain unverified. Website chats and unrelated CLI
sessions are not imported. OpenClaw detection/setup does not connect its chat.
