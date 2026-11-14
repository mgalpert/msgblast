---
name: msgblast-use
description: Ask the person's AI agents and Messages contacts something through msgblast and read their replies. Use when the person wants to message, blast, compare or follow up with their agents, or read a comparison. Needs msgblast connected; if its tools are missing, use the msgblast-setup skill.
---

# Use msgblast

msgblast runs on the person's Mac. It sends one message to many AI agents and Messages contacts and keeps their replies side by side as a comparison.

## Pick agents

Call `msgblast_agents_list`. Use the `id` of each agent in every other call, never its name. If the person names an agent that isn't listed, say so; don't guess an id.

Ids that start with `messages:` are real people in Messages. Send to one only when the person asked you to, with text they approved.

## Send

- One agent: `msgblast_agent_message` with `agent` and `text`.
- Several at once: `msgblast_blast_start` with `agents` and `text`. It starts a comparison.
- More in the same comparison: `msgblast_blast_follow_up` with its `comparisonId`.

Give every send a fresh `requestId`, such as a UUID. If a call times out, call `msgblast_request_status` with that `requestId` before sending again, so nothing goes out twice.

## Read replies

Call `msgblast_blast_wait` with the `comparisonId` and the `after` from the send result. It returns when replies arrive, so don't poll. Then call `msgblast_comparison_read` for the full replies. Summarize them for the person, and say which agents haven't replied yet.

`msgblast_comparisons_list` shows earlier comparisons. `msgblast_comparison_end` ends one so nothing more is sent in it.

## Access

The person chose a level for you in msgblast. Read only can list and read but not send. If a send fails with `needsAccess`, tell the person to switch you to Full access in msgblast → Settings → Outside agents, then try again. If sends fail with `agentSendsStopped`, the person stopped agent sends in msgblast; don't retry until they allow them again.
