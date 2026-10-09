# Guided onboarding evidence

Native macOS captures from the current source using an isolated blue `msgblast Guided Demo` app. All accounts, CLI installations, Contacts candidates, existing Messages conversations, and Bot callbacks are local fixtures. No live sign-in, provider request, paid Bot task, Messages send, Contacts write, or permission change was performed. The user's running app was not replaced.

The screenshots demonstrate the unified equal-size picker without a scrollbar or Set up later; multiple selection; a signed-out ChatGPT page with Continue disabled; a ready account; the exact Grok Bot prompt and circular avatar; Claude Code; OpenClaw and Hermes capability/setup guidance; grouped Instinct/Fo/Szn setup; explicit contact confirmation; and opening the workspace with only the completed selections checked. Skipped agents remain available through Finish setup. OpenClaw/Hermes do not unlock chat by themselves.

The Bot connection fields are exercised in source/core tests. This fixture screen substitutes an explicitly labeled simulated connection button; it does not validate a live routine, webhook key, tunnel, or provider response. Messages access is already simulated as granted in these captures; they do not prove a native permission grant. This is a native Mac feature, so there is no mobile UI capture.

`workflow.mp4` is assembled from native screenshot samples collected around the actual clicks. Playback timing is edited, frames repeat, and gaps are omitted. It is a playable interaction sequence, not a continuous real-time recording.

Additional isolated launch checks used prepared synthetic stores: `auto-advance.png` shows two already-ready agents advancing automatically with an unsent draft retained and zero send attempts; `legacy-draft.png` shows legacy-store onboarding bypass with the saved draft retained; `resume-before-quit.png` records returning to the chooser. On relaunch of that same unfinished store, selected/skip intent remained and completion markers were cleared for fresh verification. The explicit Grok Bot skip remains skipped when continuing, covered by the added state regression.

The full native core suite passed 237 tests before the review fixes. Final affected-core verification passed 76 tests, and all five onboarding UI workflows passed. Two new UI regressions first failed on the unintended Fo recipient and stale runtime status, then passed after their fixes. The existing signed-out workflow also passed, preserving the draft and requiring an explicit send after login. `native-checks.txt` contains final test summary output; `capture-manifest.json` records source hashes and fixture limits.

## Review resolution

The completed ce-code-review receipt is run `20261008-162127-76e84bc8`. All five source-validated findings were applied:

1. Workspace recipient restoration intersects completed choices with current selection. The deselected Fo UI regression passes.
2. Onboarding Bot configuration leaves recipient selection false, including after a late completion. Workspace entry reconciles completed selections. The fixture connection/reopen regression passes.
3. Runtime and CLI setup directly observe PersonalAgentController. The installation update UI regression passes.
4. Every unfinished launch clears cached completion, including a saved chooser. Stable-store relaunch verifies retained intent and fresh completion checks.
5. Skip/Back invalidate refresh ownership; a prior check cannot discard the next provider's refresh or clear its checking state. This is verified by source inspection of the generation guard and by the successive-provider workflow; a delayed live CLI account check was not induced.

The requested independent Grok review could not start because its transport package was unavailable before egress. A local adversarial review covered that lens; no private account data or credentials were sent to a peer. No justified review findings remain unapplied. Real account expiry, live permission grants, and a production Bot routine remain deliberate live-validation limits.
