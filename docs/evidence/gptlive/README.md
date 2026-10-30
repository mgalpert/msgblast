# GPT-Live native evidence

Captured October 29, 2026 from **gptlive Demo - 2026-10-29 21-40-58 PDT**
(`com.msgblast.gptlive-demo`), built from source commit
`741f8709f0c04fc944f684b532c8324d7c659805` with Xcode 27.
The subsequent evidence commit changes only these media and this explanation;
application code is identical to the reviewed and tested source.

The app ran with `--demo --isolated-demo`. All agents and conversations are
sample data; voice, microphone and destination sends are simulated in these images.
The ordinary app composer is separate from the voice-only sidebar.

- `voice.png`: one toolbar action starts the voice sidebar, with Mic and End.
- `compact.png`: Discover navigation, retained transcript preference, and compact
  window resize without the previous AppKit constraints crash.
- `debug-off.png`: Activity is accessible while Debug mode remains off.
- `walkthrough.mp4`: a 17.5-second sequence of actual native window captures:
  before/start, transcript, Discover, End, reopen and compact resize. Timing is
  condensed to 2.5 seconds per captured state. This is a snapshot walkthrough,
  not a continuous recording or evidence of live speech recognition. It has no audio.

The complete MP4 was decoded successfully with ffmpeg; sampled frames were
visually inspected. Screenshots contain no real conversations or credentials.

The exact-source Dev build **dev - gptlive - 2026-10-29 21-40-59 PDT** is installed
locally. Both packages passed build, ad-hoc signature, helper and archive checks.
The earlier approved build reached Listening on the hardware route; the final
rebuild is awaiting its own macOS microphone approval before the API connects.
Final-build hardware mute/unmute and physical speech remain unverified.

Separate live API validation used the production controller and synthetic speech
with isolated Demo data. It ran get_app_state, navigate_app, list_agents and
prepare_message, received 763,200 bytes of reply audio, and staged a Cedar draft
without sending. The session closed with confirmed final usage: 16.0 voice
seconds and 12,452 backend tokens.

Other checks: 26 focused native XCTest tests, six actual-app controller fixture
sections, production audio conversion/mute/buffer fixtures, and 127 Python tooling
tests (126 passed, one skipped). Native GUI controls were exercised with Cua;
the XCTest UI runner was not used because it previously stalled on this machine.
