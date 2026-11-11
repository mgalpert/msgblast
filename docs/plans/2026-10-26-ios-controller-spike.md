# iOS controller phase 0 spike results

Status: phase 0 of [the iOS controller plan](2026-10-24-ios-controller-architecture.md) §6.
Run on 2026-10-26 on the owner's development Mac (macOS 27.2, build 26B118,
Xcode 27.0 27A5218g, Swift 6.4, Apple silicon) from branch `ios-controller`
at `6faf49d`. The throwaway programs lived under `build/spike/` (ignored by Git);
the parts worth keeping became `msgblast/Core/Remote/` in phase 1. Nothing here
launched, quit, or changed the installed msgblast app, its support folder, any
macOS permission, Tailscale, or another app.

## Answers

| Question | Answer | Evidence |
| --- | --- | --- |
| a. TLS 1.3 `NWListener`, self-signed P-256 identity, bound to the Tailscale utun and the LAN address, Bonjour on LAN only, pinned client | **Yes** | One listener per address on one port. Pinned client got TLS 1.3 and an echo on all three addresses; a wrong pin and `127.0.0.1` were refused. Bonjour registered only on `en0` once the LAN listener set `requiredInterface`. |
| b. Off-window `WKWebView` (800×600, never in a window) passes the page script's `getClientRects().length > 0` test | **True** | Standalone probe and two existing unit tests that submit through never-windowed fixture pages. `document.visibilityState` is `hidden`. |
| c. Lock-screen matrix | **Not run** (needs a human at the Mac) | Procedure below. |
| d. Availability loop cost | **~45 ms per warm pass** (median of 20; p90 49 ms; cold 157 ms) | Probe below. Contacts status (~16 ms) and the screen-capture preflight (~8 ms) dominate. |
| Tailscale variant on this Mac | **Standalone (macsys) app 1.104.1, plus a Homebrew `tailscaled` 1.102.3** | Read-only inspection below. Two tailnet utuns are up at once. |

## a. Listener, TLS, bind, Bonjour

Method (`build/spike/tls_spike.swift`, one process acting as server and client):

1. Generate a CryptoKit `P256.Signing.PrivateKey`. Build a minimal X.509 v3
   certificate by hand in DER (issuer = subject = `CN=msgblast remote`,
   `ecdsa-with-SHA256`, 20-year validity, no extensions) and sign the TBS with the
   same key.
2. `SecKeyCreateWithData` on the key's 97-byte x9.63 representation (an
   in-memory key, no Keychain item) plus `SecCertificateCreateWithData`, then the
   public `SecIdentityCreate(nil, certificate, key)` and `sec_identity_create`.
   No Keychain write and no PKCS#12 import are needed.
3. `getifaddrs` → IPv4 addresses. Tailscale = a `utun*` interface with an address
   in `100.64.0.0/10`; LAN = a non-utun RFC 1918 address. Loopback is excluded.
   This Mac had `utun0 = 100.123.173.125`, `utun9 = 100.68.57.78`, and
   `en0 = 192.168.4.25`.
4. One `NWListener` per address with `NWProtocolTLS` min and max **TLS 1.3**,
   `requiredLocalEndpoint = address:port` and the same port on every listener.
   Only the LAN listener sets `service = _msgblast._tcp`.
5. Client: `NWConnection` with TLS 1.3 and a `sec_protocol_options_set_verify_block`
   that hashes the leaf's SubjectPublicKeyInfo (P-256 SPKI prefix + x9.63 key)
   with SHA-256 and compares it to the pinned value.

Results:

```
listener ready on utun0 100.123.173.125:59971
listener ready on utun9 100.68.57.78:59971
listener ready on en0 192.168.4.25:59971
pinned client → 100.123.173.125: ok tls=1.3 reply=echo:utun0:hello
pinned client → 100.68.57.78: ok tls=1.3 reply=echo:utun9:hello
pinned client → 192.168.4.25: ok tls=1.3 reply=echo:en0:hello
wrong pin → 100.123.173.125: waiting: -9808: bad certificate format
loopback (must not be bound) → 127.0.0.1: waiting: Connection refused
bonjour registration on en0: add(msgblast-spike-59971._msgblast._tcp.local.)
bonjour result: msgblast-spike-59971._msgblast._tcp.local. interfaces: ["en0"]
```

Findings that shape phase 1:

- **Same port on several addresses needs `allowLocalEndpointReuse = true`.**
  Without it the second and third listeners failed with `EADDRINUSE` even though
  each named a different address.
- **Bonjour follows `requiredInterface`, not the bound address.** With only
  `requiredLocalEndpoint`, the browse result listed `lo0`, `en0` and `anri1`.
  Setting `requiredInterface` to the `NWInterface` named `en0` (from
  `NWPathMonitor.availableInterfaces`) limited the advertisement to `en0`.
  `NWPathMonitor` did not list `utun0` at all, so Tailscale listeners bind by
  address and set `requiredInterface` only when the monitor knows the interface.
- A loopback connection to the port is refused, so binding by address never
  exposes the Grok Bot loopback range or a wildcard.
- **Not proven:** a phone on cellular reaching the utun address through
  Tailscale. The same-machine client exercises the bound socket, the TLS stack
  and pinning, not the tailnet path. A human test is listed under c.

## b. Off-window WebKit readiness

Method 1 (`build/spike/webview_spike.swift`): `WKWebView(frame: 800×600)` with a
non-persistent store and `javaScriptCanOpenWindowsAutomatically = false`, never
added to a window, exactly like `WebAgentSession.makePage`. Load the fixture
editor shapes and evaluate the page script's own predicate
`e => !!e && e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden'`.

| Page | window | `getClientRects().length` | predicate | `document.visibilityState` |
| --- | --- | --- | --- | --- |
| `<textarea>` editor (ChatGPT/Grok/OS3 fixture shape) | none | 1 | **true** | hidden |
| contenteditable editor (Claude/Dots fixture shape) | none | 1 | **true** | hidden |
| control: `display:none` editor | none | 0 | false | hidden |

Method 2: the existing tests already submit through never-windowed sessions.
`MultiWebAgentTests/testContentEditableSpacingDoesNotStopSharedSubmission` and
`testSavedDraftRestoresIntoWhitespaceOnlyWebsiteEditor` wait for
`snapshot.ready` (which requires a visible unique editor) and then send. Both
passed on this Mac:

```
xcodebuild … -derivedDataPath build/ios-controller \
  -only-testing:msgblastTests/MultiWebAgentTests/testContentEditableSpacingDoesNotStopSharedSubmission \
  -only-testing:msgblastTests/MultiWebAgentTests/testSavedDraftRestoresIntoWhitespaceOnlyWebsiteEditor \
  test-without-building   →  ** TEST EXECUTE SUCCEEDED **
```

Limits: these are local fixture pages. `document.visibilityState` is `hidden`
for an unwindowed view, so a real site that defers rendering or throttles timers
while hidden could still fail its own readiness. Display sleep and a hidden app
were not tested. Phase 3 (live Dev) must check each real website with the main
window closed.

## c. Lock-screen matrix (human procedure, not run)

Prerequisites: a Demo build is **not** enough for this question; it simulates
apps and sends. Use the blue-green **msgblast Dev** preview on a Mac whose owner
authorizes one real send per connection type, with phase 1's
`scripts/remote_client` paired to it (see `docs/remote-control.md`). Use test
prompts such as "Reply with OK". Do not use real Messages contacts unless the
owner explicitly approves that contact.

1. On the Mac: open msgblast Dev, Settings → Remote, turn remote control on,
   pair `remote_client` from a second machine on the tailnet (or the same Mac's
   Terminal over the utun address). Confirm `macStatus.locked == false`.
2. Lock the Mac with ⌃⌘Q. Do not let it sleep: keep it on power and confirm the
   keep-awake assertion with `pmset -g assertions | grep msgblast` from an SSH
   session if available.
3. From the client, print the next `macStatus` event. Record `locked`, `awake`,
   and whether a send command is rejected with `macLocked` (the decided v1
   behavior). This verifies the v1 guard, not whether a send would work.
4. To answer the original research question (what would work if v1 allowed it),
   repeat with a debug build in which the lock guard is disabled locally (never
   committed): one send each to a website agent, a CLI agent, the Grok Bot
   webhook, and one Mac app agent. Record per type: command result, attempt
   status after 3 minutes, and whether the reply text appears in the projection.
   Expected: desktop apps fail (no window server input while locked); websites,
   CLIs, and the webhook are the open questions.
5. Repeat step 3 with the display asleep but unlocked (`pmset displaysleepnow`)
   and record `awake` and the result.
6. Unlock. Confirm the client receives `locked == false` and that queued events
   resume from its last `seq` without a full snapshot.
7. Cellular check for a: put the phone on cellular with Tailscale on, run the
   client (or the phase 2 app) against the Mac's `100.x` address, and record
   connect time and whether pinning succeeds. Then turn Tailscale off on the
   phone and confirm the connection fails rather than falling back to anything.

## d. Availability loop cost

Method (`build/spike/probe_spike.swift`, `-O`, one process, main thread): one pass
= `AXIsProcessTrusted`, `CGPreflightScreenCaptureAccess`, a fresh one-byte read
of `~/Library/Messages/chat.db`, `CNContactStore.authorizationStatus`,
`AEDeterminePermissionToAutomateTarget(… ask: false)` for Messages when it is
running, `NSRunningApplication` + `NSWorkspace.urlForApplication` for the six
desktop bundle ids, and `CGSessionCopyCurrentDictionary`. 21 passes; the first
is reported separately.

```
cold first pass: 156.89 ms
warm passes n=20 median 44.88 ms p90 48.76 ms max 61.02 ms
```

Per probe (median of 20):

| Probe | ms |
| --- | --- |
| `CNContactStore.authorizationStatus` | 16.37 |
| `CGPreflightScreenCaptureAccess` | 7.96 |
| Automation `ask: false` (Messages running) | 5.89 |
| `NSRunningApplication` ×6 | 0.75 |
| `CGSessionCopyCurrentDictionary` | 0.07 |
| chat.db one-byte read | 0.02 |
| `urlForApplication` ×6 | 0.01 |
| `AXIsProcessTrusted` | 0.00 |

The spike binary is not msgblast, so the permission values it read describe the
terminal's TCC identity, not the app's; only the timing matters. CLI account
status (`codex login status`, `claude auth status`) was not run, to avoid
invoking the owner's CLIs; it is a 10-second-bounded subprocess and belongs on a
slow cadence. Phase 1 consequence: the loop runs every 5 s only while a client is
connected and keeps the Contacts, screen-capture and Automation probes off the
main thread (the existing `AppPermissions.refresh` already detaches the slow
ones).

## Tailscale variant (read-only)

- `/Applications/Tailscale.app`: bundle id `io.tailscale.ipn.macsys`, version
  1.104.1, with `io.tailscale.ipn.macsys.network-extension.systemextension` and
  no `_MASReceipt`, so it is the **standalone (Developer ID) app**, not the Mac
  App Store build (`io.tailscale.ipn.macos`).
- `/var/run/tailscaled.socket` exists and `/opt/homebrew/opt/tailscale/bin/tailscaled`
  (Homebrew 1.102.3) is running: the **open-source daemon** is also installed.
- Two Tailscale utuns are up (`utun0`, `utun9`), presumably one per daemon. The
  bind policy must therefore treat *every* CGNAT utun as a Tailscale candidate
  rather than assume one. The optional LocalAPI `whois` check would have to pick
  a daemon; it stays out of v1.
