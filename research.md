# Enforceable agent guardrails: project research

Inspected October 28, 2026. These are observations of public source, not claims
about every live repository protection setting or the effectiveness of all checks.

## OpenClaw: budget instructions and ratchet existing debt

At revision `0d49c7d37eb42caa429364ff86bc318f5b2b1b3e`, OpenClaw has a dedicated
AGENTS.md size check. It uses the runtime's 20,000-character bootstrap cap and
measures JavaScript UTF-16 length, matching the runtime rather than guessing at
tokens. Its root instructions were 19,732 UTF-8 bytes when inspected; it is not an
example of an extremely short root file.

Its preflight runs line-cap growth, suppression, test-timeout, and mock-export
ratchets. The line-cap checker compares changed files to a Git base and accounts
for renamed paths. Its baseline runner refuses pruning in CI. The useful pattern
is to stop new debt and growth while leaving existing debt explicitly visible.

Sources: [instruction checker](https://github.com/openclaw/openclaw/blob/0d49c7d37eb42caa429364ff86bc318f5b2b1b3e/scripts/check-agents-md-size.mts),
[runtime cap](https://github.com/openclaw/openclaw/blob/0d49c7d37eb42caa429364ff86bc318f5b2b1b3e/src/agents/embedded-agent-helpers/bootstrap-limits.ts),
[preflight](https://github.com/openclaw/openclaw/blob/0d49c7d37eb42caa429364ff86bc318f5b2b1b3e/scripts/check.mts),
[line-cap ratchet](https://github.com/openclaw/openclaw/blob/0d49c7d37eb42caa429364ff86bc318f5b2b1b3e/scripts/check-line-cap-ratchet.mts),
[baseline CI runner](https://github.com/openclaw/openclaw/blob/0d49c7d37eb42caa429364ff86bc318f5b2b1b3e/scripts/ci-baseline-ratchets.mts).

## OpenClaw runtime: measure context and retain originals

Its runtime docs distinguish context pruning from conversation compaction.
Pruning trims tool results while preserving the original transcript. On described
client-side cache-TTL paths, oversized results can retain a head and tail, followed
by clearing older tool content when context remains large. This is runtime-owned
behavior; a repository rule cannot provide the same guarantee.

Its context inspector reports instruction, skill-catalog, and tool-schema costs.
Full skill instructions load on demand. The practical next step for a coding
harness is to measure those categories before adding a compression proxy, and
keep full logs accessible after trimming.

Sources: [session pruning](https://docs.openclaw.ai/concepts/session-pruning),
[context accounting and on-demand skills](https://docs.openclaw.ai/concepts/context).

## VS Code: encode architecture in the language tooling

At `b6bfa95ebee8b183d65dee4997c0527eadfe5384`, VS Code has a custom ESLint
layering rule with explicit allowed dependencies: common code, Node code,
browser code, and Electron layers. It resolves relative imports before checking
layers. The inspected config sets layering to warning, while some private/deep
import rules are errors. A rule existing in source does not establish that every
violation blocks a merge.

For msgblast, a narrowly chosen module-boundary check would be more useful than a
generic list of prohibited imports. First identify a boundary the compiler does
not already enforce and one actual failure it should catch.

Sources: [layering rule](https://github.com/microsoft/vscode/blob/b6bfa95ebee8b183d65dee4997c0527eadfe5384/.eslint-plugin-local/code-layering.ts),
[configured severities and boundaries](https://github.com/microsoft/vscode/blob/b6bfa95ebee8b183d65dee4997c0527eadfe5384/eslint.config.js).

## Rust: small, deterministic policy checks with explicit exceptions

At `92ffebeceaa0a071066f233873c2438e73d70fe7`, Rust's tidy style checker includes a
3,000-line file ceiling, file-type-specific line-length checks, and explicit
suppression directives. It also checks directive usage. These thresholds are
project-specific; 3,000 lines is not a recommended PR budget.

The transferable lesson is that exceptions should be visible, narrow, and checked,
instead of silently expanding a baseline whenever CI fails.

Source: [tidy style checker](https://github.com/rust-lang/rust/blob/92ffebeceaa0a071066f233873c2438e73d70fe7/src/tools/tidy/src/style.rs).

## Recommendations for this repository

1. Keep the initial four changes small: short default instructions, size/scope
   check, function-metric ratchet, and bounded context/output.
2. Require a different-model review against the exact commit and actual tests in
   temporary fixtures. Retain the receipt and make its status required. GitHub
   can require a status but cannot attest the identity of an AI model itself.
3. Protect the checks: execute trusted base code where possible, use read-only
   workflow tokens, and review changes to workflow/checker files explicitly.
4. Add one architecture rule only after choosing a real boundary. Add dead-code
   detection in report mode first, checking SwiftUI/reflection false positives
   before turning it into a gate.
5. Audit false positives and bypasses. Do not reward line-count gaming, compressed
   code, or tests that merely repeat implementation. A semantic scope review
   still belongs to the independent reviewer.

GitHub documents that required checks must cover the latest commit; skipped or
neutral outcomes may count as success, and job conditions can therefore weaken a
gate. Require checks that actually execute and preserve failure results.
[GitHub required-check behavior](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/troubleshooting-required-status-checks).

No compression proxy, broad dependency scanner, or new architecture framework was
added as part of this work. Those would increase operational surface before a
specific need has been established.
