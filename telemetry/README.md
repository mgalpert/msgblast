# msgblast telemetry intake

`worker.mjs` is a dependency-free Cloudflare Worker handler for the native
collector. The public source contains no PostHog project token or personal API
key. Collection permission belongs to the native client; this endpoint enforces
the data schema independently. A public ingestion endpoint cannot establish that
events came from an authentic app. Treat statistics as directional.

## Contract

POST `/api/telemetry` with `Content-Type: application/json`:

```json
{
  "schema": 1,
  "events": [{
    "id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    "name": "app_active",
    "category": "activity",
    "timestamp": "2026-10-12T12:00:00Z",
    "distinctID": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
    "properties": { "cohortDay": 7, "appVersion": "0.2.0", "osMajor": 26 }
  }]
}
```

Maximum 20 events and 32 KiB per batch, including streamed requests without a
Content-Length header. Unknown fields are rejected, rather than silently removed.
All events require UUID `id`, ISO8601 `timestamp`, `name`, `category`, and a
`properties` object. A random installation UUID `distinctID` is optional; omit it
when Activity linkage is disabled. Unlinked events use their own event UUID as
PostHog's required distinct ID.

| Event | Category | Required properties |
| --- | --- | --- |
| `onboarding_completed` | `activity` | None |
| `agent_added` | `agentUsage` | `provider`: catalog key; `count`: additions |
| `agent_inventory` | `agentUsage` | `counts`: provider to integer count (0–100) |
| `message_submitted` | `messageCounts` | `kind`: shared/private; `recipientCount`: 1–100 |
| `app_active` | `activity` | None |
| `app_engaged` | `activity` | None |
| `operation_result` | `reliability` | `operation`: send/setup/storage; `result`: success/failure |
| `operation_timing` | `performance` | `operation`: send/setup/storage; `duration`: under_1s/1_to_5s/5_to_30s/over_30s |

Provider keys: `chatgpt`, `claude`, `grok`, `muse`, `dots`, `os3`, `hark`,
`grokbot`, `codexCLI`, `claudeCode`, `dshCLI`, `openclaw`, `hermes`, `instinct`, `fo`, `szn`,
`poke`, `otherMessages`. Custom names and contact identities are never accepted.

Optional common properties: `buildChannel` (`development` or `production`), `appVersion` (32-character safe version token),
`osMajor` (15–99), `cohortDay` (0–3660, only with `distinctID`), `cohortStartedAt` (ISO8601 UTC, only with `distinctID`), and `fixture`
(boolean). Production rejects `fixture: true`. An isolated test Worker/project
can explicitly enable fixture intake through `TELEMETRY_ALLOW_FIXTURES=true`.
Never enable that flag in production or send fixture data to production projects.

Success is HTTP 204 only after PostHog's batch endpoint returns a successful
status. This establishes ingestion submission, not that dashboards have finished
processing events. On transient failure, the native collector retries with the
same event UUIDs; PostHog uses these for deduplication. The Worker does not retain
a queue or retry itself. Upstream requests have a 5-second timeout and redirects
are refused.

## Integrating into a Worker

The production landing checkout is separate from this repository. Import or
copy this module there, routing `/api/telemetry` to `handleTelemetry(request,
env)` before the static asset handler. Other website routes remain with the
existing handler. Keep the public collector URL configurable for forks; personal
source builds and Demo must not enable official production collection. Dev can explicitly enable consent-controlled uploads with the preview packager flag.

Configure the deployment with:

- `POSTHOG_HOST`: exactly `https://us.i.posthog.com` or
  `https://eu.i.posthog.com`, matching the selected project's region.
- `POSTHOG_PROJECT_TOKEN`: Worker secret containing that project's ingestion
  token. Do not use a personal API key, or commit credentials.
- `TELEMETRY_RATE_LIMIT`: rate-limit binding. Example Wrangler fragment:

```json
{
  "ratelimits": [{
    "name": "TELEMETRY_RATE_LIMIT",
    "namespace_id": "1001",
    "simple": { "limit": 60, "period": 60 }
  }]
}
```

Select an unused namespace ID for the account. The example is not proof of an
available namespace. Cloudflare rate limits are per location, not an exact global
quota. Shared networks may encounter a shared limit.

The rate limiter uses an hourly SHA-256 digest of the network IP solely for
short-lived abuse control. This is not an anonymity guarantee: Cloudflare sees
the network request, and hashes of IPs can be guessed. No IP, user agent,
request header, content, or raw error is forwarded to PostHog or logged by this
module. Do not enable invocation logs, request-body logs or request traces on
the telemetry route without revisiting privacy disclosures and their retention.
The Worker does not create PostHog person profiles and disables GeoIP enrichment.
The endpoint is for native requests and does not expose browser CORS headers.

Reference: [Cloudflare rate-limit bindings](https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/),
[PostHog capture API](https://posthog.com/docs/api/capture),
[PostHog capture SDK contract](https://github.com/PostHog/sdk-specs/blob/main/openspec/specs/capture/spec.md).

## Validation

Run `node --test telemetry/worker.test.mjs` from the repository root. Tests call
the actual HTTP handler with native Web Request/Response and streams, replacing
only Cloudflare's rate binding and the outbound PostHog transport. They cover
allowed payloads, identity handling, privacy-field rejection, streamed byte
limits, fixtures, upstream rejection, and fail-closed configuration.

These tests do not prove a live Cloudflare binding or real PostHog ingestion.
Before enabling an official release, verify an isolated project's synthetic
batch through the deployed endpoint and query that same event UUID in PostHog.
Record the source revision, project/environment, and fixture limitation. Also
verify production rejects fixture batches. No deployment is performed by tests.

## Native client

Official builds configure `MSGBLAST_TELEMETRY_ENDPOINT` through the release packager. The generator defaults it to empty, and the runtime rejects collection in Demo and unknown bundle identities. Dev uploads are explicitly enabled by `scripts/build_preview_apps.py --enable-dev-telemetry`; default previews stay disabled. Development events include `buildChannel: development`, and official releases use `production`. No PostHog SDK or token is embedded in the app. Accepted events are persisted by the actor off the main thread before the next upload so short sessions survive quit. A Swift actor uses an ephemeral, cookie-free URLSession, at most 200 queued events and 20 events per upload. Uploads occur every 60 seconds or at the batch threshold, with bounded exponential backoff. Pending events expire after seven days. Changes to saved consent cancel an in-flight request and clear the unsent queue. Already transmitted requests cannot be recalled. Collection never delays quit or requires an upload to finish before a send. See [metric definitions](metrics.md).

`onboarding_screen_viewed` belongs to Agent usage and contains a closed `screen` value, optional `previousScreen`, and optional catalog `provider`. Screens: connectors, permissions, messages, agents, browserImport, providerConnection, runtimeSetup, feedback. These events begin after saved consent; the initial sharing screen is not tracked. Screen visits can repeat when going Back.
