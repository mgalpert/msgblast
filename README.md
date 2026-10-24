# PR79 evidence

Evidence-SHA: 0b28ac51f10dc9b9d96a4f51ebe8cb2c136e956b
Base-SHA: b8bf6143f4875a1b6de9372335bf77dae8035f75

Numbered images show the actual native msgblast Demo from this committed revision. Onboarding fixtures simulate permissions, installation and connections; they do not prove OS grants or provider delivery. Demo was launched with the supported onboarding, permission-guide and isolated-profile preview flags. No mobile UI applies.

The video is a continuous native window recording, played at 2x speed, without cuts or audio and scaled to 1280px wide. It shows a partial permission group blocking Continue, app access becoming complete, the six-agent catalog without Gemini, blocked pending connections, two Ready results and the final onboarding step.

Grok Bot and Wabi images show observed live first replies and follow-ups on clean Dev 5fe4683. The only later source change was one test assertion; application sources, generated project and build settings match the final revision exactly. Claude shows observed first and follow-up replies in the final Dev build, using Chat mode. Muse failed its final input check before Send and remains a live-validation hold. Gemini is deferred; existing saved state remains intact. ChatGPT and Dots live reruns were skipped at the user's request. These limitations are separate from Demo success.

Dev and Demo were rebuilt from the clean Evidence-SHA with updates disabled; compiled blue-green/blue artwork and deep signatures were verified. The locally installed Dev retains its existing Apple Development signing identity; no OS grants were reset. Production was unchanged.

Final native units: 685 passed, one existing-permission-dependent AX smoke skipped, zero failures. Actual AppModel/controller fixtures passed. Details: validation.json.

## SHA-256

- `01-permissions.png`: `864d7a98b2ae3e865f3a8457dd4cecc6bedb933fb9ff67370addb9b8e3b0132c`
- `02-agents.png`: `fab58d5314098a94cd8105d77bf6128ac6f0b6009927a8e318efc3801a5644eb`
- `03-connections-pending.png`: `86b05ab3ca63e6cda4b7a88eb5d3ae3528adea2a6d64ba7d13d2e230b7f0159e`
- `04-connections-ready.png`: `4a28fd12ab9f1000ff23260ebf9ac43b05d79903b8d92e0253e9341bb49967f4`
- `grok-live.png`: `7457b1b786e4efef9da4ae6449211caccb0ba925aec380fb3426be262bd4bdbb`
- `wabi-live.png`: `35b5f8683a50ba40affb52b4400233e7c2e4c8577e4dac236dcfc64206b49736`
- `claude-live.png`: `c80d37c9f4a23ee0cefc125efc7c9edf0c55e174a3067a0ec8ade36a3140952a`
- `onboarding.mp4`: `ad00bfb89027bc4d9ab56c96ab23d70200c572da2b91f1eba01c094938ff122f`
- `preview-manifest.json`: `f8be12eb33371bf6a6cf961cee711c82c218d129265628ee81131f30c94209a8`
- `validation.json`: `081f499a9fdfcddb16a728d59ecd74fb1203b6acfeaf6d3d6d7c9b43540d416a`
