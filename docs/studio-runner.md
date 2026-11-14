# Run the native checks on a Mac Studio

The `native` job in `validate.yml` builds the app and runs the core tests. On
GitHub's hosted `xcode-27` runner it starts from an empty machine every time,
so the Debug build alone takes about 20 minutes. On a Mac Studio that keeps
its derived data between runs, the build is incremental.

The workflow only uses the Studio when the repository variable
`MSGBLAST_STUDIO_RUNNER` is `true`. Without it, or if you delete it later,
everything runs on GitHub-hosted runners exactly as before.

## Who can run code on the Studio

This repository is public, and GitHub warns that a self-hosted runner on a
public repository can be made to run code from a fork: a pull request can
edit `runs-on` in its own copy of the workflow. Three things keep fork code
off the Studio:

1. **The job-started hook (the real guard).** The runner runs
   `scripts/ci/studio-job-started.sh` from a copy installed outside the
   repository before every job. It allows only pushes to `main`, manual runs,
   and pull requests whose branch is in this repository, and fails anything
   else before a single step runs. A pull request cannot change the installed copy.
2. **Approval for outside contributors.** GitHub will not start any workflow
   from an outside contributor's fork until you approve it. Before approving,
   check that the PR does not touch `.github/`.
3. **The `runs-on` expression.** Unedited workflows send fork pull requests to
   GitHub's `xcode-27` runner anyway.

Signing, release, and `pull_request_target` workflows never use the Studio.
Anyone with write access can still run code there, including code that edits
the runner's `.env` to drop the hook for later jobs, and runs share one build
cache, so give write access only to people you trust with that machine.

## One-time setup on the Studio

1. Create a separate standard macOS user for the runner (System Settings,
   Users & Groups). Branch code runs as this user, so it should not be able
   to read your own home folder, keychain, or SSH keys.
2. Log in as that user once and leave the session logged in (use fast user
   switching to go back to your own account). The tests launch the app, which
   needs a logged-in session. In Energy settings, stop the Mac from sleeping.
3. As that user, install Xcode 27 at `/Applications/Xcode_27.0.app`, which is
   the path the workflow sets in `DEVELOPER_DIR`. If Xcode is already installed
   elsewhere, an admin can link it:
   `sudo ln -s /Applications/Xcode.app /Applications/Xcode_27.0.app`.
   Then run `sudo xcodebuild -license accept` and `sudo xcodebuild -runFirstLaunch`.
4. On GitHub, open the repository's Settings, Actions, Runners, New self-hosted
   runner, and pick macOS and ARM64. Run the download commands it shows in the
   runner user's home folder, then configure it with the label the workflow
   asks for:

   ```
   ./config.sh --url https://github.com/mgalpert/msgblast --token <token from that page> \
     --name studio-1 --labels msgblast-studio --unattended
   ./svc.sh install
   ./svc.sh start
   ```

   `svc.sh` installs a LaunchAgent, so the runner starts whenever the runner
   user is logged in. The runner page should show it as Idle.
5. Install the job-started hook so the runner user cannot change it. From a
   checkout of `main`, an admin installs a root-owned copy, then the runner
   user points the runner at it from the runner's folder:

   ```
   sudo install -d -o root -g wheel -m 755 /usr/local/libexec/msgblast-runner
   sudo install -o root -g wheel -m 555 scripts/ci/studio-job-started.sh /usr/local/libexec/msgblast-runner/
   echo "ACTIONS_RUNNER_HOOK_JOB_STARTED=/usr/local/libexec/msgblast-runner/studio-job-started.sh" >> .env
   ./svc.sh stop && ./svc.sh start
   ```

   Reinstall it the same way whenever the hook changes on `main`.
   The hook only guards anything if the runner actually runs it. After the
   first job, open its log and check that "Set up runner" or the first step
   shows `Studio runner accepted`. If that line is missing, the hook is not
   installed and fork code would not be refused, so turn the variable off
   until it is. The hook needs `/usr/bin/python3`, which comes with the Xcode
   command line tools.
6. In Settings, Actions, General, under "Approval for running fork pull request
   workflows from contributors", choose "Require approval for all external
   contributors". Check that it is saved before the next step.
7. In Settings, Secrets and variables, Actions, Variables, add the repository
   variable `MSGBLAST_STUDIO_RUNNER` with the value `true`.

## Running more than one PR at a time

A runner takes one job at a time. To check two PRs at once, configure a second
runner in another folder with `--name studio-2` and the same label. Each
runner keeps its own derived data in
`~/Library/Caches/msgblast-ci/<runner name>/DerivedData`.

## Turning it off

Set `MSGBLAST_STUDIO_RUNNER` to anything other than `true`, or delete it. New
runs go back to `xcode-27`. To reset a bad build cache, delete the runner
user's `~/Library/Caches/msgblast-ci` folder.
