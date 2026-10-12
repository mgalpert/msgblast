# Benchmark service (local implementation preview)

This dedicated Worker provides account-isolated immutable recording ingestion,
redacted unlisted comparison reading/revocation, and separately opted-in
contribution validation. It does not change the landing, feedback or updater
services. Native account/sync/publication UI is a separate dependent integration.
My Stats remains local; Benchmarks owns optional contributions/account history.

**Live launch requires provisioning.** The committed mode is disabled. Fixture
mode accepts only loopback request hosts and verifies signed fixture JWTs against
a local JWKS responder. Configured live mode uses the managed Auth0 adapter; this
checkout contains no live identity configuration, credentials or resource IDs.

## Local checks

Use Node 22+, then run from the repository root:

```sh
npm ci --prefix benchmarks
npm test --prefix benchmarks
npm run check --prefix benchmarks
npm run test:browser --prefix benchmarks
npm audit --prefix benchmarks
```

Browser testing needs Playwright Chromium (`cd benchmarks` then
`npx playwright install chromium`). `test` bundles with Wrangler dry-run and
runs the actual workerd runtime with local D1, private R2, Queue delivery and
Static Assets. There are no production binding IDs, remote writes, real provider
requests, Messages sends or Contacts changes. `check` regenerates Wrangler types,
typechecks and bundles; it does not deploy. Tests use temporary local storage.

The browser script publishes a synthetic redacted projection through the API,
checks desktop/mobile reader behavior and script escaping, selects an agent on
mobile, revokes with a verified fixture bearer token, then checks the unavailable
result. It does not demonstrate native preview, account sign-in, or sync consent.

## Contract and integration

See [API contract](contract-v1.md) and [operations prerequisites](operations.md).
The exact Stream A canonical native fixture is pinned at
`test/fixtures/native-upload-v1.json`, SHA-256
`548a27eaaaeae4292a26d8445d243233cdb5f2d444a97506d48ea592afa0504d`.
Its source is Stream A `docs/performance/sample-upload-v1.json` and
`event-contract-v1.md`; the copied synthetic bytes are tested unchanged.

Private sync, publication and contribution are three independent actions. A
publication uploads only the hash-confirmed redacted projection and can have no
private session at all. Optional `localID` is owner-private association metadata
outside the projection; an optional `sessionID` must belong to that owner and
match the comparison. Legacy session-linked publications derive that association.
Deleting the comparison's cloud record revokes and cleans its associated pages,
including pages published before private upload, and prevents republishing that
tombstoned comparison. An older standalone page without either association
cannot be inferred retroactively and must be revoked separately. Local originals are never fetched by the reader. Tokens
are random 192-bit capabilities, stored as hashes, and returned only at creation.
Recipients may copy or forward a page; revocation cannot erase those copies.

Server receipts and event/chunk chains preserve received bytes. They do not prove
that local observations, DOM state, completion, scope or declared fixture status
were truthful. All accepted cohorts remain voluntary-selected samples. Unsupported
timing stays missing, failures remain in outcome denominators, and preferences
never stand for quality. No ranking, public profiles, searchable directory,
reward, payout or raw-transcript aggregate endpoint is implemented.

## Dependencies

Runtime: jose 6.2.12 (MIT) for RS256 JWT verification. Development: Wrangler and
Miniflare (MIT), TypeScript (Apache-2.0), Playwright (Apache-2.0), esbuild (MIT). Versions are
pinned in the lockfile. Wrangler/Miniflare were selected at patched versions
following the initial local tooling audit; other service dependencies are unchanged.

Additional exact native fixtures cover observation/generation states, all event
kinds, streaming feedback and the optional provider extension. These are produced
by the actual Swift recorder/canonicalizer in the coordinating stream; the original
fixture remains unchanged. Standalone `test/native-contract.swift` can be compiled
against its pinned PerformanceModels/PerformanceStore/PerformanceRecorder; no
replacement Swift model is maintained here. `native-providers-v1.json` is pinned
at 96c6cb1d78c41f5da36363a64e055d3291207a940c1096734ded2850d13e39b3.

`npm run evidence:api --prefix benchmarks` records actual local API responses in
an explicitly labeled evidence viewer: denied consent, verified fixture account,
preview-hash-checked publish with zero private sessions/contributions, anonymous
read, authenticated revoke and immediate unavailable page/JSON. This viewer is
not a native account/preview screen or a production owner UI. Tokens are hidden;
inputs and scripted pauses are synthetic. Its JSON log is fixture-only.

### Configured identity and snapshot continuation

The real Auth0 management deletion adapter is implemented. Live mode remains off
until the owner provisions the dedicated identity tenant/application, server-only
management secret, D1/R2/Queue resources, domain, and approved cost/retention policy.
See [the API contract](contract-v1.md#managed-identity-provisioning) for configuration.
Local tests supply synthetic tokens and external provider responses; no real
identity accounts are created or deleted.

Finalization produces an immutable snapshot ID. Resuming private sync requires
an explicit cloud revision anchored to the prior head. Contributions bind a
chosen snapshot; local feedback and later uploads never silently move that choice.
The mutable feedback overlay endpoint is retired in favor of canonical native
feedback events. Old initial upload/finalize and single-snapshot contribution
requests remain supported. See [revision routes](contract-v1.md#immutable-cloud-revisions).
