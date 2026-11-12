# msgblast onboarding — Remotion prototype

Local comparison prototype on `codex/remotion-onboarding`.
Base-SHA: `2cc4e312bf036a82abd0ccb168ed8a030382fdb2`.

An eight-second, 1920 × 1200, 30 fps sequence follows the approved story: **too many agents → one place → ready to use**.

1. **Overload (0–2 s):** 102 actual agent assets form a dense wall of uniformly sized 140 px tiles, with consistent 154 px horizontal / 150 px vertical spacing and half-column staggered rows passing steadily across white. No jitter, random rotation, scale variation, or chaotic scattering.
2. **Consolidation (2–4.3 s):** the green msgblast icon appears as the rows decelerate. Distance from the anchored intake orders a nearest-first cascade; icons accelerate along direct lines, shrink, and disappear at the intake. The app has a subtle 2.5% pulse. There are no spirals or orbits.
3. **Ready (4.3–8 s):** brief stillness, app movement to the left (4.65–5.35 s), Applications reveal (5.15–5.65 s), then dotted arrow and exact instruction “Drag to Applications” (5.7–6.15 s). The complete result holds for 1.85 s.

Quantity creates the overload; choreography remains orderly. This supersedes every earlier motion direction. All motion is deterministic and frame-driven.

This project also contains `IPhonePromo`, a vertical promo for the iPhone app and the 0.11.0 release. See [PROMO.md](PROMO.md) for its script and render steps.

## Preview and render

Node.js 22+ and npm. Prepared images are included, so ordinary playback/rendering needs no Xcode. Remotion downloads its headless browser on the first render. From this folder:

```sh
npm ci
npm run check
npm run preview
npm run render
npm run still
npm run background
```

Outputs, intentionally ignored by Git:

- `renders/onboarding.mp4`: H.264, full animation with illustrated app/folder icons.
- `renders/final-frame.png`: matching illustrated final frame, frame 239.
- `renders/finder-background.png`: matching static background with both icon slots empty for actual Finder draggable items. Designed as a 960 × 600 point window at 2× resolution; app center (290,340), Applications center (670,340). Final Finder text/icon positioning and Retina background selection must be verified during later DMG integration.

**Standard Finder DMG backgrounds are static. This animation is a preview, not an animation that will run in a standard DMG.** The existing DMG packager now supports the matching static layout explicitly; see Installer integration below. No custom executable installer, deployment, release, real conversation, or paid generation is introduced.

## Artwork inventory and fidelity

`src/inventory.json` lists every source path and original SHA-256. 102 assets: 90 Discover PNGs, 11 WebAgentIcons files (ChatGPT, Claude, Dots, Fo, Grok, Grok Bot, Hermes, Instinct, OpenClaw, rabbit OS3, Szn), and Muse. No available files in these agent artwork directories are omitted. Similar or repeated identities remain separate because the brief asks for all available assets. Optional Codex CLI/Claude Code reuse the repository's existing provider artwork, rather than adding invented logos. Private account avatars are not accessed.

PNG/JPEG files are copied byte-for-byte; Dots PDF and Grok Bot ICNS are rasterized with AppKit. Tiles use contain sizing, preserving marks. The repository documents Grok's existing asset as an ImageGen adaptation; this prototype preserves that supplied image and does not generate or redraw any logo. See ../../msgblast/Resources/WebAgentIcons.md and the Discover catalog for provenance and owners. The logos and trademarks retain their owners' rights.

The app image is a native compilation of `output/app-icons/msgblast.icon`, exported from the resulting ICNS with AppKit at 1024 px. Applications is exported from macOS's `ApplicationsFolderIcon.icns`. To regenerate on a Mac with full Xcode:

```sh
bash prepare-artwork.sh
```

This changes only prototype assets/output and leaves the source artwork intact. `prepare-assets.py` regenerates the agent inventory and images. Native folder artwork can vary by macOS version; included exports fix the appearance for review.

## Comparison considerations

Logo fidelity: original repository pixels/native exports, no redrawing. Motion: orderly staggered rows, nearest-first direct accelerating intake, anchored subtle pulse, sequenced installation reveal. Onboarding clarity: instruction arrives after the crowded field clears, with a quiet final hold. Reproducibility: pinned npm lockfile, included asset exports, single render commands. Setup complexity: browser/Node dependencies for rendering; Mac/Xcode only for artwork regeneration. Output quality: 1920 × 1200 H.264 plus lossless PNGs. A sibling implementation has not been inspected here, so no comparative winner is asserted.

Remotion's own license applies to its tooling; evaluate its terms before adopting it in a commercial production pipeline. This isolated prototype adds no dependency to the native app.

## Local validation

- `npm run check`: passes for prototype source. `skipLibCheck` is enabled because Remotion's browser-codec declaration files overlap TypeScript's DOM declarations; this skips dependency declaration checking, not source checking.
- `npm run render`, `npm run still`, `npm run background`: completed locally. The explicit optional Apple Silicon compositor package ensures rendering works when npm omits transitive optional dependencies on this host.
- `ffprobe`: H.264, 1920 × 1200, 30 fps, 240 frames, 8.000 seconds.
- Inspected the final PNG and sampled video frames throughout the sequence. Adjusted the header timing to avoid two text lines overlapping during the reveal. The 140 px tiles use consistent spacing and scale on white. All 102 source assets participate once, with no invented or redrawn logos. A white halo keeps msgblast legible during consolidation. Sampled frames show the orderly opening, nearest-first intake, cleared screen and installation hold. This is not a readable provider catalog.
- Native app unit/UI tests were not run because native app behavior is unchanged. Installer integration was subsequently built and inspected using the real mounted isolated Demo DMG; the 83 Python tooling tests pass, including layout serialization. The PR evidence records the submitted revision.

## Installer integration

The selected static layout is implemented as an opt-in style in the repository's existing `scripts/build_installer.py`. See `../../scripts/installer-assets/README.md` for packing and regeneration. The background is committed separately from ignored review renders, so packaging requires no Node or Remotion installation. The app and Applications items in the DMG are real Finder items, not baked-in illustrations. Release automation still selects its existing default style.


## Audio alignment

The supplied `onboarding.mp3` is eight seconds long. The sound composition starts it at frame zero, at original speed/pitch and gain. Its main energy rise at about 2.25 s meets the app reveal/intake at 2.2 s; its decay after 5 s accompanies the installation reveal, ending naturally during the final hold. The approved visual timing is preserved. Alignment was checked with signal analysis; direct listening is unavailable in the authoring session.

The supplied recording is bundled at `public/audio/onboarding.mp3`, so `npm ci` and `npm run render` reproduce the sound composition. `npm run render:silent` works without it. `Onboarding` in Studio includes sound; `OnboardingSilent` and `FinderBackground` do not. The static DMG asset and installer packaging are unaffected.
