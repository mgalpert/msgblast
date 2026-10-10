# Combined 0.6.10 release notes

Reviewed notes source: `248f0703bbd4e51a6622440186e04486bc74f8a1`.
The preview was built from `f30b60ebb376ae4e3b8506cb6694c6e3b05ad639`;
`git diff` confirms its tree is identical to the reviewed source above.

Native CUA captures show opening What's New, reading the three highlights and
contributor credits, opening Full release notes, and scrolling to the credits.
The blue Demo was copied with symlinks preserved, given the unique identity
`com.msgblast.demo.release-notes-0610` and support folder
`msgblast-ReleaseNotes-Demo`, and ad-hoc signed and strictly verified.
Its local marketing-version metadata was set to 0.6.10 to preview the notes;
this is not a published or installed production release. Demo mode remains
enabled and production updates remain disabled. No app source was edited.

`workflow.mp4` is an edited 12-second H.264 sequence of actual native screenshot
samples taken around CUA interactions, with repeated frames and edited timing.
It is not a continuous real-time recording. No interface pixels or text were
generated. All visible conversation/agent data is synthetic. No live requests,
browser-cookie reads, sign-ins, permission changes, or real sends occurred.

Contributor attribution was verified against PR #32's author and retained commits.
No additional app tests were added for this notes-only change. The three feature
PRs passed evidence, Linux, and native core/updater CI before integration.
The final functional Dev release preflight is a separate publication gate.
