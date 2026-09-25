pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Pending Arch updates (repo via a private pacman database copy, AUR via yay).
// Checking happens in the background on a schedule; installing never happens
// on its own – it always opens a terminal so errors stay visible.
//
// Alongside the updates it keeps an eye on system maintenance:
//  - Arch news published since the last full system upgrade (fetched with the
//    update check, at most hourly unless asked for; read links persist)
//  - a reboot when the running kernel is no longer the installed one
//  - .pacnew / .pacsave files, orphaned packages and the package caches
// The local scan is cheap and runs at start, every 10 minutes, with each
// update check and after every update or maintenance task. Maintenance tasks
// run in a terminal exactly like updates (scripts/maintenance_run.sh).
Singleton {
	id: root

	readonly property string scripts: Paths.scripts
	readonly property string stateDir: `${Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"}/quickshell-updates`

	// [{ source: "repo"|"aur", name, current, next }]
	property var packages: []
	property bool checking: false
	property string error: ""
	property real lastCheck: 0

	// settings
	property bool autoCheck: true
	property int intervalHours: 6

	// a running update
	property string runId: ""
	property bool running: false
	property var runningNames: []
	property real progress: 0
	property string progressLabel: ""
	property string result: ""

	// Arch news: [{ date (ms), title, link }] and the links marked as read
	property var news: []
	property var newsRead: []
	property real lastNews: 0
	property bool fetchingNews: false
	// the last full system upgrade according to pacman.log (ms)
	property real lastUpgrade: 0
	readonly property real newsSince: root.lastUpgrade > 0 ? root.lastUpgrade : Date.now() - 14 * 86400000
	readonly property var unreadNews: root.news.filter(n => n.date > root.newsSince && !root.newsRead.includes(n.link))

	// maintenance scan
	property bool scanning: false
	property bool rescan: false
	property real lastScan: 0
	property string runningKernel: ""
	property string installedKernel: ""
	property bool rebootNeeded: false
	property var pacnew: []
	property var orphans: []
	property real pacmanCache: 0
	property real yayCache: 0
	property bool hasPacdiff: false
	property bool hasPaccache: false
	readonly property real cacheSize: root.pacmanCache + root.yayCache
	readonly property bool cacheLarge: root.cacheSize >= 2 * 1024 * 1024 * 1024
	// what the maintenance page flags: every config file, orphans, a big cache
	readonly property int attention: root.pacnew.length + (root.orphans.length > 0 ? 1 : 0) + (root.cacheLarge ? 1 : 0)

	// a running maintenance task: pacnew | orphans | cache | paccache
	property string task: ""
	readonly property bool busy: root.running || root.task !== ""
	// set when an update finished with the panel closed: toast after the rescan
	property string announce: ""

	readonly property string logPath: `${root.stateDir}/run-${root.runId}.log`
	readonly property string statusPath: `${root.stateDir}/run-${root.runId}.status`

	readonly property int count: root.packages.length
	readonly property int repoCount: root.packages.filter(p => p.source === "repo").length
	readonly property int aurCount: root.packages.filter(p => p.source === "aur").length

	// `manual` also refreshes the news even if they were fetched recently
	function check(manual) {
		root.scan();
		if (manual || Date.now() - root.lastNews > 3600000) root.fetchNews();
		if (root.checking) return;
		root.checking = true;
		root.error = "";
		checkProc.running = true;
	}

	function scan() {
		if (root.scanning) {
			root.rescan = true;
			return;
		}
		root.scanning = true;
		scanProc.running = true;
	}

	function fetchNews() {
		if (root.fetchingNews) return;
		root.fetchingNews = true;
		newsProc.running = true;
	}

	function markRead(link) {
		if (!link || root.newsRead.includes(link)) return;
		root.newsRead = root.newsRead.concat([String(link)]).slice(-60);
		root.persist();
	}

	function markAllRead() {
		root.newsRead = root.newsRead.concat(root.unreadNews.map(n => n.link)).slice(-60);
		root.persist();
	}

	function openNews(item) {
		if (!item?.link) return;
		Quickshell.execDetached(["xdg-open", item.link]);
		root.markRead(item.link);
	}

	function formatBytes(bytes) {
		const units = ["B", "KB", "MB", "GB", "TB"];
		let value = Number(bytes) || 0;
		let unit = 0;
		while (value >= 1024 && unit < units.length - 1) {
			value /= 1024;
			unit += 1;
		}
		return `${value >= 10 || unit === 0 ? Math.round(value) : value.toFixed(1)} ${units[unit]}`;
	}

	// pacnew | orphans | cache | paccache, in a terminal like the updates
	function runTask(name) {
		if (root.busy || !name) return;
		root.runId = String(Date.now());
		root.task = String(name);
		const titles = { pacnew: "Config files", orphans: "Orphans", cache: "Package cache", paccache: "Package cache" };
		terminal.environment = ({ QS_UPDATE_STATUS: root.statusPath });
		terminal.command = ["kitty", "--title", titles[name] || "Maintenance", "--class", "shell-update", "zsh", "-i", "-c", `'${root.scripts}/maintenance_run.sh' '${root.task}'`];
		terminal.running = true;
	}

	function finishTask(state) {
		root.task = "";
		Haptics.play(state === "ok" ? "taskDone" : "taskFailed");
		root.scan();
	}

	function updateAll() {
		root.start([]);
	}

	function updateOne(name) {
		if (name) root.start([String(name)]);
	}

	function updateSome(names) {
		const list = (names || []).map(String).filter(n => n !== "");
		if (list.length > 0) root.start(list);
	}

	function isRunning(name) {
		return root.running && root.runningNames.includes(name);
	}

	function start(names) {
		if (root.busy) return;
		// every run gets its own log and status file, so a finished run can
		// never be mistaken for the one that is just starting
		root.runId = String(Date.now());
		root.running = true;
		root.result = "";
		root.progress = 0;
		root.runningNames = names.slice();
		root.progressLabel = names.length === 1 ? `Updating ${names[0]}…` : (names.length > 1 ? `Updating ${names.length} packages…` : "Starting update…");
		tail.running = true;
		// the update runs in an interactive zsh so it looks and behaves like
		// a normal terminal session
		const script = `'${root.scripts}/updates_run.sh' ${names.map(n => `'${n}'`).join(" ")}`;
		terminal.environment = ({ QS_UPDATE_LOG: root.logPath, QS_UPDATE_STATUS: root.statusPath });
		terminal.command = ["kitty", "--title", "System update", "--class", "shell-update", "zsh", "-i", "-c", script];
		terminal.running = true;
	}

	function finish(state, code) {
		if (root.task !== "") {
			root.finishTask(state);
			return;
		}
		if (!root.running) return;
		const panelClosed = Popups.current !== "updates";
		tail.running = false;
		root.running = false;
		root.progress = state === "ok" ? 1 : root.progress;
		if (state === "ok") {
			root.result = "ok";
			root.progressLabel = "Update finished";
			root.packages = root.runningNames.length === 0 ? [] : root.packages.filter(p => !root.runningNames.includes(p.name));
			root.persist();
			Haptics.play("taskDone");
			if (panelClosed) root.announce = "ok";
			root.scan();
			recheck.restart();
		} else {
			root.result = "failed";
			root.progressLabel = code ? `Update failed (exit ${code})` : "Update failed";
			Haptics.play("taskFailed");
			if (panelClosed) Notifs.pushInternal("error", root.progressLabel, "", {
				icon: "package_variant",
				actions: [{ label: "Show", icon: "package_up", run: () => root.openPanel() }]
			});
		}
		root.runningNames = [];
		clearResult.restart();
	}

	function openPanel() {
		Popups.withFocusedScreen(screen => Popups.open("updates", screen));
	}

	function announceResult() {
		const actions = root.rebootNeeded ? [{ label: "Reboot", icon: "restart", run: () => Popups.withFocusedScreen(screen => Popups.openModal("power", screen)) }] : [];
		Notifs.pushInternal("done", "Update finished", root.rebootNeeded ? "Reboot required" : "", { icon: "shield_check", actions: actions, duration: root.rebootNeeded ? 12000 : 5000 });
	}

	function applyScan(text) {
		const pacnew = [];
		const orphans = [];
		const tools = [];
		for (const line of String(text).split("\n")) {
			const parts = line.split("\t");
			switch (parts[0]) {
			case "kernel":
				root.runningKernel = parts[1] || "";
				root.installedKernel = parts[2] || "";
				root.rebootNeeded = parts[3] === "1";
				break;
			case "upgrade":
				root.lastUpgrade = (Number(parts[1]) || 0) * 1000;
				break;
			case "pacnew":
				if (parts[1]) pacnew.push(parts[1]);
				break;
			case "orphan":
				if (parts[1]) orphans.push(parts[1]);
				break;
			case "cache":
				if (parts[1] === "pacman") root.pacmanCache = Number(parts[2]) || 0;
				else if (parts[1] === "yay") root.yayCache = Number(parts[2]) || 0;
				break;
			case "tool":
				tools.push(parts[1]);
				break;
			}
		}
		root.pacnew = pacnew;
		root.orphans = orphans;
		root.hasPacdiff = tools.includes("pacdiff");
		root.hasPaccache = tools.includes("paccache");
		root.lastScan = Date.now();
	}

	function clear() {
		if (root.running) return;
		root.result = "";
		root.progress = 0;
		root.progressLabel = "";
	}

	function parseProgress(line) {
		// terminal output: keep only what is left after the last carriage
		// return (progress bars redraw in place) and drop colour codes
		const raw = String(line);
		const tail = raw.slice(raw.lastIndexOf("\r") + 1);
		const clean = tail.replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "").replace(/\x1b\][^\x07]*\x07/g, "").trim();
		const step = clean.match(/^\(\s*(\d+)\/\s*(\d+)\)\s+(\S+)\s*(\S*)/);
		if (step) {
			const done = Number(step[1]);
			const total = Math.max(1, Number(step[2]));
			root.progress = Math.min(1, done / total);
			root.progressLabel = `${step[3]} ${step[4]} · ${done}/${total}`;
			return;
		}
		const phase = clean.match(/^::\s+(.+?)\.*$/);
		if (phase) root.progressLabel = phase[1];
	}

	function applySettings(data) {
		root.autoCheck = data.autoCheck !== false;
		root.intervalHours = Number(data.intervalHours) > 0 ? Number(data.intervalHours) : 6;
		root.lastCheck = Number(data.lastCheck) || 0;
		root.packages = Array.isArray(data.packages) ? data.packages : [];
		root.news = Array.isArray(data.news) ? data.news : [];
		root.newsRead = Array.isArray(data.newsRead) ? data.newsRead : [];
		root.lastNews = Number(data.lastNews) || 0;
	}

	function persist() {
		settings.setText(JSON.stringify({
			autoCheck: root.autoCheck,
			intervalHours: root.intervalHours,
			lastCheck: root.lastCheck,
			packages: root.packages,
			lastNews: root.lastNews,
			news: root.news,
			newsRead: root.newsRead
		}, null, 2));
	}

	function setAutoCheck(on) {
		root.autoCheck = !!on;
		root.persist();
	}

	function setInterval(hours) {
		root.intervalHours = Number(hours) || 6;
		root.persist();
	}

	function dueIn() {
		if (!root.autoCheck) return -1;
		const next = root.lastCheck + root.intervalHours * 3600000;
		return Math.max(0, next - Date.now());
	}

	Process {
		id: checkProc

		command: ["bash", `${root.scripts}/updates_check.sh`]
		stdout: StdioCollector {
			onStreamFinished: {
				const rows = [];
				for (const line of String(text).split("\n")) {
					const parts = line.split("\t");
					if (parts.length < 4) continue;
					rows.push({ source: parts[0], name: parts[1], current: parts[2], next: parts[3] });
				}
				rows.sort((a, b) => a.source === b.source ? a.name.localeCompare(b.name) : (a.source === "repo" ? -1 : 1));
				root.packages = rows;
				root.lastCheck = Date.now();
				root.persist();
			}
		}
		onExited: exitCode => {
			root.checking = false;
			if (exitCode !== 0) root.error = "Update check failed";
			scheduler.restart();
		}
	}

	Process {
		id: scanProc

		command: ["bash", `${root.scripts}/maintenance_check.sh`]
		stdout: StdioCollector {
			onStreamFinished: root.applyScan(text)
		}
		onExited: {
			root.scanning = false;
			if (root.announce !== "") {
				root.announce = "";
				root.announceResult();
			}
			if (root.rescan) {
				root.rescan = false;
				root.scan();
			}
		}
	}

	Process {
		id: newsProc

		command: ["bash", `${root.scripts}/updates_news.sh`]
		stdout: StdioCollector {
			onStreamFinished: {
				const items = [];
				for (const line of String(text).split("\n")) {
					const parts = line.split("\t");
					if (parts.length < 3 || !(Number(parts[0]) > 0)) continue;
					items.push({ date: Number(parts[0]), title: parts[1], link: parts[2] });
				}
				if (items.length === 0) return;
				root.news = items;
				root.lastNews = Date.now();
				// read marks of news that left the feed are dropped
				root.newsRead = root.newsRead.filter(link => items.some(n => n.link === link));
				root.persist();
			}
		}
		onExited: root.fetchingNews = false
	}

	Timer {
		running: true
		repeat: true
		interval: 600000
		onTriggered: root.scan()
	}

	Component.onCompleted: root.scan()

	Process {
		id: terminal

		onExited: {
			// the terminal may exit before the status file is flushed
			statusCheck.restart();
		}
	}

	// tails the update log to drive the progress bar
	Process {
		id: tail

		command: ["sh", "-c", `mkdir -p '${root.stateDir}'; find '${root.stateDir}' -name 'run-*' ! -name 'run-${root.runId}.*' -delete 2>/dev/null; : > '${root.logPath}'; tail -n +1 -F '${root.logPath}'`]
		stdout: SplitParser {
			onRead: data => root.parseProgress(data)
		}
	}

	FileView {
		id: statusFile

		path: root.busy ? root.statusPath : ""
		printErrors: false
		watchChanges: true
		onFileChanged: reload()
		onLoaded: {
			const parts = String(text()).trim().split("\t");
			if (parts[0] === "ok" || parts[0] === "failed") root.finish(parts[0], parts[1] || "");
		}
	}

	// the status file may be created after the watcher started, so it is
	// also polled while an update or a maintenance task runs
	Timer {
		running: root.busy
		repeat: true
		interval: 1000
		onTriggered: statusFile.reload()
	}

	// the terminal is gone: give the status file a moment, then give up
	Timer {
		id: statusCheck
		interval: 1200
		onTriggered: {
			statusFile.reload();
			lateCheck.restart();
		}
	}

	Timer {
		id: lateCheck
		interval: 900
		onTriggered: if (root.busy) root.finish("failed", "")
	}

	// the finished banner fades out on its own
	Timer {
		id: clearResult
		interval: 8000
		onTriggered: root.clear()
	}

	Timer {
		id: recheck
		interval: 2000
		onTriggered: root.check()
	}

	// checks on the configured schedule; also right after the shell started
	Timer {
		id: scheduler

		running: root.autoCheck
		repeat: false
		interval: Math.max(60000, root.dueIn() || 60000)
		onTriggered: {
			if (!root.autoCheck) return;
			if (root.dueIn() > 0) {
				restart();
				return;
			}
			root.check();
		}
	}

	FileView {
		id: settings

		path: Paths.stateFile("updates.json")
		printErrors: false
		onLoaded: {
			try {
				root.applySettings(JSON.parse(String(text() || "{}")));
			} catch (error) {
				root.applySettings({});
			}
			if (root.autoCheck && Date.now() - root.lastNews > root.intervalHours * 3600000) root.fetchNews();
			scheduler.restart();
		}
		onLoadFailed: scheduler.restart()
	}
}
