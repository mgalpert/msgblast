# Business choice evidence

Source: `4e767b5710f0450174ea9ac59c9026d4e3d09a64`, October 12, 2026.
The verified executable was `build/business-choice-preview/msgblast Demo.app/Contents/MacOS/msgblast`, launched with `--isolated-demo --business-choices-preview`.

- `choices.png`: decoded synthetic quick-reply card with **Find Plumbers** and **Not Now**, both actionable in the isolated Demo.
- `selected.png`: chosen option checked, both actions disabled, one synthetic outgoing title and an explicitly simulated reply.
- `workflow.mp4`: real selected-window capture of that in-app interaction, at normal speed. It contains only the Demo window.

These are local sample inputs and responses. Demo does not invoke native Messages,
request Accessibility permission, or submit a Business response. Its synthetic
outgoing title is a fixture, not proof of Apple's structured reply transport.

Validation: full native `msgblastTests` passed before the final recovery/ordinary-empty-body polish; final `BusinessChoiceTests`, `MessagesDatabaseTests`, and `CoreTests` passed after that polish. The final actual app/controller fixture passed, including durable choice attempts and repeated-action blocking. Public binary quick-reply/list-picker archives decoded their expected options. Final preview packaging passed builds, signatures, icon and metadata verification.

Separately, the user authorized a live **Find Plumbers** test in Apple Messages.
The native client showed **Selected Option**, **Delivered**, and Poke acknowledged
that it was checking repair options. Scoped/background tool actions produced no
selection; foreground desktop input completed it. This verifies Apple's native
choice behavior, not the new app's AXPress path. The latter still needs an end-to-end
live check with msgblast's own Accessibility and Messages-history permissions.
Private live screenshots and conversation content are not included here.
