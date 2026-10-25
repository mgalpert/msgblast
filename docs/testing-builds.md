# Publish a feature testing build

Use **Publish testing build** (`test-build.yml`) to share a signed, notarized
**msgblast Dev.app** with outside testers. Downloads are GitHub prerelease assets
in this public repository. Feature code and testing notes will be public too.
The workflow never uses R2, the production appcast, Sparkle secrets, release
counters, or `v*` tags. It does not update installed production apps.

## Activate once

Merge this workflow and its tooling into the default branch before dispatching.
Reuse the existing repository Apple signing/notarization secrets and variables
from [Developer ID signing](developer-id-signing.md); no new certificates are needed.

Create the GitHub environment **test-build-signing** with:

- A required maintainer reviewer. Self-review may remain enabled for a sole maintainer.
- Administrator bypass disabled.
- A custom deployment branch policy allowing only the default branch, as a branch
  (no tag rule or wildcard).

The resolver checks these rules and fails before building if approval is missing.
Environment configuration is repository state, not something merging YAML creates.
Recheck it before publishing. Ordinary PR validation and ad-hoc previews stay unchanged.

## Publish

1. Fetch the repository, choose a full 40-character SHA on a pushed branch in
   this repository, and review its changes. Unmerged feature branches are supported;
   fork-only source must first be reviewed and pushed to a maintainer-owned branch.
   A workflow from `main` supplies the trusted signing and publishing scripts.
2. Write a short feature title and public instructions describing what to try,
   expected results, and known limits. Do not put private reports or account data
   in the notes. Testing builds support Apple Silicon and Intel Macs running macOS 15+.
3. Dispatch from the default branch, using a JSON file so multiline notes and
   user text are not interpreted by a shell:

   ```sh
   gh api --method POST repos/mgalpert/msgblast/actions/workflows/test-build.yml/dispatches \
     --input /PRIVATE_TEMP_DIRECTORY/testing-dispatch.json
   ```

   The file has this shape; replace the example values with the chosen source:

   ```json
   {
     "ref": "main",
     "inputs": {
       "source_revision": "FULL_REVIEWED_40_CHARACTER_SHA",
       "feature_title": "Composer testing",
       "testing_notes": "Try editing a draft, closing the window, and reopening it.\nExpected: your draft is retained."
     }
   }
   ```

4. Identify the resulting run by workflow, initiator, dispatch time, and input SHA;
   do not assume the first listed run belongs to you. Watch it with
   `gh run view RUN_ID -R mgalpert/msgblast` and inspect its summary.
   Feature code runs the Python and native core checks and builds an ad-hoc Dev
   artifact without signing secrets or a write token.
5. The signing job waits for **test-build-signing** approval. Its job name includes
   the full source SHA. Review the resolver summary and selected revision, then
   approve that deployment in GitHub. An agent should leave this decision to the
   maintainer; do not automatically approve its own pending deployment.
6. Trusted default-branch code extracts the bundle as data, verifies its Dev
   identity, source, blue-green icon, disabled updater, and universal binaries
   (app, frameworks, cloudflared, and embedded CuaDriver), then signs and notarizes
   it with the existing Apple identity. It never executes feature scripts or the
   feature app while credentials are available. A separate job with a write token
   publishes the signed package.
7. Publication reserves a new tag pinned to the selected source, then creates a
   draft prerelease tagged `test-FULL_SOURCE_SHA-RUN_ID-ATTEMPT`, uploads the Dev ZIP and two public
   manifests, downloads and compares all assets, and checks the tag target before
   publishing. The release is explicitly marked prerelease and never latest.
   The final check anonymously downloads the public ZIP and verifies its SHA-256.

After success, share the release page from the run summary. Verify its source SHA,
the `preview-manifest.json` signing/notarization status, and `test-release.json`
download URL/hash. A run's `headSha` is the trusted workflow revision on `main`;
the tested feature revision is the input/resolver/manifest SHA. Record both when
reporting a build. GitHub Actions artifacts expire after 14 days; published release
downloads remain available until someone explicitly removes the release/assets.

## Tester experience

Download and unzip the Dev ZIP, then drag **msgblast Dev.app** to Applications.
Keep **msgblast.app** installed. Dev has its own blue-green icon, bundle identity,
preferences, and `~/Library/Application Support/msgblast-Dev` folder. Connect
accounts and grant permissions separately as needed. Dev uses real integrations;
it is not the blue simulated Demo app.

All Dev builds share the Dev profile. Quit Dev before replacing it, keep the same
installation path/signing identity, and back up Dev state before switching
features or trying older builds. This first version has manual downloads rather
than automatic Dev updates. Feedback should include the full source SHA from the
release notes/manifest and a reproducible description; remove private content
before posting publicly. These builds do not add a new in-app feedback service.

## Failure and validation limits

A failed upload/hash/tag check leaves a draft; a failed draft creation may leave
only its reserved tag. Inspect the existing tag, draft, and run
before retrying. Rerun with a new run attempt for a distinct tag; never overwrite
assets, move a published tag, or repurpose a production version. An anonymous
download failure happens after publication, so the prerelease may already be live.
Inspect it before deciding whether to publish another build. Credential cleanup
runs even when signing fails.

Python regression tests use synthetic archives and a fake GitHub transport. They
exercise bundle/path isolation, source/hash/signing rejection, draft-first
publication, and verification failures. They do not prove Apple signing, native
interactions, or real publication. The first approved hosted run is the activation
check. Native core tests are run on the builder; the workflow does not test UI
interactions, real Messages sends, Contacts writes, or permission retention.

The reusable agent skill is [msgblast-test-build](../skills/msgblast-test-build/SKILL.md).
Copy that directory to your Codex skills directory for personal discovery.

## First hosted activation check (after merge)

Pre-merge Python checks cannot establish a successful hosted prerelease. After
this workflow lands on main, a maintainer must request one testing build using
the full reviewed source SHA and approve `test-build-signing` for that exact run.
Do not dispatch the production release workflow or bypass approval to test this.
Record both the trusted workflow SHA and selected-source SHA. Require the build,
sign, and publish jobs to succeed; verify the reserved `test-*` tag, all downloaded
asset hashes, Accepted notarization, and the anonymously downloaded ZIP. Extract
that ZIP and inspect its Dev identity/support profile, disabled production feed,
blue-green compiled icon, signatures/entitlements, and arm64/x86_64 slices of the
app, frameworks, cloudflared, and CuaDriver. Launch it on an authorized test Mac
without Demo flags, preserve production state and existing Dev drafts, and check
manual replacement/relaunch before reporting the hosted path verified. Any new
macOS permission approval belongs to the user. No real messages or paid calls
are needed for this activation check.
