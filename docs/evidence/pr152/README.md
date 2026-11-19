# PR 152 evidence: late messages start a direct thread

Simulated: packaged blue **msgblast Demo** built from `6955653018c0bbfad190b630d72bc07d59026f71`,
launched with `--isolated-demo --late-message-preview` in the foreground test VM. No real Messages,
no real sends; all text is Demo sample data.

| File | Shows |
| --- | --- |
| `late-message-flow.mp4` | Send "What should we compare first?" to Cedar, reply, late pair, open "Cedar · Direct messages", reply "See you then" from it, next late pair, close dialog, End and Close (row becomes "Direct messages · Ended") |
| `a-conversation-list.png` | Both Cedar rows: the direct thread ("Direct messages") and the original conversation |
| `b-original-conversation.png` | Original conversation: only the prompt and its reply; Send to bar and both composers still present |
| `c-direct-thread.png` | Cedar's direct thread with the late pair and a single "Message" composer (no Send to bar) |
| `f-end-dialog.png` | Closing the direct thread: "End this thread with Cedar?" / "Keep the history. Their next message starts a new thread." |
| `g-direct-thread-after-reply.png` | Reply sent from the direct thread, simulated answer and the next late pair all stay in that thread |
| `h-list-after-end-new-thread.png` | After End and Close and a new prompt to Cedar: a new "Direct messages" row appears; the ended one reads "Direct messages · Ended" |
| `i-ended-direct-thread.png` | The ended direct thread keeps only what it showed |
| `j-new-direct-thread.png` | The new direct thread holds only the newest late pair |

Fixture evidence only; it does not establish live Messages behavior.
