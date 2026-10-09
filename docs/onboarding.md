# Guided onboarding

New installations choose agents from one multi-select grid. All tiles have the same dimensions, including Another Messages agent. The picker has no scrolling, category headings, help-to-choose link, or Set up later action. At least one selected agent must be ready for chat before the workspace opens.

## Connection queue

Selected website accounts and CLI conversations get individual setup screens. Setup loads only the current connection and never sends a prompt. A recognized, usable account can advance automatically. An unknown account or page layout stays in setup with Check again and Skip for now; it is not described as signed out merely because readiness is unknown.

Grok Bot has its own setup screen with the exact `GrokBotService.routineInstructions` visible and selectable, Copy prompt, and connection fields. The webhook key is masked and remains outside normal app state. Configuring the callback connection does not submit a Bot task or prove that the remote routine accepts a request. Existing native credential storage and callback handling remain unchanged.

OpenClaw and Hermes reuse their existing installation detection and user-triggered Terminal setup. Their capabilities are stated directly: Hermes supports comparison reports, and neither currently supplies a chat pane. Acknowledging their setup does not satisfy the chat-ready requirement.

Instinct, Fo, Szn, and Another Messages agent share one screen. Messages history and Contacts access are requested once, only when missing. Users choose and confirm each contact/address. An agent with no eligible existing one-to-one conversation shows Open Messages and Check again. Its selection is not considered connected until routing succeeds. Automation permission stays contextual to the first explicit Messages send.

After the connection queue is resolved, a final screen explains that feedback is available anytime from Help → Share Feedback… and shows the native menu with that command highlighted. Start chatting checks that a selected connection is still usable, acknowledges the tip, and opens the workspace. Disabling the sole connected agent during the tip returns to the picker for another connection. Opening the feedback window leaves onboarding in place and never submits feedback automatically.

Individual agents may be skipped. Skipping every chat-capable selection returns to the picker; it cannot open an empty workspace. After one connection is ready, remaining selections can be skipped and revisited through Finish setup.

## State and lifecycle

`AppState.onboarding` is optional so legacy stores still load. `AppModel` distinguishes a fresh store before saving it and only initializes onboarding for new installations. Legacy accounts, drafts, comparisons, receipts, and web-store identities retain their existing paths.

`OnboardingState` persists selection, completion/skip intent, and chosen Messages contact IDs. On a partial-setup restart, completion is recomputed from actual accounts and permissions. Restarting from the feedback tip returns to connection verification before showing the tip again; finished onboarding remains finished. No credential or Messages transcript is added to onboarding state. Skipped providers are not selected for shared sends or shown as chat panes.

The Grok Bot resource stays unchanged; `AgentArtwork` crops and masks its displayed avatar to a circle for all app surfaces.

## Verification

`OnboardingTests` covers queue grouping, skip/complete transitions, the mandatory chat connection, separate runtime setup, legacy decoding, and saved contact/selection intent. `OnboardingWorkflowTests` exercises multi-selection, the workspace gate, exact Grok Bot prompt, contact confirmation, tile dimensions, and the absence of a picker scrollbar.

The DEBUG-only demo preview accepts `--demo --isolated-demo --onboarding-preview`, or a demo bundle with `msgblastOnboardingPreview` enabled. Accounts, contact candidates, existing conversations, and Grok Bot callbacks in this preview are simulated. It advances on Continue so each screen can be inspected. No live sign-in, provider request, Messages send, Contacts write, or permission grant occurs in that fixture workflow.

Native checks use an isolated derived-data directory and `AppIconDemo`. Production account/permission behavior still requires a deliberate authorized live check; fixture evidence does not prove a live permission grant or webhook routine.
