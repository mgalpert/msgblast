# Connect your agents

Local agents talk to msgblast through the msgblast command (`mcp` on stdio). Turn on Settings → Outside agents → "Let agents on this Mac use msgblast". The first call from each agent asks you to approve it.

Read only: see agents, comparisons and replies; can't send anything.

Full access: everything, including sends to your AI agents and Messages contacts.

The path below is the installed app. Settings copies the command for the build you are running.

## Claude Code

```
claude mcp add msgblast -- /Applications/msgblast.app/Contents/MacOS/msgblast mcp
```

## Codex

```
codex mcp add msgblast -- /Applications/msgblast.app/Contents/MacOS/msgblast mcp
```

## Cursor and Gemini CLI

Settings → Outside agents → Copy MCP config. Paste that JSON into the client's MCP config. It names the msgblast command and the `mcp` argument.

## Claude Desktop

Add the same MCP server in Claude Desktop's developer settings. The comparison view is an MCP App and renders inline.

## Grok Bot

Grok Bot uses Tailscale, not this stdio command; if the macOS firewall is on, allow msgblast incoming connections. See [Grok Bot over Tailscale](grok-bot.md).

## Plugin folder

[integrations/agent-plugins/msgblast/](../integrations/agent-plugins/msgblast/README.md) is a draft for Codex and Claude Code. It is not published. `codex plugin add` and `claude plugin install` install from a marketplace, not from this folder alone.

## What agents can do today

Read-only tools list agents and comparisons. `msgblast_comparison_read` and `msgblast_blast_wait` open the side-by-side comparison view. In Codex and ChatGPT, @-mention a comparison: `msgblast_mentions` returns `msgblast://comparison/<id>` links, and reading one runs `msgblast_comparison_read`. Sending needs Full access and is not in the view.
