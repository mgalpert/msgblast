# msgblast for Mac: the conversation window

The Mac app's conversation window follows the same rules as the iPhone
controller (`docs/mobile-design-principles.md` on the `ios-controller` branch):
Apple Messages is the reference, one control per concept, nothing shown twice,
details behind a click, one spacing table. This page records how those rules
land on macOS, where the app is a comparison tool with one column per agent.

## What the window is

- **Columns, not one thread.** A comparison shows one column per agent so
  answers can be read side by side. Website agents are embedded pages and
  cannot be merged into a thread; app agents and Messages agents render as
  Messages-style threads inside their column.
- **The header is the cluster.** Each column's header is the agent's avatar
  with a check badge and the name under it, as Messages shows a thread's
  identity. Clicking the avatar toggles whether that agent receives the next
  message. Across columns the headers are the group's cluster: identity and
  recipient list in one control. There is no separate "Send to" row.
- **One compose bar.** One Messages-style field at the bottom of the window
  sends to the checked agents: everyone, a subset, or one (a private reply).
  Columns have no field of their own. The plus button appears only when a
  checked recipient takes attachments (Messages agents today); the send arrow
  sits inside the field once there is something to send.
- **Details behind ⓘ.** Reload, app options, Grok Bot settings, remove from
  view, adding an agent, re-checking Messages access and ending the
  conversation live in the Details popover from the toolbar (and in a column's
  context menu). Nothing was deleted; it moved behind a click.
- **The forming prompt is pinned.** A group shows the prompt that formed it
  under the headers, two lines, click to expand.
- **Permission status is one line, and only when something is missing.** With
  Full Disk Access granted nothing is shown. Without it, one line with the
  reason and the two actions. A guided permission flow keeps its card while
  it runs.

## Thread metrics

Messages' measured metrics, from `msgblast/Windows/Layout.swift`:

| Metric | Value |
| --- | --- |
| Bubble corner | 18 pt, continuous, curved tail on the last bubble of a run |
| Bubble inset | 12 × 7 |
| Within a run / between runs | 2 pt / 8 pt |
| Time header | 11 pt semibold, 12 pt above and below, after a 5-minute gap |
| Body text | 13 pt (`NSFont.systemFontSize`) |
| Incoming run | 28 pt avatar at the bottom of the run, 8 pt from the edge; no name (the column header names its one sender, as a 1:1 Messages thread names nobody) |
| Bubble width | at most 75 percent of the column |
| Colors | outgoing `systemBlue`, incoming E9E9EB / 3B3B3D, no custom tints |

Every inset, gap, corner and frame literal maps to a `Space` name. A new
literal in a view is a review comment.

## Appearance

Light and dark are both native: system colors and materials only, no tinted
header bands, the window background behind headers and the compose bar, the
text background behind threads.

## How we check it

Build the blue **msgblast Demo** preview and render fixture states from inside
the app (Debug builds only, Demo only; nothing is sent, read or contacted):

```sh
"build/preview/msgblast Demo.app/Contents/MacOS/msgblast" --design-fixture group \
  --appearance dark --window-size 1180x800 --capture-window /tmp/group-dark.png
```

`--design-fixture side-chat|group|no-access` seeds the state, `--appearance
light|dark` forces the appearance, `--window-size WxH` sizes the window, and
`--capture-window <png>` or `--capture-sequence <dir>` saves the window through
the app's own ScreenCaptureKit capture and quits. The loop is build, capture,
critique against a Messages window, fix. Evidence for a change lives under
`docs/evidence/<name>/` with its README naming the fixture and the revision.
