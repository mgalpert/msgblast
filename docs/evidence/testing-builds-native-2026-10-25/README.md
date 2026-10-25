# PR 75 final native and tooling validation

Evidence-SHA: cae4d75abdc5250581644eff86d1c455c55a046f
Base-SHA: 7676362e87e1097fa2cf933a045da8d724923bf8

Testing ran on the explicitly authorized **local Apple Silicon Mac** (Mac17,7),
macOS 27.2, Xcode 27.0 (27A5218g). Studio previously passed nine simulated
permission-controller checks, but lacked full Xcode. Full packaging, native
suites, controller fixtures, and actual GUI checks below ran locally after the
user authorized that Mac. A shared atomic worker lock serialized native activity
with PR 78; it was released after all validation apps and tests stopped.

## Real packages

Both final-revision packages were built using:

```sh
python3 scripts/build_preview_apps.py --variant all --universal \
  --sha cae4d75abdc5250581644eff86d1c455c55a046f \
  --run-url https://github.com/mgalpert/msgblast/pull/75 \
  --output build/pr75-cae4d75-universal
```

The actual apps and re-extracted ZIPs passed strict/deep ad-hoc signature checks.
All 11 Mach-O files in each app contain arm64 and x86_64, including the app,
debug libraries, frameworks, Sparkle helpers, cloudflared and CuaDriver. The
compiled icons are blue-green Dev and blue Demo; both retain hardened runtime
and the trusted Debug entitlements. Original package metadata verifies distinct
bundle IDs/support folders, Dev outside fixture mode, Demo inside fixture mode,
and blank production feed/key with updates disabled. ZIP hashes and per-binary
architecture results are in `package-inspection.json`.

The first real universal build exposed an invalid multi-architecture lipo
invocation. The new real clang/lipo regression failed before the repair and
passes with one verification call per architecture. It also rejects an actual
arm64-only helper. Native CI now runs this regression.

A real final Dev ZIP passed signer extraction/metadata/icon/architecture preflight,
then deliberately failed actual codesign using a nonexistent isolated identity
and keychain. No Apple credentials were imported or read, and no publishable ZIP
or manifest was produced. Notarization was not attempted. Credential lifecycle
unit tests use simulated Keychain/Apple responses.

## Native tests and fixtures

- Python: 115 collected, 114 passed, one skipped. Publisher module: 12 passed,
  including real clang/lipo and synthetic GitHub/signing rejection contracts.
- First full local native run: 694 passed, one skipped, one Dots sprite pixel
  assertion failed. That unchanged case passed on a focused rerun. The unchanged
  full serial rerun passed **695 tests, one skipped, zero failures**. No Swift
  production or test code was changed to obtain those passes. The first result
  remains recorded in `validation.json`.
- The native Accessibility smoke test skipped because its host was not already
  authorized. It never requested a grant.
- Isolated native UI menu/update test: one passed. It launched a dedicated test
  app with `--demo --isolated-demo` and verified the Updates unavailable result.
- Web/native-agent/restart controller fixtures passed, including durable native
  bindings, pending connections, approved/skipped setup, drafts and restart
  recovery. Configured CLI, report shutdown/persistence, and nine permission
  boundary fixtures passed. Their integrations/OS responses are controlled.
- Real isolated Sparkle harness: all five cases passed (install/preservation,
  unreadable-state recovery, no update, invalid signature, failed download).
- Actionlint and git diff checks passed. Final source CI passed at
  https://github.com/mgalpert/msgblast/actions/runs/40167376021.

Native suites reused compiled test bundles after verifying zero changes to native
source, project generation inputs, and Swift test source between their build and
the final revision. Universal distribution packages were rebuilt from the clean
final revision. This PR changes tooling/workflow code; native app code is unchanged.

## Actual GUI evidence and isolation limits

Existing installed Dev/Demo processes were kept running. The original packages
above were inspected without alteration. For GUI checks only, additional copies
received unique validation bundle IDs/support profiles and fresh ad-hoc signatures.
Their compiled code/resources stayed unchanged; mappings are recorded in
`validation-copies.json`. This is an explicit coexistence accommodation, not proof
of stable Developer ID identity or TCC retention across downloaded upgrades.

Dev launched **without Demo flags**, reached its real Allow access screen with
permissions unrequested, and displayed Updates unavailable. Demo launched with
its explicit fixture metadata and `--isolated-demo`, and showed the same disabled
updater result with sample data. No permission switches were enabled, and no real
Messages, Contacts writes, feedback submission, or paid model call was performed.
Only the validation copies were quit. Production installation/profiles were not
modified; all three original Dev/Demo processes were retained.

`dev-workflow.mp4` and `demo-workflow.mp4` are continuous native ScreenCaptureKit
captures, window-cropped and trimmed to 16 seconds, encoded as H.264. Timing was
not retimed. `dev-updates-disabled.png` is cropped to the Dev window from an actual
desktop capture, because window-only capture omitted the floating native alert.
Private desktop backgrounds and raw accessibility states were not published.

`package-check.jpg` shows execution against the real built apps. The tooling clip
contains 30 actual browser captures replayed at 3 fps with edited timing, showing
real package verification followed by publisher regressions. The report is
loopback-only evidence scaffolding. Publisher GitHub/signing responses are
synthetic; the real clang/lipo test is labeled separately. Raw sanitized output
is retained alongside the screenshots. Compiled-icon PNGs are actual exports.

The UI's Version 0.9.0 (1) is the checked-in development default, not a new
production/prerelease version or allocated production counter.

## Post-merge activation still required

No signed/notarized hosted testing prerelease was published. After this workflow
lands on main, a maintainer must request the reviewed source and approve the
signing environment. Verify build/sign/publish success, exact tag/source, Accepted
notarization, original Dev identity/profile, actual downloaded signatures/icons/
architectures, anonymous ZIP hash, and authorized install/relaunch behavior.
The runbook's first-hosted-activation checklist is the concrete next step. Neither
approval gates nor production release/signing/update configuration were bypassed.
