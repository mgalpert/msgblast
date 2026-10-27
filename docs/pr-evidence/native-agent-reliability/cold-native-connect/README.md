# Closed-app connection and reply verification

Executable source: `f08cba3dfde61bf1367b2fa86dd0c48c672ece64`.
The evidence commit adds only documentation and these captures.

- Candidate: blue-green **msgblast Dev PR 84 (build 1)**,
  `com.msgblast.development`, installed at its existing Dev path.
- Machine: Pal’s Studio. All GUI actions and captures took place there.
- Native providers: Wabi 0.1.15 and Grok Bot 0.75.3, signed in by the user.
- Package SHA-256:
  `4c014388cb99cc055b49b2c8cbd0d5886ef7875e61260beaf7bf80e2f2b7a396`.
- Signing: the same approved Apple Development identity and designated
  requirement; not notarized. Existing state, profiles, production app, and
  macOS permissions were preserved.

Both provider processes were quit normally before testing. One Connect click
for each opened the installed app, initialized its native controls, reached
Ready, and returned focus to the original msgblast setup sheet. No manual
provider activation, second Connect click, or message was needed for setup.

A new shared comparison then submitted the same first prompt to both apps.
Both exact replies appeared in msgblast. A single follow-up requested three
paragraphs and a final marker; both complete answers and markers appeared.
Each prompt used one Send & compare click. There was no manual provider recovery
or resend. The final shared composer was empty, no busy indicator or warning
remained, and msgblast was active. `validation.json` records these checks.

## Captures

- `grok-before.png` and `grok-ready.png` are actual Dev Settings window captures.
- `wabi-ready.png` is the Dev Settings window cropped from the continuous setup
  recording, at 20 seconds. It is not a reconstructed screen.
- `first-replies.png` and `followup-completed.png` show the live replies inside
  msgblast, including both follow-up end markers.
- `connect.mp4` contains two continuous setup excerpts, cropped to the fixed
  Settings window: Wabi at 0–20 seconds and Grok Bot at 86–103 seconds of the
  recording. The intervening idle time and navigation are cut; speed is unchanged.
  The crop excludes unrelated windows and is not proof of focus by itself.
- `followup.mp4` is a 12-second sequence of actual Dev window captures before
  sending, while waiting, and after completion. Holds are edited. It is not a
  continuous recording or a latency measurement.

Both exported videos were decoded and their relevant frames inspected locally.
Raw desktop recordings and native provider sidebars are excluded from this folder.
These are native installed-app checks with live replies, not website or Demo
fixture checks. No permissions were granted or reset by automation.

`focus-trace.json` contains only timestamps, active-app booleans, and read-error
flags from independent read-only Cua sampling around the first request. It
records msgblast → Grok Bot → Wabi → msgblast, with no read errors. It proves
automatic return, not subsecond latency or every intermediate activation.
Separate active-app reads confirmed msgblast after each Connect and the follow-up.

## Regression coverage and limits

The final affected run passed 188 native tests with no failures; controller
fixtures passed. The new setup regressions run the real session and adapters
against temporary driver processes that expose controls only after activation.
They failed before the repair. Negative cases preserve an external draft and
reject restoration to a different sheet. These deterministic tests do not prove
compatibility with future provider versions.

Earlier Dots and Demo evidence remains in sibling folders with its own source
and simulation labels. This run verifies Wabi and Grok Bot. Muse sign-in and
current-version Claude live checks remain pending; PR 84 stays draft. Gemini
remains deferred.
