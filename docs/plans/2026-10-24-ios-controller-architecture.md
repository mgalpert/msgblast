# iOS controller for msgblast: architecture discussion

Status: **draft for discussion, not approved.** Written against revision
`b8bf6143f4875a1b6de9372335bf77dae8035f75` (main after PR #74). The source
survey this is based on is in [the companion survey](2026-10-24-ios-controller-mac-survey.md);
its line numbers refer to that revision. Open questions are at the end; nothing
here is a build instruction until they are answered.

Decisions recorded so far (owner, 2026-10-24):

- **Audience:** public. The iOS app ships in the same open-source repo and is
  distributed through TestFlight links. Nothing may assume a single power user.
- **Use case:** out and about, encrypted sync with the Mac at home or work.
- **Feature parity:** every messaging feature on the Mac is offered on iOS.
  Account and permission setup that is physically Mac-bound (website sign-in in
  the Mac's WebKit store, CLI login, Full Disk Access, Automation, Contacts
  permission, Grok Bot key entry) stays on the Mac; the phone shows the blocked
  state and what to do on the Mac.
- **Push notifications:** offered as an opt-in in v2. v1 must not paint us into
  a corner: the route chosen for v1 decides how cheap v2 push is (§3).
- **Route for v1 (2026-10-25):** Tailscale direct, with LAN direct on the same
  listener. A Cloudflare-hosted encrypted gateway is the v2 route for the public.
  The app-layer encryption in §2.1 is built in v1 so the gateway is only a new
  route, not a protocol change.
- **Pairing in v1:** exactly one phone per Mac and one Mac per phone. Pairing a
  second device replaces the first after confirmation on the Mac. Multi-device
  is v2.
- **UX first:** v1 exists to find the right phone UX before hardening. The blue
  Demo build simulates installed native apps, permissions, and replies without
  touching real apps, so the iOS UX can be iterated against a Demo Mac without
  live sends. Live Dev checks come after the UX settles.
- **Base revision moved:** this plan now targets 0.10.0
  (`7676362e87`, merge of PR #81). 0.10.0 adds native Mac app conversations,
  which makes per-agent availability (§2.7) a first-class part of the protocol.

## 1. What the Mac app actually is (and why the phone cannot replace it)

Every connection type has a hard dependency on the Mac process:

| Connection | Mac-only dependency | Could iOS do it natively? |
| --- | --- | --- |
| Messages | Read-only `~/Library/Messages/chat.db` via SQLite; sends via `osascript` Apple Events; Full Disk Access + Automation permissions | No. iOS has no programmatic iMessage send or history read. The user already has those chats in the iPhone Messages app. |
| Websites (Muse, ChatGPT, Claude, Grok, Dots, rabbit OS3, Hark) | `WKWebView` per agent with the Mac's own `WKWebsiteDataStore` sign-in; replies are scraped from the live DOM on a 1 s poll and exist only in memory until the conversation is ended | Only by re-signing-in on the phone with separate cookies, which defeats "same conversation" and violates the app's rule that credentials never leave their store. |
| CLI conversations (Codex, Claude Code) | `Process` spawning the installed CLI, resumable session ids, 3-minute runs, working directories under the support folder | No. |
| Grok Bot | Loopback `NWListener` + bundled cloudflared quick tunnel; webhook key in a Secure Enclave vault | Technically a phone could call the webhook, but the callback tunnel and vault are Mac-bound. |
| Native Mac apps (0.10.0: ChatGPT, Dots, Claude, Muse, Wabi, Grok Bot app; Gemini deferred) | Bundled CuaDriver in embedded mode under msgblast's Accessibility and Screen Recording grants; the target app must be installed, signed in, and have one main window; replies are read from the accessibility tree and must stay stable for 3 s; native requests run strictly in sequence | No. These are the Mac's own desktop apps and permissions. |

Consequence: **the Mac is the single executor and the single source of truth.**
"Sync" means the Mac projects a view of its state to the phone and the phone
submits commands. No credential, cookie store, `chat.db` row, or vault plaintext
ever travels. This matches the existing boundaries in `AGENTS.md` (websites,
CLIs, reports, and Grok Bot stay distinct; a send call is submission evidence,
not delivery; uncertain sends are never auto-retried).

Other facts that shape the design (all verified in source):

- The app is **not sandboxed** and already runs a loopback HTTP listener for
  Grok Bot, so a second listener needs no new entitlement.
- `AppModel`, `WebAgents`, and every `WebAgentSession` are `@MainActor`
  `ObservableObject`s with `@Published` state. An in-process bridge can observe
  everything, including website assistant text that never touches disk.
- There is no URL scheme, App Intent, XPC, CloudKit, Bonjour, or inbound Apple
  Events surface today. A file-tailing approach would miss web replies and
  Messages replies entirely.
- The "send to everyone" orchestration is a private method on a SwiftUI view
  (`WebServicesView.send`), not on `AppModel`. Errors surface as a modal alert
  bound to `model.error`. Closing an active conversation is an `NSAlert` sheet.
- `msgblastCore` is macOS 15 only. `Models.swift`, `Routing.swift`,
  `WebServices.swift` (state types), and `WebProvider.swift` are pure Foundation;
  `WebAgentSession` pulls in AppKit and WebKit, so the Core target cannot be
  compiled for iOS as a unit.

## 2. Proposed shape

```
iPhone (controller)                         Mac (executor, source of truth)
┌──────────────────────────┐   TLS 1.3     ┌──────────────────────────────────┐
│ SwiftUI messenger UI     │  pinned cert  │ RemoteService (new)              │
│ Local cache (SQLite)     │◄────────────►│  ├ Listener (Network.framework)   │
│ Pairing (QR, Keychain)   │  framed JSON  │  ├ Pairing + device registry      │
│ Command queue (none when │  over TCP     │  ├ Projection + change journal    │
│   offline; no retries)   │               │  └ Command executor → AppModel    │
└──────────────────────────┘               │ AppModel / WebAgents / sessions   │
          ▲                                 └──────────────────────────────────┘
          │ route: Tailscale (anywhere) or LAN (Bonjour); same protocol either way
```

Three deliverables:

1. **`msgblastRemoteProtocol`** — a new SwiftPM target, pure Foundation,
   platforms macOS 15 + iOS. Wire DTOs, framing, codec, protocol version, unit
   tests. Deliberately *not* the persisted `Models.swift` types: the wire format
   is a projection and must evolve independently of `state.json` migrations.
2. **`RemoteService` in the Mac app** (`msgblast/Remote/`, registered through
   `scripts/generate_project.py`). Listener, pairing UI in Settings, projection,
   command executor, and the headless hardening of existing paths listed in §5.
3. **iOS app target** (`msgblastMobile/`), SwiftUI, with a local cache.

### 2.1 Transport and security

Security must not depend on the route. Encryption and authentication live in
the app layer so the same frames are safe over LAN, Tailscale, or a relay.

- **Identity and encryption.** The Mac generates a long-lived P-256 identity
  once (reuse the Secure Enclave pattern from `GrokBotCredentialVault`); the
  phone generates its own in the iOS Keychain. Pairing exchanges public keys;
  each session does an ephemeral key agreement (HPKE / X25519 → ChaChaPoly via
  CryptoKit) authenticated by those pair keys. Every frame is encrypted and
  authenticated end to end. On direct routes the Mac additionally serves TLS
  from the same identity with the SPKI pinned on the phone. A relay, if used,
  carries ciphertext only. No CA, no hostnames to validate, works on any route.
- **Pairing.** Settings → Remote shows a QR code: candidate endpoints (tailnet
  MagicDNS name, 100.x address, LAN addresses), port, SPKI hash, one-time code
  valid for two minutes. The phone connects, answers an HMAC challenge with the
  code, and receives a device token (stored in the iOS Keychain). The Mac keeps
  only the token hash, device name, granted scopes, created/last-seen times.
  Settings lists paired devices with **Revoke**.
- **Bind policy.** Default: bind only to the Tailscale interface when one is
  present (the `100.64.0.0/10` utun), otherwise LAN with Bonjour
  `_msgblast._tcp` for discovery. Explicit **Off** state. Never bind loopback
  (that port belongs to Grok Bot callbacks) and never expose via Funnel.
- **Scopes per device.** `read`, `send.web`, `send.cli`, `send.bot`,
  `send.messages`, `attachments`, `manage` (end conversations, create). Suggest
  `send.messages` **off by default**: a real iMessage send is irreversible and
  the phone already has Messages natively.
- **Optional Tailscale identity check.** If the standalone Tailscale variant is
  installed, the Mac can ask the LocalAPI `whois` for the peer's tailnet user
  and refuse connections from other users even before pairing. Nice-to-have,
  variant-dependent, not a substitute for pairing.

### 2.2 Protocol

Framed JSON messages over the TLS stream (length-prefixed, via
`NWProtocolFramer`), symmetric on both ends. Message kinds:

- `hello {protocolVersion, deviceToken, sinceSeq}` → `snapshot` or `events`.
- `event {seq, kind, payload}` pushed by the Mac. Kinds: agent upsert/remove,
  conversation upsert, turn upsert (text, role, agent, attempt status),
  attempt status change, Mac status (busy, sign-in required per agent,
  database availability, awake/asleep).
- `command {clientCommandID, kind, payload}` → `commandResult {accepted |
  rejected(reason) | applied}`, followed by ordinary events for outcomes.
- `ping`/`pong` with the Mac's current seq so the phone can detect gaps.

Why not HTTP + WebSocket: the Mac has no HTTP server library and the existing
loopback receiver is a minimal hand-written parser. A framed stream gives
server push for free and needs no dependency. Cost: no `curl` debugging, so
phase 1 ships a small Swift CLI client under `scripts/` for tests and evidence.
If an HTTP shape is preferred, FlyingFox (pure Swift, HTTP + WebSocket) is the
lightest dependency and would need a third-party notice entry.

### 2.3 Projection and change journal

A `RemoteProjection` object on the main actor subscribes to
`AppModel.objectWillChange` and `WebAgents.objectWillChange` (which already
re-publishes every session), debounces ~100 ms, builds a normalized projection,
diffs it against the previous one by stable id, assigns a monotonic `seq`, and
pushes events. A bounded journal (say the last 5,000 events) supports
`sinceSeq` resume; older cursors get a full snapshot.

Stable ids already exist: `Agent.id`, `WebAgentID.id`, `Comparison.id`,
`FollowUp.id`, Messages `ROWID`/`guid`, CLI/Bot `WebPageMessage.id`. Website
turns are the exception: provider ids survive reloads but synthetic `node-N`
ids do not, so the projection assigns its own turn ids by `(agent, conversation,
ordinal, text hash)` and treats a re-render as an update, not a new turn.

Diffing on every publish is cheap at this state size (tens of conversations,
hundreds of turns) and avoids instrumenting every mutation site. It is the one
place that reads `session.snapshot.messages`, so phones see website replies
live even though the Mac never persists them until **End**.

### 2.4 Commands map onto existing paths, never around them

| Phone action | Mac path | Guard preserved |
| --- | --- | --- |
| New blast to selected agents | `prepareWebComparison` + `WebAgents.prepareComparison` + `AgentBroadcast.send` (today only reachable from `WebServicesView.send`; lift into `AppModel`) | sign-in check, `busy`, Contacts permission, Hark exclusion |
| Shared follow-up | same broadcast with existing comparison | duplicate-text and unresolved-attempt blocks |
| Private message to one agent | `WebAgentSession.send(text, comparisonID:)` or `followUp(only:)` | anchor/next-anchor rules |
| End conversation | `endConversation` | `canArchiveComparison` (page must be loaded) |
| Stop waiting / acknowledge | `acknowledgeIncompleteRequest`, `cancelNativeRequest` | |
| Attach from phone | chunked upload → `LocalStore.stage` → `addAttachments` | shared composer forbids attachments when web agents are selected |

Idempotency: the Mac records `clientCommandID`s; a replayed command returns the
original result. The phone **never** retries a send on its own; a disconnect
mid-command shows "unconfirmed, check on Mac", exactly like the Mac's own
`.uncertain` state.

### 2.5 iOS app

Native messenger feel, not a remote desktop:

- **Inbox:** one row per conversation (comparison) with stacked agent avatars,
  last reply preview, unresolved-attempt badge. Plus 1:1 rows for each agent's
  private pane.
- **Conversation:** your shared turns on the right; each agent's replies as
  grouped bubbles with the agent avatar on the left; a segmented filter
  **All · Claude · ChatGPT · …** that collapses to a single agent's private
  thread. Status chips under your turn: *Sending on Mac → Submitted → Replied*
  or *Uncertain*, per agent.
- **Compose bar:** recipient chips. Chips = all members → shared send; one chip
  → private send. Drafts stay on the phone (per device) unless we decide to
  sync them (question 7).
- **New blast:** agent grid mirroring the Mac's visible grid, including named
  copies and Grok Bots; agents needing sign-in are shown dimmed with "Sign in
  on Mac".
- **Mac status banner:** connected / reconnecting / Mac asleep or app not
  running, with the last known seq so stale content is labelled.
- **Cache:** SQLite (GRDB or SwiftData) holding the projection and last seq;
  full offline read. No offline send queue.

### 2.6 Availability on the Mac

The Mac must be running the app, awake, and (for websites) have the WebKit
pages able to pass the page script's visibility checks. Proposed:

- Hold an `IOPMAssertion` (prevent idle sleep) while a remote command is in
  flight, and optionally while any paired device is connected (user setting).
- **Spike before committing:** does `getClientRects()` return non-empty rects
  for a `WKWebView` that is not in any window, or when the display is asleep?
  The session already creates views at 800×600 without a window, so website
  sends from the phone may work with the Mac window hidden, but the source does
  not prove it. If rects are empty, the Mac needs an off-screen host window.
- Wake-from-sleep over Tailscale is not solvable from the phone alone (Wake on
  LAN needs a LAN peer). Document "Mac must be awake" or rely on an always-on
  desktop.

### 2.7 Agent availability model (required by 0.10.0)

The phone must answer "can this agent take a message right now, and if not,
why, and where do I fix it?" for every agent. Today the Mac cannot answer that
with one value. The [availability survey](2026-10-24-ios-controller-availability-survey.md)
found, with line references:

- Readiness is `snapshot.ready` (a `Bool`) plus `snapshot.reason` (a `String`)
  per session, and only after something called `refresh`. Desktop, CLI, and
  webhook sessions never poll; the 2 s timer only re-reads Messages.
- `canSubmitNativePrompt` is true for a desktop app that is installed with a
  saved binding but **not running**, because a send will launch it. The
  composer therefore says "ready" when a send will actually open and activate
  an app on the Mac.
- Permission state (Full Disk Access, Contacts, Automation, Accessibility,
  Screen Recording) lives on `AppPermissions` and `CuaPermissionsController`
  and is composed only inside the onboarding controller. `sendNative` never
  consults it; it finds out when the accessibility read or the driver fails.
- Installation and running state are read only on view appear, app activation,
  or an explicit refresh. Quitting ChatGPT is invisible until then.
- There is no desktop "signed out" signal. Logged-out apps collapse into
  "keep one main window open" or a parse error. `checkSignIn` returns nil for
  every native provider, so the shared-send sign-in gate never blocks a desktop app.
- One unresolved desktop attempt blocks every later desktop send for that
  provider across comparisons until someone acknowledges it. All desktop
  providers share one serial execution group; ChatGPT and Dots additionally
  share one process and one `occupied` actor.
- Seventeen `WebProvider` cases include website, Mac app, CLI, and webhook
  forms of the same product (ChatGPT ×3, Claude ×3, Muse ×2, Dots ×2, Grok Bot
  ×2) with separate state files and histories. Nothing records which form the
  user prefers.
- Nothing checks whether the Mac is awake, unlocked, or has its display on.

**Design.** A new `AgentAvailability` DTO in the protocol package, computed on
the Mac by an `AvailabilityModel` (main actor) from existing signals. It is
strictly side-effect free: it never launches an app, clicks inside a target
app, or triggers a permission prompt. In particular it must not call
`refreshDesktop`, which can click **New side chat** in Muse, **New chat** in
Wabi, or sidebar controls in ChatGPT and Dots.

```
AgentAvailability
  agentID, product (chatgpt | claude | muse | …), form (website | macApp | cli | webhookBot | messages)
  displayName, avatarRef, visibleInGrid, selectedForSharedSend
  capabilities { sharedSend, privateSend, attachments, namedCopies, endConversation, sharesOneConversation }
  readiness: ready | readyWillLaunch | busy(detail) | blocked([reason]) | unavailable([reason])
  reasons: [ { code, userText, fixOn: mac | phone | none, attemptID? } ]
  observedAt, source: live | lastKnown
```

Reason codes, each traceable to a source signal: `notInstalled`,
`appNotRunning`, `appVersionUnsupported`, `windowMissingOrAmbiguous`,
`dialogOpen`, `signedOut`, `signInUnknown`, `disabled`, `notOfferedInBuild`
(Gemini), `noSharedSends` (Hark), `permissionMissing(fullDiskAccess | contacts |
automation | accessibility | screenRecording)`, `automationNeedsMessagesOpen`,
`driverUnavailable`, `storageFailed`, `incompleteRequestBlocking(attemptID)`,
`sendInFlight`, `queuedBehindDesktopSend`, `cliSignedOut`,
`cliVersionUnsupported`, `webhookNotConfigured`, `tunnelStarting`,
`messagesDatabaseUnavailable`, `conversationUnroutable(status)`, `macLocked`,
`macDisplayAsleep`.

`readyWillLaunch` is a distinct state on purpose: the phone shows "will open
ChatGPT on your Mac" before the send, because the launch activates the app and
steals focus on the Mac.

**Freshness while a phone is connected.** Add a light availability loop that
runs only while a remote client is connected: `refreshDesktopInstallation`
(cheap: `NSRunningApplication` plus LaunchServices, no launch), the prompt-free
permission probes (`AXIsProcessTrusted`, `CGPreflightScreenCaptureAccess`, the
one-byte `chat.db` read, Automation with `ask: false`), CLI account status at
a slower cadence, and lock state. Desktop `desktopReady` stays `lastKnown` with
its timestamp; it is only refreshed by the explicit paths that already exist.

**Lock and sleep state (new, decided 2026-10-26).** Read
`CGSessionCopyCurrentDictionary` for the screen-locked flag and observe
`NSWorkspace` screen sleep notifications. A locked Mac counts as
**disconnected as a whole**: the remote service reports `macLocked` as a Mac
state, the phone shows "Disconnected: your Mac is locked", and no command is
accepted until the Mac is unlocked. There is no per-agent `macLocked` reason
and no attempt to keep a list of which agents might still work while locked.
Keep-awake is requested by the phone on connect (an `IOPMAssertion` held while
a phone is connected and during any send) and can be turned off in the Mac's
Settings → Remote pane.

**Serial desktop sends.** Remote sends to desktop agents enter the same serial
group the shared send uses, and the phone shows `queuedBehindDesktopSend`
instead of a refusal.

**Product grouping.** The phone groups the forms of one product and labels the
form ("ChatGPT · Mac app", "ChatGPT · Web", "Codex CLI"), honoring the Mac's
grid visibility and enabled flags. Histories are never merged across forms.

## 3. Reachability options and tradeoffs (public-app lens)

The phone is on cellular or someone else's Wi-Fi; the Mac is behind a home or
office NAT. Something has to get packets between them. With app-layer
encryption (§2.1) the route only affects reachability, friction, latency,
privacy of *metadata*, and who runs infrastructure.

| Route | Who makes it reachable | User friction | Latency | What a third party can see | Push in v2 | Maintainer cost |
| --- | --- | --- | --- | --- | --- | --- |
| **A. Tailscale direct** | Tailscale's coordination server + DERP relays (WireGuard end to end) | High for the public: install Tailscale on Mac and iPhone, sign up, keep the VPN on; conflicts with any other VPN | Best | Tailscale sees node metadata; DERP sees WireGuard ciphertext when NAT traversal fails | Needs an extra component anyway | None hosted |
| **B. LAN direct** (same listener) | Bonjour on the local network | None | Best | Nothing leaves the LAN | N/A | None |
| **C. CloudKit private database as mailbox** | Apple, tied to the user's Apple ID | None visible: same Apple ID on both devices even pairs automatically | 0.5–3 s per hop, bursty; not chat-smooth | Apple holds record keys unless we encrypt payloads ourselves (then only sizes/timing); data at rest in iCloud | Free: `CKSubscription` silent push | iCloud entitlement per build variant; provisioning profile for the Developer ID Mac app; ad-hoc contributor and CI builds must strip it; CloudKit quotas |
| **D. Own relay** (Cloudflare Worker + Durable Object, WebSocket both ends) | Our relay; both devices connect outbound, no inbound ports | None: pair with QR, it works | ~RTT, true push | Relay sees ciphertext, pair ids, timing, sizes. Never plaintext | Cheap: relay already knows when the phone is offline; add APNs | A hosted service the maintainer runs (the repo already runs the download and feedback Workers); outage means "phone can't reach Mac" |
| E. Hybrid: B + D, with A as an opt-in | Direct when on the same network or tailnet, relay otherwise | None by default; Tailscale users get direct-anywhere | Best available | As D only when relayed | As D | As D |

What this means in plain terms:

- **Tailscale is the best route for you personally and the worst onboarding
  story for the public.** A TestFlight user who has never heard of Tailscale
  has to install two more apps and keep a VPN running before the first message.
  It also does nothing for push notifications, so v2 would add a server anyway.
- **CloudKit is the "no server, no setup" option** and gives push for free,
  but it is a mailbox, not a socket. Replies arrive in noticeable bursts, and
  it ties the whole repo's build pipeline to an iCloud container, which the
  contributor and ad-hoc CI builds have to opt out of. It also puts transcript
  ciphertext in iCloud, which is a posture change from today's local-only app.
- **A relay you run is what every consumer messenger does.** The app-layer
  encryption means the relay is a dumb pipe for ciphertext; it cannot read
  messages, only see that two paired devices are talking. The cost is that
  msgblast gains an always-on hosted dependency, which is new for this project
  (Grok Bot deliberately avoided one), and the maintainer owns its uptime.
- **Hybrid (E) is the recommendation.** One protocol, one encryption layer,
  three routes tried in order: LAN, Tailscale if the Mac has a tailnet address,
  relay. Default users never see the word Tailscale; power users get a direct
  path everywhere; v2 push is an APNs call from the relay with a content-free
  payload. Tailscale alone is the fallback recommendation if a hosted relay is
  unacceptable, accepting the onboarding cost and a separate push component.

### Notifications when a reply lands (v2)

iOS does not let an app keep a socket open in the background for long, so a
backgrounded phone only learns about replies through a push. The push payload
should be content-free ("activity in conversation X"), with the phone fetching
the actual turns over the encrypted channel when opened. With route D or E,
the relay already knows the phone is offline and can call APNs. With A or B
alone, v2 needs a new component (CloudKit silent push or a stateless Worker)
just for the ping. This is why the v1 route decision matters for v2.

## 4. Repository and packaging

- Same repo, new targets added in `scripts/generate_project.py`
  (`msgblastRemoteProtocol` package target, `msgblastMobile` app target,
  `msgblastMobileTests`), plus `Package.swift` platforms `[.macOS("15.0"),
  .iOS("18.0")]` for the protocol target only.
- Dev / Demo variants: the listener advertises the variant and the phone shows
  it; Demo never performs real sends, which makes it the PR-evidence vehicle.
- `validate.yml` gains an iOS simulator test job; PR evidence gains iOS
  simulator screenshots and video.
- Distribution of the phone app: TestFlight through App Store Connect (the
  Developer ID program covers it) or direct Xcode install for a personal
  device. Public distribution is a later maintainer decision.

## 5. Mac-side changes required regardless of transport

These fix the headless gaps the survey found and are good hygiene on their own:

1. Lift shared-send orchestration from `WebServicesView.send` into `AppModel`
   (or a Core `BlastCoordinator`) so the UI and the remote executor call one path.
2. Route errors from remote-originated commands to the command result instead
   of `model.error` (which is bound to a modal alert on the main window).
3. Expose sign-in-required, `busy`, `databaseAvailable`, and per-session
   `isSending` as projection state so the phone can disable actions up front.
4. Allow `endConversation` from remote only when `canArchiveComparison` is
   true; otherwise reject with "open the chat on the Mac first".
5. Add `IOPMAssertion` handling and the off-window WebKit spike result.
6. Persist nothing new about transcripts: the projection is derived state.
   The only new persisted data is the device registry and the Mac identity.

## 6. Phases for v1 (Tailscale + LAN, one pair, UX first)

0. **Spike on the Mac (days, throwaway code allowed):**
   - TLS `NWListener` bound to the Tailscale utun and LAN, pairing handshake,
     reachability from an iPhone on cellular over Tailscale.
   - Off-window `WKWebView` readiness (does `getClientRects()` report visible
     editors with no window / hidden app / display asleep?).
   - Lock-screen matrix: with the Mac locked, trigger one send per connection
     type from a CLI client and record which succeed. Desktop apps are expected
     to fail; the question is whether websites, CLIs, and the webhook work.
   - Availability loop cost on a real profile.

   **Status (2026-10-26):** done except the human-only parts. Results in
   [the spike record](2026-10-26-ios-controller-spike.md): TLS 1.3 listeners on
   both Tailscale utuns and the LAN with a pinned client work (same-port binds need
   `allowLocalEndpointReuse`; Bonjour follows `requiredInterface`); an unwindowed
   `WKWebView` passes the visibility test; a probe pass costs about 45 ms. The
   cellular reachability check and the lock-screen matrix are written as a human
   procedure and not yet run.
1. **Mac remote service:** protocol package (DTOs, `AgentAvailability`,
   events, commands, framing, tests), `AvailabilityModel`, projection and
   journal, listener with single-device pairing and revoke, Settings → Remote
   pane (QR, paired phone, bind policy, keep-awake setting), headless hardening
   (§5), CLI test client under `scripts/`, Demo fixtures that simulate every
   agent form. Demo evidence for the PR.

   **Status (2026-10-26):** landed on `ios-controller` as atomic commits; see
   [Remote control](../remote-control.md). Protocol framework
   `msgblast/RemoteProtocol/` (macOS 15 and iOS 26) with `RemoteClientDriver` for
   phone code; Mac identity, pairing, settings, availability, projection and
   journal, executor, server and listener in `msgblast/Core/Remote/`; AppModel
   adapters and `RemoteService` in `msgblast/Remote/`; Settings → Remote;
   `scripts/remote_client` and `scripts/test_remote_client.sh`. §5 items 1–5 are
   done (`AppModel.sendShared`/`sendDirect`, `RemoteErrorCapture`). Differences
   from this plan: the TLS and handshake identity is a software P-256 key wrapped
   by a Secure Enclave key, because the Enclave cannot hold a TLS server key;
   device scopes reduce to the single "Send iMessages from the phone" setting;
   website sends that must navigate a page return `preparedNotSent` and need a
   second explicit send, as from the Mac composer. Not yet done: Demo PR video
   evidence, live Dev validation (phase 3).
2. **iOS app, UX iteration against the Demo Mac:** pairing, inbox,
   conversation, availability-aware agent grid, shared and private sends,
   attempt status chips, end and acknowledge, attachments. Iterate on the
   messenger feel here before any live sends. Internal TestFlight.
3. **Live Dev validation over Tailscale:** real agents, lock and sleep
   behavior, focus-steal feedback, long desktop sends. Fix what the UX
   iteration missed.
4. **v2 (separate plan):** Cloudflare encrypted gateway as the public route,
   opt-in push notifications, multi-device pairing and a Mac switcher.

## 7. Feature parity map (owner asked for every Mac feature on iOS)

| Mac feature | On iOS | How |
| --- | --- | --- |
| Shared blast, follow-ups, private messages to web / CLI / Bot | Yes | Commands onto the lifted `AppModel` broadcast path |
| iMessage sends to Messages agents | Yes | Same `submit` / `followUp` path; still a per-device scope so a lost phone cannot text your contacts |
| Comparison view with all agents' replies, incl. Messages replies | Yes | Projection reads `AppModel.messages` and live web snapshots |
| Attachments (files, images) | Yes | Chunked upload → `LocalStore.stage`; same web-agent attachment limits apply |
| New blast with agent grid, named copies, multiple Grok Bots | Yes | Grid projection mirrors `AgentGridLayout` |
| End / keep active, acknowledge uncertain, stop waiting | Yes | Existing calls; End requires the page loaded on the Mac |
| Hide pane / remove from view | Yes, per device | Local UI state, like hidden panes on the Mac |
| Comparison reports (Hermes / restricted adapters) | Yes, trigger and read | `PersonalAgentController` commands; runs on the Mac |
| Chat image sharing | Yes, native | Rendered on the phone from the projection, not ScreenCaptureKit |
| Enable / disable CLIs, rename / hide agents, Discover catalog adds | Yes | Settings-style commands with the `manage` scope; Contacts writes stay guarded |
| Website sign-in, browser login import, CLI login, Grok Bot key entry, macOS permissions, onboarding, updates | **Mac only** | Physically bound to the Mac's stores and TCC. Phone shows the blocked state with instructions |
| New Blast global shortcut, window layout | N/A | Desktop-only concepts |

## 8. Open questions

Answered 2026-10-24: audience is public via TestFlight in this repo; full
messaging-feature parity; push is a v2 opt-in.

Answered 2026-10-25: v1 route is Tailscale plus LAN with a Cloudflare gateway
in v2; one phone per Mac in v1; UX first against the Demo build.

Answered 2026-10-26 (owner):

1. **Lock screen:** a locked Mac is treated as disconnected. The phone shows
   "Disconnected: your Mac is locked". No remote unlock, ever.
2. **Keep awake:** the phone turns it on when it connects; the Mac stays awake
   while a phone is connected and during sends; a Mac Settings toggle turns
   it off.
3. **Drafts:** per device.
4. **Minimum iOS version:** iOS 26.
5. **Tailscale variant:** both the Mac App Store and the standalone apps must
   work. The standalone LocalAPI `whois` check is an optional extra, never a
   requirement.
6. **Accounts:** none; pairing is a device pair. Revisit with the v2 gateway.

Build decision 2026-10-26: Claude Opus 5.5 implements the plan under this
session's supervision, as atomic commits on the `ios-controller` branch cut
from 0.10.0 (`7676362e87`). Phases are reviewed in order; no push or PR
without the owner's say-so.

No questions are open. New ones are added here as the work raises them.
