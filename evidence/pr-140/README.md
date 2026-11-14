# PR #140 telemetry evidence (2026-11-14)

Build: "msgblast Dev (Analytics 1114)", slot b (com.msgblast.development.test-b), head
1ef0229fe1cb7d26dd09143700381affbc82a8c2 (includes main 675afc5), dev telemetry to
https://msgblast.app/api/telemetry (Worker version 2057531e). Run in the msgblast-fg-lab VM, not the host.

1. 01: sharing choices, all five categories on.
2. 02: ChatGPT app agent connected ("Ready").
3. 03: "analytics check 1" sent from the Mac window (06:16:28Z); ChatGPT replied.
4. 04/05: MCP client "Codex" approval prompt with Full access selected; after Allow, Settings showed
   Codex as Read only and the first send call was refused ("This needs Full access"). Set to Full access in
   Settings; possible bug in the approval prompt's level picker.
5. 06: "analytics check 2" sent with msgblast_agent_message over the stdio MCP server (outcome done,
   ChatGPT status observed, 06:21:20Z).
6. 07: PostHog rows (buildChannel = development, last hour), queried 06:23Z.

Screenshots are cropped to msgblast's own windows; no IPs, tailnet names, usernames or keys.
No screen recording: screencapture inside the VM failed to save (/tmp/fg-lab.mov) for both attempts.
Phone send skipped (no phone paired in the VM).
