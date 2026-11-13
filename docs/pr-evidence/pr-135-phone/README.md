# PR 135 / PR 125 phone check through iPhone Mirroring (head a563f97)

Evidence-SHA: a563f974c87401fd0e5d58a617e074d9dacfff03 (PR 135, includes PR 125 at d7de844)

Mac: "msgblast Dev (Alexa 1113)" built from a563f97. iPhone: msgblast built from a563f97.
Captured from the iPhone Mirroring window only. Alexa's replies are blanked in the video
and the personalized purchase-history line is blanked in screenshot 3.

1. `1-inbox.png`: the phone inbox after reconnecting, no "Connecting…" or "Not connected".
2. `2-new-thread-only-alexa.png`: a new conversation starts empty, with only the agent
   selected on the Mac preselected (Alexa), not rabbit OS3.
3. `mirror-new-alexa-thread.mp4` (2x speed): opening an older thread, starting a new Alexa
   thread, sending from the phone, "still replying" while Alexa answers, then the reply.
4. `3-reopened-thread-saved-replies.png`: after leaving and reopening the new thread, its
   replies are still there (saved by the Mac; 4 turns saved for that thread).

Not shown: Alexa returned text-only answers in this run ("every product search failed" on
Amazon's side), so no product cards or photos appeared to tap. Product photos on the phone
were confirmed earlier by msg on the c5b1e29 build, and the Mac downloaded 8 product photos
at b300ed6. Older threads whose replies predate the saved-turns fix stay empty.

## Product photos on the phone (second run, 12:30 local)

Prompt "Show me water bottles" sent from the phone in a new Alexa thread.

5. `4-product-lines-with-photos.png`: product lines with a photo under each (end of the reply).
6. `5-photo-opened.png`: tapping a photo opens it full size.
7. `6-reopened-photos-kept.png`: after leaving and reopening the thread, each product keeps its photo.
8. `mirror-product-photos.mp4`: the same steps, Mirroring window only.

The Mac saved this reply as 10 product lines, each with its photo; the 8 Amazon products carry
an amazon.com/dp/ link. Not shown: opening a link. Scrolling through iPhone Mirroring did not
work, so only the two non-Amazon web results at the end of the reply were on screen.
