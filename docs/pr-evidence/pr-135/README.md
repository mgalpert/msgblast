# PR 135 evidence: Alexa product photos (head b300ed6)

Evidence-SHA: b300ed64745172412971517e1a8fa48bd8ca18b4 (stacked on PR 125 at 5bb4840)

## What was checked on the Mac (background only, no focus taken)

- Test copy "msgblast Dev (Alexa 1113)" rebuilt in place from b300ed6, keeping its
  Amazon sign-in. One shopping prompt sent from the shared composer, to Alexa only.
- `mac-alexa-reply-b300ed6.png`: the Alexa pane after the reply, showing product cards
  with photos. Alexa's personalized intro sentence is blanked.
- PR 125's part (product text lines): the reader at 2abe715 was run against the real
  reply DOM in an offscreen WebKit view; every product became one line
  (title, price, rating, blurb, amazon.com/dp link). Headers read cleanly, with no
  "Purchased" badges or duplicates.
- PR 135's part (photo URLs): the reader at ce10fee, run the same way, returned exactly one
  Amazon CDN image URL per product card and none for headers or text sections.
- The downloader at b300ed6 fetched a real product image (image/jpeg, 160 KB) with the
  shipped code, standalone, and stored it under its SHA-256 name.

## Not shown yet

- Photo downloads in the running app start only while a phone is connected:
  the remote projection runs while a client is attached (`RemoteService.clientChanged`).
  With the phone handed back, no download happened in the app, as designed.
- Photos on the iPhone, opening a link, and reopening the conversation: pending the
  phone check (iPhone Mirroring was paused on another Space; it was not brought forward).
- No screen recording: the region capture picked up another window overlapping the app,
  so it was discarded rather than published.
