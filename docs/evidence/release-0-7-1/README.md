# 0.7.1 combined patch evidence

Captured code and notes revision: `e50453f25ef1db541fa40842f1ece6b0bf32f477`.
Base: `1d8d4763fbc388cd3c6244057d3c97b00ddf1dd5`.
This combines the full heads of PRs #56, #58 and #60; the only merge conflict
was documentation, and both instructions were retained.

The native macOS 27.2 Demo screenshots and normal-speed selected-window video
show a 40-line individual reply sent only to Cedar, with its end revealed above
the composer. The recipient bar includes Muse despite its unselected state.
All agents and messages are local simulated data. Automatic fixture replies
are enabled in this combined-build capture; the screenshot is from submission
before the automatic reply. PR #60 separately records the same scroll behavior
with automatic replies disabled.

The original Business choices evidence in `../business-choices/` shows the
unchanged feature from that PR's stated revision. It is not a live Dev action
or a capture of this combined revision.

Validation: 345 native unit tests passed, 83 Python tests passed (one skipped),
and web comparison controller fixtures passed. Dev is a separate ad-hoc,
hardened-runtime functional app, with Contacts and Messages Automation
entitlements, blue-green compiled artwork, production updates disabled and
`msgblast-Dev` support storage. The green production source artwork is intact.

Publication is gated on the final reviewed source's functional Dev preflight.
No real send or Business selection was performed for these fixture captures.
