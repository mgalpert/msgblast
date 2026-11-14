# PR 147 evidence: never show a pairing code without an address

Build used for these captures: commit `33d80f5`, made as the local Dev test copy "msgblast Dev (Pair Address VM 1114)" with `scripts/build_test_app.py` and run in the shared foreground-test VM on 2026-11-14. That commit merged `origin/main` `eecd2ed` with no changes. Later commits on this PR, up to `6a16692`, change only how `RemoteListener.start` is structured, what happens when a start replaces a pending retry or follows a shutdown, and when Settings clears the old reason (see Observation). Otherwise the flow shown here works the same way at those commits.

## Files

| File | Shows |
| --- | --- |
| `02-no-address-settings.png` | Settings → Remote with Remote on and Network set to "Tailscale only" on a Mac with no Tailscale address. Status reads "No Tailscale address on this Mac. Start Tailscale or choose another network option." Pressing "Pair a phone…" shows that reason in orange, plus "msgblast keeps checking and shows a code once the phone can reach this Mac", and no QR code. |
| `04-recovery.mp4` | 42 s, entirely in Settings → Remote. (1) "Tailscale only": Status shows the reason, and "Pair a phone…" shows the orange reason with no code. (2) Network is switched to "Tailscale if available, otherwise local network" (Automatic), and Status changes to listening. (3) "Pair a phone…" now shows the QR code. |
| `03-code-appears.png` | Still of step 3: the QR code shown after the switch, with Status listening. |

## Redaction

- **`03-code-appears.png` and `04-recovery.mp4`:** solid boxes cover the "Listening on …" address, the key fingerprint and the address line under the QR code. The QR code is blurred until it can't be read. In the video, each mask starts before the item first appears: from 19 s for the status line and from 34 s for the code.
- **`02-no-address-settings.png`:** needed no redaction.
- **All files:** no usernames or tailnet names appear.

The port number is left visible.

## Observation

In the recording, after the switch to Automatic, the orange reason from the earlier "Pair a phone…" press stays on screen until "Pair a phone…" is pressed again; Status updates on its own. This was fixed in `6a16692`, after the recording: the reason now clears as soon as the Mac is listening again. The code still appears only after the button is pressed.

## Not captured

The sidebar Phone panel (`01-no-address-sidebar.png`) was not captured. In the shared VM, stray Tab key presses landed in the test app's composer and kept the main window from drawing. The Settings window was not affected.

## Other coverage

- **Unit tests:** `RemoteListenerRecoveryTests` covers the listener retrying after a network change and on its timer while it has no address.
- **Real device:** a real iPhone paired with this Mac over Tailscale on 2026-11-14, using "msgblast Dev (Pair Address 1114)" built from `96be0b1`.
