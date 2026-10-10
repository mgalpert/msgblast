# Personal agent reports

This guide covers current website/CLI conversations and the separate restricted
comparison-report policy. For building and validation, use [Build from source](build-from-source.md)
and [Testing](testing.md). The source map is in [Architecture](architecture.md).

## Website chats and optional CLI conversations

ChatGPT and Claude use embedded websites by default, alongside Muse and Grok. These four web agents are selected on a new installation. Each website keeps its own sign-in and saved chat for each comparison. Browser cookies and CLI accounts are separate.

In **Settings → Your local accounts**, turn on **Enable Codex CLI** or **Enable Claude Code** to add a separate agent to the picker. You can select both a website and its CLI in the same blast. Enabling a CLI never replaces the website. Account status, refresh, installation links, and **Switch account** live in Settings; connected conversation columns contain only the conversation and composer.

CLI conversations save replies, drafts, and session IDs for each comparison. Follow-ups use `codex exec resume SESSION_ID` or `claude --resume SESSION_ID`, including after restarting msgblast. A new comparison creates new sessions. If a configured CLI’s saved session has been removed, the error stays visible; msgblast does not silently start another session or resend the request. Disabling a CLI removes it from new sends without deleting its history. Opening an archived comparison can still display that history; enable the CLI in Settings to continue it.

Upgrades separate previously shared ChatGPT/Codex and Claude/Claude Code records. The original state files are retained as backups. Website data-store identifiers and saved URLs stay intact; native transcripts, session references, drafts, and working directories move to the separate CLI identities. A comparison with both kinds of history retains both destinations. Optional CLIs start disabled until explicitly enabled.

CLI conversations use each CLI’s normal user/global configuration: configured skills, built-in tools, MCP servers/connectors, plugins, and hooks are available subject to that CLI’s permission rules and headless-mode support. msgblast does not change CLI configuration files or add permission-bypass flags. Prompts and replies remain text; tools may perform actions within the CLI’s configured permissions. Login credentials remain CLI-owned. Website chats are not imported into CLI sessions.

Each comparison retains its existing private working directory. Configuration and context local to another project directory are not automatically imported; msgblast currently has no project-directory picker. Global configuration paths inherited by the app (including `CODEX_HOME` and `CLAUDE_CONFIG_DIR`) are preserved. The app’s environment may differ from an interactive shell beyond the discovered executable PATH.

Codex uses noninteractive `exec` with its configured/default sandbox and headless approval behavior. Claude Code requires version **2.1.259 or later** and uses `--permission-prompts none`: configured permission rules, mode, and hooks still decide actions, while unanswered interactive approvals are denied. Claude’s reported permission denials are shown explicitly in the reply. CLI failures and failed Codex turns remain errors; they never become completed replies. Actions requiring interactive approval may need to be completed in Terminal. Runs retain bounded output, a three-minute timeout, and cancellation. An incomplete or canceled request can consume usage without returning a reply; its saved receipt blocks automatic continuation until explicitly acknowledged.

On the first explicit follow-up to a conversation created with the old restricted adapter, msgblast starts a configured session using the saved transcript as quoted history. This removes the old session’s persistent tool restrictions and “Do not use tools” instruction. The comparison identity, history, drafts, and working directory stay intact; previous CLI session IDs are retained in saved state for recovery. The new session’s explicit policy version and exact ID are recorded after a completed reply, making the transition idempotent. Later follow-ups resume that configured session. No CLI request is made during upgrade alone. CLI-only context absent from msgblast’s saved transcript is not reconstructed.

Settings also shows OpenClaw and Hermes installation status and their official icons. **Set up** opens a sheet, then **Continue in Terminal** hands off to the detected `openclaw configure` or `hermes setup` command. Detection does not launch either runtime, and installation does not prove sign-in or gateway health. Hermes has a comparison-report adapter; OpenClaw conversations are not connected yet. Demo sign-in and setup are disabled and clearly labeled.

Tests use local website and executable fixtures; they do not prove current live website layouts, provider authentication, billing, or live CLI resumption. Demo replies never invoke installed CLIs or provider services. Session handling follows [Codex non-interactive mode](https://developers.openai.com/codex/noninteractive) and [Claude Code programmatic conversations](https://code.claude.com/docs/en/headless#continue-conversations).

## Comparison reports

Click **Summarize** in the top-right toolbar of a comparison window, a separate conversation window, or the floating shared composer. A separate, resizable **Comparison report** window opens and starts the personal agent selected last time (or the first detected CLI on first use). The report leads with **Best next action** and its reasoning, then compares the responses and lists open questions. Select a different personal agent in the report window and click **Update report** to use it.

The report includes every participant's available responses, reactions, confirmed follow-ups, and explicit thread replies within the same boundaries as the conversation columns. It is independent of the message-recipient selection. At least one reply or recipient reaction is required to generate a report; the response count includes both. The report is saved with the comparison, can be copied, and becomes visibly stale when the conversation changes. Clicking **Summarize** again focuses the existing report window and requests an update; clicking while a request is running only focuses the report. New replies never trigger automatic provider requests. Existing saved summaries remain readable until replaced by a report.

Supported CLIs: **Codex, Claude Code, Gemini CLI, Pi, and Hermes**. Detection checks the login shell's PATH and common installation directories; it does not install agents or inspect credential files. A desktop app alone may not include its CLI. CLI updates can change supported flags; launch, authentication, and output errors leave the previous summary intact.

The **Settings → Your local accounts** panel checks saved Codex and Claude Code sign-ins with `codex login status` and `claude auth status`. An existing ChatGPT or Claude subscription login is reused automatically; API-key and other authentication modes are labeled separately because they may bill differently. Status checks do not generate a report or make a model request. A successful check confirms the CLI's authentication state, not remaining quota or a successful model request.

Click **Sign in with ChatGPT** or **Sign in with Claude** to open the detected official CLI's login command in Terminal and complete its browser flow. Return to msgblast to refresh status automatically, or click **Refresh accounts**. Sign-in updates the shared CLI account used by your other CLI sessions too. If the CLI is missing, the panel links to its official installation guide. Other agents retain their own Terminal setup commands. msgblast does not read, copy, or store account tokens and does not log out other apps. Login handoffs use a private executable temporary script that removes itself when its Terminal command exits; if Terminal never starts the script, the OS temporary directory may retain that token-free script. The demo displays simulated account states with sign-in disabled.

### Research: bb and local subscription accounts

The bb comparisons below are revision-pinned design research. Prior validation
results describe the earlier tested change, not a passing result for a new branch.
Use the current test commands below when changing these adapters.

Inspected [bb revision 937e5a9](https://github.com/get-bb/bb/tree/937e5a9b92cb57522a1e14a30ee237231d4cecac). Its [Codex provider](https://github.com/get-bb/bb/blob/937e5a9b92cb57522a1e14a30ee237231d4cecac/plugins/provider-codex/src/bridge/provider-maintenance.ts) advertises `codex login`; its [Claude provider](https://github.com/get-bb/bb/blob/937e5a9b92cb57522a1e14a30ee237231d4cecac/plugins/provider-claude-code/src/bridge/provider-maintenance.ts) advertises `claude /login`. Provider execution uses local runtimes. Separately, its optional [account-pool import](https://github.com/get-bb/bb/blob/937e5a9b92cb57522a1e14a30ee237231d4cecac/plugins/account-pool/src/credentials.ts) reads Codex's `~/.codex/auth.json` and Claude Code's Keychain credentials or `~/.claude/.credentials.json`, then manages imported tokens. That credential-pool design is unnecessary for msgblast's one-shot local report workflow.

The implementation uses the documented CLI paths: [OpenAI authentication](https://developers.openai.com/codex/auth) covers shared cached authentication and token refresh; [Claude CLI reference](https://code.claude.com/docs/en/cli-reference) documents `claude auth login`, JSON status, and exit codes; [Claude authentication](https://code.claude.com/docs/en/authentication) explains subscription and API credential precedence. Browser cookies and a ChatGPT/Claude desktop login alone do not establish a usable local CLI account. The chosen CLI owns subscription eligibility, limits, account policy, credential storage, and renewal.

Account-login validation: 66 isolated Xcode unit tests passed, including CLI stdout/stderr status parsing, subscription/API mode distinctions, shell-injection quoting, configuration-directory consistency, and token-free login scripts. Controller shutdown and persistence fixtures passed. The new account panel was inspected manually in a separate blue-icon demo build with simulated account states and disabled login actions. Xcode's automated UI runner could not initialize macOS automation mode, so its new panel assertions remain unverified. No live OAuth login, account change, or model request was performed.

Cursor (`cursor-agent`) is excluded from discovery and rejected before any report process can launch. Cursor's [Ask mode](https://cursor.com/docs/cli/overview) permits read-only exploration, and its [permission configuration](https://docs.cursor.com/cli/reference/permissions) does not establish a verified denial of every tool in msgblast's adapter. Participant replies are untrusted, so read-only mode is insufficient. Existing saved Cursor selections and reports still decode; the report window explains the restriction and offers the other installed agents. This restriction remains until complete tool denial can be enforced and verified.

Grok is also excluded and rejected before launch. Its empty `--tools` argument is treated as no override, and `dontAsk` retains explicitly allowed actions from user configuration. The report adapter stays disabled until complete built-in and MCP tool denial is verified independently of those inherited rules. Saved Grok preferences and reports remain readable.

This follows [bb's local CLI integration approach](https://github.com/get-bb/bb/tree/c8b9459ba911a5666fda4ed63291aed68b6a64be/plugins): its Claude adapter resolves the local executable for the Agent SDK, Codex uses a local app-server child, and Cursor/OpenCode/omp/Grok/Hermes use ACP bridges. msgblast uses one-shot CLI adapters for its single-summary workflow rather than embedding bb's TypeScript server or long-lived session protocol. OpenCode and omp are not included in this initial adapter set. No bb source code is copied.

The chosen CLI uses its existing account and provider billing/usage limits; msgblast does not add an API-key form or promise that every CLI configuration bills a subscription. The comparison text is sent to the selected provider only when you request a summary. Unsent drafts, contact addresses, unrelated conversations, and attachment contents/paths are excluded (attachment filenames remain as context). For comparison reports, Codex and Hermes use their isolated configuration modes while retaining CLI-owned authentication; other adapters disable tools or request the CLI's read-only mode. These are provider controls, not an OS-level isolation guarantee for third-party executables. Each run uses a private temporary working directory, direct arguments and stdin, a three-minute timeout, cancellation, and bounded output. Cancellation, timeout, and normal app quit stop the request process group before removing temporary request/output files; force quitting or a system crash cannot run that cleanup. After a completed run those files are removed; the provider may maintain its own history under its own policy.

The demo always uses a clearly labeled simulated report and never invokes an
installed agent. Adapter fixtures prove transport/parsing and failure behavior,
not live provider authentication or billing. Run the [native core tests](testing.md#native-core-tests)
and [controller fixtures](testing.md#controller-and-executable-fixtures) first.
On an authorized Mac, select the UI cases
`testSeparateConversationWindowsShareOneComparisonReport` and
`testPersonalAgentOpensComparisonReportWithBestNextAction` with the isolated UI
test command in that guide. No fixture run establishes live account eligibility.


## Configured conversation fixture

After the testing guide's core build, run:

```sh
bash scripts/test_configured_cli_conversations.sh build/contributor-tests build/cli-configured-evidence
```

The harness invokes the real core adapter with a deterministic local executable and temporary fixture configuration. It prints actual inputs/results for new and resumed Codex/Claude conversations, a denied write, a still-restricted comparison summary, and legacy-session retention. The optional second directory receives `requests.jsonl` containing actual fixture arguments, stdin, outputs, and working directories. No installed provider CLI, credential, paid model, live skill, or connector is used. It verifies adapter configuration transport and policy separation, not live provider configuration interpretation or connector access. Claude’s unattended permission behavior follows its [programmatic CLI documentation](https://code.claude.com/docs/en/headless#turn-off-permission-prompts-in-unattended-runs).
