# Instinct contact photo

Native macOS CUA captures from application source `ecbf3f9dce67ec05fbdf8e263c06b6042f064dbf`. The blue msgblast Demo uses simulated Contacts, example.com addresses, permissions, and conversations. Instinct’s artwork is the actual user-requested contact photo; the private contact export is excluded.

The screenshots show the updated picker, selecting the Messages agents, the grouped confirmation rows, and the feedback screen after Connect selected. The video is an edited sequence of these screenshots around real clicks, with repeated frames and scaled/padded window captures; it is not a continuous screen recording. No mobile UI changed.

Isolated Demo and Dev builds passed and both package the exact JPEG. The one-line photo precedence change was reviewed against ContactSearch’s existing thumbnail fetch. Live Contacts fetch verification remains pending before production publication. The original Dev workspace was restored and all file hashes matched.
