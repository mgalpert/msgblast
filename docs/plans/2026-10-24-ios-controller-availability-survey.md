> Source survey produced on 2026-10-25 against revision 7676362e87 (0.10.0, merge of PR #81) by a Grok 4.7 subagent and spot-checked by hand. Line numbers refer to that revision only. Companion to [the iOS controller architecture discussion](2026-10-24-ios-controller-architecture.md).

# msgblast availability survey (source, release 0.10.0)

Read-only. Range `b8bf614..HEAD` includes merge `7676362` (PR #81). `msgblast/Core/Models.swift` has no diff in that range. Line numbers are the worktree at survey time.

No `WebProvider` case is a Messages agent. Messages agents are `OnboardingChoice` values persisted as `Agent` (`msgblast/Core/Models.swift:52`).

## 1. Provider catalog

`WebProvider` cases: `msgblast/Core/WebProvider.swift:4`.

Defaults that matter:

- `supportsSharedSubmissions`: `self != .hark` (`WebProvider.swift:15`). Hark is the only false.
- `supportsCopies`: only `.muse, .chatgpt, .claude, .grok` (`WebProvider.swift:17`). Copies are `WebAgentID.instance != nil`, registry `web-agent-instances.json`, file `web-instance-<uuid>.json` (`WebAgents.swift:49-59`, `220-223`). Desktop, CLI, bot, Hark, Dots, OS3 cannot be copied (`WebAgents.swift:52`, `82-86`).
- `usesNativeConversation`: CLI or `.grokbot` or `desktopApp != nil` (`WebProvider.swift:16`).
- `isAvailableInBuild`: `self != .geminiApp` (`WebProvider.swift:10`). Gemini stays Codable and is not offered (`Onboarding.swift:6-8`).
- `isEnabled` default differs: native requires `state.enabled == true` (nil = off). Website is on unless `websiteEnabled == false` (`WebAgentSession.swift:255`). Fresh installs force the five settings-only websites off (`AppModel.swift:62`, `WebAgents.swift:41-43`).
- Storage: Muse website `web-services.json`; every other provider `web-<rawValue>.json` (`WebProvider.swift:60`). Desktop apps are separate files from their websites. `WebProviderStateMigration.pairs` is only `(.chatgpt, .codexCLI)` and `(.claude, .claudeCode)` (`WebServices.swift:342`). No website-to-desktop migration.
- `WebAgentID` statics stop at Hark (`WebProvider.swift:97-106`). Desktop sessions use `WebAgentID(provider:)` with `instance == nil`, so `id == rawValue` (`WebProvider.swift:93-96`, `WebAgents.swift:36-39`).

| raw value | display name | kind | shared sends | shares one conversation | named copies | Mac bundle id(s) | Messages type |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `muse` | Muse (`22`) | website | yes | no (`43`) | yes | none | none |
| `chatgpt` | ChatGPT | website | yes | no | yes | none | none |
| `claude` | Claude | website | yes | no | yes | none | none |
| `grok` | Grok | website | yes | no | yes | none | none |
| `codexCLI` | Codex CLI | CLI (`18-19` → `PersonalAgentProvider.codex`, executable `codex`, `LocalPersonalAgent.swift:5-19`) | yes | no | no | none | none |
| `claudeCode` | Claude Code | CLI → `.claude`, executable `claude` | yes | no | no | none | none |
| `dots` | Dots | website | yes | no | no | none | none |
| `grokbot` | Grok Bot | webhook bot (`usesNativeConversation`, not `desktopApp`) | yes | no | no (`supportsCopies` false; `addGrokBot` is a special case, `WebAgents.swift:89-90`) | none | none |
| `os3` | rabbit OS3 | website | yes | yes (`43`) | no | none | none |
| `hark` | Hark | website | no | no | no | none | none |
| `museApp` | Muse | desktop → `DesktopAppProvider.muse` (`11-12`) | yes | no (excluded at `43`) | no | `com.meta.endo` (`DesktopAppConversation.swift:8`) | none |
| `grokBotApp` | Grok Bot | desktop → `.grokBot` | yes | yes (`43`: desktop and not in the exclusion list) | no | `com.anysphere.sand` (`9`) | none |
| `wabi` | Wabi | desktop → `.wabi` | yes | yes (`43`) | no | `ai.wabi.desktop` (`10`) | none |
| `geminiApp` | Gemini | desktop → `.gemini`, **not in `desktopProviders`** (`8`) and **not available this build** (`10`) | yes (flag) but `isEnabled` is false | no | no | `com.google.GeminiMacOS` (`11`) | none |
| `chatgptApp` | ChatGPT | desktop → `.chatgpt` | yes | no | no | `com.openai.codex`, then `com.openai.chat` (`12`) | none |
| `dotsApp` | Dots | desktop → `.dots` (same bundles as ChatGPT) | yes | yes (explicit at `43`) | no | same two OpenAI ids (`12`) | none |
| `claudeApp` | Claude | desktop → `.claude` | yes | no | no | `com.anthropic.claudefordesktop` (`13`) | none |

`desktopProviders` (`WebProvider.swift:8`) is ChatGPT, Dots, Claude, Muse, Grok Bot, Wabi. Gemini is a `desktopApp` but omitted from that array.

`sharesOneConversation` (`WebProvider.swift:43`) is true for `os3`, `dotsApp`, `grokBotApp`, and `wabi`. Wabi still stores a per-comparison `wabi://` URL in `conversationURLs` (`WebServices.swift:231-244`). The flag still makes Wabi reuse one live page and one draft key (`WebAgentSession.swift:61-65`, `417-418`).

### Two forms, and how the user picks

| Product | Forms | How the user chooses |
| --- | --- | --- |
| Muse | `muse` website, `museApp` | Onboarding offers only the app (`Onboarding.swift:6-8` drops `settingsOnlyWebProviders`, `WebProvider.swift:6`). Website toggle is Settings → Web agents (`Views.swift:733-771`). App toggle is Settings → App Agents (`AppAgentsSettingsView.swift:18-65`). Both can be on. Separate state files. |
| ChatGPT | `chatgpt` website, `chatgptApp`, plus `codexCLI` | Same split. CLI is its own provider, not a mode of the website (`architecture.md:70-71`). |
| Claude | `claude` website, `claudeApp`, plus `claudeCode` | Same. |
| Dots | `dots` website, `dotsApp` | Website is settings-only. App is onboarding/App Agents. `dotsApp` continues the account dot; the website is a different session (`desktop-app-conversations.md:217-218`). |
| Grok Bot | `grokbot` webhook, `grokBotApp` | Webhook is Settings → Grok Bot (`Views.swift:736-737`), not an onboarding choice (`Onboarding.swift:7` excludes `.grokbot`). App is onboarding/App Agents and picks a sidebar bot (`DesktopAppSetupView.swift:45-58`). |
| Grok website | `grok` only | Settings → Web agents. No desktop provider. |
| Wabi | `wabi` only | Onboarding and App Agents. |
| Gemini | `geminiApp` only | Retained, not offered (`WebProvider.swift:9-10`, `Onboarding.swift:6-8`). |
| Hark, OS3 | website only | Onboarding (`offeredChoices` keeps them). |
| Codex CLI, Claude Code | CLI only | Onboarding. |

ChatGPT and Dots apps share one install. `bundleID` is the first id, `com.openai.codex` (`DesktopAppConversation.swift:15`). A running copy wins over the LaunchServices URL (`DesktopAppInstallation.swift:10-12`). `com.openai.chat` validates as installed (`16-18`) but the reader requires `AXWebArea` URL `app://-/index.html` or throws "This ChatGPT application version is not supported yet." (`ChatGPTAppObservation.swift:60`).

### Messages agents (not `WebProvider`)

| `OnboardingChoice` | raw | What it is |
| --- | --- | --- |
| `.instinct`, `.fo`, `.szn`, `.poke` | same | Named Contacts suggestions (`Onboarding.swift:52-58`). Poke also matches a Business chat named Poke (`Routing.swift:26-39`). |
| `.otherMessages` | `otherMessages` | Catch-all Messages agent (`Onboarding.swift:18`, `48-49`). |

Grid id is `.messages(UUID)` or `.featuredMessages(choice)` (`AgentGrid.swift:3-8`, `AgentGridModel.swift:22-35`). No bundle id. There is no per-agent "type" enum on `Agent`; the choice raw value is the label, and `messageAgentIDs` maps choice → `Agent.id` (`Onboarding.swift:132`, `208-210`).

OpenClaw and Hermes are `LocalAgentRuntime` (`LocalAgentDetection.swift:3-6`), grid id `.runtime`, not providers.

## 2. Availability signals

Nothing returns one enum of "ready / why not" per agent. The pieces below are separate.

### Messages

| Signal | Type / where | Refresh | Side effects |
| --- | --- | --- | --- |
| `databaseAvailable`, `databaseStatus` | `Bool`, `String`, `@Published` on `AppModel` (`AppModel.swift:10-11`) | 2s timer `refreshIfChanged` (`106`, `200-207`) if not busy/demo and (`!needsOnboarding` or Messages is in use). Also explicit `refresh()` | Opens `~/Library/Messages/chat.db` read-only (`226-227`, `MessagesDatabase.swift:15`). May `pinBusinessDestinations` and drop selection (`231-234`). No dialog. |
| `contactsAvailable` | `Bool` `@Published` (`AppModel.swift:22`, `247-252`) | Same 2s path via `refreshContactAccess` | Reads `CNContactStore.authorizationStatus` (`ContactSearch.swift:7`). No prompt. |
| `AppPermissions.history` | `AppPermissionStatus` `@Published` (`AppPermissions.swift:6-18`, `42`) | `refreshPermissions` on Settings/onboarding appear and `didBecomeActive` (`PermissionsSettingsView.swift:102-110`), and launch (`OnboardingController.swift:69-80`) | Fresh 1-byte read of `chat.db` (`182-199`). No prompt. Missing file → `.notConnected`. Permission error → `.denied`. Other → `.unavailable`. |
| `AppPermissions.contacts` | same enum (`44`) | same refresh | Maps `CNAuthorizationStatus` (`156-168`). `.restricted` cannot be enabled (`PermissionsSettingsView.swift:68`). Enable on `.notRequested` calls `connectContacts` → `requestAccess` (`AppPermissions.swift:83-90`, `AppModel.swift:254-263`). Denied opens Settings. |
| `AppPermissions.sending` | Automation (`45`) | refresh uses `AEDeterminePermissionToAutomateTarget` with `ask == false` (`79`, `171-179`) | If Messages is not running, status is `.needsMessages` and Messages is not opened (`73-75`). Enable on `.needsMessages` opens Messages with `activates = false` (`111-113`, `145-148`), then may prompt (`121`). |
| `ChatResolver.resolve` / `status` | `Chat?` / `String` (`Routing.swift:41-53`) | Computed when called (`messageConnectionStatus`, `AppModel.swift:384-386`) | None. Strings: "Connect Messages", "Connected", "No supported conversation found", "Conversation found · sending unavailable", Business variants, "Saved conversation unavailable · choose again", "Multiple Business conversations found · sending unavailable". |
| `Chat.eligible` | `Bool` (`Models.swift:30-36`) | on the `Chat` | One-to-one iMessage with an email or phone, or a verified Business scripting id (`17-28`). |
| `Agent.destination` | `MessagesDestination?` (`Models.swift:54`) | saved | A saved chat must match exactly or resolve returns nil (`Routing.swift:11-13`). |
| `AppState.selection` | `Set<UUID>` (`Models.swift:291`) | user / `retainAvailableSelection` (`311-316`) | Not "can send". Shared-send recipients. |
| `Member.submission` | `Submission` `.ready/.sending/.submitted/.failed/.uncertain` (`Models.swift:120-129`, `142`) | during send; `.sending` becomes `.uncertain` on load (`330-332`) | Per recipient of one comparison, not a live Messages-app probe. |
| `Member.error` | `String?` (`144`) | with submission | Text only. |
| `busy` | `Bool` `@Published` (`AppModel.swift:13`) | around Messages send (`412-420`) | While true, `refresh()` returns immediately (`210`) and `start` returns (`415`). |
| Grid | `AgentGridLayout.visibleIDs` (`AgentGrid.swift:31`) | saved in `AppState.agentGrid` (`Models.swift:297`) | `shown` hides Messages ids absent from `availableMessages` (`AgentGrid.swift:51-58`). Featured Instinct/Fo/Szn (`27-29`). |
| Onboarding | `discoveredMessageAgentIDs`, `excluded…`, `messagesAutomaticallyAdded`, `completed`/`skipped` (`Onboarding.swift:126-131`) | discovery when messaging section is approved (`OnboardingController.swift:486-526`) | Adds existing routable contacts. Does not create Contacts (`484-485`). Unroutable agents are skipped (`502`). |

`OnboardingPermissionReadiness.messagingReady` is FDA + Contacts + Automation (`Onboarding.swift:98`). It is computed, not stored (`OnboardingController.swift:53-59`). Saved `approvedPermissionSections` is the last review, not a live grant (`Onboarding.swift:172-173`, `OnboardingController.swift:82-83`).

### Websites (`muse`, `chatgpt`, `claude`, `grok`, `dots`, `os3`, `hark`)

| Signal | Type / where | Refresh | Side effects |
| --- | --- | --- | --- |
| `WebPageSnapshot.ready` | `Bool`, default false (`WebServices.swift:299-304`) | `@Published snapshot` (`WebAgentSession.swift:9`) | From page JS `status()` (`WebPageScript.swift:99-117`). |
| `snapshot.signedIn` | `Bool?` (`302`) | same | `false` if a login button matches; `true` if account node exists; else `nil` (`101-103`). Unknown is not signed-out. |
| `snapshot.signedOut` | `Bool?` (`310`) | Dots only (`117`) | Login visible and no account node. |
| `snapshot.reason` | `String` (`304`) | same | Not a chat URL; sign-in; unrecognized layout; dialog; generating; missing editor (`109-116`). Hark forces `ready: false` (`WebPageScript.swift:20-23`). |
| `snapshot.draft` / `draftAvailable` | `String` / `Bool?` (`305-306`) | same | Non-empty draft blocks shared send (`WebAgentSession.swift:595-596`). |
| `checkSignIn()` | `Bool?` (`646-667`) | On demand. Onboarding `refresh` (`OnboardingController.swift:459-461`). `WebAgents.signInRequired` (`WebAgents.swift:146-155`) | Calls `connect()` (loads the page). Up to 40×250ms. Runs `signInStatus` JS. No submit. Returns `nil` for every native provider (`647`). |
| `connected` | `Bool` `@Published` (`11`) | `connect()` sets true once (`322-324`) | Means the session started, not that the user is signed in. |
| Poll | `Task` (`341-345`) | Every 1s while connected, websites only | `refreshPages` → `inspect` JS (`719-743`). ChatGPT/Dots also run `configureInitialLayout` (`737-738`). May restore a draft into the editor (`758+`). Does not click Send. |
| `isEnabled` / `state.selected` / `state.websiteEnabled` | `Bool` (`255`, `WebServices.swift:58`, `73`) | saved | Selected + enabled + `supportsSharedSubmissions` = shared-send candidate (`WebAgents.swift:19`). |
| `isSending` | `Bool` `@Published` (`10`) | during `send` (`961-962`) | Blocks another send (`956`). |
| `loading` | `Bool` `@Published` (`12`) | navigation (`1826-1834`) | |
| `error` | `String?` `@Published` (`13`) | overwritten on the next success/failure (`541-566`, `1035`) | Not an enum. Cleared when `openComparison` succeeds (`548`). |
| `storageFailed` / `isStorageAvailable` | private / `Bool` (`129`, `143`) | load (`196`) | Blocks send (`957`). |
| `isReadyForOnboarding` | `Bool` (`153-157`) | computed | Enabled, connected, not loading, page not loading, host matches, `signedIn == true`. |
| `needsConversationLink` / `canLinkCurrentConversation` | `Bool` (`421-436`) | computed | Blocks treating the page as the saved chat. Link does not click Send (`450-451`). |
| Unresolved attempt | `WebSendStatus.isUnresolved` = attempting/waiting/uncertain (`WebServices.swift:6`) | saved on the session | `hasUnresolvedSend` blocks the same text (`WebServices.swift:270-271`, `WebAgentSession.swift:960`). |

`signInRequired` ignores native sessions (`WebAgents.swift:147`). A desktop app never fails that gate.

### Desktop apps

| Signal | Type / where | Refresh | Side effects |
| --- | --- | --- | --- |
| `desktopInstallation` | `DesktopAppInstallation` `@Published` (`WebAgentSession.swift:101`). `isInstalled` = `url != nil`. `isRunning` = installed and `processID != nil` (`DesktopAppInstallation.swift:4-8`) | `refreshDesktopInstallation` (`1236-1245`): init (`208`), `setEnabled` (`259`), inside desktop refresh, Settings/onboarding `.task` and `didBecomeActive` (`AppAgentsSettingsView.swift:21-24`, `DesktopAppSetupView.swift:152-158`, `OnboardingController.swift:438-443`) | **No launch.** `NSRunningApplication` + `NSWorkspace.urlForApplication`, then bundle id + executable check (`DesktopAppInstallation.swift:26-31`, `15-18`). Not on the 2s timer. Stale until the next call. A change sets `desktopReady = false` and clears `grokBotNames` (`1239-1240`). |
| `desktopReady` | `Bool` `@Published` (`91`) | Set true only after a successful `refreshDesktop` or `connectDesktopConversation` (`1410-1412`, `1446+`) | Cleared at the start of every `refreshDesktop` (`1424`) and when installation changes. |
| `desktopStatus` | `String` `@Published` (`100`) | same | Human text, not an enum. Not installed / not running / checking / connected / error string (`1242-1244`, `1376`, `1519`). |
| `snapshot.ready` / `reason` for desktop | derived in `updateNativeSnapshot` (`1525-1534`) | after install/refresh/connect/send | `ready` = enabled, storage ok, process running, `desktopReady`, no unresolved desktop attempt. `reason` = enable text, incomplete-request text, or `desktopStatus`. |
| `state.desktopConversation` | `DesktopConversationBinding?` (`WebServices.swift:62`) | saved on successful connect (`1408`) | Name only (`DesktopAppConversation.swift:18-20`). Not proof the window is open now. |
| `connected` | `Bool` | `connect()` before any app check (`322-336`); also set true on connect success (`1410`) | True does not mean the app is running. |
| `isEnabled` | requires `enabled == true` and `isAvailableInBuild` (`255`) | `setEnabled` refuses if not installed (`257-260`) | Disabling clears `selected` and cancels the native task (`265-267`). |
| `canSubmitNativePrompt` | `Bool` (`146-150`) | computed | Composer enable (`WebServicesView.swift:802`). True if `snapshot.ready` **or** (installed and a saved binding and no incomplete request), even when the app is not running. Send then launches. |
| `isReadyForOnboarding` | `Bool` (`153-155`) | computed | Native path is `snapshot.ready` only. No separate sign-in bool. |
| `desktopConnectionConfirmation` | `String?` (`1189-1198`) | computed | Shown only when onboarding-ready and `desktopReady` and a binding exists (`DesktopAppSetupView.swift:28`). |
| `desktopRecoveryMessage` | `String?` (`92-98`) | computed | Nil if disabled, no desktop provider, or `desktopReady`. If not installed: "Install …". If `error` nonempty: that string. Otherwise nil ("stale readiness is normal"). Not-running with an empty `error` shows no recovery row (`WebServicesView.swift:722-723`). |
| `error` | `String?` | set by failed launch/connect/send (`530`, `1266`, `1414`, `1745`) | `refreshDesktop` failure writes `desktopStatus` only (`1517-1519`), not `error`. Success of `refreshDesktop` does not clear `error`. The pane hides `error` when it equals `desktopRecoveryMessage` (`WebServicesView.swift:653`). |
| `incompleteDesktopAttempt` / `hasIncompleteNativeRequest` | `WebSendAttempt?` / `Bool` (`1548-1571`) | saved attempts | For a desktop provider, **any** unresolved attempt blocks, across comparisons (`1570-1571`). |
| `isSending`, `loading`, `refreshing` | `Bool` (`10`, `12`, `131`) | launch and connect set `loading` (`1286`, `1378`). `refreshDesktop` sets `refreshing` (`1420`) | `sendNative` refuses while `loading` (`1588`). `refreshDesktop` returns if `loading` (`1419`). |
| `grokBotNames` | `[String]` `@Published` (`102`) | `refreshGrokBots` (`1201-1227`) | Calls `availableGrokBots` (AX + driver). Does not send. Requires `isRunning` or clears the list (`1204`). Occupies the Grok driver (`DesktopAppConversation.swift:373-375`). |
| Per-app bindings | see §3 | during prepare/send | Not a readiness flag. Missing/foreign binding throws a string. |
| Embedded driver | no `@Published` readiness | `EmbeddedCuaDriver.connection()` on first `call` (`DesktopAppConversation.swift:340`, `EmbeddedCuaDriver.swift:63-81`) | Starts `cua-driver serve --embedded` (`101-102`). Re-reads AX + screen-capture **without prompting** (`52-55`). Mismatch or failed `check_permissions` / `health_report` throws and discards the process (`122-125`, `136-164`). `CuaPermissionsController.installed` is only `findDriver() != nil` (`CuaPermissions.swift:50`, `75`). |
| Permission for apps | `CuaPermissionsController.hostAccessibility`, `windowCapture`: `CuaPermissionStatus` `@Published` (`CuaPermissions.swift:7-11`, `25-26`). `OnboardingPermissionReadiness.appsReady` = both allowed and driver file present (`Onboarding.swift:99`) | Same permission refresh as Messages. Not inside `WebAgentSession` | `refresh` uses `AXIsProcessTrusted()` and `CGPreflightScreenCaptureAccess()` (`75-79`). No prompt. `unknown` and `notInstalled` exist on the enum (`7-8`) and are not assigned by `refresh`. Enable methods can prompt (`57-66`) but Settings uses the drag guide instead (`PermissionsSettingsView.swift:79-91`, `120-131`), which opens System Settings (`MessagesAccessGuide.swift:68`). |
| AX read gate | `DesktopAccessibility.capture` (`DesktopAccessibility.swift:153-154`) | every native metadata read | Throws if not trusted. No prompt. |
| Sign-in | **no desktop `signedIn` field** | | `target` drops windows titled `"Log in"` (`DesktopAppConversation.swift:453`). If that leaves zero or many windows, the error is "Keep one main window open and dismiss any dialogs" (`455-456`), not "signed out". Not-running copy says "Open …, sign in…" (`440-441`) without inspecting login UI. ChatGPT dialogs: `AXDialog`/`AXSheet` (`ChatGPTAppObservation.swift:68`). Dots setup headings are a different error (`77-85`, `148`). |

`refreshDesktop` (`1418-1522`) is **not** on a timer. Desktop `connect` refreshes once (`335-336`). It runs again from `openComparison`, `reload`, and `sendNative` (`537`, `352`, `1613`). It calls `list_apps` / `list_windows` / AX. It does not launch. It can still change the app:

- Muse with a comparison id calls `museApp.prepare`, which clicks "New side chat" when no thread is saved (`1496-1499`, `MuseAppConversation.swift:209-217`).
- Wabi with a comparison id calls `wabiApp.prepare`, which clicks "New chat" when no URL is saved (`1473-1475`, `WabiAppConversation.swift:249-258`).
- ChatGPT/Dots `checkAvailable` calls `open` when kind is Dots or `dotSetup` (`ChatGPTAppConversation.swift:201-206`, `125-176`), which clicks sidebar/mode controls.
- Claude `checkAvailable` only reads (`ClaudeAppConversation.swift:97-115`).
- Grok `checkGrokBot` reads (`DesktopAppConversation.swift:402-409`).
- Gemini `checkAvailable` is unreachable while `isAvailableInBuild` is false (`1419`, `1142`).

Explicit Connect launches first: `prepareDesktopConnection` → `launchDesktopAppForConversation` (`1259-1261`, `DesktopAppSetupView.swift:174-184`).

### CLIs (`codexCLI`, `claudeCode`)

| Signal | Type / where | Refresh | Side effects |
| --- | --- | --- | --- |
| `installedAgent` | private `InstalledPersonalAgent?` | `refresh()` (`698-707`) | `LocalPersonalAgent.discover()` walks PATH and `isExecutableFile` (`LocalPersonalAgent.swift:227-251`). Does not run the CLI. |
| `accountStatus` | `PersonalAgentAccountStatus` `@Published` (`WebAgentSession.swift:103`): `.subscription/.apiKey/.other/.signedOut/.unknown` (`LocalPersonalAgent.swift:135-145`) | same `refresh`, and `PersonalAgentController.refreshAccounts` (`PersonalAgentController.swift:36-48`) when the local-agent settings view appears or the app becomes active (`WebServicesView.swift:479-488`) | Runs `codex login status` or `claude auth status`, timeout 10s (`167-195`). No login UI. |
| `snapshot.ready` | (`1543`) | `updateNativeSnapshot` | Enabled, storage ok, and status is subscription, api key, or other. `.signedOut` and `.unknown` are not ready. Reason is `accountStatus.label` or the install string (`1544`). |
| `PersonalAgentController.installed` / `accounts` | `@Published` (`7-10`) | settings view only | Separate from the session snapshot. Session `refresh` is once on `connect`, no poll (`335-336`). |
| `OnboardingController.compatibility` | `[WebProvider: Bool]` `@Published` (`OnboardingController.swift:9`) | onboarding check (`456-458`, `590-598`) | Claude Code only: runs `claude --help` and looks for `--permission-prompts` (`LocalPersonalAgent.swift:154-164`). Codex returns nil from that function (`593`). |
| `checkNativeAccount` | `Bool` (`677-686`) | on demand | `connect` + `refresh`. True when `snapshot.ready`. |
| `supportsConfiguredConversation` | `Bool` | onboarding only | Not stored on the session. |
| OpenClaw/Hermes `detectedLocalAgents` | `[InstalledLocalAgent]` (`PersonalAgentController.swift:13`) | onboarding `.task` / active (`OnboardingView.swift:526`) and the settings refresh above | PATH lookup only (`LocalAgentDetection.swift:45-54`). Comment: does not launch or read config (`49`). No account status. `setUp` opens Terminal (`57-64`). |

Cursor, Gemini CLI, Pi, Grok CLI, Hermes exist on `PersonalAgentProvider` (`LocalPersonalAgent.swift:5-6`). Cursor and Grok CLI have `unavailabilityReason` and are excluded from discover (`34-42`, `247`). They are not `WebProvider`s. Pi/Gemini/Hermes can be discovered for reports; configured chat is Codex or Claude only (`260`).

### Grok Bot webhook (`grokbot`)

| Signal | Type / where | Refresh | Side effects |
| --- | --- | --- | --- |
| `grokBotIsConfigured` | `Bool` (`1921`) | credentials in memory | `fixture \|\| credentials != nil`. Not "tunnel up". |
| `grokBotConnectionReady` | private `Bool?` | `startGrokBotConnection` (`2007`) | Nil until the tunnel starts. `refreshGrokBot` starts it when enabled (`2029-2031`). |
| `grokBotReplyURL` | private `URL?` | tunnel (`2007`) | Loopback receiver + cloudflared (`1986-2004`). |
| `grokBotConnectionActivity` | `GrokBotConnectionActivity?` `@Published` (`120`, `GrokBotService.swift:27-34`) | during key read, key save, tunnel start | `snapshot.reason` uses `activity.title` (`1539`). Key read waits up to 15s; tunnel up to 90s (`36-39`). |
| `grokBotNeedsKeychainRetry`, `grokBotRemembersConnection` | `Bool` `@Published` (`121-122`) | restore (`1931-1946`) | Read can set `error`. |
| `configuringGrokBot` | `Bool` (`124`) | activity != nil | `snapshot.ready` is false while configuring (`1538`). |
| `snapshot.ready` | (`1538-1539`) | | Enabled, storage ok, not configuring, credentials and `connectionReady == true` (or fixture), no unresolved attempt. |
| `hasPendingGrokBotRequests` | `Bool` (`1922-1924`) | attempts | Blocks `configureGrokBot` (`1951`). |
| `state.grokBotRememberedConnection` | `Bool?` (`WebServices.swift:61`) | saved | `false` skips key restore (`204`). |
| Poll | fixture only, 3s (`327-332`) | production `connect` refreshes once (`326`) | Receipts are push callbacks (`1986-1988`). UI says keep the Mac awake (`GrokBotSettingsView.swift:169`, `WebAgentSession.swift:2100`). |

`error` on tunnel drop (`1997-2001`) marks attempting/waiting attempts `.uncertain` (`2014-2016`).

### Shared grid / onboarding (all kinds)

| Signal | Meaning | Not the same as |
| --- | --- | --- |
| `AgentGridLayout.visibleIDs` (`AgentGrid.swift:31`) | Picker membership | Enabled, signed in, or able to send |
| `isVisibleInAgentGrid` (`AgentGridModel.swift:108`) | id is in that list | |
| `agentGridCatalog` (`37-38`) | Settings-only websites appear only if `isEnabled`. Other available providers always appear | |
| `quickChatAgents` (`AppModel.swift:466-477`) | New Chat With list | Ready now. A native agent is included if onboarding completed the same `sessionID`, or `isReadyForOnboarding`, or `signedIn == true`, or it has URLs/attempts, **or** `usesNativeConversation && enabled == true` |
| `WebAgents.selected` (`WebAgents.swift:19`) | Enabled, `state.selected`, supports shared sends | Ready |
| `state.selected` (`WebServices.swift:73`) | Shared-send checkbox. Decode default true (`108`) but new sessions force false (`WebAgentSession.swift:175`) | |
| `OnboardingState.completed` / `skipped` (`Onboarding.swift:130-131`) | Setup progress. `recheckConnections` clears `completed` (`320-323`) | Live OS permission or app running |
| `permissionsSkipped` (`120`) | User skipped Allow access. Does not grant (`153-155`) | |
| `needsOnboarding` (`AppModel.swift:42`) | Unfinished stage or `permissionsCompleted == false` | |
| `canStartNewBlast` (`441-442`) | Not onboarding, no model error, not `busy` / `webBroadcastBusy`, no session `isSending` | Per-agent ready |
| `webBroadcastBusy` (`14`) | Shared send in flight (`WebServicesView.swift:303-306`) | |

## 3. State types added or changed in 0.10.0

Diff base `b8bf614`. `Models.swift` (`AppState`, `Comparison`, `WebSendAttempt`) is unchanged.

### `WebWorkspaceState` (`WebServices.swift:55-68`) — new Codable fields

| Field | Type | Line |
| --- | --- | --- |
| `websiteEnabled` | `Bool?` | `58` |
| `desktopConversation` | `DesktopConversationBinding?` | `62` |
| `claudeConversations` | `[String: ClaudeConversationBinding]` | `63` |
| `chatgptConversations` | `[String: ChatGPTConversationBinding]` | `64` |
| `geminiPreferences` | `GeminiPreferences` | `65` |
| `geminiComparisonPreferences` | `[String: GeminiPreferences]` | `66` |
| `geminiConversations` | `[String: GeminiConversationBinding]` | `67` |
| `museAppConversations` | `[String: MuseSideChatBinding]` | `68` |

Decode defaults: missing `websiteEnabled` is nil (websites stay enabled). Missing maps become `[:]`. Missing Gemini prefs become `.init()` (`89-100`).

Nested Codable types:

| Type | Fields | Line |
| --- | --- | --- |
| `DesktopConversationBinding` | `name: String` | `DesktopAppConversation.swift:18-20` |
| `ClaudeConversationBinding` | `comparisonID: UUID`, `url: URL?`, `firstPrompt: String?` | `ClaudeAppObservation.swift:12-15` |
| `ChatGPTConversationBinding` | `comparisonID`, `kind: ChatGPTAppKind`, `title: String?`, `firstPrompt: String?`, `fallbackTitle: String?` | `ChatGPTAppObservation.swift:3-10` |
| `ChatGPTAppKind` | `chatgpt`, `dots` | `ChatGPTAppObservation.swift:3` |
| `GeminiPreferences` | `mode: GeminiMode`, `model: String?`, `thinking: String?` | `GeminiAppObservation.swift:7-10` |
| `GeminiMode` | `chat`, `task` | `GeminiAppObservation.swift:3` |
| `GeminiConversationBinding` | `comparisonID`, `mode`, `title?`, `firstPrompt?`, `fallbackTitle?` | `GeminiAppObservation.swift:16-21` |
| `MuseSideChatBinding` | `comparisonID`, `threadID: UUID?`, `title: String` (`url` is computed, not stored) | `MuseAppObservation.swift:3-7` |
| Wabi destination | existing `conversationURLs[comparisonUUID]` (`WebServices.swift:77`, `231-244`). No new field | |

`GrokBotNativeState` (`name`, `draft`, `composerFocused`) is Codable (`GrokBotAppProfile.swift:3-6`) but not a `WebWorkspaceState` field. It is an in-memory AX read.

### `WebSendAttempt` — no new fields

Existing fields used as desktop receipts (`WebServices.swift:26-41`): `conversationURL` (Claude `1723`, Muse `1769`, Wabi attempt `1623`), `recoveryConversationURL` (Muse candidate before the outgoing message is confirmed, `1752-1759`). `receiptContext` / `manualContext` stay website receipt structs (`48-52`). No desktop-specific attempt field was added.

### `OnboardingState` — new Codable fields (`Onboarding.swift:119-127`)

| Field | Type | Line |
| --- | --- | --- |
| `permissionsCompleted` | `Bool?` default false | `119` |
| `permissionsSkipped` | `Bool?` | `120` |
| `approvedPermissionSections` | `Set<OnboardingPermissionSection>?` | `121` |
| `messagesAutomaticallyAdded` | `Bool?` | `125` |

`OnboardingPermissionSection` is `messaging`, `apps` (`74-75`). `OnboardingPermissionReadiness` is not Codable (`79`).

`OnboardingChoice` gained raw values `chatgptApp`, `dotsApp`, `claudeApp`, `museApp`, `grokBotApp`, `wabi`, `geminiApp` (`4`). Old files still decode the previous cases.

### `AppState`, `Comparison`, `AgentGridLayout`

No new stored fields. `AgentGridLayout` still stores only `visibleIDs` (`AgentGrid.swift:31`). `shown(in:availableMessages:)` gained an optional Messages filter (`51-58`). `AppState` still holds `onboarding` and `agentGrid` (`Models.swift:296-297`). `Comparison` still holds `webProviders` and `webAgentIDs` (`Models.swift:225-226`). Desktop agents use the same `WebAgentID` as websites.

### Identity

Desktop providers do not get instance UUIDs. One session per case, file `web-<rawValue>.json`. `WebAgentID.id` for those is the raw value (`WebProvider.swift:96`). Copies remain website-only.

## 4. Desktop send path

Entry: shared send `WebAgents.send` (`208-216`) or the pane `sendNative` (`1586`). Fixture mode sleeps 350ms and never touches the app (`1639-1660`).

1. **Gates** (`1587-1593`): enabled, not shutting down, not already `isSending`, storage ok, nonempty text, desktop not `loading`, no unresolved attempt. Failure returns nil or sets `error`. No attempt row yet.
2. **`isSending = true`** (`1594-1596`) until the function returns.
3. **Launch** (`1598-1603`): `launchDesktopAppForConversation` (`1273-1323`).
   - Not installed → `WebSessionFailure.notReady(desktopStatus)` (`1280`).
   - Already running: `desktopDriver.target`. If that returns, stop. No activate (`1291-1295`).
   - Otherwise `desktopApps.open`: `NSWorkspace.openApplication`, **`activates = true`** (`DesktopAppInstallation.swift:32-35`).
   - Poll 200ms up to **10s** for `isRunning` and `target` (`1301-1316`).
   - Timeout: "opened, but its main window is not ready…" (`1317`). Draft kept. No attempt (`1602-1603` returns nil).
4. **Attempt row** inserted `.preparing` (`1605-1608`), comparison id assigned.
5. **`refresh()` → `refreshDesktop`** (`1613`, `691-692`). Must leave `snapshot.ready` and an empty draft (`1615-1617`).
6. **Status `.attempting`**, save (`1621-1624`). `started = true`. After this, failure becomes `.uncertain` unless it is `GeminiSelectionError` (`.notSent`) (`1740`).
7. **Adapter** (`1662-1711`):
   - Muse: `museApp.reply` (`1662-1672`).
   - Wabi: `wabiApp.reply` (`1674-1676`). Requires a prepared URL.
   - Claude: `claudeApp.reply` (`1689-1697`).
   - ChatGPT/Dots: `chatgptApp.reply` (`1699-1707`).
   - Grok Bot app: `desktopDriver.reply` (`1709-1711`).
   - Gemini: `geminiApp.reply` is in the source (`1678-1687`) and does not run when `isEnabled` is false.
8. **Observe**. `DesktopAppWorkflow.reply` (`DesktopAppWorkflow.swift:80-100`): one `submit`, then poll. Default interval **1s**, stable **3s**, timeout **180s** (`DesktopAppConversation.swift:309-313`). Transient AX/incomplete errors reset the stable timer (`91-95`). Timeout does not resend (`100`).
9. **Success**: append user + assistant locally, clear draft if it matches, status `.observed` (`1719-1730`). Detail says the reply was stable for three seconds and the app may continue (`1729`).

### Window, focus, Space, how long it blocks

`target` (`DesktopAppConversation.swift:438-458`):

- `list_apps`: exactly one running process for the first bundle id that has any (`440-445`). Extra copies: "Quit extra copies…". No window is inspected.
- `list_windows` candidates (`449-454`): `layer == 0`, width and height `>= 400`, (`is_on_screen != false` **or** `space_ids` nonempty), title nonempty except Gemini/ChatGPT/Dots/Claude, title not `"Log in"`.
- Exactly one candidate (`455-457`).

Not required by this function: frontmost, unminimized, or current Space. Off-screen windows **with** `space_ids` are kept. Comment: those are another desktop; helpers have neither a surface nor a Space (`447-448`). `DesktopNativeWindowLookup` reads AX including other Spaces via a remote token and "never activates or moves" the window (`DesktopNativeWindowLookup.swift:15-17`, `31-32`).

No source check for miniaturized. Whether a minimized window is `is_on_screen == false` with empty `space_ids` (and therefore dropped) is **UNCERTAIN**.

No source check that the Mac is awake, unlocked, or that the display is on. Those states are **UNCERTAIN**. The webhook UI tells the user to keep the Mac awake (`GrokBotSettingsView.swift:169`). The desktop send path does not.

Focus:

- Launch of a closed app, or of a running app whose `target` failed: **activates the app** (`DesktopAppInstallation.swift:34`).
- If `target` already succeeds: no activate.
- Clicks, typing, and Return use `delivery_mode: background` (`DesktopAppConversation.swift:480-482`, `562`; `ChatGPTAppConversation.swift:86`, `98`; `MuseAppConversation.swift:43`, `73`, `257`, `318`; `WabiAppConversation.swift:206`).
- A driver refusal (`refusal`, `status == refused`, `isError`, `error`) throws and does not switch to foreground (`DesktopAppConversation.swift:358-359`).
- ChatGPT still takes a window PNG and may pass `x`/`y` for the first chunk (`ChatGPTAppConversation.swift:94-107`, `254-271`). Muse focuses with a background click that includes a `capture_id` (`MuseAppConversation.swift:73`). That is still `delivery_mode: background`.

Screenshots are per target window (`get_window_state` `include_screenshot`, `screenshot_out_file`) (`DesktopAppConversation.swift:460-465`), deleted after (`ChatGPTAppConversation.swift:96`, `549`). They are not the chat-share ScreenCaptureKit path (`architecture.md:273`).

Block time, all on `isSending`:

- Embedded driver start up to 10s (`EmbeddedCuaDriver.swift:43`, `113-118`).
- Each driver `call` timeout 30s (`DesktopAppConversation.swift:313`, `347`).
- Window snapshot `timeout_ms` 10_000 (`465`).
- Launch wait 10s (`WebAgentSession.swift:1301`).
- Reply wait 180s (`DesktopAppConversation.swift:312`, `DesktopAppWorkflow.swift:86-100`).
- Typing is 256-UTF-16 chunks plus Shift-Return (`DesktopAppWorkflow.swift:25-34`) with per-chunk readback (ChatGPT `checkedDraft`; Grok 3s, `DesktopAppConversation.swift:512`).

A send can hold the session for several minutes. Cancel sets `requestCancelled` and cancels the task (`1574`, `1717`). Started work becomes `.uncertain` with the draft kept (`1741-1745`). Cancel does not stop the other app (`desktop-app-conversations.md:313` matches `cancelNativeRequest`, which only cancels the local task).

### Two sends, same app

- `WebAgents.executionGroups` puts **every** desktop provider in one serial group (`WebAgents.swift:170-178`). ChatGPT's send finishes before Claude's starts. Websites stay parallel.
- `sendNative` if `isSending` returns nil (`1587`).
- Each adapter has `occupied`. ChatGPT and Dots share one `ChatGPTAppConversation.occupied` (`ChatGPTAppConversation.swift:9`, `195-196`, `242-243`). A second call throws "ChatGPT is already handling a request."
- Claude, Wabi, Muse, Gemini each have their own `occupied`. Grok uses `DesktopAppConversation.occupied` per `DesktopAppProvider` (`307-308`, `543-544`).
- Muse `checkAvailable` checks `occupied` but does not set it (`MuseAppConversation.swift:131-132`). `prepare` and `reply` do (`159-160`, `223-224`).
- One unresolved attempt blocks every later desktop send for that provider, any comparison (`1570-1571`, `1590-1592`). Another comparison can acknowledge that attempt (`1553-1559`, `WebServicesView.swift:784-789`). No automatic resend.

ChatGPT and Dots are two sessions and one process. They are serialized by the group and by the shared actor. Two running PIDs of the same bundle never get input (`DesktopAppConversation.swift:443-444`).

### Per-app observation (ChatGPT, as the sample)

`read` is AX via `ChatGPTAppProfile.capture`, 3 tries, 1s apart (`ChatGPTAppConversation.swift:13-23`). `snapshot` is the driver tree, used to bind `element_token` and screenshot geometry (`61-78`). Reply poll is the workflow 1s/3s/180s (`278-292`). Sender boundaries come from AX classes (`message-bubble` / transcript), not OCR (`ChatGPTAppObservation.swift:103-119`). Generating is a Stop button (`102`). Empty draft and not generating are required before input (`25-26`, `237-238`). Submit is one background click on "Send" (`278-279`). Unknown click results are not retried (`113-114` swallows the error after a cancellation check; the next `checked`/`observe` must see the new message).

Grok Bot replies use the driver AX tree plus a second native walk (`DesktopAppConversation.swift:364-371`, `560-568`), same 1s/3s/180s poll.

## 5. Remote-availability gaps

A remote client cannot ask "for each agent, can it take a message now, and why?"

| Gap | Where |
| --- | --- |
| No function returns per-agent readiness plus a reason enum. Closest is `snapshot.ready` (`Bool`) and `snapshot.reason` (`String`), and only after something has called `refresh`. | `WebAgentSession.swift:1525-1545`, `WebServices.swift:299-304` |
| `canSubmitNativePrompt` is true when a desktop binding exists and the app is merely installed, so the composer lies about "ready now". | `WebAgentSession.swift:146-150`, `WebServicesView.swift:802` |
| `connected` means `connect()` ran, including before any app or sign-in check. | `WebAgentSession.swift:322-336` |
| Desktop/CLI/webhook sessions do not poll. `desktopReady` and `isRunning` stay until the next explicit refresh, view appear, or `didBecomeActive`. The 2s timer only re-reads Messages. | `335-336`, `AppModel.swift:106`, `200-207`, `AppAgentsSettingsView.swift:21-24` |
| Installation is not pushed. Quitting the target app is invisible until `refreshDesktopInstallation`. | `DesktopAppInstallation.swift:26-31`, `WebAgentSession.swift:1236-1245` |
| Permission state lives on `AppPermissions` and `CuaPermissionsController`, composed in the onboarding controller. It is not on `WebAgentSession`, not in `state.json` as a live grant, and not consulted by `sendNative`. Send finds out when AX or the driver fails. | `OnboardingController.swift:53-59`, `CuaPermissions.swift:41-54`, `WebAgentSession.swift:1586-1603`, `DesktopAccessibility.swift:154`, `EmbeddedCuaDriver.swift:52-55` |
| `approvedPermissionSections` is the last skip/complete snapshot. Startup rechecks and may clear `permissionsCompleted`, but only inside the Mac app process. | `Onboarding.swift:172-173`, `OnboardingController.swift:69-102` |
| `CuaPermissionStatus.unknown` and `.notInstalled` are never set by `refresh`. Driver-missing is a separate `installed` bool plus `message`. | `CuaPermissions.swift:7-11`, `41-54` |
| No desktop sign-in bool. Logged-out UI collapses into window-count and AX parse errors. | `DesktopAppConversation.swift:438-457`, `ChatGPTAppObservation.swift:56-68` |
| `checkSignIn` returns nil for every native provider, and `signInRequired` therefore cannot block a desktop send. | `WebAgentSession.swift:647`, `WebAgents.swift:146-155` |
| `desktopRecoveryMessage` is nil when not ready and `error` is empty (except not installed). Not-running is only `desktopStatus`, shown in setup when `!desktopReady`, not as a typed reason. | `WebAgentSession.swift:92-98`, `DesktopAppSetupView.swift:149`, `WebServicesView.swift:722-723` |
| `refreshDesktop` failure does not set `session.error`. A later success does not clear an old `error`. The pane suppresses `error` when it equals the recovery string. | `1517-1519`, `1414`, `WebServicesView.swift:653` |
| Strings are the reason. `DesktopAppError.unavailable(String)` and `WebSessionFailure` are not a stable code. | `DesktopAppConversation.swift:23-29` |
| Onboarding `completed` is cleared for desktop choices that are not `isReady` at `begin`, and `recheckConnections` clears all `completed`. Neither is a live query API. | `OnboardingController.swift:186-190`, `Onboarding.swift:320-323` |
| Grid visibility, `selected`, and `enabled` are three different flags. `quickChatAgents` treats enabled native agents as listable even when `snapshot.ready` is false. | `AgentGrid.swift:31`, `WebServices.swift:73`, `WebAgentSession.swift:255`, `AppModel.swift:466-477` |
| Website vs app vs webhook vs CLI for the same product are different sessions. No field says which one the user intends. | `WebProvider.swift:4-17`, `Views.swift:723-737` |
| `sharesOneConversation` is true for Wabi even though each comparison has its own URL. A client that treats the flag as "one shared thread" mis-reads Wabi. | `WebProvider.swift:43`, `WebServices.swift:231-244` |
| Gemini is disabled by `isAvailableInBuild` but still decodes and still has connect/send code behind `isEnabled`. | `WebProvider.swift:10`, `WebAgentSession.swift:255`, `1142`, `1419` |
| CLI account status on the session updates only when that session `refresh`es. The settings controller has a second copy, refreshed when its view is open. They can disagree. | `WebAgentSession.swift:698-707`, `PersonalAgentController.swift:36-48`, `WebServicesView.swift:479-488` |
| OpenClaw/Hermes have install detection only. No signed-in, no busy, no send. | `LocalAgentDetection.swift:45-54` |
| Messages "can send" is `databaseAvailable` + Contacts authorized + Automation allowed + `ChatResolver.resolve` + not `busy` + member submission not in flight. No single function. Automation is `.needsMessages` when Messages is closed, which is not `.denied` (`requiresReview` treats `.needsMessages` as ok). | `AppPermissions.swift:52-55`, `73-75`, `Routing.swift:41-43`, `AppModel.swift:389-409` |
| Unresolved desktop attempts are per session file, not a process-wide lock list, except the in-memory `occupied` sets which a remote client cannot read. | `WebAgentSession.swift:1570-1571`, `ChatGPTAppConversation.swift:9` |
| Driver generation is private. In-flight calls keep the old socket and are not replayed. There is no published "driver ready" flag. | `EmbeddedCuaDriver.swift:63-76`, `168-171` |

## 6. Headless risks (desktop apps, remote trigger)

| Risk | What the source does | Line |
| --- | --- | --- |
| App launch | Closed app, or running app whose window fails `target`, is opened with `activates = true`. Shared send passes `startNativeApps: true`, so the first prompt launches. | `DesktopAppInstallation.swift:32-35`, `WebAgentSession.swift:1273-1299`, `WebServicesView.swift:313`, `WebAgents.swift:193` |
| Focus theft | That open activates the app. Background input does not call activate when `target` already works. | `DesktopAppInstallation.swift:34`, `DesktopNativeWindowLookup.swift:31-32`, `DesktopAppConversation.swift:480` |
| Permission dialogs | Status checks do not prompt (`AXIsProcessTrusted`, `CGPreflightScreenCaptureAccess`, FDA read, Automation `ask: false`). A send does not call the prompt APIs. If TCC is missing, AX throws or the driver refuses. The drag guide and `enableHostAccessibility(prompt: true)` / `CGRequestScreenCaptureAccess` run only from the permission UI. | `CuaPermissions.swift:75-79`, `DesktopAccessibility.swift:154`, `EmbeddedCuaDriver.swift:52-55`, `PermissionsSettingsView.swift:79-91`, `AppPermissions.swift:79`, `171-173` |
| Messages Automation prompt | Not on the desktop path. Enable Automation can prompt, and if Messages is closed it opens Messages first (`activates = false`). | `AppPermissions.swift:95-121`, `145-148` |
| Contacts prompt | Only `enableContacts` / `connectContacts` when status is `.notDetermined`. | `AppPermissions.swift:83-90` |
| Target-app login and other dialogs | Not dismissed. `"Log in"` windows are excluded. ChatGPT `AXDialog`/`AXSheet` aborts. Multiple windows abort. The user must dismiss them. A remote trigger cannot. | `DesktopAppConversation.swift:453-456`, `ChatGPTAppObservation.swift:68` |
| Navigation inside the app | Connect check and `refreshDesktop` can click New chat / sidebar / mode (Muse, Wabi, ChatGPT/Dots). That is UI mutation without a user prompt in the target app. | `MuseAppConversation.swift:209-217`, `WabiAppConversation.swift:249-258`, `ChatGPTAppConversation.swift:201-206` |
| Space switch | No Space API in this tree. Other-Space windows are eligible if `space_ids` is nonempty. Lookup claims it does not move the window. Whether a background click pulls a Space forward is **UNCERTAIN** (no branch). | `DesktopAppConversation.swift:447-451`, `DesktopNativeWindowLookup.swift:31-32` |
| Screen recording | Permission is process-wide. Sends that need geometry set `include_screenshot` and write a PNG of that window, then delete it. The capture is the driver's window shot, not a documented full-desktop recording. What the driver captures if the window is off-screen or the display is asleep is **UNCERTAIN**. | `DesktopAppConversation.swift:460-465`, `ChatGPTAppConversation.swift:94-96`, `CuaPermissions.swift:78-79` |
| Recording whatever else is on screen | Not requested by the desktop send path. Chat image share is a different ScreenCaptureKit path and is user-initiated. | `architecture.md:273` |
| Lock screen / sleep / display off | No guard on the desktop send path. **UNCERTAIN.** Webhook copy tells the user to keep the Mac awake. Keychain item uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` for the webhook key only. | `GrokBotSettingsView.swift:169`, `WebAgentSession.swift:2100`, `GrokBotService.swift:177` |
| Modal System Settings | `MessagesAccessGuide.start` opens System Settings and drives it for up to the guide's wait. That is the enable action, not a send. A remote send does not call it. | `MessagesAccessGuide.swift:45-80` |
| Occupied UI | A second remote send while the first holds `isSending` or `occupied` fails or waits behind the serial desktop group. It does not queue. | `WebAgents.swift:170-178`, `WebAgentSession.swift:1587`, `ChatGPTAppConversation.swift:242-243` |
| Embedded driver process | First call starts a helper under `/tmp/msgblast-cua-<uuid>` and checks the parent bundle. Failure throws before input. The helper inherits msgblast's TCC identity. | `EmbeddedCuaDriver.swift:92-102`, `136-164` |
| Gemini | Remote `configure`/`connect`/`send` hit `isEnabled == false` or `isAvailableInBuild` and return without the driver. | `WebProvider.swift:10`, `WebAgentSession.swift:255`, `1142`, `1361-1363`, `1419` |

Passive `refreshDesktopInstallation` and background `refreshDesktop` do not launch (`DesktopAppInstallation.swift:27-31`, `WebAgentSession.swift:1258`, `1418-1425`). The launch risk is `openDesktopApp`, Connect, `openComparison` with a comparison id or `startNativeApp`, and `sendNative`.
