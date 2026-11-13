# Outside agents

Agents on this Mac, such as Claude Code and Codex, can use msgblast through the
`msgblast` command and its stdio MCP server (`msgblast mcp`). Grok Bot can use the
same tools over Tailscale; see [Grok Bot over Tailscale](grok-bot.md). Everything
is off until Settings → Outside agents → "Allow agents on this Mac" is on.
Switching it off again ends every open session at once: nothing new runs, even
if an approval prompt is answered afterwards, and a request that was running gets
no reply. A send already under way finishes, because stopping it halfway could
leave a message half sent.

## Connect your agents

The paths below are the installed app. Settings → Outside agents → Copy Setup
copies the command for the build you are running.

- **Claude Code:** `claude mcp add msgblast -- /Applications/msgblast.app/Contents/MacOS/msgblast mcp`
- **Codex:** `codex mcp add msgblast -- /Applications/msgblast.app/Contents/MacOS/msgblast mcp`
- **Cursor and Gemini CLI:** Settings → Outside agents → Copy Setup → Cursor or Gemini CLI, then
  paste that JSON into the client's MCP config. It names the msgblast command and
  the `mcp` argument.
- **Claude Desktop:** add the same MCP server in Claude Desktop's developer
  settings. The comparison view is an MCP App and renders inline.
- **Grok Bot:** uses Tailscale, not this stdio command. If the macOS firewall is
  on, allow msgblast incoming connections. See [Grok Bot over Tailscale](grok-bot.md).

[integrations/agent-plugins/msgblast/](../integrations/agent-plugins/msgblast/README.md)
is a draft plugin for Codex and Claude Code. It is not published. `codex plugin add`
and `claude plugin install` install from a marketplace, not from this folder alone.

## Approval and levels

The first call from each agent name opens a prompt in msgblast. The person picks
one level or chooses Don't Allow, which msgblast remembers until it quits.

- **Read only:** see agents, comparisons and replies, including message text, and
  wait for new events. Nothing can be sent.
- **Full access:** everything above, plus the send tools. That includes Messages
  contacts, so a Full access agent can send iMessages to real people.

Settings lists each approved agent under Agents, with its level and a remove button.

msgblast knows an agent only by the name it gives. Any program running as you on
this Mac can run the `msgblast` command with an approved name, such as "Claude
Code", and get that name's level. Give Full access only if you trust what runs on
this Mac under your account, and remove names you no longer use.

## Tools

| Tool | Level | What it does |
| --- | --- | --- |
| `msgblast_status` | Read only | Version, permissions, busy agents |
| `msgblast_agents_list` | Read only | Agents and their ids |
| `msgblast_comparisons_list`, `msgblast_comparison_read` | Read only | Saved comparisons and their conversations |
| `msgblast_mentions` | Read only | Comparisons as links for @-mentions |
| `msgblast_blast_wait` | Read only | Waits for replies, send results and busy changes |
| `msgblast_request_status` | Read only | The stored result of an earlier send call |
| `msgblast_blast_start` | Full access | One message to several agents, as a new comparison |
| `msgblast_blast_follow_up` | Full access | A follow-up in a comparison |
| `msgblast_agent_message` | Full access | A private message to one agent |
| `msgblast_comparison_end` | Full access | Ends a comparison |

## Comparison view and mentions

`msgblast_comparison_read` and `msgblast_blast_wait` open the side-by-side
comparison view in clients that support MCP Apps. The view only shows; it never
sends. In Codex and ChatGPT, @-mention a comparison: `msgblast_mentions` returns
`msgblast://comparison/<id>` links, and reading one runs `msgblast_comparison_read`.

## How sends behave

Send tools use the same command executor and send paths as the iPhone controller
(see [Remote control](remote-control.md)), so every check that guards a send from
the Mac or the phone applies:

- Nothing is retried. A send whose result is unclear stays unclear; check the
  comparison or `msgblast_request_status` before sending again.
- `requestId` makes a call safe to repeat while msgblast is running. The same
  agent name and `requestId` return the first result instead of sending again.
  msgblast remembers its last 1,000 sends and forgets them when it quits, so after
  a restart check the comparison before repeating. Without a `requestId`, each
  call is new. A refusal is remembered too, so use a new `requestId` to try again.
- Sends run one at a time. An agent's send waits for an earlier agent send to
  finish. While the Mac or the phone is sending, it is refused as busy instead.
- A locked Mac, an agent that isn't signed in or ready, or an ended comparison
  refuses the send. The error says why for each agent and names a code, such as
  `macLocked`, `macBusy` or `agentUnavailable`. Nothing is sent.
- Each agent name may call the send tools 6 times a minute and 60 times an hour.
  A repeat of a known `requestId` does not count.
- A result of `done` means msgblast submitted the message to each agent. Replies
  arrive later as `replyArrived` events from `msgblast_blast_wait`. A send tool's
  result has an `after` cursor taken just before the send; pass it to
  `msgblast_blast_wait` so a reply that came before the wait started isn't missed.
  A repeat of a known `requestId` leaves `after` out, because its replies may be
  older; wait with `after` 0 and the `comparisonId` to get what msgblast still holds.

The phone's "Send iMessages from the phone" setting does not apply to outside
agents; Full access is what allows Messages contacts.

## Seeing and stopping agent sends

While an agent's send runs, a banner above the agents says who is sending and
what (for example "Codex · Started a blast · 3 agents") and offers **Stop Agent
Sends**. The send already under way finishes, because stopping it halfway could
leave a message half sent; nothing new goes out after it, including sends that
were waiting their turn.

While sends are stopped, the banner says so and offers **Allow Agent Sends**.
Every new send call is refused, and the error names the code `agentSendsStopped`.
A stopped call isn't stored, so once sends are allowed again the same call, with
the same `requestId`, can be repeated. Agents can still read. The setting is
saved, so quitting msgblast doesn't turn sends back on.
Settings → Outside agents has the same switch, and Recent sends under it lists the last
agent sends since msgblast opened, with each one's result. The list never holds message text and
is not saved.
