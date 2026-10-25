---
name: msgblast-test-build
description: Publish a signed, notarized msgblast Dev feature build for testers through the manual GitHub prerelease workflow. Use for sharing testing builds, including reviewed unmerged features; production app releases use msgblast-release.
---

# Publish a msgblast testing build

Locate the intended msgblast checkout from the current chat or repository remote;
do not rely on a saved worktree path. Read its `AGENTS.md` and
`docs/testing-builds.md`. That runbook is the source for workflow inputs, approval,
verification, and failure handling. Use `mgalpert/msgblast` unless the user has
explicitly selected another configured repository. This skill publishes Dev
prereleases, not production updates or simulated Demo recordings.

Resolve the requested feature to a full pushed commit SHA. Inspect branch, local
changes, remotes, and the diff from the intended base. Do not silently substitute
local HEAD, main, or another feature when a requested revision is unavailable.
Review unmerged source before making it a testing candidate. Changes or a source
push alone do not authorize publishing a tester download; a request to publish or
share a test build does. Prepare missing code/checks before dispatch, preserving
unrelated work and the production app.

Check GitHub authentication, that `test-build.yml` and its scripts are merged into
the default branch, the environment's reviewer/default-branch rules, and existing
Apple configuration names (never read or print secret values). Do not create new
Apple credentials or disable the approval gate to get a build through.

Write a clear feature title and testing instructions from the requested feature:
what to try, expected result, and known limits. Treat them as public release text.
Use a temporary JSON dispatch file and `gh api --input` as shown in the runbook;
never interpolate user prose into executable shell text. Dispatch exactly once
from the default branch for the selected full source SHA.

Identify and follow that run. The workflow's `headSha` identifies trusted tooling,
while the selected feature SHA is recorded separately. At the signing approval,
report the run URL and exact selected SHA, and leave the GitHub environment
approval to the maintainer. Do not approve it automatically. Existing user approval
of publishing does not remove this workflow's human review step.

After approval, follow the same run to completion. Verify its prerelease tag,
source SHA, Dev bundle identity, Developer ID/Accepted notarization manifest,
disabled updater, and ZIP hash. Independently download the ZIP anonymously and
compare its SHA-256 with `test-release.json`; do not call a queued, failed, draft,
or unverified run published. Report the release page, direct Dev ZIP link, selected
source SHA, and relevant limits. Explain installation alongside regular msgblast,
separate permissions/data, shared Dev state across feature builds, and manual updates.

On failure, inspect the run and any draft/public prerelease before retrying.
Never replace published bytes, move tags, reset production counters, modify the
stable feed, or invoke `release-adhoc.yml` for testing. A failed final download check
can leave a live prerelease; say so and diagnose before dispatching again.
