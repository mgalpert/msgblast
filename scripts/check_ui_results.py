"""Require an actual passing UI run, not an empty or skipped test selection."""
import json
from pathlib import Path
import sys


def check(summary):
    if not isinstance(summary, dict):
        raise ValueError("UI test summary must be an object")
    counts = [summary.get(name) for name in ("totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures")]
    if any(type(value) is not int or value < 0 for value in counts):
        raise ValueError("UI test summary has missing or invalid counts")
    total, passed, failed, skipped, expected = counts
    if summary.get("result") != "Passed" or total == 0 or passed != total or failed or skipped or expected:
        raise ValueError(f"UI run incomplete or failing: total={total}, passed={passed}, failed={failed}, skipped={skipped}, expected failures={expected}")
    return passed


if __name__ == "__main__":
    try:
        passed = check(json.loads(Path(sys.argv[1]).read_text()))
    except (IndexError, OSError, ValueError, TypeError) as error:
        print(f"UI verification failed: {error}", file=sys.stderr)
        sys.exit(2)
    print(f"PASS: {passed} UI tests actually executed; no failures or skips")
