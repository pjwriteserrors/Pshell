#!/usr/bin/env python3
"""Styles are local Git branches of this repository.

Switching a style is a `git switch` plus a Quickshell config reload. The shell
process, its Wayland connection and its warm QML cache all survive, so the
desktop blinks once instead of disappearing for several seconds.

Nothing here ever stashes, force-checks-out, resets, pulls or discards work. A
dirty tree is a hard stop, and a checkout that does not come up is rolled back
to the branch it came from.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

MANIFEST = ".quickshell-style.json"
# How long a reload may take before it counts as failed. A reload is normally
# well under a second; a cold QML cache after a big style change is the slow case.
RELOAD_TIMEOUT = 20.0


def run(args, cwd, check=True):
    result = subprocess.run(args, cwd=cwd, text=True, capture_output=True)
    if check and result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "Command failed")
    return result


def git(repo, *args):
    return run(["git", *args], repo).stdout.strip()


def manifest(repo, branch):
    raw = run(["git", "show", f"refs/heads/{branch}:{MANIFEST}"], repo, False)
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
                             description=info.get("description", ""),
                             current=name == current, compatible=bool(info)))
    # Styles first, then anything else (archive branches, work in progress).
    branches.sort(key=lambda entry: (not entry["compatible"], entry["name"].lower()))
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
    """Preflight, then move HEAD. Returns the branch that was left behind."""
    previous = preflight(repo, branch)
    git(repo, "switch", "--no-guess", branch)
    return previous


# --------------------------------------------------------------- the shell ---

def ipc(repo, *args, check=True):
    return run(["quickshell", "ipc", "-p", str(repo), "call", *args], repo, check)


def session_state(repo):
    result = ipc(repo, "styleSession", "state", check=False)
    if result.returncode:
        return None
    try:
        return json.loads(result.stdout)
    except ValueError:
        return None


def expected_style(repo, branch):
    return manifest(repo, branch).get("name", "")


def await_style(repo, style, deadline):
    """Wait until the shell reports it is running `style`."""
    while time.monotonic() < deadline:
        state = session_state(repo)
        if state is not None and state.get("style") == style:
            return state
        time.sleep(0.1)
    return None


def reload_shell(repo, style):
    """Ask the running shell to re-read the checked-out config.

    A config that does not compile is refused by Quickshell, which keeps the
    previous one running - so a shell that still reports the old style after
    the timeout means the new branch is broken, not that it is slow.
    """
    ipc(repo, "styleSession", "reload", check=False)
    state = await_style(repo, style, time.monotonic() + RELOAD_TIMEOUT)
    if state is None:
        raise RuntimeError(f"The style did not come up; rolled back. Check `quickshell log -p {repo}`.")
    return state


def start_shell(repo):
    """Cold start, for the case where no shell is running at all."""
    run(["quickshell", "-p", str(repo), "--daemonize", "--no-duplicate"], repo)
    deadline = time.monotonic() + RELOAD_TIMEOUT
    while time.monotonic() < deadline:
        if session_state(repo) is not None:
            return
        time.sleep(0.15)
    raise RuntimeError("The new shell did not report a session state.")


def switch(repo, branch):
    previous = preflight(repo, branch)
    if previous == branch:
        return

    state = session_state(repo)
    if state is None:
        # Nothing is running: check out and start cold.
        checkout(repo, branch)
        start_shell(repo)
        return

    if state.get("locked") is not False:
        raise RuntimeError("Cannot change styles while the session is locked.")

    target_style = expected_style(repo, branch)
    previous_style = state.get("style", "")
    if target_style == previous_style:
        raise RuntimeError(
            f"'{branch}' and '{previous}' both call themselves \"{target_style}\"; "
            f"give them different names in {MANIFEST}."
        )

    # Stop reacting to files while the checkout rewrites them, so the shell
    # reloads exactly once, when the tree is whole again.
    ipc(repo, "styleSession", "freeze", check=False)
    try:
        checkout(repo, branch)
    except Exception:
        ipc(repo, "styleSession", "thaw", check=False)
        raise

    try:
        reload_shell(repo, target_style)
    except Exception:
        # Roll back only a clean checkout: never overwrite files created in
        # the meantime.
        if not git(repo, "status", "--porcelain"):
            git(repo, "switch", "--no-guess", previous)
            try:
                reload_shell(repo, previous_style)
            except Exception:
                # The old style will not come back up either. A cold start is
                # the last thing left that can give the desktop a shell.
                run(["quickshell", "kill", "-p", str(repo)], repo, False)
                try:
                    start_shell(repo)
                except Exception:
                    pass
        raise


# ---------------------------------------------------------------- plumbing ---

def state_directory(repo):
    base = Path(os.environ.get("XDG_RUNTIME_DIR", tempfile.gettempdir()))
    key = hashlib.sha256(str(repo).encode()).hexdigest()[:16]
    path = base / f"quickshell-styles-{os.getuid()}-{key}"
    path.mkdir(mode=0o700, exist_ok=True)
    if path.is_symlink() or path.stat().st_uid != os.getuid():
        raise RuntimeError("Unsafe style state directory")
    return path


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
        finally:
            run(["quickshell", "ipc", "-p", str(repo), "call", "styleSession", "thaw"], repo, False)
        temporary = status_file.with_suffix(".tmp")
        temporary.write_text(json.dumps({"message": message}))
        temporary.replace(status_file)
        if message:
            raise SystemExit(1)


if __name__ == "__main__":
    main()
