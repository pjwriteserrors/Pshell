#!/usr/bin/env python3
"""Local Git styles; never stash, force-checkout, pull or discard changes."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


def run(args, cwd, check=True):
    result = subprocess.run(args, cwd=cwd, text=True, capture_output=True)
    if check and result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "Command failed")
    return result


def git(repo, *args):
    return run(["git", *args], repo).stdout.strip()


def manifest(repo, branch):
    raw = run(["git", "show", f"refs/heads/{branch}:.quickshell-style.json"], repo, False)
    try:
        value = json.loads(raw.stdout)
        return value if value.get("api") == 1 else {}
    except (ValueError, AttributeError):
        return {}


def catalog(repo):
    current = git(repo, "branch", "--show-current")
    dirty = bool(git(repo, "status", "--porcelain", "--untracked-files=normal"))
    branches = []
    for name in git(repo, "for-each-ref", "--format=%(refname:short)", "refs/heads").splitlines():
        info = manifest(repo, name)
        branches.append(dict(branch=name, name=info.get("name", name),
                             current=name == current, compatible=bool(info)))
    return dict(current=current, dirty=dirty, branches=branches)


def preflight(repo, branch):
    info = catalog(repo)
    if not info["current"]:
        raise RuntimeError("Detached HEAD: first select a local branch manually.")
    if info["dirty"]:
        raise RuntimeError("Uncommitted changes or untracked files: commit or move them first. Nothing was discarded.")
    target = next((b for b in info["branches"] if b["branch"] == branch), None)
    if not target or not target["compatible"]:
        raise RuntimeError("This local branch is not a compatible Quickshell style.")
    for record in git(repo, "worktree", "list", "--porcelain").split("\n\n"):
        if f"branch refs/heads/{branch}" in record.splitlines():
            worktree = record.splitlines()[0].removeprefix("worktree ")
            if Path(worktree).resolve() != repo:
                raise RuntimeError("That branch is checked out in another worktree.")
    return info["current"]


def checkout(repo, branch):
    previous = preflight(repo, branch)
    git(repo, "switch", "--no-guess", branch)
    return previous


def state_directory(repo):
    base = Path(os.environ.get("XDG_RUNTIME_DIR", tempfile.gettempdir()))
    key = hashlib.sha256(str(repo).encode()).hexdigest()[:16]
    path = base / f"quickshell-styles-{os.getuid()}-{key}"
    path.mkdir(mode=0o700, exist_ok=True)
    if path.is_symlink() or path.stat().st_uid != os.getuid():
        raise RuntimeError("Unsafe style state directory")
    return path


def switch(repo, branch):
    previous = preflight(repo, branch)
    if previous == branch:
        return
    state = run(["quickshell", "ipc", "-p", str(repo), "call", "styleSession", "state"], repo)
    session = json.loads(state.stdout)
    if session.get("locked") is not False:
        raise RuntimeError("Cannot change styles while the session is locked.")
    run(["quickshell", "kill", "-p", str(repo)], repo)
    for _ in range(50):
        if "Instance " not in run(["quickshell", "list", "-p", str(repo)], repo, False).stdout:
            break
        time.sleep(0.1)
    else:
        raise RuntimeError("The old shell did not stop; checkout was not performed.")
    try:
        checkout(repo, branch)  # Recheck after stopping: no force and no stash.
        run(["quickshell", "-p", str(repo), "--daemonize", "--no-duplicate"], repo)
        time.sleep(0.7)
        run(["quickshell", "ipc", "-p", str(repo), "call", "styleSession", "state"], repo)
    except Exception:
        run(["quickshell", "kill", "-p", str(repo)], repo, False)
        # Roll back only a clean checkout. Never overwrite files created meanwhile.
        if not git(repo, "status", "--porcelain"):
            git(repo, "switch", "--no-guess", previous)
        run(["quickshell", "-p", str(repo), "--daemonize", "--no-duplicate"], repo, False)
        raise


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("action", choices=["catalog", "switch"])
    parser.add_argument("branch", nargs="?")
    args = parser.parse_args()
    repo = args.repo.resolve()
    state = state_directory(repo)
    status_file = state / "status.json"
    if args.action == "catalog":
        info = catalog(repo)
        try:
            info["message"] = json.loads(status_file.read_text()).get("message", "")
        except (OSError, ValueError):
            info["message"] = ""
        print(json.dumps(info))
        return
    with (state / "switch.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        try:
            if not args.branch:
                raise RuntimeError("No branch selected")
            switch(repo, args.branch)
            message = ""
        except Exception as error:
            message = str(error)
        temporary = status_file.with_suffix(".tmp")
        temporary.write_text(json.dumps({"message": message}))
        temporary.replace(status_file)
        if message:
            raise SystemExit(1)


if __name__ == "__main__":
    main()
