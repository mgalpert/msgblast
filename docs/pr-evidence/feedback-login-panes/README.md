# Feedback regression evidence

Runtime source: `40ae88e5e4b4e071cd392a352651d566166cbbab`.
Base: `b8bf6143f4875a1b6de9372335bf77dae8035f75`.
The subsequent evidence commit adds only these media files and this record; it does not change the tested app source.

## Local Dev check

Built and launched the blue-green Dev preview on the user's Mac with Xcode 27.0 (27A5218g). It has a separate review bundle identity and support folder, fixture mode off, production updates disabled, and an ad-hoc signature verified with `codesign --verify --deep --strict`. Checked the real signed-out Muse onboarding page and feedback draft entry, diagnostic opt-out, and manual window dismissal. No existing browser sessions were imported. This fresh profile has no connected account; live sends, delivery, and successful production feedback submission were not exercised.

## Simulated regression checks

The blue Demo preview was built from the same source and uses a separate review identity/profile. All names, prompts, replies, and message sends in the media are local fixtures. Its feedback endpoint alone was set to a loopback HTTP fixture, then the bundle was re-signed and verified. No feedback was uploaded to Cloudflare.

- `before.png`: baseline source on the isolated Mac; selected Cedar, Lumen, and Orbit disappear while Muse needs sign-in. Different window size and appearance from the local after capture.
- `signed-out-after.png`: the fixed local app retains all three Messages panes, selected recipients, and the unsent draft.
- `signed-in-unsent.png`: signing in still leaves the draft unsent.
- `explicit-send.mp4`: an explicit simulated send produces the Muse reply and all three native conversations. Window-only recording; resized, silent, and trimmed to 12 seconds with no timing changes.
- `feedback-failure.png`: an HTTP 503 keeps the window and note available for retry.
- `feedback-retry.mp4`: local HTTP failure, retry, and confirmed-receipt window closure. Window-only recording trimmed to 7.1 seconds; the final black fraction is the captured window disappearing. No timing changes.
- `feedback-success.png`: the main comparison workspace is restored after that successful retry.

The receipt fixture observed exactly two attempts with the same request UUID and note: HTTP 503, then matching HTTP 201. The production controller fixture also passed failure retention and successful workspace restoration against an injected URLProtocol transport on the isolated Mac. Native build-for-testing passed there; the XCTest UI runner could not enable automation mode, so the UI regression above was checked manually on the user's Mac instead. Demo results do not establish real Messages delivery or today's authenticated provider behavior.
