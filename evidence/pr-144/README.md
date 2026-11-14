# PR #144 access menu evidence (2026-11-14)

Build: "msgblast Dev (Access Menu 1114)", slot c (com.msgblast.development.test-c), head
c2afee47a61cddd199859c5ca2d991f0dc5b064f (includes main 9e2ecf8). Run in the msgblast-fg-lab VM, not the host.
The test client was a local stdio MCP session (`msgblast mcp`, clientInfo "Repro F1") that called only the
read-only `msgblast_status` tool. Nothing was sent to any agent or contact. All times are UTC.

## Setup

1. 00-03: Settings → Outside agents, "Allow agents on this Mac" turned on. Baseline: no outside-agents.json.

## F1: approval prompt with Full access, then ⌘W closes Settings

1. 08:18:03.7 client started; 10: "Repro F1 wants to use msgblast", level popup on Read only.
2. 11/12: popup opened, Full access chosen; the popup reads Full access.
3. 08:18:43.9 Allow clicked. File written 08:18:45.6: `{"Repro F1":2}`. Read at 08:18:47.0: same.
4. 08:18:47.1 ⌘W pressed once (about 3–5 s after Allow); 13: Settings closed.
5. Reads after ⌘W, all `{"Repro F1":2}` with the 08:18:45.6 modification time: 08:18:54.1, 08:18:57.1, 08:19:07.2.
6. 14: Settings reopened; the row reads "Repro F1 — Full access".

## Row level menu

| Step | Screenshot | File | Modification time |
|---|---|---|---|
| Menu opened: Read only, ✓ Full access | 20 | | |
| Read only chosen | 21 | `{"Repro F1":0}` (read 08:20:19.6) | 08:20:14.8 |
| Menu opened: ✓ Read only, Full access | 22 | | |
| Full access chosen | 23 | `{"Repro F1":2}` (read 08:20:47.3) | 08:20:43.6 |
| Menu opened: ✓ Full access | 24 | | |
| Full access chosen again (no change) | 25 | `{"Repro F1":2}` (read 08:21:14.8) | 08:20:43.6, unchanged |

## File watcher (0.2 s poll), complete log

```
08:18:45.805  {"Repro F1":2}
08:20:14.946  {"Repro F1":0}
08:20:43.822  {"Repro F1":2}
```

No write after Allow besides the prompt's own, none on ⌘W, and none when the level already set was chosen again.

## Video

`pr144-c2afee4-menu.mp4` (H.264, 1024×768, 115 s) runs from Settings being reopened through the last
no-op pick. The Allow and ⌘W part has screenshots and file reads only: the first recording attempt
stopped after 120 s without saving.

Screenshots and video are the VM's own screen; no host paths, usernames, IPs, tailnet names or keys.
