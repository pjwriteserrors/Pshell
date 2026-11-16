"""ClamAV over the files (folders included). One clamscan for all of them:
loading the signatures is the slow part, on the Pi half a minute."""
import os
import re
import shutil
import time

from . import TaskError
from .media import run as tool


def run(ctx, inputs, options):
    if not shutil.which("clamscan"):
        raise TaskError("ClamAV (clamscan) is not installed")
    local = {}
    for item in inputs:
        ctx.check()
        local[ctx.fetch(item["path"])] = item["path"]
    command = ["clamscan", "--no-summary", "--infected", "--stdout", "-r", "--follow-dir-symlinks=2",
               "--follow-file-symlinks=2"]
    database = os.environ.get("CLAMAV_DB")
    if database and os.path.isdir(database):
        command.append(f"--database={database}")
    ctx.progress(0.05, "Loading the signatures")
    # clamscan exits 1 when it found something; that is no failure
    out = tool(command + list(local), ctx, 6 * 3600, ok=(0, 1))
    found = {}
    for line in (out or b"").decode("utf-8", "replace").splitlines():
        match = re.match(r"^(.*): (.+) FOUND$", line.strip())
        if match:
            found[match.group(1)] = match.group(2)
    scans = {}
    for path_local, path in local.items():
        hits = {name: what for name, what in found.items() if name == path_local or name.startswith(path_local + "/")}
        scans[path] = {"infected": bool(hits), "name": ", ".join(sorted(set(hits.values())))[:300],
                       "files": [os.path.relpath(name, path_local) for name in hits][:50], "at": time.time(),
                       "engine": "clamav"}
    ctx.progress(1.0)
    return {"scans": scans, "infected": sum(1 for scan in scans.values() if scan["infected"])}
