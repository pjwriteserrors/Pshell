pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// The task manager (plugin "task-manager"). What runs is read by a daemon of
// its own (scripts/taskmgr/daemon.py), which reads only as much as is asked
// for: nothing while nobody needs it, the machine and each process's load
// every 2 s for the bar, the alerts, the history and the hints on windows,
// and every second with the window's list while the window is open. This is
// the shell's end: what it asks, what the daemon tells, what the shell does
// with it (notifications, game mode, parked windows, agents, the files).
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("task-manager")
	readonly property string daemon: `${Paths.scripts}/taskmgr/daemon.py`
	readonly property string socketPath: `${Paths.runtime}/taskmgr.sock`
	property bool connected: false

	// ── what the daemon tells ──────────────────────────────────────────────
	// { host, kernel, os, machine, boot, cpu, threads, cores, maxFreq, gpus, memTotal, disks }
	property var info: ({})
	// the last look at the machine (daemon.py, event "system")
	property var system: null
	readonly property int coreCount: root.system?.coreCount ?? (root.info.threads ?? 1)
	readonly property real cpu: root.system?.cpu ?? 0
	readonly property var memory: root.system?.memory ?? ({ total: 0, used: 0, available: 0 })
	readonly property real memoryLevel: root.memory.total > 0 ? root.memory.used / root.memory.total : 0
	readonly property var gpus: root.system?.gpus ?? []
	readonly property real gpu: root.gpus.reduce((top, g) => Math.max(top, Number(g.busy) || 0), 0)
	readonly property bool hasGpu: root.gpus.some(g => g.busy !== null && g.busy !== undefined)
	readonly property var temps: root.system?.temps ?? ({})
	readonly property var pressure: root.system?.pressure ?? ({ cpu: { some: 0 }, memory: { some: 0, full: 0 }, io: { some: 0, full: 0 } })
	// the worst of the three pressures: how much time something waited
	readonly property real stall: Math.max(root.pressure.cpu?.some ?? 0, root.pressure.memory?.some ?? 0, root.pressure.io?.some ?? 0)
	readonly property var disks: root.system?.disks ?? []
	readonly property real diskRate: root.disks.reduce((sum, d) => sum + d.read + d.write, 0)
	readonly property var network: root.system?.network ?? []
	readonly property var top: root.system?.top ?? []
	readonly property var topMem: root.system?.topMem ?? []
	readonly property var topGpu: root.system?.topGpu ?? []
	// window id → [load, memory, key] of the app behind it
	readonly property var windowLoad: root.system?.windows ?? ({})
	// windows whose app keeps more than half a core busy for a while
	readonly property var hot: root.system?.hot ?? []

	// the last two minutes, a value a second (two in light): name → [values]
	readonly property int span: 120
	property var series: ({})

	// the list of the window: key → row, in `order`; changes come as `rowsRev`
	property var rows: ({})
	property var order: []
	property int rowsRev: 0
	// the row picked and what the daemon tells of it
	property string selected: ""
	property var detail: null
	property var facts: null
	// keys being ended, and those that did not end in time
	property var ending: ({})
	property var lingering: ({})

	// ── how the window shows it ────────────────────────────────────────────
	// "apps" | "performance" | "services" | "startup" | "ports" | "history"
	property string tab: "apps"
	property string mode: "apps"
	property bool tree: false
	property string sort: "cpu"
	property bool desc: true
	property string filter: ""
	property var expanded: ({})
	property var collapsed: ({ kernel: true })
	property bool showKernel: false
	// the order stays while the pointer is over the list
	property bool hold: false
	// the performance page's device: "cpu" | "memory" | "gpu:<pci>" | "disk:<name>" | "net:<name>" | "sensors" | "power"
	property string device: "cpu"

	property var settings: ({
		background: true, alerts: { leak: true, busy: true, heat: true, memory: true, oom: true }, ignore: [],
		columns: { cpu: true, mem: true, io: true, gpu: true }, gameOffer: true, powerOffer: true, keepAwake: true, agentPorts: true
	})

	function setting(name, fallback) {
		const value = root.settings[name];
		return value === undefined ? fallback : value;
	}

	function setSetting(name, value) {
		root.settings = Object.assign({}, root.settings, { [name]: value });
		root.saveSettings();
		if (["alerts", "ignore", "background"].includes(name)) root.sendLevel();
	}

	function alertOn(kind) {
		return Plugins.on("task-manager-alerts") && (root.settings.alerts?.[kind] ?? true);
	}

	// ── where it shows ─────────────────────────────────────────────────────
	property alias surface: popout
	property alias windowed: popout.windowed
	property alias windowOpen: popout.windowOpen
	readonly property bool panelled: popout.panelled
	readonly property bool shown: popout.shown

	Popout {
		id: popout

		popup: "taskmgr"
		panel: Plugins.on("task-manager-bar")
	}

	function open(tab) {
		if (!root.enabled) return;
		if (tab) root.tab = tab;
		popout.open();
		root.wake();
	}

	function close() {
		popout.close();
	}

	function toggle(tab) {
		if (root.shown && (!tab || tab === root.tab)) root.close();
		else root.open(tab);
	}

	function popOut() {
		popout.popOut();
		root.saveSettings();
	}

	function dock() {
		popout.dock();
		root.saveSettings();
		root.open();
	}

	// ── who needs what ─────────────────────────────────────────────────────
	// something shows a value of the machine (Live sources, a tray, the phone)
	property int watchers: 0
	property int gpuWatchers: 0
	readonly property bool needed: root.enabled && (root.shown || root.watchers > 0 || root.settings.background !== false
		|| Plugins.on("task-manager-alerts") || Plugins.on("task-manager-hints") || root.pausedKeys.length > 0)
	readonly property string level: !root.needed ? "off" : (root.shown ? "full" : "light")

	function watch(delta, gpu) {
		root.watchers = Math.max(0, root.watchers + delta);
		if (gpu) root.gpuWatchers = Math.max(0, root.gpuWatchers + delta);
	}

	onLevelChanged: root.sendLevel()
	onGpuWatchersChanged: root.sendLevel()

	function sendLevel() {
		if (!root.connected) {
			if (root.needed) root.wake();
			return;
		}
		const kinds = Object.keys(root.settings.alerts ?? {}).filter(kind => root.alertOn(kind));
		root.request("level", { level: root.level, gpu: root.gpuWatchers > 0, alerts: kinds.length > 0, ignore: (root.settings.ignore ?? []).concat(["leak", "busy", "heat", "memory", "oom"].filter(kind => !kinds.includes(kind))) });
		if (root.level === "full") {
			root.rows = {};
			root.order = [];
			root.sendView(true);
			if (root.selected !== "") root.request("select", { key: root.selected });
		}
	}

	// ── the list ───────────────────────────────────────────────────────────
	function viewState() {
		return {
			mode: root.mode, tree: root.tree, sort: root.sort, desc: root.desc, filter: root.filter,
			expanded: Object.keys(root.expanded), collapsed: Object.keys(root.collapsed), kernel: root.showKernel, hold: root.hold
		};
	}

	function sendView(now) {
		if (!root.connected) return;
		root.request("view", Object.assign(root.viewState(), { now: !!now }));
	}

	Timer {
		id: viewSoon

		interval: 40
		onTriggered: root.sendView(true)
	}

	onModeChanged: viewSoon.restart()
	onTreeChanged: viewSoon.restart()
	onSortChanged: viewSoon.restart()
	onDescChanged: viewSoon.restart()
	onFilterChanged: viewSoon.restart()
	onShowKernelChanged: viewSoon.restart()
	onHoldChanged: root.sendView(false)

	function sortBy(column) {
		if (root.sort === column) root.desc = !root.desc;
		else {
			root.sort = column;
			root.desc = column !== "name";
		}
		root.saveSettings();
	}

	function setExpanded(key, on) {
		const sections = key.startsWith("s:");
		const name = sections ? key.slice(2) : key;
		if (sections) {
			const next = Object.assign({}, root.collapsed);
			if (on) delete next[name];
			else next[name] = true;
			root.collapsed = next;
		} else {
			const next = Object.assign({}, root.expanded);
			if (on) next[name] = true;
			else delete next[name];
			root.expanded = next;
		}
		root.sendView(true);
	}

	function toggleExpanded(key) {
		const row = root.rows[key];
		if (!row || !row.x) return;
		root.setExpanded(key, row.x === 1);
	}

	function select(key) {
		root.selected = key ?? "";
		root.detail = null;
		root.facts = null;
		if (root.connected) root.request("select", { key: root.selected });
	}

	// a window's app picked in the list (the taskbar, Alt+Tab, the launcher)
	function showWindow(windowId) {
		const entry = root.windowLoad[String(windowId)];
		root.tab = "apps";
		root.mode = "apps";
		root.filter = "";
		root.open();
		if (entry) root.select(entry[2]);
		else root.request("keyOfPid", { pid: Niri.windowMap[windowId]?.pid ?? 0 }, data => {
			if (data?.key) root.select(data.key);
		});
	}

	function showKey(key) {
		root.tab = "apps";
		root.filter = "";
		root.open();
		root.select(key);
	}

	// ── what a row is ──────────────────────────────────────────────────────
	function entryOf(appId) {
		return appId ? DesktopEntries.heuristicLookup(String(appId)) : null;
	}

	// the name a row shows: an app by its desktop entry
	function nameOf(row) {
		if (!row) return "";
		if (row.t === "group" && row.kind === "app") return root.entryOf(row.i)?.name || row.n;
		return row.n ?? "";
	}

	// an image for apps, a glyph for the rest: "glyph:<name>" or an image source
	function iconOf(row) {
		if (!row) return "glyph:application_outline";
		if (row.t === "section") return `glyph:${({ apps: "application_outline", vms: "monitor", pshell: "view_dashboard_outline", background: "cog_transfer_outline", system: "shield_account_outline", kernel: "chip" })[row.sec] ?? "folder_outline"}`;
		if (row.i && String(row.i).startsWith("glyph:")) return row.i;
		if (row.t === "group" && row.kind === "app") return AppIcons.forAppId(row.i);
		const guess = root.guessIcon(row.n);
		return guess !== "" ? guess : `glyph:${row.t === "group" ? "cog_outline" : "console"}`;
	}

	property var iconCache: ({})

	function guessIcon(name) {
		const key = String(name ?? "").toLowerCase().replace(/\.(py|sh|js)$/, "").split(/[ /]/)[0];
		if (key === "") return "";
		if (root.iconCache[key] !== undefined) return root.iconCache[key];
		const entry = DesktopEntries.applications.values.find(e => e.id.toLowerCase() === key || String(e.icon).toLowerCase() === key
			|| String(e.command?.[0] ?? "").split("/").pop().toLowerCase() === key);
		const icon = entry ? AppIcons.forEntry(entry) : "";
		root.iconCache[key] = icon;
		return icon;
	}

	function stateLabel(state) {
		return ({ R: "Running", S: "Sleeping", D: "Waiting for disk", T: "Paused", t: "Traced", Z: "Zombie", I: "Idle", X: "Dead" })[state] ?? state;
	}

	function percent(value, digits) {
		const v = Math.max(0, Number(value) || 0) * 100;
		if (v > 0 && v < 0.1) return "<0.1%";
		return `${v.toFixed(digits ?? 1)}%`;
	}

	// a share of the machine as a share of one core (the way top says it)
	function coresOf(value) {
		return (Number(value) || 0) * root.coreCount;
	}

	// ── doing things ───────────────────────────────────────────────────────
	// end | kill | pause | resume
	function act(key, action, admin, done) {
		if (!key) return;
		if (action === "end" || action === "kill") {
			root.ending = Object.assign({}, root.ending, { [key]: action });
			const lingered = Object.assign({}, root.lingering);
			delete lingered[key];
			root.lingering = lingered;
		}
		root.request("signal", { key: key, action: action, admin: !!admin }, (data, error) => {
			if (error || data?.needsAdmin) {
				const next = Object.assign({}, root.ending);
				delete next[key];
				root.ending = next;
			}
			if (data?.needsAdmin) {
				const row = root.rows[key];
				Notifs.pushInternal("error", `${root.nameOf(row) || "That"} belongs to ${row?.u ?? "another user"}`, "", {
					icon: "shield_lock_outline",
					actions: [{ label: "As administrator", icon: "shield_key_outline", run: () => root.act(key, action, true) }]
				});
			} else if (error) {
				Notifs.pushInternal("error", String(error), "", { icon: "alert_circle_outline" });
			} else if (action === "pause" || action === "resume") {
				root.markPaused(key, action === "pause");
				Sounds.play(action === "pause" ? "toggleOff" : "toggleOn");
			} else {
				Sounds.play("trash");
			}
			if (done) done(!error && !data?.needsAdmin);
		});
	}

	function end(key) { root.act(key, "end"); }
	function kill(key) { root.act(key, "kill"); }
	function pause(key) { root.act(key, "pause"); }
	function resume(key) { root.act(key, "resume"); }

	function isPaused(key) {
		const row = root.rows[key];
		if (row?.f && row.f.includes("paused")) return true;
		return root.pausedKeys.includes(key);
	}

	// keys paused from here (kept so the bar and parked windows know)
	property var pausedKeys: []

	function markPaused(key, on) {
		const has = root.pausedKeys.includes(key);
		if (on && !has) root.pausedKeys = root.pausedKeys.concat([key]);
		else if (!on && has) root.pausedKeys = root.pausedKeys.filter(k => k !== key);
	}

	// background | low | normal | high
	function setPriority(key, level, admin) {
		root.request("priority", { key: key, level: level, admin: !!admin }, (data, error) => {
			if (data?.needsAdmin) {
				Notifs.pushInternal("error", "A higher priority needs an administrator", "", {
					icon: "shield_lock_outline",
					actions: [{ label: "As administrator", icon: "shield_key_outline", run: () => root.setPriority(key, level, true) }]
				});
			} else if (error) {
				Notifs.pushInternal("error", String(error), "", { icon: "alert_circle_outline" });
			} else {
				root.facts = null;
				Sounds.play("select");
			}
		});
	}

	function setAffinity(key, cpus) {
		root.request("affinity", { key: key, cpus: cpus }, (data, error) => {
			if (error) Notifs.pushInternal("error", String(error), "", { icon: "alert_circle_outline" });
		});
	}

	// ── a process that is watched: a notification when it ends ────────────
	property var watched: ({})

	function setWatched(key, on) {
		root.request("watch", { key: key, on: on }, (data, error) => {
			if (error) return Notifs.pushInternal("error", String(error), "", { icon: "alert_circle_outline" });
			const next = Object.assign({}, root.watched);
			if (on) next[key] = { name: root.nameOf(root.rows[key]) || key, since: Date.now() };
			else delete next[key];
			root.watched = next;
			Sounds.play(on ? "toggleOn" : "toggleOff");
		});
	}

	// ── the windows behind it ──────────────────────────────────────────────
	function windowKey(windowId) {
		return root.windowLoad[String(windowId)]?.[2] ?? "";
	}

	function endWindow(windowId) {
		const key = root.windowKey(windowId);
		if (key !== "") root.end(key);
		else root.request("keyOfPid", { pid: Niri.windowMap[windowId]?.pid ?? 0 }, data => {
			if (data?.key) root.end(data.key);
		});
	}

	// the app of a window paused only when none of its windows is in sight
	function appWindows(key) {
		return Object.keys(root.windowLoad).filter(id => root.windowLoad[id][2] === key).map(Number);
	}

	function pauseWindow(windowId, onlyIf) {
		const key = root.windowKey(windowId);
		if (key === "" || key === "pshell") return false;
		if (onlyIf && !root.appWindows(key).every(id => onlyIf(id))) return false;
		root.act(key, "pause");
		return true;
	}

	function resumeWindow(windowId) {
		const key = root.windowKey(windowId);
		if (key !== "" && root.isPaused(key)) root.act(key, "resume");
	}

	// ── asking ─────────────────────────────────────────────────────────────
	property var lastPorts: []

	function ports(done, fresh) {
		root.request("ports", { fresh: !!fresh }, data => {
			root.lastPorts = data?.ports ?? [];
			if (done) done(root.lastPorts);
		});
	}

	// a key, a pid or a name from outside (IPC, the launcher)
	function resolve(what, done) {
		const text = String(what ?? "").trim();
		if (text === "") return;
		if (/^[a-z]+:/.test(text) || root.rows[text]) {
			done(text);
			return;
		}
		root.request("find", { name: text }, data => {
			const hit = (data?.found ?? [])[0];
			if (hit) done(hit.key);
		});
	}

	function actOn(what, action) {
		root.resolve(what, key => root.act(key, action));
	}

	function services(scope, done) {
		root.request("services", { scope: scope }, data => done(data?.services ?? []));
	}

	function serviceAction(scope, unit, action, done) {
		root.request("service", { scope: scope, unit: unit, action: action }, (data, error) => {
			if (error) Notifs.pushInternal("error", String(error), unit, { icon: "alert_circle_outline" });
			else Sounds.play("select");
			if (done) done(!error);
		});
	}

	function journal(scope, unit, after, done) {
		root.request("journal", { scope: scope, unit: unit, after: after || "" }, data => done(data ?? { entries: [], cursor: after }));
	}

	function autostart(done) {
		root.request("autostart", {}, data => done(data ?? { autostart: [], services: [] }));
	}

	function setAutostart(file, on, done) {
		root.request("setAutostart", { file: file, on: on }, (data, error) => {
			if (error) Notifs.pushInternal("error", String(error), "", { icon: "alert_circle_outline" });
			if (done) done(!error);
		});
	}

	function environ(pid, done) {
		root.request("environ", { pid: pid }, (data, error) => done(data?.environ ?? [], error));
	}

	function history(done) {
		root.request("history", {}, data => done(data ?? { history: [], tops: [] }));
	}

	function usage(day, done) {
		root.request("usage", { day: day || "" }, data => done(data ?? { usage: {}, days: [] }));
	}

	// ── replaced libraries ─────────────────────────────────────────────────
	property var oldLibs: []
	property bool oldLibsLoading: false

	function checkOldLibs(announce) {
		root.oldLibsLoading = true;
		root.request("oldlibs", {}, data => {
			root.oldLibsLoading = false;
			root.oldLibs = data?.apps ?? [];
			if (announce && root.oldLibs.length > 0) {
				const names = root.oldLibs.slice(0, 3).map(app => root.nameOf({ t: "group", kind: app.kind, i: app.icon, n: app.name })).join(", ");
				Notifs.pushInternal("done", root.oldLibs.length === 1 ? "One app still runs the old version" : `${root.oldLibs.length} apps still run the old version`, names, {
					icon: "restart",
					duration: 10000,
					actions: [{ label: "Show", icon: "format_list_bulleted", run: () => root.open("apps") }]
				});
			}
		});
	}

	// an app on the new libraries: ended, and started again when it has a desktop entry
	function restartApp(item) {
		if (item.kind === "svc" && item.unit) {
			root.serviceAction(item.key.startsWith("sys:") ? "system" : "user", item.unit, "restart", () => root.checkOldLibs(false));
			return;
		}
		const entry = item.kind === "app" ? root.entryOf(item.icon) : null;
		root.act(item.key, "end", false, ok => {
			if (!ok) return;
			if (entry) relaunch.start(entry);
			Qt.callLater(() => root.checkOldLibs(false));
		});
	}

	Timer {
		id: relaunch

		property var entry: null

		function start(target) {
			relaunch.entry = target;
			relaunch.restart();
		}

		interval: 1600
		onTriggered: relaunch.entry?.execute()
	}

	Connections {
		target: root.enabled && Plugins.on("updates") ? Updates : null

		function onRunningChanged() {
			if (!Updates.running && Updates.result === "ok") updated.restart();
		}
	}

	Timer {
		id: updated

		interval: 3000
		onTriggered: root.checkOldLibs(true)
	}

	// ── who holds a path (the file manager's "still in use") ───────────────
	function holders(path, done) {
		root.request("holders", { path: path }, data => done(data?.holders ?? []));
	}

	function explainBusy(path, name) {
		if (!root.enabled) return;
		root.holders(path, list => {
			if (list.length === 0) return;
			const keys = [...new Set(list.map(item => item.group || `p:${item.pid}`))];
			const names = [...new Set(list.map(item => item.groupName || item.name))];
			Notifs.pushInternal("error", `${name} is in use`, names.slice(0, 4).join(", "), {
				icon: "folder_lock_outline",
				duration: 12000,
				actions: [
					{ label: list.length === 1 ? "End it" : "End them", icon: "close_circle_outline", run: () => keys.forEach(key => root.end(key)) },
					{ label: "Show", icon: "format_list_bulleted", run: () => {
						root.filter = names[0] ?? "";
						root.open("apps");
					} }
				]
			});
		});
	}

	// ── the shell's leftovers ──────────────────────────────────────────────
	property int leftovers: 0

	function findLeftovers() {
		root.request("orphans", {}, data => root.leftovers = data?.pids?.length ?? 0);
	}

	function cleanLeftovers() {
		root.request("orphans", { clean: true }, data => {
			root.leftovers = 0;
			Notifs.pushInternal("done", "Leftovers ended", "", { icon: "broom" });
		});
	}

	// ── notifications ──────────────────────────────────────────────────────
	function announce(message) {
		const kind = String(message.kind);
		if (!root.alertOn(kind)) return;
		const key = String(message.key);
		const ignore = { label: "Not again", icon: "bell_off_outline", run: () => root.setSetting("ignore", (root.settings.ignore ?? []).concat([key])) };
		const show = { label: "Show", icon: "format_list_bulleted", run: () => root.showKey(key) };
		const name = root.nameOf({ t: "group", kind: message.kind === "leak" ? "app" : "", i: message.icon, n: message.name }) || message.name;
		switch (kind) {
		case "leak":
			Notifs.post({
				app: "Task Manager", icon: "memory", summary: `${name} keeps taking memory`,
				body: `${Format.bytes(message.from)} → ${Format.bytes(message.to)} in ${message.minutes} min`,
				actions: [{ text: "Restart", invoke: () => root.restartApp({ key: key, kind: message.kind === "leak" && key.startsWith("app:") ? "app" : "proc", icon: message.icon, unit: "" }) },
					{ text: "Show", invoke: show.run }, { text: "Not again", invoke: ignore.run }]
			});
			break;
		case "busy":
			Notifs.post({
				app: "Task Manager", icon: "cpu_64_bit", summary: `${name} is busy in the background`,
				body: `${Math.round(message.cores * 100)}% of a core for ${message.minutes} min`,
				actions: [{ text: "Pause", invoke: () => root.pause(key) }, { text: "End", invoke: () => root.end(key) }, { text: "Not again", invoke: ignore.run }]
			});
			break;
		case "heat":
			Notifs.post({
				app: "Task Manager", icon: "thermometer_alert", summary: `The processor is at ${Math.round(message.temp)} °C`,
				body: (message.top ?? []).map(item => `${root.nameOf({ t: "group", kind: item.kind, i: item.icon, n: item.name })} ${root.percent(item.c, 0)}`).join(" · "),
				urgency: 2,
				actions: [{ text: "Show", invoke: () => root.open("performance") }]
			});
			break;
		case "memory":
			Notifs.post({
				app: "Task Manager", icon: "memory", summary: "Memory is running out",
				body: `${Format.bytes(message.available)} free · ` + (message.top ?? []).map(item => `${root.nameOf({ t: "group", kind: item.kind, i: item.icon, n: item.name })} ${Format.bytes(item.m)}`).join(" · "),
				urgency: 2,
				actions: (message.top ?? []).slice(0, 1).map(item => ({ text: `End ${root.nameOf({ t: "group", kind: item.kind, i: item.icon, n: item.name })}`, invoke: () => root.end(item.key) }))
					.concat([{ text: "Show", invoke: () => root.open("apps") }])
			});
			break;
		case "oom":
			Notifs.post({
				app: "Task Manager", icon: "skull_outline", summary: `${message.name} was ended`,
				body: message.by === "kernel" ? "The memory had run out" : `${message.by}: ${message.why ?? "memory pressure"}`,
				urgency: 2
			});
			break;
		}
	}

	function finished(message) {
		const key = String(message.key);
		const next = Object.assign({}, root.watched);
		delete next[key];
		root.watched = next;
		const name = root.nameOf({ t: "group", kind: key.startsWith("app:") ? "app" : "", i: message.icon, n: message.name }) || message.name;
		Notifs.post({ app: "Task Manager", icon: "flag_checkered", summary: `${name} is done`, body: `After ${Format.duration(message.ran)}` });
	}

	// ── keep awake while something watched runs ────────────────────────────
	readonly property bool holdsAwake: root.enabled && root.settings.keepAwake !== false && Object.keys(root.watched).length > 0

	// ── game mode: background work paused while playing, on offer ──────────
	property var gamePaused: []

	Connections {
		target: root.enabled ? GameMode : null

		function onActiveChanged() {
			if (GameMode.active) gameStarted.restart();
			else root.gameEnded();
		}
	}

	Timer {
		id: gameStarted

		interval: 6000
		onTriggered: root.offerCalm()
	}

	function offerCalm() {
		if (!GameMode.active || root.settings.gameOffer === false) return;
		const game = new Set(Games.windows.map(w => root.windowKey(w.id)).filter(k => k !== ""));
		const heavy = root.top.filter(item => !game.has(item.key) && item.kind !== "app" && item.kind !== "pshell" && !item.key.startsWith("sys:") && root.coresOf(item.c) >= 0.15);
		if (heavy.length === 0) return;
		const names = heavy.map(item => item.name).slice(0, 3).join(", ");
		Notifs.pushInternal("running", "Background work while you play", `${names} · ${root.percent(heavy.reduce((s, item) => s + item.c, 0), 0)} of the processor`, {
			icon: "gamepad_variant",
			duration: 12000,
			actions: [{ label: "Pause while playing", icon: "pause", run: () => {
				root.gamePaused = heavy.map(item => item.key);
				heavy.forEach(item => root.pause(item.key));
			} }]
		});
	}

	function gameEnded() {
		if (root.gamePaused.length === 0) return;
		const keys = root.gamePaused;
		root.gamePaused = [];
		keys.forEach(key => root.resume(key));
		Notifs.pushInternal("done", "Background work goes on", "", { icon: "play" });
	}

	// ── a long load on a saving power profile: performance, on offer ───────
	property real loadedSince: 0
	property real offeredPowerAt: 0

	function checkPower() {
		if (!Plugins.on("power-profiles") || root.settings.powerOffer === false || PowerProfile.current === "performance" || !PowerProfile.profiles.includes("performance")) {
			root.loadedSince = 0;
			return;
		}
		if (root.cpu < 0.85) {
			root.loadedSince = 0;
			return;
		}
		const now = Date.now();
		if (root.loadedSince === 0) root.loadedSince = now;
		if (now - root.loadedSince < 120000 || now - root.offeredPowerAt < 3600000) return;
		root.offeredPowerAt = now;
		Notifs.pushInternal("running", "The processor has been at its limit for two minutes", PowerProfile.label(PowerProfile.current), {
			icon: "speedometer",
			duration: 10000,
			actions: [{ label: "Performance", icon: "speedometer", run: () => PowerProfile.set("performance") }]
		});
	}

	// ── agents: what a turn left running ───────────────────────────────────
	property var agentPorts: ({})

	function agentStarted(windowId) {
		if (!root.enabled || root.settings.agentPorts === false) return;
		const key = root.windowKey(windowId);
		if (key === "") return;
		root.request("portsOf", { key: key }, data => {
			const next = Object.assign({}, root.agentPorts);
			next[windowId] = (data?.ports ?? []).map(p => `${p.proto}:${p.port}`);
			root.agentPorts = next;
		});
	}

	function agentFinished(windowId, agent, topic) {
		if (!root.enabled || root.settings.agentPorts === false) return;
		const before = root.agentPorts[windowId];
		const key = root.windowKey(windowId);
		const next = Object.assign({}, root.agentPorts);
		delete next[windowId];
		root.agentPorts = next;
		if (!before || key === "") return;
		root.request("portsOf", { key: key }, data => {
			const fresh = (data?.ports ?? []).filter(p => p.proto === "tcp" && !before.includes(`${p.proto}:${p.port}`));
			if (fresh.length === 0) return;
			const first = fresh[0];
			Notifs.post({
				app: agent || "Agent", icon: "lan_connect",
				summary: fresh.length === 1 ? `:${first.port} still runs` : `${fresh.length} servers still run`,
				body: `${fresh.map(p => `${p.name} :${p.port}`).join(" · ")}${topic ? `\n${topic}` : ""}`,
				actions: [{ text: "Open", invoke: () => Qt.openUrlExternally(`http://localhost:${first.port}`) },
					{ text: "Stop", invoke: () => fresh.forEach(p => p.pids.forEach(pid => root.act(`p:${pid}`, "end"))) }]
			});
		});
	}

	// ── the windows the daemon matches processes to ────────────────────────
	function sendWindows() {
		if (!root.connected) return;
		root.request("windows", { windows: root.windowList() });
	}

	function windowList() {
		return Niri.windows.map(w => ({ id: Number(w.id), pid: Number(w.pid ?? 0), appId: String(w.app_id ?? ""), title: String(w.title ?? ""), workspace: Number(w.workspace_id ?? 0) }));
	}

	Timer {
		id: windowsSoon

		interval: 300
		onTriggered: root.sendWindows()
	}

	Connections {
		target: root.enabled ? Niri : null

		function onWindowsChanged() {
			windowsSoon.restart();
		}
	}

	// ── what comes in ──────────────────────────────────────────────────────
	function take(message) {
		const next = {};
		const previous = root.series;
		const span = root.span;
		const push = (name, value) => {
			const list = previous[name] ? previous[name].slice(previous[name].length >= span ? 1 : 0) : [];
			list.push(Number(value) || 0);
			next[name] = list;
		};
		push("cpu", message.cpu);
		(message.cores ?? []).forEach((value, i) => push(`core:${i}`, value));
		const memory = message.memory ?? {};
		push("memory", memory.total > 0 ? memory.used / memory.total : 0);
		push("swap", memory.swapTotal > 0 ? memory.swapUsed / memory.swapTotal : 0);
		for (const g of message.gpus ?? []) push(`gpu:${g.pci}`, g.busy ?? 0);
		push("gpu", (message.gpus ?? []).reduce((top, g) => Math.max(top, Number(g.busy) || 0), 0));
		for (const d of message.disks ?? []) {
			push(`disk:${d.name}:r`, d.read);
			push(`disk:${d.name}:w`, d.write);
		}
		push("disk", (message.disks ?? []).reduce((sum, d) => sum + d.read + d.write, 0));
		let down = 0, up = 0;
		for (const n of message.network ?? []) {
			push(`net:${n.name}:d`, n.down);
			push(`net:${n.name}:u`, n.upRate);
			if (n.kind !== "virtual") {
				down += n.down;
				up += n.upRate;
			}
		}
		push("net:d", down);
		push("net:u", up);
		push("temp", message.temps?.cpu ?? 0);
		push("watts", message.power?.watts ?? 0);
		push("pressure", Math.max(message.pressure?.cpu?.some ?? 0, message.pressure?.memory?.some ?? 0, message.pressure?.io?.some ?? 0));
		root.series = next;
		root.system = message;
		root.checkPower();
	}

	function receive(line) {
		let message;
		try {
			message = JSON.parse(line);
		} catch (error) {
			return;
		}
		if (message.event !== undefined) {
			switch (message.event) {
			case "system":
				root.take(message);
				break;
			case "rows": {
				const next = Object.assign({}, root.rows, message.set);
				for (const key of message.gone ?? []) delete next[key];
				root.rows = next;
				root.rowsRev += 1;
				break;
			}
			case "order":
				root.order = message.keys ?? [];
				break;
			case "detail":
				if (message.key !== root.selected) break;
				root.detail = message;
				if (message.facts !== undefined) root.facts = message.facts;
				break;
			case "alert":
				root.announce(message);
				break;
			case "finished":
				root.finished(message);
				break;
			case "lingering":
				root.lingering = Object.assign({}, root.lingering, { [message.key]: message.count });
				break;
			case "ended": {
				const next = Object.assign({}, root.ending);
				delete next[message.key];
				root.ending = next;
				const lingered = Object.assign({}, root.lingering);
				delete lingered[message.key];
				root.lingering = lingered;
				root.markPaused(message.key, false);
				if (root.selected === message.key) root.select("");
				break;
			}
			}
			return;
		}
		const done = root.callbacks[message.id];
		if (done) {
			delete root.callbacks[message.id];
			done(message.ok ? message.data : null, message.ok ? null : message.error);
		}
	}

	// ── talking to the daemon ──────────────────────────────────────────────
	property int counter: 0
	property var callbacks: ({})
	property var queued: []

	function request(op, args, done) {
		root.counter += 1;
		const id = root.counter;
		if (done) root.callbacks[id] = done;
		const message = Object.assign({ id: id, op: op }, args || {});
		if (!root.connected && op !== "hello") {
			if (root.enabled) {
				root.queued.push(message);
				root.wake();
			} else if (done) {
				delete root.callbacks[id];
				done(null, "The task manager is off");
			}
			return id;
		}
		root.socket?.write(JSON.stringify(message) + "\n");
		root.socket?.flush();
		return id;
	}

	function wake() {
		if (!root.enabled || root.connected) return;
		if (!retry.running) retry.start();
	}

	function hello() {
		const kinds = Object.keys(root.settings.alerts ?? {}).filter(kind => root.alertOn(kind));
		root.request("hello", {
			level: root.level, gpu: root.gpuWatchers > 0, alerts: kinds.length > 0, windows: root.windowList(), view: root.viewState(),
			ignore: (root.settings.ignore ?? []).concat(["leak", "busy", "heat", "memory", "oom"].filter(kind => !kinds.includes(kind)))
		}, (data, error) => {
			if (error || !data) return;
			root.connected = true;
			root.attempts = 0;
			root.info = data.info ?? {};
			// the graphs start with what the daemon kept
			const seeded = {};
			const recent = data.recent?.history ?? [];
			if (recent.length > 0) {
				seeded.cpu = recent.map(s => s[1]);
				seeded.memory = recent.map(s => s[2]);
				seeded.gpu = recent.map(s => s[3]);
				seeded.temp = recent.map(s => s[4]);
				seeded["net:d"] = recent.map(s => s[5]);
				seeded.disk = recent.map(s => s[6]);
				seeded.watts = recent.map(s => s[7]);
			}
			if (Object.keys(root.series).length === 0) root.series = seeded;
			if (data.system) root.take(data.system);
			const waiting = root.queued;
			root.queued = [];
			for (const message of waiting) root.socket?.write(JSON.stringify(message) + "\n");
			root.socket?.flush();
			if (root.level === "full" && root.selected !== "") root.request("select", { key: root.selected });
			if (root.pausedKeys.length > 0 && Number(data.paused ?? 0) === 0) root.pausedKeys = [];
		});
	}

	property var socket: null

	Component {
		id: socketMaker

		Socket {
			id: link

			path: root.socketPath
			parser: SplitParser {
				onRead: line => root.receive(line)
			}
			onConnectionStateChanged: {
				if (link !== root.socket) return;
				if (link.connected) {
					root.helloAt = Date.now();
					root.hello();
				} else {
					root.dropped();
				}
			}
			onError: if (link === root.socket) root.dropped()
		}
	}

	function dial() {
		if (root.socket) root.socket.destroy();
		root.socket = socketMaker.createObject(root, {});
		root.socket.connected = true;
	}

	function hangUp() {
		if (root.socket) root.socket.destroy();
		root.socket = null;
	}

	function dropped() {
		const was = root.connected;
		root.connected = false;
		root.helloAt = 0;
		if (was) {
			const queued = root.queued.map(message => String(message.id));
			const waiting = root.callbacks;
			root.callbacks = {};
			for (const id of Object.keys(waiting)) {
				if (queued.includes(id)) root.callbacks[id] = waiting[id];
				else waiting[id](null, "The task manager's daemon went away");
			}
		}
		if (root.needed) root.wake();
	}

	property int attempts: 0
	property real helloAt: 0

	Timer {
		id: retry

		interval: root.attempts < 12 ? 150 : 2000
		repeat: true
		onTriggered: {
			if (!root.enabled || root.connected) {
				retry.stop();
				return;
			}
			if (Date.now() - root.helloAt < 900) return;
			if (root.attempts % 15 === 1) Quickshell.execDetached(["python3", "-u", root.daemon]);
			root.attempts += 1;
			root.dial();
		}
	}

	onNeededChanged: {
		if (root.needed) {
			letGo.stop();
			root.wake();
		} else {
			letGo.restart();
		}
	}

	Timer {
		id: letGo

		interval: 5000
		onTriggered: {
			if (root.needed) return;
			retry.stop();
			root.hangUp();
			root.connected = false;
			root.system = null;
		}
	}

	// a daemon that was killed comes back
	Timer {
		running: root.needed
		repeat: true
		interval: 5000
		onTriggered: root.wake()
	}

	onEnabledChanged: {
		if (root.enabled) {
			root.attempts = 0;
			root.wake();
		} else {
			retry.stop();
			root.hangUp();
			root.connected = false;
			root.windowOpen = false;
			root.system = null;
		}
	}

	Component.onCompleted: if (root.needed) root.wake()

	// ── kept ───────────────────────────────────────────────────────────────
	property bool loaded: false

	function saveSettings() {
		if (!root.loaded) return;
		settingsFile.setText(JSON.stringify(Object.assign({}, root.settings, {
			windowed: root.windowed, tab: root.tab, mode: root.mode, tree: root.tree, sort: root.sort, desc: root.desc,
			kernel: root.showKernel, device: root.device
		}), null, 2) + "\n");
	}

	FileView {
		id: settingsFile

		path: Paths.stateFile("taskmgr.json")
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(String(text() || "{}"));
				root.settings = Object.assign({}, root.settings, data, { alerts: Object.assign({}, root.settings.alerts, data.alerts ?? {}), columns: Object.assign({}, root.settings.columns, data.columns ?? {}) });
				root.windowed = data.windowed === true;
				if (data.tab) root.tab = data.tab;
				if (data.mode) root.mode = data.mode;
				root.tree = data.tree === true;
				if (data.sort) root.sort = data.sort;
				if (data.desc !== undefined) root.desc = data.desc;
				root.showKernel = data.kernel === true;
				if (data.device) root.device = data.device;
			} catch (error) {}
			root.loaded = true;
		}
		onLoadFailed: root.loaded = true
	}
}
