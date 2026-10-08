pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Where the time at the screen goes. Every few seconds the time since the
// last look is added to the window that has the focus, its app, its
// workspace and, in a browser, the page in front. Idle, locked and asleep
// count for nothing; a video keeps counting, it holds the screen awake.
//
// The page comes from the browser extension (dotfiles/floorp/downloads): it
// tells which tab is in front, and a browser window counts for that page
// while its title starts with the tab's. Only host and path are kept, never
// what follows a ? or #, and nothing of a private window.
//
// A day keeps its total, its hours, its longest stretch without a pause and
// the seconds per app, window, workspace, host and page (screentime.json).
// Windows and pages of days older than two weeks shrink to the biggest few.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("screentime")
	readonly property int sampleSeconds: 5
	readonly property int idleSeconds: 90
	readonly property int keepDays: 400
	readonly property int detailDays: 14

	// day (yyyy-MM-dd) → { total, longest, longestEnd, hours: [24], apps: { appId: s },
	//   windows: { "appId\ntitle": s }, spaces: { "output\nname": s }, links: { host: s },
	//   pages: { "host/path": [s, title] } }
	// changed in place: whatever reads it binds to `stamp`
	property var days: ({})
	property int stamp: 0
	property string today: root.dayKey(new Date())
	property real lastTick: Date.now()
	// seconds at the screen since the last pause
	property int stretch: 0
	property bool dirty: false
	// the tab in front of each browser: { source: { host, path, title } }
	property var tabs: ({})
	readonly property bool browserLinked: Object.keys(root.tabs).length > 0

	readonly property var kinds: [
		{ value: "apps", label: "Apps" },
		{ value: "windows", label: "Windows" },
		{ value: "spaces", label: "Workspaces" },
		{ value: "links", label: "Links" }
	]

	function dayKey(date) {
		return Qt.formatDate(date, "yyyy-MM-dd");
	}

	function dateOf(key) {
		const parts = String(key).split("-").map(Number);
		return new Date(parts[0], parts[1] - 1, parts[2]);
	}

	function shifted(key, days) {
		const date = root.dateOf(key);
		return root.dayKey(new Date(date.getFullYear(), date.getMonth(), date.getDate() + days));
	}

	function emptyDay() {
		return { total: 0, longest: 0, longestEnd: 0, hours: new Array(24).fill(0), apps: {}, windows: {}, spaces: {}, links: {}, pages: {} };
	}

	function format(seconds) {
		const minutes = Math.round(seconds / 60);
		if (seconds > 0 && minutes === 0) return "<1 min";
		return minutes < 60 ? `${minutes} min` : `${Math.floor(minutes / 60)} h ${String(minutes % 60).padStart(2, "0")}`;
	}

	// 5:42, where there is little room
	function clock(seconds) {
		const minutes = Math.round(seconds / 60);
		return `${Math.floor(minutes / 60)}:${String(minutes % 60).padStart(2, "0")}`;
	}

	// ── reading ─────────────────────────────────────────────────────────────
	function day(key) {
		root.stamp;
		return root.days[key] || root.emptyDay();
	}

	function total(key) {
		root.stamp;
		return root.days[key]?.total ?? 0;
	}

	function appName(appId) {
		if (!appId) return "Desktop";
		const entry = DesktopEntries.heuristicLookup(appId);
		if (entry && entry.name) return entry.name;
		// org.gnome.Nautilus → Nautilus
		const last = String(appId).split(".").pop() || String(appId);
		return last.charAt(0).toUpperCase() + last.slice(1);
	}

	// what a day went to, biggest first: [{ key, label, detail, appId, icon, seconds }]
	function rows(key, kind) {
		const day = root.day(key);
		const table = day[kind] || {};
		const outputs = {};
		if (kind === "spaces") Object.keys(table).forEach(name => outputs[name.split("\n")[0]] = true);
		// the page of each host most time went to
		const pages = {};
		if (kind === "links") {
			for (const page of Object.keys(day.pages)) {
				const host = page.split("/")[0];
				if (!pages[host] || day.pages[page][0] > pages[host][0]) pages[host] = day.pages[page];
			}
		}
		return Object.keys(table).map(name => {
			const parts = name.split("\n");
			const row = { key: name, label: name, detail: "", appId: "", icon: "", seconds: table[name] };
			if (kind === "apps") {
				row.label = root.appName(name);
				row.appId = name;
			} else if (kind === "windows") {
				row.label = parts[1] || root.appName(parts[0]);
				row.detail = parts[1] ? root.appName(parts[0]) : "";
				row.appId = parts[0];
			} else if (kind === "spaces") {
				row.label = /^\d+$/.test(parts[1]) ? `Workspace ${parts[1]}` : parts[1];
				row.detail = Object.keys(outputs).length > 1 ? parts[0] : "";
				row.icon = "view_grid_outline";
			} else {
				row.detail = pages[name] ? String(pages[name][1] || "") : "";
				row.icon = "web";
			}
			return row;
		}).filter(row => row.seconds > 0).sort((a, b) => b.seconds - a.seconds);
	}

	// the week of a day, Monday to Sunday: [{ key, date, total, ahead }]
	function week(key) {
		root.stamp;
		const date = root.dateOf(key);
		const out = [];
		for (let i = 0; i < 7; i += 1) {
			const each = new Date(date.getFullYear(), date.getMonth(), date.getDate() - (date.getDay() + 6) % 7 + i);
			const name = root.dayKey(each);
			out.push({ key: name, date: each, total: root.days[name]?.total ?? 0, ahead: name > root.today });
		}
		return out;
	}

	// a day against the one before, which for today counts up to this time
	// of day: { seconds, ratio } or null when that day has nothing to say
	function versus(key) {
		root.stamp;
		const before = root.days[root.shifted(key, -1)];
		if (!before) return null;
		let reference = before.total;
		if (key === root.today) {
			const now = new Date();
			reference = before.hours.slice(0, now.getHours()).reduce((sum, s) => sum + s, 0) + before.hours[now.getHours()] * now.getMinutes() / 60;
		}
		if (reference < 60) return null;
		const seconds = root.total(key) - reference;
		return { seconds: seconds, ratio: seconds / reference };
	}

	// ── counting ────────────────────────────────────────────────────────────
	function cleanTitle(title) {
		// spinners, bullets and unread counts in front of a title change all the time
		return String(title || "").replace(/^(\(\d+\)|[ -⯿⠀-⣿•·*]+)\s*/, "").trim().slice(0, 160);
	}

	function tabFor(title) {
		for (const source of Object.keys(root.tabs)) {
			const tab = root.tabs[source];
			if (tab.host !== "" && tab.title !== "" && title.startsWith(tab.title)) return tab;
		}
		return null;
	}

	function tick() {
		const now = Date.now();
		const seconds = Math.round((now - root.lastTick) / 1000);
		root.lastTick = now;
		const date = new Date(now);
		const key = root.dayKey(date);
		if (key !== root.today) {
			root.today = key;
			root.prune();
		}
		// asleep, or nobody there
		if (seconds > root.sampleSeconds * 4 || seconds <= 0 || Session.locked || idle.isIdle) {
			root.stretch = 0;
			return;
		}
		if (!root.days[key]) root.days[key] = root.emptyDay();
		const day = root.days[key];
		const count = (table, name) => table[name] = (table[name] || 0) + seconds;

		day.total += seconds;
		day.hours[date.getHours()] += seconds;
		root.stretch += seconds;
		if (root.stretch > day.longest) {
			day.longest = root.stretch;
			day.longestEnd = now;
		}
		const space = Niri.workspaces.find(workspace => workspace.is_focused);
		if (space) count(day.spaces, `${space.output}\n${space.name || space.idx}`);
		const window = Niri.windows.find(each => each.is_focused);
		if (window) {
			const app = String(window.app_id || "");
			count(day.apps, app);
			count(day.windows, `${app}\n${root.cleanTitle(window.title)}`);
			const tab = root.tabFor(String(window.title || ""));
			if (tab) {
				count(day.links, tab.host);
				const page = day.pages[tab.host + tab.path] || (day.pages[tab.host + tab.path] = [0, ""]);
				page[0] += seconds;
				page[1] = tab.title;
			}
		}
		root.dirty = true;
		root.stamp += 1;
	}

	// the biggest `keep` of a table
	function shrunk(table, keep, seconds) {
		const names = Object.keys(table);
		if (names.length <= keep) return table;
		const out = {};
		names.sort((a, b) => seconds(table[b]) - seconds(table[a])).slice(0, keep).forEach(name => out[name] = table[name]);
		return out;
	}

	function prune() {
		const cutoff = root.dayKey(new Date(Date.now() - root.keepDays * 24 * 3600 * 1000));
		const detail = root.dayKey(new Date(Date.now() - root.detailDays * 24 * 3600 * 1000));
		for (const key of Object.keys(root.days)) {
			const day = root.days[key];
			if (key < cutoff) {
				delete root.days[key];
				continue;
			}
			const keep = key < detail ? 12 : 150;
			day.windows = root.shrunk(day.windows, keep, value => value);
			day.pages = root.shrunk(day.pages, keep, value => value[0]);
		}
	}

	// ── the browser (through the socket of Downloads) ───────────────────────
	function tab(source, message) {
		const host = String(message.host || "").replace(/^www\./, "");
		root.tabs = Object.assign({}, root.tabs, { [source]: { host: host, path: String(message.path || "/"), title: String(message.title || "") } });
	}

	function tabGone(source) {
		if (!root.tabs[source]) return;
		const next = Object.assign({}, root.tabs);
		delete next[source];
		root.tabs = next;
	}

	function save() {
		if (!root.dirty) return;
		root.dirty = false;
		root.prune();
		store.setText(JSON.stringify({ days: root.days }));
	}

	Component.onDestruction: root.save()

	IdleMonitor {
		id: idle

		enabled: root.enabled
		timeout: root.idleSeconds
		respectInhibitors: true
	}

	Timer {
		running: root.enabled
		repeat: true
		interval: root.sampleSeconds * 1000
		onRunningChanged: root.lastTick = Date.now()
		onTriggered: root.tick()
	}

	Timer {
		running: root.enabled
		repeat: true
		interval: 60 * 1000
		onTriggered: root.save()
	}

	FileView {
		id: store

		path: Paths.stateFile("screentime.json")
		blockLoading: true
		blockWrites: true
		printErrors: false
		onLoaded: {
			try {
				const days = (JSON.parse(String(text() || "{}")) || {}).days || {};
				for (const key of Object.keys(days)) days[key] = Object.assign(root.emptyDay(), days[key]);
				root.days = days;
				root.stamp += 1;
			} catch (error) {}
		}
	}
}
