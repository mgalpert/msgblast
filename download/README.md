# Latest app download

This is the maintainer guide for the download service. For the native app, use
[Build from source](../docs/build-from-source.md). Worker contributors can run
the local checks below without publishing or accessing release credentials.

`https://updates.msgblast.app/latest.zip` returns a temporary **302** redirect to the highest published build in the Sparkle appcast. The root README uses this fixed URL. Publishing a new signed appcast automatically changes its destination; neither README edits nor Worker redeployments are needed per release.

The Worker fetches the fixed public feed on each request, verifies its Ed25519 signature using the app's persistent public key, and accepts only the version/build-matching ZIP on the release host. It returns `503` if the feed is unavailable or invalid. The feed and redirect are uncached; immutable ZIPs retain their existing cache policy. The route is limited to `updates.msgblast.app/latest.zip*`, so archive, feed, and ledger traffic continue directly to R2. The handler accepts only `/latest.zip`, GET and HEAD; query parameters cannot change the destination.

## Local checks

```sh
npm ci --prefix download
npm test --prefix download
npm run check --prefix download
```

Run these from the repository root with Node.js 22/npm. `check` is a Wrangler
deployment **dry run**, not publication. The tests use controlled feed/request
fixtures. They do not prove production routing, signed feed availability, or
completed downloads. See [Testing](../docs/testing.md#python-and-backend-checks).

## Maintainer deployment

After review and local validation, an authorized maintainer can run:

```sh
npm run deploy --prefix download
```

Deployment targets `msgblast-download` in Cloudflare account `659c439216958cf1ab948ef03342ad18`. Wrangler needs an authorized Cloudflare login for Worker script/route changes. The initial deployment used the account's existing dashboard session. No new release secret, R2 binding, Apple credential, or signing key is needed. This Worker is separate from the app release workflow and needs redeployment only when its code/config changes. Keep the checked-in code and dashboard configuration in sync.

Verify the deployed fixed URL with a HEAD request using the known verifier
User-Agent. Confirm the no-store 302 and destination against the current signed
feed/immutable manifest; do not infer publication from a local dry run:

```sh
curl -fsSI -A msgblast-release-verifier https://updates.msgblast.app/latest.zip
```

Workers Logs records a `download_redirect` event with version/build for successful GET requests. HEAD checks do not generate that event. This is request/redirect activity, including retries and bots; it does not measure completed downloads or installs. No cookies, addresses, or query values are written by the application logger. Cloudflare's platform request metadata follows the account's existing policies. Logs have platform retention/sampling limits; no permanent Analytics Engine download counter is configured.

References: [Cloudflare routes](https://developers.cloudflare.com/workers/configuration/routing/routes/), [Workers redirects](https://developers.cloudflare.com/workers/examples/redirect/), [Web Crypto](https://developers.cloudflare.com/workers/runtime-apis/web-crypto/).
