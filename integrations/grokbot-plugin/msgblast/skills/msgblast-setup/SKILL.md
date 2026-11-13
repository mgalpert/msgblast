---
name: msgblast-setup
description: Help a person connect Grok Bot to msgblast on their Mac over Tailscale. Use when they want Grok Bot to call msgblast, add the msgblast connector from msgblast Settings. Do not add the connector yourself, and never ask for the key in chat.
---

# msgblast setup for Grok Bot

msgblast runs on the person's Mac and listens for HTTP MCP on that Mac's Tailscale addresses. You cannot add the connector yourself. Guide the person, and ask them to paste only the Server URL.

## Check Tailscale

Grok Bot needs its Tailscale plugin on the same tailnet as the Mac.

1. Ask the person to open Connect apps → Your plugins → Tailscale.
2. If that tailnet is not connected, ask them to click Authenticate.
3. A company tailnet has to be enabled by a team admin at cursor.com → Integrations → Tailscale, and it needs Tailscale Premium or Enterprise. A personal tailnet works when the person owns or administers it.

Do not install Tailscale on the bot computer.

## Ask for the Server URL only

Ask the person to open msgblast → Settings → Outside agents, turn on Outside agents and "Let agents on other devices use msgblast over Tailscale", then click "Copy URL" and paste only the URL here. It looks like `http://<MagicDNS name>:<port>/mcp`.

Never ask for the key, and tell the person not to paste the `Authorization` header or the "Copy setup" block from the Grok Bot (Tailscale) row into this chat. The key goes only into the connector's header field. If they paste a key anyway, tell them to click "New key" in msgblast and use the new one in the connector.

Use the URL they pasted. Do not invent a host or a port.

## Guide them to add the connector

Tell them to add it in Grok Bot. You cannot add it for them.

1. Add a custom connector → Remote HTTPS.
2. Server URL: the URL they pasted.
3. Header: in msgblast click "Copy header" and paste it into the connector's header field (name `Authorization`, value `Bearer <key>`).
4. They save the connector.

msgblast serves `http://` only. If the form asks for an `https://` address, say that msgblast does not serve HTTPS yet. Turning on tailnet certificates in the Tailscale admin console does not change that.

## Prove it

After they confirm the connector is saved, call the msgblast tool `msgblast_status`. The person approves that call in msgblast. The prompt names the client "Grok Bot (Tailscale)". Show them the result.

If the call fails, ask them to read the three readiness lines on the msgblast Tailscale card and follow the line that has a warning.
