# Live comparison history validation

Native computer-use run on 2026-10-08 against source `b3b4eb54f7b400417248b54181fc00b89b6dd0b2`. The blue-green Dev build used real Muse, ChatGPT, Claude and Grok accounts. Fixture mode was false and updates were disabled.

The test app used `com.msgblast.development.comparison-history` with its own `msgblast-Comparison-Live-Test` support directory. Existing browser sessions were copied locally from the installed app’s WebKit stores. Credentials and account stores remain outside the repository and app bundle. The existing Dev bundle was not overwritten by this test and its Grok Bot service was not targeted.

The saved blue-green exploration 32 artwork was staged only in an isolated build workspace, following the user’s icon instructions. Compiled `AppIcon` sampled RGB `[8.0, 143.0, 124.5]`. The app was ad-hoc signed with hardened runtime and the project’s Debug entitlements. Its development label is 0.4.3 (1), not a release version.

## What passed

- The shared composer submitted A once to each of the four live services; each replied `A_READY`.
- An unsent Claude draft and an unsent shared draft stayed with A while B opened four different live chats and received `B_READY`.
- Returning to A restored its original histories and both drafts. ChatGPT’s A was still unlinked at this point; switching did not show B or require resending A.
- Returning to B restored B’s history and independent shared draft.
- A shared follow-up received `A_FOLLOWUP` in A’s original four conversations. B remained unchanged.
- Ordinary Quit saved the new unsent Claude marker. Relaunch fetched A’s original request, reply, follow-up and reply from all four live servers and restored that marker.
- B’s original server histories and shared draft also restored after relaunch.
- Persisted ledger assertions show exactly **two requests per model in A and one per model in B**, with eight distinct saved conversation addresses. Reopening created no additional send attempts. `validation.json` contains counts and booleans, without credentials or conversation addresses.

## Observed limits

ChatGPT’s first sends reached the service and received replies, but automatic receipt attribution stayed unconfirmed. Its **Use this conversation** action successfully linked A and B after their existing request/reply were inspected. The action did not resend either prompt. A’s later follow-up confirmed automatically.

B’s first shared-send click finished preparing cold pages without creating a comparison or sending. A second click after readiness submitted B once per model. This remains a usability issue; this run does not claim every cold comparison sends on its first click.

The short responses completed before the recorded switches, so this run does not establish a live switch during ongoing generation. Inactive-page/background receipt coverage remains in the native regression suite. Messages and Contacts permissions were not granted to this separate test identity; the run covers web accounts only.

## Captures

The captures show real provider UI and replies to synthetic test inputs. There are no simulated replies, no real iMessage recipients, and no unrelated account histories in the curated images.

- `02-a-drafts.jpg`: A’s live replies and unsent private/shared markers.
- `03-b-live.jpg`: B’s separate live replies.
- `04-a-restored.jpg`: A restored while ChatGPT still needs its receipt-recovery action.
- `05-b-restored.jpg`: B restored with its own shared draft, after receipt recovery.
- `07-a-followup.jpg`: A’s follow-up in its original four conversations.
- `09-a-after-relaunch.jpg`: A’s server histories and unsent page draft restored after restarting the app.
- `10-b-after-relaunch.jpg`: B’s server histories and shared draft restored after restarting the app.

`walkthrough.mp4` is a 28-second sampled sequence of these seven actual captures, held for four seconds each. Timing is edited; it is not a continuous recording or latency measurement. Original screenshots are 3646 × 2200; the video is 1920 × 1158. Native macOS UI has no mobile layout.
