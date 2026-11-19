# PR 152 evidence: late messages start a direct thread

Simulated: packaged blue **msgblast Demo** built from `55aea37ff1430e83968181de29b8d79e98581fd5`,
launched with `--isolated-demo --late-message-preview` in the foreground test VM. No real Messages,
no real sends; all text is Demo sample data.

| File | Shows |
| --- | --- |
| `late-message-flow.mp4` | Send "What should we compare first?" to Cedar, reply, late pair arrives, list gains "Cedar · Direct messages", open it |
| `a-conversation-list.png` | Both Cedar rows: the direct thread ("Direct messages") and the original conversation |
| `b-original-conversation.png` | Original conversation holds only the prompt and its reply |
| `c-direct-thread.png` | Cedar's direct thread holds "Running late, see you at 7" and "No problem, see you then" |
| `d-list-after-second-send.png` | After a second prompt to Cedar: still one direct row, plus the new conversation |
| `e-direct-thread-after-second-send.png` | The second late pair joins the same direct thread |

Fixture evidence only; it does not establish live Messages behavior.
