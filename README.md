<p align="center">
  <img src="docs/images/readme/msgblast-icon.png" alt="msgblast" width="96">
</p>

<h1 align="center">msgblast</h1>
<p align="center"><strong>Ask once. Compare the answers.</strong></p>
<p align="center">Send one question to AI assistants across the web, Messages, and your local CLIs. Compare their replies side by side on your Mac.</p>
<p align="center"><a href="https://updates.msgblast.app/latest.zip"><strong>Download for Mac</strong></a> · macOS Sequoia 15 or later</p>

<img src="docs/images/readme/compare-answers.jpg" alt="One question sent to Instinct, Fo, and Szn, with three different answers side by side and a shared follow-up message" width="1100">

Planning a weekend, researching a purchase, or testing an idea? Write your question once, choose your assistants, and compare their suggestions in one window. Send a follow-up to everyone or just one assistant. Your comparisons stay saved so you can return to them later.

*Actual Messages comparison captured from an earlier app version. The replies are illustrative sample text.*

## Features

- **One question, several assistants.** Choose who receives each blast and read the answers together. Send follow-ups to everyone, a few agents, or one.
- **Saved conversations.** Reopen a comparison from the sidebar and continue where you left off. Each web or CLI agent keeps a dedicated conversation for that blast; Muse uses a side chat.
- **Your web and CLI accounts, together.** Ask ChatGPT and Codex CLI, or Claude and Claude Code, the same question. Each uses its own account, conversation, and configured capabilities.
- **Discover more agents.** Search the built-in directory, browse categories, visit an agent’s website, and add it to your agents.
- **Rich Messages conversations.** Send photos and files to Messages agents and read replies with attachment previews, link cards, and reactions.
- **Comparison reports.** For Messages comparisons, ask a local agent to compare the replies, explain the tradeoffs, and recommend a next action. Save, copy, or update the report as the conversation develops.

## Supported agents

| Connection | Agents | How it works |
| --- | --- | --- |
| Websites | **Muse, ChatGPT, Claude, Grok** | Choose during setup, sign in inside msgblast, and keep the chats in the app. |
| Your dot | **Dots** | Select Dots to message your ongoing dot at chatgpt.com/dots. Its displayed avatar is saved locally. |
| Messages | AI assistants you already text, including **Instinct, Fo, and Szn** | Connect existing one-to-one iMessage conversations. Photos and files are supported. |
| Optional CLI conversations | **Codex CLI, Claude Code** | Enable each in Settings to add it alongside the websites. Uses the installed CLI’s sign-in, skills, tools, and connectors, subject to its permissions. |
| Optional Bot webhook | **Grok Bot** | Separate from Grok's website. The Mac sends directly to your Bot's routine and receives replies through an app-managed temporary tunnel. [Setup and availability](docs/grokbot.md). |

Each service’s own account, subscription, and usage limits apply. Web and CLI requests use text; attachments are available when only Messages agents are selected.

## Get started

1. [Download msgblast](https://updates.msgblast.app/latest.zip), unzip the file, and drag **msgblast.app** into **Applications**. Open the app.
2. On first launch, choose the agents you use and connect at least one to start chatting. Connect the remaining selections or **Skip for now**. Instinct, Fo, Szn, and other Messages agents share one setup screen; Grok Bot shows its routine prompt and connection fields directly. OpenClaw and Hermes offer their existing Terminal setup; Hermes supports comparison reports, and neither currently has a chat pane. Existing installations keep their saved setup.
3. Write your question and press the send arrow. If sign-in is needed, finish it in the relevant pane and send again. Your question stays ready. Messages access is only needed for Messages agents; see the steps below.
4. Compare the replies, choose recipients for a follow-up, or click **New Blast** to start another comparison. Saved comparisons remain in the sidebar.

<details>
<summary>Help opening the app and allowing Messages access</summary>

**If macOS blocks the first launch:** after trying to open msgblast, go to **System Settings → Privacy & Security**, scroll to the security section, and choose **Open Anyway**. Confirm **Open** if you trust the download. [Apple’s first-launch instructions](https://support.apple.com/en-us/102445#openanyway).

**Messages history:** click **Open Settings** in msgblast. In **Privacy & Security → Full Disk Access**, click **+**, choose **msgblast.app** from **Applications**, and click **Open**. Enable its switch and authenticate if asked. Quit and reopen msgblast, then click **Check again** if the history banner remains. This lets msgblast read replies from your existing Messages conversations.

**Add a Messages agent:** start a one-to-one iMessage conversation with the assistant, then click **Add Agent** in msgblast and search by name, email, or phone number.

**Contacts:** allow access when msgblast asks so it can find your assistants. If you previously declined, enable msgblast in **Privacy & Security → Contacts**.

**Sending through Messages:** on the first send, allow msgblast to control **Messages**. If you previously declined, enable **Messages** under **Privacy & Security → Automation → msgblast**.

</details>

Check for updates from **msgblast → Check for Updates**.

Skipped agents stay available through **Finish setup**. Setup saves your progress through a restart and never sends a question automatically. You can add agents later through Settings and Discover.

## Web accounts and optional CLI agents

Muse, ChatGPT, Claude, Grok, and Dots run as websites inside msgblast. Dots is an optional selection and continues your existing dot conversation across blasts. Its rendered profile avatar, including custom pets, is saved locally and refreshed when it changes; signing out clears it. Sign-ins persist between launches. Signing in through Safari, Chrome, a desktop app, or a CLI does not automatically sign you in to these embedded pages. Choose models and thinking settings in each service’s own controls.

Enable **Codex CLI** or **Claude Code** in **msgblast → Settings** to add a separate agent. Enabling a CLI does not replace its website. Each keeps its own saved history and draft, so you can compare the web account’s capabilities with the CLI’s configured skills, tools, and connectors. Manage local account sign-in and switching in Settings.

CLI conversations respect the installed CLI’s permissions. Actions needing interactive approval may require Terminal; msgblast does not bypass those approvals. Claude Code requires **2.1.259 or later**. Configuration from another project folder is not automatically loaded. See [CLI accounts and conversations](docs/personal-agent-reports.md#website-chats-and-optional-cli-conversations) for details.

<img src="docs/images/readme/choose-agents.jpg" alt="Agent selection showing Muse, ChatGPT, Claude, Grok, Instinct, Fo, and Szn with their icons" width="1100">

*App capture with sample Messages profiles. No messages were sent. Captures predate the current release; some labels and artwork have since changed.*

## Messages comparisons and reports

Connect assistants such as [Instinct](https://instinct.com/), [Fo](https://wajo.ai/), and [Szn](https://theszn.ai/) through your existing Messages conversations. Full Disk Access lets msgblast read Messages history; Automation permission allows sending through Messages. Website and CLI agents do not require Messages access.

Messages comparisons can stay in one window or use separate conversation windows with a floating shared composer. Choose the layout in **msgblast → Settings → Conversations**.

Click **Summarize** in a Messages comparison to generate a **Comparison report** with a recommended next action, supporting reasoning, differences between replies, and open questions. Reports use an installed, signed-in **Codex, Claude Code, Gemini CLI, Pi, or Hermes**. They use available Messages replies and reactions; website and CLI chat replies are not included. Attachment contents are not sent to the report agent.

Reports are saved with the comparison and update when you request it. Unlike CLI conversations, report generation keeps tools restricted to analyze the supplied responses. Hermes requires a provider and model configured in Terminal; OpenClaw currently offers only a setup shortcut, with no chat or report integration. See [OpenClaw and Hermes terminal setup](docs/personal-agent-reports.md#openclaw-and-hermes-terminal-setup) for the commands, wizard steps, and how to use Hermes in a report.

## Current limits

Website layout changes can affect sending. Review a failed or unconfirmed send before retrying; msgblast does not automatically resend it. Shared web/CLI blasts are text-only, and there is no shared model or thinking selector. Your prompts go to the selected services; CLI tools may act within their configured permissions.

## Build your own feature

Choose **msgblast → Build a New Feature…** to describe your idea and copy a
starting prompt for your coding agent. The window links to the public repository,
fork page, source download, and build guide. You can also find it in **Help**.

[msgblast's source is public](https://github.com/mgalpert/msgblast). Fork it, build
the feature you want to use, and share it through a pull request with a description,
screenshots, and a short video. You can also clone or download the source for a
personal build.

Start with [Build from source](docs/build-from-source.md) to create separate
**msgblast Dev** and **msgblast Demo** apps without replacing your installed app.
Local previews need Xcode 27 and Python, but no production release credentials.
Use Demo with sample data for testing and recordings; Dev uses live accounts.

[Contributing](CONTRIBUTING.md) covers forks and PRs.
[Architecture](docs/architecture.md) maps the codebase, [Testing](docs/testing.md)
lists checks, and the [documentation index](docs/README.md) links the current
integration and maintainer guides. Coding agents should read [AGENTS.md](AGENTS.md).

You can use your own build while your contribution is reviewed. Maintainers
publish reviewed changes separately; merging source does not distribute an app.

## License

Copyright (C) 2026 Michael Galpert and contributors.

Except where separately licensed or attributed, msgblast is licensed under the
[GNU General Public License, version 3 only](LICENSE) (`GPL-3.0-only`). You may
use, modify, and redistribute it, including commercially, under those terms.
Distributed modified versions must remain under GPLv3 and include the
corresponding source as required by the license. The software comes without
any warranty.

Third-party dependencies, service icons, logos, and other attributed assets
retain their respective licenses and rights; this license does not relicense
third-party material or grant trademark rights.
