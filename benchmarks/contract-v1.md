# Native-facing API v1

All account mutations require an OIDC RS256 access token with exact configured
issuer/audience, nonempty subject, expiry/issued-at, and `benchmarks:write` scope.
ID tokens and browser cookies are not accepted. Cross-origin/opaque Origin and
cross-site browser mutations are rejected; native bearer requests need no Origin.
No CORS or cookie login endpoint is provided. Account IDs derive only from the
verified issuer/subject. Account tombstones cannot be re-registered.

Bodies are bounded UTF-8 application/json; content encoding is rejected before
reading. Compressed upload support is intentionally absent. Event chunks must be
exact canonical bytes from the shared native v1 schema, not pretty JSON: sorted
ASCII object keys, integer-only safe numbers, ordered arrays, no whitespace.
Event and chunk hash chains are separate; sequence positions begin at 1.

| Route | Action and result |
| --- | --- |
| GET `/api/v1/account` | Verified private account identity and consent separation |
| DELETE `/api/v1/account` | Atomically tombstone sessions/links/contributions; 202 tracked cleanup; tracked provider deletion when configured |
| GET `/api/v1/account/deletion` | `{accountID,deletion}`; verified owner identity and deletion stage, allowed after account tombstone |
| POST `/api/v1/sessions` | `{localID,purpose:"sync" or "contribution",consent:true,fixture,context:"fresh"/"prior"/"unknown"/"omitted"}`; cloud UUID |
| GET `/api/v1/sessions` or `/sessions/:id` | Owner-only metadata; no public lookup |
| POST `/sessions/:id/chunks` | Native `PerformanceUploadChunk` bytes; immutable hash/sequence/server-receipt timestamp |
| GET `/sessions/:id/chunks/:chunkID` | Owner-only committed receipt; uncommitted R2 writes have no receipt |
| POST `/sessions/:id/finalize` | `{sequenceEnd,hash}` must match current durable tail; 202 Queue validation |
| GET `/sessions/:id/validation` | Complete/partial, eligible flag, reason codes, measured samples; pending until Queue result |
| DELETE `/sessions/:id` | Immediate tombstone/link revoke/credit withdrawal, tracked asynchronous cleanup |
| POST `/sessions/:id/feedback` | 409 `append_feedback_in_new_revision`; mutable overlays are no longer accepted |
| POST `/sessions/:id/contribution` | `{consent:true,revision,snapshotID}`; independent explicit snapshot choice, one session lineage of credit |
| DELETE `/sessions/:id/contribution` | Withdraw all prior contribution revisions and aggregate influence |
| GET `/api/v1/contributions` | Owner-only latest unique contribution history, validation state, accepted distinct count |
| GET `/api/v1/statistics` | Authenticated aggregate, selection/verification/missingness/denominators; no raw conversations or account IDs |
| POST `/api/v1/publications` | `{consent:true,projection,previewHash,sessionID?,localID?}`; no private sync required |
| GET `/api/v1/publications` | Owner metadata; capability plaintext is not retained |
| DELETE `/publications/:id` | Immediate revoke; private original unchanged; asynchronous artifact cleanup |
| GET `/s/:token` | Anonymous direct-link reader; no-store/noindex/no-referrer |
| GET `/s/:token/data` or `/artifacts/:id` | Rechecks active owner/publication/session in primary D1 before reading private R2 |

The abbreviated `/sessions` and `/publications` paths above are under `/api/v1`.
GET never changes consent, publication or credit. Errors are stable codes with no
transcripts, token values or SQL exception text. Registration retries use localID;
identical chunk retries return the original receipt; changed bytes conflict.
Finalized snapshots are immutable; later feedback is appended to the native event chain in an explicitly opened next cloud revision. No correction
endpoint silently overwrites a received event.

## Publication projection

Schema 1 fields: `schemaVersion`, `title`, `fixture`, `participants`, `turns`,
`omissions`, `limitations`, `includesPrivate`, `includesEarlierHistory`, `artifacts`, optional `includesUnknown`.
Participants have opaque `id`, redacted `label`, `connectionType`. Turns have
opaque `id`, `kind` (`initial`/`followUp`), redacted `prompt`, `scope` and `replies`.
Each agent reply group has `agentID`, categorical turn `outcome`, and ordered
`messages`. Every message has a stable `messageID`, redacted `text`, categorical
`outcome`, honest `timingLabel`, and optional owner `feedback`. Acknowledgments,
answers and additional replies retain separate boundaries, intervals and feedback.
Empty messages retain failed/unobserved turn outcomes. Each participant missing from a turn is rendered as
unobserved, never silently omitted. Turn order is preserved.

Unknown scope requires `includesUnknown=true` and `kind="unknown"`; absent flag defaults to exclusion. Private scope needs `includesPrivate=true`; earlier
history is a separately explicit preview flag. These declarations cannot prove
client honesty or perfect redaction. Native integration must default-exclude
private/unknown/earlier context, redact identifiers/paths/dates/metadata, and show
exact projection bytes/participants/omissions before the explicit publish action.
The server requires the SHA-256 of canonical projection bytes to equal
`previewHash` and rejects unknown fields; it never transforms private originals
into public pages. Names, manual text redactions and omissions are owner-reviewed.

Artifacts are explicit `{id,name,type,base64}` members of the preview, max 256 KiB
each, with text/plain, PNG or JPEG only (image magic checked). No executable,
HTML, SVG, external URL, cookies, hidden browser data or public bucket URL is
accepted. Text renders escaped; no transcript Markdown/HTML execution. Artifact
routes download through the same access gate.

## Proposed bounded storage

1 MiB request/projection; 1,000 events per chunk; 10,000 events/16 MiB per session;
64 MiB total stored/reserved bytes (including publication and pending objects),
128 pending object intents and 200 active sessions per account; 100 publications
per account (all revisions), up to 12 participants/200 turns/10 artifacts.
These fixture limits require owner cost/retention approval before live launch.

Canonical `agent.provider` is optional in event v1 and never inferred from editable
names. Known adapter values: muse, chatgpt, claude, grok, codexCLI, claudeCode,
dots, grokbot, os3, hark. Unknown Messages/provider identity stays absent. Private
samples retain configured agent IDs; community groups separate canonical provider,
connection, known model and context. Failures share their provider outcome
denominator; measured timing subcohorts separately disclose method and turn kind. Unknown
provider groups are labeled unclassified collection, not an agent benchmark.

Native optional `requestGroupID` and `targetAgentIDs` are accepted on turnStarted
only. The group ID comes from the actual shared/private action, never text/time
matching. Targets are unique configured agent IDs including that turn's agent.
Publication `targetedAgentIDs` is a separate projection field: native integration
must translate IDs explicitly. Listed non-targets render as Not asked, while
listed targets without captured replies retain missing-response states. Legacy
absent action grouping remains unaligned; it must not be inferred from turnPosition.

A publication turn may have `kind: "unknown"` and an `alignmentLabel` explaining
an unaligned per-agent recording. Absent target declarations do not imply that an
uncaptured agent was asked; its membership is shown as undeclared. Native sharing
must preserve unknown/unaligned turn position rather than guessing an initial or
shared request from matching text/time.


`localID` is optional owner-private comparison association metadata, outside the
public projection and its hash. Publication never registers a session or uploads
private events. If `sessionID` is supplied, it must be active and owned by the
verified account; `localID` must match its comparison or is derived when omitted.
Deleting an owner's cloud comparison revokes and cleans every associated page,
including publication-before-upload, without affecting another owner's identical
`localID`. The tombstone denies later associated publication, including at the
D1 insertion boundary. Readers recheck the comparison tombstone on every request.
Migration backfills existing session-linked publications; older standalone links
without comparison metadata cannot be inferred and require explicit revocation.

## Immutable cloud revisions

A session is one owner/comparison lineage. Its `current_revision` begins at 1;
`next_sequence` and `last_hash` always describe the global unchanged native chunk
chain. Cloud revisions are not inserted into native event bodies or hash chains.

- POST `/api/v1/sessions/:id/revisions` accepts
  `{consent:true,requestID,parentHash,parentSequenceEnd}`. The parent must be the
  current finalized snapshot. The request ID is retry-stable; changing its parent
  conflicts. Returns `{sessionID,revision,parentHash,parentSequenceEnd,status}`.
- POST `/sessions/:id/revisions/:revision/chunks` accepts the same canonical native
  bytes as the initial route. Only the current open revision can commit new chunks;
  an exact previously committed chunk retry returns its original receipt.
- POST `/sessions/:id/revisions/:revision/finalize` accepts `{sequenceEnd,hash}`
  and returns `{sessionID,revision,snapshotID,sequenceEnd,hash,status}`. A snapshot
  freezes the full chunk prefix through this head, not just the new suffix.
- GET `/sessions/:id/snapshots` returns owner-only immutable heads; GET
  `/sessions/:id/snapshots/:snapshotID/validation` returns that head's validation.
  The old `/validation` route is a compatibility view of the active finalized head.
- Initial chunk/finalize routes address cloud revision 1. After continuation,
  contribution requests must explicitly supply `snapshotID`. Retrying a contribution
  revision with another snapshot conflicts. A newer explicit contribution revision
  supersedes its predecessor while retaining one lineage of credit. Uploads, private
  continuation and ratings do not move the selected contribution automatically.

Publication bytes and capabilities remain independent immutable projections.
Optional message `revisions:[{text,timingLabel}]` carries up to 200 explicitly
previewed earlier streaming observations per message. The reader renders these
as escaped text in a labeled disclosure, preserving message boundaries.

## Managed identity provisioning

Default service mode remains disabled. Fixture mode accepts loopback requests
only. Live mode requires `IDENTITY_PROVIDER=auth0`, exact HTTPS `OIDC_ISSUER`,
`OIDC_AUDIENCE`, `AUTH0_MANAGEMENT_ORIGIN` equal to the issuer origin,
`AUTH0_CLIENT_ID`, and the `AUTH0_CLIENT_SECRET` Wrangler secret. The management
application must be granted only the necessary `delete:users` permission. No
management token or secret is sent to native clients.

The adapter obtains a client-credentials token from `/oauth/token`, then deletes
the encoded verified subject at `/api/v2/users/:subject`. Redirects are rejected;
requests have 15-second deadlines and bounded token responses. A 204 or 404 is
idempotent completion. Provider failures preserve the immediate local tombstone,
completed content cleanup, and retryable job; the owner deletion status includes
`identity_error="identity_provider_failed_retrying"` until completion. Missing
configuration is blocked and is reactivated by scheduled reconciliation after
provisioning. Minimal account/lineage tombstones remain to prevent resurrection.

Provider reference: [Auth0 Management API access tokens](https://auth0.com/docs/secure/tokens/access-tokens/management-api-access-tokens)
and [managed users](https://auth0.com/docs/manage-users/user-accounts/manage-users-using-the-management-api).

Each derived validation record is capped at 1 MiB, returning
`blocked_reason="validation_record_limit"` for larger results. The initial
compatibility validation view reads the current snapshot directly, so no second
mutable metrics copy is stored. Derived validation storage has a separate 16 MiB per-account budget (UTF-8 metrics,
reason bytes, and row allowance), enforced atomically in D1. Accounts retain at
most 1,000 snapshots. Validation polls and contribution history expose
`status="blocked"`, `blocked_reason="validation_storage_quota"` rather than
accepted credit when capacity is exhausted. Reconciliation resumes the blocked
job after capacity becomes available. Session/account cleanup removes snapshot
heads, revision requests and derived validation content; the minimal lineage
and account tombstones still prevent resurrection.

Pending publication object leases carry the same private owner/comparison association.
Session cleanup removes them even if no private session existed when publication began.
A put completing after the comparison tombstone erases its bytes; if that erasure fails,
it records a deleting lease and reopens the corresponding tracked cleanup generation.
Migration 0003 backfills committed session-linked publications and preserves legacy
session-bound pending leases without changing their retry identity. Standalone legacy
publications have no recoverable comparison association and are not guessed.

## Read-only business choices

An optional `businessChoices` on `replyObserved` events and publication messages
(or their explicitly included revisions) carries `{kind,title,options}`.
`kind` is `quickReply`, `listPicker`, or `unsupported`; each option contains
`title`, boolean `selected`, and optional `subtitle`/`section`. Labels are bounded
at 4,096 characters and cards at 500 options. Only display text and selection
are included: no source archive, fingerprint, Messages identifiers, or action URL.
Old text-only records remain valid. The owner previews and redacts card labels
before approval; the shared reader renders disabled controls with a selected
checkmark. An existing immutable link is unchanged by later native selections;
create a new reviewed share to include them.
