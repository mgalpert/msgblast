# Outside agents

Agents on this Mac, such as Claude Code and Codex, can use msgblast through the
`msgblast` command and its stdio MCP server (`msgblast mcp`). Grok Bot can use the
same tools over Tailscale; see [Grok Bot over Tailscale](grok-bot.md). Everything
is off until Settings → Outside agents → "Let agents on this Mac use msgblast" is on.

## Approval and levels

The first call from each agent name opens a prompt in msgblast. The person picks
one level or chooses Don't Allow, which msgblast remembers until it quits.

- **Read only:** see agents, comparisons and replies, including message text, and
  wait for new events. Nothing can be sent.
- **Full access:** everything above, plus the send tools. That includes Messages
  contacts, so a Full access agent can send iMessages to real people.

Settings lists each approved agent with its level and a Remove button.

## Tools

| Tool | Level | What it does |
| --- | --- | --- |
| `msgblast_status` | Read only | Version, permissions, busy agents |
| `msgblast_agents_list` | Read only | Agents and their ids |
| `msgblast_comparisons_list`, `msgblast_comparison_read` | Read only | Saved comparisons and their conversations |
| `msgblast_blast_wait` | Read only | Waits for replies, send results and busy changes |
| `msgblast_request_status` | Read only | The stored result of an earlier send call |
| `msgblast_blast_start` | Full access | One message to several agents, as a new comparison |
| `msgblast_blast_follow_up` | Full access | A follow-up in a comparison |
| `msgblast_agent_message` | Full access | A private message to one agent |
| `msgblast_comparison_end` | Full access | Ends a comparison |

## How sends behave

Send tools use the same command executor and send paths as the iPhone controller
(see [Remote control](remote-control.md)), so every check that guards a send from
the Mac or the phone applies:

- Nothing is retried. A send whose result is unclear stays unclear; check the
  comparison or `msgblast_request_status` before sending again.
- `requestId` makes a call safe to repeat. The same agent name and `requestId`
  return the first result and never send twice. Without one, each call is new.
- Sends run one at a time. While the Mac or the phone is sending, a new send is
  refused as busy rather than queued.
- A locked Mac, an agent that isn't signed in or ready, or an ended comparison
  refuses the send, and the error says why for each agent. Nothing is sent.
- Each agent name may call the send tools 6 times a minute and 60 times an hour.
  A repeat of a known `requestId` does not count.
- A result of `done` means msgblast submitted the message to each agent. Replies
  arrive later as `replyArrived` events from `msgblast_blast_wait`.

The phone's "Send iMessages from the phone" setting does not apply to outside
agents; Full access is what allows Messages contacts.

## Seeing and stopping agent sends

While an agent's send runs, a banner above the agents says who is sending and
what (for example "Codex · Started a blast · 3 agents") and offers **Stop Agent
Sends**. The send already under way finishes, because stopping it halfway could
leave a message half sent; nothing new goes out after it.

While sends are stopped, the banner says so and offers **Allow Agent Sends**.
Every new send call is refused with code `agentSendsStopped`, and agents can
still read. The setting is saved, so quitting msgblast doesn't turn sends back on.
Settings → Outside agents has the same switch and lists the last agent sends since
msgblast opened, with each one's result. The list never holds message text and
is not saved.
