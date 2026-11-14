# msgblast iPhone promo: Remotion composition and script

`IPhonePromo` in `src/promo/IPhonePromo.tsx`: 1080 × 1920 (vertical), 30 fps, 38 s, silent.

**Rule (project lead):** the promo shows only features that are merged on `main`.
A line may be added only after its PR is merged; record the PR number and merge
commit in the table below.

## Merged PRs shown

| PR | Merge commit on `main` | What the video shows |
| --- | --- | --- |
| #94 iPhone controller: pair a phone to msgblast on the Mac | `94ea9c9db9eeb1e2cb134b0b1e1a8d6f865dd083` | Every phone scene: inbox, group thread, Details, pairing, dark thread, Settings |

Checked against `origin/main` on 2026-11-11. The Mac-side PRs that an earlier
draft listed (#93, #95, #97, #99–#105, #120, #123–#129) are open, not merged, so
they are not in the video.

## Render

Node.js 22+. The phone screens are the simulator fixture captures from the
`iPhone promo captures` workflow (#130, run 43127209243). They are fetched into
`public/promo/`, which Git ignores. That artifact expires 14 days after the run.
After that, rerun the workflow and update the run ID and artifact name in `promo:fetch`.

```sh
npm ci
npm run promo:fetch      # needs gh signed in with read access to mgalpert/msgblast
npm run check            # tsc --noEmit; CI runs this in .github/workflows/remotion-prototype.yml
npm run render:promo     # renders/iphone-promo.mp4
npm run still:promo -- --frame=380
```

## Script

The VO column is for an optional voice-over. The video renders the on-screen text only and has no audio.

| Time | Picture | On screen | VO (optional) | PR |
| --- | --- | --- | --- | --- |
| 0–3 s | msgblast icon pops in | **Ask every AI. From your iPhone.** | "Ask every AI, right from your iPhone." | #94 |
| 3–8 s | Inbox (`01-inbox`) | **Your Mac's AI chats. In your pocket.** Every conversation on your Mac, on your iPhone. | "Every conversation on your Mac is now in your pocket." | #94 |
| 8–14 s | Group conversation (`02-conversation`) | **One prompt. Every answer.** Claude, ChatGPT and Muse reply side by side. | "Send one prompt. Claude, ChatGPT and Muse all answer, side by side." | #94 |
| 14–19 s | Details sheet (`03-conversation-details`) | **Pick who answers.** Websites and Mac apps, in one thread. | "Choose who's in the conversation: websites and Mac apps together." | #94 |
| 19–24 s | Pair Your Mac (`07-pairing`) | **Pair in seconds.** Scan a one-time code in Settings › Remote on your Mac. | "Pairing takes seconds: scan a one-time code from your Mac." | #94 |
| 24–29 s | Conversation, dark (`11-conversation-dark`) | **Every reply, as it lands.** Typing bubbles, tapbacks and replies, like Messages. | "Watch every answer arrive, just like Messages." | #94 |
| 29–34 s | Settings (`09-settings`) | **Private by design.** Encrypted device to device. Interrupted sends are never resent. | "Encrypted device to device, and an interrupted send is never resent." | #94 |
| 34–38 s | End card | **msgblast** · Every AI answer, side by side. · msgblast.app | "msgblast. Every AI answer, side by side." | n/a |

## Limits

- The phone screens are simulator captures of `DesignFixtures` sample data
  ("Studio Mac", sample agents and messages). No real account, pairing or send
  appears. The Settings IP address and key are fixture values.
- The video uses still screenshots with motion, not the raw clips. The raw clips
  start on the Home Screen and contain no in-app taps.
- The video is silent: there is no music or VO audio.
- Remotion's own license applies to this tooling (see README.md).
