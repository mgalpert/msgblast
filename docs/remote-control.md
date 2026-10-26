# Remote control (phone controller, Mac side)

Remote control lets one paired phone use msgblast on a Mac: see every agent's
availability and the conversations' replies, start conversations, send shared and
private messages, end conversations, and acknowledge stuck requests. The Mac stays
the only executor. Phase 1 (this guide) is the Mac service plus a command-line
client; the iOS app is phase 2 of the
[iOS controller plan](plans/2026-10-24-ios-controller-architecture.md).

## Turning it on

Settings → Remote → **Allow a paired phone to use msgblast on this Mac**. It is
off by default, and an upgraded Mac opens no port until the user turns it on.
Turning it off disconnects the phone and closes every listener.

| Setting | Default | Effect |
| --- | --- | --- |
| Network | Tailscale if available, otherwise local network | Which addresses the listener binds (below) |
| Keep this Mac awake | On | Holds an idle-sleep assertion while a phone that asked for it is connected, and during every remote send. Off disables both. |
| Send iMessages from the phone | **Off** | Messages agents refuse remote sends with `messagesSendsOff`. An iMessage cannot be unsent and the phone already has Messages. |
| Listen on the network (Demo) | Off, not saved | Demo only; see [Demo behavior](#demo-behavior) |

## Pairing

1. Settings → Remote → **Pair a phone…** shows a QR code and a `msgblast://pair`
   link (handled by the phone app in phase 2; nothing on the Mac registers the
   `msgblast://` scheme). It contains the Mac's name, candidate addresses and port, the SHA-256 of
   the TLS key, the SHA-256 of the Mac identity key, and a 128-bit one-time code.
2. The code works once and expires after two minutes. Five wrong answers close
   pairing; show a new code.
3. The phone answers an HMAC challenge keyed by the code and bound to the session
   transcript and to its own P-256 key, and signs the transcript with that key.
4. The Mac stores only the phone's public key, name, and created/last-seen dates.

One phone per Mac. **Pair a different phone…** asks for confirmation; the new
phone replaces the old record only after it pairs. **Forget** disconnects and
removes the record. There are no accounts.

## Network and bind policy

| Policy | Binds |
| --- | --- |
| Automatic | Every Tailscale address, or the LAN when no Tailscale address exists |
| Tailscale only | Every `utun*` address in `100.64.0.0/10` |
| Tailscale and local network | Both |
| Local network only | Private (RFC 1918) addresses on non-tunnel interfaces |

The listener binds each address explicitly on one port (saved in settings, a new
random port if it is taken). It never binds loopback (the Grok Bot callback range)
or a wildcard address, and never uses Tailscale Funnel. Bonjour `_msgblast._tcp`
is advertised only by LAN listeners, scoped to their interface. Addresses are
rechecked when the network changes. Both the Mac App Store and standalone
Tailscale apps work, because detection reads interface addresses only; a Mac with
two Tailscale daemons gets both addresses.

## Security model

Security does not depend on the route:

- **Mac identity.** One long-lived P-256 key, created on first use, signs every
  session and serves the TLS certificate. It is a software key wrapped by a Secure
  Enclave key rather than an Enclave key, because the Enclave cannot hold a TLS
  server key. At rest it is encrypted under a Secure
  Enclave key (as the Grok Bot vault does), otherwise kept in the data-protection
  Keychain, otherwise session-only and labeled as such in Settings (the phone must
  pair again after msgblast restarts).
- **Transport.** Direct routes use TLS 1.3 with a hand-built self-signed
  certificate; the phone pins the SubjectPublicKeyInfo hash from the QR code.
- **Application layer.** Every session does an ephemeral X25519 agreement. The
  Mac signs the handshake transcript with its identity; the phone signs it with
  its paired key (or proves the pairing code). HKDF-SHA256 derives one
  ChaChaPoly key per direction. Every frame after the handshake is encrypted with
  a strictly increasing counter, so replayed, dropped or reordered frames close the
  session. A future relay carries only ciphertext.
- **Framing.** 4-byte length prefixes; frames over 8 MB are refused before
  buffering.

Persisted remote data, all owner-only (0600) in the app support folder:
`remote-identity.json`, `remote-device.json`, `remote-settings.json`. An
unreadable file is left in place and remote control stays unavailable rather than
replacing it.

## What the phone sees and does

The Mac projects a normalized, derived view: Mac status, the visible agent grid,
per-agent availability, conversations, turns (shared prompts, follow-ups, website,
app, CLI and bot transcripts, Messages replies), attempts, and comparison reports.
Changes stream as events with a monotonic `seq`; a reconnecting phone resumes
from its cursor or receives a full snapshot. Website replies are seen live even
though the Mac persists them only when a conversation ends.

Commands run through the same AppModel and session paths as the Mac UI, so every
duplicate-send and unresolved-attempt guard applies:

| Command | Mac path |
| --- | --- |
| New conversation | `AppModel.sendShared` (websites, apps, CLIs, bots, Messages) or `startBlast` (Messages only) |
| Shared follow-up | `AppModel.sendShared` with the existing conversation |
| Private message | `AppModel.sendDirect`, a Messages private follow-up, or a one-agent `startBlast` |
| End conversation | `AppModel.endConversation`, only when every website history is loaded (`historyNotLoaded` otherwise) |
| Acknowledge / stop waiting | `acknowledgeIncompleteRequest`, `cancelNativeRequest` (the other app is not stopped) |
| Attachments | Chunked upload (256 KB chunks, 25 MB, SHA-256 checked) → `LocalStore.stage`; Messages agents only |
| Keep awake | The phone's request; the Mac setting can refuse it |
| Report | `PersonalAgentController.requestReport` on the Mac |
| Prepare agents | `WebAgents.prepareComparison` without launching apps, then a readiness wait |

Rules the Mac enforces:

- Each command has a `clientCommandID`. A replay returns the stored or in-progress
  result and never repeats the action. The ledger is in memory only.
- Sends run one at a time, so Mac app requests stay serial across commands. A send
  that waits is answered `accepted`, then re-checked when it starts; if the Mac
  user started a send meanwhile it is refused (`macBusy`), never retried.
- Nothing is retried. A phone that loses the connection mid-send must show the
  send as unconfirmed.
- A remote command never opens a Contacts prompt, never takes or clears the Mac's
  composer draft, and sets aside the Mac's Messages drafts and files for its own
  follow-up. Errors go to the command result, not the Mac's alert.
- The phone sends `prepareConversation` when it opens a composer or changes
  recipients. The Mac runs the same prepare paths as its composer (it may open a
  website chat page, never launches an app, never sends) and answers when the agents
  are ready, or with each agent's reason (`notReady`). If a send still finds a page
  that had to be prepared, nothing has been submitted; the Mac waits up to 20 seconds
  for readiness without navigating again and then sends once, or answers `notReady`
  with nothing submitted. The phone never has to "send again". `preparedNotSent`
  remains only for compatibility.
- `queryCommand` asks for an earlier command's result without running anything.
  Results live in memory only: after msgblast restarts, an unknown id is answered
  with `unknownCommand`, which the phone shows as unconfirmed.
- A remote send to an existing conversation switches the Mac's workspace to it, as
  any send does.

## Availability

Each agent has a readiness (`ready`, `readyWillLaunch`, `busy`, `blocked`,
`unavailable`) and typed reasons with user text and where to fix them (Mac, phone,
or nowhere). `readyWillLaunch` means a send will open and activate a Mac app. Codes
include permissions (Full Disk Access, Contacts, Automation, Accessibility, Screen
Recording), signed-out websites and CLIs, unconfigured webhooks, incomplete
requests, queued desktop sends, unroutable Messages chats, and two phase 1
additions: `notConnected` (a Mac app has no saved conversation yet) and
`remoteMessagesOff`.

Computing availability never connects a session, loads a page, refreshes a desktop
binding, launches an app, or prompts. While a phone is connected a loop runs every
5 seconds with the existing prompt-free probes (Accessibility and screen-capture
preflights, a one-byte `chat.db` read, Automation with `ask: false`,
`refreshDesktopInstallation`) and checks CLI account status every 60 seconds for
CLIs that are already connected. Desktop readiness is `lastKnown`: only explicit
Mac paths refresh it.

## Lock, sleep, and keep-awake

A locked Mac is disconnected as a whole: the phone receives one
"Disconnected: your Mac is locked" notice, no data, and every command is refused
with `macLocked`. On unlock the session resumes from the phone's cursor. Lock
state comes from `CGSessionCopyCurrentDictionary` and lock notifications; display
and system sleep from `NSWorkspace` notifications. Keep-awake prevents idle system
sleep only; it does not wake a sleeping Mac, keep the display on, or unlock.

## What never leaves the Mac

Website cookies and WebKit stores, CLI logins, Grok Bot keys, `chat.db` rows other
than projected replies in a conversation's range, Contacts data, macOS
permissions, and the Mac's composer drafts. Sign-in, permissions, and keys are set
up on the Mac; the phone shows the blocked state and where to fix it.

## Demo behavior

The blue Demo app serves the same protocol with simulated agents, Messages, and
replies. With remote control on it serves only in-memory clients and opens no port.
**Listen on the network (Demo)** or the `--remote-listen` launch argument opens a
real listener for evidence and phase 2 UX work; it is never saved.

## Command-line client

`scripts/remote_client` is a SwiftPM executable that links the app's protocol
module (`Sources/msgblastRemoteProtocol` is a symlink to `msgblast/RemoteProtocol`).

```sh
cd scripts/remote_client && swift build
.build/debug/msgblast-remote pair '<msgblast://pair?offer=…>' --once
.build/debug/msgblast-remote watch
.build/debug/msgblast-remote send --to claude,messages:<uuid> "Compare two approaches"
.build/debug/msgblast-remote send --to codexCLI --conversation <uuid> --private "Only you"
```

It keeps its device key and cursor in `~/Library/Application Support/msgblast-remote-client/state.json` (file 0600, folder 0700); `--state <path>` overrides it.
Use it only against a Demo Mac or a Mac whose owner authorized real sends.

## Source map

| Area | Source |
| --- | --- |
| Wire protocol (macOS 15, iOS 26) | `msgblast/RemoteProtocol/` (`msgblastRemoteProtocol.framework`) |
| Identity, pairing, settings, keep-awake, lock state | `msgblast/Core/Remote/RemoteIdentity.swift`, `RemotePairing.swift`, `RemoteSettings.swift`, `KeepAwake.swift`, `MacPowerState.swift` |
| Availability | `msgblast/Core/Remote/AvailabilityModel.swift` |
| Projection and journal | `msgblast/Core/Remote/RemoteProjection.swift` |
| Commands | `msgblast/Core/Remote/RemoteCommandExecutor.swift`, `msgblast/Remote/AppRemoteHost.swift`, `msgblast/App/SharedSend.swift` |
| Sessions, listener | `msgblast/Core/Remote/RemoteServer.swift`, `RemoteListener.swift` |
| Service and settings UI | `msgblast/Remote/RemoteService.swift`, `RemoteAppSignals.swift`, `msgblast/Windows/RemoteSettingsView.swift` |

## Limits (phase 1)

- No phone app yet; the command-line client is the only client.
- Reachability from a phone on cellular over Tailscale, the lock-screen send
  matrix, and display-sleep behavior are not yet measured; see the
  [phase 0 spike](plans/2026-10-26-ios-controller-spike.md).
- Command results are remembered only while msgblast runs.
- IPv4 addresses only; Tailscale MagicDNS names are not in the QR code.
- The optional Tailscale LocalAPI `whois` check is not implemented.
