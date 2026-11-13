# PR #97 evidence — Settings sidebar (head 417ab4e)

- Commit: `417ab4e4a251af834ccf8414aa902ed8b40e834b` (codex/organized-settings: f1451a9 with current main merged in; scripts only, no Swift change since f1451a9)
- Build: **msgblast Demo (Settings Final 417ab4e)**, bundle `com.msgblast.demo.settingsfinal417ab4e`, own support folder (`msgblast-Demo-SettingsFinal-417ab4e`), launched with `--demo --isolated-demo` (fixtures; nothing real is sent)
- Built on the Mac with Xcode 27.0 (`build-for-testing`); tested and captured in a separate macOS 26.5 test VM, so no personal Mac data is on screen. Screenshots are window-only captures of the Settings window (`screencapture -l`).

| File | Shows |
|---|---|
| 01-general.png | General: quick-access shortcut, conversation windows |
| 02-mac-apps.png | Mac apps (fixture connection states) |
| 03-webhooks.png | Webhooks: Grok Bot routine setup (demo, simulated) |
| 04-outside-agents.png | Outside agents: "Let agents on this Mac use msgblast" on; Claude Code, Codex, Terminal, and "MCP server on this Mac" rows; Tailscale toggle off with its hint (VM is not on a tailnet) |
| 05-remote.png | Remote, default off; no pairing code or QR |
| 06-permissions.png | Permissions (demo, simulated) |
| 07-sharing.png | Sharing choices |
| settings-tour.mp4 | 34 s, 900×708, window-only tour clicking General, Mac apps, Websites, CLI tools, Webhooks, Outside agents (local on, Tailscale off), Remote, Permissions, Sharing, Updates. The pink pointer is the test VM's automation cursor. |

## Test result at 417ab4e

UI test (VM, `test-without-building`):
- WorkflowTests/testSettingsNavigationRetainsSharingDraftAndCancelsShortcutRecording (visits every page incl. Outside agents and Remote) — **passed (30.5 s)**

Privacy check: every screenshot and every video frame (OCR at 2 fps plus visual review) was checked for usernames, home paths, IPs, tailnet names and keys; none appear.
