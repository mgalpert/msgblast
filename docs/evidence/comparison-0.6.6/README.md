# Comparison and feedback fixes for 0.6.6

These captures show the actual native UI compiled from source `a8ae8e96e34d05c5a929fd231fa8271bebad467e`, after main's 0.6.5 Dots and Grok Bot changes were merged. The evidence commit adds documentation and media only. The app is an isolated blue Demo preview, version 0.6.6 (1). All prompts, HTML, replies and draft markers are local fixtures; no live provider, native Messages recipient or production feedback service was contacted.

## Verified workflow

- One shared click posts the original ask to Claude and Grok; a shared follow-up stays in both original chats.
- A -> B -> A restores A's replies, its unsent Grok draft and its separate shared draft.
- The comparison omits the extra chat count/navigation strip and persistent draft warning. Shared Send retains its draft guard and explains the available actions in its help text.
- A new ChatGPT recipient receives exactly `Suggest a short hiking route.\n\nKeep it under two hours.`. Its payload excludes the unsent private draft and generated joining instructions/labels.
- Feedback shows a fixed-footer receipt and disables the button as “Feedback sent”. The response was a matching HTTP 201 receipt from a localhost fixture, with diagnostics unchecked.
- The 0.6.6 notes thank [@schultetrevor](https://x.com/schultetrevor).

## Validation

[242 native tests, zero failures](native-tests.log) cover independent pages/drafts, manual-send recovery, receipt ownership, late replies, cache eviction, whitespace readiness, privacy, Dots' ongoing conversation and native Grok Bot routing. [App controller/lifecycle checks](controllers.log) cover ordered join context, native follow-up privacy, mixed providers and Quit draft saving. A final ten-lens local review admitted no actionable findings; the external peer transport could not start, so its adversarial lens used a local fallback. The review retains a nonblocking raw-whitespace assertion gap in the existing contenteditable regression test.

## Screenshots

See [A restored with both drafts](06-a-restored.jpg), [B's separate replies](05-b-replies.jpg), [plain new-model context](08-plain-new-model-context.jpg), [feedback receipt](10-feedback-receipt.jpg) and [reporter credit](11-reporter-credit.jpg).

## Video

[Play/download the walkthrough](walkthrough.mp4): 33 seconds assembled from eleven actual UI screenshots, with three-second holds and edited timing. This is a sampled sequence, not a continuous screen recording or a latency measurement.

| Time | Capture |
| --- | --- |
| 00-03s | One shared send to Claude and Grok |
| 03-06s | Both models reply in comparison A |
| 06-09s | Shared follow-up stays in the original chats |
| 09-12s | Private and shared drafts stay with comparison A |
| 12-15s | Comparison B has its own chats and replies |
| 15-18s | Returning to A restores history and both unsent drafts |
| 18-21s | A cold model opens first; click its recipient again when ready |
| 21-24s | New model receives the ask and shared follow-up, without added instructions |
| 24-27s | Feedback note before a local synthetic submission |
| 27-30s | Visible fixed-footer receipt from localhost HTTP 201 fixture |
| 30-33s | 0.6.6 notes thank schultetrevor for the report and recording |

## Limits

A cold website recipient first opens its page; a second recipient click after readiness sends the join context. This setup boundary existed on main and was retained. The video labels this as setup followed by an explicit join, rather than claiming a first-click join. Live provider layouts and authentication differ from the fixture HTML. Native macOS changes have no mobile layout.

The user-supplied recording, private R2 feedback contents, live app screenshots and credentials are excluded from this evidence package. Publishing this source PR does not publish an app release.
