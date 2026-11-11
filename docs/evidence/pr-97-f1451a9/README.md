# PR #97 evidence — Settings sidebar (final head)

- Commit: `f1451a929f0cf00db72e4e1bf4ff6e47c7f1fd17` (codex/organized-settings, main with #94 merged)
- Build: **msgblast Demo (Settings Final f1451a9)**, bundle `com.msgblast.demo.settingsfinalf1451a9`, own support folder, launched with `--demo --isolated-demo` (fixtures; nothing real is sent)
- Captured in a separate macOS 26.5 test VM (Xcode 27.0), so no personal Mac data is on screen. Screenshots are window-only captures of the Settings window.

| File | Shows |
|---|---|
| 01-general.png | General: quick-access shortcut, conversation windows |
| 02-mac-apps.png | Mac apps (fixture connection states) |
| 03-webhooks.png | Webhooks: Grok Bot routine setup (demo, simulated) |
| 04-outside-agents.png | Outside agents: "Let agents on this Mac use msgblast" on; Claude Code, Codex, Terminal, and "MCP server on this Mac" rows; Tailscale toggle off with its hint (VM is not on a tailnet) |
| 05-remote.png | Remote (from #94), default off; no pairing code or QR |
| 06-permissions.png | Permissions (demo, simulated) |
| 07-sharing.png | Sharing choices |

## Test results at f1451a9

UI tests (VM): all 5 passed
- WorkflowTests/testSettingsNavigationRetainsSharingDraftAndCancelsShortcutRecording (visits every page incl. Outside agents and Remote) — passed (31.8 s)
- WorkflowTests/testSettingsSharesOnboardingPermissionsAndEnablesContactsIndependently — passed
- WorkflowTests/testSettingsSetsUpEveryAvailableAppWithoutChangingDraftOrStartingOnboarding — passed
- WebServiceWorkflowTests/testAddNamedAccountFromSettingsAndOpenSeparateSignIn — passed
- OnboardingWorkflowTests/testSettingsOffersWebAlternativesDisabledForNewUsers — passed

Unit tests (Xcode 27.0): AgentControlTailnetSetupTests + AgentControlHTTPTests — 16 tests, 0 failures

Privacy check: every image was reviewed for usernames, home paths, IPs, tailnet names and keys; none appear.
