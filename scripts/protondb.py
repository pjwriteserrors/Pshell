"""Which Proton runs a game best, from ProtonDB's reports (games.py).

ProtonDB publishes every report as a monthly dump (github.com/bdefore/
protondb-data, ODbL). Once a month the newest is fetched (~70 MB) and
boiled down to an index: for every app, how the reports of the last two
years went per way of running it – Steam's default Proton ("official"),
Experimental, a numbered Valve Proton, a GE-Proton by its major version,
native. The dump itself is not kept.

    recommend(appid, runners)  the installed runner the reports favour
    tier(appid)                ProtonDB's own rating (its summaries API)
    tiers(appids)              the ratings of many, the unknown ones asked side by side
"""

import json
import os
import re
import tarfile
import time
import urllib.request
from pathlib import Path

CACHE = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "pshell/games"
INDEX = CACHE / "protondb.json"
TIERS = CACHE / "protondb-tiers.json"
LISTING = "https://api.github.com/repos/bdefore/protondb-data/contents/reports"
SUMMARY = "https://www.protondb.com/api/v1/reports/summaries/{}.json"
AGENT = "Mozilla/5.0 (X11; Linux x86_64) Pshell games"
# a month between fetches; reports older than two years say little
REFRESH = 30 * 86400
WINDOW = 2 * 365 * 86400
FAULTS = ("audioFaults", "graphicalFaults", "inputFaults", "performanceFaults", "saveGameFaults", "significantBugs",
          "stabilityFaults", "windowingFaults")
MONTHS = {name: number for number, name in enumerate("jan feb mar apr may jun jul aug sep oct nov dec".split(), 1)}
# fewer reports than this do not make a way of running it the best
MIN_REPORTS = 3


def _open(url, timeout=20):
    return urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": AGENT}), timeout=timeout)


def _load(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def _save(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(data, separators=(",", ":")))
    os.replace(temporary, path)


# ── the index ──────────────────────────────────────────────────────────────
def stale():
    index = _load(INDEX)
    return not index or time.time() - index.get("checked", 0) > REFRESH


def _newest():
    """The newest dump: (name, url)."""
    with _open(LISTING) as answer:
        files = [entry for entry in json.load(answer) if isinstance(entry, dict)]

    def when(entry):
        match = re.match(r"reports_([a-z]{3})(\d+)_(\d{4})", entry.get("name", ""))
        return (int(match.group(3)), MONTHS.get(match.group(1), 0), int(match.group(2))) if match else (0, 0, 0)
    best = max(files, key=when)
    return best["name"], best["download_url"]


def _reports(stream):
    """The reports of the dump one at a time (a JSON array), without
    holding all of them."""
    decoder = json.JSONDecoder()
    buffer = ""
    started = False
    while True:
        chunk = stream.read(1 << 20)
        if chunk:
            buffer += chunk.decode("utf-8", "replace")
        at = 0
        while True:
            while at < len(buffer) and buffer[at] in " \t\r\n,[]":
                if buffer[at] == "[":
                    started = True
                at += 1
            if at >= len(buffer) or not started:
                break
            try:
                report, end = decoder.raw_decode(buffer, at)
            except ValueError:
                break
            yield report
            at = end
        buffer = buffer[at:]
        if not chunk:
            return


def _way(responses):
    """How a report ran the game: official | experimental | valve:<n> |
    ge:<n> | native, or None."""
    variant = responses.get("variant") or ""
    custom = str(responses.get("customProtonVersion") or "")
    if variant == "official":
        return "official"
    if variant == "experimental":
        return "experimental"
    if variant == "native":
        return "native"
    ge = re.search(r"GE-Proton(\d+)", custom, re.I) or re.search(r"Proton-(\d+)\.\d+-GE", custom, re.I)
    if variant in ("ge", "notListed") and ge:
        return f"ge:{ge.group(1)}"
    if variant == "older":
        match = re.search(r"(\d+)\.\d+", str(responses.get("protonVersion") or ""))
        return f"valve:{match.group(1)}" if match else None
    return None


def _score(responses):
    """0 (did not run) … 1 (ran without a fault)."""
    if responses.get("verdict") != "yes" or responses.get("startsPlay") == "no":
        return 0.0
    faults = sum(1 for key in FAULTS if responses.get(key) == "yes")
    return max(0.2, 1.0 - 0.12 * faults)


def update(force=False):
    """Fetches the newest dump when the index is a month old; the index."""
    index = _load(INDEX) or {}
    if not force and index and time.time() - index.get("checked", 0) <= REFRESH:
        return index
    name, url = _newest()
    if index.get("source") == name and not force:
        index["checked"] = int(time.time())
        _save(INDEX, index)
        return index
    with _open(url, timeout=600) as answer:
        apps = build(answer)
    index = {"source": name, "checked": int(time.time()), "apps": apps}
    _save(INDEX, index)
    return index


def build(fileobj):
    """{appid: {way: [score, reports]}} from a dump (a .tar.gz stream)."""
    since = time.time() - WINDOW
    apps = {}
    with tarfile.open(fileobj=fileobj, mode="r|gz") as tar:
        for member in tar:
            if not member.isfile() or not member.name.endswith(".json"):
                continue
            for report in _reports(tar.extractfile(member)):
                if not isinstance(report, dict) or report.get("timestamp", 0) < since:
                    continue
                appid = str(((report.get("app") or {}).get("steam") or {}).get("appId") or "")
                responses = report.get("responses") or {}
                way = _way(responses)
                if not appid.isdigit() or not way:
                    continue
                entry = apps.setdefault(appid, {}).setdefault(way, [0.0, 0])
                entry[0] = round(entry[0] + _score(responses), 2)
                entry[1] += 1
    return apps


# ── a game's best way ──────────────────────────────────────────────────────
def _major(name):
    match = re.search(r"(\d+)", name)
    return int(match.group(1)) if match else -1


_index = None


def recommend(appid, runners, steam=False):
    """What the reports favour among what is installed:
    {runner, tool, label, way, share, reports} or None. `runners` are
    windows.runners()' (id, name, kind, tool); for a game in Steam
    "official" is Steam's own choice (tool "")."""
    global _index
    if _index is None:
        _index = _load(INDEX) or {}
    ways = (_index.get("apps") or {}).get(str(appid))
    if not ways:
        return None
    protons = [each for each in runners if each.get("kind") == "proton"]
    valve = [each for each in protons if re.match(r"proton_\d+$", each.get("tool", ""))]
    valve.sort(key=lambda each: -_major(each["tool"]))
    ge = [each for each in protons if "ge-proton" in each.get("name", "").lower()]

    def runner_for(way):
        if way == "official":
            # Steam's default is its newest numbered Proton
            return {"id": "", "tool": "", "name": "Steam's choice"} if steam else (valve[0] if valve else None)
        if way == "experimental":
            return next((each for each in protons if each.get("tool") == "proton_experimental"), None)
        if way.startswith("valve:"):
            return next((each for each in valve if _major(each["tool"]) == int(way[6:])), None)
        if way.startswith("ge:"):
            same = [each for each in ge if _major(each["name"].lower().split("ge-proton", 1)[1]) == int(way[3:])]
            return same[0] if same else None
        return None

    best = None
    official = ways.get("official")
    floor = (official[0] + 1) / (official[1] + 2) if official and official[1] >= MIN_REPORTS else 0
    for way, (good, count) in ways.items():
        runner = runner_for(way)
        if not runner:
            continue
        share = (good + 1) / (count + 2)
        if way != "official":
            # another way has to be clearly better than Steam's own
            if count < MIN_REPORTS or share < floor + 0.05:
                continue
        if not best or share > best["share"] or (share == best["share"] and count > best["reports"]):
            best = {"runner": runner.get("id", ""), "tool": runner.get("tool", ""), "label": runner.get("name", ""),
                    "way": way, "share": round(share, 3), "reports": count}
    return best


def _ask(appid):
    try:
        with _open(SUMMARY.format(int(appid)), timeout=10) as answer:
            return str(json.load(answer).get("tier") or "")
    except Exception:  # noqa: BLE001 – none known (404) or no net
        return ""


def _fresh(known):
    return known and time.time() - known.get("at", 0) < 7 * 86400


def tier(appid):
    """ProtonDB's rating of an app (platinum, gold, …), "" when it has none;
    asked again after a week."""
    tiers = _load(TIERS) or {}
    known = tiers.get(str(appid))
    if _fresh(known):
        return known.get("tier", "")
    value = _ask(appid)
    tiers[str(appid)] = {"tier": value, "at": int(time.time())}
    _save(TIERS, tiers)
    return value


def cached_tiers(appids):
    """{appid: tier} of what is kept, however old."""
    kept = _load(TIERS) or {}
    return {appid: kept[appid].get("tier", "") for appid in appids if appid in kept}


def tiers(appids):
    """{appid: tier} for many; the ones not asked this week are asked a few
    at a time and kept in one write."""
    import concurrent.futures
    kept = _load(TIERS) or {}
    wanted = [appid for appid in dict.fromkeys(appids) if not _fresh(kept.get(appid))]
    if wanted:
        with concurrent.futures.ThreadPoolExecutor(6) as pool:
            answers = dict(zip(wanted, pool.map(_ask, wanted)))
        # a failed ask keeps the old rating rather than forgetting it
        kept = _load(TIERS) or {}
        now = int(time.time())
        for appid, value in answers.items():
            kept[appid] = {"tier": value or (kept.get(appid) or {}).get("tier", ""), "at": now}
        _save(TIERS, kept)
    return {appid: kept[appid].get("tier", "") for appid in appids if appid in kept}
