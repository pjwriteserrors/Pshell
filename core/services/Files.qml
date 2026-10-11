pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The file manager (plugin "filemanager"). Folders are read, pictured and
// changed by a daemon of its own (scripts/files/daemon.py) that lives apart
// from the shell: a copy goes on while the shell reloads, and other apps'
// "Show in folder" (org.freedesktop.FileManager1) reaches the shell through
// it. This service is the shell's end: requests, what the daemon tells
// (folders that changed, thumbnails, jobs, drives) and the actions every
// surface uses. What the user keeps (favourites, tags, collections, view
// settings) is FileLibrary.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("filemanager")
	// other apps' "Show in folder" and folders opened by xdg-open come here
	readonly property bool isDefault: root.enabled && Plugins.on("files-default")
	readonly property string daemon: `${Paths.scripts}/files/daemon.py`
	readonly property string socketPath: `${Paths.runtime}/files.sock`
	readonly property string home: Paths.home

	// the daemon answered the hello
	property bool connected: false
	property bool ownsDbus: false

	// ── the window ─────────────────────────────────────────────────────────
	property bool windowOpen: false
	// the window is up and has the keyboard
	property bool windowActive: false
	// asks the window to show places: { paths, kind: "folders" | "items" | "properties" | "search", newTab, query }
	signal showRequested(var request)

	function open(path) {
		if (!root.enabled) return;
		root.show({ paths: path ? [String(path)] : [], kind: "folders", newTab: false });
	}

	function openInTab(path) {
		root.show({ paths: [String(path)], kind: "folders", newTab: true });
	}

	// shows files picked in their folder
	function reveal(paths) {
		const list = (Array.isArray(paths) ? paths : [paths]).map(path => String(path)).filter(path => path !== "");
		if (list.length > 0) root.show({ paths: list, kind: "items", newTab: false });
	}

	function searchFor(query) {
		root.show({ paths: [], kind: "search", query: String(query || ""), newTab: false });
	}

	function show(request) {
		if (!root.enabled) return;
		root.windowOpen = true;
		root.showRequested(request);
		root.focusWindow();
	}

	function toggle() {
		if (root.windowOpen && root.windowActive) root.windowOpen = false;
		else root.show({ paths: [], kind: "folders", newTab: false });
	}

	function close() {
		root.windowOpen = false;
	}

	readonly property string windowTitle: "Files"

	// a window that is already up somewhere is brought here
	function focusWindow() {
		focusTimer.restart();
	}

	Timer {
		id: focusTimer

		interval: 60
		onTriggered: {
			const window = Niri.windows.find(window => String(window.title) === root.windowTitle && /quickshell/i.test(String(window.app_id)));
			if (window && !window.is_focused) Niri.focusWindow(window.id);
		}
	}

	// ── talking to the daemon ──────────────────────────────────────────────
	property int counter: 0
	property var callbacks: ({})

	function request(op, args, done) {
		root.counter += 1;
		const id = root.counter;
		if (done) root.callbacks[id] = done;
		const message = Object.assign({ id: id, op: op }, args || {});
		if (!root.connected && op !== "hello") {
			root.queued.push(message);
			root.wake();
			return id;
		}
		root.socket?.write(JSON.stringify(message) + "\n");
		root.socket?.flush();
		return id;
	}

	// what was asked before the daemon was there goes out once it is
	property var queued: []

	function wake() {
		if (!root.enabled || root.connected) return;
		if (!retry.running) retry.start();
	}

	function receive(line) {
		let message;
		try {
			message = JSON.parse(line);
		} catch (error) {
			return;
		}
		if (message.id !== undefined && message.id !== null) {
			const done = root.callbacks[message.id];
			delete root.callbacks[message.id];
			if (done) done(message.ok ? message.data : null, message.ok ? "" : String(message.error || "failed"));
			return;
		}
		switch (message.event) {
		case "changed":
			root.refreshPeek(String(message.path));
			root.folderChanged(String(message.path));
			break;
		case "thumb":
			root.thumbArrived(String(message.path), String(message.thumb || ""));
			break;
		case "peek":
			root.peekArrived(message);
			break;
		case "job":
			root.jobUpdated(message.job);
			break;
		case "attention":
			Sounds.play("attention");
			break;
		case "places":
			root.places = message.places || [];
			break;
		case "search":
			root.searchResults(String(message.search), message.entries || [], !!message.done, String(message.error || ""));
			break;
		case "du":
			root.sizes = Object.assign({}, root.sizes, { [message.path]: { size: message.size, files: message.files, folders: message.folders, done: !!message.done } });
			break;
		case "reveal":
			root.showRequested({ paths: message.paths || [], kind: String(message.kind || "folders"), newTab: false });
			root.windowOpen = true;
			root.focusWindow();
			break;
		}
	}

	signal folderChanged(string path)
	signal searchResults(string search, var entries, bool done, string error)

	function hello() {
		root.request("hello", { role: "shell", claim: root.isDefault }, (data, error) => {
			if (error) return;
			root.connected = true;
			root.ownsDbus = !!data.fm1;
			root.undoTitle = String(data.undo || "");
			const waiting = root.queued;
			root.queued = [];
			for (const message of waiting) root.socket?.write(JSON.stringify(message) + "\n");
			root.socket?.flush();
			root.syncWatches();
			root.knowVtKey();
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
		// what was asked of a daemon that went away never gets an answer; what
		// waits to be sent goes out to the next one
		if (was) {
			const queued = root.queued.map(message => String(message.id));
			const waiting = root.callbacks;
			root.callbacks = {};
			for (const id of Object.keys(waiting)) {
				if (queued.includes(id)) root.callbacks[id] = waiting[id];
				else waiting[id](null, "The file daemon went away");
			}
		}
		if (root.enabled) root.wake();
		if (was) root.jobs = Object.assign({}, root.jobs);
	}

	// The daemon is started when it does not answer; it stays while a shell
	// is connected and a minute longer.
	property int attempts: 0
	// when the last hello went out: its answer is waited for a moment
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
			// a hello on its way is waited for
			if (Date.now() - root.helloAt < 900) return;
			if (root.attempts % 15 === 1) Quickshell.execDetached(["python3", "-u", root.daemon]);
			root.attempts += 1;
			root.dial();
		}
	}

	// connected or not, a look now and then: a daemon that was killed comes back
	Timer {
		running: root.enabled
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
			root.applyDefault();
		}
	}

	onIsDefaultChanged: {
		if (root.connected) root.request("claim", { on: root.isDefault }, data => root.ownsDbus = !!data?.fm1);
		root.applyDefault();
	}

	Component.onCompleted: {
		if (root.enabled) root.wake();
	}

	// ── folders that are watched ───────────────────────────────────────────
	// what each pane shows: { owner: path }
	property var watches: ({})

	function watch(owner, path) {
		const next = Object.assign({}, root.watches);
		if (path && String(path).startsWith("/")) next[owner] = String(path);
		else delete next[owner];
		root.watches = next;
		watchSync.restart();
	}

	Timer {
		id: watchSync

		interval: 30
		onTriggered: root.syncWatches()
	}

	function syncWatches() {
		if (!root.connected) return;
		const paths = Array.from(new Set(Object.values(root.watches)));
		root.request("watch", { paths: paths });
	}

	// ── thumbnails and peeks ───────────────────────────────────────────────
	// path → thumbnail made since the folder was read; thumbTick says it changed
	property var thumbMap: ({})
	property int thumbTick: 0
	// path → { count, pictures } of a folder, { snippet } of a text file
	property var peekMap: ({})
	property int peekTick: 0
	property var wantedThumbs: []
	property var wantedPeeks: []
	property var askedThumbs: ({})
	property var askedPeeks: ({})

	function thumbOf(path) {
		return root.thumbMap[path] ?? "";
	}

	function peekOf(path) {
		return root.peekMap[path] ?? null;
	}

	// a card on the screen asks for its picture; asks are sent together
	function wantThumb(path, mime, size) {
		const key = `${path}|${size || "large"}`;
		if (root.askedThumbs[key]) return;
		root.askedThumbs[key] = true;
		root.wantedThumbs.push({ path: path, mime: mime, size: size || "large" });
		askTimer.restart();
	}

	function wantPeek(path, mime) {
		if (root.askedPeeks[path]) return;
		root.askedPeeks[path] = true;
		root.wantedPeeks.push({ path: path, mime: mime });
		askTimer.restart();
	}

	// a folder whose card is somewhere on the screen changed: its count is read again
	function refreshPeek(path) {
		const peek = root.peekMap[path];
		if (!peek || peek.count === undefined) return;
		delete root.askedPeeks[path];
		root.wantPeek(path, "inode/directory");
	}

	// a peek taken before the folder (or file) last changed is asked again;
	// the old one shows until the new one is in
	function checkPeek(path, mime, mtime) {
		const peek = root.peekMap[path];
		if (!peek) {
			root.wantPeek(path, mime);
			return;
		}
		const key = `${path}|${mtime}`;
		if (!mtime || peek.mtime === undefined || Math.abs(Number(peek.mtime) - Number(mtime)) < 0.01 || root.askedPeeks[key]) return;
		root.askedPeeks[key] = true;
		root.wantedPeeks.push({ path: path, mime: mime });
		askTimer.restart();
	}

	// a folder read again may have files that changed: their pictures are asked anew
	function forget(paths) {
		for (const path of paths) {
			delete root.askedPeeks[path];
			delete root.peekMap[path];
			delete root.askedThumbs[`${path}|large`];
			delete root.askedThumbs[`${path}|x-large`];
		}
	}

	Timer {
		id: askTimer

		interval: 24
		onTriggered: {
			const thumbs = root.wantedThumbs;
			root.wantedThumbs = [];
			const bySize = {};
			for (const item of thumbs) (bySize[item.size] = bySize[item.size] || []).push(item);
			for (const size of Object.keys(bySize)) root.request("thumbs", { items: bySize[size], size: size });
			const peeks = root.wantedPeeks;
			root.wantedPeeks = [];
			if (peeks.length > 0) root.request("peek", { items: peeks });
		}
	}

	function thumbArrived(path, thumb) {
		if (thumb === "") return;
		root.thumbMap[path] = thumb;
		tickTimer.thumbs = true;
		if (!tickTimer.running) tickTimer.start();
	}

	function peekArrived(message) {
		root.peekMap[String(message.path)] = message;
		tickTimer.peeks = true;
		if (!tickTimer.running) tickTimer.start();
	}

	// many pictures in a row change the cards once per frame or two
	Timer {
		id: tickTimer

		property bool thumbs: false
		property bool peeks: false
		interval: 40
		onTriggered: {
			if (tickTimer.thumbs) root.thumbTick += 1;
			if (tickTimer.peeks) root.peekTick += 1;
			tickTimer.thumbs = false;
			tickTimer.peeks = false;
		}
	}

	// ── jobs ───────────────────────────────────────────────────────────────
	// id → the daemon's job: { id, kind, title, state, bytes, bytesTotal, files, filesTotal, current, speed, eta, error, code, conflict, created, undoable }
	property var jobs: ({})
	readonly property var jobList: Object.values(root.jobs).sort((a, b) => Number(String(a.id).slice(1)) - Number(String(b.id).slice(1)))
	readonly property var activeJobs: root.jobList.filter(job => job.state === "preparing" || job.state === "running" || job.state === "conflict")
	readonly property var conflict: root.jobList.find(job => job.state === "conflict") ?? null
	readonly property bool busy: root.activeJobs.length > 0
	// the last thing undo would take back
	property string undoTitle: ""
	// job id → what to do once it is done: done(job)
	property var followUps: ({})
	signal jobFinished(var job)

	function startJob(kind, args, followUp) {
		root.request("job", Object.assign({ kind: kind }, args || {}), (data, error) => {
			if (error) {
				root.fail(error);
				return;
			}
			if (followUp) root.followUps[data.job] = followUp;
		});
	}

	function jobUpdated(job) {
		if (!job?.id) return;
		const before = root.jobs[job.id];
		const next = Object.assign({}, root.jobs);
		next[job.id] = job;
		root.jobs = next;
		const finished = ["done", "failed", "cancelled"].includes(job.state);
		if (!finished || (before && ["done", "failed", "cancelled"].includes(before.state))) return;
		if (job.undoable && job.kind !== "undo") root.undoTitle = job.title;
		else if (job.kind === "undo") root.request("undoable", {}, data => root.undoTitle = String(data?.title || ""));
		// tags, favourites and collections follow what was moved or renamed
		if (job.state === "done") for (const move of job.moves || []) FileLibrary.moved(move[0], move[1]);
		for (const folder of job.touched || []) root.refreshPeek(folder);
		const followUp = root.followUps[job.id];
		delete root.followUps[job.id];
		if (followUp) followUp(job);
		root.jobFinished(job);
		root.announce(job);
		// done jobs stay a moment in the tray, then go
		forgetTimer.restart();
	}

	function announce(job) {
		if (job.state === "failed") {
			if (job.code === "no-trash" || job.code === "exists" || job.code === "invalid") return; // the window asks or says
			Notifs.pushInternal("error", job.title || "File job failed", job.error, { icon: "folder_alert_outline" });
			return;
		}
		if (job.state !== "done") return;
		const long = Number(job.elapsed) > 1.5;
		if (job.kind === "trash") {
			Sounds.play("close");
			const count = Number(job.filesTotal) || 0;
			root.say(count === 1 ? "Moved to the trash" : `${count} items moved to the trash`, "trash_can_outline", true);
		}
		else if (long) Sounds.play("taskDone");
		else if (["copy", "move", "auto", "paste", "download"].includes(job.kind)) Sounds.play("copied");
		// away from the window, a longer job says it is through
		if (long && !root.windowActive && ["copy", "move", "auto", "paste", "download", "extract", "compress", "emptytrash", "delete", "convert", "pdf", "upload"].includes(job.kind)) {
			const created = job.created || [];
			Notifs.pushInternal("done", root.doneTitle(job), job.skipped > 0 ? `${job.skipped} skipped` : "", {
				icon: "folder_check_outline",
				actions: created.length > 0 ? [{ label: "Show", icon: "folder_open_outline", run: () => root.reveal(created) }] : []
			});
		}
	}

	function doneTitle(job) {
		const count = Number(job.filesTotal) || 0;
		switch (job.kind) {
		case "copy": return `Copied ${count === 1 ? "1 file" : `${count} files`}`;
		case "move": return "Moved";
		case "auto": return "Done";
		case "download": return "Downloaded";
		case "extract": return "Extracted";
		case "compress": return "Packed";
		case "convert": return "Converted";
		case "upload": return "Sent";
		case "avscan": return "Scanned";
		case "pdf": return "PDF ready";
		case "emptytrash": return "Trash emptied";
		case "delete": return "Deleted";
		default: return String(job.title || "Done");
		}
	}

	Timer {
		id: forgetTimer

		interval: 6000
		onTriggered: {
			const next = {};
			let left = false;
			for (const job of Object.values(root.jobs)) {
				const finished = ["done", "failed", "cancelled"].includes(job.state);
				if (!finished) next[job.id] = job;
				else left = true;
			}
			if (left) root.jobs = next;
		}
	}

	function resolve(choice, all, name) {
		const job = root.conflict;
		if (job) root.request("resolve", { job: job.id, choice: choice, all: !!all, name: name || "" });
	}

	function cancel(jobId) {
		root.request("cancel", { job: jobId });
	}

	function pause(jobId, on) {
		root.request("pause", { job: jobId, on: !!on });
	}

	function undo() {
		root.request("undo", {}, (data, error) => {
			if (error) root.say(error === "Nothing to undo" ? "Nothing to undo" : error, "undo");
		});
	}

	// ── what the window tells the user (above its content) ─────────────────
	signal said(string text, string icon, bool undo)
	// something the user has to agree to first: { title, detail, confirm, danger, run }
	signal confirmRequested(var question)

	// undo: the snackbar offers to take it back
	function say(text, icon, undo) {
		root.said(String(text), String(icon || "information_outline"), !!undo);
	}

	function fail(text) {
		Sounds.play("error");
		root.say(text, "alert_circle_outline");
	}

	// ── actions ────────────────────────────────────────────────────────────
	function launch(paths, app) {
		const files = paths.filter(path => String(path) !== "");
		if (files.length === 0) return;
		for (const path of files) FileLibrary.noteOpened(path);
		root.request("open", { paths: files, app: app || "" }, (data, error) => {
			if (error) root.fail(error);
		});
	}

	function setDefaultApp(path, app) {
		root.request("setdefault", { path: path, app: app }, (data, error) => {
			if (error) root.fail(error);
			else root.say("Opens with it from now on", "check");
		});
	}

	function trash(paths, asked) {
		if (paths.length === 0) return;
		if (FileLibrary.setting("confirmTrash") && !asked) {
			root.confirmRequested({
				title: paths.length === 1 ? `Move ${root.nameOf(paths[0])} to the trash?` : `Move ${paths.length} items to the trash?`,
				detail: "It can be taken out again from the trash.",
				confirm: "Move to the trash",
				danger: false,
				run: () => root.trash(paths, true)
			});
			return;
		}
		root.startJob("trash", { paths: paths }, job => {
			if (job.state !== "failed" || job.code !== "no-trash") return;
			const refused = job.failedPaths || [];
			root.confirmRequested({
				title: refused.length === 1 ? `Delete ${root.nameOf(refused[0])} for good?` : `Delete ${refused.length} items for good?`,
				detail: "This place has no trash, so this cannot be undone.",
				confirm: "Delete",
				danger: true,
				run: () => root.startJob("delete", { paths: refused })
			});
		});
	}

	function remove(paths) {
		if (paths.length === 0) return;
		root.confirmRequested({
			title: paths.length === 1 ? `Delete ${root.nameOf(paths[0])} for good?` : `Delete ${paths.length} items for good?`,
			detail: "They do not go to the trash. This cannot be undone.",
			confirm: "Delete",
			danger: true,
			run: () => root.startJob("delete", { paths: paths })
		});
	}

	// mode: "copy", "move" or "auto" (moved on the same drive, copied to another)
	function transfer(paths, target, mode, followUp) {
		const sources = paths.filter(path => String(path) !== "" && String(path) !== String(target));
		if (sources.length === 0 || !target) return;
		root.startJob(mode || "auto", { sources: sources, target: target }, followUp);
	}

	// the shell's own "cut": the next paste moves, as long as the clipboard
	// still holds these files
	property var cutPaths: []

	function clipboardSet(paths, cut) {
		if (paths.length === 0) return;
		const uris = paths.map(path => root.uri(path)).join("\n");
		Quickshell.execDetached(["sh", "-c", 'printf "%s" "$1" | wl-copy --type text/uri-list', "sh", uris]);
		root.cutPaths = cut ? paths.slice() : [];
		Sounds.play("copied");
		root.say(cut ? (paths.length === 1 ? "Cut – paste it somewhere" : `${paths.length} items cut`)
			: (paths.length === 1 ? "Copied" : `${paths.length} items copied`), cut ? "content_cut" : "content_copy");
	}

	function copyText(text, label) {
		Quickshell.execDetached(["wl-copy", "--", String(text)]);
		Sounds.play("copied");
		root.say(label, "content_copy");
	}

	function paste(target, followUp) {
		const cut = root.cutPaths.length > 0;
		root.startJob("paste", { target: target, cut: cut }, job => {
			if (cut && job.state === "done") root.cutPaths = [];
			if (followUp) followUp(job);
		});
	}

	function makeFolder(target, name, followUp) {
		root.startJob("mkdir", { target: target, name: name || "New folder" }, followUp);
	}

	function makeFile(target, name, content, followUp) {
		root.startJob("newfile", { target: target, name: name, content: content || "" }, followUp);
	}

	function rename(path, name, followUp) {
		root.startJob("rename", { path: path, name: name }, job => {
			if (job.state === "failed") root.fail(job.error);
			if (followUp) followUp(job);
		});
	}

	function renameMany(pairs, followUp) {
		root.startJob("batchrename", { pairs: pairs }, job => {
			if (job.state === "failed") root.fail(job.error);
			if (followUp) followUp(job);
		});
	}

	function duplicate(paths, followUp) {
		if (paths.length === 0) return;
		const folder = root.parentOf(paths[0]);
		root.startJob("copy", { sources: paths, target: folder }, followUp);
	}

	function compress(paths, followUp) {
		if (paths.length > 0) root.startJob("compress", { paths: paths }, followUp);
	}

	// a locked archive asks for its password (passwordAsked) and goes on with it
	function extract(path, target, followUp, password) {
		root.startJob("extract", { path: path, target: target || root.parentOf(path), password: password || "", trashArchive: !!FileLibrary.setting("trashArchive") }, job => {
			if (job.state === "failed" && job.code === "password") {
				root.passwordAsked(job.error, path, given => root.extract(path, target, followUp, given));
				return;
			}
			if (followUp) followUp(job);
		});
	}

	signal passwordAsked(string title, string path, var done)

	// ── Windows programs ───────────────────────────────────────────────────
	// [{ id, name, kind: proton | wine }] and whether Steam is there; asked once
	property var runners: []
	property bool steam: false
	property bool runnersKnown: false

	function knowRunners(done) {
		if (root.runnersKnown) {
			if (done) done();
			return;
		}
		root.request("runners", {}, data => {
			root.runners = data?.runners ?? [];
			root.steam = !!data?.steam;
			root.runnersKnown = true;
			if (done) done();
		});
	}

	// runner: "auto", "wine", "proton:<dir>"; auto follows the settings
	function runWindows(path, runner) {
		let chosen = runner || "auto";
		if (chosen === "auto") {
			const wanted = FileLibrary.setting("windowsRunner");
			const version = String(FileLibrary.setting("protonVersion") || "");
			chosen = wanted === "wine" ? "wine" : (wanted === "proton" && version !== "" ? version : (wanted === "proton" ? "proton" : "auto"));
		}
		FileLibrary.noteOpened(path);
		root.request("runwin", { path: path, runner: chosen }, (data, error) => {
			if (error) root.fail(error);
			else {
				Sounds.play("open");
				root.say(`Starting with ${data.runner}`, "microsoft_windows");
			}
		});
	}

	function addToSteam(path, name, tool, followUp) {
		root.startJob("steamadd", { path: path, name: name || "", tool: tool || "" }, job => {
			if (job.state === "done") {
				const steam = job.result?.steam;
				Sounds.play("taskDone");
				Notifs.pushInternal("done", `${steam?.name ?? "The game"} is in Steam`, steam?.restarted ? "Steam was restarted to take it in" : "It shows up in the library", {
					icon: "steam",
					actions: steam ? [{ label: "Open in Steam", icon: "play", run: () => Qt.openUrlExternally(`steam://rungameid/${steam.gameid}`) }] : []
				});
			}
			if (followUp) followUp(job);
		});
	}

	// ── VirusTotal ─────────────────────────────────────────────────────────
	property bool vtKeySet: false

	function knowVtKey() {
		root.request("vtkey", {}, data => root.vtKeySet = !!data?.set);
	}

	// upload: "ask" (unknown files are offered for upload), "yes", "never"
	function vtScan(paths, upload, quiet) {
		const files = paths.filter(path => String(path) !== "");
		if (files.length === 0) return;
		const mode = upload || (FileLibrary.setting("vtUpload") === "always" ? "yes" : "ask");
		root.startJob("vtscan", { paths: files, upload: mode }, job => {
			if (job.state === "failed" && job.code === "vtkey") {
				if (!quiet) root.settingsAsked("virus");
				return;
			}
			if (job.state !== "done") return;
			const scan = job.result?.scan ?? [];
			const bad = scan.filter(entry => entry.state === "malicious" || entry.state === "suspicious");
			if (quiet) {
				// a download checked on its own only speaks up when something is wrong
				if (bad.length > 0) Notifs.pushInternal("error", `${bad[0].name} looks dangerous`, `${bad[0].malicious + bad[0].suspicious} of ${bad[0].total} scanners flag it`, {
					icon: "shield_alert_outline",
					actions: [{ label: "Show", icon: "folder_open_outline", run: () => root.reveal([bad[0].path]) }]
				});
				return;
			}
			root.scanned(scan);
		});
	}

	signal scanned(var results)

	// ── the virus scan on this machine (ClamAV and YARA) ───────────────────
	// { clamav, yara, signatures, extras, rules, running, install }
	property var av: ({})

	function knowAv(done) {
		root.request("avstatus", {}, data => {
			root.av = data ?? {};
			if (done) done(root.av);
		});
	}

	// quiet: only a find is worth a word (a download checked on its own)
	function avScan(paths, quiet) {
		const items = paths.filter(path => String(path) !== "");
		if (items.length === 0) return;
		root.knowAv(av => {
			if (!av.clamav) {
				if (!quiet) root.settingsAsked("virus");
				return;
			}
			root.startJob("avscan", { paths: items, yara: FileLibrary.setting("avYara") !== false }, job => {
				if (job.state === "failed" && (job.code === "avmissing" || job.code === "avnosigs")) {
					if (!quiet) root.settingsAsked("virus");
					return;
				}
				if (job.state !== "done") return;
				const result = job.result?.localscan;
				if (!result) return;
				if (quiet) {
					const bad = result.flagged ?? [];
					if (bad.length > 0) Notifs.pushInternal("error", `${bad[0].name} looks dangerous`, bad[0].engines.map(hit => hit.result).slice(0, 2).join(", "), {
						icon: "shield_alert_outline",
						actions: [{ label: "Show", icon: "folder_open_outline", run: () => root.reveal([bad[0].path]) }]
					});
					return;
				}
				root.localScanned(result);
			});
		});
	}

	signal localScanned(var result)

	function avUpdate(done) {
		root.startJob("avupdate", {}, job => {
			root.knowAv();
			if (job.state === "done") root.say((job.result?.problems ?? []).length > 0 ? "Signatures updated, some extras failed" : "The signatures are up to date", "shield_check_outline");
			if (done) done(job);
		});
	}

	// ClamAV comes from the system's packages: a terminal asks for the password
	function installAv() {
		const command = String(root.av.install || "");
		if (command === "") {
			root.say("Install ClamAV with your package manager", "alert_circle_outline");
			return;
		}
		Quickshell.execDetached(["kitty", "--title", "Install ClamAV", "sh", "-c", `${command}; echo; echo 'Done – this window can close.'; read -r _`]);
	}
	// the window opens its settings (on a page)
	signal settingsAsked(string page)

	Connections {
		target: Downloads
		ignoreUnknownSignals: true

		function onFinished(item) {
			if (!root.enabled || !item?.path) return;
			if (FileLibrary.setting("avDownloads")) root.avScan([item.path], true);
			if (FileLibrary.setting("vtDownloads") && root.vtKeySet) root.vtScan([item.path], "never", true);
		}
	}

	// ── PDF tools ──────────────────────────────────────────────────────────
	// tool → what it lacks here ("LibreOffice"); asked once
	property var pdfMissing: ({})
	property var ocrLanguages: []

	function knowPdfTools() {
		root.request("pdftools", {}, data => {
			root.pdfMissing = data?.missing ?? {};
			root.ocrLanguages = data?.languages ?? [];
		});
	}

	function pdfTool(tool, paths, options, followUp) {
		root.startJob("pdf", { tool: tool, paths: paths, options: options || {} }, job => {
			if (job.state === "failed" && job.code === "password") {
				root.passwordAsked(job.error, paths[0], given => root.pdfTool(tool, paths, Object.assign({}, options, { password: given }), followUp));
				return;
			}
			if (job.state === "done" && job.result?.compare) root.compared(job.result.compare);
			if (job.state === "done" && (job.result?.saved ?? []).length > 0) {
				const before = job.result.saved.reduce((sum, pair) => sum + pair[0], 0);
				const after = job.result.saved.reduce((sum, pair) => sum + pair[1], 0);
				root.say(after < before ? `${Math.round((1 - after / before) * 100)} % smaller · ${root.sizeText(after)}` : "It was as small as it gets already", "zip_box_outline");
			}
			if (followUp) followUp(job);
		});
	}

	signal compared(var result)

	// ── to a server (the SSH plugin's logins, or any host ssh reaches) ──────
	function sendToServer(paths, server, name, dest) {
		root.startJob("upload", { paths: paths, server: server, name: name, dest: dest }, job => {
			if (job.state === "done") {
				Sounds.play("taskDone");
				root.say(`On ${name} in ${dest}`, "server_network");
			}
		});
	}

	// ── converting ─────────────────────────────────────────────────────────
	// what files can become: [{ format, label, kind }]
	function convertible(paths, done) {
		root.request("convertible", { paths: paths }, data => done(data?.targets ?? []));
	}

	function convert(paths, format, followUp) {
		root.startJob("convert", { paths: paths, format: format }, job => {
			if (job.state === "done" && job.error) root.say(job.error, "alert_circle_outline");
			if (followUp) followUp(job);
		});
	}

	function restore(entries) {
		const uris = entries.filter(entry => entry.uri && entry.orig).map(entry => [entry.uri, entry.orig]);
		if (uris.length > 0) root.startJob("restore", { uris: uris });
	}

	function emptyTrash() {
		root.confirmRequested({
			title: "Empty the trash?",
			detail: "Everything in it is deleted for good.",
			confirm: "Empty",
			danger: true,
			run: () => root.startJob("emptytrash", {})
		});
	}

	function download(url, target, followUp) {
		root.startJob("download", { url: url, target: target }, followUp);
	}

	// what another app (or another place of the shell) dropped on a folder
	function dropInto(target, drop, mode, followUp) {
		const files = [];
		const links = [];
		for (const url of drop.urls ?? []) {
			const value = String(url);
			if (value.startsWith("file://")) files.push(decodeURIComponent(value.slice(7)));
			else if (/^https?:/.test(value)) links.push(value);
		}
		if (files.length > 0) {
			root.transfer(files, target, mode || "auto", followUp);
			return true;
		}
		if (links.length > 0) {
			for (const url of links) root.download(url, target, followUp);
			return true;
		}
		if (drop.hasText && String(drop.text).trim() !== "") {
			const text = String(drop.text);
			if (/^https?:\/\/\S+$/.test(text.trim())) root.download(text.trim(), target, followUp);
			else root.makeFile(target, `Dropped text ${Qt.formatDateTime(new Date(), "yyyy-MM-dd HH.mm.ss")}.txt`, text, followUp);
			return true;
		}
		return false;
	}

	function terminal(folder) {
		Quickshell.execDetached(["kitty", "--directory", String(folder)]);
	}

	// a coding agent in a terminal, in that folder
	function agent(folder) {
		Quickshell.execDetached(["kitty", "--directory", String(folder), "claude"]);
	}

	// ── reading ────────────────────────────────────────────────────────────
	// path → { size, files, folders, done } of a folder whose size was asked
	property var sizes: ({})

	function measure(path) {
		root.request("du", { path: path });
	}

	function stopMeasuring() {
		root.request("stop", {});
	}

	// ── drives ─────────────────────────────────────────────────────────────
	// [{ id, name, path, uri, kind: system|drive|removable|phone|network, mounted, icon, canUnmount, canEject, total, free }]
	property var places: []
	readonly property var drives: root.places.filter(place => place.kind !== "network")
	readonly property var network: root.places.filter(place => place.kind === "network")

	function mount(place, password, done) {
		root.request("mount", { place: String(place), password: password || "" }, (data, error) => {
			if (error && error !== "password") root.fail(error);
			if (done) done(data?.path ?? "", error);
		});
	}

	function unmount(place, eject) {
		root.request("unmount", { place: String(place.uri || place.path), eject: !!eject }, (data, error) => {
			if (error) root.fail(error);
			else root.say(eject ? `${place.name} can be removed` : `${place.name} unmounted`, "eject");
		});
	}

	// an SSH host of the ssh plugin, through gvfs
	function hostUri(entry) {
		const user = String(entry.user || "");
		const host = String(entry.host || entry.target || "");
		const port = Number(entry.port || 0);
		return `sftp://${user ? encodeURIComponent(user) + "@" : ""}${host}${port && port !== 22 ? ":" + port : ""}/`;
	}

	// ── paths ──────────────────────────────────────────────────────────────
	function uri(path) {
		return "file://" + String(path).split("/").map(part => encodeURIComponent(part)).join("/");
	}

	function nameOf(path) {
		const value = String(path);
		if (value === "/") return "/";
		return value.replace(/\/+$/, "").split("/").pop();
	}

	function parentOf(path) {
		const value = String(path).replace(/\/+$/, "");
		const index = value.lastIndexOf("/");
		return index <= 0 ? "/" : value.slice(0, index);
	}

	function pretty(path) {
		const value = String(path);
		if (value === root.home) return "~";
		return value.startsWith(root.home + "/") ? "~" + value.slice(root.home.length) : value;
	}

	function sizeText(bytes) {
		const n = Number(bytes) || 0;
		if (FileLibrary.setting("sizeUnits") === "iec") {
			if (n < 1024) return `${n} B`;
			const units = ["KiB", "MiB", "GiB", "TiB"];
			let value = n / 1024;
			let unit = 0;
			while (value >= 1024 && unit < units.length - 1) {
				value /= 1024;
				unit += 1;
			}
			return `${value.toFixed(value < 10 ? 1 : 0)} ${units[unit]}`;
		}
		if (n < 1000) return `${n} B`;
		if (n < 1000 * 1000) return `${(n / 1000).toFixed(n < 10000 ? 1 : 0)} KB`;
		if (n < 1000 * 1000 * 1000) return `${(n / 1000 / 1000).toFixed(n < 1e7 ? 1 : 0)} MB`;
		if (n < 1e12) return `${(n / 1e9).toFixed(n < 1e10 ? 1 : 0)} GB`;
		return `${(n / 1e12).toFixed(1)} TB`;
	}

	// "Just now", "12 min ago", "Today 14:03", "Yesterday", "Mon", "3 Mar", "3 Mar 2024"
	function whenText(seconds) {
		const time = Number(seconds) * 1000;
		if (!time) return "";
		if (FileLibrary.setting("dateStyle") === "absolute") return Qt.formatDateTime(new Date(time), "dd.MM.yyyy HH:mm");
		const now = Date.now();
		const delta = (now - time) / 1000;
		const date = new Date(time);
		const today = new Date();
		today.setHours(0, 0, 0, 0);
		if (delta < 60 && delta > -60) return "Just now";
		if (delta < 3600 && delta > 0) return `${Math.floor(delta / 60)} min ago`;
		if (time >= today.getTime()) return `Today ${Qt.formatTime(date, "HH:mm")}`;
		if (time >= today.getTime() - 86400000) return `Yesterday ${Qt.formatTime(date, "HH:mm")}`;
		if (time >= today.getTime() - 6 * 86400000) return Qt.formatDate(date, "dddd");
		if (date.getFullYear() === today.getFullYear()) return Qt.formatDate(date, "d MMM");
		return Qt.formatDate(date, "d MMM yyyy");
	}

	// ── the desktop entry and the default file manager ─────────────────────
	// folders opened by xdg-open come here while files-default is on;
	// switched off, whatever was the default before is again
	readonly property string desktopId: "pshell-files.desktop"

	// the desktop entry "Pshell Files" is there while the plugin is on, so app
	// launchers offer the window too
	property bool entryInstalled: false

	function applyDefault() {
		if (!root.enabled && !root.entryInstalled) return;
		defaultProc.command = ["python3", `${Paths.scripts}/files/default.py`, !root.enabled ? "remove" : (root.isDefault ? "on" : "off")];
		defaultProc.running = true;
		root.entryInstalled = root.enabled;
	}

	Process {
		id: defaultProc
	}

	Timer {
		running: root.enabled
		interval: 4000
		onTriggered: root.applyDefault()
	}
}
