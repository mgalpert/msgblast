# Backend validation record

Scope: the fixture-only service, reader, native v1 byte contract and cloud
contribution projection. Native account/sync/share UI and finalized-snapshot
continuation are dependent integration work. No live deployment or app release.

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
- Real local Queue delivery validates registrations/finalizations and feedback.
- Deterministic barriers pause production job/manifest functions using real
  local bindings; a newer actual Queue result finishes before the old result.
- Repeated failed D1 commits leave real private R2 objects, then stop within the
  64 MiB pending account bound. Exact retries add no second object.
- A one-time injected R2 delete error preserves the tombstone and pending job;
  replay removes actual R2 bytes and D1 content. Account cleanup exposes its
  content-cleaned/identity-blocked stages honestly.
- A late put after account cleanup is erased, or reopens durable cleanup after
  an injected deletion failure; no published access is restored.
- Browser checks cover desktop/mobile ordered messages, agent selection, inert
  hostile text, no horizontal overflow, non-target membership and revocation.

The injected errors/barriers and closed nonfixture-flag cohorts are synthetic
local testing only. They do not measure remote outage incidence, prove truthful
local DOM capture, or establish representative benchmark samples. Accounts are
not independently verified unique humans. Exact final command results and source
SHA belong in PR evidence; early pass counts are not final-revision claims.
