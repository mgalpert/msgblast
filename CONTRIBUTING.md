# Contributing to msgblast

Build the feature you want to use, try it in your own build, and share it through
a pull request. The repository is public. Cloning needs no GitHub account;
forking and submitting a PR do.

Start with [Build from source](docs/build-from-source.md). Coding agents should
also read [AGENTS.md](AGENTS.md). [Architecture](docs/architecture.md) and
[Testing](docs/testing.md) explain where to make changes and how to check them.

## Get a working copy

For personal use, clone the repository or download its source ZIP from GitHub's
**Code** menu. A ZIP has no Git history; clone a fork when you want to contribute.

For a PR, [fork msgblast](https://github.com/mgalpert/msgblast/fork), then clone your
fork. Replace YOUR-USERNAME below with your GitHub username:

```sh
git clone https://github.com/YOUR-USERNAME/msgblast.git
cd msgblast
git remote add upstream https://github.com/mgalpert/msgblast.git
git fetch upstream main
git switch -c codex/my-feature upstream/main
git rev-parse upstream/main
```

Record that last SHA as the starting revision. In a fork, `origin` is your fork
and `upstream` is msgblast; a maintainer checkout may use `origin` for msgblast.
Use the appropriate remote. Pick a descriptive branch name; coding agents default
to `codex/`. Continue existing authorized work on its intended branch.

Inspect existing edits before switching or editing. Preserve them, use a separate
checkout when needed, and commit only this change. Do not reset the working tree
or force-push the default branch to get a clean base.

## Build a feature

1. Describe the problem, intended behavior, and one example of success. Keep
   unrelated changes separate.
2. Build **msgblast Dev** and **msgblast Demo** using the build guide. Dev uses live
   accounts; Demo uses simulated data. Start with Demo for UI work and evidence.
3. Follow patterns in the relevant module. Regenerate the Xcode project when
   adding/removing Swift files or changing targets/resources. Keep existing saved
   data compatible.
4. Run checks relevant to the change and record commands, results, and limits.
   Fixtures do not prove live service behavior or macOS permission flows.
5. Update documentation when behavior, setup, or commands change.

Local building does not require Apple Developer ID, Cloudflare, Sparkle private
keys, or maintainer Actions secrets. Leave production updates disabled in
personal previews. Releases and service deployment are separate maintainer tasks.

Keep real conversations, contact information, credentials, and the installed app
out of fixtures. Dev has separate app state but can send real requests. Exercise
live sends, Contacts writes, or paid provider calls only when the user authorizes
that actual workflow.

## Give your coding agent the project

In the app, choose **msgblast → Build a New Feature…** (also available in
**Help**). Enter an optional idea and press **Copy Prompt**, then paste it into
your coding agent. The selectable preview is the complete copied text: your idea,
installed app version/build, public repository, and contribution instructions.
Editing the idea resets the copy confirmation. Closing the window clears the
idea; opening it again while it is open keeps the current draft.
The window does not include conversations, contacts, credentials, or diagnostics.

Use this starting prompt and replace the feature idea:

```text
I'm using msgblast and want to build a feature for myself, then share it with other users.

My feature idea: [Describe the problem and the behavior you want.]

Use https://github.com/mgalpert/msgblast. Help me fork and clone it, or work in my existing clone. Read AGENTS.md, CONTRIBUTING.md, and the build, architecture, and testing guides before making changes.

Implement a focused change on a feature branch. Build separate Dev and Demo apps without replacing my installed app or changing its saved data. Use Demo with sample data for testing and screenshots/video. Run the relevant checks and explain any limits.

Help me run my own build. Prepare a PR against upstream main with a clear description, validation, Base-SHA, Evidence-SHA, relevant screenshots, and a short playable video following the repository's evidence requirements.
```

## Submit a pull request

Commit your change, push the branch to your fork, and open a PR against
`mgalpert/msgblast:main` through GitHub or `gh pr create`. Review the diff before
pushing; exclude build products, private state, sensitive logs, and unrelated
changes. Use a draft PR when native validation or evidence is still pending, and
state the limitation.

The description should include:

- The problem and resulting behavior, with a concrete before/after example when useful.
- Validation and its limits, including the source revision tested.
- Setup, migration, or compatibility effects the reviewer needs to know.
- `Base-SHA:` with the starting upstream commit and `Evidence-SHA:` with the full
  40-character PR branch head.
- `## Screenshots` and `## Video`, as described below.

Do not add a production version or release tag merely to submit a feature.
Maintainers choose release versions and publish reviewed source. A PR merge does
not install the feature for everyone; you can use your separate build while
review and release are pending.

## Screenshots and video

Every PR created or updated needs both sections. Capture the changed feature or
workflow from the submitted revision. Native Mac UI needs the affected window
and a short recording of the interaction and result. Responsive web changes need
desktop and mobile screenshots. Include before/after views when useful.

Use **msgblast Demo** with sample data for fixtures. Label simulated inputs,
mocked accounts, edited timing, and other limits. Generated mockups, unrelated
browser screenshots, test result bundles, and screenshot-only ZIPs are not
implementation video evidence. Refresh captures when the demonstrated behavior
changes; update Evidence-SHA after a new branch head and verify the capture still
represents it.

Embed screenshots with real HTTPS image URLs. Embed or directly link a playable
HTTPS video: `.mp4`, `.webm`, `.mov`, or a GitHub user-attachment video URL. Upload
through the PR editor or use repository-hosted evidence at the reviewed revision
with a direct media URL. Check that reviewers can view it. Keep media within the
repository's access boundary; use sample data for this public repository. Local
paths and private support reports are not PR evidence.

For docs, tooling, and other nonvisual changes, show the relevant document,
terminal, or API workflow when feasible. If meaningful evidence truly cannot be
captured, explain why in both sections for a person to review. The explanation
does not make the automated evidence check pass.

Save the actual PR body as a UTF-8 file and validate its structure:

```sh
python3 scripts/check_pr_evidence.py \
  --body-file /path/to/pr-description.md \
  --head "$(git rev-parse HEAD)"
```

For a `cursor/*` branch, add `--require-preview`. Its description also needs the
Actions preview run URL, both app names, a **msgblast Demo fixture** label, and
separate `msgblast Dev SHA-256:` and `msgblast Demo SHA-256:` lines containing the
different 64-character ZIP hashes from `preview-manifest.json`. These must refer
to genuine Actions previews. The automatic preview job runs for same-repository
Cursor PR branches or manual dispatch; a fork PR does not automatically receive
those previews. Coordinate with a maintainer when that path is needed.

The checker validates structure and SHA; a reviewer checks that the media shows
this change. Syntax hidden in code fences, inline code, comments, or escaped
examples does not count.

## Review and CI

Validation runs Linux tooling/Worker checks and native core/updater checks. The
native job uses the configured `xcode-27` runner; a fork's own Actions environment
may not have it. Workflow approval, runner availability, and maintainer access
can affect fork PR CI. Record local results while checks are pending; Linux
tests do not establish a native app build.

Respond to review and refresh the description/evidence when changes affect the
result. `validate.yml` does not run UI tests; manual native evidence remains
required. See [Testing](docs/testing.md) and [cloud agents](docs/cloud-agent.md)
for commands and limits.

## License and credits

Contributions are included under the repository's [GPL-3.0-only license](LICENSE),
except separately attributed third-party material. Preserve notices and asset
attribution. Describe new dependencies and their licenses in the PR. Follow the
README's license terms when distributing a modified build; branding and
third-party service marks retain their stated rights.

Release notes credit contributors with linked GitHub handles. Explain the value
of your change in the PR so maintainers can write useful highlights and credits.
