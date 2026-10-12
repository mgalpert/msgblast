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
| DELETE `/api/v1/account` | Atomically tombstone sessions/links/contributions; 202 tracked cleanup; identity deletion blocked |
| GET `/api/v1/account/deletion` | Owner-only deletion stage; allowed after account tombstone |
| POST `/api/v1/sessions` | `{localID,purpose:"sync" or "contribution",consent:true,fixture,context:"fresh"/"prior"/"unknown"/"omitted"}`; cloud UUID |
| GET `/api/v1/sessions` or `/sessions/:id` | Owner-only metadata; no public lookup |
| POST `/sessions/:id/chunks` | Native `PerformanceUploadChunk` bytes; immutable hash/sequence/server-receipt timestamp |
| GET `/sessions/:id/chunks/:chunkID` | Owner-only committed receipt; uncommitted R2 writes have no receipt |
| POST `/sessions/:id/finalize` | `{sequenceEnd,hash}` must match current durable tail; 202 Queue validation |
| GET `/sessions/:id/validation` | Complete/partial, eligible flag, reason codes, measured samples; pending until Queue result |
| DELETE `/sessions/:id` | Immediate tombstone/link revoke/credit withdrawal, tracked asynchronous cleanup |
| POST `/sessions/:id/feedback` | `{consent:true,segmentID,agentID,messageID,revision,selection}`; separate immutable revision of an observed reply |
| POST `/sessions/:id/contribution` | `{consent:true,revision}`; independent explicit choice, one session lineage of credit |
| DELETE `/sessions/:id/contribution` | Withdraw all prior contribution revisions and aggregate influence |
| GET `/api/v1/contributions` | Owner-only latest unique contribution history, validation state, accepted distinct count |
| GET `/api/v1/statistics` | Authenticated aggregate, selection/verification/missingness/denominators; no raw conversations or account IDs |
| POST `/api/v1/publications` | `{consent:true,projection,previewHash,sessionID?}`; no private sync required |
| GET `/api/v1/publications` | Owner metadata; capability plaintext is not retained |
| DELETE `/publications/:id` | Immediate revoke; private original unchanged; asynchronous artifact cleanup |
| GET `/s/:token` | Anonymous direct-link reader; no-store/noindex/no-referrer |
| GET `/s/:token/data` or `/artifacts/:id` | Rechecks active owner/publication/session in primary D1 before reading private R2 |

The abbreviated `/sessions` and `/publications` paths above are under `/api/v1`.
GET never changes consent, publication or credit. Errors are stable codes with no
transcripts, token values or SQL exception text. Registration retries use localID;
identical chunk retries return the original receipt; changed bytes conflict.
Finalized events are immutable; feedback uses separate records. No correction
endpoint silently overwrites a received event.

## Publication projection

Schema 1 fields: `schemaVersion`, `title`, `fixture`, `participants`, `turns`,
`omissions`, `limitations`, `includesPrivate`, `includesEarlierHistory`, `artifacts`.
Participants have opaque `id`, redacted `label`, `connectionType`. Turns have
opaque `id`, `kind` (`initial`/`followUp`), redacted `prompt`, `scope` and `replies`.
Each agent reply group has `agentID`, categorical turn `outcome`, and ordered
`messages`. Every message has a stable `messageID`, redacted `text`, categorical
`outcome`, honest `timingLabel`, and optional owner `feedback`. Acknowledgments,
answers and additional replies retain separate boundaries, intervals and feedback.
Empty messages retain failed/unobserved turn outcomes. Each participant missing from a turn is rendered as
unobserved, never silently omitted. Turn order is preserved.

Unknown scope is rejected. Private scope needs `includesPrivate=true`; earlier
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
