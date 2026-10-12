# Local recording and optional benchmark cloud actions

My Stats uses records on this Mac. Recording defaults off. Signing in, recording,
favorites and negative feedback do not themselves permit a cloud upload.

The Benchmarks tab provides separate choices:

- **Future private sync:** off by default and bound to the verified account. New
  comparisons after opt-in queue automatically. Existing comparisons require
  explicit selection. Previously selected cloud lineages may continue privately.
  Pause stops transmission and retries; sign-out pauses the account's queue.
  Another account cannot use its ownership or consent. Relaunch restores ongoing
  consent only for the same verified account. Unknown provider context stays unknown.
- **Selected private upload:** uploads the complete captured prefix, including
  private prompts, identifiers, reply revisions and feedback. A selected prefix
  remains saved for exact retry. Uploading one prefix does not opt into future sync.
- **Publication:** creates an independently reviewed projection. Default preview
  excludes private/unknown-scope turns, earlier uncollected history, attachments
  and earlier streaming revisions. Captured private/unknown turns and revisions
  have separate inclusion controls. Public title and agent aliases are editable; captured prompts/replies are read-only.
  Manual redaction only replaces exact selected text with `[redacted]` masks. Selected
  text/PNG/JPEG artifacts are shown as their actual bytes. Inspect images and text
  before approval; automatic redaction is incomplete. The exact preview bytes and
  hash determine the publication. Sharing works with private sync paused.
- **Contribution:** explicit evidence selection can upload while private sync stays
  paused. A separate final choice binds a finalized snapshot. Later private
  replies or feedback do not change that selection. A freshly approved new snapshot supersedes the same lineage, which counts once. Revision numbers are computed from verified owner history;
  active identical retries retain their binding. Withdrawal removes its
  current aggregate influence. Fixtures never receive accepted benchmark credit.

Private snapshots pin the original global event/chunk sequence and hash prefix.
A continuation opens a new cloud revision; finalized validation and older links
remain unchanged. Stars and negative feedback stay frictionless local actions.
With ongoing private sync enabled they can appear in a later private revision;
they never publish or revise a contribution automatically.

Cloud record deletion tombstones access, associated links and contribution before
asynchronous cleanup. Local records remain unless separately deleted. Account
cleanup tracks content and managed identity stages; a provider error is not a
completed deletion. Deleting local records cancels/clears the local upload journal
and future-sync consent without claiming remote deletion. Original damaged journals
are preserved rather than replaced with empty successful state.

## Authentication and encrypted credentials

Managed sign-in uses AuthenticationServices, PKCE, random state, an exact callback
and a scope-qualified bearer token. The API independently verifies token signature,
issuer, audience and expiry. Native account identity comes from its verified API
response. Agent browser cookies and ID-token payloads do not establish ownership.

Credentials stay in encrypted macOS Keychain storage, scoped by app bundle,
profile and service/issuer/client/audience/callback realm. Provisioned signatures
with access-group entitlements use Data Protection Keychain. The supported ad-hoc
signature uses the encrypted login Keychain with its normal code ACL. The adapter
chooses before operations; storage failures remain visible and never cause a file
or UserDefaults fallback. Queries suppress authentication UI.

An actual isolated signed native-host test found Data Protection-only storage
failed with `errSecMissingEntitlement (-34018)` under ad-hoc signing. The encrypted
login-Keychain save/read/delete test passed after the explicit route correction.
It used a throwaway synthetic UUID scope and removed the item. This proves a
same-host round trip, not credential retention across signature changes. Changes
to code identity may require owner Keychain approval or renewed sign-in. See
[Apple's macOS Keychain implementation guidance](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains).

## Configure a managed build

The generator defaults all service/provider values empty; cloud login stays
unconfigured until the maintainer supplies public build settings:

- `BENCHMARK_SERVICE_URL`: dedicated HTTPS service origin.
- `BENCHMARK_OIDC_ISSUER`: approved Auth0 issuer with trailing slash.
- `BENCHMARK_NATIVE_CLIENT_ID`: public native PKCE client.
- `BENCHMARK_OIDC_AUDIENCE`: independently verified API audience.

The callback is `PRODUCT_BUNDLE_IDENTIFIER:/benchmark`; its scheme is registered
in Info.plist. Allowlist each intended variant callback at the provider. Enable
refresh rotation/grants and `benchmarks:write`. Keep management client secrets on
the Worker, never in the app. Finalize resource/domain/retention/cost approval
before live activation. Source review is neither deployment nor app distribution.

## Synthetic integrated verification

Native unit tests use the documented isolated Xcode test command. The focused
classes are BenchmarkAccountTests, BenchmarkOAuthTests, BenchmarkKeychainTests,
BenchmarkSyncStoreTests, BenchmarkCloudClientTests and ComparisonPublicationTests.

The actual native controller fixture can connect to the dependent backend checkout:

```sh
npm run check --prefix /absolute/backend-checkout/benchmarks
node scripts/fixtures/benchmark_worker_bridge.mjs /absolute/backend-checkout/benchmarks /absolute/temporary-fixture-directory
bash scripts/test_benchmark_cloud.sh /absolute/isolated-derived-data /absolute/temporary-fixture-directory
```

The bridge creates a synthetic signed token in an owner-only temporary file; it
prints no token. OAuth browser/code exchange and credential storage are simulated.
Account verification, private upload, snapshots, publication, anonymous read,
contribution/withdrawal/revoke/deletion use actual local Worker/D1/R2/Queue paths.
The test covers ongoing future consent, exclusion of old prefixes, pause/resume,
relaunch and immutable prior heads/capabilities. It sends no real Messages, creates
no Contacts, and makes no live provider/identity calls.

For visible QA, launch an isolated Demo with `--benchmark-fixture` pointing to the
temporary directory and `--isolated-demo`. The directory must resolve below the
current macOS temporary directory; only loopback HTTP is accepted. Its AppStore
is isolated beneath that directory. `benchmark_seed.swift` creates accurately
labeled synthetic native journal events for preview interaction, not live connector
evidence. Production and Dev never load this fixture transport or credential store.

### Review fixes and account recovery

Contribution approval is bound to the verified owner, comparison, cloud session, and finalized snapshot. A newer private continuation clears that approval; contribution submission checks the same binding again after loading history. The accepted comparison count comes from the verified owner's service response, and remains unavailable until loaded. Switching accounts clears cloud records, links, history, and that count.

Temporary token endpoint or verification outages retain the current verified account for retry. A rotated credential is held in memory only until its identity is verified and Keychain persistence succeeds; it cannot authorize cloud requests before those checks. If it expires during an outage, recovery uses its rotated refresh credential. A permanent authentication failure or changed identity stops the session. Restart before an unpersisted rotation is recovered can require signing in again.

A deleted account can restore a restricted session only when the authenticated deletion response confirms the saved owner. It permits only read-only deletion-status polling, including blocked identity cleanup. Refresh still requires the identity provider: expired credentials cannot bypass authentication if that provider is unavailable or the identity has already been removed.

Publication association is private request metadata outside the approved public projection. Sharing sends the selected local comparison ID and, if available, its verified owner's cloud session ID; it does not create or upload a raw session. Deleting that comparison's cloud record revokes associated links whether publication happened before or after the explicit upload. Saved associated links are marked revoked locally. Older saved links without association metadata remain separately revocable; their original journal format still decodes.

Focused controller regression checks can be run with `scripts/test_benchmark_controller.sh /absolute/path/to/isolated-derived-data`. They use actual native controllers and synthetic OAuth, HTTP, and credential-store boundaries; they hold requests across debounce and account changes and verify local-delete cancellation/preservation. The separate loopback Worker workflow verifies both publication/deletion orderings and fixture-ineligible accepted count.
