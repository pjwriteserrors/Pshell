pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.style.theme

// The NAS (docs/nas.md): the shell's end of `scripts/nas/nas.py daemon`,
// which keeps the connection to netcore, mounts it, runs the worker, the
// sync pairs and the backups. This service starts the daemon when it does
// not answer, talks JSON lines with it over `$PSHELL_RUNTIME_DIR/nas.sock`,
// keeps the State it reports and hands its notifications to Notifs. It
// also does the shell's own parts: the palette goes to the NAS when it
// changes, the worker pauses while a game runs (when asked), finished
// downloads and torrents go to the NAS, shelf items go to /Shelf and come
// from there, the watch progress of Streams is shared through kv `streams`.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("nas")
	readonly property string daemon: `${Paths.scripts}/nas/nas.py`
	readonly property string socketPath: `${Paths.runtime}/nas.sock`
	readonly property string adminFile: Paths.stateFile("nas-admin.txt")

	// the daemon answered
	property bool connected: false

	// ── what the daemon tells ──────────────────────────────────────────────
	// State (docs/nas.md): { configured, connected, via, address, server_id,
	// mounted, mount_path, disk, worker, tasks, sync, backup, uploads, health, pc_awake }
	property var status: ({})
	// the server's settings.json, read when something shows them (loadSettings)
	property var settings: ({})
	property bool settingsLoaded: false
	// nas.json, the PC side
	property var local: ({})
	// id → { id, kind, progress, text, done, error, at }
	property var jobs: ({})
	// pair id → { pair, state, conflicts }
	property var syncs: ({})
	// the last backup event: { set, state, … }
	property var backupEvent: ({})
	// the devices of the NAS (op devices, when the daemon has it)
	property var devices: []

	// ── what the views read ────────────────────────────────────────────────
	readonly property bool configured: !!root.status.configured
	readonly property bool online: root.connected && !!root.status.connected
	readonly property string via: String(root.status.via ?? "")
	readonly property string address: String(root.status.address ?? "")
	readonly property bool mounted: !!root.status.mounted
	readonly property string mountPath: root.expand(String(root.status.mount_path ?? root.local.mount_path ?? "~/NAS"))
	readonly property var disk: root.status.disk ?? ({})
	readonly property real total: Number(root.disk.total) || 0
	readonly property real free: Number(root.disk.free) || 0
	readonly property real used: Number(root.disk.used) || Math.max(0, root.total - root.free)
	readonly property real fill: root.total > 0 ? root.used / root.total : -1
	readonly property var worker: root.status.worker ?? ({})
	readonly property var current: root.worker.current ?? []
	readonly property var tasks: root.status.tasks ?? ({})
	readonly property int queued: Number(root.tasks.queued) || 0
	readonly property int running: Number(root.tasks.running) || 0
	readonly property var pairs: root.status.sync ?? []
	readonly property var backup: root.status.backup ?? ({})
	readonly property real backupLast: root.seconds(root.backup.last)
	readonly property bool backupOk: root.backup.ok !== false
	readonly property int uploads: Number(root.status.uploads) || 0
	readonly property var health: root.status.health ?? ({})
	readonly property var warnings: root.health.warnings ?? []
	// file jobs of the daemon (uploads, downloads) that still run
	readonly property var activeJobs: {
		const byId = {};
		for (const job of root.status.jobs ?? []) byId[job.id] = job;
		for (const job of Object.values(root.jobs)) byId[job.id] = job;
		return Object.values(byId).filter(job => !job.done);
	}
	readonly property real jobProgress: {
		const list = root.activeJobs.filter(job => job.progress >= 0);
		return list.length > 0 ? list.reduce((sum, job) => sum + Number(job.progress || 0), 0) / list.length : -1;
	}
	readonly property bool transferring: root.activeJobs.length > 0 || root.uploads > 0
	readonly property bool computing: root.current.length > 0
	readonly property int conflicts: root.pairs.reduce((sum, pair) => sum + (Array.isArray(pair.conflicts) ? pair.conflicts.length : Number(pair.conflicts) || 0), 0)
	// "Free 412 GB", "Not reachable", …
	readonly property string summary: {
		if (!root.enabled) return "";
		if (!root.connected) return "Starting…";
		if (!root.configured) return "Not set up";
		if (!root.online) return "Not reachable";
		return root.total > 0 ? `${Format.bytes(root.free)} free` : "Connected";
	}
	readonly property string viaText: root.via === "home" ? "At home" : (root.via === "vpn" ? "Over the VPN" : "")

	// local settings with the defaults the daemon uses (scripts/nas/config.py)
	function localOf(key, fallback) {
		const value = root.local[key];
		return value === undefined || value === null ? fallback : value;
	}
	readonly property bool pauseInGames: !!root.localOf("pause_in_games", false)
	readonly property bool shelfSync: Plugins.on("shelves") && !!root.localOf("shelf_sync", false)
	readonly property bool streamsSync: Plugins.on("streams") && !!root.localOf("streams_sync", false)
	readonly property bool downloadsToNas: Plugins.on("downloads") && !!root.localOf("downloads_to_nas", false)
	readonly property bool torrentsToNas: Plugins.on("torrents") && !!root.localOf("torrents_to_nas", false)
	readonly property string downloadsFolder: String(root.localOf("downloads_folder", "/Downloads"))

	signal stateArrived

	// ── helpers ────────────────────────────────────────────────────────────
	function expand(path) {
		return String(path).replace(/^~(?=\/|$)/, Paths.home);
	}

	// seconds since the epoch, whatever came (ms or s, an ISO date)
	function seconds(value) {
		if (value === undefined || value === null || value === "") return 0;
		const n = Number(value);
		if (!isNaN(n)) return n > 1e12 ? n / 1000 : n;
		const parsed = Date.parse(String(value));
		return isNaN(parsed) ? 0 : parsed / 1000;
	}

	// "just now", "5 min ago", "never"
	function ago(value) {
		const s = root.seconds(value);
		if (s <= 0) return "never";
		const text = Format.ago(s * 1000);
		return text === "now" ? "just now" : `${text} ago`;
	}

	// a NAS path under the mount, or "" while it is not mounted
	function localPath(nasPath) {
		if (!root.mounted) return "";
		const path = String(nasPath || "/");
		return root.mountPath + (path.startsWith("/") ? path : `/${path}`).replace(/\/$/, "");
	}

	// the NAS path of a file under the mount, or ""
	function nasPathOf(path) {
		const value = String(path).replace(/^file:\/\//, "");
		if (value === root.mountPath) return "/";
		return value.startsWith(root.mountPath + "/") ? value.slice(root.mountPath.length) : "";
	}

	function isUnderMount(path) {
		return root.nasPathOf(path) !== "";
	}

	function webUrl() {
		return root.address !== "" ? root.address : "http://192.168.178.22:8096";
	}

	// ── talking to the daemon ──────────────────────────────────────────────
	property int counter: 0
	property var callbacks: ({})
	// what was asked before the daemon was there goes out once it is
	property var queued_: []

	// done(data, error): error is "" or a text
	function call(op, args, done) {
		root.counter += 1;
		const id = root.counter;
		if (done) root.callbacks[id] = done;
		const message = Object.assign({}, args || {}, { id: id, op: String(op) });
		if (!root.connected && op !== "status") {
			root.queued_.push(message);
			root.wakeDaemon();
			return id;
		}
		root.socket?.write(JSON.stringify(message) + "\n");
		root.socket?.flush();
		return id;
	}

	function errorText(error) {
		if (!error) return "failed";
		if (typeof error === "string") return error;
		return String(error.message || error.error || error.code || "failed");
	}

	function receive(line) {
		let message;
		try {
			message = JSON.parse(line);
		} catch (error) {
			return;
		}
		if (message.event === undefined && message.id !== undefined && message.id !== null) {
			const done = root.callbacks[message.id];
			delete root.callbacks[message.id];
			if (done) done(message.ok ? (message.data ?? {}) : null, message.ok ? "" : root.errorText(message.error));
			return;
		}
		root.event(message);
	}

	function event(message) {
		switch (message.event) {
		case "state":
			root.takeState(message.state ?? message.data ?? message);
			break;
		case "notify":
			root.notify(message);
			break;
		case "job":
			root.takeJob(message.job ?? message);
			break;
		case "task": {
			const task = message.task ?? message;
			if (task.state === "failed") root.notify({ level: "error", title: `${task.label || task.type || "A task"} failed`, body: String(task.error || ""), key: `task-${task.id}` });
			break;
		}
		case "sync": {
			const next = Object.assign({}, root.syncs);
			next[String(message.pair)] = { pair: message.pair, state: message.state, conflicts: message.conflicts ?? [] };
			root.syncs = next;
			break;
		}
		case "backup":
			root.backupEvent = message;
			break;
		case "local":
			root.local = message.local ?? message.data ?? {};
			break;
		case "settings":
			root.settings = message.settings ?? message.data ?? {};
			root.settingsLoaded = true;
			break;
		case "changed":
			// the server's file events, when the daemon passes them on
			if ((message.paths ?? []).some(path => String(path).startsWith("/Shelf"))) shelfLook.restart();
			break;
		case "kv":
			if (message.ns === "streams") streamsPull.restart();
			if (message.ns === "shelf") shelfLook.restart();
			break;
		}
	}

	function takeState(state) {
		if (!state || typeof state !== "object") return;
		const was = root.online;
		root.status = state;
		root.stateArrived();
		if (!was && root.online) root.cameOnline();
	}

	function takeJob(job) {
		if (!job || job.id === undefined) return;
		const next = Object.assign({}, root.jobs);
		const before = next[job.id];
		next[job.id] = Object.assign({}, before ?? {}, job, { at: Date.now() });
		// finished ones go after a while
		for (const id of Object.keys(next))
			if (next[id].done && Date.now() - next[id].at > 60000) delete next[id];
		root.jobs = next;
		if (job.done && !before?.done && job.error) Notifs.pushInternal("error", "NAS", root.errorText(job.error), { icon: "server_network", app: "NAS" });
	}

	// the daemon's notifications, once per key while it stays the same
	property var told: ({})
	function notify(message) {
		const key = String(message.key || "");
		const text = `${message.title}|${message.body}`;
		if (key !== "" && root.told[key] === text) return;
		if (key !== "") root.told[key] = text;
		const level = String(message.level || "info");
		Notifs.post({
			app: "NAS",
			icon: "server_network",
			summary: String(message.title || "NAS"),
			body: String(message.body || ""),
			urgency: level === "error" ? 2 : 1,
			actions: [{ text: "Open", identifier: "default", invoke: () => root.openSettings() }]
		});
	}

	function hello() {
		root.call("status", {}, (data, error) => {
			if (error) return;
			root.connected = true;
			root.takeState(data);
			const waiting = root.queued_;
			root.queued_ = [];
			for (const message of waiting) root.socket?.write(JSON.stringify(message) + "\n");
			root.socket?.flush();
			root.loadLocal();
			root.pushTheme();
		});
	}

	// a socket that failed never connects again: every attempt gets a new one
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
			const queued = root.queued_.map(message => String(message.id));
			const waiting = root.callbacks;
			root.callbacks = {};
			for (const id of Object.keys(waiting)) {
				if (queued.includes(id)) root.callbacks[id] = waiting[id];
				else waiting[id](null, "The NAS daemon went away");
			}
		}
		if (root.enabled) root.wakeDaemon();
	}

	function wakeDaemon() {
		if (!root.enabled || root.connected) return;
		if (!retry.running) retry.start();
	}

	// The daemon is started when it does not answer; a second start exits by
	// itself when the socket answers (docs/nas.md).
	property int attempts: 0
	property real helloAt: 0

	Timer {
		id: retry

		interval: root.attempts < 12 ? 200 : 3000
		repeat: true
		onTriggered: {
			if (!root.enabled || root.connected) {
				retry.stop();
				return;
			}
			if (Date.now() - root.helloAt < 1500) return;
			// the service itself (it logs to ~/.cache/pshell/nas-daemon.log, leaves a while after the last client)
			if (root.attempts % 15 === 1) Quickshell.execDetached(["sh", "-c", 'exec python3 -u "$1" serve </dev/null >/dev/null 2>&1', "sh", root.daemon]);
			root.attempts += 1;
			root.dial();
		}
	}

	// connected or not, a look now and then: a daemon that was killed comes back
	Timer {
		running: root.enabled
		repeat: true
		interval: 5000
		onTriggered: root.wakeDaemon()
	}

	// the State as asked, in case an event was missed
	Timer {
		running: root.enabled && root.connected
		repeat: true
		interval: 60000
		onTriggered: root.call("status", {}, (data, error) => {
			if (!error) root.takeState(data);
		})
	}

	onEnabledChanged: {
		if (root.enabled) {
			root.attempts = 0;
			root.wakeDaemon();
		} else {
			retry.stop();
			root.hangUp();
			root.connected = false;
		}
	}
	Component.onCompleted: if (root.enabled) root.wakeDaemon()

	// ── settings ───────────────────────────────────────────────────────────
	function loadSettings(done) {
		root.call("settings", {}, (data, error) => {
			if (!error) {
				root.settings = data ?? {};
				root.settingsLoaded = true;
			}
			if (done) done(data, error);
		});
	}

	function loadLocal(done) {
		root.call("local", {}, (data, error) => {
			if (!error) root.local = data ?? {};
			if (done) done(data, error);
		});
	}

	// a server setting; `policy.thumb` style keys are kept flat as the server has them
	function set(key, value, done) {
		const before = root.settings[key];
		const next = Object.assign({}, root.settings);
		next[key] = value;
		root.settings = next;
		root.call("set", { key: key, value: value }, (data, error) => {
			if (error) {
				const back = Object.assign({}, root.settings);
				back[key] = before;
				root.settings = back;
				Notifs.pushInternal("error", "NAS setting not changed", error, { icon: "server_network", app: "NAS" });
			} else if (data && typeof data === "object" && Object.keys(data).length > 1) {
				root.settings = data;
			}
			if (done) done(data, error);
		});
	}

	function setting(key, fallback) {
		const value = root.settings[key];
		return value === undefined || value === null ? fallback : value;
	}

	function setLocal(key, value, done) {
		const next = Object.assign({}, root.local);
		next[key] = value;
		root.local = next;
		root.call("setlocal", { key: key, value: value }, (data, error) => {
			if (error) Notifs.pushInternal("error", "NAS setting not changed", error, { icon: "server_network", app: "NAS" });
			else if (data && typeof data === "object" && Object.keys(data).length > 1) root.local = data;
			if (done) done(data, error);
		});
	}

	// ── what the shell does with it ────────────────────────────────────────
	function report(error, doneText, icon) {
		if (error) Notifs.pushInternal("error", "NAS", error, { icon: "server_network", app: "NAS" });
		else if (doneText) Notifs.pushInternal("done", doneText, "NAS", { icon: icon || "server_network", app: "NAS" });
	}

	function pathsOf(list) {
		return (Array.isArray(list) ? list : [list]).map(path => String(path).replace(/^file:\/\//, "")).map(path => decodeURIComponent(path)).filter(path => path !== "");
	}

	// files of this PC to the NAS: `to` defaults to what the daemon chooses (/Shelf …)
	function send(paths, to, done) {
		const list = root.pathsOf(paths);
		if (list.length === 0) return;
		const args = { paths: list };
		if (to) args.to = String(to);
		root.call("send", args, (data, error) => {
			root.report(error, error ? "" : (list.length === 1 ? `Sending ${list[0].split("/").pop()} to the NAS` : `Sending ${list.length} items to the NAS`), "cloud_upload");
			if (done) done(data, error);
		});
	}

	// from a drop (urls) to the NAS
	function sendDrop(drop, to) {
		const paths = (drop?.urls ?? []).map(url => String(url)).filter(url => url.startsWith("file://"));
		if (paths.length > 0) root.send(paths, to);
		return paths.length;
	}

	function fetch(paths, to, done) {
		root.call("fetch", { paths: paths, to: String(to || `${Paths.home}/Downloads`) }, (data, error) => {
			root.report(error, error ? "" : "Downloading from the NAS", "download");
			if (done) done(data, error);
		});
	}

	function search(query, semantic, done) {
		root.call("search", { q: String(query), semantic: !!semantic }, (data, error) => done(error ? [] : (data?.entries ?? []), error));
	}

	function ls(path, done) {
		root.call("ls", { path: String(path || "/") }, (data, error) => done(error ? [] : (data?.entries ?? []), error));
	}

	// a NAS path opened on this PC: through the mount when it is there
	function open(nasPath) {
		const path = String(nasPath || "/");
		const here = root.localPath(path);
		if (here === "") {
			root.call("open", { path: path }, (data, error) => root.report(error, ""));
			return;
		}
		root.call("ls", { path: path }, (data, error) => {
			// a folder lists; a file does not (or lists only itself)
			const folder = !error && Array.isArray(data?.entries) && !(data.entries.length === 1 && data.entries[0].path === path && !data.entries[0].dir);
			if (folder && Plugins.on("filemanager")) Files.open(here);
			else if (folder) Quickshell.execDetached(["xdg-open", here]);
			else if (Plugins.on("filemanager")) Files.launch([here]);
			else Quickshell.execDetached(["xdg-open", here]);
		});
	}

	function reveal(nasPath) {
		const here = root.localPath(nasPath);
		if (here === "") return root.report("The NAS is not mounted", "");
		if (Plugins.on("filemanager")) Files.reveal([here]);
		else Quickshell.execDetached(["xdg-open", here.slice(0, here.lastIndexOf("/")) || "/"]);
	}

	function share(paths, kind, expires, password, done) {
		const args = { paths: paths, kind: kind || "download", expires: expires ?? 168 };
		if (password) args.password = password;
		root.call("share", args, (data, error) => {
			if (!error && data?.url) {
				Quickshell.execDetached(["wl-copy", "--", String(data.url)]);
				Notifs.pushInternal("done", "Link copied", String(data.url), { icon: "link_variant", app: "NAS" });
			} else {
				root.report(error, "");
			}
			if (done) done(data, error);
		});
	}

	// files under the mount go to the NAS's trash instead of the local one
	function trash(paths, done) {
		root.call("trash", { paths: root.pathsOf(paths) }, (data, error) => {
			root.report(error, "");
			if (done) done(data, error);
		});
	}

	function task(type, paths, options, done) {
		root.call("task", { type: type, paths: paths, options: options || {} }, (data, error) => {
			root.report(error, "");
			if (done) done(data, error);
		});
	}

	function syncNow(pair) {
		root.call("syncnow", pair ? { pair: pair } : {}, (data, error) => root.report(error, "Syncing with the NAS", "folder_sync_outline"));
	}

	function backupNow(set) {
		root.call("backupnow", set ? { set: set } : {}, (data, error) => root.report(error, "Backing up to the NAS", "backup_restore"));
	}

	function saves(action, game, done) {
		const args = { action: action };
		if (game) args.game = game;
		root.call("saves", args, (data, error) => {
			if (action !== "list") root.report(error, action === "restore" ? "Restoring game saves" : "Backing up game saves", "content_save_cog_outline");
			if (done) done(data, error);
		});
	}

	function versions(path, done) {
		root.call("versions", { path: String(path) }, (data, error) => done(error ? [] : (data?.versions ?? []), error));
	}

	function restore(path, id, mode, done) {
		root.call("restore", { path: path, version: id, mode: mode || "beside" }, (data, error) => {
			root.report(error, "Restoring from the NAS", "restore");
			if (done) done(data, error);
		});
	}

	function mount(on) {
		root.call(on ? "mount" : "unmount", {}, (data, error) => root.report(error, ""));
	}

	function wake(device) {
		root.call("wake", { device: String(device) }, (data, error) => root.report(error, `Waking ${device}`, "power"));
	}

	// a token for the laptop or the phone: done({ id, token, server_id, addresses })
	function mint(name, kind, done) {
		root.call("mint", { name: String(name), kind: String(kind) }, (data, error) => {
			root.report(error, "");
			if (done) done(data, error);
		});
	}

	// any call of the server's API the ops miss (op `api`)
	function api(method, path, body, done) {
		const args = { method: method, path: path };
		if (body !== undefined && body !== null) args.body = body;
		root.call("api", args, done);
	}

	function loadDevices(done) {
		root.api("GET", "/api/devices", null, (data, error) => {
			if (!error) root.devices = Array.isArray(data) ? data : (data?.devices ?? []);
			if (done) done(root.devices, error);
		});
	}

	function openWeb() {
		Quickshell.execDetached(["xdg-open", root.webUrl()]);
	}

	function openSettings() {
		NiriSettings.page = "nas";
		Popups.withFocusedScreen(screen => Popups.openModal("niri", screen));
	}

	// the admin password the setup keeps (mode 600); done(text) with "" when there is none
	function readAdmin(done) {
		const reader = adminReader.createObject(root, { done: done });
		reader.running = true;
	}

	Component {
		id: adminReader

		Process {
			id: proc

			property var done: null
			command: ["cat", root.adminFile]
			stdout: StdioCollector {
				onStreamFinished: if (proc.done) proc.done(String(text).trim())
			}
			onExited: proc.destroy()
		}
	}

	// ── the palette goes to the NAS ────────────────────────────────────────
	function pushTheme() {
		if (root.enabled && root.connected && root.online) themePush.restart();
	}

	Timer {
		id: themePush

		interval: 4000
		onTriggered: root.call("theme", {})
	}

	Connections {
		target: Theme

		function onWalChanged() {
			root.pushTheme();
		}
	}

	function cameOnline() {
		root.pushTheme();
		if (root.shelfSync) shelfLook.restart();
		if (root.streamsSync) streamsPull.restart();
	}

	// ── the worker rests while a game runs (when asked) ────────────────────
	property bool pausedForGame: false
	readonly property bool gameNow: root.enabled && root.pauseInGames && GameMode.active

	onGameNowChanged: {
		if (!root.connected) return;
		if (root.gameNow && !root.localOf("worker_paused", false)) {
			root.pausedForGame = true;
			root.setLocal("worker_paused", true);
		} else if (!root.gameNow && root.pausedForGame) {
			root.pausedForGame = false;
			root.setLocal("worker_paused", false);
		}
	}

	// ── finished downloads and torrents go to the NAS ──────────────────────
	Connections {
		target: Downloads
		enabled: root.enabled && root.downloadsToNas

		function onFinished(item) {
			if (item?.state === "done" && item.path) root.send([item.path], root.downloadsFolder);
		}
	}

	Connections {
		target: Torrents
		enabled: root.enabled && root.torrentsToNas

		function onFinishedOne(torrent) {
			const where = String(torrent?.destination || "");
			const name = String(torrent?.name || "");
			if (where && name) root.send([`${where.replace(/\/$/, "")}/${name}`], String(root.localOf("torrents_folder", root.downloadsFolder)));
		}
	}

	// ── shelf sync: what lands on a shelf goes to /Shelf, what others put there shows up
	// names already in /Shelf, so only new ones come to the shelves
	property var shelfKnown: null
	property var shelfSent: ({})

	function shelfAdded(paths) {
		if (!root.enabled || !root.shelfSync || !root.online) return;
		const fresh = paths.filter(path => !root.isUnderMount(path) && !String(path).startsWith(Paths.stateFile("shelf")));
		if (fresh.length === 0) return;
		for (const path of fresh) root.shelfSent[String(path).split("/").pop()] = true;
		root.call("send", { paths: fresh, to: "/Shelf" }, (data, error) => {
			if (error) root.report(error, "");
		});
	}

	Timer {
		id: shelfLook

		interval: 1500
		onTriggered: root.lookAtShelf()
	}

	Timer {
		running: root.enabled && root.shelfSync && root.online
		repeat: true
		interval: 90000
		onTriggered: root.lookAtShelf()
	}

	function lookAtShelf() {
		if (!root.shelfSync || !root.online) return;
		root.ls("/Shelf", (entries, error) => {
			if (error) return;
			const names = entries.map(entry => String(entry.name || String(entry.path).split("/").pop())).filter(name => name !== "" && !name.startsWith("."));
			if (root.shelfKnown === null) {
				root.shelfKnown = names;
				return;
			}
			const fresh = names.filter(name => !root.shelfKnown.includes(name) && !root.shelfSent[name]);
			root.shelfKnown = names;
			if (fresh.length === 0 || !root.mounted) return;
			const items = fresh.map(name => ({ kind: "file", path: `${root.mountPath}/Shelf/${name}` }));
			const target = Shelf.shelves[Shelf.shelves.length - 1];
			if (target) Shelf.addItems(target.id, items);
			else Shelf.create(items, "NAS");
		});
	}

	onShelfSyncChanged: {
		if (!root.shelfSync) root.shelfKnown = null;
		else if (root.online) shelfLook.restart();
	}
	onStreamsSyncChanged: if (root.streamsSync && root.online) streamsPull.restart()

	// ── watch progress of Streams in kv `streams`, key `progress`:
	// { <video id>: { position, duration, watched, at, by } }
	property var streamsTold: ({})

	Connections {
		target: Streams
		enabled: root.enabled && root.streamsSync

		function onPlayingChanged() {
			const playing = Streams.playing;
			if (!playing?.id) return;
			const told = root.streamsTold[playing.id] ?? 0;
			const watched = playing.duration > 0 && playing.position / playing.duration >= 0.9;
			root.streamsPending[playing.id] = { position: Math.floor(playing.position || 0), duration: Math.floor(playing.duration || 0), watched: watched, at: Math.floor(Date.now() / 1000), by: Host.hostname };
			if (watched || Date.now() - told > 30000) {
				root.streamsTold[playing.id] = Date.now();
				streamsPush.restart();
			}
		}
	}

	property var streamsPending: ({})

	Timer {
		id: streamsPush

		interval: 2000
		onTriggered: {
			const pending = root.streamsPending;
			root.streamsPending = {};
			if (Object.keys(pending).length === 0 || !root.online) return;
			root.call("kvget", { ns: "streams", key: "progress" }, (data, error) => {
				const known = (!error && data && typeof data === "object") ? (data.value ?? data) : {};
				const merged = Object.assign({}, known, pending);
				root.call("kvset", { ns: "streams", key: "progress", value: merged });
			});
		}
	}

	Timer {
		id: streamsPull

		interval: 3000
		onTriggered: root.pullStreams()
	}

	Timer {
		running: root.enabled && root.streamsSync && root.online
		repeat: true
		interval: 15 * 60000
		onTriggered: root.pullStreams()
	}

	// what was watched elsewhere is marked watched here; a half-watched
	// position needs an op of the streams daemon that does not exist yet
	function pullStreams() {
		if (!root.streamsSync || !root.online) return;
		root.call("kvget", { ns: "streams", key: "progress" }, (data, error) => {
			if (error || !data) return;
			const known = data.value ?? data;
			for (const id of Object.keys(known)) {
				const entry = known[id];
				if (!entry?.watched || entry.by === Host.hostname || root.streamsTold[`in-${id}`]) continue;
				root.streamsTold[`in-${id}`] = true;
				Streams.call("mark", { video: id, watched: true, upTo: "" });
			}
		});
	}
}
