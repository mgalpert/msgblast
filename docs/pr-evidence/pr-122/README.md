# PR #122 evidence: test copies keep macOS grants

1. Built `Shared Grants A 1111` from ec88bf3 into slot a (`com.msgblast.development.test-a`), signed with the local Apple Development certificate (team C4XLZBEPK8).
2. Granted A Full Disk Access, Accessibility (Device Control and Data Access) and Screen Recording once in System Settings.
3. Quit A. Built `Shared Grants B 1111` from f6bb459 into the same slot, a different binary with a different name and support folder.
4. Launched B. It showed every permission as allowed, with no macOS prompt.

| File | Shows |
|---|---|
| `a-permissions.png` | A's Settings → Permissions after the one-time grant, all allowed |
| `b-launch-no-prompt.mp4` | B launching (onboarding "Allow access" already all on) and its Settings → Permissions, all allowed, no system prompt (window-only crop, 29 s) |
| `b-permissions.png` | B's Settings → Permissions, all allowed |
| `system-settings-screen-recording.png` | System Settings → Screen & System Audio Recording, msgblast rows only. B has no row of its own: it shares slot a's entry, which macOS labels with the first app's name (Shared Grants A 1111) |
| `system-settings-full-disk-access.png` | System Settings → Full Disk Access, msgblast rows only, same shared slot-a entry |
| `designated-requirements.txt` | `codesign -dr -` for A and B (certificate name redacted). They are identical, which is why the grant carries over |
