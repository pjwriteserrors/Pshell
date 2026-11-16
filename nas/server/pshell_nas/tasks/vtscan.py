"""VirusTotal: the file's hash is looked up; an unknown file is uploaded
only with the setting `vt_upload` (or the task's own option)."""
import time

from . import TaskError, files


def key_of(ctx, options):
    key = options.get("_vt_key") or (ctx.settings or {}).get("vt_key")
    if not key:
        try:
            key = files("virustotal").get_key()
        except Exception:  # noqa: BLE001 – no keyring here
            key = ""
    if not key:
        raise TaskError("No VirusTotal API key – set one in the NAS settings")
    return key


def run(ctx, inputs, options):
    vt = files("virustotal")
    key = key_of(ctx, options)
    upload = bool(options.get("upload")) and bool(options.get("_vt_upload", (ctx.settings or {}).get("vt_upload")))
    scans = {}
    for number, item in enumerate(inputs):
        ctx.check()
        if item.get("dir"):
            scans[item["path"]] = {"state": "skipped", "why": "folder"}
            continue
        local = ctx.fetch(item["path"])
        ctx.progress(number / len(inputs), "Hashing")
        sha = vt.sha256(local, check=ctx.check)
        try:
            report = vt._get(f"/files/{sha}", key)
            verdict = vt.verdict(report, sha)
        except vt.Problem as problem:
            if getattr(problem, "code", "") != "unknown" and "Not known" not in str(problem):
                raise TaskError(str(problem))
            if not upload:
                verdict = {"sha256": sha, "state": "unknown", "link": f"https://www.virustotal.com/gui/file/{sha}"}
            else:
                ctx.progress(number / len(inputs), "Uploading to VirusTotal")
                analysis = vt.upload(local, key)
                vt.wait_for(analysis, key, ctx.check, lambda text: ctx.progress(number / len(inputs), str(text)))
                verdict = vt.verdict(vt._get(f"/files/{sha}", key), sha)
        verdict["at"] = time.time()
        verdict["engine"] = "virustotal"
        scans[item["path"]] = verdict
        ctx.progress((number + 1) / len(inputs))
    return {"scans": scans}
