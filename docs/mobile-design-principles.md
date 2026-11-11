# msgblast for iPhone: design principles and how we build it

The phone app is a controller for msgblast on your Mac. These are the rules we
settled while building it, written down so the next change keeps the same shape.
Where a rule came from a specific decision, the reason is next to it.

## What the app is

- **The Mac executes, the phone controls.** Nothing runs on the phone: no agent
  sessions, no sign-ins, no keys, no retries. The phone sends intents over one
  paired, pinned, end-to-end encrypted channel and shows the Mac's projection of
  the result. If the connection drops mid-send, the send is **Unconfirmed**, it is
  never resent by itself, and the user checks the thread before trying again.
- **Messages is the reference, not the template.** Anything Messages already
  solved, we copy to the metric: the inbox row, the header cluster, bubble runs
  with tails, the typing bubble, time headers, the unread dot, the bottom search
  and compose bar, tapbacks. We diverge only where the product is different,
  and we say so: one prompt answered by several agents, a per-agent filter that
  is also the recipient list, status per agent, and the Unconfirmed state.
- **Telegram for the compose bar.** A quiet capsule holding the recipient badge,
  the placeholder and the dictation glyph, a plus on the left and a round send
  on the right. No glass, no hairline, nothing outside the capsule but those two.

## Reading at a glance

- **One short line per state.** Anything the phone shows inline is at most
  about 40 characters, one clause, no trailing period on captions and chips.
  "on your Mac" appears at most once in a line, never "in msgblast on your Mac".
- **Details behind a tap, never deleted.** Every Mac reason keeps its full text
  as a detail reachable from an ⓘ, a popover or a sheet. The Mac sends a short
  line plus a detail (`AvailabilityReason.userText` and `detail`,
  `RemotePhoneText.short`); the phone never parses sentences.
- **No consequence clauses.** "Nothing was sent", "nothing will be retried"
  and "usage may have been consumed" are implied by the state the UI already
  shows. They live only in the detail.
- **Icons for status, words for accessibility.** Send status is one line of
  agent glyphs with a corner badge (clock, check, check bubble, red x, orange
  question mark). The words appear in the glyph's popover and in its
  accessibility label.
- **Buttons are Title Case verbs.** Scan Code, Paste Link, Pair, Dismiss,
  Stop Waiting, Try Again, Forget This Mac.

## One control per concept

- The **header cluster** of a group thread is its identity, its content filter
  and its recipient list. Tap an avatar to focus on that agent, tap more to add,
  nothing selected means everyone. The thread shows exactly the selected
  agents' turns and a send goes to exactly them. The pill under the cluster
  names the selection and opens Details.
- Because the header is out of reach with the keyboard up, the **badge inside
  the field** opens the same selection as a strip of Mac-style icons with corner
  checks, directly above the field. It is the same selection, not a second one.
- Nothing is shown twice. The owner struck a duplicate pill row and a duplicate
  recipient chip row for this reason; keep it that way.
- The forming prompt of a group is **pinned** under the header once it scrolls
  out of view, because the title is derived from it but is not it.

## Artwork and color

- **Real artwork, from the Mac.** Agents show the same avatars the Mac shows,
  fetched once per content hash over the paired channel, cached on the phone,
  cleared by Forget This Mac. Initials in a colored disc are only the fallback.
- **Transparency stays.** Marks with alpha keep it, trimmed to fill the frame,
  with no disc behind them. Opaque photos and square icons get the circle clip.
  A mark that would vanish against the current background gets a faint backing,
  decided at render time from its luminance.
- **Blue bubbles and system tint.** The interface uses the system blue;
  outgoing bubbles are Messages' blue. The brand green appears only on the app
  icon and the pairing hero, which is the split Messages itself makes.
- The app icon is the canonical Icon Composer bundle, compiled for iOS. Never
  load the layered app icon as a flat image; the flat brand mark is a separate
  asset with its provenance recorded.

## Spacing

- One spacing system in `Layout.swift`. Lists, margins and the pairing screen
  use the 16 pt grid. The thread uses Messages' measured metrics, which are
  tighter: 12 by 7 inside bubbles, 2 pt within a run, 8 between runs, 11 pt
  captions, 42 pt incoming gutter in groups. Round numbers that are larger than
  Messages' read as bad padding; copy the metric, not the ideal.
- Every inset, gap, corner and frame literal maps to a named constant. A new
  literal in a view is a review comment.

## Accessibility and appearance

- Every screen is reviewed in light and dark and at the largest accessibility
  text size before it is accepted. Status lines may wrap at large sizes; they
  never truncate meaning. Glyph rows stack name over state rather than let a
  separator start a line.
- Reduce Motion turns the typing dots and the agent flight into crossfades.
- Every tap target is at least 44 pt, including small avatars in the header and
  glyphs inside the field, with the frontmost element winning overlaps.

## Protocol discipline

- Additions are optional fields and new actions. Older Macs answer
  `unsupported` and the phone degrades visibly: initials instead of artwork,
  filenames instead of thumbnails, a hidden Name field instead of a rename.
- Every command is idempotent by client id. Bytes (avatars, attachments) stay
  out of the replay ledger and are capped so one frame carries them.
- The Mac validates; the phone displays. Renames, sends and reads all apply on
  the Mac and come back through the projection.
- Privacy follows the channel: artwork, attachments and dictation text travel
  only between the paired devices. Dictation runs on the phone with Apple's
  on-device recognizer where it exists; only the text reaches the Mac.

## How we build it

- **Fixtures for every state.** A Debug-only `MSGBLAST_FIXTURE` launch mode
  renders each screen and state without pairing, including focused field,
  reply mode, recipient strip, dictation glyph and short and long threads.
  Release builds contain none of it, verified by searching the binary.
- **The loop is build, capture, critique, fix.** Nothing is accepted from a
  report. The reviewer looks at every capture, in both appearances, and sends
  back what fails the glance test. Three to five rounds per feature is normal.
- **Hardware for what the simulator cannot show.** Permission prompts, speech,
  iPhone Mirroring limits, real artwork, Swift concurrency traps on system
  callbacks and tapbacks from real contacts are checked on the phone against
  the real Mac. Crash reports are pulled from the device, not guessed at.
- **Clean builds from the committed tree.** Previews and device builds come
  from a `git archive` export of HEAD, never from a tree a builder is editing.
  Previews are stamped with the build time, signed with the Apple Development
  identity so Accessibility and Screen Recording grants survive rebuilds, and
  superseded copies are deleted. Launch previews by path, not by bundle id.
- **Tests at every layer, run by the reviewer.** The kit suite hosted on macOS,
  the Mac remote and Messages reader classes, the protocol round trips and the
  Python tooling. Date-dependent tests take an injected clock.
- **Atomic commits, nothing pushed without the owner.** One behavior per
  commit, with its tests and its docs, and the session's attribution line.

## Deliberate non-goals, for now

- Bubble tails, pinning and muting conversations, and a separate emoji
  keyboard button were considered and left out or removed by the owner.
- The phone does not execute, store secrets, or retry on its own, and it never
  will under this design.
