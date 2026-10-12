#!/usr/bin/env python3
"""Run a committed revision on an explicit SSH Mac; never fall back locally."""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import threading


ROOT = Path(__file__).resolve().parents[1]
SUITES = ("core", "controllers", "updater", "ui", "all")


def machine_id():
    if platform.system() != "Darwin":
        return None
    result = subprocess.run(["ioreg", "-rd1", "-c", "IOPlatformExpertDevice"], capture_output=True, text=True, check=True)
    match = re.search(r'"IOPlatformUUID" = "([^"]+)"', result.stdout)
    if not match:
        raise RuntimeError("Cannot identify this Mac; refusing a potentially local test run")
    return match[1]


def ssh_command(host, arguments):
    if not re.fullmatch(r"(?:[A-Za-z0-9_.-]+@)?[A-Za-z0-9][A-Za-z0-9_.-]*", host):
        raise ValueError("Use an SSH alias or user@hostname (configure ports/keys in ~/.ssh/config)")
    return ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", host, shlex.join(arguments)]


def revision(ref):
    result = subprocess.run(["git", "rev-parse", "--verify", ref + "^{commit}"], cwd=ROOT, capture_output=True, text=True, check=True)
    sha = result.stdout.strip()
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise RuntimeError("Expected a full Git commit SHA")
    return sha


def prepare(host, sha, developer_dir, remote_python="python3"):
    # Probe and refuse this computer before creating a workspace or executing tests.
    probe = """import json,platform,subprocess,re
text=subprocess.check_output(['ioreg','-rd1','-c','IOPlatformExpertDevice'],text=True) if platform.system()=='Darwin' else ''
match=re.search(r'"IOPlatformUUID" = "([^\\"]+)"',text)
print(json.dumps({'system':platform.system(),'name':platform.node(),'id':match[1] if match else None}))
"""
    result = subprocess.run(ssh_command(host, [remote_python, "-c", probe]), capture_output=True, text=True, check=True, timeout=45)
    remote = json.loads(result.stdout)
    if remote["system"] != "Darwin" or not remote["id"]:
        raise RuntimeError("Remote target must be an identifiable Mac")
    if remote["id"] == machine_id():
        raise RuntimeError("The SSH target is this Mac. Choose another machine; tests were not started")
    preflight = """import os,sys,subprocess,tempfile,json,pathlib
if sys.version_info<(3,11): raise SystemExit('Remote Mac needs Python 3.11+')
env=dict(os.environ)
if sys.argv[1]: env['DEVELOPER_DIR']=sys.argv[1]
version=subprocess.check_output(['xcodebuild','-version'],env=env,text=True)
if not version.startswith('Xcode 27.'): raise SystemExit('Remote Mac needs full Xcode 27')
root=pathlib.Path.home()/'Library/Caches/msgblast-tests'
root.mkdir(parents=True,exist_ok=True)
workspace=tempfile.mkdtemp(prefix=sys.argv[2][:12]+'-',dir=root)
print(json.dumps({'workspace':workspace,'xcode':version.strip()}))
"""
    result = subprocess.run(ssh_command(host, [remote_python, "-c", preflight, developer_dir or "", sha]), capture_output=True, text=True, check=True, timeout=45)
    details = json.loads(result.stdout)
    return {**remote, **details}


def run(args):
    sha = revision(args.revision)
    if args.timeout_seconds <= 0:
        raise ValueError("Timeout must be positive")
    if args.remote_python != "python3" and (not args.remote_python.startswith("/") or Path(args.remote_python).name != "python3"):
        raise ValueError("--remote-python must be python3 or an absolute executable named python3 so worker helpers use the same interpreter")
    if args.suite == "ui" and not args.allow_remote_ui:
        raise ValueError("UI tests use the remote desktop; pass --allow-remote-ui for a dedicated interactive Mac")
    output = Path(args.output).resolve()
    if output.exists():
        raise ValueError("Output already exists; choose a fresh directory to preserve earlier results")
    print(f"Revision: {sha}\nSSH target: {args.host}\nSuite: {args.suite}", flush=True)
    if args.dry_run:
        print("Dry run: no SSH connection, build, test, or workspace creation")
        return 0
    remote = prepare(args.host, sha, args.developer_dir, args.remote_python)
    workspace = remote["workspace"]
    output.mkdir(parents=True)
    manifest = {"revision": sha, "host": args.host, "machine": remote["name"], "xcode": remote["xcode"], "remote_python": args.remote_python, "suite": args.suite, "remote_workspace": workspace, "status": "running"}
    print(f"Remote Mac: {remote['name']}\nWorkspace: {workspace}\n{remote['xcode']}", flush=True)
    manifest_path = output / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    try:
        # git archive excludes uncommitted edits, credentials, local accounts, and build products.
        with tempfile.TemporaryFile() as archive:
            subprocess.run(["git", "archive", "--format=tar", sha], cwd=ROOT, stdout=archive, check=True)
            archive.seek(0)
            subprocess.run(ssh_command(args.host, ["tar", "-xf", "-", "-C", workspace]), stdin=archive, check=True, timeout=120)
        command = ["env", "MSGBLAST_REMOTE_TEST_WORKER=1"]
        if "/" in args.remote_python:
            # Use the selected Python's bin directory for the worker's Python helpers too.
            command.append("PATH=" + str(Path(args.remote_python).parent) + ":/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        if args.developer_dir:
            command.append("DEVELOPER_DIR=" + args.developer_dir)
        command += ["bash", workspace + "/scripts/mac_checks.sh", args.suite, sha]
        with (output / "run.log").open("w") as log:
            process = subprocess.Popen(ssh_command(args.host, command), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
            timed_out = threading.Event()
            def stop_group(sig):
                try:
                    os.killpg(process.pid, sig)
                except ProcessLookupError:
                    pass
            kill_timer = threading.Timer(5, stop_group, args=(signal.SIGKILL,))
            kill_timer.daemon = True
            def expire():
                timed_out.set()
                stop_group(signal.SIGTERM)
                kill_timer.start()
            timer = threading.Timer(args.timeout_seconds, expire)
            timer.daemon = True
            timer.start()
            try:
                for line in process.stdout:
                    print(line, end="", flush=True)
                    log.write(line)
                    log.flush()
                code = process.wait()
            except BaseException:
                stop_group(signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    stop_group(signal.SIGKILL)
                    process.wait()
                raise
            finally:
                timer.cancel()
                kill_timer.cancel()
                process.stdout.close()
        if timed_out.is_set():
            code = 124
            print("Remote test connection timed out. Inspect the remote worker/lock before retrying.", file=sys.stderr)
        manifest["status"] = "timed-out" if timed_out.is_set() else "passed" if code == 0 else "failed"
        manifest["worker_exit_code"] = code
        manifest["exit_code"] = code
        # Preserve .xcresult and fixture logs on the remote even if retrieval fails.
        try:
            with (output / "results.tar.gz").open("wb") as results:
                retrieved = subprocess.run(ssh_command(args.host, ["tar", "-czf", "-", "-C", workspace, "build/test-results"]), stdout=results, timeout=120)
        except (subprocess.TimeoutExpired, OSError) as error:
            manifest["results_retrieved"] = False
            manifest["retrieval_exit_code"] = None
            manifest["retrieval_error_type"] = type(error).__name__
            manifest["exit_code"] = code or 1
            if code == 0:
                manifest["status"] = "interrupted-or-incomplete"
            print(f"Results retrieval failed: {error}\nResults remain at {args.host}:{workspace}/build/test-results", file=sys.stderr)
            return manifest["exit_code"]
        manifest["results_retrieved"] = retrieved.returncode == 0
        manifest["retrieval_exit_code"] = retrieved.returncode
        manifest["exit_code"] = code or retrieved.returncode
        if retrieved.returncode:
            if code == 0:
                manifest["status"] = "retrieval-failed"
            print(f"Results remain at {args.host}:{workspace}/build/test-results", file=sys.stderr)
        return manifest["exit_code"]
    except BaseException as error:
        manifest["status"] = "interrupted-or-incomplete"
        manifest["exit_code"] = 130 if isinstance(error, KeyboardInterrupt) else 1
        manifest.setdefault("results_retrieved", False)
        raise
    finally:
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True, help="Dedicated Mac SSH alias or user@Tailscale-hostname")
    parser.add_argument("--revision", default="HEAD", help="Committed source only; uncommitted changes are excluded")
    parser.add_argument("--suite", choices=SUITES, default="all", help="all includes core/controllers/updater, excludes UI")
    parser.add_argument("--output", required=True, help="Fresh local folder for log, manifest, and remote result archive")
    parser.add_argument("--developer-dir", help="Remote full Xcode developer directory")
    parser.add_argument("--remote-python", default="python3", help="python3 or an absolute executable named python3 (e.g. /opt/homebrew/bin/python3)")
    parser.add_argument("--allow-remote-ui", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--timeout-seconds", type=int, default=5400, help="Remote test connection deadline (default 90 minutes)")
    args = parser.parse_args()
    try:
        return run(args)
    except subprocess.CalledProcessError as error:
        print(f"Remote checks stopped: command exited {error.returncode}", file=sys.stderr)
        if error.stderr:
            print(error.stderr.strip(), file=sys.stderr)
        return 1
    except (ValueError, RuntimeError, subprocess.TimeoutExpired, OSError) as error:
        print(f"Remote checks stopped: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
