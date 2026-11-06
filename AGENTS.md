# msgblast agent instructions

msgblast is a native macOS app. Build focused contributor PRs; production
publishing is a separate, explicitly requested maintainer operation.

## Plan and scope

- Before editing code, propose the behavior, affected paths, validation, and a
  split into independently passing PRs. Wait for the user's approval; an already
  approved plan is sufficient. Revisit the plan if the scope materially changes.
- Target 200–300 changed lines per PR. More than 250 added-plus-deleted lines is
  advisory; more than 600 requires splitting or recorded maintainer approval for
  the exact head revision. Explain added code, files, dependencies, and scope
  changes in the PR. Do not split one logical change into unreviewable fragments.
- Write the minimum code that satisfies the requirement. Prefer functions over
  classes and flat control flow over nesting where existing interfaces allow.
  Add no unrequested features, abstractions, compatibility layers, comments, or
  speculative error handling. Preserve required safety checks and error handling.
- Finish with a removal pass: delete unused code, unnecessary abstractions, and
  redundant comments introduced by the change. Test behavior, not implementation.
- Read specific symbols and relevant sections. Bound tool output; summarize large
  logs and preserve the full artifact separately. Do not hide errors by truncation.

## Start and implement

- Inspect branch, index, worktree, remotes, and applicable instructions. Preserve
  existing work; commit only requested files. Fetch the intended upstream base,
  record its full SHA, verify ancestry, and use a descriptive `codex/` branch.
  Continue authorized work from its intended ref; report a stale base, never reset.
- Before feature work read [Contributing](CONTRIBUTING.md), [Build from source](docs/build-from-source.md),
  [Architecture](docs/architecture.md), and [Testing](docs/testing.md). Historical
  plans and evidence are not current setup instructions or proof of passing checks.
- Preserve Codable compatibility, session identity, migration backups, drafts,
  attachments, private/shared scope, and send receipts. Never replace failed loads
  with empty stores or mutate the Messages database. Uncertain sends are not retried.
- Keep website, CLI, restricted-report, and Grok Bot authentication, permissions,
  histories, and retry policies separate. Submission does not establish delivery.
- Edit `scripts/generate_project.py` for project changes, regenerate, and review
  the diff. Keep both icon resources registered; update docs and dependency notices.

## Verify and share

- Use full Xcode 27 and Python 3.11+. Package isolated previews with
  `scripts/build_preview_apps.py`. Blue-green Dev uses live accounts; blue Demo
  uses fixtures. Never pass `--demo` or `--isolated-demo` to Dev.
- Preserve production and its support folder. A new output path alone does not
  isolate state. Never send real messages, write Contacts, reset permissions, or
  request paid work merely for evidence without authorization for that workflow.
- Run relevant checks from the testing guide. Linux checks do not prove native
  builds; core tests do not prove UI behavior. Report unavailable validation.
- Every PR needs `Base-SHA:`, `Evidence-SHA:` (full head SHA), `## Screenshots`, and
  `## Video`. Capture the actual changed workflow from the reviewed revision;
  link viewable HTTPS images and playable video within the repository's access
  boundary. Label fixtures and timing edits, refresh stale evidence, and preserve
  human review responsibility. Follow [the evidence rules](docs/agent-runbooks.md#pull-request-evidence).

## Task-specific safeguards

Read the relevant [agent runbook](docs/agent-runbooks.md) before icon changes,
release preparation, publishing, or Cursor Cloud work. It retains the detailed
requirements for green production artwork, separate Dev/Demo identities, signing,
versioning, release verification, and evidence. Releases must follow
[automated releases](docs/automated-releases.md); never use release jobs as tests.
The [documentation index](docs/README.md) links the other current runbooks.
