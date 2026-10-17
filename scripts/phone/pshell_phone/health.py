"""What the watch measured, kept as a history for the shell's >watch.

The face hands it over now and then ({"t":"health","d":…}, watch/face/lib/
health.js): last night's sleep with its stages, the heart through the day
in 10-minute means, stress and blood oxygen by the hour, skin temperature by
the half hour, the day's activity. The watch counts minutes from 0:00 of
its day; `at` (ms) and `minute` (now, in that count) place them in time.

Kept in watch-health.json: nights by the day they ended, days by their
date, both for DAYS days. The topic "watch" (owner daemon, local) is what
the shell sees: the last nights and days, today in full.
"""

import json
import os
import time
from datetime import date, datetime, timedelta

from . import config

FILE = config.STATE / "watch-health.json"
DAYS = 120
STAGES = ("wake", "rem", "light", "deep")


def _number(value, default=0):
    try:
        number = float(value)
    except (TypeError, ValueError):
        return default
    return number if number == number else default  # NaN


def _series(values, length, low=None):
    """A list of at most `length` numbers; what is not one becomes 0."""
    out = []
    for value in list(values or [])[:length] if isinstance(values, list) else []:
        number = round(_number(value), 1)
        out.append(0 if low is not None and number <= low else number)
    return out


def _day(stamp):
    return datetime.fromtimestamp(stamp).date().isoformat()


class Health:
    def __init__(self, path=None):
        self.path = path or FILE
        self.nights = {}
        self.days = {}
        self.synced = 0
        self.battery = -1
        try:
            data = json.loads(self.path.read_text())
            self.nights = data.get("nights") or {}
            self.days = data.get("days") or {}
            self.synced = data.get("synced") or 0
            self.battery = data.get("battery", -1)
        except (OSError, ValueError, AttributeError):
            pass

    def save(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_suffix(".tmp")
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w") as handle:
            json.dump({"nights": self.nights, "days": self.days, "synced": self.synced, "battery": self.battery}, handle, separators=(",", ":"))
        temporary.replace(self.path)

    # ── taking it in ───────────────────────────────────────────────────────
    def add(self, d, now=None):
        """Takes one handover; returns False when it is not one."""
        if not isinstance(d, dict):
            return False
        now = now or time.time()
        at = _number(d.get("at")) / 1000 or now
        # the watch's clock wins for where its day starts, ours if it is off
        if abs(at - now) > 6 * 3600:
            at = now
        minute = int(_number(d.get("minute"), -1))
        if not 0 <= minute < 1440:
            local = datetime.fromtimestamp(at)
            minute = local.hour * 60 + local.minute
        midnight = int(at // 60 * 60) - minute * 60
        today = _day(midnight + 3600)

        self.synced = int(at)
        self.battery = int(_number(d.get("battery"), -1))
        night = self._night(d.get("sleep"), midnight, minute)
        if night:
            self.nights[night["date"]] = night
        self._today(today, d, midnight, at)
        self._week(d, midnight)
        self._trim(today)
        self.save()
        return True

    def _night(self, sleep, midnight, minute):
        if not isinstance(sleep, dict):
            return None
        total = int(_number(sleep.get("total")))
        if total <= 0:
            return None
        end = int(_number(sleep.get("end"))) % 1440
        start = int(_number(sleep.get("start"))) % 1440
        # it ended today, or yesterday if that time has not come yet today
        wake = midnight + end * 60
        if end > minute + 5:
            wake -= 86400
        length = (end - start) % 1440 or total
        bed = wake - length * 60

        def place(m):
            back = (end - int(_number(m)) % 1440) % 1440
            # a stage may run on a little past the end the watch gives
            if back > 1380:
                back -= 1440
            return wake - back * 60

        stages = []
        sums = dict.fromkeys(STAGES, 0)
        for stage in sleep.get("stages") or []:
            if not isinstance(stage, list) or len(stage) < 3:
                continue
            kind = stage[0] if stage[0] in STAGES else "light"
            begin, stop = place(stage[1]), place(stage[2])
            if stop <= begin:
                continue
            # minutes from going to bed: compact, and the shell needs no dates
            stages.append([kind, round((begin - bed) / 60), round((stop - bed) / 60)])
            sums[kind] += round((stop - begin) / 60)
        stages.sort(key=lambda s: s[1])
        naps = []
        for nap in sleep.get("naps") or []:
            if isinstance(nap, list) and len(nap) >= 2:
                begin = midnight + int(_number(nap[0])) % 1440 * 60
                stop = midnight + int(_number(nap[1])) % 1440 * 60
                if stop > begin:
                    naps.append([begin, stop])
        deep = int(_number(sleep.get("deep"))) or sums["deep"]
        return {
            "date": _day(wake),
            "bed": bed,
            "wake": wake,
            "total": total,
            "score": int(_number(sleep.get("score"))),
            "deep": deep,
            "light": sums["light"],
            "rem": sums["rem"],
            "awake": sums["wake"],
            "stages": stages,
            "naps": naps,
        }

    def _today(self, key, d, midnight, at):
        day = dict(self.days.get(key) or {})
        day["date"] = key
        for name in ("steps", "calories", "stand", "fat"):
            part = d.get(name)
            if isinstance(part, dict):
                day[name] = int(_number(part.get("now")))
                day[name + "Goal"] = int(_number(part.get("goal")))
        if "distance" in d:
            day["distance"] = int(_number(d.get("distance")))
        heart = d.get("heart")
        if isinstance(heart, dict):
            day["heart"] = _series(heart.get("day"), 144)
            day["resting"] = int(_number(heart.get("resting")))
            day["last"] = int(_number(heart.get("last")))
            day["max"] = int(_number(heart.get("max")))
            day["maxAt"] = int(_number(heart.get("maxAt")))
        stress = d.get("stress")
        if isinstance(stress, dict):
            day["stress"] = _series(stress.get("hours"), 24)
            day["stressNow"] = int(_number(stress.get("now")))
        oxygen = d.get("oxygen")
        if isinstance(oxygen, dict):
            # the last 24 hours up to now, oldest first
            day["oxygen"] = _series(oxygen.get("hours"), 24)
            day["oxygenNow"] = int(_number(oxygen.get("now")))
        if "temperature" in d:
            day["temperature"] = _series(d.get("temperature"), 48, low=-100)
        pai = d.get("pai")
        if isinstance(pai, dict):
            day["pai"] = round(_number(pai.get("total")))
            day["paiToday"] = round(_number(pai.get("today")))
        day["at"] = int(at)
        self.days[key] = day

    def _week(self, d, midnight):
        """The last week's stress and PAI by the day fill days the face
        did not reach."""
        stress = (d.get("stress") or {}).get("week") if isinstance(d.get("stress"), dict) else None
        pai = (d.get("pai") or {}).get("week") if isinstance(d.get("pai"), dict) else None
        for name, values in (("stressDay", stress), ("paiDay", pai)):
            if not isinstance(values, list):
                continue
            for back, value in enumerate(reversed(values[:7])):
                key = _day(midnight + 3600 - back * 86400)
                number = round(_number(value))
                if number > 0:
                    day = self.days.setdefault(key, {"date": key})
                    day[name] = number

    def _trim(self, today):
        oldest = (date.fromisoformat(today) - timedelta(days=DAYS)).isoformat()
        self.nights = {k: v for k, v in self.nights.items() if k >= oldest}
        self.days = {k: v for k, v in self.days.items() if k >= oldest}

    # ── what the shell sees ────────────────────────────────────────────────
    def view(self, link=None):
        today = date.today().isoformat()
        days = []
        for key in sorted(self.days)[-60:]:
            day = self.days[key]
            hours = [v for v in day.get("stress") or [] if v > 0]
            days.append({
                "date": key,
                "steps": day.get("steps", 0),
                "stepsGoal": day.get("stepsGoal", 0),
                "calories": day.get("calories", 0),
                "resting": day.get("resting", 0),
                "stress": round(sum(hours) / len(hours)) if hours else day.get("stressDay", 0),
                "pai": day.get("paiDay", day.get("paiToday", 0)),
            })
        latest = self.days.get(today) or (self.days[max(self.days)] if self.days else {})
        return {
            "synced": self.synced,
            "battery": self.battery,
            "link": link or {},
            "nights": [self.nights[k] for k in sorted(self.nights)[-60:]],
            "days": days,
            "today": latest,
        }
