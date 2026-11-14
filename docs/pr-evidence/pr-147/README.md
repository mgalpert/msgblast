# PR 147 evidence: never show a pairing code without an address

Head commit tested: `33d80f5` (branch `claude/project-thread-eis2jx`; `origin/main` `eecd2ed` merged, no changes).
Build: "msgblast Dev (Pair Address VM 1114)", a local Dev test copy made with `scripts/build_test_app.py` from `33d80f5`, run in the shared foreground-test VM on 2026-11-14.

## Files

| File | Shows |
| --- | --- |
| `02-no-address-settings.png` | Settings → Remote with Remote on and Network set to "Tailscale only" on a Mac with no Tailscale address. Status reads "No Tailscale address on this Mac. Start Tailscale or choose another network option." Pressing "Pair a phone…" shows that reason in orange, plus "msgblast keeps checking and shows a code once the phone can reach this Mac", and no QR code is shown. |

No redaction was needed for this file: it shows no IP addresses, QR code, key fingerprint, usernames or tailnet names.

## Not captured

- `01-no-address-sidebar.png` (sidebar Phone panel showing the reason instead of a QR code)
- `03-code-appears.png` (QR code appearing on its own after switching Network to "Automatic")
- `04-recovery.mp4` (recording of that switch)

These were not captured because the shared VM kept receiving stray Tab key presses during the run. They landed in the test app's composer and kept its main window from drawing, so the sidebar Phone panel never appeared. No second VM could be started: two macOS VMs were already running, which is Apple's limit per Mac.

## Other coverage

- **Unit tests:** `RemoteListenerRecoveryTests` covers the listener retrying after a network change and on its timer while it has no address. `RemoteServerTests`, `RemoteInterfaceTests` and `RemoteListenerPortTests` also pass: 15 tests, 0 failures, on `96be0b1`. The full macOS unit target passed on `96be0b1` with 1113 tests, 0 failures and 1 unrelated skip. `33d80f5` adds only two log lines on top of it.
- **Real device:** a real iPhone paired with this Mac over Tailscale on 2026-11-14, using "msgblast Dev (Pair Address 1114)" built from `96be0b1`.
