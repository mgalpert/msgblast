# Website agent labels

Captured on October 25, 2026 from source revision `5533ebe273de9eb164899b92efb7025206758798` in the packaged blue msgblast Demo (`com.msgblast.demo`), launched with `--isolated-demo`. Subsequent evidence-only commits do not change the captured app source.

- `app-agents.png`: native app names remain ChatGPT, Dots, and Claude.
- `web-agents.png`: Settings shows Muse Web, ChatGPT Web, Claude Web, Dots Web, and Grok Web.
- `web-enabled.png`: enabling ChatGPT Web succeeds through the actual Settings toggle.
- `grid.png`: closing Settings returns to the grid with the ChatGPT Web tile.
- `workflow.mp4`: 12-second sampled walkthrough of these actual native window captures, in that order, with edited timing. It is not a continuous screen recording or latency measurement.

All accounts, installation checks, permissions, contacts, and website content are Demo fixtures. No live messages or provider requests were sent; no real permission settings changed. Mobile screenshots do not apply to this native macOS app.

Validation: Xcode 27.0 native build plus `WebAgentInstanceTests` and `MultiWebAgentTests`: 99 tests passed, 0 failures. Existing tests were used unchanged because this is a display-string rename; they cover custom names, saved identity, and provider conversation boundaries. `git diff --check` passed. Preview packaging verified the Demo signature and compiled icon.

Code review: skipped (mechanical diff) — seven website display strings change; native names and all provider identities, routing, and storage paths remain unchanged.
