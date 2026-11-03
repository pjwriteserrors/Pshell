"""What was fetched from the watch (zepp/fetch.py) or imported from a
Gadgetbridge database, kept raw, and turned into the days and nights the
shell shows (the format of scripts/phone/pshell_phone/health.py: nights by
the day they ended with their stages in minutes from going to bed; days with
the heart in 10-minute means, stress and blood oxygen by the hour, skin
temperature by the half hour, steps, PAI). The phone app builds the same
from the same samples (mobile/.../zepp/HealthBuild.kt).
"""

import json
import os
import sqlite3
import time
from datetime import date, datetime, timedelta
from pathlib import Path

KEEP_DAYS = 120
NOT_WORN, CHARGING, SLEEP = 115, 118, 120


class Store:
    """Raw samples by kind, each keyed by its time: {kind: {t: sample}}."""

    def __init__(self, path):
        self.path = Path(path)
        self.kinds = {}
        self.since = {}
        try:
            data = json.loads(self.path.read_text())
            self.kinds = {k: {int(t): s for t, s in v.items()} for k, v in (data.get("kinds") or {}).items()}
            self.since = data.get("since") or {}
        except (OSError, ValueError, AttributeError):
            pass

    def add(self, kind, samples):
        """→ the local dates the samples touch."""
        part = self.kinds.setdefault(kind, {})
        dates = set()
        for s in samples:
            t = int(s["t"])
            part[t] = s
            dates.add(_day(s.get("wake", t)))
            if kind == "sleep":
                dates.add(_day(s.get("bed", t)))
        if samples:
            self.since[kind] = max(self.since.get(kind, 0), max(int(s["t"]) for s in samples) + 60)
        return dates

    def trim(self):
        oldest = time.time() - KEEP_DAYS * 86400
        for kind in self.kinds:
            self.kinds[kind] = {t: s for t, s in self.kinds[kind].items() if t >= oldest}

    def save(self):
        self.trim()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump({"kinds": self.kinds, "since": self.since}, f, separators=(",", ":"))
        tmp.replace(self.path)

    def between(self, kind, start, end):
        return [s for t, s in sorted(self.kinds.get(kind, {}).items()) if start <= t < end]


def _day(t):
    return datetime.fromtimestamp(t).date().isoformat()


def _midnight(key):
    return int(datetime.fromisoformat(key).timestamp())


def _means(samples, start, slot, count, value, keep=lambda s: True):
    sums, ns = [0.0] * count, [0] * count
    for s in samples:
        i = int((s["t"] - start) // slot)
        v = value(s)
        if 0 <= i < count and v is not None and keep(s):
            sums[i] += v
            ns[i] += 1
    return [round(sums[i] / ns[i], 1) if ns[i] else 0 for i in range(count)]


def build_day(store, key):
    start = _midnight(key)
    end = start + 86400
    act = store.between("activity", start, end)
    worn = {s["t"] // 60 for s in act if s["k"] not in (NOT_WORN, CHARGING)}
    hr = lambda s: s["h"] if 0 < s["h"] < 255 else None
    day = {"date": key}
    if act:
        day["steps"] = sum(s["s"] for s in act)
        day["heart"] = _means(act, start, 600, 144, hr)
        beats = [(s["h"], s["t"]) for s in act if hr(s)]
        if beats:
            day["max"], at = max(beats)
            day["maxAt"] = at
            day["last"] = beats[-1][0]
        day["active"] = sum(1 for s in act if s["s"] > 0)
        day["worn"] = len(worn)
    resting = store.between("resting", start, end)
    if resting:
        day["resting"] = resting[-1]["v"]
    elif day.get("heart"):
        means = [v for v in day["heart"] if v > 0]
        day["resting"] = round(sorted(means)[len(means) // 10]) if means else 0
    stress = store.between("stress", start, end)
    if stress:
        day["stress"] = _means(stress, start, 3600, 24, lambda s: s["v"])
        day["stressNow"] = stress[-1]["v"]
        day["stressDay"] = round(sum(s["v"] for s in stress) / len(stress))
    spo2 = store.between("spo2", start, end)
    if spo2:
        day["oxygen"] = _means(spo2, start, 3600, 24, lambda s: s["v"])
        day["oxygenNow"] = spo2[-1]["v"]
    temp = store.between("temperature", start, end)
    if temp:
        # only while it was worn: off the wrist it measures the room
        day["temperature"] = _means(temp, start, 1800, 48, lambda s: s["v"], keep=lambda s: s["t"] // 60 in worn)
    pai = store.between("pai", start, end + 3600)
    if pai:
        day["pai"] = round(pai[-1]["total"])
        day["paiToday"] = round(pai[-1]["today"])
        day["paiDay"] = round(pai[-1]["total"])
    hrv = store.between("hrv", start, end)
    if hrv:
        day["hrv"] = round(sum(s["v"] for s in hrv) / len(hrv))
    day["at"] = int(time.time())
    return day if len(day) > 2 else None


def _night_from_session(store, s):
    bed, wake = s["bed"], s["wake"]
    stages = sorted(([k, round((a - bed) / 60), round((b - bed) / 60)] for k, a, b in s["stages"]), key=lambda x: x[1])
    breathing = store.between("breathing", bed, wake)
    total = s["light"] + s["deep"] + s["rem"]
    return {"date": _day(wake), "bed": bed, "wake": wake, "total": total or round((wake - bed) / 60) - s["awake"],
            "score": s["score"], "deep": s["deep"], "light": s["light"], "rem": s["rem"], "awake": s["awake"],
            "stages": stages, "naps": [], "avgHr": s["avgHr"],
            "breathing": round(sum(b["v"] for b in breathing) / len(breathing), 1) if breathing else 0}


def _nights_from_activity(store, start, end):
    """Without the watch's sleep sessions: the minutes it marked as sleep,
    with deep and REM by Gadgetbridge's thresholds."""
    act = [s for s in store.between("activity", start, end) if s["k"] == SLEEP]
    nights, run = [], []
    for s in act:
        if run and s["t"] - run[-1]["t"] > 30 * 60:
            nights.append(run)
            run = []
        run.append(s)
    if run:
        nights.append(run)
    out = []
    for run in nights:
        if len(run) < 90:
            continue
        bed, wake = run[0]["t"], run[-1]["t"] + 60
        stages, sums = [], {"light": 0, "deep": 0, "rem": 0, "wake": 0}
        for s in run:
            kind = "rem" if s["r"] & 127 > 55 else ("deep" if s["d"] & 127 > 42 else "light")
            m = round((s["t"] - bed) / 60)
            sums[kind] += 1
            if stages and stages[-1][0] == kind and stages[-1][2] == m:
                stages[-1][2] = m + 1
            else:
                stages.append([kind, m, m + 1])
        out.append({"date": _day(wake), "bed": bed, "wake": wake, "total": sums["light"] + sums["deep"] + sums["rem"], "score": 0,
                    "deep": sums["deep"], "light": sums["light"], "rem": sums["rem"], "awake": 0, "stages": stages, "naps": [],
                    "estimated": True})
    return out


def build_nights(store, dates):
    out = {}
    for key in dates:
        start = _midnight(key) - 86400 + 12 * 3600   # from noon the day before
        end = _midnight(key) + 18 * 3600
        sessions = [s for s in store.kinds.get("sleep", {}).values() if start <= s["wake"] < end]
        if sessions:
            best = max(sessions, key=lambda s: (s["light"] + s["deep"] + s["rem"], s["t"]))
            out[key] = _night_from_session(store, best)
        else:
            for n in _nights_from_activity(store, start, end):
                if n["date"] == key and (key not in out or n["total"] > out[key]["total"]):
                    out[key] = n
    return out


def build(store, dates):
    """→ {days: [day], nights: [night]} for the given local dates."""
    days = [d for d in (build_day(store, k) for k in sorted(dates)) if d]
    nights = list(build_nights(store, dates).values())
    return {"days": days, "nights": nights}


# ── Gadgetbridge's database export ───────────────────────────────────────
GB_TABLES = {
    # kind: (table, columns → sample)
    "activity": ("HUAMI_EXTENDED_ACTIVITY_SAMPLE", "TIMESTAMP, RAW_KIND, RAW_INTENSITY, STEPS, HEART_RATE, SLEEP, DEEP_SLEEP, REM_SLEEP",
                 lambda r: {"t": r[0], "k": r[1], "i": r[2], "s": r[3], "h": r[4], "sl": r[5] or 0, "d": r[6] or 0, "r": r[7] or 0}),
    "stress": ("HUAMI_STRESS_SAMPLE", "TIMESTAMP, STRESS", lambda r: {"t": r[0] // 1000, "v": r[1]}),
    "spo2": ("HUAMI_SPO2_SAMPLE", "TIMESTAMP, SPO2", lambda r: {"t": r[0] // 1000, "v": r[1]}),
    "resting": ("HUAMI_HEART_RATE_RESTING_SAMPLE", "TIMESTAMP, HEART_RATE", lambda r: {"t": r[0] // 1000, "v": r[1]}),
    "hrv": ("GENERIC_HRV_VALUE_SAMPLE", "TIMESTAMP, VALUE", lambda r: {"t": r[0] // 1000, "v": r[1]}),
    "breathing": ("HUAMI_SLEEP_RESPIRATORY_RATE_SAMPLE", "TIMESTAMP, RATE", lambda r: {"t": r[0] // 1000, "v": r[1]}),
    "temperature": ("GENERIC_TEMPERATURE_SAMPLE", "TIMESTAMP, TEMPERATURE", lambda r: {"t": r[0] // 1000, "v": round(r[1], 2)}),
    "pai": ("HUAMI_PAI_SAMPLE", "TIMESTAMP, PAI_LOW, PAI_MODERATE, PAI_HIGH, TIME_LOW, TIME_MODERATE, TIME_HIGH, PAI_TODAY, PAI_TOTAL",
            lambda r: {"t": r[0] // 1000, "low": r[1], "mod": r[2], "high": r[3], "minLow": r[4], "minMod": r[5], "minHigh": r[6], "today": r[7], "total": r[8]}),
}


def import_gadgetbridge(store, db_path, name_hint="Active 2"):
    """Reads a Gadgetbridge database export (read only) into the store; → dates."""
    from . import fetch
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    dates = set()
    try:
        dev = con.execute("SELECT _id FROM DEVICE WHERE NAME LIKE ? OR NAME LIKE 'Amazfit%' ORDER BY _id DESC", (f"%{name_hint}%",)).fetchall()
        ids = [d[0] for d in dev]
        if not ids:
            return dates
        marks = ",".join("?" * len(ids))
        for kind, (table, cols, conv) in GB_TABLES.items():
            try:
                rows = con.execute(f"SELECT {cols} FROM {table} WHERE DEVICE_ID IN ({marks})", ids).fetchall()
            except sqlite3.Error:
                continue
            dates |= store.add(kind, [conv(r) for r in rows if r[1] is not None])
        try:
            rows = con.execute(f"SELECT TIMESTAMP, DATA FROM HUAMI_SLEEP_SESSION_SAMPLE WHERE DEVICE_ID IN ({marks})", ids).fetchall()
            sessions = []
            for _, blob in rows:
                if blob and len(blob) >= 594:
                    sessions += fetch.parse("sleep", 0, bytes(blob[:594]))
            dates |= store.add("sleep", sessions)
        except sqlite3.Error:
            pass
    finally:
        con.close()
    oldest = (date.today() - timedelta(days=KEEP_DAYS)).isoformat()
    return {d for d in dates if d >= oldest}
