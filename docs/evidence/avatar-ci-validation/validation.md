# Avatar release-test validation

The 0.4.0 job failed before publication on the two Muse avatar fixtures:
https://github.com/mgalpert/msgblast/actions/runs/37430553853

Waiting for generated image decoding did not resolve the runner-only failure.
The next check gives the avatar tests a real window-backed WebKit rendering
context, matching displayed avatar capture in the app, rather than relying on
detached-view rasterization. Product code and publication/signing behavior are
unchanged. CI now prints the exact XCResult assertion summary when core tests
fail. The CI-specific rendering hypothesis remains unconfirmed until the next
release job passes.

Local validation on October 6, 2026: both focused avatar tests passed; 35
release-tooling tests passed. Independent review found no blockers. The two
test windows use synthetic generated avatars and are detached/hidden afterward.
No live services, account changes, sends, or app installations were exercised.

This is a nonvisual test/CI change. A screenshot or video of the app would not
demonstrate whether detached image rasterization works on the GitHub runner.
The workflow result and assertion summary are the relevant evidence; unrelated
UI captures are deliberately not substituted for them.
