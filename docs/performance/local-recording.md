# Local performance recording

Settings has General, My Stats, and Benchmarks tabs. Performance & Benchmarks is
off by default, including old saved app state. Enabling it records subsequent
comparison attempts and observed replies under the selected app support folder's
`Performance/events.jsonl`. It doesn't create an account, make network requests,
activate private sync, publish, or contribute. Disabling it closes recording
segments and hides timing/feedback controls. Records remain until explicit local
deletion; conversation state and Messages history are separate.

My Stats shows recorded comparisons and per-agent attempted turn counts, initial
versus follow-up counts, separate initial/follow-up medians with timing sample counts, observed reply
rates and outcome fractions from the same attempted-turn cohort, supported
answer completion rates with supported-signal denominators, known failure/cancel/uncertain
counts, and the last seven active dates in a selected date range. It keeps named
copies distinct by configured identity. It estimates no missing history, costs,
tokens, quality score, or public rank. Favorites open a saved local comparison
projection; this view contacts no provider.

Stars and thumbs down are mutually exclusive reversible msgblast preferences.
Their append-only revisions survive restart. They send no Messages reaction or
website feedback. The embedded website companion strip lists recorded reply
excerpts; native conversations place controls beneath the corresponding reply.

## Measurement and collection limits

Elapsed time uses native monotonic clocks within one process and segment. Sleep,
wake, navigation, web-process loss, and disabled segments invalidate crossing
metrics. Wall dates and Messages source timestamps are retained separately.
Website observations use normalized conversation messages, a scoped mutation
notification, and existing one-second polling as fallback. DOM updates are not
model tokens. Performance-only extraction preserves paragraph line breaks and
preformatted code whitespace; receipt/send matching retains its existing
normalization. Known running-to-idle transitions in one document can establish
observed answer completion; unknown generation markup cannot. A website reply
is attributed only after the existing outgoing receipt path identifies its user
message. This may delay its first attributed observation. Manual sends are
recorded only in a linked page with a newly observed unique user message, with
unknown scope and no retroactive dispatch time.

Messages refresh at about two seconds. A sole owned outgoing receipt provides ordinary initial-turn timing even without
reply-to metadata. Saved follow-up payload anchors, or a unique new outgoing row
after a captured baseline and accepted plain-text submission, support follow-up
association. Intervening unowned sends or overlapping pending turns keep unknown
turn membership unless explicit source membership resolves it. Messages has no supported completion signal. CLI records
final output, with streaming unavailable; Bot uses its existing authenticated
callback. These signals describe answers, never successful task execution.

Earlier provider history is excluded at activation/navigation. Unknown layouts,
provider remounts, ambiguous ownership, and missing replies remain limitations;
the app does not claim independent witnessing or all-account completeness. Hidden message elements and hidden/script/style descendants are excluded through
a performance-specific extraction path; receipt extraction stays separate. A
recording error disables capture and preserves damaged bytes; it never retries a
provider request. Explicit deletion of the local performance journal can recover
recording, after which tracking must be enabled again.

## Integration boundary

`event-contract-v1.md` and `sample-upload-v1.json` define the versioned portable
native output. `PerformanceUploadChunk` is a data envelope, not a network client.
`PerformanceController` owns local lifecycle and native observation hooks.
`BenchmarkSettingsView` is the replaceable cloud-settings boundary. This build
shows honest local-only/account-not-connected content, with no simulated working
sign-in/upload controls. Cloud stream owns account/client/outbox/publication and
contribution integration, each behind its own consent.

Production, Dev, Demo, and isolated test support directories are selected by the
existing LocalStore/SupportDirectory boundary. Capture inherits that selected
directory and fixture provenance; it reads no provider cookies, credentials,
hidden DOM state, unrelated account UI, or general browsing history.


The journal writer appends one canonical line under an exclusive file lock and
synchronizes before publishing committed events. It verifies the retained byte
length to reject a competing stale writer. An interrupted/torn append preserves
all original bytes and stops recording; it is not truncated into a successful
empty record. This bounds each write independently of retained journal size.
My Stats does not show raw configured UUIDs; provider names and configured names
identify separate rows. Messages completion is explicitly unavailable; CLI/Bot
latencies are labeled final output/callback observations, with streaming absent.

Shared action membership uses optional app-generated requestGroupID and exact
configured targetAgentIDs, carried through existing broadcast/follow-up hooks.
Private/manual interleaving and repeated prompt text cannot align sessions by
text, timestamps or agent turnPosition. Unknown legacy/manual groups are unaligned;
publication must distinguish selected targets from agents not asked in that action.
