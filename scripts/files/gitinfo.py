"""Git in the file manager: which files of a folder in a repository changed,
a commit of some of them, and what changed in a file (for quick look).
"""
import os
import subprocess
import time

CACHE = {}  # folder → (at, result)


def git(args, cwd, timeout=8, input_text=None):
    return subprocess.run(["git", "-c", "core.quotepath=off", *args], cwd=cwd, capture_output=True, text=True,
                          timeout=timeout, input=input_text, env=dict(os.environ, GIT_OPTIONAL_LOCKS="0", LC_ALL="C"))


def top_of(folder):
    """The repository a folder is in, or ""."""
    current = os.path.realpath(folder)
    while True:
        if os.path.exists(os.path.join(current, ".git")):
            return current
        parent = os.path.dirname(current)
        if parent == current:
            return ""
        current = parent


def status(folder):
    """{ repo, branch, ahead, behind, files: { name in folder: "M" | "A" | "?" | "D" | "U" | "!" } }
    – a folder below shows the strongest state of what is inside it. "" when
    the folder is not in a repository."""
    repo = top_of(folder)
    if not repo:
        return None
    cached = CACHE.get(folder)
    if cached and time.monotonic() - cached[0] < 1.5:
        return cached[1]
    try:
        out = git(["status", "--porcelain=v1", "-z", "--branch", "--untracked-files=normal", "--", "."], os.path.realpath(folder))
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    real = os.path.realpath(folder)
    prefix = os.path.relpath(real, repo)
    prefix = "" if prefix == "." else prefix + "/"
    files = {}
    branch, ahead, behind = "", 0, 0
    rank = {"U": 5, "M": 4, "A": 3, "D": 3, "R": 3, "?": 1}
    parts = out.stdout.split("\0")
    index = 0
    while index < len(parts):
        entry = parts[index]
        index += 1
        if not entry:
            continue
        if entry.startswith("## "):
            head = entry[3:]
            branch = head.split("...")[0].replace("No commits yet on ", "")
            if "ahead " in head:
                ahead = int(head.split("ahead ")[1].split(",")[0].split("]")[0])
            if "behind " in head:
                behind = int(head.split("behind ")[1].split("]")[0])
            continue
        code, path = entry[:2], entry[3:]
        if code[0] in "RC":
            index += 1  # the old name follows
        state = "?" if code == "??" else ("U" if "U" in code or code in ("AA", "DD") else
                                          ("A" if code[0] == "A" else ("D" if "D" in code else ("R" if code[0] == "R" else "M"))))
        if not path.startswith(prefix):
            continue
        name = path[len(prefix):].rstrip("/").split("/")[0]
        if rank.get(state, 0) > rank.get(files.get(name, ""), -1):
            files[name] = state
    result = {"repo": repo, "branch": branch, "ahead": ahead, "behind": behind, "files": files}
    CACHE[folder] = (time.monotonic(), result)
    return result


def diff(path):
    """What changed in a file since the last commit (or the whole file when it is new)."""
    folder = path if os.path.isdir(path) else os.path.dirname(path)
    repo = top_of(folder)
    if not repo:
        raise RuntimeError("Not in a git repository")
    out = git(["diff", "HEAD", "--no-color", "--no-ext-diff", "--", path], repo, timeout=15)
    text = out.stdout
    if not text.strip():
        untracked = git(["ls-files", "--others", "--exclude-standard", "--", path], repo).stdout.strip()
        if untracked and os.path.isfile(path):
            with open(path, encoding="utf-8", errors="replace") as file:
                body = file.read(120_000)
            text = f"new file {os.path.relpath(path, repo)}\n" + "".join(f"+{line}\n" for line in body.splitlines())
    log = git(["log", "-n", "8", "--format=%h\x1f%an\x1f%ar\x1f%s", "--", path], repo).stdout
    commits = [dict(zip(("hash", "author", "when", "subject"), line.split("\x1f"))) for line in log.splitlines() if line]
    return {"repo": repo, "diff": text[:400_000], "commits": commits}


def commit(paths, message, push=False):
    if not paths:
        raise RuntimeError("Nothing to commit")
    repo = top_of(os.path.dirname(paths[0]) if not os.path.isdir(paths[0]) else paths[0])
    if not repo:
        raise RuntimeError("Not in a git repository")
    added = git(["add", "--all", "--", *paths], repo, timeout=60)
    if added.returncode != 0:
        raise RuntimeError(added.stderr.strip() or "git add failed")
    done = git(["commit", "-m", message, "--", *paths], repo, timeout=60)
    if done.returncode != 0:
        raise RuntimeError((done.stdout + done.stderr).strip().splitlines()[-1] if (done.stdout + done.stderr).strip() else "git commit failed")
    CACHE.clear()
    head = git(["log", "-1", "--format=%h %s"], repo).stdout.strip()
    result = {"repo": repo, "head": head}
    if push:
        pushed = git(["push"], repo, timeout=120)
        result["pushed"] = pushed.returncode == 0
        if pushed.returncode != 0:
            result["pushError"] = (pushed.stderr.strip().splitlines() or ["push failed"])[-1]
    return result


def file_versions(path, limit=30):
    """Earlier versions of a file in its repository: [{ id, when, title, source }]."""
    repo = top_of(os.path.dirname(path))
    if not repo or not os.path.isfile(path):
        return []
    rel = os.path.relpath(os.path.realpath(path), repo)
    out = git(["log", "-n", str(limit), "--follow", "--format=%H\x1f%ct\x1f%an\x1f%s", "--", rel], repo, timeout=15)
    versions = []
    for line in out.stdout.splitlines():
        parts = line.split("\x1f")
        if len(parts) == 4:
            versions.append({"id": f"git:{parts[0]}:{rel}", "when": int(parts[1]), "title": parts[3], "detail": f"Commit {parts[0][:7]} by {parts[2]}", "source": "git"})
    return versions


def show_version(repo, commit_hash, rel, target):
    out = subprocess.run(["git", "show", f"{commit_hash}:{rel}"], cwd=repo, capture_output=True, timeout=30)
    if out.returncode != 0:
        # a renamed file: ask for the name it had then
        names = git(["show", "--name-only", "--format=", commit_hash], repo).stdout.split()
        base = os.path.basename(rel)
        alt = next((name for name in names if os.path.basename(name) == base), "")
        out = subprocess.run(["git", "show", f"{commit_hash}:{alt}"], cwd=repo, capture_output=True, timeout=30) if alt else out
        if out.returncode != 0:
            raise RuntimeError("This version cannot be read")
    with open(target, "wb") as file:
        file.write(out.stdout)


def run(path, what):
    """pull, push or fetch; a line about how it went."""
    if what not in ("pull", "push", "fetch"):
        raise RuntimeError("Not a git command this does")
    repo = top_of(path if os.path.isdir(path) else os.path.dirname(path))
    if not repo:
        raise RuntimeError("Not in a git repository")
    args = {"pull": ["pull", "--ff-only"], "push": ["push"], "fetch": ["fetch", "--all", "--prune"]}[what]
    out = git(args, repo, timeout=180)
    CACHE.clear()
    text = (out.stdout + out.stderr).strip().splitlines()
    if out.returncode != 0:
        raise RuntimeError(text[-1] if text else f"git {what} failed")
    summary = {"pull": "Pulled", "push": "Pushed", "fetch": "Fetched"}[what]
    if what == "pull" and any("Already up to date" in line for line in text):
        summary = "Already up to date"
    return {"summary": summary}
