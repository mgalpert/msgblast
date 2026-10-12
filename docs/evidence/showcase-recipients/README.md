# Recipient options Demo evidence

Captured from source `7e81df9a3bf52b62c210a749faef40afb988690d` on October 12, 2026.
The packaged blue msgblast Demo (`com.msgblast.demo`) ran with `--isolated-demo`.
The running executable was verified at `build/showcase-final/msgblast Demo.app`.

- `showcase-grid.png`: unchecked Muse plus selected Cedar, Lumen, and Orbit.
- `messages-send-to.png`: the Messages-only comparison offers Muse; hidden connected Maple, Echo, and Flint are absent.
- `muse-joined.png`: Muse has joined the same comparison and received its original ask.
- `workflow.mp4`: selected-window recording of the simulated send, choosing Muse, explicit join after loading, and toggling Muse off/on. Playback is accelerated 2x; window capture switches between the native comparison and main workspace. No other app windows were recorded.

All inputs, Messages replies, website pages, and submissions are local fixtures.
This does not verify current live Muse authentication or delivery. No real Messages,
Contacts writes, paid requests, production updates, or releases were performed.

Validation: native `msgblastTests` passed on source `6394923644baad62d9d6a339ae52b7e97edc8aeb`;
`scripts/test_web_comparisons.sh build/showcase-tests` passed on the final source;
final Dev/Demo packaging passed signature, icon, and metadata verification.
The last source commit only moves website workspace opening ahead of preparation;
its complete native build and affected Demo interaction were verified.
