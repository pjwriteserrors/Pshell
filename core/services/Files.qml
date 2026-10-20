pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.style.theme

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

	// a file shown in its folder, quick look open on it
	function look(path) {
		root.show({ paths: [String(path)], kind: "look", newTab: false });
	}

	// any place of the window: { kind: "storage" | "duplicates" | "search" | …, path, … }
	function goTo(location) {
		root.show({ paths: [], kind: "place", location: location, newTab: false });
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
		case "index":
			root.index = Object.assign({}, root.index, message.state || {});
			if (!message.state?.running) root.knowIndex();
			break;
		case "rules":
			root.rules = message.rules || [];
			root.knowRules();
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
			root.knowIndex();
			root.knowAv();
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

	// ── long jobs: awake, a word when through, a shutdown after ────────────
	readonly property var heavyKinds: ["copy", "move", "auto", "paste", "download", "extract", "compress", "emptytrash", "delete", "convert", "pdf", "upload", "avscan", "avupdate", "vtscan", "dupes", "storage", "share", "sync", "trim", "gif", "aipull", "image"]
	readonly property bool longJobs: root.activeJobs.some(job => root.heavyKinds.includes(job.kind) && Number(job.elapsed) > 8)
	// the machine does not sleep while one runs
	readonly property bool awake: root.longJobs && FileLibrary.setting("keepAwake") !== false
	property bool shutdownAfter: false

	Process {
		running: root.awake
		command: ["systemd-inhibit", "--what=sleep:idle", "--who=Pshell Files", "--why=A file job is running", "--mode=block", "sleep", "infinity"]
	}

	onBusyChanged: {
		if (root.busy || !root.shutdownAfter) return;
		root.shutdownAfter = false;
		shutdownTimer.left = 30;
		shutdownTimer.start();
		root.shutdownToast = Notifs.pushInternal("running", "Shutting down in 30 seconds", "The file jobs are through", {
			icon: "power",
			duration: 30000,
			actions: [{ label: "Cancel", icon: "close", run: () => shutdownTimer.stop() }]
		});
	}

	property int shutdownToast: 0

	Timer {
		id: shutdownTimer

		property int left: 30
		interval: 1000
		repeat: true
		onTriggered: {
			shutdownTimer.left -= 1;
			if (shutdownTimer.left > 0) return;
			shutdownTimer.stop();
			Session.run("shutdown");
		}
	}

	// the keyboard breathes when a long job ends while you are elsewhere
	function pulse(ok) {
		if (FileLibrary.setting("ledPulse") === false || !Lighting.enabled || Lighting.modeOf("keyboard") === "live") return;
		Quickshell.execDetached(["python3", `${Paths.scripts}/files/ledpulse.py`, String(ok ? Theme.success : Theme.danger)]);
	}

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
		root.checkTagged();
		const followUp = root.followUps[job.id];
		delete root.followUps[job.id];
		if (followUp) followUp(job);
		root.jobFinished(job);
		root.announce(job);
		// done jobs stay a moment in the tray, then go
		forgetTimer.restart();
	}

	// a tag counts the files that are still there: what went to the trash
	// keeps its tags for when it comes back
	function checkTagged() {
		const paths = Object.keys(FileLibrary.tagged).slice(0, 2000);
		if (paths.length === 0) {
			FileLibrary.missing = ({});
			return;
		}
		root.request("describe", { paths: paths }, data => {
			const there = new Set((data?.entries ?? []).map(entry => entry.path));
			const missing = {};
			for (const path of paths) if (!there.has(path)) missing[path] = true;
			FileLibrary.missing = missing;
		});
	}

	onWindowOpenChanged: if (root.windowOpen) root.checkTagged()

	Connections {
		target: FileLibrary

		function onTaggedChanged() {
			if (root.windowOpen) root.checkTagged();
		}
	}

	function announce(job) {
		if (job.state === "failed") {
			if (job.code === "no-trash" || job.code === "exists" || job.code === "invalid") return; // the window asks or says
			if (Number(job.elapsed) > 20 && !root.windowActive) root.pulse(false);
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
		if (Number(job.elapsed) > 20 && !root.windowActive) root.pulse(true);
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
		// a file of a folder with a workspace of its own opens there
		const workspace = FileLibrary.workspaceOf(root.parentOf(files[0]));
		if (workspace >= 0) Quickshell.execDetached(["niri", "msg", "action", "focus-workspace", String(workspace)]);
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

	// ── the Windows VM (vm-launcher) ───────────────────────────────────────
	// { vm, known, state, folder, shared, watcher, suggested }
	property var vmShare: ({})
	readonly property string vmName: String(Machines.vms[0]?.name ?? "win11")

	function knowVm(done) {
		if (!Plugins.on("vm-launcher")) return;
		root.request("vmshare", { vm: root.vmName }, data => {
			root.vmShare = data ?? {};
			if (done) done(root.vmShare);
		});
	}

	// the folder the VM shares with the PC; the VM must be off for it
	function setupVmShare(folder) {
		root.request("vmshare", { vm: root.vmName, action: "setup", folder: folder || "" }, (data, error) => {
			if (error) {
				root.fail(error);
				return;
			}
			root.vmShare = data ?? {};
			Sounds.play("taskDone");
			root.say(`${root.vmName} shares ${root.pretty(root.vmShare.folder)}`, "folder_network_outline");
		});
	}

	// a Windows program into the shared folder, asked to open there; the VM is started when it is off
	function openInVm(path) {
		root.request("vmshare", { vm: root.vmName, action: "open", path: path }, (data, error) => {
			if (error) {
				if (/no shared folder/.test(error)) root.settingsAsked("windows");
				root.fail(error);
				return;
			}
			FileLibrary.noteOpened(path);
			if (data.state !== "running") {
				// the VM's own window shows it coming up (storage, start, display)
				Machines.refresh();
				Popups.withFocusedScreen(screen => Popups.openModal("vm", screen));
				vmLaunch.restart();
			}
			root.say(data.state === "running" ? `${root.nameOf(path)} opens in Windows` : `Starting ${root.vmName} – it opens once Windows is up`, "microsoft_windows");
		});
	}

	Timer {
		id: vmLaunch

		interval: 900
		onTriggered: Machines.launch(root.vmName)
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
		Quickshell.execDetached(Terminal.command({ title: "Install ClamAV" }, ["sh", "-c", `${command}; echo; echo 'Done – this window can close.'; read -r _`]));
	}
	// the window opens its settings (on a page)
	signal settingsAsked(string page)

	Connections {
		target: Downloads
		ignoreUnknownSignals: true

		function onFinished(item) {
			if (!root.enabled || !item?.path) return;
			if (FileLibrary.setting("downloadToast") !== false) root.downloadToast(String(item.path));
			if (FileLibrary.setting("avDownloads")) root.avScan([item.path], true);
			if (FileLibrary.setting("vtDownloads") && root.vtKeySet) root.vtScan([item.path], "never", true);
		}
	}

	// a download that is through: what can be done with it, right in the toast
	function downloadToast(path) {
		const name = root.nameOf(path);
		const archive = /\.(zip|tar|tgz|gz|xz|zst|bz2|7z|rar)$/i.test(name) && !/\.(deb|rpm|apk|jar)$/i.test(name);
		const actions = [
			{ label: "Open", icon: "open_in_app", run: () => root.launch([path]) },
			{ label: "Show", icon: "folder_open_outline", run: () => root.reveal([path]) }
		];
		if (archive) actions.push({ label: "Extract", icon: "package_variant", run: () => root.extract(path, root.parentOf(path)) });
		if (!FileLibrary.setting("avDownloads") && (root.av.clamav || root.vtKeySet)) actions.push({ label: "Scan", icon: "shield_search", run: () => root.av.clamav ? root.avScan([path]) : root.vtScan([path]) });
		Notifs.pushInternal("done", name, `Downloaded to ${root.pretty(root.parentOf(path))}`, {
			icon: archive ? "package_variant_closed" : "download",
			image: /\.(png|jpe?g|webp|gif)$/i.test(name) ? path : "",
			duration: 9000,
			actions: actions
		});
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
				root.say(after < before ? `${Math.round((1 - after / before) * 100)} % smaller · ${Format.bytes(after)}` : "It was as small as it gets already", "zip_box_outline");
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

	// ── what can be taken back ─────────────────────────────────────────────
	// [{ title, at, kind, count }], newest first
	function history(done) {
		root.request("history", {}, data => done(data?.entries ?? []));
	}

	function undoAt(at) {
		root.request("undo", { at: at }, (data, error) => {
			if (error) root.say(error, "undo");
		});
	}

	// ── copies of the same file ────────────────────────────────────────────
	// folder → { groups, at } of the last look for copies
	property var dupeResults: ({})
	property var dupeRunning: ({})

	function findDupes(path, options, done) {
		root.dupeRunning = Object.assign({}, root.dupeRunning, { [path]: true });
		root.startJob("dupes", { paths: [path], options: options || { pictures: true } }, job => {
			const next = Object.assign({}, root.dupeRunning);
			delete next[path];
			root.dupeRunning = next;
			if (job.state === "done") root.dupeResults = Object.assign({}, root.dupeResults, { [path]: { groups: job.result?.dupes?.groups ?? [], at: Date.now() } });
			if (done) done(job);
		});
	}

	// ── what takes the space ───────────────────────────────────────────────
	property var storageRunning: ({})
	property var storageScanned: ({})

	function measureStorage(path, done) {
		root.storageRunning = Object.assign({}, root.storageRunning, { [path]: true });
		root.startJob("storage", { path: path }, job => {
			const next = Object.assign({}, root.storageRunning);
			delete next[path];
			root.storageRunning = next;
			if (job.state === "done") root.storageScanned = Object.assign({}, root.storageScanned, { [path]: Date.now() });
			if (done) done(job);
		});
	}

	function storageTree(rootPath, path, done) {
		root.request("storagetree", { root: rootPath, path: path, depth: 2 }, data => done(data?.tree ?? null));
	}

	// ── rules ──────────────────────────────────────────────────────────────
	// [{ id, name, enabled, folder, subfolders, when, match: {…}, action: {…}, lastRun, count }]
	property var rules: []
	property var ruleTexts: ({})

	function knowRules() {
		root.request("rules", {}, data => {
			root.rules = data?.rules ?? [];
			root.ruleTexts = data?.described ?? {};
		});
	}

	function setRules(list) {
		root.request("rules", { rules: list }, data => {
			root.rules = data?.rules ?? [];
			root.ruleTexts = data?.described ?? {};
		});
	}

	function saveRule(rule) {
		const list = root.rules.filter(each => each.id !== rule.id);
		const at = root.rules.findIndex(each => each.id === rule.id);
		list.splice(at >= 0 ? at : list.length, 0, rule);
		root.setRules(list);
	}

	function removeRule(id) {
		root.setRules(root.rules.filter(rule => rule.id !== id));
	}

	function runRule(id) {
		root.request("rulerun", { rule: id }, (data, error) => {
			if (error) root.fail(error);
			else if (!data.count) root.say("Nothing there fits the rule", "playlist_check");
		});
	}

	// ── music (an mpv of the file manager) ─────────────────────────────────
	// { playing, title, path, paused, position, duration, index, count, mpris }
	property var music: ({ playing: false })

	function play(paths, append) {
		root.request("play", { paths: paths, append: !!append }, (data, error) => {
			if (error) {
				root.fail(error);
				return;
			}
			if (append && root.music.playing) root.say(paths.length === 1 ? "In the queue" : `${paths.length} in the queue`, "playlist_plus");
			musicTimer.restart();
		});
	}

	function musicDo(action) {
		root.request("player", { action: action }, data => {
			root.music = data ?? { playing: false };
			musicTimer.restart();
		});
	}

	// while it plays, what plays is asked every second
	Timer {
		id: musicTimer

		interval: 1000
		repeat: true
		triggeredOnStart: true
		onTriggered: root.request("player", {}, data => {
			root.music = data ?? { playing: false };
			if (!root.music.playing) musicTimer.stop();
		})
	}

	// ── a folder as the wallpaper ──────────────────────────────────────────
	// FileLibrary's wallRotation: { folder, minutes, shuffle, last, at }
	function rotateWallpaper(now) {
		const rotation = FileLibrary.setting("wallRotation");
		if (!rotation?.folder) return;
		if (!now && Date.now() / 1000 - Number(rotation.at || 0) < Number(rotation.minutes || 60) * 60 - 5) return;
		root.request("list", { path: rotation.folder }, data => {
			const pictures = (data?.entries ?? []).filter(entry => !entry.dir && !entry.hidden && /^image\//.test(entry.mime)).sort((a, b) => b.mtime - a.mtime);
			if (pictures.length === 0) return;
			let next;
			if (rotation.shuffle !== false) {
				const others = pictures.filter(entry => entry.path !== rotation.last);
				next = others[Math.floor(Math.random() * others.length)] ?? pictures[0];
			} else {
				const at = pictures.findIndex(entry => entry.path === rotation.last);
				next = pictures[(at + 1) % pictures.length];
			}
			FileLibrary.set("wallRotation", Object.assign({}, rotation, { last: next.path, at: Date.now() / 1000 }));
			Quickshell.execDetached(["bash", `${Paths.scripts}/apply_theme_selection.sh`, next.path]);
		});
	}

	Timer {
		running: root.enabled && !!FileLibrary.setting("wallRotation")?.folder && Plugins.on("studio-wallpaper")
		interval: 60000
		repeat: true
		onTriggered: root.rotateWallpaper(false)
	}

	// ── time spent on a folder (screentime) ────────────────────────────────
	// seconds of the last `days` days in windows whose title names the folder
	// (an editor's project, a terminal's path, a browser tab of it)
	function timeIn(folder, days) {
		if (!Plugins.on("screentime")) return 0;
		const name = root.nameOf(folder).toLowerCase();
		const pretty = root.pretty(folder).toLowerCase();
		if (name.length < 3) return 0;
		const words = new RegExp(`(^|[^a-z0-9])${name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}([^a-z0-9]|$)`);
		let total = 0;
		for (let back = 0; back < days; back += 1) {
			const day = Screentime.day(Screentime.shifted(Screentime.today, -back));
			for (const key of Object.keys(day.windows ?? {})) {
				const title = key.split("\n").slice(1).join(" ").toLowerCase();
				if (title.includes(pretty) || title.includes(String(folder).toLowerCase()) || words.test(title)) total += day.windows[key];
			}
		}
		return total;
	}

	// the folders most time went to this week: [{ path, seconds }]
	function busyFolders() {
		const candidates = Array.from(new Set(FileLibrary.favorites.concat(FileLibrary.visited.slice(0, 25).map(entry => entry.path))));
		return candidates.map(path => ({ path: path, seconds: root.timeIn(path, 7) })).filter(entry => entry.seconds >= 300).sort((a, b) => b.seconds - a.seconds).slice(0, 6);
	}

	// ── the calendar ───────────────────────────────────────────────────────
	// the events of an .ics file go into the Microsoft 365 calendar
	function importCalendar(path) {
		calendarProc.command = ["python3", `${Paths.scripts}/ms_calendar.py`, "import", String(path)];
		calendarProc.running = true;
	}

	Process {
		id: calendarProc

		stdout: StdioCollector {
			onStreamFinished: {
				let answer = {};
				try {
					answer = JSON.parse(text.trim().split("\n").pop() || "{}");
				} catch (error) {
					answer = { error: "The calendar did not answer" };
				}
				if (answer.error) {
					root.fail(answer.error);
					return;
				}
				Sounds.play("taskDone");
				root.say(answer.imported === 1 ? "The event is in the calendar" : `${answer.imported} events are in the calendar`, "calendar_check");
				MsCalendar.refresh();
			}
		}
	}

	// ── to people: a new mail, a WhatsApp chat ─────────────────────────────
	// a new mail with the files attached (a folder is packed first); a big one asks first
	function mailFiles(paths, asked) {
		const items = paths.filter(path => String(path) !== "");
		if (items.length === 0) return;
		root.request("describe", { paths: items }, data => {
			const entries = data?.entries ?? [];
			const folders = entries.filter(entry => entry.dir).map(entry => entry.path);
			if (folders.length > 0) {
				root.say("Packing the folder first…", "zip_box_outline");
				root.compress(items, job => {
					if (job.state === "done" && (job.created ?? []).length > 0) root.mailFiles(job.created, asked);
				});
				return;
			}
			const total = entries.reduce((sum, entry) => sum + Number(entry.size || 0), 0);
			if (total > 20e6 && !asked) {
				root.confirmRequested({
					title: `Attach ${Format.bytes(total)} to a mail?`,
					detail: "Many mail servers refuse more than 20–25 MB. A link to share is lighter – or pack them as a ZIP first.",
					confirm: "Attach anyway",
					danger: false,
					run: () => root.mailFiles(items, true)
				});
				return;
			}
			const kept = Mail.drafts["new"] ?? { html: "", files: [], to: "", cc: "", bcc: "", subject: "" };
			const files = (kept.files ?? []).concat(items.filter(path => !(kept.files ?? []).includes(path)));
			Mail.keep("new", Object.assign({}, kept, { files: files, subject: kept.subject || (items.length === 1 ? root.nameOf(items[0]) : `${items.length} files`) }));
			Messages.open("new");
		});
	}

	// the people a file can go to on WhatsApp, the ones most sent to first, then the newest chats
	readonly property var recentChats: WhatsApp.enabled && WhatsApp.linked ? WhatsApp.chats.filter(chat => !chat.group && !chat.archived).map((chat, order) => ({ chat: chat, order: order, sent: FileLibrary.sentTo[chat.id] ?? 0 })).sort((a, b) => b.sent - a.sent || a.order - b.order).map(entry => entry.chat) : []

	function sendToChat(chat, paths) {
		WhatsApp.send(chat.id, "", "", paths.map(path => ({ path: path, as: /\.(jpe?g|png|webp|gif|mp4|mov|webm)$/i.test(path) ? "" : "document" })), []);
		FileLibrary.noteSent(chat.id);
		Sounds.play("copied");
		root.say(paths.length === 1 ? `Sent to ${chat.name}` : `${paths.length} files sent to ${chat.name}`, "whatsapp");
	}

	// ── the index for search by meaning ────────────────────────────────────
	// { files, meanings, described, withText, built, running, done, total, current, error, ai: { text, vision, embed, models } }
	property var index: ({})

	function knowIndex(done) {
		root.request("indexstatus", {}, data => {
			if (data) root.index = data;
			if (done) done(root.index);
		});
	}

	function indexNow() {
		root.request("indexbuild", { settings: {
			folders: FileLibrary.setting("aiFolders"),
			pictures: FileLibrary.setting("aiPictures") !== false,
			ocr: FileLibrary.setting("aiOcr") !== false,
			describe: FileLibrary.setting("aiDescribe") !== false,
			models: FileLibrary.setting("aiModels")
		} });
		root.index = Object.assign({}, root.index, { running: true });
	}

	// the index keeps up by itself while it is on: soon after the start, then every few hours
	Timer {
		running: root.enabled && root.connected && !!FileLibrary.setting("aiIndex")
		interval: root.index.built ? 4 * 3600 * 1000 : 10 * 60 * 1000
		repeat: true
		onTriggered: if (!root.index.running) root.indexNow()
	}

	function pullModel(model) {
		root.startJob("aipull", { model: model }, job => {
			if (job.state === "done") {
				root.say(`${model} is ready`, "check");
				root.knowIndex();
			}
		});
	}

	// ── tasks about files (todos plugin) ───────────────────────────────────
	signal tasksChanged

	function rememberTask(paths, group, note) {
		root.request("tasks", { action: "add", group: group, paths: paths, note: note || "" }, (data, error) => {
			if (error) {
				root.fail(error);
				return;
			}
			FileLibrary.set("taskGroup", data.group);
			Sounds.play("pinned");
			root.say(paths.length === 1 ? `A task in ${data.group}` : `${paths.length} tasks in ${data.group}`, "checkbox_marked_circle_outline");
			root.tasksChanged();
		});
	}

	// ── git ────────────────────────────────────────────────────────────────
	function commit(paths, message, push) {
		root.startJob("gitcommit", { paths: paths, message: message, push: !!push }, job => {
			if (job.state !== "done") return;
			const git = job.result?.git ?? {};
			Sounds.play("taskDone");
			root.say(git.pushError ? `Committed, the push failed: ${git.pushError}` : (git.pushed ? `Committed and pushed: ${git.head}` : `Committed: ${git.head}`), "source_commit");
		});
	}

	// pull, push or fetch in the repository of a folder
	function gitRun(path, what) {
		root.startJob("gitrun", { path: path, what: what }, job => {
			if (job.state === "done") root.say(String(job.result?.git?.summary || "Done"), what === "push" ? "upload_outline" : "source_pull");
		});
	}

	// ── earlier versions ───────────────────────────────────────────────────
	function versionsOf(path, done) {
		root.request("versions", { path: path }, data => done(data?.versions ?? [], data?.providers ?? []));
	}

	// mode: "beside" (a copy next to it) or "replace" (the current one goes to the trash)
	function restoreVersion(path, version, mode) {
		root.startJob("restoreversion", { path: path, version: version, mode: mode || "beside" }, job => {
			if (job.state === "done") root.say(mode === "replace" ? "The earlier version is back" : "The earlier version is beside it", "history");
		});
	}

	// ── vaults (gocryptfs) ─────────────────────────────────────────────────
	// { installed, install, fingerprint, vaults: [{ id, name, cipher, mount, open, keyring, remember }] }
	property var vaults: ({ installed: false, vaults: [] })

	function knowVaults(done) {
		root.request("vault", { action: "status" }, data => {
			if (data) root.vaults = data;
			if (done) done(root.vaults);
		});
	}

	function vaultDo(args, done) {
		root.request("vault", args, (data, error) => {
			if (data) root.vaults = data;
			if (done) done(data, error);
			else if (error && error !== "password") root.fail(error);
		});
	}

	// a vault whose password is in the keyring asks for a finger first: on
	// the PC's reader, else on the phone
	function proveIdentity(what, done) {
		if (root.vaults.fingerprint) {
			fingerProc.done = done;
			fingerProc.running = true;
			root.say("Put your finger on the reader", "fingerprint");
			return;
		}
		if (Plugins.on("phone-unlock") && Phone.reachable) {
			root.say(`Confirm on ${Phone.name}`, "cellphone_key");
			Phone.call("unlock", "pam", { what: what, body: "Put your finger on the sensor to open it." }, (data, error) => done(!error && !!data, String(error?.message ?? error ?? "")));
			return;
		}
		done(true, "");
	}

	Process {
		id: fingerProc

		property var done: null

		command: ["fprintd-verify"]
		onExited: code => {
			const done = fingerProc.done;
			fingerProc.done = null;
			if (done) done(code === 0, code === 0 ? "" : "The finger did not match");
		}
	}

	// ── a link to share ────────────────────────────────────────────────────
	// [{ id, name, url, host, at, expires, size }]
	property var shares: []

	function knowShares(done) {
		root.request("shares", {}, data => {
			root.shares = data?.shares ?? [];
			if (done) done(data);
		});
	}

	function share(paths, options) {
		const settings = FileLibrary.setting("shareServer") || {};
		root.startJob("share", {
			paths: paths,
			host: options.host,
			hours: Number(options.hours) || 24,
			server: options.host === "ssh" ? settings.server : null,
			folder: settings.folder || "",
			baseUrl: settings.url || ""
		}, job => {
			if (job.state !== "done") return;
			const made = job.result?.share;
			if (!made?.url) return;
			Quickshell.execDetached(["wl-copy", "--", made.url]);
			Sounds.play("taskDone");
			root.knowShares();
			Notifs.pushInternal("done", "The link is on the clipboard", `${made.url}${made.expires ? " · until " + Qt.formatDateTime(new Date(made.expires * 1000), "ddd HH:mm") : ""}`, {
				icon: "link_variant",
				actions: [{ label: "Open", icon: "open_in_new", run: () => Qt.openUrlExternally(made.url) }]
			});
		});
	}

	function unshare(id) {
		root.request("shares", { remove: id }, data => root.shares = data?.shares ?? []);
	}

	// ── pictures and tags ──────────────────────────────────────────────────
	function imageTool(tool, paths, options) {
		root.startJob("image", { tool: tool, paths: paths, options: options || {} }, job => {
			if (job.state === "done" && job.error) root.say(job.error, "alert_circle_outline");
		});
	}

	function writeTags(path, tags, cover, removeCover) {
		root.startJob("tags", { path: path, tags: tags, cover: cover || "", removeCover: !!removeCover }, job => {
			if (job.state === "done") root.say("Tags saved", "tag_check_outline");
		});
	}

	// ── two folders ────────────────────────────────────────────────────────
	function compareFolders(left, right, done) {
		root.request("compare", { left: left, right: right, deep: true }, (data, error) => {
			if (error) root.fail(error);
			done(data);
		});
	}

	function syncPlan(source, target, direction, remove, done) {
		root.request("syncplan", { source: source, target: target, direction: direction, delete: !!remove }, (data, error) => done(data, error));
	}

	function sync(source, target, direction, remove) {
		root.startJob("sync", { source: source, target: target, direction: direction, delete: !!remove }, job => {
			if (job.state === "done") root.say("The folders are in step", "folder_sync_outline");
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
		// files of the phone or entries of the clipboard history, dragged out of their place
		if ((drop.formats ?? []).includes("application/x-pshell-items")) {
			let items = [];
			try {
				items = JSON.parse(drop.getDataAsString("application/x-pshell-items"));
			} catch (error) {
				items = [];
			}
			root.materialize(items, target);
			return items.length > 0;
		}
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

	// things that are not files yet become files in a folder: phone files are
	// sent up, those of another PC fetched, clipboard entries written out
	function materialize(items, target) {
		const phone = items.filter(item => String(item.path).startsWith("phone:"));
		const clips = items.filter(item => String(item.path).startsWith("clip:"));
		if (phone.length > 0) PhoneDrive.importEntries(phone.map(item => Object.assign({ phoneId: String(item.path).slice(6) }, item)), target);
		// those of another PC come over its link, per PC
		const pcs = {};
		for (const item of items) {
			const pc = Pcs.split(item.path);
			if (pc) (pcs[pc.id] = pcs[pc.id] || []).push(pc.path);
		}
		for (const id of Object.keys(pcs)) {
			root.say(`Getting ${pcs[id].length === 1 ? Files.nameOf(pcs[id][0]) : `${pcs[id].length} items`} from ${Pcs.nameOf(id)}…`, "laptop");
			Pcs.fetch(id, pcs[id], target, paths => {
				Sounds.play("taskDone");
				root.say(paths.length === 1 ? `${root.nameOf(paths[0])} is here` : `${paths.length} items are here`, "laptop");
			});
		}
		if (clips.length > 0) root.startJob("clipsave", { ids: clips.map(item => String(item.path).slice(5)), target: target, names: clips.map(item => item.name) });
	}

	// a program for a folder: on the folder's workspace when it has one, else
	// (a terminal) below the Files window in its column
	function spawnFor(folder, command, stack) {
		const workspace = FileLibrary.workspaceOf(folder);
		const args = ["python3", `${Paths.scripts}/files/spawn_here.py`];
		if (workspace >= 0) args.push("--workspace", String(workspace));
		else if (stack && FileLibrary.setting("terminalBeside") !== false && root.windowActive) args.push("--stack");
		Quickshell.execDetached(args.concat(["--"], command));
	}

	function terminal(folder) {
		root.spawnFor(String(folder), Terminal.command({ dir: String(folder) }, []), true);
	}

	// a coding agent in a terminal, in that folder
	function agent(folder) {
		root.spawnFor(String(folder), Terminal.command({ dir: String(folder) }, ["claude"]), true);
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
