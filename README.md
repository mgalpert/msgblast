# PR 79 Muse input verification

Evidence-SHA: 9d491d177de7556deba361d2c9ecf8c140a2c731

Actual blue-green msgblast Dev built from this committed revision, installed with the existing development signing identity, deep/strict signature verified, live mode, production updates disabled. No permission grants were changed or reset. Muse 9.0 (1098887160) was used.

Cold run: Muse was fully quit before one initial Send. Dev launched Muse and created its own side chat, then observed the first reply and follow-up in that same UUID. No Reconnect, external Muse snapshot before the first reply, or manual Muse activation/input was used. Warm run: a second comparison created a different side chat, and its follow-up retained that UUID. All four attempts were observed. Screenshots show only these QA prompts and replies; no private app dumps are included.

The 29-second playable video is a continuous 115-second native-window capture played at 4x speed, without cuts or audio, scaled to fit. The app narrows to one chat column during the recording, leaving black padding. This is live delivery, not a fixture or screenshot sequence. No mobile layout applies to this native Mac workflow.

The regression executes the actual Muse adapter with controlled driver/native observations: two unchanged post-input readbacks must settle to the exact draft before one Send. It failed on the previous code with the exact prepared-draft error. The 115 affected tests passed after repair, including permanent no-op, partial text, lost focus, changed chat/history and generation refusal. Fixtures establish those guards, not provider delivery.

The original intermittent failure was not reproduced in two diagnostic live runs before this repair. Source inspection and the discriminating regression establish the immediate-readback race; successful final live runs do not prove every future WebKit or driver focus failure impossible. Input and uncertain sends are never automatically replayed.

Onboarding media retained elsewhere in PR 79 is explicitly labeled as native Demo from 2a927d2 with simulated permissions/installations/connections. This evidence refresh covers the changed Muse input workflow. Final native CI is linked in the PR description separately.
