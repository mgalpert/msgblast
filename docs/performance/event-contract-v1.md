# Portable performance event contract v1

Stream A owns this contract. Local tracking has no network client. Stream B may
consume `PerformanceUploadChunk` only after separate upload consent.

`schemaVersion` is 1. IDs are opaque strings, never contact handles, cookie IDs,
provider credentials, paths, or account subjects. `agent.id` is the configured
agent instance, not its display name. `model` is omitted if unknown; connection
is `website`, `messages`, `cli`, or `grokBot`. Names and transcript text are private
originals, not a publication projection. `fixture` must be retained and excludes
these examples from real benchmarks.

Events are immutable, sequenced from 1 within each comparison in a local journal. Each has
`id`, `comparisonID`, `segmentID`, `kind`, `stamp`, and `fixture`. Optional fields
are omitted, not zero/empty stand-ins. `turnID` identifies an attempted user turn
for one agent. `turnPosition` counts observed attempted turns for that agent in
this comparison (0 initial). `scope` is `shared`, `private`, or `unknown`;
unknown scope is never permission to publish. Replies can have no turnID when
association is ambiguous. Revisions keep messageID within segment/agent/page
identity; feedback events store `favorite`, `negative`, or `unmarked`. Feedback
is a local preference, never a provider reaction or accuracy label.

`stamp.wallMS` is Unix milliseconds, informational only. `monotonicMS` is native
system uptime milliseconds, comparable only within the same `clockID` (opaque
per process). No elapsed metric crosses a gap, segment, or clockID. `sourceMS`
when present is a separately labeled source timestamp (e.g. Messages), never a
replacement for receipt time. Observed latency is not model-token latency.
`method` names observation capability, cadence, and missingness. Terminal outcomes
are observed completion, failed, canceled, uncertain, or unsupported; submission
acceptance alone is not delivery or task completion. Segment start/end and gap
reasons declare partial capture. `observationState` records recognized running/idle
transitions or unsupported generation capability without collecting account UI. Completion on websites requires a observed
running→idle generation transition in one document; navigation is a gap.

## Canonical bytes and upload envelope

Canonical JSON uses ASCII object keys sorted lexicographically at every level,
UTF-8 strings without normalization, standard JSON escaping (no escaped slash),
integers only for numbers, no whitespace, and ordered arrays. Omit absent optional
fields. This constrained subset matches RFC 8785; do not extend it to floating
point, non-ASCII keys, or server-owned fields without a new version. Hash hex is
lowercase SHA-256 of exactly these canonical UTF-8 bytes. Local event.previousHash
is SHA-256 of the preceding canonical event for that comparison; first event omits previousHash.
Chunk.previousHash is the preceding accepted **chunk body** hash, absent on first
chunk. The chunk hash is computed externally (not a self-referential body field).

Chunk fields: schemaVersion=1, id (retry-stable opaque UUID), sessionID (comparison
ID), sequenceStart, sequenceEnd, optional previousHash, events, artifacts (empty
in v1 native output). Event sequence and chunk sequenceStart/End are contiguous per-session positions,
starting at 1, counting immutable events in the chunk. The uploader must persist positions/receipts; replay identical bytes
for retries. No server time, authentication claim, ownership, contribution credit,
or independently-witnessed assertion is supplied by native events. Server
registration adds separate receipts, never mutates submitted events.

The fixture file is synthetic, including its arbitrary clock and dates. It is
portable contract evidence, not proof of a real provider interaction.

## Backward-compatible provider metadata

`agent.provider` is optional and comes only from the authoritative adapter enum:
`muse`, `chatgpt`, `claude`, `grok`, `codexCLI`, `claudeCode`, `dots`, `grokbot`,
`os3`, or `hark`. It never comes from a display name. Unknown Messages providers
omit it. A renamed copy has the same provider but its own configured instance ID.
Unknown models remain omitted. Older v1 records/fixtures without this field still
decode and re-encode to the same canonical bytes.

`sample-upload-providers-v1.json` was emitted through the compiled native
PerformanceRecorder/PerformanceUploadChunk/PerformanceCanonical interfaces. It
adds optional provider metadata, Unicode text, `observationState` generating/idle
signals, and distinct acknowledgment/answer message identities. It is synthetic
and excluded from real benchmarks. The original sample's bytes/hash are pinned
unchanged. Both hashes have companion `.sha256` files.

Reply `method` values from the current adapters begin with `web-`, `messages-`,
`cli-`, or `bot-`, with explicit cadence/final-output/unsupported details. These
are observation capability definitions, not model quality or token timestamps.

## Authoritative request groups (additive v1)

`turnStarted` may have optional `requestGroupID` and `targetAgentIDs`. These are
app-orchestration metadata, never inferred from prompt text, timing, or per-agent
turn position. The initial action uses Comparison.id; shared/targeted follow-ups
use the actual FollowUp.id/broadcast action UUID. Target IDs are the exact saved
configured agent IDs selected for that action, deduplicated and sorted; they are
not contact handles, chat database IDs, account subjects, or provider cookies.
Private native sends get an explicit single-target action ID. Joined-context
replay gets its own single-target group. Manual/legacy actions with unobservable
groups omit both fields and must remain labeled unaligned.

A private turn can advance one agent's turnPosition without advancing another's.
Repeated shared prompt text can identify different actions. Publication must use
explicit request groups and selected targets to distinguish 'not asked' from a
missing reply, preserving per-agent turn IDs and distinct response messages.
These client declarations do not establish independent witnessing.

`sample-upload-request-groups-v1.json` is native-produced by
`scripts/fixtures/performance_request_groups.swift`. It contains an initial
four-agent action, an interleaved private CLI turn, a repeated-text shared
follow-up, a subset follow-up, and an explicitly unaligned manual observation.
Original v1/provider fixture bytes remain unchanged and decodable.
