# Run Mac checks away from your working desktop

Use GitHub Actions for routine PR validation. `validate.yml` runs Python, download
and feedback Worker tests on Linux, and core/updater/permission/controller checks
on the configured `xcode-27` runner. Its manual dispatch has an optional `run_ui`
input for isolated UI tests on that runner. None of these workflows publishes an app.

For a focused native investigation, use another Mac reachable over Tailscale.
The remote runner sends a **committed Git snapshot**, builds in a fresh remote
workspace, and retrieves its logs/results. It refuses to run on the initiating
Mac and never falls back to local execution when SSH or the remote setup fails.

## Prepare a dedicated Mac

The target needs Apple Silicon, full Xcode 27 with first-launch setup completed,
Python 3.11+ and Git. Follow [Build from source](build-from-source.md) for
native prerequisites. Select Xcode on that machine or pass `--developer-dir`;
the script does not change machine-wide Xcode selection.
If SSH resolves Apple's older Python, pass `--remote-python /opt/homebrew/bin/python3`
or an absolute executable named `python3` for your installed Python 3.11+.
Versioned names such as `python3.14` are rejected so preflight and worker helpers
cannot select different interpreters. The selected bin
directory is used for the worker's Python helpers without editing shell profiles.

Connect both computers to the authorized tailnet. Configure a working SSH alias
with the remote username and key in your personal `~/.ssh/config`. Ordinary
OpenSSH over a Tailscale address works with macOS Remote Login; it does not require
the separate Tailscale SSH server. See [SSH over Tailscale](https://tailscale.com/docs/reference/ssh-over-tailscale).
Enable Remote Login only for the dedicated test account, following your tailnet's
access policy. Verify host keys through your normal trusted setup; the script does
not disable verification or install credentials.

For example, using your own alias and remote Xcode path:

```sh
ssh test-mac 'python3 --version; xcodebuild -version'
python3 scripts/run_mac_checks.py --host test-mac --revision HEAD \
  --suite controllers --output build/remote-controller-results \
  --developer-dir /Applications/Xcode_27.0.app/Contents/Developer
```

Commit the intended changes first. `--revision HEAD` excludes unstaged/staged
edits, ignored files, local accounts, and credentials. The manifest records the
resolved full SHA, remote machine, Xcode version, suite, and combined check/retrieval
exit code. `worker_exit_code` preserves the test process result; `results_retrieved`
and `retrieval_exit_code` describe archive retrieval. After successful worker execution,
failed retrieval is `retrieval-failed`, not `passed`; retrieval timeout leaves an
incomplete record and a nonzero exit code. Worker failures and deadlines keep their
original status/code when retrieval also fails. To see
the revision/target without connecting or running tests, add `--dry-run`.

## Choose the suite

| Suite | What runs |
| --- | --- |
| `core` | Native `msgblastTests` |
| `controllers` | Core tests, web/app/storage/feedback fixtures, configured CLI fixtures, report lifecycle fixtures, simulated permission checks |
| `updater` | Core tests and isolated Sparkle updater harness |
| `all` (default) | Core, controller, and updater checks; excludes UI |
| `ui` | Native `msgblastUITests`; requires `--allow-remote-ui` |

Core checks build the framework the executable fixtures need. The remote worker
uses a separate app identity, Demo artwork, and temporary fixture profiles. UI
tests explicitly request isolated Demo data. They still need an unlocked remote
desktop and the runner's native automation permissions. Use a Mac nobody is
actively using; these tests can open windows or alter focus on **that** Mac.
Do not reset permissions or authorize real sends to make fixture tests pass.

```sh
python3 scripts/run_mac_checks.py --host test-mac --revision HEAD \
  --suite ui --allow-remote-ui --output build/remote-ui-results
```

An SSH session alone does not establish a working UI test session. A locked
desktop or permission failure is a failure/limitation, not a passing interaction.
Demo fixtures do not prove live Messages, paid providers, or real TCC retention.

## Results and interruption

Use a fresh local output directory for each run. It contains `run.log`,
`manifest.json`, and `results.tar.gz` (logs plus the native `.xcresult`). Remote
workspaces remain in `~/Library/Caches/msgblast-tests/` for inspection; delete only
the recorded run directory after retaining the results you need. An `.xcresult`
is test evidence, not a playable PR interaction video.

A per-account remote lock prevents overlapping native runs through this worker.
SSH preflight has a 45-second deadline; transfers/results have a two-minute
deadline, and the test connection defaults to 90 minutes (`--timeout-seconds`
can change it). A timed-out test is recorded with exit status 124.
An interrupted SSH connection can leave a remote worker running. Inspect that
Mac's processes and the recorded workspace before retrying or removing a stale
`~/Library/Caches/msgblast-tests/native.lock`; never remove an active run's lock.
The runner records an incomplete status rather than claiming disconnected work
passed. If result retrieval fails, its remote path is printed and remains intact.

This tool does not enroll a GitHub runner, install Xcode/Tailscale, change tailnet
policy, or touch installed production apps. GitHub's native runner and a personal
SSH test Mac may be different machines. Keep runner credentials and personal SSH
aliases outside the public repository.

To request the GitHub UI run from a pushed feature branch:

```sh
gh workflow run validate.yml -R mgalpert/msgblast --ref YOUR-BRANCH -f run_ui=true
```

Manual dispatch also builds the existing Dev/Demo preview artifacts. Ordinary
PR validation leaves the UI option off; use its result separately from core
passes, and record any hosted-desktop/permission limits honestly.
