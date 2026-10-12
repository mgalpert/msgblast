# Private Messages send visibility

Captured source: `ad387a27895a989c51f9e1a0ada292f3ffdb8518`.
Base: `1d8d4763fbc388cd3c6244057d3c97b00ddf1dd5`.

Native macOS msgblast Demo (`com.msgblast.demo`), built with
`scripts/build_preview_apps.py`, launched with
`--isolated-demo --no-demo-replies`. Only simulated Messages and sample text
were used. Automatic replies were disabled so they could not move the pane.
The final evidence commit adds only these media and this record.

- `composing.png`: 40-line reply entered into Cedar's individual composer.
- `sent-visible.png`: immediately after Send privately, its end marker is
  visible above Cedar's composer, without manual scrolling. Lumen and Orbit
  retain only the original shared message.
- `workflow.mp4`: normal-speed selected-window capture of that interaction.
  ScreenCaptureKit adds black padding beneath the window in the video.

The AppKit controller fixture passes with an overflowing joined pane and late
tapback. It also passed before this fix, so it is not the reproducer for the
real composer timing failure. Native GUI testing reproduced the failure with
the prior scroll implementation and verified the final committed build.

The Xcode UI runner timed out enabling automation before executing the new
UI regression. This capture proves the sample native interaction, not live
Messages delivery. No production release or live message was sent for this
scroll check. This is a macOS view; mobile evidence does not apply.
