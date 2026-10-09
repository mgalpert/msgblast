# Web agent icons

ChatGPT and Claude use unmodified 512 × 512 artwork from the official US iOS App Store listings. Grok uses a user-requested ImageGen adaptation of its App Store icon, without the square rim and with padding for the circular avatar. Original App Store artwork was retrieved October 5, 2026 through Apple's [Lookup API](https://itunes.apple.com/lookup?id=6448311069,6473753684,6670324846&country=us&entity=software), using each result's `artworkUrl512`.

| Resource | Official app | Publisher | App Store ID |
| --- | --- | --- | --- |
| `WebAgentIcons/chatgpt.jpg` | [ChatGPT](https://apps.apple.com/us/app/chatgpt/id6448311069) | OpenAI OpCo, LLC | 6448311069 |
| `WebAgentIcons/claude.jpg` | [Claude by Anthropic](https://apps.apple.com/us/app/claude-by-anthropic/id6473753684) | Anthropic PBC | 6473753684 |
| `WebAgentIcons/grok.png` (ImageGen adaptation) | [Grok AI](https://apps.apple.com/us/app/grok-ai/id6670324846) | X Corp. | 6670324846 |

These bundled images identify their respective services in the agent picker, embedded chat headers, and connection screens. They use the existing circular avatar treatment and load immediately without a website connection. The providers retain ownership of their artwork and trademarks. Muse continues to use its personalized avatar when available, with its existing bundled default otherwise.

## Original App Store references

- [ChatGPT artwork](https://is1-ssl.mzstatic.com/image/thumb/Purple211/v4/e8/b3/01/e8b30151-1abb-e33c-75e2-a2e230c85b52/AppIcon-0-0-1x_U007epad-0-0-0-1-0-85-220.png/512x512bb.jpg) — SHA-256 `243ff2cead1bf06f43f2c90dfde5f7420d5b1b8ddd8f1bd497df4877ddef3bb2`.
- [Claude artwork](https://is1-ssl.mzstatic.com/image/thumb/Purple211/v4/2d/a8/d0/2da8d08e-a2b8-4e33-1a37-23beee74e211/AppIcon-0-0-1x_U007epad-0-1-85-220.png/512x512bb.jpg) — SHA-256 `50d784959c3e09b6c3ed992d306efcdf306d949d3ae833c510d91a7623135b30`.
- [Grok artwork](https://is1-ssl.mzstatic.com/image/thumb/Purple211/v4/c1/01/ed/c101eda2-64f9-c361-55cd-83c4ba71eabf/AppIcon-0-0-1x_U007epad-0-0-0-1-0-0-0-85-220.png/512x512bb.jpg) — SHA-256 `5a93ad441c3215321adf9aaba22ec4bf0eb67950717c11c0f6a765db3f08fae7`.

## Grok adaptation

Generated with the built-in ImageGen tool at the user’s request. This is a custom adaptation, not the unmodified official App Store artwork. The generated PNG is bundled unchanged; the app applies its existing circular mask. The Grok name and mark belong to their owner.

### Initial edit

Use case: precise-object-edit. Asset type: Grok agent avatar inside a native macOS app, displayed as a circular crop at 38–100 points. Input image 1 is the edit target and logo identity reference, the Grok iOS app icon. Reconstruct a cleaner, better-fitting version of this exact Grok symbol. Preserve the distinctive broken circular ring crossed by the diagonal tapered stroke from lower left to upper right, its orientation, proportions, and recognizable silhouette. Remove the entire rounded-square rim/beveled app-icon frame and all outer-edge highlights. Use a perfectly uniform pure black full-bleed square background, with no inset container, no border, no circle outline, and no vignette. Center the complete silver-white Grok symbol optically, make it crisp, smooth, and restrained, with only subtle soft dimensional shading rather than heavy chrome reflections. Scale the whole symbol to fit comfortably inside an invisible central circle 74 percent of canvas width; keep both diagonal tips entirely within that safe circle, with generous balanced breathing room for circular cropping. One square production icon, 1024 by 1024. No text, no extra objects, no mockup, no watermark. The output must be a finished reusable avatar image, not a screenshot.

### Padding refinement

Edit this Grok avatar image. Preserve the exact symbol shape, silver-white color, subtle dimensional shading, and pure black background. Change only the scale of the symbol: make the whole symbol 25 percent smaller around the canvas center so there is substantially more pure-black empty padding on ALL sides. Both long diagonal tips must be well inside a centered circular crop, not near the crop boundary. Do not add a visible circular border or square frame. Same square canvas, one centered symbol, no text or other objects. This is an icon that must look clean when masked into a circle at 38 points.

### Final refinement

Precise scale-only edit for this Grok avatar. Keep the exact logo silhouette, monochrome silver-white shading, centered placement, and black square background unchanged. Enlarge the symbol by about 30 percent relative to its present size, expanding symmetrically from the center. Its two diagonal tips should still have clear black space around them inside a circular crop; aim for a symbol about 60 percent of the image's width and height, with 20 percent black margin at each outer edge. No square frame, no outline, no text. A polished, legible circular app avatar.

## Local account icons

The local accounts panel in Settings reuses the unmodified ChatGPT and Claude App Store artwork above. OpenClaw and Hermes use unmodified PNGs from their official project repositories, retrieved October 6, 2026 and pinned to the source revisions below. The projects retain ownership of their artwork and trademarks.

| Resource | Official source | SHA-256 |
| --- | --- | --- |
| `WebAgentIcons/openclaw.png` | [OpenClaw iOS app icon](https://github.com/openclaw/openclaw/blob/bff90d69144ceec82e75f92d59c3a29ec7876351/apps/ios/Sources/Assets.xcassets/AppIcon.appiconset/1024.png) | `8ce11071e6cc34f3086b1947bb5f4b7f43f237a7a023bd8e0aa0ac529173ceb8` |
| `WebAgentIcons/hermes.png` | [Hermes desktop app icon](https://github.com/NousResearch/hermes-agent/blob/85db7c3a6886762773827598793b0b51ef4e3325/apps/desktop/assets/icon.png) | `2e69dd9a8a1d3f9e3f627efc37102aed416f703e22f599e31c5d86b212a4d6de` |

## Dots avatar

Dots opens `https://chatgpt.com/dots` in its own persistent WebKit session, separate from the basic ChatGPT agent. Its live DOM was inspected on October 7, 2026 using an existing account without sending messages. `/dots` resolves to `/dots/<dot UUID>`; blasts continue that ongoing conversation.

The app crops the rendered avatar beside the dot’s profile trigger. This supports character artwork and custom pets rendered from CSS sprite sheets without requesting their underlying signed media URLs. The 256 × 256 PNG is saved in the app’s private `web-dots.json`, shown in the picker and pane header, and refreshed when the displayed avatar changes. Normal navigation preserves the cached avatar; a login/logout page or signed-out Dots UI clears it. When there is no saved avatar, the picker and pane use `WebAgentIcons/dots.pdf`: a transparent vector ring matching the default mark in the user-provided screenshot and [Dots feature page](https://chatgpt.com/features/dots/). Personal avatars take precedence. Muse retains its existing avatar behavior.

The Dots demo uses synthetic SVG and CSS artwork and local conversation replies. It does not sign in, submit live messages, or start dot tasks.

## Grok Bot icon

`WebAgentIcons/grokbot.icns` is the unmodified native icon from the locally installed Grok Bot 0.68.1 app (`com.anysphere.sand`), retrieved October 8, 2026. SHA-256: `0174e1ce966156a20c07f5715bbf6577b39cec60bd539267395e5f5fa15bbf80`. The bundled artwork identifies Grok Bot in Settings and chat avatars, including Macs without Grok Bot installed. Its owner retains the artwork and trademark rights.

`AgentArtwork` draws a centered crop of this source inside a circular mask for the picker, onboarding, Settings, and chat headers. The original icon file remains unchanged.

## Messages onboarding avatars

`WebAgentIcons/instinct.jpg`, `fo.jpg`, and `szn.jpg` are unchanged copies of the user's saved contact artwork already retained in `docs/images/readme/agent-icons/`. They identify the onboarding choices; after connection, the selected contact's own picture is used. These files contain artwork only, with no contact addresses or identifiers.
