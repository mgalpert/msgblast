# Crash-report review evidence

App source: `5c7bd96afa777018e3894de3baadc1929070c970`. Base: `b8bf6143f4875a1b6de9372335bf77dae8035f75`. The following commit adds evidence only; application code is unchanged.

## Captured workflow

- `review.png`: exact sanitized payload and optional context before consent.
- `uncertain.png`: frozen context after an uncertain response; Retry remains available.
- `sent.png`: confirmed receipt and disabled duplicate submission.
- `dev-empty.png`: Help review in a separate non-Demo development profile, with no eligible report.
- `workflow.mp4`: continuous native-window recording of context entry, Send, uncertain response, Retry, and confirmation. The final static hold was trimmed from 35 to 18 seconds; interaction timing is unchanged. No audio.

The Demo evidence uses two **synthetic Apple-format IPS files**, not a deliberately crashed process. Both pass through the actual crash collector. The actual native controller submits to the actual Worker handler over loopback, backed by an in-memory fixture store. The fixture returns a simulated 503 after storage on the first submission. Retry sends the identical report ID and context: two requests, one stored report. Synthetic version/build values in the screenshots are fixture data.

The preview apps were built from the source revision above. Only task-owned bundle identity, support profile and (for Demo) loopback endpoint metadata were adjusted for local capture, then the outer app signature was resealed ad-hoc. The user's installed app, profile and permissions were untouched.

Manual relaunch checks confirmed startup detection, selection of the newly eligible incident, remembered submission and dismissal, and Help review availability. A separate non-Demo Dev profile excluded the Demo reports and disabled Send. The two synthetic IPS files were removed afterward.

## Validation

- Dedicated build Mac, Xcode 27.0: full `msgblastTests` suite, **364 passed**.
- `node --test feedback/worker.test.mjs`: **14 passed**.
- `python3 -m unittest discover -s scripts/tests -p 'test_*.py'`: **97 tests, zero failures, one skipped**.
- `bash scripts/test_crash_reporting.sh build/crash-tests`: actual native controller to actual Worker handler; verifies consent, uncertain-response retry, frozen journal recovery, one stored report, duplicate blocking, editable oversized context and selection context clearing.
- Isolated unsigned arm64 Release archive: app and core dSYMs present and UUIDs match their binaries.
- `git diff --check`: passed.

Regression failures were reproduced before fixes for the archive allowlist and equivalent retry payloads with reordered object keys. Review findings about pending-report recovery, incident selection and context isolation were also applied and checked.

## Limits

No production intake was deployed and no app was released. The native UI test suite was not run; the UI was exercised manually and through the controller fixture. Synthetic IPS files do not establish that macOS generated a real crash report. The symbol check used an isolated unsigned archive, not a production release artifact. Live account submission and distributed-update permission retention were not tested. No real Messages send, Contacts write, paid model call or permission reset was used.

`validation.json` records the checks, fixture details and media SHA-256 digests. Production intake deployment remains a separate action before shipping an app that sends crash payloads.
