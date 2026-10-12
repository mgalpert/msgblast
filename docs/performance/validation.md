# Local milestone validation

Scope: U1–U3 and U9. Synthetic/local validation only; no account login, private
sync, publication, contribution, service deployment, real Messages/Contacts action,
or paid provider request was performed. Native account integration belongs to the
separate cloud stream.

- Full Xcode native core suite: 343 tests, zero failures.
- Focused performance suite: eleven tests, zero failures. Covers old state off,
  selected turn cohorts, separate initial/follow-up samples, unavailable Messages
  completion, clock/gap boundaries and per-agent versus global gaps, feedback revisions, corruption preservation,
  permissions, distinct providers/copies, and stale-writer rejection.
- Actual AppModel/WebKit/controller fixture: passed all four connector paths,
  manual website follow-up capture, hidden DOM exclusion, ordinary nil-replyTo and
  receipt-owned follow-up Messages association, intervening-send/overlap ambiguity,
  no-op refresh deduplication, native cancellation, sleep after re-enable, capture
  failure with exactly one ordinary send, and explicit deletion recovery.
- Configured CLI fixture: passed local executable/new/resumed/denied-action and
  restricted-report/session-retention checks. No provider CLI account was used.
- Native application build and generated-project registration: passed.
- `git diff --check`: passed.
- XCTest UI automation did not execute: macOS timed out enabling automation mode.
  Actual packaged Demo computer-use checks replace that unavailable run for UI
  evidence; they do not establish an XCTest automation pass.
- The initial new cohort/concurrent-writer regression tests failed before repair
  for the expected counts, modified bytes, and corrupted reload. Later passes
  verify the repair. The Swift Package test target has a pre-existing missing
  MessagesAccessGuide source issue; the documented Xcode target was used.

The full local code review completed and independently confirmed six findings:
active-segment gaps, date-cohort outcomes, manual web turns, hidden DOM content,
unchanged Messages reprocessing, and growing journal rewrites. All were addressed.
Persistence uses a bounded locked/fsync append instead of introducing a general
logging framework. Final integration/code/evidence review remains owned by the
coordinating chat; this milestone is submitted as a draft.

## Retained-history workload

One temporary synthetic journal with 5,000 seeded prior events, then five agents,
ten user turns per agent, and four reply revisions per turn. No live sends.
The final journal was 7,872,135 bytes. The same compiled native recorder workload
reloaded all 5,301 events and 5,050 distinct response identities.

| Per reply capture | Whole-journal rewrite | Bounded durable append |
| --- | --- | --- |
| Median | 3.992 ms | 0.112 ms |
| p95 | 5.425 ms | 1.030 ms |
| Maximum | 12.585 ms | 5.026 ms |

These measurements describe this Mac, temporary local storage, synthetic text,
and direct capture calls. They support reduced persistence work and do not prove
all live provider layouts, all disk conditions, or end-to-end UI responsiveness.

## Portable bytes

Original v1 fixture SHA-256 remains
`548a27eaaaeae4292a26d8445d243233cdb5f2d444a97506d48ea592afa0504d`.
Native-produced additive provider/generation/multi-reply fixture SHA-256 is
`96c6cb1d78c41f5da36363a64e055d3291207a940c1096734ded2850d13e39b3`.
Both native canonical round-trips are tested. Backend acceptance of current
native-produced bytes is a separate cross-stream integration check.


Post-review fidelity checks use actual WebKit paragraphs/line breaks and indented
pre/code DOM. The performance serializer preserves visible formatting and code
content while the existing receipt normalization stays unchanged. Hidden content
remains absent. Demo follow-up replies reference their own outgoing GUID so
initial and follow-up timing are demonstrated against the correct synthetic
source membership. The agent-local navigation-gap regression reproduced an
unavailable Beta measurement before the fix and preserves its 60 ms afterward;
nil-agent global gaps still invalidate both agents.


Authoritative optional requestGroupID/targetAgentIDs metadata is captured through
actual shared orchestration. The controller fixture repeats the same prompt after
an interleaved private CLI turn and verifies common action identity across four
intended agents despite different per-agent turn positions. A later subset action
excludes the Bot from its target vector. Private native groups remain single-target;
manual/legacy groups remain absent and unaligned. A third native-produced fixture
pins these optional v1 fields without changing either older fixture's bytes.
