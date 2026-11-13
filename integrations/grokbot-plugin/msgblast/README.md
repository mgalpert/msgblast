# msgblast

Draft Grok Bot plugin. Not published. Not available in Cursor.

Grok Bot 0.49 or newer can call msgblast on the person's Mac over a shared Tailscale network. This plugin does not ship an `mcp.json`. Every Mac has its own Server URL. The person copies it from msgblast.

## Who can use it

- Grok Bot 0.49 or newer, with the Tailscale plugin connected to the same tailnet as the Mac.
- A company tailnet needs Tailscale Premium or Enterprise and a team admin enabling it at cursor.com → Integrations → Tailscale.
- A personal tailnet needs the person to own or administer it.

## Setup

The `msgblast-setup` skill walks through the steps. It cannot add the connector by itself.

1. In msgblast, turn on Outside agents and the Tailscale toggle.
2. In Grok Bot, Connect apps → Your plugins → Tailscale → Authenticate.
3. Ask the person for the Server URL only, from msgblast's "Copy URL" button. Never ask for the key, the header, or the "Copy setup" block in chat.
4. Guide them to Add a custom connector → Remote HTTPS, with that Server URL, and to paste the header from msgblast's "Copy header" button straight into the connector. The key never goes into chat.
5. Call `msgblast_status`. The person approves it in msgblast.

## License

MIT
