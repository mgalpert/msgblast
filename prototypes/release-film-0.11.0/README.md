# msgblast 0.11.0 feature film (Remotion)

A 1920×1080, 30 fps product film for release 0.11.0, in a clean, minimal style. Original design: no Apple footage, music or assets.

## Cuts

- `Film` (71 s): everything in the 0.11.0 merge order, including PRs still open on 2026-11-14 07:30Z (Alexa Shopping #125/#135, first-connect fix #136).
- `FilmMergedOnly` (64 s): only what was on main at 51fedbe. Drops the Alexa scene and the #136 line.

Which scenes or lines depend on open PRs is set in `src/Root.tsx` (`pending: true`). Flip those once the PRs merge, or delete what doesn't ship.

## Scenes (src/scenes.tsx)

Intro → "Now on iPhone." → iPhone inbox and conversation (#94) → pairing from the sidebar Phone section (#126) → "Now your agents can use it, too." → MCP flow: list agents, Read only / Full access approval, blast with the Stop banner (#107, #97, #124) → Grok Bot over Tailscale, Add buttons for Claude Code/Codex (#139) → Alexa Shopping (#125, #135) → Settings redesign (#97) → "And a lot more." fixes (#123, #126, #143, #136) → outro.

## Media and privacy

- Phone screens are the design-fixture screenshots from the #130 evidence (simulator, fake conversations).
- Agent icons come from `msgblast/Resources/WebAgentIcons`; the app icon from `prototypes/remotion-onboarding`.
- Mac windows, the approval dialog, Grok Bot setup and Alexa products are redrawn in React. The pairing code is a decorative pattern, not a real QR code; the server URL is a placeholder and the key is shown as "(key hidden)". No IPs, tailnet names, usernames, keys or real contacts appear.

## Run

```sh
npm ci
npm run preview        # Remotion Studio
npm run render         # renders/msgblast-0.11.0.mp4
npm run render:merged  # renders/msgblast-0.11.0-merged-only.mp4
```

On a Mac the text renders in SF Pro; elsewhere it falls back to Inter. The film is silent; add a licensed track with `<Audio>` in `src/Root.tsx` if wanted.
