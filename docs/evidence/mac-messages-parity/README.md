# Mac conversation window: Messages parity evidence

Implementation source: the `codex/mac-messages-parity` branch head named in the
PR's `Evidence-SHA` line. Base: `08e29ee679058b2513abe9ebad6288f2a7c301cb`.

## How the pictures were made

Every picture is the blue **msgblast Demo** preview's own window, rendered by
the Debug-only design fixtures and saved from inside the app
(`--design-fixture … --appearance … --window-size … --capture-window …`, see
`docs/mac-conversation-design.md`). The "after" pictures come from a Demo
build of the Evidence-SHA tree (`git archive` export, then
`scripts/build_preview_apps.py --variant demo`). The "before" pictures come
from the same fixtures run against `main` (`08e29ee…`) plus only the fixture
commit, so both sides show identical sample data.

Fixture data is sample agents (Cedar, Lumen, Orbit) and a simulated Muse app
session: no Messages database was read, no app, CLI or provider was contacted,
nothing was sent, and the installed production app and its support folder
were not touched. The `--isolated-demo` store is a temporary folder. The
orange "Local fixture · no real sends" row is the Demo build's own banner.
Light unless named dark.

| File | Fixture | Shows |
| --- | --- | --- |
| `00-before-side-chat-light.png`, `00-before-side-chat-dark.png` | `side-chat` on `main` | The old window: permanent "Connect Messages" card, tinted header with subtitle, gear and reload squares, full-width "You" / "Muse" slabs, a per-pane field plus the "Send to" row and a second field |
| `00-before-group-light.png`, `00-before-group-dark.png` | `group` on `main` | The old one-window comparison: name pills, a field under every column, the pill row and a fifth field |
| `01-side-chat-light.png`, `02-side-chat-dark.png` | `side-chat` | Muse side chat: no permission card, the avatar-and-check header, Messages bubbles with the curved tail, a time header, the agent's avatar at the bottom of its run, one compose field, ⓘ and capture in the toolbar, compose over the sidebar, the agent's artwork in the sidebar row |
| `03-group-light.png`, `04-group-dark.png` | `group` | Four columns (Muse app plus three Messages agents): pinned forming prompt, the header cluster with every agent checked, one run per sender, one compose bar |
| `05-group-filtered.png` | `group` sequence | Lumen and Orbit unchecked in the header: the next message goes to Muse and Cedar only |
| `06-group-details.png` | `group` sequence | The Details popover: members with recipient checks and per-agent menus, agents that can be added, End Conversation |
| `07-group-follow-up.png` | `group` sequence | After sending "Which of these would you actually use?": the follow-up reaches the two checked agents only |
| `08-no-access-light.png` | `no-access` | History access simulated as unavailable: the permission card is one line with the reason, an ⓘ, Allow Full Disk Access and Check Again (the caption under it is the Demo's own preview label) |

## Video

`walkthrough.mp4` (25 s) is assembled from the fixtures' `--capture-sequence`
frames, 2.5 s each, in this order: the group as opened, Lumen and Orbit
unchecked in the header, the Details popover, a draft in the compose bar, the
follow-up sent to the checked agents, the replies; then the Muse side chat as
opened, a draft, the send, Muse's simulated reply. It is not a screen
recording: the frames are the app's own window captures of fixture states, so
there is no cursor and no typing animation. No real interaction with Messages
or Muse took place.

## Validation on the reviewed revision

- `msgblastTests`: see the PR body for the executed count.
- Python tooling (`scripts/tests`): passed, one skip.
- Debug and Release compile; the Release binary contains no fixture strings.

## Limits

Fixture evidence does not establish live Messages, website, Muse or
permission behavior. Website agents (embedded pages) keep their column and
were not captured. The separate-windows style and `msgblastUITests` were not
run; several UI tests still look for controls this change moved (see the PR).
