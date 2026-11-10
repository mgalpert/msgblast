# Review guardrails

Every change needs an approved behavior, path scope, PR split, and validation plan.
The author finishes with a removal pass and owns the result, including AI-written
code. Apply the `agent-written` label to assisted PRs. The maintainer remains
accountable for the merge. Before merging, a different model must review the
exact revision and the relevant checks must pass in an isolated fixture/test
environment. Record provider/model, base/head SHAs, findings, fixes, test results,
and limits. Publish the required `Independent model review` commit status only
after that review completes; use a review receipt as its target URL. Never publish
a passing status from an author-only review or a stale receipt. New commits need
a new review. This is an externally supplied status, not a PR-body checkbox;
GitHub does not itself attest which model performed the review.

## Size and scope

`PR scope` warns above 250 added-plus-deleted lines and fails above 600. Tests,
docs, generated text, and deletions count. File moves count as delete/add to keep
large reorganizations visible. Binary files are reported separately; the byte
metric is the total size of changed files at the head, not added bytes.

Declare intended repository paths in the PR body, one per line:

```text
Scope: scripts/check_pr_scope.py
Scope: scripts/tests/test_pr_scope.py
Scope: .github/workflows/pr-scope.yml
Scope: docs/review-guardrails.md
```

Globs are supported. A reviewer must reject declarations broader than the approved
request. Matching paths does not establish semantic scope or code quality.

For an indivisible change over 600 lines, a different human with write, maintain,
or admin access must approve the exact head commit with this standalone line in
the review body: `Size-exception: <40-character head SHA>`. While a user-owned
repository's owner is the only user with write, maintain, or admin access, the
owner may instead submit that line in a review on their own PR (GitHub records
it as a comment review, since authors cannot approve their own PRs); adding any
other maintainer turns this off. The check cannot tell the owner from an agent
using the owner's credentials, so only the owner may write that line. After the
review, re-run the `PR scope` job; it reads reviews when it runs. A new commit
invalidates the exception. Dismissal revokes an approval; a later owner review
on the same head without the line revokes the owner's exception. An exception
waives only the line ceiling, never declared scope or other checks.

Local check (event JSON contains a `pull_request.body` string):

```sh
python3 scripts/check_pr_scope.py --base origin/main --head HEAD --event-file /tmp/pr-event.json
python3 -m unittest discover -s scripts/tests -p test_pr_scope.py -v
```

The workflow executes only the base branch's checker and fetches the PR as Git
data. It needs no write token and never executes PR code. Bootstrap the workflow
onto the default branch before requiring its status; a PR cannot run a newly
introduced `pull_request_target` workflow before that workflow exists there.

## Context and tool output

The scope job also checks every tracked coding-agent instruction file, at any
depth and in any letter case: `AGENTS.md`, `AGENTS.override.md`, `CLAUDE.md`,
`CLAUDE.local.md`, `GEMINI.md`, `.cursorrules`, `copilot-instructions.md`, and
files under `.cursor/rules/` or `.claude/rules/`: 6 KiB per file, 24 KiB total,
measured as stored bytes. Each must be a regular file, not a symlink, submodule
or Git LFS pointer. Text pulled in through `@` imports is not counted.
Keep detailed references in linked docs and load only relevant sections.

Use the bounded runner for commands with potentially large output:

```sh
python3 scripts/lean_run.py --log build/check-unique.log -- python3 -m unittest discover -s scripts/tests -v
```

It forwards at most 100 KiB plus a short truncation notice, drains both streams
into a new local log, and preserves the command's exit status. Existing logs are
never overwritten. Inspect relevant errors from the saved log when truncated.
This opt-in wrapper does not control Codex connectors or third-party tools.
The CI instruction cap is enforced independently of whether an agent uses it.
App-control snapshots already request bounded element count, depth, and time;
they are application data, not this repository's coding-agent context. No arbitrary
100 KiB app-response cap is introduced without workflow-specific validation.
