"""Two folders side by side: what is only on one side, what differs and
which is newer – and bringing one side up to date with the other (rsync).
"""
import os
import re
import subprocess

SKIP = {".git", "node_modules", "__pycache__"}


def scan(root, deep, hidden):
    out = {}
    for current, folders, names in os.walk(root):
        folders[:] = [name for name in folders if (hidden or not name.startswith(".")) and name not in SKIP]
        rel_dir = os.path.relpath(current, root)
        for name in names + ([] if deep else folders):
            if not hidden and name.startswith("."):
                continue
            path = os.path.join(current, name)
            try:
                st = os.lstat(path)
            except OSError:
                continue
            rel = name if rel_dir == "." else os.path.join(rel_dir, name)
            out[rel] = (st.st_size, st.st_mtime, os.path.isdir(path))
        if not deep:
            break
    return out


def same_content(a, b, size):
    if size > 64 * 1024 * 1024:
        return None  # too big to read for this: size and time decide
    try:
        with open(a, "rb") as fa, open(b, "rb") as fb:
            while True:
                x = fa.read(1 << 20)
                y = fb.read(1 << 20)
                if x != y:
                    return False
                if not x:
                    return True
    except OSError:
        return None


def compare(left, right, deep=True, hidden=False, check=lambda: None):
    """{ left: { rel: state }, right: { rel: state }, counts } – a state is
    "only", "newer", "older", "differs" or "same"; a folder (not deep) is
    "only" or "same"."""
    a = scan(left, deep, hidden)
    b = scan(right, deep, hidden)
    states_left, states_right = {}, {}
    counts = {"onlyLeft": 0, "onlyRight": 0, "newerLeft": 0, "newerRight": 0, "differ": 0, "same": 0}
    for rel, (size, mtime, is_dir) in a.items():
        check()
        if rel not in b:
            states_left[rel] = "only"
            counts["onlyLeft"] += 1
            continue
        other_size, other_mtime, other_dir = b[rel]
        if is_dir or other_dir:
            states_left[rel] = states_right[rel] = "same"
            counts["same"] += 1
            continue
        if size == other_size:
            same = same_content(os.path.join(left, rel), os.path.join(right, rel), size)
            if same or (same is None and abs(mtime - other_mtime) < 2):
                states_left[rel] = states_right[rel] = "same"
                counts["same"] += 1
                continue
        if abs(mtime - other_mtime) < 2:
            states_left[rel] = states_right[rel] = "differs"
            counts["differ"] += 1
        elif mtime > other_mtime:
            states_left[rel], states_right[rel] = "newer", "older"
            counts["newerLeft"] += 1
        else:
            states_left[rel], states_right[rel] = "older", "newer"
            counts["newerRight"] += 1
    for rel in b:
        if rel not in a:
            states_right[rel] = "only"
            counts["onlyRight"] += 1
    return {"left": states_left, "right": states_right, "counts": counts}


ITEM = re.compile(r"^([<>ch.*][fdLDS][^ ]*|\*deleting)\s+(.*)$")


def plan(source, target, delete, hidden):
    """What a sync would do, without doing it: [{ action: copy|update|delete, path }]."""
    command = rsync_command(source, target, delete, hidden)
    command[1:1] = ["--dry-run", "--itemize-changes", "--info=none"]
    command.remove("--info=progress2")
    out = subprocess.run(command, capture_output=True, text=True, timeout=300)
    if out.returncode not in (0, 24):
        raise RuntimeError((out.stderr.strip().splitlines() or ["rsync failed"])[-1])
    steps = []
    for line in out.stdout.splitlines():
        match = ITEM.match(line)
        if not match:
            continue
        flags, path = match.groups()
        if flags == "*deleting":
            steps.append({"action": "delete", "path": path.rstrip("/")})
        elif flags[1] == "d" and "+++++" not in flags:
            continue
        else:
            steps.append({"action": "copy" if "+++++" in flags else "update", "path": path.rstrip("/")})
    return steps


def rsync_command(source, target, delete, hidden):
    command = ["rsync", "-a", "--info=progress2", "--no-inc-recursive", "--protect-args"]
    if delete:
        # what goes away on the target is kept in its trash folder of rsync's, not lost
        command += ["--delete", "--backup", f"--backup-dir={os.path.join(target, '.sync-removed')}"]
    if not hidden:
        command += ["--exclude", ".*"]
    command += ["--exclude", ".sync-removed/", "--", source.rstrip("/") + "/", target.rstrip("/") + "/"]
    return command
