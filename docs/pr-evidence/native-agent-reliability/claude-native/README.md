# Claude connection and complete replies

Captured on Pal's Studio on 2026-10-27 UTC with **msgblast Dev PR 84 (build 1)**,
executable source `edeaba8cb1ebaed805fd3f0ed6279c6d23753797`.
The existing Apple Development signing requirement, Dev support folder and
permissions were retained. This local candidate is not notarized.

Claude 3.6556.2 on macOS 27.0.1 began closed. One Connect reopened it and reached
Ready in the original Settings sheet, without a setup message or manual Claude
activation. A new comparison and its follow-up both returned their headings,
two paragraphs and final markers inside msgblast. Every reply segment matched
the native accessibility text independently. The saved comparison contains four
messages and two observed send receipts; its draft is empty and Sending cleared.

- [Closed-app Connect](cold-connect.png)
- [First complete reply](first-reply.png)
- [Completed follow-up](followup-completed.png)
- [Before the heading fix](before-heading-fix.png), executable source `e33424e`.

[Play the follow-up capture sequence](followup.mp4): 12 seconds of actual native
window captures before Send, during submission and after completion. Holds are
edited. This is not a continuous recording or a latency measurement. The images
are unmodified; the private full-desktop recording is not published.

[Validation](validation.json) records candidate identity, test results and limits.
[Read-only focus samples](focus-trace.json) ended with msgblast active after both
requests. They do not time brief foreground transitions. No manual focus repair,
resend or connection retry was used during either request.

The initial-window-shell regression failed before its repair. The reply-body
regressions separately detected a dropped visible heading and whitespace-only
responses. All 29 Claude tests passed after the repairs. The preceding shared
native run passed 221 tests; these counts overlap and are not additive.

These checks establish Claude's flow on this candidate. Muse remains unverified
pending sign-in handback. Gemini is deferred and unavailable in this build.
Other providers' separately dated evidence does not prove this candidate.
