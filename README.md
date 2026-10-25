# What’s New footer visibility

Base source: 7676362e87e1097fa2cf933a045da8d724923bf8
Fixed source: 5ff9d6760613e75a930cd7be742f602d592c61d3

Native msgblast Demo builds from the source revisions above, built on macOS 27.2 with Xcode 27.0 through scripts/build_preview_apps.py --variant demo. Each fixture uses its own com.msgblast.demo.banner-* identity and msgblast-BannerFixture-* support profile. Fixture-only Info.plist changes select that identity/profile; the light fixture also sets NSRequiresAquaSystemAppearance=true. Production updates are disabled. The version 0.9.0 shown is the repository's development default, not a claim about the published version.

Forty synthetic saved comparisons, all titled ChatGPT and containing numbered sample travel prompts, overflow the sidebar. These are simulated records; no real conversation data, provider request, Messages send, or Contacts write was used. Main-window sizes inspected: approximately 1512x907, 1000x650, and 800x600 points. Screenshots can be scaled by the capture driver.

before.png: base revision; conversation content is visible through the What’s New card.
after.png and after-full.png: fixed revision, unread card remains clear.
after-scroll.png: actual sidebar scrolling moves the list from conversations 1–6 to 12–18; footer stays clear.
history-open.png: clicking the actual What’s New button opens release history.
history-viewed.png: dismissing history leaves the viewed card clear.
after-compact.png: fixed revision at a compact window size.
after-light.png: fixed revision with the native light appearance.

sidebar-workflow.mp4 is a 15-second sampled workflow video assembled from actual window captures in this order: before, fixed, after scrolling, opened release history, viewed card after closing. States are held for readability; timing is edited. This is not a continuous recording of the scroll animation or pointer motion. The MP4 was decoded successfully with ffmpeg.

Validation: both Demo preview builds and signature/icon packaging verification passed; native fixture checks of scroll, open/dismiss history, unread/viewed states, compact/full windows, and light/dark appearance passed. git diff --check passed. No automated pixel regression test was added for this two-line visual fix. Core tests and CI were not run locally for this change.
