"""Where a world comes from, whatever is switched on.

A role of the world (mapping.json) lists providers in order of preference; the
first whose plugins are on and which has data takes the role. So without the
timer, towns grow from commits, then from screen time, then from finished
todos, and at the very least from the hours the machine was up.

Providers read only. `realms` hands out work per day as
{realm, plot, key, bill, other, ...}, the others a number per day. Numbers of
past days are kept in a ledger of our own, because some sources forget (the
downloads after 60 days), and a day that shrinks would move what came after it.
"""

import importlib.machinery
import importlib.util
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from collections import defaultdict
from datetime import date, datetime, timedelta
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPTS = HERE.parent
sys.path.insert(0, str(SCRIPTS))
import host  # noqa: E402

WORK_APPS = re.compile(r"kitty|alacritty|foot|term|code|codium|zed|nvim|idea|storm|editor|gimp|figma|obsidian|libreoffice|pshell", re.I)


def state():
	return Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state") / "pshell"


def cache():
	return Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "pshell"


def read_json(path, fallback=None):
	try:
		return json.loads(Path(path).read_text())
	except (OSError, ValueError):
		return {} if fallback is None else fallback


def sqlite_rows(path, query):
	if not Path(path).exists():
		return []
	try:
		with sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=2) as connection:
			return connection.execute(query).fetchall()
	except sqlite3.Error:
		return []


def day_of(stamp):
	return datetime.fromtimestamp(float(stamp)).strftime("%Y-%m-%d")


def norm(text):
	return re.sub(r"[^a-z0-9]+", "", str(text or "").lower())


# ── work: realms and plots ──────────────────────────────────────────────────

def load_qtrack():
	cli = SCRIPTS / "qtrack/qtrack-local"
	loader = importlib.machinery.SourceFileLoader("qtrack_local", str(cli))
	spec = importlib.util.spec_from_loader("qtrack_local", loader)
	module = importlib.util.module_from_spec(spec)
	sys.modules["qtrack_local"] = module
	loader.exec_module(module)
	return module


def tickets():
	"""Only what has a Teamwork ticket: keywords like "System" are not places."""
	module = load_qtrack()
	source = module.resolve_db_path()
	if not Path(source).exists():
		return {}
	out = defaultdict(list)
	with tempfile.TemporaryDirectory(prefix="pshell-world-") as scratch:
		copy = Path(scratch) / "tracker.db"
		live = sqlite3.connect(f"file:{source}?mode=ro", uri=True)
		target = sqlite3.connect(copy)
		live.backup(target)
		target.close()
		live.close()
		store = module.TrackerStore(copy)
		now = int(time.time())
		for day in sorted(item["day"] for item in store.tracked_days(now)["days"]):
			for entry in store.day_entries(day, now)["entries"]:
				minutes = int(entry.get("tracking_minutes") or 0)
				task = entry.get("teamwork_task_id")
				if minutes <= 0 or not task:
					continue
				billable = entry.get("teamwork_billable") not in (False, 0)
				out[day].append({
					"realm": str(entry.get("teamwork_project_name") or entry.get("project") or "").strip() or "Teamwork",
					"realmKey": f"p{entry.get('teamwork_project_id') or norm(entry.get('teamwork_project_name'))}",
					"plot": str(entry.get("teamwork_task_name") or entry.get("description") or "").strip(),
					"key": f"t{task}", "task": int(task),
					"project": str(entry.get("project") or ""), "description": str(entry.get("description") or ""),
					"bill": minutes if billable else 0, "other": 0 if billable else minutes,
					"sent": bool(entry.get("teamwork_synced")), "at": int(entry.get("first_started_ts") or 0),
				})
		store.close()
	return out


def git_repos(mapping):
	found = []
	for root in mapping.get("gitRoots", []):
		root = Path(root).expanduser()
		if (root / ".git").exists():
			found.append(root)
		elif root.is_dir():
			found += [child for child in sorted(root.iterdir()) if (child / ".git").exists()]
	return found


def git_commits(mapping):
	"""Per repository: (day, author, first folders touched) of one's own commits, and the tags."""
	repos = {}
	for repo in git_repos(mapping):
		try:
			mail = subprocess.run(["git", "-C", str(repo), "config", "user.email"], capture_output=True, text=True, timeout=5).stdout.strip()
			log = subprocess.run(["git", "-C", str(repo), "log", "--all", "--no-merges", "--name-only", "--format=\x01%ct\x02%ae"], capture_output=True, text=True, timeout=30).stdout
			tags = subprocess.run(["git", "-C", str(repo), "for-each-ref", "refs/tags", "--format=%(creatordate:unix)"], capture_output=True, text=True, timeout=10).stdout
		except (OSError, subprocess.SubprocessError):
			continue
		commits, authors = [], set()
		for block in log.split("\x01")[1:]:
			head, _, files = block.partition("\n")
			stamp, _, author = head.partition("\x02")
			authors.add(author)
			if mail and author != mail:
				continue
			first = next((line.split("/")[0] for line in files.splitlines() if line.strip()), "")
			commits.append((day_of(stamp), first))
		if commits:
			repos[repo.name] = {"commits": commits, "people": len(authors), "tags": [day_of(line) for line in tags.split() if line.isdigit()]}
	return repos


def realms_git(mapping):
	out = defaultdict(list)
	for name, repo in git_commits(mapping).items():
		for day, folder in repo["commits"]:
			out[day].append({"realm": name, "realmKey": f"g{norm(name)}", "plot": folder or name, "key": f"g{norm(name)}/{norm(folder)}",
			                 "bill": 30, "other": 0, "people": repo["people"]})
	return out


def screentime():
	return read_json(state() / "screentime.json").get("days", {})


def app_seconds(day):
	apps = day.get("apps")
	if isinstance(apps, dict):
		return {name: float(value if not isinstance(value, dict) else value.get("seconds", 0)) for name, value in apps.items()}
	if isinstance(apps, list):
		return {str(item.get("key") or item.get("name") or item.get("app")): float(item.get("seconds") or 0) for item in apps if isinstance(item, dict)}
	return {}


def realms_screentime(_mapping):
	out = defaultdict(list)
	for day, data in screentime().items():
		apps = app_seconds(data)
		if not apps and float(data.get("total") or 0) > 0:
			apps = {"Desktop": float(data["total"])}
		for name, seconds in apps.items():
			minutes = int(seconds / 60)
			if minutes < 5:
				continue
			work = bool(WORK_APPS.search(name))
			out[day].append({"realm": name, "realmKey": f"a{norm(name)}", "plot": name, "key": f"a{norm(name)}",
			                 "bill": minutes if work else 0, "other": 0 if work else minutes})
	return out


def realms_todos(_mapping):
	"""Without dates a closed task stands on the day it was first seen by the ledger."""
	path = Path.home() / "todo/Tasks.md"
	today = date.today().isoformat()
	out = defaultdict(list)
	group = "Tasks"
	try:
		lines = path.read_text().splitlines()
	except OSError:
		return out
	for line in lines:
		if line.startswith("## "):
			group = line[3:].strip()
		elif re.match(r"\s*- \[[xX]\]", line):
			out[today].append({"realm": group, "realmKey": f"n{norm(group)}", "plot": group, "key": f"n{norm(group)}", "bill": 30, "other": 0})
	return out


def boots():
	try:
		text = subprocess.run(["journalctl", "--list-boots", "-o", "json", "--no-pager"], capture_output=True, text=True, timeout=10).stdout
		rows = json.loads(text)
	except (OSError, ValueError, subprocess.SubprocessError):
		return {}
	days = defaultdict(float)
	for row in rows:
		first, last = row.get("first_entry"), row.get("last_entry")
		if first and last:
			days[day_of(first / 1e6)] += (last - first) / 6e7
	return days


def realms_boots(_mapping):
	name = (Path("/etc/hostname").read_text().strip() if Path("/etc/hostname").exists() else "") or "Pshell"
	out = defaultdict(list)
	for day, minutes in boots().items():
		out[day].append({"realm": name, "realmKey": "host", "plot": name, "key": "host", "bill": int(minutes * .3), "other": int(minutes * .7)})
	return out


REALMS = {
	"tickets": (("qtrack",), lambda mapping: tickets()),
	"git": ((), realms_git),
	"screentime": (("screentime",), realms_screentime),
	"todos": (("todos",), realms_todos),
	"boots": ((), realms_boots),
}


# ── numbers per day ─────────────────────────────────────────────────────────

def breaks_days():
	return read_json(state() / "breaks.json").get("days", {})


def numbers(work, mapping):
	"""provider → (plugins, {day: number})"""
	breaks = breaks_days()
	screen = screentime()
	activity = {day: sum(item["bill"] + item["other"] for item in items) for day, items in work.items()}

	def gaps():
		out = {}
		for day, data in screen.items():
			hours = data.get("hours") or []
			used = [i for i, value in enumerate(hours) if float(value or 0) > 120]
			if used:
				out[day] = sum(1 for i in range(used[0], used[-1]) if float(hours[i] or 0) < 900)
		return out

	def untracked():
		return {day: max(0, float(data.get("total") or 0) / 60 - activity.get(day, 0)) for day, data in screen.items()}

	def mail_counts():
		counts = defaultdict(int)
		for day, amount in sqlite_rows(cache() / "messages/mail.db", "select date(date,'unixepoch','localtime'), count(*) from messages group by 1"):
			counts[day] += amount
		return counts

	def chat_counts():
		counts = defaultdict(int)
		for day, amount in sqlite_rows(state() / "whatsapp/chats.db", "select date(case when ts>100000000000 then ts/1000 else ts end,'unixepoch','localtime'), count(*) from messages group by 1"):
			counts[day] += amount
		return counts

	def games():
		days = defaultdict(float)
		for sessions in read_json(state() / "game-sessions.json").values():
			for start, end in sessions:
				start, end = float(start), float(end)
				if start > 1e11:
					start, end = start / 1000, end / 1000
				days[day_of(start)] += max(0, end - start) / 60
		return days

	def streams():
		return dict(sqlite_rows(state() / "streams/streams.db", "select day, sum(seconds)/60 from watch_day group by 1"))

	def prints():
		days = defaultdict(int)
		data = read_json(state() / "printer-history.json", [])
		for item in data if isinstance(data, list) else data.get("history", []):
			if isinstance(item, dict) and item.get("ended"):
				days[day_of(float(item["ended"]) / (1000 if float(item["ended"]) > 1e11 else 1))] += 1
		return days

	def downloads():
		out = {}
		for day, kinds in read_json(state() / "downloads-stats.json").get("days", {}).items():
			out[day] = sum(int(kind.get("count") or 0) for kind in kinds.values() if isinstance(kind, dict))
		return out

	def sleep():
		nights = read_json(state() / "phone/watch-health.json").get("nights", {})
		return {day: float(night.get("total") or 0) / (60 if float(night.get("total") or 0) > 1000 else 1) for day, night in nights.items()}

	return {
		"water": (("breaks", "water"), {day: int(mark.get("ml") or 0) + int(mark.get("glasses") or 0) * 250 for day, mark in breaks.items()}),
		"activity": ((), {day: minutes * 2 for day, minutes in activity.items()}),
		"hours": ((), {day: minutes // 60 for day, minutes in activity.items()}),
		"breaks": (("breaks",), {day: int(mark.get("breaks") or 0) for day, mark in breaks.items()}),
		"screentime-gaps": (("screentime",), gaps),
		"headaches": (("breaks", "headache-log"), {day: len(mark.get("headaches") or []) for day, mark in breaks.items()}),
		"pressure": (("breaks",), {day: float((mark.get("pressure") or {}).get("swing") or 0) for day, mark in breaks.items()}),
		"sleep": (("watch",), sleep),
		"long-days": (("screentime",), {day: float(data.get("total") or 0) / 3600 for day, data in screen.items()}),
		"calendar": (("microsoft-calendar",), lambda: calendar(work)),
		"mail": (("messages",), lambda: merge(mail_counts(), chat_counts())),
		"games": (("games",), games),
		"streams": (("streams",), streams),
		"printer": (("printer",), prints),
		"downloads": (("downloads",), downloads),
		"screentime-untracked": (("screentime",), untracked),
	}


def merge(*counts):
	out = defaultdict(int)
	for count in counts:
		for day, value in count.items():
			out[day] += value
	return out


def calendar(work):
	"""Meetings per day as 100 × big ones + small ones; past days are asked only once."""
	path = state() / "world-calendar.json"
	known = read_json(path)
	today = date.today().isoformat()
	wanted = sorted(day for day in work if day == today or day not in known)
	if wanted:
		try:
			text = subprocess.run([sys.executable, str(SCRIPTS / "ms_calendar.py"), "events", wanted[0], (date.fromisoformat(wanted[-1]) + timedelta(days=1)).isoformat()],
			                      capture_output=True, text=True, timeout=25).stdout
			events = json.loads(text)
			events = events.get("events", events) if isinstance(events, dict) else events
		except (OSError, ValueError, subprocess.SubprocessError):
			events = None
		if isinstance(events, list):
			for day in wanted:
				known[day] = 0
			for event in events:
				if not isinstance(event, dict) or event.get("allDay") or event.get("showAs") == "free":
					continue
				day = str(event.get("start"))[:10]
				if day in known:
					known[day] += 100 if len(event.get("attendees") or []) >= 6 else 1
			write_json(path, known)
	return known


def write_json(path, value):
	path.parent.mkdir(parents=True, exist_ok=True)
	scratch = path.with_suffix(".tmp")
	scratch.write_text(json.dumps(value))
	scratch.replace(path)


def available(names, plugins, table):
	for name in names:
		needs, data = table.get(name, (("?",), None))
		if all(plugin in plugins for plugin in needs):
			yield name, data


def gather(mapping_path=HERE / "mapping.json"):
	"""Everything the layout needs, and which provider took which role."""
	mapping = read_json(mapping_path)
	plugins = {name for name, on in host.plugins().items() if on}
	used = {}

	work = {}
	for name, data in available(mapping["realms"], plugins, REALMS):
		work = data(mapping)
		if work:
			used["realms"] = name
			break
	work = {day: list(items) for day, items in work.items()}

	# a provider without non-billable work leaves the forest to the next
	if not any(item["other"] for items in work.values() for item in items):
		for name, data in available(mapping["forest"], plugins, REALMS):
			if name == used.get("realms"):
				continue
			source = data(mapping) if name in REALMS else {}
			added = False
			for day, items in source.items():
				for item in items:
					if item["other"] > 0:
						work.setdefault(day, []).append(dict(item, realm="Wald", realmKey="forest", bill=0))
						added = True
			if added:
				used["forest"] = name
				break

	table = numbers(work, mapping)
	today = date.today().isoformat()
	ledger_path = state() / "world-ledger.json"
	ledger = read_json(ledger_path)
	result = {}
	for role, names in mapping.items():
		if role in ("realms", "forest", "gitRoots"):
			continue
		chosen = {}
		for name, data in available(names, plugins, table):
			chosen = data() if callable(data) else data
			if chosen and any(chosen.values()):
				used[role] = name
				break
			chosen = {}
		kept = ledger.setdefault(role, {})
		provider = used.get(role)
		if provider and kept.get("_provider") not in (None, provider):
			kept.clear()
		if provider:
			kept["_provider"] = provider
		for day, value in chosen.items():
			kept[day] = value if day == today else max(value, kept.get(day, 0))
		result[role] = {day: value for day, value in kept.items() if day != "_provider"} if provider else {}
	write_json(ledger_path, ledger)

	monuments = {}
	if used.get("realms") != "git" and "monuments" in result:
		repos = git_commits(mapping)
		for name, repo in repos.items():
			for day in repo["tags"]:
				monuments[day] = monuments.get(day, 0) + 1
	result["monuments"] = monuments
	sent = defaultdict(int)
	unsent = defaultdict(int)
	if used.get("realms") == "tickets":
		for day, items in work.items():
			for item in items:
				(sent if item.get("sent") else unsent)[item["realmKey"]] += item["bill"]
	result["sent"], result["unsent"] = dict(sent), dict(unsent)
	# what the todo list says now; it has no dates
	result["todos"] = todo_counts() if "todos" in plugins and used.get("realms") != "todos" else (0, 0)
	return work, result, used, plugins


def todo_counts():
	try:
		text = (Path.home() / "todo/Tasks.md").read_text()
	except OSError:
		return 0, 0
	return len(re.findall(r"^\s*- \[[xX]\]", text, re.M)), len(re.findall(r"^\s*- \[[ /!?>]\]", text, re.M))


# ── who else is on a ticket ─────────────────────────────────────────────────

def ticket_people(task_ids):
	"""Teamwork: everyone assigned to a ticket or who logged time on it, kept for a day. Names only go into the cache."""
	path = cache() / "world/people.json"
	known = read_json(path)
	missing = [task for task in task_ids if str(task) not in known.get("tasks", {})]
	if not missing and time.time() - known.get("at", 0) < 86400:
		return known.get("tasks", {})
	tasks = dict(known.get("tasks", {}))
	try:
		module = load_qtrack()
		client = module.TeamworkClient()
		for start in range(0, len(task_ids), 40):
			part = task_ids[start:start + 40]
			payload = client.request("GET", "/projects/api/v3/tasks.json", params={"ids": ",".join(map(str, part)), "include": "users", "pageSize": 100})
			users = (payload.get("included") or {}).get("users") or {}
			names = {str(user_id): f"{user.get('firstName', '')} {user.get('lastName', '')}".strip() for user_id, user in users.items()}
			for task in payload.get("tasks") or []:
				ids = {str(user.get("id")) for user in task.get("assigneeUsers") or task.get("assignees") or [] if isinstance(user, dict)}
				for field in ("createdBy", "updatedBy"):
					if task.get(field):
						ids.add(str(task[field]))
				tasks[str(task.get("id"))] = sorted(names.get(user, user) for user in ids)
		for task in task_ids:
			payload = client.request("GET", f"/projects/api/v3/tasks/{task}/time.json", params={"include": "users", "pageSize": 200})
			users = (payload.get("included") or {}).get("users") or {}
			names = {str(user_id): f"{user.get('firstName', '')} {user.get('lastName', '')}".strip() for user_id, user in users.items()}
			loggers = {names.get(str(entry.get("userId")), str(entry.get("userId"))) for entry in payload.get("timelogs") or [] if entry.get("userId")}
			tasks[str(task)] = sorted(set(tasks.get(str(task), [])) | loggers)
		write_json(path, {"at": time.time(), "tasks": tasks})
	except Exception:  # offline or no key: the world stands without them
		pass
	return tasks
