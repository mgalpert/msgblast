# Evidence: ChatGPT panel fix and background Send (PR #123)

Test setup: the msgblast-fg-lab macOS VM, ChatGPT 26.1103.60933, test copy "msgblast Dev (Fixes 1111 VM)".
Test prompts are throwaway. Screenshots and video are cropped to the msgblast window.

Final head: 1613e310a9751e1425dbc9abec61925df71b203e (Info.plist msgblastSourceRevision 1613e310).

From the final head 1613e31:
- 05-connected-after-reopen-1613e31.png: ChatGPT running with its main window closed and hidden; Connect reopened the window in the background (one flash of about 0.07 s, see 08) and the connection is ready.
- 06-chatgpt-background-send-1613e31.mp4: New Blast to ChatGPT, "msgblast test 3 of 3: reply with only the word ALPHA", through to the reply. ChatGPT had been put on a new chat first (background press of its New chat button). msgblast stays the active app throughout; ChatGPT never comes to the front.
- 07-chatgpt-send-reply-1613e31.png: the same send with the reply ALPHA shown.
- 08-front-app-log-1613e31.txt: the VM's front-app log for the three Connect cases (quit, hidden with a window, window closed and hidden) and for the send, with the measured flashes.

From earlier builds (kept for history):
- 01-connect-chatgpt-dots-ready.png: build 2f1c53c on the host; ChatGPT and Dots connection checks pass on 26.1103.
- 02-ab-screen-msgblast-waits.png: ChatGPT answered with its "Compare responses" A/B screen. msgblast attributes no reply and keeps waiting.
- 03-chatgpt-send-reply-b103ea1.png and 04-chatgpt-background-send-b103ea1.mp4: despite the b103ea1 in their names, these ran on a binary built from 2a49736 (the test copy had not been restarted). The ChatGPT send code is the same as at b103ea1; the focus handling has changed since, so use 06/07 for the final head.
