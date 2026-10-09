# msgblast agent instructions

## Contributor quickstart

msgblast is a public native macOS app for comparing AI answers across websites,
existing Messages chats, optional local CLI conversations, and Grok Bot. Help the
user build their feature locally and share a focused PR. Production distribution
is a separate maintainer action.

Read [Contributing](CONTRIBUTING.md), [Build from source](docs/build-from-source.md),
[Architecture](docs/architecture.md), and [Testing](docs/testing.md) before making
a feature change. [docs/README.md](docs/README.md) indexes the current guides.
Older plans, research, and evidence record their stated revisions; do not use
them as current setup instructions or proof that today's branch passes.

### Start from the intended source

- Inspect branch, index, working tree, remotes, and applicable instructions before
  editing. Preserve existing work and commit only the requested files.
- For a new task, fetch the current upstream default branch and record its full
  SHA. In a fork, `origin` is normally the user's fork and `upstream` is
  `mgalpert/msgblast`; verify rather than assuming. Use a descriptive `codex/`
  branch by default. Existing authorized work continues from its intended ref.
- Verify the recorded base is an ancestor of the working branch. Report a stale
  or wrong base instead of resetting existing work. Include `Base-SHA:` and
  `Evidence-SHA:` in the PR.
- No production secret, Apple Developer ID, Cloudflare login, or release tag is
  needed to implement a feature or package the local previews.

### Build and inspect the right app

- Use full Xcode 27 and Python 3.11+. The recommended preview packager is
  `scripts/build_preview_apps.py`; exact commands are in the build guide.
  It creates separate blue-green **msgblast Dev** and blue **msgblast Demo**
  identities/profiles with production updates disabled, and preserves the
  committed production icon by staging changes in a temporary workspace.
- Use Demo for simulated sends, fixture demonstrations, and PR evidence. Dev
  uses live accounts/data; do not pass `--demo` or `--isolated-demo` to Dev.
- Keep the installed production app and its support folder intact. A different
  output path, bundle name, icon, or derived-data folder alone does not isolate
  state. Preview packaging configures both identity and support folder.
- The preview script copies working-tree edits; its `--sha` is metadata, not
  proof that the built source matches a commit. For reviewed evidence, rebuild
  the committed revision and record fixture/live limits.
- Inspect the actual changed workflow. Do not send real Messages, write real
  Contacts, request paid model work, or reset permissions merely to get evidence
  without authorization for that workflow.

### Implement with the existing boundaries

- Menus/scenes: `msgblast/App/msgblastApp.swift`; main orchestration:
  `AppModel.swift`; native views/windows: `msgblast/Windows/`; shared models and
  integrations: `msgblast/Core/`; state/attachments: `msgblast/Storage/`.
- Treat `scripts/generate_project.py` as the Xcode project source. After adding
  or removing Swift files, or changing targets/resources/settings, regenerate
  with `python3 scripts/generate_project.py` and review the generated diff.
  Keep both icon resources registered. Do not fix only generated output.
- Preserve existing Codable data, session/working-directory identity, migration
  backups, drafts, attachments, private/shared scope, and send receipts.
  Never replace failed-to-load state with an empty store or mutate Messages'
  database; history access stays read-only.
- Websites, optional configured CLI conversations, restricted comparison reports,
  and Grok Bot are distinct execution/account boundaries. Do not merge their
  authentication, permissions, private histories, or retry policies.
- Keep updates and fixture/live behavior explicit. A successful send call is
  submission evidence, not delivery; uncertain sends are not automatically retried.
- Keep documentation and third-party notices current with behavior/dependencies.

### Verify and share

- Use the testing guide to select native unit/UI tests, controller fixtures,
  Python tooling, Worker/feedback checks, or updater verification. Use meaningful
  existing tests; documentation-only changes need instruction/link verification.
- Linux checks do not prove a native app build. CI core tests do not prove native
  UI interactions. Record pending or unavailable validation honestly.
- PRs must include the real changed-feature screenshots and playable video,
  revision identifiers, a description of the behavior, and validation limits.
  See Contributing and the evidence requirements below. Refresh evidence when
  it no longer represents the reviewed change.
- Contributor PRs do not require release tags, production counters, deployments,
  or Actions secret changes. Perform those only for an explicitly requested
  maintainer operation using the corresponding runbook.

## App icons

- **Live/production app (default for users):** use the green icon imported from the user's `msgblast.icon` bundle. Its canonical project source is `output/app-icons/msgblast.icon`. Ensure `msgblast/AppIcon.icon` matches this bundle exactly when preparing a live build or release.
- **Development app:** use `output/app-icons/msgblast-dev.icon`, a duplicate of the live artwork with the saved blue-green background. Copy it to `msgblast/AppIcon.icon` only for an isolated development build; restore the green live bundle before release.
- Blue-green development previews use live data. Do not launch msgblast Dev with `--demo` or `--isolated-demo`; use the blue msgblast Demo app for simulated data, fixture demonstrations, and PR evidence.
- **Demo/fixture app:** use `output/app-icons/msgblast-demo.icon`, a duplicate of the live artwork with the saved blue background. Its app resource is `msgblast/AppIconDemo.icon`.
- Standard builds select `ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon`. `scripts/build_demo.sh` selects `AppIconDemo`. Verify the selected artwork matches the intended live, development, or demo build before building or publishing; choosing Release alone does not switch the development icon to green.
- The previous exploration 32 bundles under `output/icon-gradients/` are historical artwork. Do not use them for new builds or site branding.
- The public website at `https://msgblast.app` is served by the Cloudflare `msgblast-landing` Worker from the owner's separate landing checkout (currently `/Users/contains/projects/msgblast/landing/dist`); its source and deployment instructions are in that checkout's `README.md` and `wrangler.jsonc`. This owner-local path is not a contributor prerequisite. The Sites URL is a separate private preview.
- The public website uses a native macOS export of `output/app-icons/msgblast.icon` for its brand icon, favicon, and social card. Refresh those assets when the canonical live artwork changes; updating the private Sites preview does not update the public domain.
- Preserve the user's saved artwork when copying these icons into the app resources. Keep both icon resources registered in `scripts/generate_project.py` and the generated Xcode project.
- Validate icon changes with an isolated derived data directory. The demo script uses `build/icon-demo` and packages `build/Build/Products/Debug/msgblast Demo.app`. Do not overwrite or restart the user's running development app merely to validate an icon change.

## Building and publishing app updates

The default distribution path is now **automated ad-hoc releases without Apple credentials**. `.github/workflows/release-adhoc.yml` runs for pushed `vVERSION` tags or manual dispatches from the default branch. Pushing ordinary source commits does not distribute a new app. The workflow tests, builds, ad-hoc signs, signs the Sparkle ZIP/feed, uploads to an existing public R2 host and verifies anonymous downloads. No coding agent needs to repeat build/sign/upload commands each release.

These are maintainer operations. Read `docs/automated-releases.md` before activating or changing the pipeline; use `docs/developer-id-signing.md` for optional Developer ID/notarization and `docs/updates.md` for updater/local preparation details. The workflow must be on the default branch and release source must be reachable from it. The source repository is public; installed apps still use the separately configured public HTTPS archive/feed host.

### One-time activation

- Configure a dedicated Cloudflare R2 bucket and HTTPS custom domain. Set Actions variables `MSGBLAST_PUBLIC_BASE_URL` (ending in `/`), `MSGBLAST_R2_ACCOUNT_ID`, `MSGBLAST_R2_BUCKET` and `MSGBLAST_PUBLIC_KEY`.
- Set Actions secrets `MSGBLAST_SPARKLE_PRIVATE_KEY` (persistent base64 32-byte seed), `MSGBLAST_R2_ACCESS_KEY_ID` and `MSGBLAST_R2_SECRET_ACCESS_KEY`. Scope the R2 credential to the release bucket. Apple certificate/team/notarization credentials are not required.
- Generate the Sparkle key once, retain its Keychain copy and secure backup, and reuse it across releases. Never put private keys in YAML, command arguments, logs, PRs, source or assets. The workflow uses an owner-only temporary seed file outside artifacts and removes it with `always()` cleanup.
- Respect archive cache headers and bypass cache for `appcast.xml` and `release-counter.json`. Do not host the feed behind GitHub login, expiring tokens or a development `r2.dev` URL.
- Preserve bundle identifier `com.msgblast.mac`, update key and installed app location. Users whose current version lacks Sparkle need one manual installation into `/Applications`; ordinary development builds with no feed/key cannot receive updates.

The README download URL is fixed at `https://updates.msgblast.app/latest.zip`. The `download/` Worker verifies the published signed appcast and redirects to its highest build; releases do not require README edits or Worker redeployments. Keep the redirect uncached and archive names immutable. See `download/README.md` for maintaining the endpoint and the limits of request logs as download metrics.

### Version and build numbers

- Use `MAJOR.MINOR.PATCH` for the user-facing version. Increase PATCH for fixes, MINOR for new features, and MAJOR for incompatible changes after 1.0. During 0.x development, incompatible changes also advance MINOR. Reset lower components when advancing a higher component. Documentation-only commits do not need an app release.
- Read the current published `appcast.xml` and recent successful Actions runs before selecting a version. Examples below use `0.1.3`; they are examples, not a permanent next-version setting. Do not infer the published version from a local development app.
- `CFBundleShortVersionString` is the marketing version; `CFBundleVersion` is the automatically allocated build counter. About must show the distributed values, for example `Version 0.1.3 (5)` if Actions actually allocated build 5.
- The publisher allocates the counter from `release-counter.json` and the authenticated signed feed. Never choose, reset, or manually increment a production build counter. Failed reservations leave gaps; reruns use a new counter.
- The release workflow passes `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` to Xcode. Keep Info.plist's build-setting substitutions intact. Local project defaults in `scripts/generate_project.py` and the generated project are development defaults; changing those alone does not publish or prove a release version.
- Choose a new marketing version for new published source. A retry of an unsuccessful release can reuse its intended marketing version, with a fresh allocated build. Never replace previously published archive bytes or move a published tag.

### Push source changes

1. Inspect the branch, index, and working tree before editing or committing. Use an isolated `codex/` branch/worktree when other work is present. Commit only the requested files; do not absorb unrelated changes or reset the user's checkout.
2. Complete the change and relevant checks. For an app release, add concise user-facing `release-notes/VERSION.md` to the same reviewed source. Verify the saved green production artwork matches `msgblast/AppIcon.icon`; `scripts/release.py` enforces this before building.
3. Push the source branch and get the intended changes reviewed and merged onto `main`. Honor the PR evidence requirements below. Fetch `origin/main` and identify the exact reviewed release revision. Do not force-push `main`.
4. A source push or PR merge does **not** publish an app. Trigger distribution when the user requests a release/update. Report source-only work as source-only until publication has been verified.

### Trigger a release

Prefer an annotated tag pinned to the reviewed revision. Run the commands separately, check each result, and stop on failure. First confirm the version is newer than the published version and the tag is unused. After the source and release notes are merged:

```sh
git fetch origin main --tags
release_version=0.1.3
release_revision=$(git rev-parse origin/main)
git cat-file -e "$release_revision:release-notes/$release_version.md"
git tag -a "v$release_version" "$release_revision" -m "Release $release_version"
git push origin "v$release_version"
```

Verify `release_revision` is the reviewed commit before tagging. The workflow requires tagged source to be reachable from the default branch. Never use an unreviewed local HEAD merely because the local branch is named `main`.

Alternatively, dispatch the workflow from `main` with a numeric version, without the `v` prefix:

```sh
gh workflow run release-adhoc.yml -R mgalpert/msgblast --ref main -f version=0.1.3
```

Dispatch builds `main` as resolved for that run. Verify the run's `headSha` matches the intended source; use a tag when the revision must be pinned. Choose **one** trigger per release. Do not push a tag and dispatch the same release as two separate jobs.

Actions handles testing, building, ad-hoc signing, Sparkle signing, counter allocation and R2 publication. Do not repeat those steps manually or add Apple credentials for this distribution path.

### Verify publication before calling it released

1. Identify the run belonging to the chosen tag/dispatch and check its source SHA. Wait for completion and inspect its conclusion and summary. A queued, canceled, failed, or unfinished run is not evidence of a successful release.

   ```sh
   gh run list -R mgalpert/msgblast --workflow release-adhoc.yml --limit 5
   gh run view RUN_ID -R mgalpert/msgblast --json status,conclusion,headSha,url
   gh run watch RUN_ID -R mgalpert/msgblast --exit-status --interval 20
   ```

2. Check the published signed feed and immutable `releases/VERSION-BUILD.json` manifest. Confirm version, allocated build and `source_revision`; use the actual allocated build from the run, not a predicted counter.
3. Check that `https://updates.msgblast.app/latest.zip` returns a no-store **302** to the manifest's immutable ZIP URL. Download through that fixed URL and compare its SHA-256 with the manifest. Use the known verifier User-Agent for CLI checks:

   ```sh
   curl -fsSI -A msgblast-release-verifier https://updates.msgblast.app/latest.zip
   ```

4. Inspect `msgblast.app/Contents/Info.plist` inside the downloaded ZIP: the version/build must match the feed and manifest, the app name must be `msgblast`, and the bundle ID must be `com.msgblast.mac`. Inspect the compiled icon in the downloaded artifact and verify the green production icon. Inspecting only source artwork does not prove the distributed icon is correct.
5. The README keeps `https://updates.msgblast.app/latest.zip` without a hardcoded version label. A successfully published feed advances the redirect automatically; do not rewrite the README for each build or point it back to an old immutable archive.
6. Report the verified version/build, release result and fixed download link. Publishing does not mean the user's installed app has updated. For the first hosted update, validate install/relaunch and retention of drafts, attachments, agents, comparisons, preferences and macOS permissions with the user's authorized setup. Do not send real messages, write real Contacts, overwrite the user's live app or reset permissions solely to validate a release. Keep fixture limits labeled in PR evidence.

### Failed releases and rollback

- Inspect the failed step, signed feed and immutable manifest before retrying. If failure occurs after the conditional feed upload, the release may already be live even though the final anonymous check failed.
- Fix the cause, then rerun the same intended release only when appropriate. Its build counter will advance; do not delete published objects, reset the ledger, reuse a ZIP filename, or force-move the tag. If fixing source changes the tagged revision, choose a new version/tag.
- GitHub can replace an older pending concurrency run with a newer pending run. Check canceled runs and decide whether their source should still ship; do not blindly rerun every canceled job.
- Rollback is a new release of the intended reverted source with a new marketing version and a larger automatically allocated build. Lowering the feed counter does not downgrade installed clients.

The publisher verifies the existing signed feed directly from authenticated R2, then atomically reserves the next counter in `release-counter.json`. Counters are independent of Git commit count; failed attempts consume numbers and reruns get fresh immutable archive names. Never reset the ledger or reuse a filename for different bytes. It uploads/verifies the ZIP first, retains an immutable manifest, and updates the signed feed **last** with an ETag condition. Signature, authentication or public download failures stop publication; a competing publisher cannot replace a newer feed. GitHub may replace an older pending concurrency run with a newer one: inspect canceled pending tags before deciding to rerun them.

Ad-hoc app signing is explicit and unnotarized, with disabled library validation for nested ad-hoc code and strict code-signature verification. Sparkle still authenticates both feed and ZIP with Ed25519. First-launch approval may be needed, and TCC permission retention must be verified on actual distributed updates. Do not claim Apple-verified publisher identity, Gatekeeper acceptance or notarization for this path. Developer ID remains the default for direct `scripts/release.py` calls; use `--signing-mode ad-hoc` for this credential-free path rather than silently falling back when Apple credentials are absent.

Signing-key/identity changes require a deliberate migration. Missing R2 hosting or Actions variables/secrets are activation prerequisites; committed workflow code alone does not prove live distribution is configured.

## Cursor Cloud specific instructions

Hosted Cloud Agents run on Ubuntu and cannot validate the native Mac app. Follow [docs/cloud-agent.md](docs/cloud-agent.md) for install, Linux checks, the non-publishing native workflow, GitHub access limits, and release verification. Linux tests are not a substitute for `.github/workflows/validate.yml` on the `xcode-27` runner.

- Start new tasks from fresh `main` unless the user specifies another pushed branch or exact commit. Fetch the intended base, record its resolved SHA, verify it is an ancestor of the working branch before editing, and include `Base-SHA:` in the PR. Report a stale/wrong base instead of resetting existing work. Cursor defaults are `mgalpert/msgblast` / `main`; the saved environment enables stale-build updates with a threshold of `0`.
- Install with `bash scripts/cloud-agent-install.sh`. It pins `scripts/installer-requirements.txt` in `${MSGBLAST_INSTALLER_VENV:-$HOME/.msgblast-installer}` and runs `npm ci --prefix download`. Do not commit `.cursor/environment.json`; that file overrides the saved environment.
- Linux checks: `python3 -m unittest discover -s scripts/tests -p 'test_*.py' -v`, then `npm test --prefix download` and `npm run check --prefix download`. The Wrangler check is a dry-run and does not deploy.
- Native core checks belong to `validate.yml` (`msgblastTests` plus `scripts/test_updates.py` on `xcode-27`). Cursor PR branches (`cursor/*`) and manual `workflow_dispatch` also build two ad-hoc preview ZIPs in that workflow: blue-green `msgblast Dev.app` (`com.msgblast.development`) and blue fixture `msgblast Demo.app` (`com.msgblast.demo`, `msgblastDemo` true). Artifacts stay on the Actions run for 14 days. Do not dispatch `release-adhoc.yml` as a test.
- Pull request descriptions need `## Screenshots`, `## Video`, and `Evidence-SHA: <branch head>`. `.github/workflows/pr-evidence.yml` rejects missing, local-only, placeholder, or stale evidence, including an empty or local `<video>` tag. Cursor branch previews also need separate `msgblast Dev SHA-256:` and `msgblast Demo SHA-256:` lines. A human still checks that the pictures show the change. A written exception is for that person to review; the checker does not treat it as a pass. Native UI evidence needs an authorized isolated Mac; Ubuntu cannot capture it, and an `.xcresult` is not a video. Do not use the user's live Mac without setup authorization.
- Keep Sparkle and R2 secrets in Actions only. Recheck `gh auth status`, the live appcast, and recent successful runs before any release. Historical baselines in `docs/cloud-agent.md` are observations from their stated dates, not the current published version or a next-version setting.

## Pull request evidence

- Every PR I create or update must include **Screenshots** and **Video** sections in its description showing the changes in that PR. A screenshot of whatever browser tab happens to be open does not count. Include `Evidence-SHA: <40-character branch head>` so `.github/workflows/pr-evidence.yml` can reject stale evidence. Cursor branch previews also name `msgblast Dev`, the `msgblast Demo` fixture, the Actions run URL, and separate lines `msgblast Dev SHA-256:` and `msgblast Demo SHA-256:` with different hashes. The workflow checks structure only; a human still has to confirm the images and video show this change.
- Capture the actual changed feature or workflow from the reviewed revision. Include desktop and mobile screenshots for responsive UI changes, and a short video showing the relevant interaction and result. Show before/after states when they make the change clearer.
- Embed screenshots and embed or directly link a playable video in the PR description; local-only file paths are not sufficient for reviewers. Keep evidence within the repository's existing access boundary.
- For nonvisual changes, show the relevant terminal/API workflow when feasible. If meaningful visual evidence cannot be captured, write the reason for a person to review. `scripts/check_pr_evidence.py` does not accept that explanation, an empty `<video>`, a local file, an unrelated image, or an example hidden in a code fence, indented code block, HTML comment, pre or code element, inline code, or escape. This setup change can record the workflow, so its screenshots and playable video stay mandatory.
- Label local fixtures, simulated inputs, edited timing, and other demonstration limitations accurately. Refresh evidence after changes that affect what it demonstrates. Do not start paid jobs or live matches solely to capture evidence without existing authorization.
- When the user asks for screenshots of a PR, show the changed feature's evidence, not the currently open browser page.
