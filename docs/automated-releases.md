# Automated msgblast releases

This is a maintainer publishing runbook. For personal feature builds, use
[Build from source](build-from-source.md); for PRs, use [Contributing](../CONTRIBUTING.md).
Local previews and PR validation do not need the production secrets below.

`.github/workflows/release-adhoc.yml` runs on a pushed `vVERSION` tag, or a manual workflow dispatch from the default branch. It tests, prepares a Release app in the configured signing mode, signs the ZIP and appcast with Sparkle, publishes to the existing Cloudflare R2 host, and checks anonymous downloads. Production is configured with `MSGBLAST_SIGNING_MODE=developer-id`, including Apple notarization. The historical workflow filename does not select ad-hoc signing. The source repository is public; archives and the updater feed use the separately configured R2 host.

For the persistent Developer ID identity and Apple notarization setup, follow [developer-id-signing.md](developer-id-signing.md). Verify the repository variable and prior published manifest before each release. The workflow's unset-variable fallback is ad-hoc, but the publisher refuses a production downgrade after a Developer ID release. Missing credentials stop the run; reuse the existing credentials rather than switching signing modes. Explicit ad-hoc builds remain available for personal or diagnostic use without Apple credentials.

## One-time activation

Merge the workflow/updater changes onto the default branch first. A tagged commit must be reachable from that branch. A workflow file on a PR branch alone is not an activated release service.

Prepare a dedicated R2 bucket with a public HTTPS **custom domain**. The pipeline uses R2's authenticated S3 endpoint for writes and the custom domain for installed-app reads. A private GitHub asset URL or expiring presigned URL will not work. Use the custom domain for production distribution, not the rate-limited `r2.dev` development endpoint. The public base URL must end in `/`; any path below the domain becomes the bucket object prefix. For example, `https://downloads.example.com/msgblast/` maps to `msgblast/appcast.xml` and `msgblast/downloads/...`.

Configure the domain to respect object cache headers. In particular, **bypass cache for appcast.xml and release-counter.json**; the workflow serves them with `Cache-Control: no-store`. Archives are immutable and may be cached for a year. Do not add a blanket cache rule that overrides the feed policy.

Create a bucket-scoped R2 Object Read & Write API credential. It needs get/put access, including conditional puts; it does not need authority over unrelated buckets or repository settings.

Set these GitHub Actions repository variables:

| Variable | Value |
| --- | --- |
| `MSGBLAST_PUBLIC_BASE_URL` | Public custom-domain base URL ending in `/` |
| `MSGBLAST_R2_ACCOUNT_ID` | Cloudflare account ID |
| `MSGBLAST_R2_BUCKET` | Dedicated bucket name |
| `MSGBLAST_PUBLIC_KEY` | Persistent Sparkle Ed25519 public key, base64 32 bytes |

Set these GitHub Actions repository secrets:

| Secret | Value |
| --- | --- |
| `MSGBLAST_SPARKLE_PRIVATE_KEY` | Base64 32-byte Sparkle private seed; reuse across releases |
| `MSGBLAST_R2_ACCESS_KEY_ID` | Bucket-scoped R2 S3 access key ID |
| `MSGBLAST_R2_SECRET_ACCESS_KEY` | Corresponding secret access key |

Create the persistent signing key once with Sparkle's `generate_keys --account msgblast`, then obtain its public key with `generate_keys --account msgblast -p`. Securely export the private seed with `generate_keys --account msgblast -x /secure/temporary/key-file` and pass that file through stdin to `gh secret set MSGBLAST_SPARKLE_PRIVATE_KEY -R mgalpert/msgblast`. Keep the Keychain copy and a secure backup; remove the temporary export. Never put private keys in workflow YAML, command arguments, logs, source or release artifacts. Existing legacy 96-byte Sparkle key exports require migration before using this pipeline's 32-byte seed format.

The workflow writes the private seed to an owner-only file in the temporary runner directory, uses Sparkle's `--ed-key-file`, and removes the file in an `always()` step. Only the public key is embedded in the app. Keep the same key: installed clients trust the key in their bundle, so an accidental replacement prevents future updates.

No hosting account/bucket/domain is created by the workflow. Until these variables/secrets are configured, its preflight fails with the missing configuration name before building or publishing.

## Each release

Keep `release-notes/VERSION.md` brief: start with at most three short bullets about changes users will notice. Put setup instructions and technical detail after the highlights. Add a `## Contributors` section with linked GitHub handles and a specific thank-you; verify attribution from the release's commit range or pull requests. The sidebar shows the highlights and credits first, with full notes available on demand. `release-notes/highlights.json` supplies concise summaries for older long-form notes.

`release-notes/unpublished.json` excludes historical updater fixtures and failed release attempts from the app's history. Their original Markdown remains in the repository; the changes from 0.3.0–0.4.2 first shipped in 0.4.3.

1. Commit/review the intended source and write `release-notes/VERSION.md` with user-facing notes. Include the source on the default branch.
2. Read the live signed appcast and recent successful runs; choose a newer unused
   marketing version. Fetch the default branch and tags, identify the exact
   reviewed source SHA, and confirm that revision contains its release notes.
   Follow [AGENTS.md's tag procedure](../AGENTS.md#trigger-a-release) to push one
   annotated tag pinned to that revision. Do not tag an unreviewed local HEAD or
   move a published tag.

   Alternatively, dispatch **Release msgblast** from the default branch with the
   numeric marketing version, without a `v` prefix. Verify that run's headSha
   matches the intended source. Choose one trigger; never tag and dispatch the
   same release as two jobs. A source push alone does not distribute a build.
3. GitHub Actions performs the remaining steps. Its summary provides the published
   version/build, source revision, ZIP/installer URLs, and feed URL. Workflow
   artifacts have 30-day retention and repository Actions access rules; public
   archives and immutable release manifests remain on R2.
4. Follow [publication verification](../AGENTS.md#verify-publication-before-calling-it-released):
   successful run and correct SHA, signed feed and manifest, no-store latest.zip
   redirect, downloaded hash, bundle version/build/identity, and compiled green
   icon. Inspect the published manifest before retrying a failed final check.

Use the actual signing mode and allocated build from the successful run/manifest
when reporting a release. Defaults do not prove the mode of an existing release.
Historical version examples and development project defaults are not next-version
instructions; the production counter is allocated by Actions, never manually.

No coding agent is needed for repetitive build/sign/upload steps once activation is complete. Release notes and the decision to release a source revision remain part of preparing the tag.

## Production icon

Release preparation verifies that `msgblast/AppIcon.icon` matches the canonical green icon at `output/app-icons/msgblast.icon`, including its layer artwork. It stops before building if development/demo artwork has been substituted. Normal source builds use this green resource; development work can select the canonical `output/app-icons/msgblast-dev.icon` variant in an isolated workspace. Updater fixtures continue to select `AppIconDemo`.

## Fixed README download link

The README uses [the latest-download URL](https://updates.msgblast.app/latest.zip). The separate `download/` Worker returns a no-store 302 redirect to the highest build in the authenticated Sparkle feed. Successful publication of the appcast automatically advances the destination, with no README rewrite or per-release Worker deployment. Failed publication before the feed update keeps the old destination. See [download endpoint operations](../download/README.md).

## What the workflow does

1. Checks that the source is on the default branch, release notes and configuration exist, and Xcode 27 is selected on the `xcode-27` Apple Silicon runner. Official checkout/artifact actions are pinned by commit; the GitHub token has read-only contents permission.
2. Runs Python release/publication tests, core/controller Xcode regressions and the real Sparkle Debug integration fixtures. No live sends or Contacts writes are used for these tests.
3. Reads the prior appcast directly from authenticated R2, verifies its Sparkle signature, and reads the highest published build. Missing feed means first release; authentication/network/signature failures stop the release.
4. Atomically reserves the next counter in `release-counter.json`, taking the maximum of reserved and published counters before incrementing. Failed runs consume a number; gaps are expected and a rerun gets a fresh archive filename. Counters do not depend on Git commit count. A competing reservation fails safely instead of silently reusing a number.
5. In ad-hoc mode, builds a Release archive without Apple signing, copies its app,
   signs nested frameworks/helpers inside-out while preserving helper entitlements,
   then ad-hoc signs the outer app with hardened runtime and Automation entitlement.
   This mode explicitly disables library validation for ad-hoc nested code. Strict
   code-signature checks still apply; there is no Apple notarization or Gatekeeper
   acceptance claim. Developer ID mode instead follows the signing/notarization
   checks in [the signing runbook](developer-id-signing.md).
6. Packages the app and signs/verifies both archive and feed with the persistent
   Sparkle key. The manifest records the selected signing mode, notarization result
   (null for ad-hoc), hashes, and source revision.
7. Uploads the ZIP with an immutable filename, downloads it anonymously and checks its SHA-256, then uploads an immutable version/build manifest. It never overwrites an existing archive.
8. Publishes the signed appcast **last**, conditional on the prior feed's ETag (or its absence for the first release), then anonymously downloads and checks the feed hash. A concurrent publisher cannot replace a newer feed. A failed archive/download check leaves the previous feed intact.

The final anonymous feed check occurs after its conditional upload. If that check fails, the release may already be published even though Actions reports failure. Inspect the authenticated feed and immutable manifest before rerunning; do not assume the prior feed remains after this final-step failure.

Only one stable release workflow runs at a time. GitHub concurrency can replace an older pending run with a newer pending run; it does not cancel the running release. Check Actions for canceled pending tags and rerun those only if they should still be released.

## Install and operational limits

Install the first updater-enabled `msgblast.app` manually in `/Applications`. Verify Developer ID identity, hardened runtime, notarization, stapling and Gatekeeper acceptance in the actual production download. Explicit ad-hoc builds may require macOS first-launch approval and do not have Apple-verified publisher identity or notarization. Confirm Full Disk Access, Contacts and Messages Automation, and test their retention during a real distributed update; source or fixture checks alone do not prove installed permission retention.

Later releases can install through Check for Updates or automatic checks. Preserve app-owned drafts/attachments and verify the version after the first distributed update. Publishing an update does not force an immediate installation on every client.

To roll back, release the intended reverted source with a new tag/version or dispatch; the pipeline allocates a larger counter. Never reset the counter, lower the appcast build or replace an existing archive. If a run uploaded an archive but failed later, retain it and rerun; the next reservation advances the counter.

The workflow code and local tests do not prove that an unconfigured R2 host or GitHub runner is working. The first hosted workflow run and a real old-to-new installed-app update are activation checks. The same automated workflow supports Developer ID/notarization after the setup and verification in [developer-id-signing.md](developer-id-signing.md).

References: [Sparkle publishing](https://sparkle-project.org/documentation/publishing/), [R2 public buckets](https://developers.cloudflare.com/r2/buckets/public-buckets/), [R2 conditional S3 operations](https://developers.cloudflare.com/r2/api/s3/api/), [Xcode 27 runner image](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md).

## First-install disk image

Actions also packages the signed app in a drag-to-Applications DMG, signs the DMG with the persistent Sparkle key, and records its immutable URL, signature and SHA-256 in the version/build manifest. The publisher verifies and uploads both ZIP and DMG before updating the signed appcast. The existing fixed `latest.zip` endpoint remains the updater ZIP; use the manifest’s `installer_url` for the first-install DMG. No Apple notarization is implied.

Install the pinned metadata dependencies with `python3 -m pip install -r scripts/installer-requirements.txt`, then build a local installer with `python3 scripts/build_installer.py PATH/TO/msgblast.app OUTPUT.dmg`. Packaging writes and verifies Finder metadata directly, without launching Finder or requiring Automation permission. Release apps opened outside `/Applications` or `~/Applications` show installation guidance before creating the Messages model. Debug builds remain runnable from Xcode; downloaded, mounted and translocated Debug copies show the same guidance.
