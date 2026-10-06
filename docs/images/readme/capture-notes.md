# README screenshot capture

The comparison image uses the actual native views from published 0.2.2 (7) source, `f86cce472649d5468792d04a86dd05a7b763774a`. This is the version returned by `https://updates.msgblast.app/latest.zip` when checked on October 6, 2026. The public release manifest at `https://updates.msgblast.app/releases/0.2.2-7.json` records the source revision. The README explains this released Messages workflow first.

The seven-assistant picker uses unchanged native view code from current main `32b983a71f899b6636453565731130529880fa32`. The README explicitly labels it as a next-version preview; Muse, ChatGPT, Claude, and Grok direct connections are not advertised as present in the current download.

Both capture apps use separate bundle identities, the required blue demo app icon, and temporary state. README branding uses the verified green production icon. Only backend initialization and initial window framing were adjusted for screenshot capture. Native UI view code is unchanged; its hashes are recorded in `capture-manifest.json`. The two capture-only patches are retained here as evidence and are not applied to shipped source. They use zero-context unified diffs (`git apply --unidiff-zero`) to avoid whitespace-only context lines.

Instinct, Fo, and Szn use the original pictures the user added to the earlier isolated capture app. No personal contact identifiers, addresses, or phone numbers are included. Their sample handles are example.com placeholders. Replies are authored sample copy, not live service outputs. Muse, ChatGPT, Claude, and Grok use the existing bundled artwork. See `agent-icons/README.md` for provenance.

No real messages, provider requests, Contacts writes, live app replacements, or permission changes were made by the capture workflow. The user's original capture app and added profiles are preserved.

`workflow.mp4` is a sampled walkthrough of actual comparison captures with edited timing: all three recipients included, Fo excluded, and all three included again. This is not continuous video, a response latency benchmark, or a live send demonstration. No send action is taken. Mobile app screenshots do not apply to this native macOS app.
