# First App Agent prompt and follow-up

Captured from committed source `65af44df7af64335e0ec74e4ef4d3fe4d8339058`
in the blue **msgblast Demo PR 87 (build 1)** on October 28, 2026.

The owned Demo profile starts with Muse, Wabi and Claude enabled and selected,
with no saved `desktopConversation` setup. The recording enters a shared prompt,
submits it once, shows each simulated reply, then submits a follow-up in the
same comparison. No separate Connect action occurs.

- `01-first-prompt.png`: selected agents and first prompt, before submission.
- `02-first-replies.png`: outgoing prompt and simulated replies in their own panes.
- `03-followup-replies.png`: the follow-up and replies in the same comparison.
- `first-send.mp4`: actual native UI interaction, with idle waits removed, 2×
  playback and the final frame held for four seconds. The fixed 1400 × 1000 crop
  excludes the desktop; after the window widens, its rightmost 32 pixels are
  outside the crop. Screenshots contain the complete window.

All providers, installation state and replies in this Demo are simulated.
Cedar is an unselected sample Messages agent. No native provider app, Messages
account, Contacts write or permission change is used by the Demo. The seeded
completed-onboarding checkpoint does not demonstrate fresh macOS consent.
The MP4 was decoded and its first, transition and final states inspected.

Separate live checks on this source used Apple Development signed
**msgblast Dev PR 87 first-send (build 1)** with an owned empty-history profile
and existing native accounts/OS permissions. Muse, Wabi, Claude and ChatGPT
passed the first four-app broadcast without saved app setup, then a follow-up
in the same comparison. Grok Bot passed a new conversation and follow-up using
the existing chosen bot. Replies appeared in msgblast and focus returned there.
Those checks are not the simulated media above. The normal Dev profile, draft,
selected agents and prior native ChatGPT mode were restored afterward.

Dots remains unverified on this source because the local native account exposes
no “Your dot” destination. Gemini remains deferred. Forty native state tests and
the controller fixtures passed; they do not replace the live checks.
