# Grok Bot over Tailscale

Grok Bot can call msgblast over your Tailscale network. msgblast listens for HTTP MCP on this Mac's Tailscale addresses. Grok Bot uses a remote connector. Nothing is shared with the public internet, and Tailscale Funnel is not used.

msgblast speaks `http://` only. It does not serve `https://` yet. Settings checks whether this tailnet has HTTPS certificates so you can see that before Grok Bot asks for an `https://` address.

## Requirements

- Tailscale is running on the Mac that runs msgblast.
- Grok Bot 0.49 or newer is connected to the same tailnet through its Tailscale plugin.
- A company tailnet needs Tailscale Premium or Enterprise. A team admin enables it at cursor.com → Integrations → Tailscale.
- A personal tailnet works when the person owns or administers it.

## Setup

1. In msgblast, turn on Settings → Outside agents, then turn on "Let Grok Bot use msgblast over Tailscale".
2. In Grok Bot, open Connect apps → Your plugins → Tailscale → Authenticate.
3. In Grok Bot, choose Add a custom connector → Remote HTTPS. Paste the Server URL and the header from msgblast ("Copy URL" and "Copy header", or both at once with "Copy Grok Bot setup"). Put the key only in the connector's header field, never in a chat message.
4. Ask Grok Bot to call `msgblast_status`. Approve it in msgblast. The prompt names the client "Grok Bot (Tailscale)".

The copied block looks like this, with your own URL and key:

```
msgblast MCP server for Grok Bot
Server URL: http://<MagicDNS name>:<port>/mcp
Header: Authorization: Bearer <key>
```

The default port is 47480. The URL uses this Mac's MagicDNS name. If that name is missing, msgblast uses the Mac's 100.x address and says so. The key is shown once. After a relaunch, choose New key to see another one.

## Security

msgblast binds only to Tailscale addresses (IPv4 `100.64.0.0/10` and IPv6 `fd7a:115c:a1e0::/48` on `utun`). It does not bind a wildcard, loopback, or Funnel.

The key is stored as a SHA-256 hash in `outside-agents-tailnet.json` (mode 0600), next to the other outside-agent file. The plaintext key stays in memory only until msgblast quits.

msgblast shows the approval prompt only after a valid key. Choose what that client may do. Remove in Settings deletes the approval and the key's hash.

On a personal tailnet, Grok Bot's device has the person's own tailnet access. A grant can limit that device to this Mac on the msgblast port. Replace the placeholders with the device and the Mac:

```hujson
{
  "grants": [
    {
      "src": ["<grok-bot-device>"],
      "dst": ["<your-mac>"],
      "ip": ["tcp:47480"],
    },
  ],
}
```

## Readiness

The Tailscale card shows three lines.

- "Tailscale isn't connected on this Mac." Open Tailscale on this Mac and sign in. "Connected as" followed by the MagicDNS name means that name was found.
- "HTTPS certificates are off for this tailnet." msgblast keeps using `http://`. If Grok Bot asks for `https://`, an admin can turn certificates on in the Tailscale admin console under DNS. "HTTPS certificates are on for this tailnet" means that array is set. msgblast still does not serve `https://`.
- "No Grok Bot device on your tailnet yet" means the Tailscale plugin is not connected. In Grok Bot, use Connect apps → Your plugins → Tailscale → Authenticate. "A Grok Bot device is on your tailnet" means that device is visible and has not called yet. Copy the setup block and add the connector, then ask for `msgblast_status`. "Grok Bot last called …" means a request passed the key check. Approve it in msgblast if the prompt is waiting.

## Troubleshooting

- Grok Bot cannot reach the URL. Use the MagicDNS name from the card, not a public DNS name that points at a 100.x address.
- The key was copied before a relaunch. Make a new key and copy the setup block again.
- Remove was clicked. Turn the Tailscale toggle on again if it is off, make a new key, and approve the next call.
- A company tailnet refuses the Tailscale plugin. A team admin enables it at cursor.com → Integrations → Tailscale. The tailnet needs Tailscale Premium or Enterprise.
