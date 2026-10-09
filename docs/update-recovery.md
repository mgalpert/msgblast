# Recover an update blocked by saved state

This is user recovery guidance. Contributor previews should use the separate
profiles in [Build from source](build-from-source.md). For developer storage and
migration work, read [Architecture](architecture.md#state-credentials-and-compatibility)
and [Testing](testing.md). Version numbers below describe the historical
compatibility issue, not the current latest release.

An older msgblast can reject state written by a newer app or preview. For example, 0.4.3 cannot decode comparisons containing the separate Codex CLI or Claude Code providers introduced in 0.5.0. Its save guard protects the file, but also refuses the quit request required by Sparkle.

## If an older app is already stuck

The new release cannot change code in an already running older app. Use a one-time manual installation:

1. Copy any text entered in the current window to a safe place. The older app may be unable to save it.
2. In Finder, use Go → Go to Folder and enter `~/Library/Application Support/`. Copy the entire `msgblast` folder to a safe backup location. Do not delete, rename, or replace the original folder.
3. Choose Apple menu → Force Quit → msgblast. Ordinary Quit may show the same save error.
4. Download [the latest signed update ZIP](https://updates.msgblast.app/latest.zip), open it, and replace **only** `/Applications/msgblast.app` with the downloaded app. Do not delete its Application Support folder. Keep the app in its existing installation location.
5. Open msgblast and check About for the installed version. State written by 0.5.0/0.5.1 is understood by 0.5.2. Confirm your saved comparisons and drafts are present. If macOS asks for an existing permission again, review that request.

Do not reset `state.json` to get past the alert. If a newer app still cannot load the file, keep the backup and recovery snapshots for repair. Manual installation upgrades the reader; it does not repair arbitrary malformed JSON or disk permissions.

## Behavior in 0.5.2 and later

Sending and ordinary state writes remain blocked after a load/save failure. Quit and Install and Relaunch instead write a recovery snapshot under:

`~/Library/Application Support/msgblast/Recovery/<unique-id>/`

- `original-state.json` preserves the original file byte for byte, when it can be read. If reading fails, `original-read-error.txt` records the error and the original remains untouched in its existing location.
- `drafts-state.json` preserves the current in-memory state, including draft text and staged attachment references.

Each attempt uses a separate folder. All snapshots are retained, including snapshots from failed attempts; repeated recovery attempts can use additional disk space. Directories are private (0700) and files are private (0600). The main `state.json` is never overwritten by this path. Recovery snapshots are retained for manual recovery; they are not automatically merged into the main state. Referenced attachments remain in their existing location.

The app still waits for active submissions, shuts down agent processes through the normal lifecycle, and cancels quitting if recovery cannot be saved. Existing successful-load saves retain their original behavior: an ordinary disk-write failure blocks quitting rather than silently discarding drafts.

Production, development, and demo apps have separate support directories. Run isolated previews instead of giving them the production support directory. Opening an older production app after newer code has written production state is still a compatibility hazard.
