# Grok Bot over Tailscale

Grok Bot can call msgblast over your Tailscale network. Grok Bot's Tailscale connection only works with an `https://` URL that has a real certificate, so msgblast uses Tailscale Serve for that: Serve holds this Mac's `ts.net` certificate and forwards to msgblast on `127.0.0.1`. Nothing is shared with the public internet, and Tailscale Funnel is not used.

Other MCP clients on your tailnet can still use msgblast's plain `http://` address on this Mac's Tailscale addresses.

## Requirements

- Tailscale is running on the Mac that runs msgblast.
- Grok Bot 0.49 or newer is connected to the same tailnet through its Tailscale plugin.
- A company tailnet needs Tailscale Premium or Enterprise. A team admin enables it at cursor.com → Integrations → Tailscale.
- A personal tailnet works when the person owns or administers it.

## Setup

1. In msgblast, turn on Settings → Outside agents, then turn on "Let agents on other devices use msgblast over Tailscale". The first key is made for Grok Bot.
2. Once per tailnet: in the [Tailscale admin console](https://login.tailscale.com/admin/dns), under DNS, turn on HTTPS Certificates.
3. Once per Mac: in msgblast, click "Tailscale Serve → Copy command", paste it into Terminal and run it. The command is:

   ```sh
   tailscale serve --bg --https=47443 http://127.0.0.1:47480
   ```

   It uses its own port, 47443, so it leaves anything you already serve on 443 alone. `--bg` keeps it on after restarts. To undo it, run `tailscale serve --https=47443 off`. When the readiness line says "Tailscale Serve gives msgblast a private https:// address", the MCP server URL starts with `https://`.
4. In Grok Bot, open Connect apps → Your plugins → Tailscale → Authenticate.
5. In Grok Bot, choose Add a custom connector → Remote HTTPS. Paste the MCP server URL and the header from Settings → Outside agents ("Copy URL" and "Copy header", or both at once with "Copy setup" on the Grok Bot (Tailscale) row). Put the key only in the connector's header field, never in a chat message.
6. Ask Grok Bot to call `msgblast_status`. Approve it in msgblast. The prompt names the client "Grok Bot (Tailscale)".

The copied block looks like this, with your own URL and key:

```
msgblast MCP server for Grok Bot
Server URL: https://<MagicDNS name>:47443/mcp
Header: Authorization: Bearer <key>
```

Until Serve is set up, the URL is `http://<MagicDNS name>:47480/mcp`. Grok Bot needs the `https://` one, but other MCP clients can use either. The URL uses this Mac's MagicDNS name. If that name is missing, msgblast uses the Mac's 100.x address and says so. The key is shown once. After a relaunch, choose New key to see another one.

## Other MCP clients over Tailscale

Any MCP client that can reach this Mac over your tailnet and send an HTTP header can use the same endpoint, for example Claude Code or Codex on another computer. In Settings → Outside agents, type a name under the Tailscale section and choose **Add agent**. msgblast saves it as "<name> (Tailscale)" with its own key, so each agent has its own approval, access level, New key and Remove. Add the MCP server URL as a remote HTTP server in that client with that agent's header, for example:

```sh
claude mcp add --transport http msgblast http://<MagicDNS name>:47480/mcp --header "Authorization: Bearer <key>"
```

On its first call msgblast asks you to approve it, as for Grok Bot.

## Security

msgblast binds only to Tailscale addresses (IPv4 `100.64.0.0/10` and IPv6 `fd7a:115c:a1e0::/48` on `utun`) and to `127.0.0.1` for Tailscale Serve. It never binds a wildcard. On `127.0.0.1` it takes a request only when Serve's `X-Forwarded-For` names a tailnet address. Serve replaces any `X-Forwarded-For` that the caller sent. Every request still needs a key and your approval, wherever it came from. msgblast only reads `tailscale serve status`, and it never changes Tailscale settings. If Funnel is on for the Serve site, msgblast won't use the `https://` address and tells you to turn Funnel off.

The key is stored as a SHA-256 hash in `outside-agents-tailnet.json` (mode 0600), next to the other outside-agent file. The plaintext key stays in memory only until msgblast quits.

msgblast shows the approval prompt only after a valid key. Choose what that client may do. Remove in Settings deletes the approval and the key's hash.

Any device on the tailnet that has a key can call msgblast as that key's agent, so treat each key like a password. New key stops the old key at once but keeps the agent's approval level; Remove clears both. Copies that contain the key are marked concealed, so clipboard history apps skip them, and are cleared after 2 minutes.

Limits: a request over 1 MB gets 413, a request must arrive whole within 10 seconds (408), a connection idle for 60 seconds closes, and at most 16 connections are open at once.

On a personal tailnet, Grok Bot's device has the person's own tailnet access. A grant can limit that device to this Mac on the msgblast port. Replace the placeholders with the device and the Mac:

```hujson
{
  "grants": [
    {
      "src": ["<grok-bot-device>"],
      "dst": ["<your-mac>"],
      "ip": ["tcp:47443", "tcp:47480"],
    },
  ],
}
```

## Readiness

The Tailscale card shows up to three lines; the Grok Bot line appears only while Grok Bot has a key. When the macOS firewall is on, one more line appears right after the Tailscale line and says whether msgblast may accept incoming connections. msgblast only reads that state.

- "Tailscale isn't connected on this Mac." Open Tailscale on this Mac and sign in. "Connected as" followed by the MagicDNS name means that name was found.
- "HTTPS certificates are off for this tailnet." Turn on HTTPS Certificates in the Tailscale admin console under DNS. Grok Bot needs `https://`.
- "Grok Bot needs https://. Run this once in Terminal: …" Certificates are on, but Tailscale Serve doesn't point at msgblast yet. Use "Copy command" and run it.
- "Tailscale Funnel makes msgblast's HTTPS port public …" Run `tailscale funnel --https=47443 off`. msgblast keeps the `http://` URL until Funnel is off.
- "Tailscale Serve gives msgblast a private https:// address." The MCP server URL is ready for Grok Bot.
- "No Grok Bot device on your tailnet yet" means the Tailscale plugin is not connected. In Grok Bot, use Connect apps → Your plugins → Tailscale → Authenticate. "A Grok Bot device is on your tailnet" means that device is visible and has not called yet. Copy the setup block and add the connector, then ask for `msgblast_status`. "Grok Bot last called …" means a request passed the key check. Approve it in msgblast if the prompt is waiting.

## Troubleshooting

- Grok Bot cannot reach the URL. Use the MagicDNS name from the card, not a public DNS name that points at a 100.x address. The URL must start with `https://`. If it starts with `http://`, follow the readiness line about HTTPS.
- Grok Bot gets a certificate error on its first call. A new `ts.net` certificate can take a minute to issue. Try again.
- Grok Bot can't connect, and the macOS firewall is on: open System Settings → Network → Firewall → Options and allow msgblast to accept incoming connections (or answer Allow when macOS asks). msgblast only reads the firewall state; it never changes it.
- The key was copied before a relaunch. Make a new key and copy the setup block again.
- Remove was clicked. Turn the Tailscale toggle on again if it is off, make a new key, and approve the next call.
- A company tailnet refuses the Tailscale plugin. A team admin enables it at cursor.com → Integrations → Tailscale. The tailnet needs Tailscale Premium or Enterprise.
