# Native agent reliability evidence

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
