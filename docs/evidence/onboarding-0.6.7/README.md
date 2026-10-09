# Onboarding 0.6.7 evidence

Captured from reviewed application source `0df8194e105e4af3173465162e56679bd382013a` using native CUA clicks and screenshots on macOS 27.2 beta (26B5091g). The later evidence commit adds only this directory; application source remains identical.

The public screenshots and videos use the blue **msgblast Demo** fixture (`com.msgblast.demo`) with isolated data and production updates disabled. Contacts addresses, browser accounts, permissions and runtime detection are simulated. No real messages, Contacts writes, feedback submissions, Bot routines or paid requests were made. The local version 0.4.3 (1) is a development default; the release workflow supplies the distributed version/build.

The captured queue covers the unified agent picker, account setup, exact Grok Bot prompt and circular artwork, Claude Code, OpenClaw, Hermes, the shared Messages confirmation and the feedback reminder. Search changes a contact proposal; two checked Messages rows connect together, while unchecked choices remain available through Finish setup. The workspace appears after the final feedback acknowledgment.

`workflow.mp4` and `messages-confirmation.mp4` are edited native screenshot samples around the actual clicks. Frames repeat, timing is shortened and gaps are omitted. They are not continuous recordings. Floating native menu popovers were checked through accessibility and are not present in window screenshot samples. Contact search and the resulting screen are captured.

The blue-green **msgblast Dev** build uses actual Contacts and Messages access with a separate standard `msgblast-Dev` data folder. The original folder is preserved with file hashes. The current final-source live check confirmed an authenticated Codex CLI can finish while Messages access is unavailable, with no Messages recipient restored; a Messages-only retry stays blocked before a connection. Actual Contacts fetch and grouped confirmation are still awaiting the macOS approval prompt. This pending check prevents publication; fixture evidence does not replace it.

Validation: all 262 core cases passed on `099d222` before the narrow final correction. The corrected source compiled the app and UI tests and passed all 19 focused onboarding cases. The local full Xcode runner stalled in test-daemon bootstrap before any test; direct Xcode `xctest` executed the same built core bundle successfully. Automated UI execution is not claimed because of the earlier accessibility authorization block; native fixture CUA checks covered proposals, dropdown/search, checked-only confirmation, four rows without a scrollbar, zero selection, missing conversations, and clearing previously confirmed rows.

The final bounded review found no actionable findings after correcting access-loss recipient retention and strengthening proposal-only assertions. An injected unavailable-access controller/UI regression remains advisory coverage. Live account sign-out during setup and a production Grok Bot connection/routine remain unexercised. This is a native Mac change; no mobile interface changed.

See `capture-manifest.json` for hashes and encoding details.
