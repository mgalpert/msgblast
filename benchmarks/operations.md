# Service operations prerequisites

This revision is fixture-only and deliberately cannot enable live cloud actions.
Do not deploy the local placeholder bindings. No Cloudflare resource, tenant,
production domain, retention policy or paid provider access has been provisioned
by this work. The public landing/updater/feedback domains remain separate.

Before a live implementation can be launched, maintainers must approve and
configure managed identity (proposed Auth0 tenant, issuer, API audience and
scopes; system-browser PKCE native client and exact variant-specific callbacks),
implement and verify its account-deletion management adapter, and register
isolated staging and production resources/domains. Verify wrong issuer/audience,
expired tokens, sign-out and account deletion against the actual provider.
Fixture JWKS tests verify the JWT boundary, not Auth0 configuration or live login.

Each environment needs its own Worker/Static Assets deployment, D1 access metadata,
private R2 bucket with public access disabled, Queue consumer/dead-letter queue,
and reconciliation cron. No shared production bucket/database/queue, public
r2.dev URL, dashboard rewrite or updater route may be inferred from local names.
Configure Worker-first routing on all reader/API paths. Validate with authenticated
staging tests and anonymous revoke checks on every artifact path before launch.

## Recovery and deletion

R2 writes are immutable and conditional. A durable object-intent lease precedes
R2 writes; D1 commits a receipt only after the object write. A retry can reconcile
an object without a receipt. D1 triggers atomically check ownership/tombstones,
sequence/hash tail and byte quotas while advancing the manifest. Proposed old
uncommitted-object cleanup is 24h; reconciliation atomically claims stale upload
leases and never removes committed objects. There are no public object routes.

Finalization persists a durable outbox job atomically with session status. Queue
messages contain only opaque job IDs. At-least-once delivery is idempotent;
completed generations are skipped. A newer enqueue cannot be hidden by an older
job marking itself complete. Cron re-sends pending jobs after a Queue send failure.
No recovery path sends an agent request again. Failed consumers retry after 30s;
verify dead-letter handling and alerting before production.

Session/account deletion atomically disables access and withdraws contributions
before asynchronous content cleanup. Jobs recheck tombstones. Account deletion
has separate content-cleaned and blocked identity-management stages; blocked
identity work is excluded from dispatch so it cannot starve other jobs. Its status
is visible to the same verified subject through `/account/deletion`, even after
other account actions return 410. It is never reported fully deleted while the
identity adapter is missing. Content-free session tombstones prevent outbox
resurrection; minimal account identity remains until provider deletion can be
verified. Backup/Time Travel retention is an operator launch decision, not proof
that revoked data has vanished from all backups. Recipients may retain copies.

Approve quotas, abandoned-open-session retention, deletion receipts, backup
windows and costs before enabling uploads. This fixture backend proposes owner
retention until deletion, 24h orphan cleanup and the bounds in contract-v1.md;
incomplete registered sessions currently remain until owner deletion. No automated
open-session expiry or provider-management cleanup is claimed implemented.

## Logs and verification limits

Application errors emit only opaque request/job identifiers and operation status;
never bodies, prompts, subjects, capability URLs, auth tokens or exception text.
Invocation logs are disabled. Review trace settings and provider/platform
access-log URL capture before live deployment; capability paths must not appear
in retained logs. No analytics/third-party scripts are on reader pages.

Local workerd checks prove runtime binding behavior, real local SQL/R2/Queue
retry boundaries and browser layout. They do not prove Cloudflare region/replica
configuration, public routing, provider login, remote quotas, backups, native
Keychain/callback/outbox handling, or a production launch. Received hashes prove
received-byte integrity only; cohort statistics are voluntary-selected samples
with declared provenance and unsupported observations preserved.

Pending bytes/intents are reserved per owner before R2 writes and charged with
committed session/publication content. Receipt/publication commits atomically
release reservations. Tombstoned content stays charged until physical cleanup.
Late in-flight puts recheck account/session access; canceled content is erased,
and cleanup failures restore a durable deletion generation. Account cleanup-stage
writes are generation-guarded as well as validation results.
