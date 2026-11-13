# Evidence: ChatGPT panel fix and background Send (PR #123)

Build under test: msgblast Dev (Fixes 1111 VM), source b103ea10b362 (Info.plist msgblastSourceRevision),
in the msgblast-fg-lab macOS VM, ChatGPT 26.1103.60933. Test prompts are throwaway.

- 01-connect-chatgpt-dots-ready.png: build 2f1c53c on the host; ChatGPT and Dots connection checks pass on 26.1103.
- 02-ab-screen-msgblast-waits.png: b103ea1; ChatGPT answered with its "Compare responses" A/B screen. msgblast attributes no reply and keeps waiting.
- 03-chatgpt-send-reply-b103ea1.png: b103ea1; background send "reply with only the word ALPHA", reply ALPHA shown within 26 s.
- 04-chatgpt-background-send-b103ea1.mp4: the same send, cropped to the msgblast window (VM screenshots about every second, 2 fps). msgblast stays the active window throughout; ChatGPT never comes to the front.
