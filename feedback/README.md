# Private feedback intake

For native contributor setup, see [Build from source](../docs/build-from-source.md),
[Architecture](../docs/architecture.md), and [Testing](../docs/testing.md).
The source and handler are public, but submitted reports and their storage remain
private. Local handler/schema fixtures need no production account or R2 secret.

The native app sends an explicit, user-approved report to `POST https://msgblast.app/api/feedback`. The response is a receipt ID. This endpoint does not create GitHub issues, send email, return report contents, or publish downloadable files.

## Contract

Send `Content-Type: application/json` with `{id, kind, note, contact?, diagnostics?}`. The ID is a UUID retained for retries of the same submission. `kind` is `feedback` or `bug`. The native app enforces 8,000 Swift characters for the note and preflights the endpoint limits: 16,000 UTF-16 code units and a 64 KiB JSON request body. Oversized submissions show a local error before network transmission. The optional contact is a blank string or email address of at most 120 characters. `diagnostics` is an optional JSON **string** from `DiagnosticReport.diagnosticsJSON`; it is absent when the checkbox is off. The server parses it and accepts only the known diagnostic keys, types and categories. Changes to DiagnosticPayload need coordinated updates to the server validator.

A new report returns `201 {"id":"…"}` only after R2 confirms the write. An identical retry returns `200` with the same receipt. A reused ID with different content returns `409`. The server uses a canonical SHA-256 content hash in object metadata and an atomic conditional write. The app should retain an ID after an uncertain network result and reuse it only while the content is unchanged.

Validation failures return `400`; wrong media types `415`; excessive raw bytes `413`; non-POST methods `405`. Rate limiting returns `429` with `Retry-After: 60`. Storage or limiter failure returns `503`, so a failed write never looks like success. No public read/list endpoint or wildcard CORS is provided; this is a native-app API.

## Storage and operations

Create a dedicated **private** `msgblast-feedback` R2 bucket in the configured msgblast account. Never bind the public release/archive bucket. Do not enable the R2 public development URL or attach a public custom domain to this bucket. Reports include the user's note, optional reply email and optional diagnostics, so access must remain restricted to authorized team members through the Cloudflare dashboard or authenticated R2 tooling.

The Worker stores `reports/<lowercase UUID>.json` with `id`, `kind`, `note`, `contact`, optional parsed `diagnostics`, and a server-assigned ISO `receivedAt`. No IP address is persisted. The IP is used only as the rate-limit key. The Worker does not log the body, note, contact, IP, or diagnostic data. Invocation logs are disabled; sampled operational traces are enabled.

Production runs in the authoritative `msgblast-landing` Worker. Copy/import `handleFeedback` into that Worker's entry point and invoke it only for `/api/feedback`, delegating existing routes to `ASSETS.fetch`. Add `FEEDBACK_BUCKET` and `FEEDBACK_RATE_LIMIT` bindings there, retaining its existing assets, routes and hosting configuration. The template here deliberately defines no production routes and must not replace or compete with the landing Worker. Use the distinct rate-limit namespace `10018` with ten requests per sixty seconds. Cloudflare rate limiting is local to a Cloudflare location, not a guaranteed global quota.

Reports are available in the private bucket's dashboard object browser. Open only reports needed for support. R2 storage does not itself notify the team or create an issue; triage is manual. If an issue is needed, summarize the relevant problem after reviewing the report rather than exposing contact information or diagnostic artifacts publicly.

## Local validation

Run `node --test feedback/worker.test.mjs` from the repository root; no dependency installation is required. These tests use in-memory R2 and rate-limit fixtures and cover validation, streamed size limits, failure responses, opt-in omission, duplicate retries and races. They do not prove live Cloudflare bindings or deployment.

The `wrangler.jsonc` is a local/template configuration with no route. If needed,
use the pinned Wrangler installed by `npm ci --prefix download`. From `feedback/`,
run `../download/node_modules/.bin/wrangler dev` for a local API, or
`../download/node_modules/.bin/wrangler deploy --dry-run` to validate the bundle.
Inspect the template's local bindings before exercising it. These commands do
not deploy the production landing Worker or prove its private storage bindings.

Production deployment belongs to the owner's separate authoritative landing
checkout, followed by a clearly labeled fixture request and authenticated
verification that the private object was written. Its local path is not a
contributor prerequisite. Coordinate native diagnostic-schema changes with that
handler and keep the existing assets/routes intact. Never deploy this template
as a replacement for the landing site or include private reports in public PR media.

API semantics: [R2 Workers bindings](https://developers.cloudflare.com/r2/api/workers/workers-api-reference/) and [Workers rate limiting](https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/).

## Verified deployment — October 7, 2026

The authoritative landing checkout at `/Users/contains/projects/msgblast/landing` deployed Worker version `f1f579d1-5824-46b1-9a9f-ea3f018732a3` on `msgblast.app`, with this handler copied byte-for-byte into `worker.mjs`. Its assets use `ASSETS` and `run_worker_first: ["/api/feedback"]`. The private bucket was created with Public Access disabled. Synthetic API checks confirmed new-report 201, identical-retry 200, and GET 405. An isolated native demo app submitted a synthetic note with diagnostic opt-in and displayed the matching receipt; the authenticated R2 object preview confirmed the note and allowed diagnostic fields. These checks used no real messages or contact address and did not release or replace the installed app.
