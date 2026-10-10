# Rabbit OS3 and local setup evidence

Captured application source: `81c4763876f45df300ea2119f1ee405c1eeed931`.
Initial base: `5cd8a394f28f37eab71359645810421da2fa19d5`.
Integrated upstream main: `53ef8e9067dc90f7086481c4bf6c189194d58352`.
This evidence-only branch adds media and capture records to that source; it changes no application code or build settings.

These native macOS captures use the blue **msgblast Demo** app built from the clean committed source with the repository preview packager. Its unique bundle ID is `com.msgblast.demo.runtime-guide-81c4763876f4`, with support directory `msgblast-Demo-RuntimeGuide-81c4763876f4`. Demo and onboarding preview are enabled; production updates are disabled. The packaged source revision, relevant source hashes and media hashes are in `capture-manifest.json`. Strict ad-hoc signature and compiled icon verification passed for both previews. Local version/build defaults remain 0.4.3 (1); they are not a published release number.

Actual CUA interactions selected OpenClaw, Hermes and rabbit OS3 in the requested chooser order; skipped browser import; read both local setup screens; verified rabbit Ready and the shared-account context notice; finished onboarding; submitted two different fixture questions in separate comparisons; and opened the OpenClaw and Hermes Settings sheets. The second comparison shows both requests and replies in rabbit's one conversation. The screenshots also show rabbit in the featured grid and installation status that does not claim provider setup is verified. No mobile UI changed.

`workflow.mp4` is a playable 41-second H.264 video assembled from native screenshot samples captured around those interactions. It scales and pads captures, repeats frames, omits intermediate navigation, and edits playback timing. It is not a continuous real-time recording and has no audio. No interface text or pixels were drawn into the captures.

All accounts, installation status, permissions and rabbit replies in the published media are synthetic. No real provider sign-in, browser cookie import, Terminal configuration, Messages send, Contacts write, paid request, OS permission grant or production update was exercised. Live rabbit authentication, current website markup and server delivery remain unverified. The blue-green Dev preview was separately refreshed and opened with the Hermes instructions visible; its live data is not included in this public evidence.

## Validation

- The integrated full native core suite passed 297 tests at `d300a0cc04f2efd338c17995ec1cac4f0e432488`.
- After the final normalized receipt repair, all 89 `MultiWebAgentTests` passed at the captured source. Both added regression cases failed before their repairs and passed afterward.
- The current onboarding runtime detection UI test passed, including the latest browser-import skip and updated installation caption.
- Web comparison/controller and quit/update lifecycle fixtures passed after the final repair. They use controlled replies and do not terminate/update a real app.
- Dev and Demo preview packaging passed with distinct identities, correct compiled icons, source metadata and strict signatures. Committed production artwork was preserved.
- Full code review and two focused follow-up reviews completed. The confirmed draft persistence, delayed receipt, whitespace matching and UI assertion findings were fixed; the final follow-up has no open findings. External paid model calls were not used for review.

The local native result bundles and review receipts remain outside the repository. These results describe the observed revisions, not future CI or live account behavior.
