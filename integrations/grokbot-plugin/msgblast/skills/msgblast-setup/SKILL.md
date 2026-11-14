---
name: msgblast-setup
description: Help a person connect Grok Bot to msgblast on their Mac over Tailscale. Use when they want Grok Bot to call msgblast, add the msgblast connector from msgblast Settings. Do not add the connector yourself, and never ask for the key in chat.
---

# msgblast setup for Grok Bot

msgblast runs on the person's Mac and serves MCP privately on their tailnet. Grok Bot needs its `https://` address, which Tailscale Serve provides. You cannot add the connector yourself. Guide the person, and ask them to paste only the Server URL.

## Check Tailscale

Grok Bot needs its Tailscale plugin on the same tailnet as the Mac.

1. Ask the person to open Connect apps → Your plugins → Tailscale.
2. If that tailnet is not connected, ask them to click Authenticate.
3. A company tailnet has to be enabled by a team admin at cursor.com → Integrations → Tailscale, and it needs Tailscale Premium or Enterprise. A personal tailnet works when the person owns or administers it.

Do not install Tailscale on the bot computer.

## Ask for the Server URL only

Ask the person to open msgblast → Settings → Outside agents, turn on "Allow agents on other devices" under Tailscale, then click the copy button next to Server URL and paste only the URL here. It should look like `https://<MagicDNS name>:47443/mcp`.

If it starts with `http://`, HTTPS isn't set up yet. Ask them to follow the warning in msgblast's Tailscale section. That means turning on HTTPS Certificates in the Tailscale admin console under DNS, and then running the command from "Copy Command" in Terminal once. Then they copy the URL again.

Never ask for the key, and tell the person not to paste the `Authorization` header or its value into this chat. The key goes only into the connector's header field. If they paste a key anyway, tell them to open Set Up… for Grok Bot in msgblast, click New Key…, and use the new one in the connector.

Use the URL they pasted. Do not invent a host or a port.

## Guide them to add the connector

Tell them to add it in Grok Bot. You cannot add it for them.

1. Click Connect apps (three squares and a plus), scroll to the bottom of that page, and click Add a custom connector (or search "custom"). Type: Remote HTTPS. If a msgblast connector already exists, click Manage on it and edit that one instead of adding another.
2. Server URL: the URL they pasted.
3. Header: name `Authorization`. For the value, in msgblast click Set Up… on the Grok Bot (Tailscale) row, copy Value and paste it (`Bearer <key>`).
4. They save the connector.

Never suggest Tailscale Funnel. It makes the address public.

## Prove it

After they confirm the connector is saved, call the msgblast tool `msgblast_status`. The person approves that call in msgblast. The prompt names the client "Grok Bot (Tailscale)". Show them the result.

If the call fails, ask them to follow the warning in msgblast's Tailscale section, if there is one.
