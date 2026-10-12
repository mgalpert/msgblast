# Backend validation record

Scope: local service, reader, native v1 byte contract, immutable snapshot
continuation, and configured Auth0 adapter. Native account/sync/share UI remains
a dependent integration. No live deployment or app release.

The ce-code-review run `20261012-001957-backend` completed ten lenses with eight
independently confirmed findings. Local repairs cover stale result generation,
streaming preference retention, per-pair/scoped gaps, withdrawn retry state,
pending storage bounds, provider failure denominators, manifest races and actual
content cleanup. Registration-purpose behavior was additionally verified/fixed;
central guides and dependency notice were added. These checks do not represent
coordinator merge clearance.

Proof before repair: new regressions failed on native favorite retention (0 vs1),
old/new overlapping validation (new preference overwritten), gap interval (750ms
instead of unavailable), missing account denominators and withdrawn retries.

- Exact Swift-generated canonical fixtures are sent unchanged to the actual
  local Worker and compared to their independently pinned SHA-256 receipts.
- Real local Queue delivery validates immutable full-prefix snapshots, including
  canonical native feedback events.
- Deterministic barriers pause production job/manifest functions using real
  local bindings; a newer actual Queue result finishes before the old result.
- Repeated failed D1 commits leave real private R2 objects, then stop within the
  64 MiB pending account bound. Exact retries add no second object.
- A one-time injected R2 delete error preserves the tombstone and pending job;
  replay removes actual R2 bytes and D1 content. Account cleanup exposes its
  content-cleaned/identity-blocked stages honestly. The configured management
  adapter additionally demonstrates synthetic provider failure/retry/completion.
- A late put after account cleanup is erased, or reopens durable cleanup after
  an injected deletion failure; no published access is restored.
- Browser checks cover desktop/mobile ordered messages, agent selection, inert
  hostile text, no horizontal overflow, non-target membership and revocation.

The injected errors/barriers and closed nonfixture-flag cohorts are synthetic
local testing only. They do not measure remote outage incidence, prove truthful
local DOM capture, or establish representative benchmark samples. Accounts are
not independently verified unique humans. Exact final command results and source
SHA belong in PR evidence; early pass counts are not final-revision claims.

Dependent snapshot checks cover explicit parent consent, retry-stable revision
allocation, exact canonical suffix receipt retries, frozen old head validation,
unchanged public bytes, selected contribution stability before explicit newer
choice, one lineage of credit, and tombstones preventing continuation. Unknown
scope opt-in and bounded streaming revisions are checked with escaped hostile
text. Auth0 endpoint, audience, redirect, realm and encoded-subject behavior is
checked with synthetic responses and real local deletion state; no live Auth0
request is made. Retired mutable feedback tests now verify rejection and pinned
preference rather than silently changing prior contribution metrics.
