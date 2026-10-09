# Comparison workspaces

Switching A → B → A restores A’s own model pages, histories and drafts. Each model retains one account cookie store. Pages awaiting replies or confirmation, and pages with drafts, stay alive when the cache unloads safe idle pages.

## Verification

- `core-tests.log`: **200 native XCTest tests passed, zero failures**, using the compiled Xcode test bundle on macOS 27.2 / Xcode 27.0. This is a unit/integration test result; the UI runner was not used.
- `controllers.log`: actual AppModel/WindowCoordinator/AgentBroadcast checks passed for shared drafts, six provider destinations, CLI histories, private-context isolation, retry isolation and shutdown. Actual AppLifecycle code with controlled model/reply hooks proves idle Quit waits for browser draft saving and cancels Quit before shutdown when saving fails.
- The persistent WebKit-cookie test verifies that separate comparison pages share one account store. Its cookie is synthetic and deleted after the assertion.
- `regression-red.log`: original A → B → A displayed B while A was selected.
- `persistence-red.log` and `eviction-red.log`: sign-out/unavailable editors and failed restoration erased saved drafts; stale eviction discarded a fresh draft and a page awaiting its reply. The corresponding regressions pass in the final suite.
- `review.json`: completed review with no remaining findings. Original lenses were followed by focused source verification of the corrections. The external Grok route failed before egress; an independent local adversarial pass supplied that coverage. The review itself did not execute tests or validate authenticated provider transcripts.
- `source-fingerprints.json`: SHA-256 of the reviewed implementation, tests and controller fixtures captured before committing the evidence.

## Native walkthrough

Actual final app, driven through native clicks and keys in an isolated blue fixture bundle (`com.msgblast.history-fixture`). The app uses its production model, WebKit adapters and view identity handling. Accounts, prompts and replies are local simulations; no real Messages, Contacts writes, CLI calls, paid provider requests or updater requests occur.

1. `01-a-drafts.jpg`: A has four replies, an unsent Claude draft and an unsent shared draft.
2. `02-b-history.jpg`: B has its own four replies at four different chat addresses.
3. `03-a-restored.jpg`: returning to A restores its original addresses, histories and both drafts.
4. `04-b-restored.jpg`: returning to B restores B’s addresses, histories and shared draft.
5. `05-a-followup.jpg`: after clearing the simulated private draft, a shared follow-up receives replies in A’s original four chats.
6. `06-relaunch-draft.jpg`: ordinary Quit immediately after typing preserves the last Claude draft and restores it at A’s saved address after relaunch. The persisted ledger has two sends per provider in A (original + follow-up), and one per provider in B; reopening did not send another prompt.

`walkthrough.mp4` is a **20-second sampled walkthrough of captures 1–5**, with four-second holds and edited timing. It is not a continuous recording or latency measurement. Original screenshots are 3024 × 1804; video is 1920 × 1146. Native macOS UI has no mobile layout. The fixture carries development version 0.4.3 (1); this does not identify a published release.

Fixture website replies are simulated in a nonpersistent WebKit store, so the relaunch capture verifies saved destinations and drafts, not server transcript retrieval. A later [live account run](live/README.md) verifies authenticated server history after relaunch and records first-send recovery and cold-page limits. Source and production icon resources remain unchanged by fixture packaging; no production release was triggered.

## Reproduce

```sh
xcodebuild -project msgblast.xcodeproj -scheme msgblast \
  -derivedDataPath build/history-validation -destination 'platform=macOS,arch=arm64' \
  ASSETCATALOG_COMPILER_APPICON_NAME=AppIconDemo \
  -only-testing:msgblastTests build-for-testing -quiet
DYLD_FRAMEWORK_PATH="$PWD/build/history-validation/Build/Products/Debug" \
  /Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/xctest \
  build/history-validation/Build/Products/Debug/msgblastTests.xctest
bash scripts/test_web_comparisons.sh build/history-validation
```
