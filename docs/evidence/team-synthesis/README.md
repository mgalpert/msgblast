# Comparison report team synthesis evidence

Source revision: `818003e99233e496d4bbdce349986931dfdb199c`
Base revision: `5cd8a394f28f37eab71359645810421da2fa19d5`

Captured from an ad-hoc blue **msgblast Demo** built from the clean committed source. Demo uses a temporary isolated profile, synthetic Cedar/Lumen/Orbit conversations, and a fixed simulated report. Production updates are disabled. No provider request, live send, sign-in, Contacts write, or permission reset was performed.

- `report.png`: project overview and grouped findings, with Update report and the compact actions menu.
- `sources.png`: source footnotes and open questions after scrolling the actual report.
- `workflow.mp4`: actual native-window interaction: open actions, copy report, update the simulated report, scroll through findings and source footnotes. The video samples native window screenshots and preserves their recorded wall-clock intervals. No generated or composited UI frames are used.

This is a native macOS window, so mobile browser evidence does not apply. The existing inline Markdown viewer uses grouped bullets; there is no HTML renderer, table renderer, classifier, map/review lookup, or hosted share link in this change.

Validation: native app build, 270 core tests, controller shutdown/persistence fixtures, manual Demo report creation/copy/update/scroll and options interaction. XCTest UI automation failed to initialize (automation-mode timeout); manual evidence does not establish live model output quality, authentication, or billing.
