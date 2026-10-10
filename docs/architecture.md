# Architecture and source map

msgblast is a native macOS app with SwiftUI views, AppKit windows, a shared core
framework, and small separately maintained web services. Start with [Build from
source](build-from-source.md) and [Testing](testing.md) for runnable commands.

## Where to make a change

| Area | Source | Responsibility |
| --- | --- | --- |
| App entry and menu | `msgblast/App/msgblastApp.swift` | SwiftUI scenes, focused commands, app startup, and Settings |
| Main orchestration | `msgblast/App/AppModel.swift` | Agent selection, Messages refresh, comparison lifecycle, sending, and persistence |
| Update lifecycle | `msgblast/App/AppUpdater.swift`, `UpdateProbe.swift` | Sparkle configuration and isolated Debug update fixtures |
| Report orchestration | `msgblast/App/PersonalAgentController.swift` | CLI discovery, report requests, cancellation, and saved reports |
| Main and comparison UI | `msgblast/Windows/Views.swift`, `RichMessageViews.swift` | Picker, sidebar, conversations, scope, and transcript rendering |
| Window ownership | `msgblast/Windows/WindowCoordinator.swift` | Joined/separate conversations, report windows, frames, and floating composer |
| Web/CLI UI | `msgblast/Windows/WebServicesView.swift`, `WebProvider.swift`, `WebAgentSession.swift` in Core | Website panes, native CLI/Bot panes, and provider session state |
| Other panels | `msgblast/Windows/` | Discover, installation, feedback, Grok Bot settings, attachments, and What's New |
| Persisted models and routing | `msgblast/Core/Models.swift`, `Routing.swift` | Codable state, comparisons, recipients, attempts, anchors, and range rules |
| App-owned storage | `msgblast/Storage/LocalStore.swift` | Atomic state writes, migration backups, staged files, and attachment references |
| Messages history | `msgblast/Core/MessagesDatabase.swift` | Read-only SQLite schema/query adapter and replies/reactions/attachments |
| Messages submission | `msgblast/Messages/MessageSender.swift`, `App/AttachmentDelivery.swift` | Messages Apple Events and per-recipient attachment delivery |
| Contacts and permission UI | `msgblast/Contacts/`, `msgblast/Permissions/`, `Core/PermissionHandoff.swift` | Contacts lookup and explicit macOS permission handoff |
| Provider sessions | `msgblast/Core/WebAgents.swift`, `WebServices.swift`, `WebAgentSession.swift` | WebKit/CLI session state, identity migration, comparison membership, and receipts |
| Website adaptation | `msgblast/Core/WebPageScript.swift`, `MusePageScript.swift` | Page interaction, sign-in detection, composer preparation, and submission checks |
| Local CLI execution | `msgblast/Core/LocalPersonalAgent.swift`, `LocalAgentDetection.swift` | Executable/account detection, conversation adapters, restricted reports, and process cleanup |
| Grok Bot | `msgblast/Core/GrokBot*.swift` | Webhook requests, secure storage, loopback replies, and bundled tunnel process |
| Feedback | `Core/DiagnosticReport.swift`, `FeedbackSubmission.swift`, `Windows/FeedbackView.swift` under `msgblast/` | Explicit feedback note, allowed diagnostics, and private intake submission |
| Download service | `download/` | Signed-feed verification and fixed latest.zip redirect |
| Feedback handler | `feedback/` | Validated private R2 intake; template integrated into a separate production landing Worker |
| Build/release tooling | `scripts/`, `.github/workflows/` | Project generation, helpers, previews, installers, validation, and distribution |

## Runtime boundaries

The app creates its model only after installation checks allow startup. The model
owns app state and coordinates Messages and provider sessions. Views observe those
objects rather than querying Messages or spawning CLIs independently. AppKit
controllers retain native windows and bring existing windows forward when needed.
Follow nearby panels and lifecycle code when adding a window or menu command.

`BuildFeatureWindowController` owns the reusable **Build a New Feature** window.
It needs no app model or provider connection. Its prompt contains only static
contributor instructions, the entered idea, and the installed version/build;
**Copy Prompt** writes that visible text to the clipboard. Links open in the
default browser. Closing the window discards its local draft.

There are four distinct connection types:

| Connection | How it works |
| --- | --- |
| Messages | Existing one-to-one iMessage chats, read-only history, and Apple Events submission |
| Websites | Muse, ChatGPT, Claude, Grok, Dots, and rabbit OS3 inside persistent WebKit stores |
| Optional CLI conversations | Separate Codex CLI / Claude Code agents using installed CLI accounts, configured tools, and saved sessions |
| Grok Bot | Direct webhook call and authenticated reply through a temporary bundled cloudflared tunnel |

Website login does not authenticate a CLI. CLI configuration does not replace the
website. Grok Bot is distinct from Grok's website. Comparisons keep each provider's
identity and private history; joining another agent shares only explicitly shared
context, not private one-to-one turns.

rabbit OS3 is featured in the agent grid and available during onboarding, but
is not selected until the user connects or chooses it. Its account has one
ongoing conversation: switching comparisons retains that page, its draft, and
earlier context. Receipts remain attached to each comparison's own send attempt;
an already observed message cannot be linked to another attempt.

**Comparison reports** are a separate execution policy. They summarize available
Messages replies with restricted local adapters; they do not inherit the full
configured tool access of optional CLI conversations. Keep those policies separate
when changing adapters. See [conversations and reports](personal-agent-reports.md)
for supported providers and limitations.

Messages submissions have explicit per-recipient attempts and reconciliation.
An accepted automation command is not proof of delivery. Failed or ambiguous
submissions must preserve drafts and avoid automatic duplicate sends. Website
receipts must identify the expected chat; a page layout change cannot justify
sending into a different saved conversation.

## State, credentials, and compatibility

`LocalStore` retains `state.json`, app-authored prompts/drafts, comparison metadata,
send attempts/anchors, window frames, and staged attachment references. It does
not import the user's entire Messages history. Staged attachments live beneath
the selected app support folder. Web/CLI providers additionally retain their
per-provider session files and comparison/session identifiers.

| Build | App support folder |
| --- | --- |
| Production | `~/Library/Application Support/msgblast` |
| Packaged Dev | `~/Library/Application Support/msgblast-Dev` |
| Packaged Demo | `~/Library/Application Support/msgblast-Demo` |
| Isolated UI fixture | Temporary profile; tests explicitly request demo/isolation |

`SupportDirectory` in `Core/InstallationLocation.swift` controls the profile;
changing a bundle ID alone does not change the support folder. Preview packaging
sets both identity and profile. Preferences are per bundle ID; demo arguments
also have a permission-fixture defaults suite. Other local builds of the same
variant can share state. Never point a fixture at the production profile.

WebKit retains web sign-in separately. CLI-owned authentication remains with the
CLI, rather than being copied into msgblast state. Grok Bot uses an encrypted
hardware-backed vault when available, a permitted noninteractive data-protection
Keychain fallback, or explicitly labeled session-only storage. See [Grok Bot](grokbot.md).
Private feedback is submitted separately from app state and is never PR evidence.

When changing Codable state, inspect existing decode defaults, migration backups,
legacy provider identifiers, retained session working directories, and in-flight
receipt recovery. Use fixtures that open old state and preserve its original
bytes when migration fails. A load failure must not be "fixed" by replacing user
state with a fresh empty model. See [update recovery](update-recovery.md).

## Project and resources

`scripts/generate_project.py` is the source of the committed Xcode project and
shared `msgblast` scheme. It enumerates app Swift files recursively and test files
in the test directories, separates Core into a framework, registers icons and
resources, pins Sparkle, and adds the cloudflared build phase. Update the generator
for build-setting/resource changes rather than only editing generated output.

```sh
python3 scripts/generate_project.py
git diff -- scripts/generate_project.py msgblast.xcodeproj
```

Review and commit both generator and generated changes when applicable. A clean
clone already contains a generated project. Package.swift is a secondary Swift
package manifest, not the complete native app packaging recipe; keep relevant
dependencies/resources aligned when changing shared code.

Canonical icon bundles live under `output/app-icons/`. Green production artwork
must match `msgblast/AppIcon.icon`; blue Demo artwork must match
`msgblast/AppIconDemo.icon`. The preview packager stages blue-green Dev artwork in
an isolated copy, preserving the source resources. A build configuration, filename,
or icon color alone does not set demo mode or isolate data.

The Xcode build downloads/verifies pinned cloudflared assets and embeds the
architecture-matching helper. Resource/attribution changes need the generator,
notices, and corresponding checks. See [Grok Bot](grokbot.md#bundled-helper).

## Services and release boundary

The source repository is public. Public app archives/feed use a dedicated R2 host;
private feedback uses a different private bucket. Neither local development nor
PR validation needs the release signing seed or R2 publishing credentials.

The landing site is in the owner's separate authoritative checkout. Changing
`feedback/` here does not deploy its production handler. Changing `download/`
does not release the app. Pushing app source does not publish an update.
See [documentation index](README.md#maintainer-operations) for each operation.

## Changes that need particular care

- Preserve exact recipient/chat identity and private/shared scope.
- Preserve saved data and attachment references across failures and upgrades.
- Keep website, configured conversation, and restricted report policies distinct.
- Keep processes and callbacks bounded and cleaned up on normal cancellation/quit.
- Keep production, Dev, and Demo mode/state/update configuration explicit.
- Verify current live behavior separately from fixtures when the change depends on
  website layouts, provider authentication, Messages, or macOS permissions.
