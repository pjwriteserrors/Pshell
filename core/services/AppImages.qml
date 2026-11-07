pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// AppImages as apps (plugin "appimage", `appimage-default` makes it what
// AppImages open in): a window of its own (core/views/appimages/) that installs
// one – from a file or a download link – with a desktop entry, its icon and a
// command on the PATH, keeps them up to date and takes them off the system
// again with what they left. scripts/appimage/appimage.py does the work and
// never runs an AppImage to look into it.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("appimage")
	readonly property string script: `${Paths.scripts}/appimage/appimage.py`
	readonly property string windowTitle: "AppImages"

	// ── the window ─────────────────────────────────────────────────────────
	property bool windowOpen: false

	function open() {
		if (!root.enabled) return;
		root.windowOpen = true;
		root.reload();
		root.focusWindow();
	}

	function close() {
		root.windowOpen = false;
	}

	// Escape: the sheet first, then what removing asks, then the window
	function back() {
		if (root.candidate) {
			if (root.candidate.stage !== "installing") root.dismiss();
		} else if (root.removal) {
			root.cancelRemove();
		} else {
			root.close();
		}
	}

	function toggle() {
		if (root.windowOpen) root.close();
		else root.open();
	}

	function focusWindow() {
		focusTimer.restart();
	}

	Timer {
		id: focusTimer

		interval: 80
		onTriggered: {
			const window = Niri.windows.find(window => String(window.title) === root.windowTitle && /quickshell/i.test(String(window.app_id)));
			if (window && !window.is_focused) Niri.focusWindow(window.id);
		}
	}

	// ── what there is ──────────────────────────────────────────────────────
	// installed: [{ id, name, version, comment, file, program, mode, entry, icon, command, size,
	//   present, running, commandPresent, origin, update, checkedAt, checkError, installedAt, … }]
	property var installed: []
	// set up by another tool: [{ file, name, icon, entries, size, present, running, version }]
	property var foreign: []
	// lying in Downloads and the like: [{ file, name, icon, version, size, modified, folder }]
	property var loose: []
	property bool binOnPath: true
	property string store: ""
	property bool loading: false
	property bool loaded: false
	property string error: ""
	readonly property int updateCount: root.installed.filter(app => !!app.update).length
	readonly property real totalSize: root.installed.reduce((sum, app) => sum + (app.size || 0), 0)

	function reload() {
		if (lister.running) {
			root.reloadAgain = true;
			return;
		}
		root.loading = true;
		lister.running = true;
	}
	property bool reloadAgain: false

	Process {
		id: lister

		command: ["python3", root.script, "list"]
		stdout: StdioCollector {
			onStreamFinished: {
				try {
					const data = JSON.parse(String(text));
					root.installed = data.installed || [];
					root.foreign = data.foreign || [];
					root.loose = data.loose || [];
					root.binOnPath = data.binOnPath !== false;
					root.store = String(data.store || "");
					root.loaded = true;
				} catch (error) {
					root.error = "Could not read the AppImages";
				}
			}
		}
		onExited: {
			root.loading = false;
			if (root.reloadAgain) {
				root.reloadAgain = false;
				root.reload();
			}
		}
	}

	// ── installing ─────────────────────────────────────────────────────────
	// The one being installed: { stage: "fetching" | "inspecting" | "ready" | "installing" | "done" | "failed",
	//   path, url, look, origin, step, progress, done, total, speed, error, app,
	//   name, command, mode ("file" | "unpacked"), keep }
	property var candidate: null
	// asked while one is under way: paths and links
	property var waiting: []
	// whether the command name is free: { ok, reason, path, owner }
	property var commandCheck: ({ ok: true, reason: "", path: "" })
	readonly property var steps: [
		{ id: "download", label: "Download" },
		{ id: "check", label: "Check" },
		{ id: "copy", label: "Place the app" },
		{ id: "icon", label: "Icon" },
		{ id: "entry", label: "App entry" },
		{ id: "command", label: "Command" }
	]

	function plainPath(path) {
		let text = String(path || "").trim();
		if (text.startsWith("file://")) text = decodeURIComponent(text.slice(7));
		return text;
	}

	function isLink(text) {
		return /^https?:\/\//i.test(String(text || "").trim());
	}

	// a file or a link: looked into, then the window asks how it goes in
	function install(what) {
		if (!root.enabled) return;
		const text = String(what || "").trim();
		if (text === "") return;
		root.open();
		if (root.candidate && ["fetching", "inspecting", "installing"].includes(root.candidate.stage)) {
			root.waiting = root.waiting.concat([text]);
			return;
		}
		if (root.isLink(text)) {
			root.candidate = { stage: "fetching", url: text, path: "", look: null, origin: null, step: "resolve", progress: -1, done: 0, total: 0, speed: 0, error: "" };
			fetcher.command = ["python3", root.script, "fetch", text];
			fetcher.running = true;
		} else {
			const path = root.plainPath(text);
			root.candidate = { stage: "inspecting", url: "", path: path, look: null, origin: null, step: "", progress: 0, error: "" };
			inspector.command = ["python3", root.script, "inspect", path];
			inspector.running = true;
		}
		Sounds.play("open");
	}

	function pickFile() {
		Files.pick({ title: "Install an AppImage", folder: `${Paths.home}/Downloads`, filters: ["*.AppImage", "*.appimage"], acceptLabel: "Install" }, paths => {
			if (paths.length > 0) root.install(paths[0]);
		});
	}

	function change(fields) {
		if (!root.candidate) return;
		root.candidate = Object.assign({}, root.candidate, fields);
	}

	function ready(look, origin, path) {
		const already = root.installed.find(app => app.id === look.id);
		root.change({
			stage: "ready",
			look: look,
			origin: origin,
			path: path,
			name: already ? already.name : look.name,
			command: already && already.command ? already.command : look.command,
			mode: already ? (already.mode || "file") : "file",
			keep: !!origin ? false : !String(path).includes("/Downloads/"),
			already: already ?? null
		});
		root.checkCommand(root.candidate.command);
	}

	function checkCommand(name) {
		const text = String(name || "").trim();
		if (text === "") {
			root.commandCheck = { ok: true, reason: "none", path: "" };
			return;
		}
		commandChecker.running = false;
		commandChecker.command = ["python3", root.script, "check-command", text, root.candidate?.look?.id ?? ""];
		commandChecker.running = true;
	}

	function confirmInstall() {
		const c = root.candidate;
		if (!c || c.stage !== "ready") return;
		const command = ["python3", root.script, "install", c.path, "--name", String(c.name || c.look.name), "--mode", c.mode || "file"];
		if (String(c.command || "").trim() !== "") command.push("--command", String(c.command).trim());
		// a downloaded file is ours to move; a file of the user's stays where it was when asked
		if (c.keep && !c.origin) command.push("--keep");
		if (c.origin) command.push("--origin", JSON.stringify(c.origin));
		root.change({ stage: "installing", step: "check", progress: 0, error: "" });
		installer.command = command;
		installer.running = true;
	}

	function dismiss() {
		if (root.candidate && ["fetching", "inspecting", "installing"].includes(root.candidate.stage)) {
			if (root.candidate.stage === "installing") return;
			fetcher.running = false;
			inspector.running = false;
		}
		root.candidate = null;
		root.next();
	}

	function next() {
		if (root.waiting.length === 0) return;
		const first = root.waiting[0];
		root.waiting = root.waiting.slice(1);
		Qt.callLater(() => root.install(first));
	}

	function failed(text) {
		root.change({ stage: "failed", error: String(text || "That did not work") });
		Sounds.play("error");
	}

	// a line of the helper: a step, or how it ended
	function stepLine(line, done) {
		let data;
		try {
			data = JSON.parse(String(line));
		} catch (error) {
			return;
		}
		if (data.error) {
			root.failed(data.error);
			return;
		}
		if (data.step) {
			const fields = { step: data.step, progress: data.progress };
			if (data.total !== undefined) Object.assign(fields, { done: data.done || 0, total: data.total || 0, speed: data.speed || 0 });
			root.change(fields);
			return;
		}
		done(data);
	}

	Process {
		id: inspector

		stdout: StdioCollector {
			onStreamFinished: {
				let data;
				try {
					data = JSON.parse(String(text));
				} catch (error) {
					root.failed("Could not look into it");
					return;
				}
				if (data.error) root.failed(data.error);
				else root.ready(data, null, data.path);
			}
		}
	}

	Process {
		id: fetcher

		stdout: SplitParser {
			onRead: line => root.stepLine(line, data => {
				if (data.fetched) root.ready(data.look, data.origin, data.fetched);
			})
		}
	}

	Process {
		id: installer

		stdout: SplitParser {
			onRead: line => root.stepLine(line, data => {
				if (!data.done) return;
				root.change({ stage: "done", app: data.done, step: "command", progress: 1 });
				Sounds.play("confirm");
				root.reload();
			})
		}
		onExited: code => {
			if (code !== 0 && root.candidate?.stage === "installing") root.failed("The install stopped");
		}
	}

	Process {
		id: commandChecker

		stdout: StdioCollector {
			onStreamFinished: {
				try {
					root.commandCheck = JSON.parse(String(text));
				} catch (error) {}
			}
		}
	}

	// ── using one ──────────────────────────────────────────────────────────
	function launch(app) {
		if (!app) return;
		if (app.entry) Quickshell.execDetached(["gio", "launch", String(app.entry)]);
		else Quickshell.execDetached([String(app.program || app.file)]);
		Sounds.play("open");
	}

	function reveal(path) {
		if (Files.enabled) Files.reveal([String(path)]);
		else Quickshell.execDetached(["xdg-open", String(path).replace(/\/[^/]*$/, "")]);
	}

	function copyCommand(command) {
		Quickshell.execDetached(["wl-copy", String(command)]);
	}

	// ── removing ───────────────────────────────────────────────────────────
	// what removing one takes with it: { target, loading, items: [{ path, size, kind, fixed }], running, total }
	property var removal: null
	// target → true while it goes
	property var removing: ({})
	// "freed" toast: { name, freed }
	signal removed(string name, real freed)

	function askRemove(target) {
		if (root.removal?.target === target) {
			root.removal = null;
			return;
		}
		root.removal = { target: target, loading: true, items: [], running: [], total: 0 };
		leftoverProc.running = false;
		leftoverProc.command = ["python3", root.script, "leftovers", target];
		leftoverProc.running = true;
	}

	function cancelRemove() {
		root.removal = null;
	}

	function remove(target, data, stop, name) {
		const busy = Object.assign({}, root.removing);
		busy[target] = true;
		root.removing = busy;
		const proc = removeProc.createObject(root, { target: target, name: String(name || "") });
		proc.command = ["python3", root.script, "remove", target].concat(stop ? ["--stop"] : []).concat((data || []).flatMap(path => ["--data", String(path)]));
		proc.running = true;
		if (root.removal?.target === target) root.removal = null;
	}

	Process {
		id: leftoverProc

		stdout: StdioCollector {
			onStreamFinished: {
				try {
					const data = JSON.parse(String(text));
					if (!root.removal) return;
					if (data.error) root.removal = Object.assign({}, root.removal, { loading: false, error: data.error });
					else root.removal = Object.assign({ target: root.removal.target, loading: false }, data);
				} catch (error) {}
			}
		}
	}

	Component {
		id: removeProc

		Process {
			id: proc

			property string target: ""
			property string name: ""

			stdout: StdioCollector {
				onStreamFinished: {
					try {
						const data = JSON.parse(String(text));
						if (data.error) {
							Sounds.play("error");
							root.error = data.error;
						} else {
							root.removed(proc.name, data.freed || 0);
						}
					} catch (error) {}
				}
			}
			onExited: {
				const busy = Object.assign({}, root.removing);
				delete busy[proc.target];
				root.removing = busy;
				root.reload();
				proc.destroy();
			}
		}
	}

	// ── updates ────────────────────────────────────────────────────────────
	// id → { step, progress, done, total, speed, error }
	property var updating: ({})
	property var updateQueue: []
	property bool checking: false

	function check(id) {
		if (checker.running) return;
		root.checking = true;
		checker.command = ["python3", root.script, "check"].concat(id ? [String(id)] : []);
		checker.running = true;
	}

	function update(id) {
		if (root.updating[id]) return;
		root.setUpdating(id, { step: "download", progress: -1, done: 0, total: 0, speed: 0, error: "" });
		if (updater.running) {
			root.updateQueue = root.updateQueue.concat([id]);
			return;
		}
		root.runUpdate(id);
	}

	function updateAll() {
		for (const app of root.installed)
			if (app.update) root.update(app.id);
	}

	function runUpdate(id) {
		updater.target = id;
		updater.command = ["python3", root.script, "update", id];
		updater.running = true;
	}

	function setUpdating(id, value) {
		const next = Object.assign({}, root.updating);
		if (value) next[id] = Object.assign({}, next[id] ?? {}, value);
		else delete next[id];
		root.updating = next;
	}

	// where its updates come from: a link, or "" for what the image says
	function setOrigin(id, url) {
		originProc.command = ["python3", root.script, "origin", id, String(url || "")];
		originProc.running = true;
	}
	property string originError: ""

	Process {
		id: checker

		stdout: StdioCollector {
			onStreamFinished: {
				let data;
				try {
					data = JSON.parse(String(text));
				} catch (error) {
					return;
				}
				root.keep("lastCheck", Date.now());
				const fresh = (data.updates || []).filter(entry => !root.announced.includes(`${entry.id}@${entry.update?.version ?? ""}`));
				if (fresh.length > 0 && root.setting("notify", true)) root.announce(fresh);
			}
		}
		onExited: {
			root.checking = false;
			root.reload();
		}
	}

	Process {
		id: updater

		property string target: ""

		stdout: SplitParser {
			onRead: line => {
				let data;
				try {
					data = JSON.parse(String(line));
				} catch (error) {
					return;
				}
				if (data.error) {
					root.setUpdating(updater.target, { error: data.error, step: "failed" });
					Sounds.play("error");
				} else if (data.step) {
					const fields = { step: data.step, progress: data.progress };
					if (data.total !== undefined) Object.assign(fields, { done: data.done || 0, total: data.total || 0, speed: data.speed || 0 });
					root.setUpdating(updater.target, fields);
				} else if (data.done) {
					root.setUpdating(updater.target, null);
					Sounds.play("confirm");
					root.updated(data.done.name, data.done.version);
				}
			}
		}
		onExited: {
			const failed = root.updating[updater.target]?.step === "failed";
			if (!failed) root.setUpdating(updater.target, null);
			root.reload();
			if (root.updateQueue.length > 0) {
				const next = root.updateQueue[0];
				root.updateQueue = root.updateQueue.slice(1);
				root.runUpdate(next);
			}
		}
	}
	signal updated(string name, string version)

	Process {
		id: originProc

		stdout: StdioCollector {
			onStreamFinished: {
				try {
					const data = JSON.parse(String(text));
					root.originError = data.error ? String(data.error) : "";
					if (!data.error) root.check(data.id);
				} catch (error) {}
			}
		}
		onExited: root.reload()
	}

	// told once per version
	property var announced: []

	function announce(fresh) {
		root.announced = root.announced.concat(fresh.map(entry => `${entry.id}@${entry.update?.version ?? ""}`));
		const app = root.installed.find(each => each.id === fresh[0].id);
		Notifs.post({
			app: "AppImages",
			icon: app?.icon || `${Paths.assets}/icons/pshell-appimages.svg`,
			summary: fresh.length === 1 ? `${fresh[0].name} ${fresh[0].update?.version ?? ""} is out` : `${fresh.length} AppImages have updates`,
			body: fresh.length === 1 ? `You have ${fresh[0].version || "an older one"}.` : fresh.map(entry => `${entry.name} ${entry.update?.version ?? ""}`).join(", "),
			actions: [
				{ text: fresh.length === 1 ? "Update" : "Update all", invoke: () => fresh.forEach(entry => root.update(entry.id)) },
				{ text: "Show", invoke: () => root.open() }
			]
		});
	}

	// ── settings ───────────────────────────────────────────────────────────
	// autoCheck: look for updates by itself; everyHours; notify; lastCheck (ms)
	property var settings: ({ autoCheck: true, everyHours: 6, notify: true, lastCheck: 0 })

	function setting(name, fallback) {
		const value = root.settings[name];
		return value === undefined ? fallback : value;
	}

	function keep(name, value) {
		const next = Object.assign({}, root.settings);
		next[name] = value;
		root.settings = next;
		settingsFile.setText(JSON.stringify(next) + "\n");
	}

	FileView {
		id: settingsFile

		path: `${Paths.state}/appimages-settings.json`
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				root.settings = Object.assign({}, root.settings, JSON.parse(String(text() || "{}")));
			} catch (error) {}
		}
	}

	// looks every so often, a while after the start (not with it)
	Timer {
		running: root.enabled && root.setting("autoCheck", true)
		repeat: true
		interval: 10 * 60 * 1000
		triggeredOnStart: false
		onTriggered: root.checkIfDue()
	}

	Timer {
		running: root.enabled
		interval: 90 * 1000
		onTriggered: {
			root.reload();
			if (root.setting("autoCheck", true)) root.checkIfDue();
		}
	}

	function checkIfDue() {
		const every = Math.max(1, Number(root.setting("everyHours", 6))) * 3600 * 1000;
		if (Date.now() - Number(root.setting("lastCheck", 0)) >= every) root.check("");
	}

	// ── what AppImages open in (scripts/appimage/appimage.py claim) ────────
	readonly property bool isDefault: root.enabled && Plugins.on("appimage-default")
	property bool entryPlaced: false

	function applyDefault() {
		if (!root.enabled && !root.entryPlaced) return;
		defaultProc.command = ["python3", root.script, root.isDefault ? "claim" : (root.enabled ? "install-entry" : "unclaim")];
		defaultProc.running = true;
		root.entryPlaced = root.enabled;
	}

	onIsDefaultChanged: root.applyDefault()
	onEnabledChanged: root.applyDefault()
	Component.onCompleted: root.applyDefault()

	Process {
		id: defaultProc
	}

	// ── small things for the views ─────────────────────────────────────────
	function sizeText(bytes) {
		const value = Number(bytes) || 0;
		if (value >= 1e9) return `${(value / 1e9).toFixed(value >= 1e10 ? 0 : 1)} GB`;
		if (value >= 1e6) return `${Math.round(value / 1e6)} MB`;
		if (value >= 1e3) return `${Math.round(value / 1e3)} kB`;
		return `${value} B`;
	}

	function ago(seconds) {
		const s = Math.max(0, Date.now() / 1000 - Number(seconds || 0));
		if (s < 90) return "just now";
		if (s < 3600) return `${Math.round(s / 60)} min ago`;
		if (s < 86400) return `${Math.round(s / 3600)} h ago`;
		const days = Math.round(s / 86400);
		return days === 1 ? "yesterday" : `${days} days ago`;
	}

	function originText(origin) {
		if (!origin || !origin.kind) return "";
		if (origin.kind === "github") return `GitHub · ${origin.owner}/${origin.repo}`;
		if (origin.kind === "zsync") return "Its own update server";
		try {
			return String(origin.url).replace(/^https?:\/\//, "").split("/")[0];
		} catch (error) {
			return "A link";
		}
	}
}
