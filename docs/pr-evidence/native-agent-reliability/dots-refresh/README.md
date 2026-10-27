# Dots follow-up verification

Executable source: `4b0f76d178be24113ff99517ddaa6cadd6b9ea26`.
Later evidence and test-synchronization commits preserve this runtime behavior.
The test-only synchronization change makes the refresh deadline injectable; its
production default remains one second.

- App: blue-green **msgblast Dev PR 84**, build 1, `com.msgblast.development`.
- Machine: Pal’s Studio, native ChatGPT 26.1007.30912 (20156), `com.openai.codex`.
- Package SHA-256: `681e7bc9356b11171ec9bb22c0c2006cc1aa7d617fdd4f53519674012d3884eb`.
- Signing: the same previously approved Apple Development identity; not notarized.
  Existing setup, WebKit profiles, production app, and macOS grants were preserved.

A new comparison and two consecutive follow-ups each returned their exact requested
marker inside msgblast. Each prompt was submitted through the Dev UI once. No
manual native-app recovery or resend was needed. Before the first follow-up,
a read-only native capture confirmed an existing “1 unread message” badge and
an empty native composer. The final build acknowledged that badge before typing,
then completed the follow-up. Cua’s active-app snapshots confirmed automatic
return to msgblast; the final active app was msgblast Dev PR 84.

The screenshots are actual Dev window captures using live provider replies, not
Demo fixtures. `followup.mp4` is a 10.7-second sequence of actual window captures
before the Send click, its click annotation, the pending state, and the completed
reply. Holds and timing are edited; this is not a continuous screen recording or
a measurement of submission latency. Window captures exclude an unrelated iMCP
macOS consent dialog that was left for the user. No permissions were granted or
reset by automation.

`focus-trace.json` contains only timestamps and active-app booleans from read-only
Cua sampling. Sampling proves return to msgblast; it does not prove that every
subsecond activation was sampled. The one-shot unread refresh, exact original
window restoration, production three-second stability interval, activation and
restoration failures, and no repeated Send are covered by composed deterministic
native regressions. Those regressions use fake driver processes and independent
native observations; they are distinct from these live checks.

Validation: 205 affected native tests passed, as did controller fixtures. Earlier
full-suite validation at `0c7a40a` ran 727 tests with one permission-dependent skip
and no failures. That earlier full run is not a full-suite result for this source.
A preceding live candidate (`46c07ae`) also imported a 990-word reply; the final
candidate checks here specifically revalidate first-send and repeated follow-up
behavior after the sticky-badge repair. This evidence does not establish readiness
of every other native app; PR 84 remains draft for separate Grok Bot verification.
