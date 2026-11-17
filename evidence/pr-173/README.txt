PR #173 evidence — msgblast Demo 20261117-1353 (fixture), source a852a8773611a043ed76a83f864b036517ebc6a2
Captured 2026-11-17 in the msgblast-fg-lab VM (macOS 26.5.2); host desktop untouched.
Setup (fixture): web-museApp.json seeded with Muse enabled and one "waiting" request created 14m40s before launch. No real sends.
1 Muse shows Busy at launch. 2 Clicking Busy Muse does nothing. 3 About 64 s after launch (request age about 15m44s) the 60 s timer released it:
  status=dismissed, detail="msgblast stopped waiting after 15 minutes. Nothing was resent." 4 Muse is then selectable (checkmark).
Video: pr173-busy-release.mp4 — real-time 99 s video stitched from about 1 fps VM screenshots (screencapture -v hangs in this VM).
