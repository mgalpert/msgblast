# msgblast agent plugin

Draft for review. Not published. The msgblast app does not install this folder.

Codex and Claude Code can load it as a plugin. `.mcp.json` starts the installed app:

`/Applications/msgblast.app/Contents/MacOS/msgblast mcp`

The setup skill asks the person to turn on Settings → Outside agents and approve the agent. It never asks for keys or passwords. The use skill lists agents, sends one message or a blast, waits for replies and reads the comparison, and asks before messaging a Messages contact.

## Install locally for review

`codex plugin add` installs `PLUGIN@MARKETPLACE` only (`codex plugin add --help`). `claude plugin install` installs from a marketplace (`claude plugin install --help`). Both `codex plugin marketplace add` and `claude plugin marketplace add` accept a local path, and that path has to be a marketplace. This folder is a plugin, so those commands do not install it by itself.

Connect an agent with the commands in [Connect your agents](../../../docs/outside-agents.md), or with Settings → Outside agents → Copy MCP config.
