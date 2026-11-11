> Source survey produced on 2026-10-24 against revision b8bf6143f4875a1b6de9372335bf77dae8035f75 (0.9.0; the 0.10.0 additions are covered by the availability survey) by a Grok 4.7 subagent and spot-checked by hand. Line numbers refer to that revision only. Companion to [the iOS controller architecture discussion](2026-10-24-ios-controller-architecture.md).

# msgblast Mac app internals (source survey)

Read-only survey of the worktree at the time of reading. Line numbers refer to that tree. Claims are from the cited source. Items marked UNCERTAIN are not settled by the source.

Connection types (docs/architecture.md:60–67): Messages (one-to-one iMessage, read-only `chat.db`, Apple Events submit), Websites (Muse, ChatGPT, Claude, Grok, Dots, rabbit OS3, Hark in WebKit stores), optional CLI conversations (Codex CLI, Claude Code), Grok Bot (webhook + loopback callback via bundled cloudflared).

---

## 1. TARGETS AND SHARED CODE

### Targets

| Target | Kind | Where declared | Notes |
| --- | --- | --- | --- |
| `msgblastCore` | Xcode framework `com.apple.product-type.framework`; SPM `.target` | `scripts/generate_project.py:35,64–65,85`; `Package.swift:11` | Sources: `msgblast/**/*.swift` under `msgblast/Core/`. Links `sqlite3`. SPM dependency: SweetCookieKit. Xcode product id `com.msgblast.msgblastCore`. Embedded in the app (`generate_project.py:82–83`). |
| `msgblast` | Application | `generate_project.py:35,66–83,85`; `Package.swift:5,12–14` | Every `msgblast/**/*.swift` except `msgblast/Core/`. Info.plist, entitlements, Sparkle. Bundle id build setting `com.msgblast.mac` (`generate_project.py:67`). Deployment `15.0`. Hardened runtime YES. |
| `msgblastTests` | Unit-test bundle | `generate_project.py:35,45–46,85`; `Package.swift:15` | SPM depends only on `msgblastCore`. Xcode also compiles `msgblast/Permissions/MessagesAccessGuide.swift` into the test target (`generate_project.py:46`). |
| `msgblastUITests` | UI-test bundle | `generate_project.py:35,61–63,85` | Not in `Package.swift`. Depends on the `msgblast` app target. `TEST_TARGET_NAME = msgblast`. |

Shared scheme `msgblast.xcscheme` builds the app and both test bundles (`generate_project.py:91–94`). `Package.swift` is not the full app packaging recipe (`docs/architecture.md:174–177`).

### Platforms

`Package.swift:4`: `platforms: [.macOS("15.0")]`. No iOS platform. Xcode project `SDKROOT = macosx`, `MACOSX_DEPLOYMENT_TARGET = 15.0` (`generate_project.py:60,87`). `Info.plist:19–20`: `LSMinimumSystemVersion` `15.0`.

### Core imports that are macOS-only

`import AppKit` is the only import that does not exist on iOS:

| File | Line |
| --- | --- |
| `msgblast/Core/AttachmentImport.swift` | 1 |
| `msgblast/Core/AttachmentTextView.swift` | 1 |
| `msgblast/Core/PermissionHandoff.swift` | 1 |
| `msgblast/Core/WebAgentSession.swift` | 1 |

`WebAgentSession.swift:4` also `import WebKit`. The WebKit module exists on iOS; this file is still macOS-only because of AppKit (`NSRect` at line 28, `NSImage` / `NSBitmapImageRep` at 855–867).

These imports exist on iOS as well (not listed as macOS-only imports). The files still depend on macOS behavior called out in the next table: `SQLite3` (`MessagesDatabase.swift:2`, `BrowserLoginImporter.swift:2`), `Darwin` (`GrokBotCredentialVault.swift:5`, `GrokBotTunnel.swift:2`), `Network` (`GrokBotCallbackReceiver.swift:2`), `Security` + `LocalAuthentication` (`GrokBotCredentialVault.swift:3–4`, `GrokBotService.swift:3–4`), `UniformTypeIdentifiers` (`Attachments.swift:2`), `Combine` (`WebAgents.swift:1`, `WebAgentSession.swift:2`), `CryptoKit` (several files).

`Process` is not a separate import. It is used from Foundation and is unavailable on iOS:

- `msgblast/Core/LocalPersonalAgent.swift:338` (`Process()`), plus `kill` / `getpgrp` / `getpgid` at 350–356.
- `msgblast/Core/GrokBotTunnel.swift:28` (`Process()`), `kill` at 96.

No Core file imports OSAKit, Carbon, Contacts, CloudKit, or XPC. AppleScript text is generated as a `String` in `MessagesSendScript.swift` (Foundation only). The `osascript` process lives in the app target: `msgblast/Messages/MessageSender.swift:38–40`.

### Pure Foundation / Codable vs macOS-bound Core files

Could compile as Foundation (plus CryptoKit / Combine / UniformTypeIdentifiers where noted). They do not import AppKit, WebKit, SQLite, Darwin, Network, or Security, and they do not construct `Process`.

| File | Imports | Role |
| --- | --- | --- |
| `Models.swift` | Foundation | Codable app state. Uses `NSDataDetector` (`Models.swift:105`), which exists on iOS. |
| `Routing.swift` | Foundation | Chat resolution, comparison row range, recipient uniqueness. |
| `WebProvider.swift` | Foundation | Provider enum + `WebAgentID`. |
| `WebServices.swift` | Foundation, CryptoKit | Session Codable state, migration, broadcast helper. |
| `WebAgents.swift` | Combine, Foundation | Registry. Instantiates `WebAgentSession`, so the type graph is not iOS-clean. |
| `WebPageScript.swift`, `MusePageScript.swift`, `MessagesSendScript.swift` | Foundation | JavaScript / AppleScript source strings. |
| `Onboarding.swift`, `AgentGrid.swift`, `DiscoverCatalog.swift` | Foundation | Codable onboarding, grid, catalog. |
| `Attachments.swift` | Foundation, UniformTypeIdentifiers | Attachment + outgoing payload. `(path as NSString).expandingTildeInPath` (`Attachments.swift:13`). |
| `ComparisonSummary.swift`, `BusinessMessagePayload.swift` | Foundation, CryptoKit | Reports; business payload decode. `BusinessMessagePayload` is not `Codable`. |
| `Telemetry.swift`, `DiagnosticReport.swift`, `FeedbackSubmission.swift` | Foundation | Telemetry + feedback models. |
| `BusinessChoice.swift` | Foundation | Choice attempt Codable model. |
| `InstallationLocation.swift`, `UpdateConfiguration.swift`, `UpdateTermination.swift`, `ReleaseHistory.swift`, `LocalAgentDetection.swift` | Foundation | Paths, updates, local-runtime detection scripts. `LocalAgentDetection` does not launch a process (`LocalAgentDetection.swift:24`). |

macOS-bound:

| File | Why |
| --- | --- |
| `WebAgentSession.swift` | AppKit + WebKit + `Process`-free but owns CLI/Grok calls and `WKWebView`. |
| `AttachmentImport.swift`, `AttachmentTextView.swift`, `PermissionHandoff.swift` | AppKit. |
| `MessagesDatabase.swift` | `SQLite3`, read-only `~/Library/Messages/chat.db`. |
| `BrowserLoginImporter.swift` | `SQLite3` Chrome/Safari cookie snapshot. |
| `LocalPersonalAgent.swift` | `Process`, process-group signals, CLI argv. |
| `GrokBotTunnel.swift` | `Process` + `Darwin.kill` of bundled cloudflared. |
| `GrokBotCallbackReceiver.swift` | `NWListener` loopback HTTP. |
| `GrokBotCredentialVault.swift` | Secure Enclave, POSIX `open`/`fstat`, Darwin. |
| `GrokBotService.swift` | Keychain (`SecItem*`, `SecTaskCreateFromSelf`), `LAContext.interactionNotAllowed`. |

---

## 2. STATE MODEL

Root persisted object is `AppState` (`Models.swift:283–299`). `AppModel` holds it in memory as `@Published var state` plus non-persisted `chats` and `messages` (`AppModel.swift:7–9`). Website/CLI/Bot session state is a separate `WebWorkspaceState` per provider file (`WebServices.swift:55–79`), not a field of `AppState`.

`Message`, `MessageReaction`, `MessageDelivery`, and `BusinessMessagePayload` are **not** `Codable`. Live Messages transcripts are not in `state.json`.

### Top-level Codable types (stored properties)

**`AppState`** (`Models.swift:283–299`): `version: Int` (default 1), `agents: [Agent]`, `comparisons: [Comparison]`, `draft: String`, `workspaceDrafts: [String: String]?`, `businessChoiceAttempts: [String: BusinessChoiceAttempt]?`, `attachmentsDraft: [MessageAttachment]?`, `selection: Set<UUID>`, `frames: [String: SavedFrame]`, `windowStyle: ComparisonWindowStyle?`, `personalAgentProvider: String?`, `onboarding: OnboardingState?`, `sharingConsent: SharingConsent?`, `agentGrid: AgentGridLayout?`.

**`Agent`** (`Models.swift:52–59`): `id: UUID` (default `UUID()`), `destination: MessagesDestination?`, `contactID: String?`, `name: String`, `handles: [String]`, `avatar: Data?`, `colorIndex: Int`.

**`MessagesDestination`** (`Models.swift:39–43`): `chatID: String`, `handle: String`, `service: String`, `businessConversation: Bool`.

**`Chat`** (`Models.swift:3–9`): `id: String`, `handle: String`, `lastActivity: Int64`, `participantCount: Int`, `service: String`, `displayName: String?`, `businessConversation: Bool?`. This is the Messages chat row, also embedded on `Member`.

**`Comparison`** (`Models.swift:203–226`): `id: UUID` (default `UUID()`), `prompt: String`, `created: Date`, `members: [Member]`, `followUps: [FollowUp]`, `sharedContext: [ConversationContextMessage]?`, `allDraft: String`, `privateDrafts: [String: String]`, `attachments: [MessageAttachment]?`, `allAttachmentsDraft: [MessageAttachment]?`, `privateAttachmentDrafts: [String: [MessageAttachment]]?`, `recipientSelection: ConversationRecipients?`, `endedAt: Date?`, `endMessageRows: [String: Int64]?`, `endedWebHistory: [String: [WebPageMessage]]?`, `summary: ComparisonSummary?`, `webProviders: [WebProvider]?`, `webAgentIDs: [WebAgentID]?`, `webProviderIdentityVersion: Int?`.

**`Member`** (`Models.swift:137–147`): `agentID: UUID`, `name: String`, `chat: Chat`, `submission: Submission`, `anchor: Anchor?`, `error: String?`, `baseline: Int64?`, `attemptedAt: Date?`, `payload: OutgoingPayload?`. `id` is computed as `agentID` (`Models.swift:138`), not stored separately.

**`FollowUp`** (`Models.swift:154–162`): `id: UUID`, `text: String`, `sharedWithAll: Bool?`, `memberIDs: [UUID]`, `states: [String: Submission]` (keys are member UUID strings), `errors: [String: String]`, `created: Date`, `payloads: [String: OutgoingPayload]?`.

**`ConversationRecipients`** (`Models.swift:172–174`): `selectedConversation: UUID?`, `excluded: Set<UUID>`. `nil` selection means all members except `excluded` (`Models.swift:186–189`).

**`ConversationContextMessage`** (`Models.swift:192–201`): `followUpID: UUID?`, `text: String`, `attachments: [MessageAttachment]`, `sharedWithAll: Bool?`, `created: Date?`.

**`Anchor`** (`Models.swift:75–77`): `rowID: Int64`, `guid: String`. Outgoing Messages receipt. Not the full message.

**`Submission`** (`Models.swift:120–122`): `ready | sending | submitted | failed | uncertain`. `canRetry` is only `.failed` (123). `.uncertain` must not be auto-resent (`Models.swift:128`, `recoveringInFlight` 318–341).

**`MessageAttachment`** (`Attachments.swift:4–9`): `id: String`, `filename: String`, `path: String`, `mimeType: String?`, `byteCount: Int64?`.

**`OutgoingPart`** (`Attachments.swift:20–28`): `id: UUID`, `text: String?`, `attachment: MessageAttachment?`, `state: Submission`, `baseline: Int64?`, `attemptedAt: Date?`, `anchor: Anchor?`, `error: String?`.

**`OutgoingPayload`** (`Attachments.swift:46–47`): stored `parts: [OutgoingPart]`. `submission` / `anchor` / `error` are computed (53–58).

**`SavedFrame`** (`Models.swift:277`): `x, y, width, height: Double`.

**`ComparisonWindowStyle`** (`Models.swift:280–281`): `connected | separate`.

**`WebAgentID`** (`WebProvider.swift:82–88`): `provider: WebProvider`, `instance: UUID?`. `id` string is `provider.rawValue` or `"\(rawValue):\(uuid)"`. `nil` instance is the original agent and keeps that provider’s file and WebKit store (`WebProvider.swift:80–81`, `docs/architecture.md:74–79`).

**`WebProvider`** raw values (`WebProvider.swift:4`): `muse, chatgpt, claude, grok, codexCLI, claudeCode, dots, grokbot, os3, hark`.

**`WebWorkspaceState`** (`WebServices.swift:55–79`, coding keys 80): `providerIdentityVersion: Int`, `enabled: Bool?`, `dotsURL: URL?`, `savedAvatar: Data?`, `grokBotRememberedConnection: Bool?`, `sessionID: UUID`, `displayName: String?`, `draft: String`, `selected: Bool`, `messageRecipients: Set<UUID>`, `comparisonID: UUID?`, `attempts: [WebSendAttempt]`, `conversationURLs: [String: URL]` (key = comparison UUID string), `webDrafts: [String: String]`, `localConversations: [String: [WebPageMessage]]`, `localSessionIDs: [String: String]`, `localSessionPolicyVersions: [String: Int]`, `localConfiguredSessionIDs: [String: String]`, `localPreviousSessionIDs: [String: [String]]`, `localDrafts: [String: String]`.

**`WebSendAttempt`** (`WebServices.swift:26–42`): `id: UUID`, `created: Date`, `text: String`, `status: WebSendStatus`, `detail: String?`, `messageID: String?`, `comparisonID: UUID?`, `conversationURL: URL?`, `callbackHash: Data?`, `recoveryConversationURL: URL?`, `receiptContext: WebReceiptContext?`, `manualContext: WebReceiptContext?`.

**`WebReceiptContext`** (`WebServices.swift:48–53`, internal): `originalURL: URL`, `baseline: [WebPageMessage]`, `existingPaths: Set<String>`, `candidateURL: URL?`.

**`WebSendStatus`** (`WebServices.swift:4–7`): `preparing, attempting, waiting, observed, notSent, uncertain, dismissed`. Unresolved = attempting/waiting/uncertain. Confirms submission = observed or waiting.

**`WebPageMessage`** (`WebServices.swift:165–168`): `id: String`, `role: String`, `text: String`.

**`WebPageSnapshot`** is `Decodable`, not `Encodable` (`WebServices.swift:174–186`): `url, ready, signedIn, reason, draft, draftAvailable, messages, submissionInterrupted, signedOut`. In-memory page observation only.

**`OnboardingState`** (`Onboarding.swift:69–83`): `connectorStartCompleted: Bool?`, `connector: OnboardingConnector?`, `prerequisitesCompleted: Bool?`, `messagesDiscoveryReviewed: Bool?`, `discoveredMessageAgentIDs: [UUID]?`, `excludedDiscoveredMessageAgentIDs: [UUID]?`, `selected/completed/skipped: Set<OnboardingChoice>`, `messageAgentIDs: [String: UUID]`, `stage: Stage` (`choosing, importing, connecting, feedback, finished`).

**`AgentGridLayout`** (`AgentGrid.swift:26–31`): `visibleIDs: [AgentGridID]`. `AgentGridID` (`AgentGrid.swift:3–8`): `web(WebProvider) | webInstance(WebAgentID) | messages(UUID) | featuredMessages(OnboardingChoice) | runtime(LocalAgentRuntime)`.

**`ComparisonSummary`** (`ComparisonSummary.swift:60–68`): `provider, text, created, fingerprint, responseCount, respondingMemberCount, memberCount, report: ComparisonReport?`. `ComparisonReport` (`4–10`): `overview, bestNextAction, rationale, comparison, uncertainties`.

**`SharingConsent`** (`Telemetry.swift:30–33`): `preferences: SharingPreferences`, `installationID: UUID?`, `cohortStartedAt: Date?`, `revision: UUID`. `SharingPreferences` (`3–8`): five Bools (`agentUsage, messageCounts, activity, reliability, performance`).

**`BusinessChoiceAttempt`** (`BusinessChoice.swift:3–9`): `messageGUID, chatID, optionID, status, detail`. Keyed in `AppState.businessChoiceAttempts` by message GUID (`AppModel.swift:289` field; attempts mutated in `AppModel.recoveringInFlight` at `Models.swift:320–323`).

**`DiscoveredAgent`** (`DiscoverCatalog.swift:9–17`): catalog resource, not user state: `id, name, tagline, categories, website, smsURL, number, icon`.

Copy registry `WebAgentConfiguration` is private (`WebAgents.swift:166–169`): `id: WebAgentID`, `accountID: UUID`. Filename `web-instance-<uuid>.json`.

### In-memory, not Codable

**`Message`** (`Models.swift:92–102`): `id: Int64` (message `ROWID`), `guid: String`, `chatID: String`, `text: String`, `outgoing: Bool`, `replyTo: String?`, `date: Date`, `reactions: [MessageReaction]`, `attachments: [MessageAttachment]`, `delivery: MessageDelivery`, `businessPayload: BusinessMessagePayload?`.

**`MessageReaction`** (`Models.swift:80–82`): `id: String` (`"me:<part>"` or `"handle-<handle_id>:<part>"`, `MessagesDatabase.swift:136–144`), `emoji: String`, `outgoing: Bool`.

**`MessageDelivery`** (`Models.swift:89–90`): `unknown | delivered | failed`. From `message.error` / `is_delivered` (`MessagesDatabase.swift:102–109`). Separate from Apple Event acceptance (`Models.swift:88`).

### Identity keys and stability across launches

| Entity | Key | Stable across launches? |
| --- | --- | --- |
| Messages agent | `Agent.id` UUID, written in `state.json` | Yes, once saved. New `Agent()` mints a UUID at init (`Models.swift:53`). Match-on-add uses `contactID` or normalized handle (`AppModel.swift:295–300`), not a new id. |
| Messages agent (Contacts) | `contactID` = `CNContact.identifier` (`ContactSearch.swift:29`) | Yes while that Contacts card exists. Manual add writes a new contact (`ContactSearch.swift:54–67`). |
| Messages chat | `Chat.id` = `chat.guid` (`MessagesDatabase.swift:58–67`) | Yes as long as Messages keeps that chat. Not an app UUID. `messagesScriptingID` may rewrite a Business id to `any;-;` (`Models.swift:17–28`). |
| Chosen destination | `MessagesDestination` exact match of chatID+handle+service+business flag (`Models.swift:48–49`) | Saved on the agent. No fallback to another thread (`Routing.swift:9–13`). |
| Comparison | `Comparison.id` UUID | Yes once inserted and saved (`AppModel.swift:419–420`). |
| Comparison member | `Member.agentID` (same as `Agent.id`) | Yes. Not a separate membership UUID. |
| Follow-up | `FollowUp.id` UUID | Yes. Per-member status key is `member.id.uuidString` (`AppModel.swift:757`). |
| Outgoing Messages message | `Anchor.rowID` = `message.ROWID`, `Anchor.guid` = `message.guid` (`AppModel.swift:650`, `Attachments.swift:72`) | Yes inside that `chat.db`. `ROWID` is the ordering key. |
| Website agent | `WebAgentID` (`provider` + optional `instance` UUID) | Yes. Original agents have `instance == nil` and fixed filenames (`WebProvider.swift:52`). Copies are in `web-agent-instances.json` (`WebAgents.swift:11,37–47`). |
| WebKit login | `WebWorkspaceState.sessionID` UUID passed to `WKWebsiteDataStore(forIdentifier:)` (`WebAgentSession.swift:18,62`) | Yes for that session file. Copies default to sharing the source `sessionID` unless “another account” (`WebAgents.swift:74`). Store bytes are WebKit’s, not in `state.json`. |
| Website conversation | `conversationURLs[comparisonUUID]` canonical HTTPS URL (`WebAgentSession.swift:1009`, `WebProvider.swift:42–49`) | Yes once a receipt pins it. rabbit OS3 and Dots do not get a new URL per comparison (`WebProvider.swift:34–35`, `WebAgentSession.swift:59–65`). |
| Website message | DOM `data-message-id` / provider attribute, else in-page `node-N` WeakMap (`WebPageScript.swift:73–90`) | Provider ids can survive reloads. Synthetic `node-N` ids live in the page JS world and are invalidated when nodes are replaced (`WebPageScript.swift:63–64`). Not a durable database id. |
| CLI session | `localSessionIDs[comparisonUUID]`, resumable only if `localConfiguredSessionIDs` matches and `localSessionPolicyVersions == 1` (`WebServices.swift:129–132`) | Yes in the provider JSON. Codex `thread_id` / Claude `session_id` must be UUIDs (`LocalPersonalAgent.swift:389–390`). |
| CLI/Bot transcript turn | `WebPageMessage.id` minted in Swift (`WebAgentSession.swift:1125`, grok user id = attempt UUID at 1478, assistant id `grokbot-<attemptUUID>` at 1437) | Yes once `localConversations` is saved. |
| Grok callback | `WebSendAttempt.id` UUID; only SHA-256 of the bearer token is stored (`callbackHash`, `WebAgentSession.swift:1471–1472`) | Attempt id is stable. Token itself is not stored. |
| Ended web transcript | `endedWebHistory` keyed by `WebAgentID.id` (`AppModel.swift:586–588`) | Frozen copy in `state.json`. Missing cutoff fields mean still active (`docs/architecture.md:245–246`, `Comparison.endedAt` optional at `Models.swift:217–218`). |

Grid visibility is not membership. `AgentGridLayout.visibleIDs` controls the picker (`AgentGrid.swift:25`). Comparison membership is `members` + `webAgentIDs` (`Comparison.setWebAgents`, `Models.swift:228–231`). Workspace Messages selection is `AppState.selection` (`Models.swift:291`).

---

## 3. STORAGE

### Support folder

`LocalStore` (`LocalStore.swift:5–10`) writes `state.json` under:

`~/Library/Application Support/<folder>/state.json`

`<folder>` from `SupportDirectory.folderName` (`InstallationLocation.swift:20–28`):

| Profile | Folder |
| --- | --- |
| Production (`demo == false`, no override) | `msgblast` |
| Demo | `msgblast-Demo` |
| Override `msgblastSupportDirectory` if it matches `^msgblast-[A-Za-z0-9][A-Za-z0-9-]{0,40}$` | that name (packaged Dev is documented as `msgblast-Dev`, `docs/architecture.md:126–130`) |
| Web preview, bundle `com.msgblast.web-preview` | `MsgBlast-WebPreview` |
| Other web preview | `MsgBlast-WebPreview-<bundle id>` |
| `--isolated-demo` / isolated flags, and not web preview | temp `msgblast-UIFixture-<uuid>` (`LocalStore.swift:7–8`) |

Changing bundle id alone does not change the folder (`InstallationLocation.swift:17–18`).

### `state.json` write

- `save` creates the directory, `JSONEncoder().encode`, `Data.write(options: .atomic)`, then mode `0600` (`LocalStore.swift:21–26`). Atomic replace, yes.
- `load` returns empty `AppState()` if the file is missing (`12–13`). If present, decodes, runs `WebProviderStateMigration.migrateComparisons`, and on identity migration preserves original bytes (`16–18`). Then `AppState.recoveringInFlight()` (`19`, `Models.swift:318–345`): in-flight `.sending` becomes `.uncertain`; business choice `.attempting` becomes `.uncertain`. A decode failure is not replaced with empty state (`AppModel.swift:81`, `docs/architecture.md:157–159`).
- `AppModel.save` refuses to overwrite when the initial load failed (`AppModel.swift:103–104`). Quit then writes `Recovery/<uuid>/drafts-state.json` plus a copy of the original bytes as `original-state.json` (`UpdateTermination.swift:27–51`). Recovery dir mode `0700`, files `0600`.

### Other files under the support folder

| Path | Writer | Mode |
| --- | --- | --- |
| `Attachments/<uuid>/<original filename>` | `LocalStore.stage` (`LocalStore.swift:33–41`, `43–53`) | dir `0700`, file `0600` |
| `web-services.json` | Muse only (`WebProvider.swift:52`) | `0600` via `WebAgentSession.save` (`WebAgentSession.swift:1194–1199`) |
| `web-<rawValue>.json` | Other providers (`WebProvider.swift:52`): `web-chatgpt.json`, `web-claude.json`, `web-grok.json`, `web-codexCLI.json`, `web-claudeCode.json`, `web-dots.json`, `web-grokbot.json`, `web-os3.json`, `web-hark.json` | same |
| `web-instance-<uuid>.json` | Named copies and extra Grok Bots (`WebAgents.swift:169`) | same |
| `web-agent-instances.json` | Copy registry, atomic `0600` (`WebAgents.swift:89–92`) | |
| `<stem>.legacy-provider-state.json` or `…-<sha256>.json` | Migration backup of original bytes (`WebServices.swift:313–326`) | `0600`, atomic. Not overwritten if bytes differ. |
| `local-conversations/chatgpt/<comparisonUUID>/` or `…/claude/…` | CLI cwd. Legacy directory names are `chatgpt` and `claude`, not `codexCLI` / `claudeCode` (`WebProvider.swift:31–33`, `WebAgentSession.swift:1096–1097`) | dir `0700` |
| `.grokbot-credentials/<sha256(context)>.json` | Hardware vault ciphertext (`GrokBotCredentialVault.swift:19–23,55`) | owner-only; symlinks rejected (`73–80`, `docs/grokbot.md:45`) |
| `telemetry-queue.json` | `TelemetryCollector` queue URL (`AppModel.swift:50`) | separate from chat state (`Telemetry.swift:112`) |
| `Recovery/<uuid>/` | Failed-store quit snapshot (`UpdateTermination.swift:29–39`) | |

WebKit data stores are **not** files named in this folder. Non-fixture sessions use `WKWebsiteDataStore(forIdentifier: state.sessionID)` (`WebAgentSession.swift:18`). Fixture sessions use `WKWebsiteDataStore.nonPersistent()`.

Unreferenced staged attachments are deleted only if the attachment’s parent directory is exactly `Attachments/<id>` (`LocalStore.swift:55–70`). Messages transport copies go outside the support folder: `~/Library/Messages/Attachments/msgblast-Outgoing/<uuid>/` (`MessageSender.swift:16–18`, `Attachments.swift:81–99`). The saved draft file is not moved.

### What changes on disk

**Messages text send** (`AppModel.submit`, 609–670):

1. Before any Apple Event: `state.json` gains a `Comparison` (or an existing member moves `ready → sending` with `baseline` + `attemptedAt`) (`419–421`, `635–639`).
2. After `osascript` returns `SUBMITTED`: member `submission = submitted`, saved again (`643–644`). Anchor filled only if exactly one outgoing row matches (`646–658`).
3. `chat.db` is written by Messages, not by msgblast. msgblast opens it `SQLITE_OPEN_READONLY` (`MessagesDatabase.swift:12`).
4. Composer `draft` / `attachmentsDraft` cleared in `state.json` on `start` (`421`). Follow-up clears `allDraft` or one `privateDrafts` entry (`750–752`).
5. Incoming replies do **not** add rows to `state.json`. They appear in memory `AppModel.messages[chat.id]` on the next refresh (`AppModel.swift:229–232`).

**Messages attachment send** (`AttachmentDelivery.deliver`, `AttachmentDelivery.swift:59–105`): same `state.json` payload parts (`ready/failed → sending → submitted` plus `Anchor`). Plus a new transport copy under `msgblast-Outgoing`. No second copy of the support-folder original.

**Website send** (`WebAgentSession.send`, 871–969): the provider/instance JSON is rewritten (atomic) at attempt insert, again at `.attempting` before the click (`933`), again when a user-message receipt is observed (`945`, `1003–1009` also writes `conversationURLs`). Assistant reply text is **not** written to that JSON. It stays on `WebPageSnapshot` in memory (`refresh` → `inspect`, `637–667`). Ending a conversation copies that snapshot into `Comparison.endedWebHistory` inside `state.json` (`AppModel.swift:586–589`). A new comparison also inserts into `state.json` via `prepareWebComparison` (`490–500`).

**CLI send** (`sendNative`, 1100–1157): provider JSON updated to `.attempting` before the process (`1127–1128`). On success, `localConversations[comparison]` gains the user turn and the assistant turn together, plus `localSessionIDs` / configured id / policy version (`1143–1149`, `WebServices.swift:134–144`). Working directory is created if needed (`LocalPersonalAgent.swift:340`). Stdout is a temp dir `msgblast-Summary-<uuid>` that is removed in `defer` (`323–325`). No partial reply is saved if the process fails (`1150–1154`: status `.uncertain` or `.notSent`, transcript not appended).

**Grok Bot send** (`sendGrokBot`, 1457–1503): provider JSON gets the attempt, `callbackHash`, and the user `WebPageMessage` before `GrokBotService.submit` (`1477–1480`). On HTTP 401/403 or other definite rejection, that user turn is removed (`1494–1496`). Assistant text is appended in `applyGrokBotReceipt` and saved before the HTTP handler returns 200 (`1433–1449`, `GrokBotCallbackReceiver.swift:74–76`). Vault file is written only at connect time (`configureGrokBot`, `1346–1353`), not per message. Tunnel config is a temp dir `msgblast-tunnel-<uuid>/config.yml` removed on stop (`GrokBotTunnel.swift:23–27,99`).

### Change notification an in-process bridge can subscribe to

No dedicated sync bus, XPC, or distributed notification for model changes.

- `AppModel` is `@MainActor` `ObservableObject` (`AppModel.swift:5–22`). `@Published`: `state, chats, messages, databaseStatus, databaseAvailable, error, busy, webBroadcastBusy, webComparisonRequest, newBlastRequest, contactResults, contactQuery, demoFailureOnce, contactStatus, contactsAvailable`. SwiftUI/Combine subscribers get `objectWillChange`. `AppStartup` forwards it (`msgblastApp.swift:198`).
- `WebAgents` is `@MainActor` `ObservableObject`. It republishes every session’s `objectWillChange` (`WebAgents.swift:57–58`). `@Published`: `sessions` (private set), `configurationError`.
- `WebAgentSession` `@Published` (`WebAgentSession.swift:8–16,91,99–101`): `state, snapshot, isSending, connected, loading, error, popup, popupURL, avatar, accountStatus, grokBotConnectionActivity, grokBotNeedsKeychainRetry, grokBotRemembersConnection`. Page refresh assigns `snapshot`, which fires this.
- `PersonalAgentController` `@Published` (`PersonalAgentController.swift:8–16`): installed CLIs, account status, report errors, tasks. Report jobs, not chat transcripts.
- `NotificationCenter` uses found are `NSApplication.didBecomeActiveNotification` / `didResignActiveNotification` for permission and shortcut UI, not for new messages (for example `WebServicesView.swift:474`, `NewBlastShortcut.swift:137`).
- Messages polling is a 2-second `Timer` on `AppModel` (`AppModel.swift:97`) calling `refreshIfChanged`. It does not post a notification; it assigns `@Published` properties when values differ (`222–232`).

A bridge inside the Mac process can observe `AppModel` and `WebAgents`/`WebAgentSession` on the main actor. There is no publisher that fires only for “a new reply row.” Website assistant text changes `snapshot` on the 1-second poll. Messages reply changes `messages` only when the 2-second timer sees a new `PRAGMA data_version` and is not `busy`.

---

## 4. ACTION SURFACE

`AppModel`, `WindowCoordinator`, and `PersonalAgentController` are internal, `@MainActor`. `WebAgentSession`, `WebAgents`, and `AgentBroadcast` are `public` and `@MainActor` (`WebAgentSession.swift:6–7`, `WebAgents.swift:4–5`, `WebServices.swift:194–196`). None of these is a remote API. Return values below are the Swift results; UI also watches `@Published` fields.

There is **no** mark-read method and no `is_read` query. Searched the app Swift sources.

### List agents

| Call | Signature | Needs | Result |
| --- | --- | --- | --- |
| Saved Messages agents | read `state.agents` | loaded model | `[Agent]` |
| Grid | `AgentGridModel` extensions on `AppModel`: `gridID(for:)`, `messageAgent(for:)`, `isVisibleInAgentGrid`, `quickChatAgents` (`AgentGridModel.swift:33,100,108`; `AppModel.swift:457–468`) | onboarding finished for `quickChatAgents` | grid ids / agents currently eligible |
| Web/CLI/Bot sessions | `webAgents.sessions`, `.availableSessions` (enabled), `.selected` (enabled, `state.selected`, and `supportsSharedSubmissions`) (`WebAgents.swift:15–16`) | `WebAgents` init, which reads session files | `[WebAgentSession]` |
| One session | `WebAgents.session(for: WebAgentID)` / `session(for: AgentGridID)` (`60–66`) | | optional session |

Hark is in `sessions` but `supportsSharedSubmissions == false` (`WebProvider.swift:8`), so `.selected` omits it (`WebAgents.swift:16`).

### Select recipients

| Call | Signature | Needs | Observed by |
| --- | --- | --- | --- |
| Workspace Messages selection | direct `state.selection` insert/remove, then `persist()` (`WebServicesView.swift:268–271`) | not busy for the button; `persist` writes `state.json` | `state.selection` |
| Comparison send-to set | `setRecipients(_:for:)` (`AppModel.swift:127–131`) | comparison index | `comparison.recipientSelection` |
| Toggle one member | `ConversationRecipients.toggleRecipient` (`Models.swift:179–184`) | member exists | caller must save |
| Web session checkbox | `WebAgents.toggle(_:)` (`WebAgents.swift:119–131`) | session enabled. If turning on, `connect()` and, for shared providers, `openComparison` | `session.state.selected` |
| Restore a comparison’s set | `WebAgents.restoreSelection(forAgentIDs:)` (`112–117`) | | `selected` flags |

Hidden panes are in-memory (`hiddenMembers` / `hiddenWebAgents` in the SwiftUI view, `WebServicesView.swift:214,254`), not saved membership (`docs/architecture.md:259–260`).

### Create / open a comparison

| Call | Signature | Needs | Returns / observation |
| --- | --- | --- | --- |
| Messages-only blast | `func start(recipientIDs: Set<UUID>) async` (`403`) | `@MainActor`. Not `busy`. Non-empty draft or attachments. `databaseAvailable`. Contacts authorized, or it calls `contacts.request()` if `.notDetermined` (`408–411`) which presents the system Contacts dialog (`ContactSearch.swift:9`). `validateMembers` (`380–400`). | Inserts comparison, saves, `coordinator?.open`, then `submit`. Errors go to `error`. No return value. |
| Web + optional Messages | `func prepareWebComparison(_ text: String, recipientIDs: Set<UUID>, agents: [WebAgentID]) async -> UUID?` (`490`) | Not `busy`. Same Contacts request if recipients nonempty and not determined (`493`). | New `Comparison.id` or `nil` + `error`. Selects that workspace. Does not itself send. |
| Open existing web comparison | `func openWebComparison(_ id: UUID, present: Bool = true)` (`551`) | Not `webBroadcastBusy`. | Sets selection, `connectSelected()`, bumps `webComparisonRequest` if `present`. |
| Window | `WindowCoordinator.open(_ id: UUID)` (`WindowCoordinator.swift:219`) | `@MainActor`. Web comparisons call `openWebComparison` and `makeKeyAndOrderFront` / `NSApp.activate()` (`229–233`). | No return. Brings windows forward. |
| Workspace focus | `func selectWorkspace(_ id: UUID?, promotingDraft: Bool = false)` (`470`) | | Swaps `state.draft` with `workspaceDrafts`. `webAgents.setComparison`. |
| New Blast (does not send) | `func requestNewBlast(agent: AgentGridID? = nil) -> Bool` (`436`) | `canStartNewBlast` (`432–434`): onboarding done, no sharing-choice block, `error == nil`, not `busy` / `webBroadcastBusy` / any `isSending`. | `newBlastRequest` UUID. Menu then activates the app (`msgblastApp.swift:84–86`). |

`validateMembers` throws if a prior same-text send to that chat is still `submitted`/`uncertain`/`sending` with `anchor == nil` (`394–396`).

### Draft text

| Call | Signature | Persistence |
| --- | --- | --- |
| Shared composer | `func setSharedDraft(_ text: String)` (`426–430`) | `state.draft` and `workspaceDrafts[comparison ?? "new"]`, `persist()` |
| Comparison shared follow-up | UI writes `comparisons[i].allDraft` then `persist()` (`Views.swift:570–571`) | `state.json` |
| Private Messages follow-up | UI writes `privateDrafts[memberUUID]` then `persist()` (`Views.swift:362–363`) | `state.json` |
| Detached window draft | UI writes `workspaceDrafts[windowComparisonID]` (`WebServicesView.swift:228–231`) | `state.json` |
| Native CLI/Bot composer | `WebAgentSession.updateState` (`183–211`) | provider JSON `draft` + `localDrafts` |
| Website composer | page `inspect` → `recordDraft` (`714–722`) | provider JSON `webDrafts` only when the editor is available |

No single `setDraft` that covers every store. Private web sends use the session’s own `state.draft` via `sendDirect` (`WebServicesView.swift:369`).

### Attach file

| Call | Signature | Needs | Result |
| --- | --- | --- | --- |
| `addAttachments(_:comparisonID:memberID:)` | `async` (`AttachmentDelivery.swift:24`) | `AttachmentImport.files([URL])` or `.image(Data, filename)`. Stages via `LocalStore.stage` off the main actor (`33–37`). | Appends to `attachmentsDraft`, `allAttachmentsDraft`, or `privateAttachmentDrafts`. `error` on failure. |
| `setAttachmentDraft(_:comparisonID:memberID:saveNow:)` | (`9`) | | Replaces that draft and deletes unreferenced files. |
| `LocalStore.stage(_: URL)` / `stage(_: Data, filename:)` | (`28`, `43`) | regular file (`32`) | `MessageAttachment` with a new UUID directory. |

Shared composer disables attachments when any web session is selected (`WebServicesView.swift:237`, caption at `195–197`). `joinWebAgent` refuses a comparison whose shared context has attachments (`AppModel.swift:510–513`).

### Send to one agent

| Path | Signature | Requires | Completion |
| --- | --- | --- | --- |
| One Messages member of an existing comparison | `func submit(_ id: UUID, retry: Bool, only memberID: UUID? = nil) async` (`609`) | Comparison not ended, not `busy`, member `.ready` (or `.failed` if `retry`). `RecipientSet.validate`. Chat still eligible. `MessageSender.send` (`642`). | No return. Watch `member.submission`, `anchor`, `error`. `busy` true until `defer`. |
| Add one Messages agent into a comparison (sends joining context) | `func addAgent(_ agent: Agent, to id: UUID) async` (`536`) | Not ended, not `busy`, not already a member. `freezeSharedContext`. | `submit(..., only: agent.id)`. Window updated via `coordinator?.updateMembershipWindow`. |
| Private Messages follow-up | `func followUp(_ id: UUID, only memberID: UUID? = nil, recipients: [UUID]? = nil, retry attemptID: UUID? = nil, resumeUnsent: Bool = false, newAttemptID: UUID? = nil) async` (`712`) | Not ended, not `busy`. Target already has `anchor` and `.submitted` (`733`). No newer comparison anchor for that chat (`735–737`). | Watch `followUps[].states[memberUUID]`. |
| One web/CLI/Bot | `WebAgentSession.send(_ text: String, comparisonID: UUID? = nil) async -> WebSendAttempt?` (`871`) | Session storage healthy, not already sending. See section 5 for WebKit / CLI / Bot preconditions. | Returned attempt plus `state.attempts` and `snapshot` / `localConversations`. |
| UI private pane | `WebServicesView.sendDirect` (`369`) | Not ended, not busy, session enabled. Creates a comparison if needed (`379`). | `attempt.status`. |
| Retry | `submit(..., retry: true)` only retries `.failed` (`618`, `Submission.canRetry` at `Models.swift:122`). `followUp(..., retry:, resumeUnsent:)` (`724–730`). | | |

`submit`/`followUp` do not require the comparison window to already exist for the Apple Event itself. `start` does call `coordinator?.open` (`422`). Website `send` calls `connect()` which creates a `WKWebView` lazily (`WebAgentSession.swift:21–39,893`) even if no window owns it yet. Whether that off-window view can pass the page’s visibility checks is UNCERTAIN (section 5).

### Send to all comparison members

UI entry `WebServicesView.send` (`274–366`), not a method on `AppModel`:

1. If no web sessions and not already in a comparison: `start(recipientIDs:)` (`288–289`).
2. Else sets `webBroadcastBusy`, asks `web.signInRequired` (`301`). If any website reports `signedIn == false`, it sets `showingConnectionIntro` and **returns without sending** (`302–305`).
3. `web.prepareComparison` (`307`, `WebAgents.swift:150–156`): each session `openComparison`.
4. `prepareWebComparison` for a new blast, or `joinWebAgent` for sessions not yet members (`311–318`).
5. `AgentBroadcast.send` (`WebServices.swift:196–210`) runs web `WebAgents.send` (`158–162`) and Messages `submit` or `followUp` concurrently.
6. Draft cleared only if something may have been sent and the draft text is unchanged (`207–209`).

`WebAgents.selected` is the default shared set (`WebAgents.swift:16`). Hark cannot be in it.

### Cancel

| Call | What it cancels | What it does not cancel |
| --- | --- | --- |
| `WebAgentSession.cancelNativeRequest()` (`1088`) | In-flight CLI `Task` (`requestCancelled`, `nativeRequest?.cancel()`). `AgentCancellation` is checked in the process wait loop (`LocalPersonalAgent.swift:369`). | An Apple Event already handed to `osascript`. A website click already issued. A Grok webhook already accepted. |
| `acknowledgeIncompleteRequest()` (`1068–1074`) | Local status of native `.waiting`/`.uncertain` → `.dismissed` for the current comparison. | Remote Grok work (`docs/grokbot.md:61`). A late callback for a dismissed attempt is rejected with 410 (`GrokBotCallbackReceiver.swift:78`, `WebAgentSession.swift:1436`). |
| `WebAgents.beginShutdown` / `cancelAndWait` (`148–149`) | Polls and native tasks on quit. | |
| `PersonalAgentController.cancel(_:)` / `cancelAll()` (`160–161`) | Comparison **report** tasks only. | CLI chat turns (those are `WebAgentSession`). |
| Messages | none | `busy == true` makes `submit`/`followUp`/`start` return immediately (`609`, `712`, `406`). Quit is deferred while busy (`UpdateTermination.swift:12–13`). |

### End / close

| Call | Signature | Behavior |
| --- | --- | --- |
| End | `func endConversation(_ id: UUID) -> Bool` (`566`) | Requires every web agent `canArchiveComparison` (`570–573`, `WebAgentSession.swift:45–53`): native needs `localConversations` if a send was confirmed; websites need a loaded non-empty page if a URL or confirmed send exists. Reads latest Messages rows even if `busy` (`577`). Sets `endedAt`, `endMessageRows` (max `ROWID` per chat), `endedWebHistory`. Saves. Returns false and restores on save failure. |
| Close window | `WindowCoordinator.windowShouldClose` → `confirmClose` (`28–63`) | If not ended, `NSAlert` sheet: “End and Close” calls `endConversation`; “Keep Active and Close” only `orderOut`/`close` (`66–70`). Ended conversations close without the sheet (`35`). |
| Dismiss without ending | `dismissConversationWindow` (`66`) | Does not set `endedAt`. |

`canArchiveComparison` returns false when the website page is missing or still loading (`WebAgentSession.swift:52–53`), so end fails until that pane has been opened in this process.

### Fetch transcript

| Call | Signature | Contents |
| --- | --- | --- |
| Messages column | `func transcript(_ comparison: Comparison, member: Member) -> [Message]` (`595–598`) | Empty if no anchor. Else `ComparisonRange.messages` (`Routing.swift:78–86`): rows with `id >= anchor.rowID` and `id < nextAnchor`, plus messages whose `replyTo` guid chains to that set. If ended, pre-filtered by `comparison.includes` (`Models.swift:220–222`): `date <= endedAt` and `id <= endMessageRows[chatID]`. |
| Raw chat | `func latest(_ chat: Chat) throws -> [Message]` (`600`) | Demo: memory. Else `database.messages(chatID:)` with `after` default 0. |
| Live website | `WebAgentSession.messagesForComparison(_:)` (`41–43`) and `snapshot.messages` | DOM snapshot, or `localConversations` for native. |
| Ended website/CLI | `comparison.endedWebHistory?[agent.id]` | Frozen at end. |
| CLI/Bot while active | `session.state.localConversations[comparisonUUID]` | Provider JSON. |

`ComparisonRange` is a **row-id window in that one chat**, not an iMessage thread id. A later comparison’s anchor truncates the window (`Routing.swift:88–90`). Follow-ups are blocked when `nextAnchor` is non-nil (`AppModel.swift:735–737`).

---

## 5. REPLY OBSERVATION PER CONNECTION TYPE

### Messages (SQLite polling)

- Timer: `Timer.scheduledTimer(withTimeInterval: 2, repeats: true)` (`AppModel.swift:97`) → `refreshIfChanged` (`191–198`).
- Skips when `busy`, `demo`, onboarding without Messages use, or `database.changeVersion()` equals `lastDataVersion`.
- `changeVersion` is `PRAGMA data_version` (`MessagesDatabase.swift:206–208`). Any write to `chat.db` bumps it, not only rows msgblast cares about.
- Open: `sqlite3_open_v2(..., SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)`, `sqlite3_busy_timeout` 1500 ms (`MessagesDatabase.swift:12–18`). Path `~/Library/Messages/chat.db` (`AppModel.swift:218`).
- Chats SQL (`50–64`): tables `chat`, `chat_handle_join`, `handle`, `chat_message_join`, `message`. Columns used: `c.guid`, `h.id`, `c.display_name` if present, `c.service_name` or `h.service`, `m.date`, `m.balloon_bundle_id` if present. Requires `COUNT(messages) > 0` and (exactly one handle and service `iMessage`) or business balloon.
- Messages SQL (`72–87`): `message` columns `ROWID, guid, text, date, is_from_me`, plus if present `thread_originator_guid`, `associated_message_type`, `associated_message_guid`, `associated_message_emoji`, `handle_id`, `error`, `is_delivered`. Join `chat_message_join`, `chat`. Filter `c.guid = ? AND m.ROWID >= ?`.
- Attachments (`184–199`): `attachment` + `message_attachment_join` when those tables/columns exist. `filename`, `guid`, `transfer_name`, `mime_type`, `total_bytes`.
- Business payload (`149–155`): `payload_data`, `balloon_bundle_id`.
- Reaction rows (`associated_message_type` 2000–3999) are folded onto the target message and not returned as their own `Message` (`91–92`, `114–146`).
- Refresh only loads chats that appear on some comparison member, from the minimum anchor `ROWID` (or 0) (`AppModel.swift:228–232`).
- While `busy`, the timer does not run (`193`). `submit` sets `busy` and `defer { refresh() }` (`614`). During the send it separately polls up to 6 times, 500 ms apart, for the **outgoing** anchor only (`646–656`).
- A new incoming row maps into a comparison only through `transcript` / `ComparisonRange` (section 4). It is not matched to a follow-up id. Delivery flags update the in-memory `Message.delivery` on the next successful read.
- Reconcile of a missing outgoing anchor runs at the end of `refresh` (`234`, `672–710`) for `.submitted`/`.uncertain` parts whose anchor is nil. Match rules: outgoing, `id > baseline`, text or filename+byte count equal, `date >= attemptedAt - 2s`, not claimed by another payload, exactly one candidate (`Attachments.swift:31–43`, `Routing.swift:63–75`).

Full Disk Access failure surfaces as `databaseAvailable = false` and `databaseStatus` (`AppModel.swift:236`, open error text `MessagesDatabase.swift:15`). No in-app modal in `refresh` itself. The main window shows `model.error` as a SwiftUI alert (`Views.swift:269–271`).

Source does not say the Mac must be unlocked or the window frontmost to **read** `chat.db`. Send is a different path (Apple Event, section 6). UNCERTAIN whether a locked session still lets `osascript` control Messages.

### Websites

Extraction (`WebPageScript.swift:73–91,127`): `inspect()` returns `{...status(), messages, submissionInterrupted}`. Each visible message node (selector per provider, lines 28–51) becomes `{id, role, text}`. Roles: ChatGPT `data-message-author-role` or search-unit `:user|:assistant`; Dots `.self` → user else assistant; Claude `data-testid=user-message` vs assistant; Grok `.items-end` → user else assistant; OS3 `.dial-user` vs assistant and `data-render-id`. Text is normalized whitespace. Hark’s `inspect` always returns `messages: []` and `ready: false` (`12–26`).

Poll: after `connect()`, a `Task` calls `refreshPages()` then sleeps **1 second** (`WebAgentSession.swift:296–300`). `refreshPages` runs `inspect` JavaScript on each live page (`631–659`). Receipt reconciliation runs inside that refresh (`674–675`).

Receipt matching is the **user** bubble, not the assistant reply (`observeReceipt`, `972–1010`):

- Page URL must be accepted by `WebProvider.acceptsReceipt` (`74–77`): same canonical chat, or the original URL was the new-chat URL.
- `snapshot.messages` must `starts(with:)` the pre-click baseline (`993`).
- Exactly one new message with `role == "user"` whose normalized text equals the attempt (`997–1001`).
- That id must not already be claimed (rabbit/OS3 shares claims across attempts, `395–396`).
- Status becomes `.observed`. `messageID` is that user node id. `conversationURLs[comparison]` is set.
- If the click happened but no unique user node appears within 20 × 250 ms, status is `.uncertain` and there is no automatic resend (`941–950`).
- `.waiting` is not assigned on the website path. It is the Grok Bot post-accept state (`WebAgentSession.swift:1485`).

Assistant replies are whatever later `inspect` puts in `snapshot.messages` with `role == "assistant"`. They are not written to disk until `endConversation` copies `messagesForComparison` (`AppModel.swift:586–588`). A 1-second poll that only changes assistant text updates `@Published snapshot` and does not by itself rewrite the provider JSON, unless the composer draft also changed (`recordDraft`, `714–722`).

`WKWebView` lifetime:

- Created in `makePage` with an 800×600 frame, navigation delegate set, **not** inserted into a window by `WebAgentSession` (`24–31`). SwiftUI representable in the chat pane is what displays it (not re-cited line-by-line). `send` calls `connect()` → `loadComparisonChat()` → `webView`, so a view object exists before the click (`893–894`).
- Send does **not** check `view.window`, `isHidden`, or app active state.
- Dots avatar capture returns immediately when `page.view.window == nil` (`798–800`). That is the only `window == nil` gate found.
- Page script treats a node as visible only if `getClientRects().length > 0` and CSS `visibility != 'hidden'` (`WebPageScript.swift:57`). `status()` then requires exactly one visible editor (`60`). A dialog (`role=dialog` / `aria-modal`) yields not-ready: “Finish the open dialog” (`105–114`). Sign-in buttons yield not-ready (`110`).
- Whether WebKit returns non-empty client rects when the view is not in a window, the app is hidden, or the display is asleep is **UNCERTAIN**. The source does not test or document it. If rects are empty, `prepareConversation` / `send` fail as not ready and do not click (`WebAgentSession.swift:899–901`, `WebPageScript.swift:109–116`).
- Inactive pages beyond 4 can be destroyed after an inspect that shows a finished assistant reply (`unloadInactivePages`, `744–770`). A bridge that never opens a pane can still have the original page if `connect` loaded it; extra comparison pages are created in `selectPage` (`77–82`).
- rabbit OS3 (`sharesOneConversation`, `WebProvider.swift:35`) keeps one `WKWebView` across comparison switches (`WebAgentSession.swift:59–65`). Receipts stay on the attempt that observed the message (`docs/architecture.md:98–102`, claimed ids at `395–396`).
- Hark never clicks Send (`WebPageScript.swift:13–14`). `supportsSharedSubmissions` is false.

Sign-in: `checkSignIn` (`567–588`) returns `Bool?` from `signInStatus` script. `WebServicesView.send` aborts the broadcast if any returns `false` (`301–305`).

### CLI conversations

Providers: `codexCLI` → `PersonalAgentProvider.codex`, `claudeCode` → `.claude` (`WebProvider.swift:11–13`). Enabled only when `WebWorkspaceState.enabled == true` (`WebAgentSession.swift:214`). Settings calls `WebAgents.setEnabled` (`WebAgents.swift:104–107`).

No `WKWebView` and no poll loop for replies (`connect` just `refresh()` once, `290–292`). A reply exists only when the process exits 0 and the parser accepts it.

Lifecycle (`LocalPersonalAgent.reply`, `258–298`, `AgentProcess.run` `317–398`):

- Timeout 180s (`288`). Output cap 4_000_000 bytes (`314`, `372`).
- Prompt on stdin. Codex persistent args include `exec`, `--json`, and `resume <sessionID>` when resuming (`LocalPersonalAgent.swift:47–57`). Claude: `--print --output-format json --permission-prompts none`, `--resume` or a new `--session-id` (`58–71`).
- Working directory: support folder `local-conversations/<chatgpt|claude>/<comparisonUUID>` (`WebAgentSession.swift:1096–1097`). Created `0700` (`LocalPersonalAgent.swift:340`).
- Stdout/stderr are temp files under `msgblast-Summary-<uuid>`, deleted in `defer` (`323–325`).
- Session id parse: Codex JSON line `type == thread.started` → `thread_id`; Claude JSON `session_id`; must be a UUID (`389–390`). Codex also requires a `turn.completed` record (`393–394`). Resume must return the same id (`268–269`).
- `resumableLocalSessionID` requires policy version 1 and the configured id (`WebServices.swift:129–132`). Docs: a missing CLI session is an error, not a silent new session (`docs/personal-agent-reports.md:13`).
- First configured follow-up when the old restricted session is not resumable sends the saved transcript as quoted history (`LocalPersonalAgent.swift:263–266`, `docs/personal-agent-reports.md:23`).
- Cancel: `cancelNativeRequest` → `Task` cancel → `AgentCancellation` → process group `SIGTERM` then `SIGKILL` (`LocalPersonalAgent.swift:351–356`). Incomplete runs become `.uncertain` if the process had been started (`WebAgentSession.swift:1150–1151`) and block another send until acknowledged (`1084–1086`, `1068–1074`).
- Tools: persistent conversation does **not** pass Codex `--sandbox read-only` or Claude `--tools ""` (`LocalPersonalAgent.swift:50–67`). The CLI may perform permitted actions. Interactive approval is denied for Claude (`--permission-prompts none`). Three-minute timeout (`PersonalAgentError.timedOut`, line 128).
- No window is required by this code. The app process must stay alive until the `Task` finishes; `cancelAndWait` waits while `isSending` (`1090–1093`). UNCERTAIN whether a locked screen blocks the CLI (source does not check lock state). GUI login for the CLI is a separate Terminal script (`loginScript`, `200–224`), not used on the send path.

### Grok Bot

Webhook (`GrokBotService.submit`, `73–95`): `POST` the routine URL, `Authorization: Bearer <webhookKey>`, `Content-Type: application/json`, ephemeral `URLSession`, no redirects (`244–246`), request timeout 20s. Body from `encodeRequest` (`59–66`): `source, request_id, comparison_id, message, history, callback_url, callback_token`. Cap 128 KiB (`45`, `65`). HTTP 200 = accepted, not answered (`88–89`, `docs/grokbot.md:24`). 401/403 → `.unauthorized` and `definitelyNotSubmitted` (`117–119`). Other errors → `.uncertain` if the request might have been sent (`WebAgentSession.swift:1494`).

Callback listener (`GrokBotCallbackReceiver.swift:19–44`):

- `NWListener` TCP, `requiredLocalEndpoint = hostPort(host: "127.0.0.1", port: .any)` (`20–21`).
- Started on `DispatchQueue.main` (`43`).
- Only `POST /reply/<UUID>` with `Content-Type: application/json`, `Content-Length`, no `Transfer-Encoding` (`131–141`).
- Bearer token checked against SHA-256 stored at register time (`66–68`).
- Identical receipt body for the same id returns 200 and does not append again (`73–75`, `1438–1440`). Different body for a completed id returns 409.
- No other routes. Wrong path 404. Connection timeout 10s (`97–99`).

Tunnel (`GrokBotTunnel.start`, `18–58`): bundled `Contents/Helpers/cloudflared`, args `tunnel --config <empty yml> --url http://127.0.0.1:<port> --no-autoupdate --loglevel info` (`29–30`). Parses `https://[a-z0-9-]+.trycloudflare.com` (`62`). Waits until that host returns 405 with the rejection body, up to 40 probes × 2s, and the whole start fails at 90s (`53–57`, `73–83`). `onDisconnect` stops and marks `.attempting`/`.waiting` as `.uncertain` (`WebAgentSession.swift:1383–1403`). Quit/stop `SIGKILL`s the helper (`GrokBotTunnel.swift:94–96`).

History for the next request is `localConversations[comparison]` (`1474–1475`). User turn is stored before POST; assistant turn on callback (`1478`, `1443`).

Awake / open (`WebAgentSession.swift:1486`, `docs/grokbot.md:59–61`): waiting detail says keep msgblast open and the Mac awake. The listener and cloudflared are in-process; quit stops both (`beginShutdown` calls `stopGrokBotConnection`, `1089`). Source does not require the window to be frontmost. Keychain item accessibility is `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (`GrokBotService.swift:177`) and UI interaction is forbidden (`127–132`). A locked Mac after first unlock may still read the item; before first unlock, or if the system demands UI, the read returns nil or `.keychainWaiting`. UNCERTAIN how sleep affects an already-registered quick tunnel beyond the documented “keep awake” string.

---

## 6. EXISTING NETWORK / IPC SURFACE

| Mechanism | Present? | Evidence |
| --- | --- | --- |
| HTTP listener | Yes, loopback only | `GrokBotCallbackReceiver` `NWListener` on `127.0.0.1` random port (`GrokBotCallbackReceiver.swift:19–22`). Only authenticated `POST /reply/<uuid>`. Not a control API. |
| Outbound HTTP | Yes | Grok webhook (`GrokBotService.swift:73–77`). Telemetry POST if an endpoint is configured (`AppModel.swift:50`, `Info.plist:27–28` `msgblastTelemetryEndpoint`). Feedback submission is a separate client (`FeedbackSubmission.swift`, not a listener). Sparkle feed (`Info.plist:29–30`). |
| URL scheme owned by the app | No | `Info.plist` has no `CFBundleURLTypes`. |
| URL schemes the app opens | Client only | `imessage://?chat=` (`AppModel.swift:822–824`). `x-apple.systempreferences:` (`AppModel.swift:256,826`). |
| Apple Events | Outbound to Messages, not an inbound scripting dictionary | Entitlement `com.apple.security.automation.apple-events` (`msgblast.entitlements:1–3`). `NSAppleEventsUsageDescription` (`Info.plist:23–24`). `MessageSender` runs `/usr/bin/osascript` (`MessageSender.swift:38–40`). No `.sdef`, no `NSAppleEventManager` in the repo Swift/plist/entitlements search. |
| XPC | No | No `NSXPC` / `XPC` matches in Swift or plists. |
| App Intents / Shortcuts donated by source | No intent types in source | No `AppIntent` type. `docs/completion-audit.md:146` mentions an Xcode AppIntents metadata warning during tests. That is not an implemented intent. UNCERTAIN whether the built app still emits empty AppIntents metadata. |
| Global hotkey | Yes, local only | `NewBlastShortcut` Carbon `RegisterEventHotKey` (`NewBlastShortcut.swift:1–22,32–39`). Opens New Blast while the app is running (`docs/architecture.md:43–46`). Not a network endpoint. Stored in `UserDefaults` keys `newBlastShortcut` / `newBlastShortcutEnabled` (`NewBlastShortcut.swift:24–25`). |
| `NSUserActivity` / Handoff | No | No matches. |
| CloudKit / iCloud | No | No matches. |
| Bonjour | No | No `NetService` / `NWBrowser`. |
| Deep links | No inbound handler | No `onOpenURL` / `handlesExternalEvents`. |

### Entitlements and sandbox

`msgblast/msgblast.entitlements` (production) and `msgblast/msgblastDebug.entitlements` (Debug, `generate_project.py:17`):

- `com.apple.security.personal-information.addressbook` = true
- `com.apple.security.automation.apple-events` = true
- `com.apple.security.network.client` = true
- Debug only: `com.apple.security.cs.disable-library-validation` = true (`msgblastDebug.entitlements:11–12`)

**Not sandboxed.** There is no `com.apple.security.app-sandbox`. No App Group entitlement. No `com.apple.security.network.server`. The loopback listener is possible because the app is unsandboxed; the Grok Keychain path explicitly checks for `com.apple.application-identifier`, `keychain-access-groups`, or `com.apple.security.application-groups` and skips the data-protection keychain when none are present (`GrokBotService.swift:134–141,156–157`). Ad-hoc builds therefore do not get that Keychain backend.

Hardened runtime is on for the app target (`generate_project.py:60`). `NSContactsUsageDescription` and `NSAppleEventsUsageDescription` are in `Info.plist:21–24`. No `NSLocalNetworkUsageDescription` (the listener binds loopback only).

`Info.plist` keys otherwise: bundle placeholders, `LSMinimumSystemVersion` 15.0, `NSPrincipalClass` = `NSApplication`, Sparkle keys, telemetry endpoint placeholder. No document types, no URL types, no background modes.

---

## 7. SECURITY-SENSITIVE SURFACES

### Where credentials live

| Secret | Where | Leaves the Mac? |
| --- | --- | --- |
| Website login cookies | `WKWebsiteDataStore` for `sessionID` (`WebAgentSession.swift:18`). Optional one-time import from Chrome/Safari via SweetCookieKit (`docs/architecture.md:139–147`, `BrowserLoginImporter.swift`). | Not copied into `state.json` or CLI/Bot stores (`docs/architecture.md:149–152`). Import writes only the WebKit cookie store (`WebAgentSession.registerBrowserCookies`, `235–273`). |
| CLI auth | Remains in the CLI’s own config. `loginScript` unsets `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, and similar before Terminal login (`LocalPersonalAgent.swift:218`). msgblast does not persist those tokens (`docs/personal-agent-reports.md:17`). | The prompt text is passed on the CLI’s stdin. |
| Grok webhook URL + key | Memory `grokBotCredentials` (`WebAgentSession.swift:94`). Persisted either in the Secure Enclave vault file `.grokbot-credentials/<hash>.json` (`GrokBotCredentialVault.swift:19–23`) or data-protection Keychain service `com.msgblast.grokbot.<bundle id>` account = SHA-256 of the session file path (`GrokBotService.swift:125–132`). If neither backend works, session-only until quit (`docs/grokbot.md:21`, `configureGrokBot` `1346–1352`). `state.json` / provider JSON store only `grokBotRememberedConnection: Bool` (`WebServices.swift:61`, `WebAgentSession.swift:1353`). Legacy file Keychain items are not read (`docs/grokbot.md:22`). | The key is sent as `Authorization: Bearer` to the webhook URL (`GrokBotService.swift:76`). |
| Per-request callback token | 256-bit random, base64 (`WebAgentSession.swift:1471`). Only SHA-256 stored on the attempt (`1472`). | Plaintext is inside the webhook JSON `callback_token` (`GrokBotService.swift:61–64`) so Grok Bot can call back. Cloudflare sees the callback HTTP (`docs/grokbot.md:47`). |
| Contacts / Messages history | Contacts via `CNContactStore`. Messages via read-only `chat.db`. Avatars may be stored on `Agent.avatar` (`Models.swift:58`, `ContactSearch.swift:77`). | Telemetry properties are a closed set and “prevent arbitrary strings, content, URLs or identities” (`Telemetry.swift:47`). Installation id only if activity sharing is on (`Telemetry.swift:37,103`). |
| Staged attachments | Support folder `Attachments/` and Messages `msgblast-Outgoing` copies. | Not uploaded by msgblast except as an Apple Event file to the existing Messages chat. |

Vault reads/writes set `LAContext.interactionNotAllowed = true` (`GrokBotCredentialVault.swift:28–31`, `GrokBotService.swift:126–132`) and time out the caller at 15s (`GrokBotCredentialWorker`, `GrokBotService.swift:210–216`). No Mac login prompt on that path (`docs/grokbot.md:12`).

### Must not leave the Mac for a sync bridge

From the code’s own boundaries: `chat.db` rows, Contacts records, `Agent.avatar`, draft strings, attachment bytes, WebKit cookie stores, CLI credential files, Grok vault plaintext and webhook key, callback bearer tokens, `callbackHash` preimages, telemetry installation id if treated as a user identifier. Provider JSON already contains full CLI/Bot transcripts and website drafts (`WebWorkspaceState`). `state.json` contains prompts, follow-ups, anchors, and ended web transcripts.

### Irreversible actions

| Action | Where | Guard |
| --- | --- | --- |
| Real iMessage text send | `MessageSender.send(_:to:)` via `osascript` (`MessageSender.swift:7–8,38`) | Not demo. Chat must stay eligible (`AppModel.validate`, `605–607`). Accepted command is not delivery (`Models.swift:88`). Timeout/ambiguous → `.uncertain`, no auto resend (`MessageSender.swift:32–33,53–56`). |
| Real iMessage file send | `MessageSender.send(_: MessageAttachment)` (`10–20`) | Copies into Messages’ attachment directory first. Same Apple Event rules (`MessagesSendScript.attachment`). |
| Contacts write | `ContactSearch.saveManual` (`45–68`) | Only when adding a manual agent with no `contactID` (`AppModel.swift:334–336`). `CNSaveRequest.add`. System permission dialog if not determined. |
| Website Send click | `script.clickSend` after state is `.attempting` (`WebAgentSession.swift:932–935`) | Duplicate same text blocked while unresolved (`878`, `WebServices.swift:145–147`). Click result `clicked == false` is `.notSent` (`936–938`). |
| CLI process | `LocalPersonalAgent.reply` | May run tools under the CLI’s own policy (`docs/personal-agent-reports.md:17–21`). Usage can be consumed without a saved reply (`docs/personal-agent-reports.md:21`). |
| Grok webhook POST | `GrokBotService.submit` | Not auto-retried (`docs/grokbot.md:18`, `.unavailable` text at `GrokBotService.swift:110`). |
| Business quick-reply click | `BusinessChoiceModel.chooseBusinessOption` (app target) | Accessibility, not a text send (`docs/architecture.md:110`). Uncertain attempts are not repeated (`Models.swift:320–323`, `BusinessChoice.swift:33` allows retry only from `.failed`). Out of scope for a normal text bridge but irreversible. |

### Duplicate-send guards (concrete)

- Durable intent is saved before the external call (`AppModel.swift:420`, `639`, `WebAgentSession.swift:933`, `1128`, `1479`).
- `.sending` recovered as `.uncertain` on next launch (`Models.swift:330–332`, `WebServices.swift:152–154`, Grok `.waiting` → `.uncertain` at `WebAgentSession.swift:160–162`).
- `.uncertain` is not `canRetry` (`Models.swift:122`). Follow-up recovery sends only `.ready` or, if `resumeUnsent`, `.failed` (`FollowUp.recipientsForRecovery`, `168–169`). Explicit UI buttons call `followUp(..., retry:)` (`Views.swift:513–516`).
- Same prompt to the same chat while an anchor is still missing is blocked (`AppModel.swift:394–396`).
- Attachment parts: a part without an anchor stops the rest of the payload (`AttachmentDelivery.swift:67–68,97`). Claimed guids cannot satisfy a second part (`Attachments.swift:69–74`, `AttachmentDelivery.claimedAnchors` `45–57`).
- Follow-up requires the original anchor and refuses if a newer comparison already anchored that chat (`AppModel.swift:733–737`).
- Website: `hasUnresolvedSend` same normalized text (`WebAgentSession.swift:1077–1080`). rabbit applies that across comparisons (`1078–1079`).
- CLI/Grok: any unresolved attempt on that comparison blocks (`1084–1086`, `1460`).
- Grok callback dedup (`GrokBotCallbackReceiver.swift:73–75`).
- Two members cannot share one `chat.id` (`Routing.swift:93–101`).

---

## 8. GAPS / RISKS FOR A REMOTE BRIDGE

Source facts that a headless or remote controller will hit. Each is a file:line, not a guess about product design.

1. **Main-actor UI owns the send orchestration.** `AppModel`, `WebAgentSession`, and `WebServicesView.send` are `@MainActor`. The shared “send to everyone” function is a private SwiftUI method (`WebServicesView.swift:274`), not `AppModel`. A bridge must call `prepareWebComparison` + `WebAgents.prepareComparison` + `AgentBroadcast.send` / `submit` / `followUp` itself, or drive that view.

2. **`model.error` raises a modal alert** on the main workspace (`Views.swift:269–271`). Many failures assign `self.error` (`AppModel.swift:424,502,548`, and others). A remote send that fails will pop “msgblast” + OK if that window is on screen. The alert’s binding clears `error` on dismiss (`269`). Attachment failures have a second alert (`Views.swift:144`, `AttachmentViews.swift:147`).

3. **Closing an active conversation is a sheet**, not a data call (`WindowCoordinator.swift:34–63`). “End and Close” vs “Keep Active and Close”. Escape keeps it active (`44`). End can then show a second failure sheet (`51–57`). `endConversation` itself does not show UI (`AppModel.swift:566`).

4. **Contacts permission dialog on the send path** if status is `.notDetermined`: `start` (`AppModel.swift:408–411`) and `prepareWebComparison` (`493`) call `contacts.request()` (`ContactSearch.swift:9`). If denied, `validateMembers` → `contacts.refreshed` throws (`AppModel.swift:386`, `ContactSearch.swift:71–72`). Manual agent add writes Contacts (`AppModel.swift:334–336`).

5. **Automation permission is outside the app.** `osascript` result `-1743` becomes a not-submitted error string telling the user to allow control of Messages (`MessageSender.swift:26–28`). There is no in-app retry that grants it. Full Disk Access failure is a thrown string from `MessagesDatabase.init` (`15–16`), not a send.

6. **Sign-in aborts a shared send** (`WebServicesView.swift:301–305`) and opens the connection intro instead of submitting. `prepareConversation` throws not-ready / not-sent when the page is logged out, has a draft, has a dialog, or is generating (`WebPageScript.swift:109–116`, `WebAgentSession.swift:516–517,540–545`). Those strings land on `session.error` or the attempt’s `detail`.

7. **Hark cannot be a shared recipient.** `supportsSharedSubmissions` is false (`WebProvider.swift:8`). Page script never inserts text or clicks Send (`WebPageScript.swift:13–14`). `WebAgents.selected` filters it out (`WebAgents.swift:16`). `WebServicesView.selectRecipient` returns immediately (`253`).

8. **rabbit OS3 is one conversation per account** (`WebProvider.swift:34–35`). Switching comparisons keeps the same page, draft, and DOM (`WebAgentSession.swift:59–65`). An observed message id cannot be reused as another attempt’s receipt (`395–396`, `docs/architecture.md:98–102`). Dots also keeps one page (`61`) and resolves `/dots` to the account’s ongoing chat (`WebAgentSession.swift:522–525`).

9. **Website send readiness depends on a visible DOM**, including `getClientRects()` (`WebPageScript.swift:57–60`). The session does not require `WKWebView` to be in a window before `send`, except Dots avatar bails when `window == nil` (`WebAgentSession.swift:800`). Off-screen / hidden / background behavior of that JavaScript is **UNCERTAIN**. A modal or “Stop generating” control blocks readiness (`WebPageScript.swift:105–115`).

10. **Ending a web comparison requires the page to be loaded in this process** (`WebAgentSession.canArchiveComparison`, `45–53`). If the view was never created or is `loading`, `endConversation` fails with “Open the saved agent chats…” (`AppModel.swift:570–572`).

11. **Messages replies are not persisted and are not pushed.** They show up only after the 2s timer, and the timer does not run while `busy` (`AppModel.swift:97,193–196`). During a multi-recipient send, replies that land in `chat.db` wait until `submit`’s `defer { refresh() }` (`614`). There is no read cursor to ack.

12. **Website assistant text is not on disk until End** (or unless it happens to be a CLI/Bot `localConversations` entry). A bridge that tails `state.json` and provider JSON will see website receipts (`WebSendAttempt`, `conversationURLs`) and drafts, not the assistant body (`recordDraft` only stores composer text, `714–722`).

13. **No mark-read, no inbound IPC, no URL scheme** (section 6). A remote controller has nothing to attach to except in-process objects or files. File observation will miss in-memory `snapshot` and `AppModel.messages`.

14. **`busy` and `webBroadcastBusy` serialize sends.** A second `submit`/`start`/`followUp` returns immediately (`AppModel.swift:406,609,712`). `canStartNewBlast` is false while any session `isSending` (`432–434`).

15. **Grok requires the app process, the listener, and the tunnel to stay up**, and the saved copy tells the user to keep the Mac awake (`WebAgentSession.swift:1486`). Disconnect marks waiting attempts `.uncertain` with no resend (`1400–1402`). Secure storage will not show a prompt (`GrokBotService.swift:132`); failure becomes `error` / `grokBotNeedsKeychainRetry` (`WebAgentSession.swift:1331`).

16. **CLI may block on a 3-minute process and may have side effects** under the user’s CLI permissions (`LocalPersonalAgent.swift:288`, `docs/personal-agent-reports.md:17–21`). Claude older than the version that supports `--permission-prompts` fails with `conversationVersionRequired` (`LocalPersonalAgent.swift:289–292,124`). OpenClaw has no chat adapter (`docs/personal-agent-reports.md:39–40`). Hermes is reports only (`57–59`).

17. **New Blast and the menu-bar shortcut activate and order the window front** (`msgblastApp.swift:80–86`, `WindowCoordinator.open` `216–233`). They are not headless.

18. **Demo mode never performs real sends** (`AppModel.swift:63`, `submit` uses `appendDemo` when `demo`, `641`). `--demo` also uses a separate permission defaults suite (`AppModel.swift:48`). A bridge pointed at a Demo build will not reach Messages, the tunnel, or live CLIs (`WebAgentSession` fixture branches `1133–1135`, `1410–1414`).

19. **Storage load failure disables sending** and will not overwrite `state.json` (`AppModel.swift:81,103–104`). Quit writes a side `Recovery/` snapshot instead (`UpdateTermination.swift:27–39`).

20. **Identity traps for sync:** `Message` is not `Codable`. Website synthetic `node-N` ids die with the DOM (`WebPageScript.swift:63–65,89`). Comparison transcript boundaries are `ROWID` windows (`Routing.swift:78–90`), so importing “the thread” from `chat.db` without anchors will include other blasts to the same contact. `Member.id == Agent.id`, so one agent cannot appear twice in one comparison.
