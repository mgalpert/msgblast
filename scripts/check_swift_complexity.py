#!/usr/bin/env python3
"""Compare pinned SwiftLint metrics against the merge base, without a stored baseline."""
import argparse
import hashlib
import json
import re
import subprocess
import tempfile
from pathlib import Path

VERSION = "0.65.1"
CONFIG = """only_rules: [function_body_length, cyclomatic_complexity]
function_body_length: {warning: 50, error: 50}
cyclomatic_complexity: {warning: 10, error: 10}
"""


def git(*args):
    return subprocess.check_output(["git", *args])


def sources(revision):
    result = {}
    for entry in git("ls-tree", "-rz", revision).split(b"\0"):
        if not entry:
            continue
        metadata, path = entry.split(b"\t", 1)
        mode, kind, oid = metadata.split()
        if path.endswith(b".swift") and mode in (b"100644", b"100755"):
            result[path.decode()] = git("cat-file", "blob", oid.decode()).decode()
    return result


def analyze(executable, files):
    if not files:
        return []
    with tempfile.TemporaryDirectory(prefix="msgblast-complexity-") as directory:
        root = Path(directory)
        for name, source in files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(source.replace("swiftlint:", "lint-directive-disabled:"))
        config = root / "rules.yml"
        config.write_text(CONFIG)
        run = subprocess.run([executable, "lint", "--quiet", "--no-cache", "--config",
                              str(config), "--reporter", "json", str(root)],
                             capture_output=True, text=True)
        if run.returncode not in (0, 2):
            raise ValueError(f"SwiftLint failed ({run.returncode}): {run.stderr[:1000]}")
        report = json.loads(run.stdout)
        for item in report:
            item["file"] = str(Path(item["file"]).relative_to(root))
        return report


def metrics(report, files, aliases=None):
    aliases = aliases or {}
    result = {}
    for item in report:
        path, line = item["file"], item["line"]
        lines = files[path].splitlines()
        declaration = lines[line - 1].strip()
        identity = declaration.split("{", 1)[0].strip()
        # Ambiguous overload/type declarations cannot borrow one another's budget.
        # Grandfather them only in an unchanged file; edits must bring them under limits.
        if sum(text.strip().split("{", 1)[0].strip() == identity for text in lines) > 1:
            digest = hashlib.sha256(files[path].encode()).hexdigest()[:16]
            identity += f" [file {digest}, line {line}]"
        match = re.search(r"currently (?:spans (\d+) lines|complexity is (\d+))", item["reason"])
        if not match:
            raise ValueError("Unrecognized SwiftLint metric: " + item["reason"][:200])
        value = int(next(group for group in match.groups() if group is not None))
        key = (aliases.get(path, path), identity, item["rule_id"])
        if key in result:
            raise ValueError(f"Ambiguous SwiftLint declaration: {path}:{line}")
        result[key] = value
    return result


def regressions(old, new):
    return [(key, value, old.get(key)) for key, value in new.items()
            if key not in old or value > old[key]]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--swiftlint", default="swiftlint")
    args = parser.parse_args()
    version = subprocess.check_output([args.swiftlint, "version"], text=True).strip()
    if version != VERSION:
        raise ValueError(f"Expected SwiftLint {VERSION}, got {version}")
    base = git("merge-base", args.base, args.head).decode().strip()
    old_files, new_files = sources(base), sources(args.head)
    # Git's rename detection preserves a function budget when its file moves.
    changes = iter(git("diff", "--name-status", "-z", "-M", base, args.head).split(b"\0"))
    aliases = {}
    for status in changes:
        if not status:
            break
        old_path = next(changes).decode()
        if status.startswith((b"R", b"C")):
            new_path = next(changes).decode()
            if status.startswith(b"R"):
                aliases[new_path] = old_path
    old = metrics(analyze(args.swiftlint, old_files), old_files)
    new = metrics(analyze(args.swiftlint, new_files), new_files, aliases)
    failures = regressions(old, new)
    for (path, declaration, rule), value, previous in failures[:20]:
        print(f"FAIL {path}: {rule} {value} (base {previous or 'within limit'}): {declaration[:160]}")
    print(f"SwiftLint {VERSION}: {len(failures)} new/worsened metrics; {len(new)} existing metrics.")
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
