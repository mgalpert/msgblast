# Busy agents and available recipients

Captured from committed source `1eb65251463ddf03e651a98852d72c8447169a24` in the isolated blue **msgblast Demo PR 87 (build 1)**. The later evidence-only commit does not change executable code.

Wabi’s earlier pending request is seeded. Claude and Cedar Messages use simulated transports and synthetic identities. No real provider or Messages request was sent for this recording. It shows disabled Busy selection, an available App Agent and Messages recipient completing the broadcast, and the Busy agent’s saved choice and pending request remaining intact. Wabi has no empty pane in the comparison it did not join.

The native controller regression also completes the older request and sends a follow-up through the real composer; that follow-up remains restricted to the current comparison’s recipients. The completion is simulated and not part of this video.

The three screenshots show the actual window before sending, its two completed recipient panes, and the unchanged Busy tile after returning to Agents. `busy-agents.mp4` is the actual interaction at 2× playback with a three-second final hold. It is cropped to the Demo window; the unused right edge is masked starting just before the window narrows. No provider latency or live delivery is demonstrated. Functional Dev and live App Agent validation are reported separately in PR #87.
