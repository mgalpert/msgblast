# msgblast iPhone promo: Remotion composition and script

`IPhonePromo` in `src/promo/IPhonePromo.tsx`: 1080 × 1920 (vertical), 30 fps, 48 s, silent.
It is a release promo for the iPhone app plus the Mac changes it ships with. It is
written as if every open PR from 2026-10-28 to 2026-11-11 lands in this release (0.11.0).
Any PR that does not land must be cut from the script and from `SCENES` /
`MAC_FEATURES` before the video is published.

## Render

Node.js 22+. The phone screens are the simulator fixture captures from the
`iPhone promo captures` workflow (#130, run 43127209243). They are fetched into
`public/promo/`, which Git ignores. That artifact expires 14 days after the run.
After that, rerun the workflow and update the run ID and artifact name in `promo:fetch`.

```sh
npm ci
npm run promo:fetch      # needs gh signed in with read access to mgalpert/msgblast
npm run check
npm run render:promo     # renders/iphone-promo.mp4
npm run still:promo -- --frame=380
```

## Script

The VO column is for an optional voice-over. The video renders the on-screen text only and has no audio.

| Time | Picture | On screen | VO (optional) | PRs |
| --- | --- | --- | --- | --- |
| 0–3 s | msgblast icon pops in | **Ask every AI. From your iPhone.** | "Ask every AI, right from your iPhone." | iPhone app (#94, merged) |
| 3–8 s | Inbox (`01-inbox`) | **Your Mac's AI chats. In your pocket.** Every conversation on your Mac, on your iPhone. | "Every conversation on your Mac is now in your pocket." | #94 |
| 8–14 s | Group conversation (`02-conversation`) | **One prompt. Every answer.** Claude, ChatGPT and Muse reply side by side. | "Send one prompt. Claude, ChatGPT and Muse all answer, side by side." | #94, #123, #104 |
| 14–19 s | Details sheet (`03-conversation-details`) | **Pick who answers.** Websites and Mac apps, in one thread. | "Choose who's in the conversation: websites and Mac apps together." | #94, #125 |
| 19–24 s | Pair Your Mac (`07-pairing`) | **Pair in seconds.** Scan the code in the new Phone section of the Mac sidebar. | "Pairing takes seconds. Scan the code from the new Phone section in the Mac sidebar." | #99, #126 |
| 24–29 s | Conversation, dark (`11-conversation-dark`) | **Read it here. Read on your Mac.** Catching up on the phone clears iMessage unread on the Mac. | "Catch up on your phone, and your iMessages show as read on your Mac." | #102, #126 |
| 29–39 s | 12-row list, "Also new on the Mac / This release" | See the next table | "And on the Mac: a Messages-style conversation window, voice control, agents that can send, and much more." | see below |
| 39–44 s | Settings (`09-settings`) | **Private by design.** Encrypted device to device. Interrupted sends are never resent. | "Encrypted device to device, and an interrupted send is never resent." | #94, #128, #129 |
| 44–48 s | End card | **msgblast** · Every AI answer, side by side. · msgblast.app | "msgblast. Every AI answer, side by side." | n/a |

### "Also new on the Mac" rows

| Row | Subline | PRs |
| --- | --- | --- |
| Messages-style conversations | A redesigned Mac conversation window | #95, #100 (#98 tests) |
| Phone in the sidebar | Pairing QR code and phone settings, always visible | #99, #126 |
| Voice control | Drive msgblast by voice with your own OpenAI key | #93 |
| Agents that can send | Full-access outside agents, with a Stop banner | #124 |
| ChatGPT and Dots in the background | Sends no longer steal the foreground | #104, #123 |
| Alexa Shopping | New optional agent in onboarding | #125 (supersedes #120) |
| Muse connects quietly | And says why when a connect fails | #127 |
| Clear "needs you" stops | When an app prompt covers the composer | #105 |
| Long Dots DMs | Read all the way to the composer | #103 |
| Ended chats scroll again | Link cards open in your browser | #101 |
| A new Settings sidebar | Every page one click away | #97 |
| Sturdier phone sends | Upload and queue caps, late confirmations matched | #128, #129 |

### Open PRs from the last two weeks that are not in the video

They have no user-facing change: #98 (UI tests), #118 (build timing), #119
(type-check speed-up, no visible change), #121 (self-hosted CI runner), #130
(capture workflow that produced these screens).

## Limits

- The phone screens are simulator captures of `DesignFixtures` sample data
  ("Studio Mac", sample agents and messages). No real account, pairing or send
  appears. The Settings IP address and key are fixture values.
- The video uses still screenshots with motion, not the raw clips. The raw clips
  start on the Home Screen and contain no in-app taps.
- Mac features appear as text rows only. Mac screen recordings for those rows
  are not in this version.
- Several PRs are still drafts. Their wording here describes each PR's stated
  behavior, not a verified release build.
- Remotion's own license applies to this tooling (see README.md).
