# Muse avatar PNG readback

The 0.3.0 release attempts at revision `37419e1abc55f04ae97a8b1a148bd16a5fbe9522` stopped before publication. Both failed `testPersonalAvatarFollowsTheMainChatMediaAndChanges` and `testAvatarClearsOnSignOutAndIsNotPersistedForAnotherAccount` on the Actions runner, while the full 121-test suite passed locally through both direct XCTest and Xcode's test launcher.

## Cause and fix

The runner's WebKit could not allocate a GPU IOSurface. The fixture's canvas exported `data:,` instead of a PNG, so its image was complete but broken, with natural width and height zero. The avatar reader correctly rejected it. Hosting the view in an AppKit window did not restore canvas export; that experiment was removed.

The production avatar reader now requests `willReadFrequently: true` when it crops media and exports a 256×256 PNG. PR #12 supplies deterministic PNG fixture inputs separately; its fixture change is retained on integration. This selects backing suited to pixel readback instead of requiring GPU surfaces. The source-image selection, same-source cache, sign-out clearing, permissions and send behavior are unchanged. The existing wait helper now reports the caller's file and line when it fails.

## Evidence

- Original release failures: [attempt 1](https://github.com/mgalpert/msgblast/actions/runs/37428767394/attempts/1), [attempt 2](https://github.com/mgalpert/msgblast/actions/runs/37428767394/attempts/2).
- [Diagnostic failure](https://github.com/mgalpert/msgblast/actions/runs/37430870182): generated source and independent default canvas both exported only `data:,`; image dimensions were zero.
- [Window-hosting experiment](https://github.com/mgalpert/msgblast/actions/runs/37431299539): still failed, with explicit IOSurface creation errors. No window-hosting change is part of the fix.
- [CPU-backed rendering check](https://github.com/mgalpert/msgblast/actions/runs/37431682074), diagnostic revision `38af10b`: **2 tests, zero failures** on the same runner type. The source was a valid PNG with 256×256 dimensions. An independent default canvas still exported `data:,` in the same process, establishing that CPU backing changed the result.
- The two existing tests also passed locally with the rendering change. The full Xcode run passed **128 tests, zero failures** on integration base `c82a5d8` (including concurrently merged PRs #7 and #11) with CPU-backed canvas fixture inputs. The final integrated deterministic PNG fixtures are checked by the release workflow.

Diagnostics use synthetic local HTML and avatar images. No user account, network request, outgoing message or production install is involved. Diagnostic logging and the temporary workflow are on a separate branch and are excluded from this fix. Local checks ran on macOS 27.2; Actions used macOS 27.0. This is not a Sequoia runtime test.

## Review

Small scoped review against `c82a5d8` found no correctness issues. The production PNG-readback canvas uses the standard CPU-backing hint. Test expectations are unchanged; no test is skipped. No refactor or broader simplification is needed for the rendering call site and diagnostic-location change.

## Screenshots and video

This change affects offscreen image readback and test diagnostics, with no intentional UI change. A screenshot or interaction video would not distinguish the GPU allocation failure from a valid fallback avatar. The linked private Actions runs provide the actual failing and passing test workflow, values and results instead. No unrelated UI capture is substituted. The unchanged web-agent UI remains documented in PR #3.
