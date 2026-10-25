# Crash reports

After a relaunch, msgblast checks macOS's local `~/Library/Logs/DiagnosticReports`
and `Retired` folder for recent `.ips` reports. A missing dirty-shutdown flag is
not crash evidence. Only Apple's JSON crash format (`bug_type: 309`) with a
supported fatal signal and a triggered stack is accepted. SIGTERM and SIGKILL
reports are excluded, so ordinary quit, permission-required restart, force quit,
and a lost session alone do not produce a crash offer. Reports older than 30
days, future-dated, malformed, empty, or over 2 MiB are ignored. Collection retries
at 5 and 30 seconds after launch for delayed macOS writes; Help can rescan later.

The app matches its exact bundle identifier and executable path. The bundled
cloudflared and embedded CuaDriver helpers must have the exact current app's
`Contents/Helpers/cloudflared` or `Contents/Helpers/cua-driver` path; standalone
CuaDriver installations, other copies, and unrelated apps are excluded. Moving the app since a crash
can make its old report ineligible. macOS path redaction can also prevent matching.
There is no crash signal handler, process termination injection, SDK, or paid
service. State, Messages, Contacts, and permission grants are never modified.

The launch offer has **Review report** and **Not now**. Neither uploads anything.
Not now and closing/dismissing the review remember the incident locally. Help →
**Review Crash Reports…**, also linked from feedback, allows later review of
eligible reports including dismissed reports. Only **Send crash report** submits.
Optional context is user-authored; the form asks users to omit private content.

The complete crash summary is visible before submission. It is reconstructed
from an allowlist: format version, incident UUID, app/helper category, app bundle
identifier, crashing executable's version/build when available, UTC day, exception
and signal categories, up to 64 crashed-thread frames (binary UUID, architecture,
image-relative instruction offset), and a grouping fingerprint. No raw IPS bytes,
exception messages, symbols, source filenames, paths, registers, process memory,
thread names, chat data, attachments, account details, or other threads are sent.
The crash workflow does not attach the general feedback diagnostic inventory.
Helper version/build can be `unknown` because standalone helper reports commonly
lack bundle metadata. Review the entire optional note before sending it.

A separate owner-only `crash-reports.json` journal lives beside the selected
profile's state file. It stores dismissals, confirmed incident IDs, and frozen
unconfirmed attempts with their user context and receipt IDs. It does not modify
`state.json`. A submission is journaled **before** network transmission. If the
network fails or the receipt is uncertain, **Retry same report** reuses identical
bytes and the same ID, including after relaunch. The note is locked during this
uncertainty: changing it could create a duplicate. Confirmed reports cannot be
submitted again through this journal. Deleting the journal or using another
profile removes that local duplicate protection; the service deduplicates by
submission ID, not globally by incident. Pending summaries remain reviewable from Help even if macOS removes the original
IPS; these frozen retries are retained until confirmation. A corrupt/unwritable journal fails closed
without sending or resetting application state.

## Maintainer triage

The existing private feedback intake stores `kind: crash` with a strictly
validated `crash` object. The 64 KiB request limit and rate limits still apply.
There is no public read endpoint or automatic issue/email notification. Use the
private feedback bucket's authenticated object browser or authorized R2 tooling
as described in [feedback operations](../feedback/README.md). Never paste private
notes or full reports into public issues, PRs, screenshots, or test fixtures.

Group reports by `crash.fingerprint`: SHA-256 of process, exception, signal, and
the first 12 UUID/offset pairs in order. It ignores incident/time and ASLR. Binary
UUID changes normally split groups across builds; compare symbolicated functions
to identify a continuing failure across releases. This is a grouping aid, not a
root-cause diagnosis. Client metadata is untrusted input and is not attestation.

For a production app report, look up the immutable
`https://updates.msgblast.app/releases/VERSION-BUILD.json` manifest. Its
`source_revision` identifies the release source. Verify binary UUIDs against the
matching archive/dSYMs before attributing a stack to that revision. Do not use the
currently running app's source SHA for a crash from a previous build. Preview
manifests and `msgblastSourceRevision` identify preview source, but development
version/build numbers may be reused: UUID verification is essential. Historical
reports without retained matching binaries/symbols may remain unsymbolicated.

Release builds explicitly generate dSYMs for the app and core framework.
The release workflow verifies both expected dSYMs, then retains the archive's dSYMs together with release JSON
in a separate `msgblast-symbols-RUN-ATTEMPT` Actions artifact for 90 days (subject
to repository retention policy). Download it before expiration and retain it in
maintainer-controlled storage for the supported lifetime of that build. The
existing public release ZIP/feed is unchanged. This source change does not create
symbols for old releases, execute a release, or prove retention in a future run.
Keep the exact app, msgblastCore, helper version/architecture, system version when
reproducing, source revision, and dSYMs. A dSYM from a rebuild is not equivalent.

Check UUIDs with `dwarfdump --uuid BINARY` and `dwarfdump --uuid FILE.dSYM`.
For an arm64 frame, symbolicate its image-relative offset with a matching dSYM:
`atos -arch arm64 -o FILE.dSYM/Contents/Resources/DWARF/EXECUTABLE -l 0 OFFSET`.
Use the frame's architecture and offset (convert decimal to hex if needed).
System frames require matching OS symbols; helper frames need the matching
upstream cloudflared or CuaDriver symbols/binary. This compact report deliberately omits
registers, raw exception reason, noncrashing threads, and OS inventories, so some
memory corruption, deadlocks, resource terminations, and contextual failures
will require a user-approved follow-up. There is no promise of complete crash
coverage: macOS can omit or delay reports, redact paths, or change its schema.

## Validation and deployment

Run the controller/intake fixture on the dedicated build Mac after building core:
`bash scripts/test_crash_reporting.sh build/crash-tests`. It wraps the actual
private intake handler in a loopback server and simulates a 503 acknowledgement
after a successful write; no production service is contacted. It verifies zero
requests before Send, persisted exact retry after reopening, one stored report,
duplicate blocking, and oversized context remaining editable.

Native regression tests use synthetic IPS data, temporary journals, unrelated
app/path cases, and state-preservation checks. Worker tests use private in-memory
storage substitutes. `--demo --isolated-demo --crash-report-preview` in a Debug
build offers one clearly labeled synthetic crash without crashing any process.
The packaged blue Demo additionally labels its workflow. Configure a loopback
`msgblastFeedbackEndpoint` on the Demo bundle for end-to-end fixture submission;
without it the synthetic preview refuses to send to production. Do not use this
fixture flag on Dev. Fixture success cannot prove macOS generated a real crash,
production intake deployment, or permission retention across an actual upgrade.

Deploying the updated handler in the authoritative landing checkout and
publishing the native app are separate maintainer actions. Existing production
intake rejects `kind: crash` until its validator is updated. An app-side rejection
remains an unconfirmed retry, with no false success. Coordinate handler deployment
before releasing the native feature. Do not deploy the template Worker from this
repository over the landing site.

Apple format reference: [Interpreting the JSON format of a crash report](https://developer.apple.com/documentation/xcode/interpreting-the-json-format-of-a-crash-report).
