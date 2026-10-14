These captures come from an isolated build of the submitted revision (bundle ID
`com.msgblast.evidence`, its own `msgblast-Evidence` support folder, updates
disabled, no production state). They show a live DSH CLI conversation: the app
starts the installed `dsh` command, sends the prompt, and stores the completed
reply. No fixture or simulated reply is used, and no other agent is enabled in
that build, so the surrounding desktop and any other accounts are excluded.

`dsh-picker.jpg` shows the agent picker with DSH in the grid and selected.

`dsh-live-reply.jpg` shows the comparison after the turn completed: "DSH · Local
account" in the pane header, the sent prompt, and the reply that the CLI's
`final` event produced.

`dsh-live-reply.mp4` is the app-window recording of that turn (40 seconds at
960×540, no desktop). It starts with the picker and the prepared prompt, shows
the send, and ends with the completed reply.

The prompt asks DSH about itself, so the reply content is incidental; the same
capture would work with any prompt. The app window is a resized single-chat
comparison, which is why the pane is narrow.

Capture revision: `953a711ed8d653f9628ce1c420932b87669e750c`, the commit that
carries the DSH adapter and its tests. The evidence commit that adds these files
is a head commit on top of it; it changes only this folder.
