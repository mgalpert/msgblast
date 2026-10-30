# iPhone controller evidence

Implementation source: the `ios-controller` branch head named in the PR's
`Evidence-SHA` line (the tests and captures below were made from a clean
`git archive` export of that revision, not from an edited working tree).
Base: `08e29ee679058b2513abe9ebad6288f2a7c301cb`.

## What the pictures show

Captured on the iPhone 17 Pro simulator (iOS 27.2) from the Debug build with
the app's design fixtures (`MSGBLAST_FIXTURE=…`). Fixture data is sample
agents and sample messages: no Mac was paired, no account was signed in, and
no message was sent. Light unless named dark.

| File | Fixture | Shows |
| --- | --- | --- |
| `01-inbox.png` | `inbox` | One list by recency, unread dots, agent initials and artwork, bottom search and compose |
| `02-conversation.png` | `conversation` | Group thread: pinned forming prompt, Messages-style runs with tails and names, a reply quote, a tapback stack, a link preview, the typing bubble, the compose bar |
| `03-conversation-filtered.png` | `conversation` + `_FILTER` | The header cluster narrowed to one agent, which also narrows the thread and the recipient list |
| `04-details.png` | `conversation` + `_DETAILS` | Details sheet: rename field, Show All, per-agent checks, Photos / Links / Documents |
| `05-new-conversation.png` | `new` | New Conversation: empty thread, every sendable agent preselected in the strip above the field, header filled from the selection |
| `06-direct-thread.png` | `conversation-short` | A direct thread with its own title and pinned prompt |
| `07-pairing.png` | `pairing` | First-run pairing screen |
| `08-settings.png` | `settings` | Settings pushed full-screen |
| `09-inbox-dark.png` | `inbox` | Inbox, dark |
| `10-conversation-dark.png` | `conversation` | Group thread, dark |
| `11-new-conversation-dark.png` | `new` | New Conversation, dark |

## Video

`walkthrough.mp4` is a continuous simulator recording of the same fixture
build with **one cut**: 2 minutes 22 seconds of idle time on the
New Conversation screen (while the recording was left running) were removed
between 1:22 and the final seconds, where an agent is added in the strip and
the header updates. Nothing else was re-timed. It was downscaled to half
resolution for size. Sequence: inbox, open a thread, tap an avatar in the
header to filter, open Details from the agent count pill, Done, back,
compose, add an agent in the strip.

## Validation on the reviewed revision

- `msgblastMobileKit` tests hosted on macOS: 48 of 48 passed.
- Mac remote, Messages reader and attachment classes: 74 of 74 passed.
- `msgblastRemoteProtocolTests`: 14 of 14 passed.
- Python tooling (`scripts/tests`): passed, one skip.
- Release simulator build: succeeded, zero fixture strings in the binary.

## Live checks and limits

On an iPhone 17 Pro (iOS 27.2) against the stamped msgblast Dev Remote
preview on the maintainer's Mac over Tailscale: pairing, reconnect after
background, locked-Mac subtitle, real agent artwork, a Mac-app send to Muse
and its reply, the new-conversation flow binding to the created thread,
header filtering on a live group, a tapback stack on a real message, and
dictation through both permission prompts into the listening state.

Not exercised to completion: dictation transcription, the camera, website
sends (no site signed in on the Dev Remote app), very long threads, and
tapbacks arriving live. No real iMessage was sent, no Contacts were written,
no permissions were reset, and no paid work was started for this evidence.
Simulator captures are fixtures and do not prove the live behavior.
