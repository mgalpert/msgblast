# Native agent reliability evidence

Live follow-up evidence:

- [Closed-app Wabi and Grok Bot connection, first replies, and follow-ups](cold-native-connect/README.md)
  from `f08cba3dfde61bf1367b2fa86dd0c48c672ece64` on Pal’s Studio.
- [Dots first request and consecutive follow-ups](dots-refresh/README.md), with
  its earlier executable revision and limits recorded separately.

The captures below are the earlier Demo fixture evidence.

App source: `653ae15650843340d32e372a609a3935e5539509`.

Captured from the packaged blue msgblast Demo app using its explicit fixture
mode and isolated temporary state. Connections and replies are simulated; no
provider app, Messages account, or paid model was contacted. These captures
verify the setup and transcript presentation, not live native app compatibility.

- `dots-connect-before.png` and `dots-connect-ready.png`: one Connect action
  checks installation/opening/readiness and reaches the ready state.
- `dots-connect.mp4`: native interaction recording; idle time removed between
  enabling Dots and connecting. No playback speed changes.
- `reply-completed.png` and `reply-status.mp4`: the outgoing prompt and completed
  fixture reply appear once, with no lingering Sending status. The video retains
  nine continuous seconds surrounding submission and completion.

Videos are cropped to the Demo window and decoded locally after export.
Private live-account captures and raw desktop recordings are excluded.
