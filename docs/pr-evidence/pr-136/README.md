# PR #136 phone evidence (simulator)

All captures come from the iOS Simulator paired to the Demo Mac fixture
(`scripts/run_demo_mac.sh`). Both were built from b452eae, which includes main
39d1622. No real messages were sent.

- A, first New Conversation after a fresh launch: passed. Adding the website agent
  rabbit OS3 Web, which wasn't preselected, showed a quiet "Getting ready…" (about
  0:10 in the video) that then cleared. There was no "Mac did not answer" and no
  Try Again (`01-first-new-conversation.png`).
- B, the Mac keeps its own conversation: not run live. The `remote_control_model`
  fixture's `checkRemoteWebsiteSend` covers it in CI.
- C, reopening an old thread after 62 s in the background: passed. There was no
  "Connecting…" under the title and no "Not connected" above the field, and tapping
  the field showed nothing orange (`02-old-thread-quiet.png`).

`pr136-phone.mp4` covers A and C. It starts after pairing, so the Mac key
fingerprint isn't shown.
