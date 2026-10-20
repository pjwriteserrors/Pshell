pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.style.theme

// The torrent client (plugin "torrents"). The downloads themselves run in a
// daemon of their own (scripts/torrents/daemon.py, libtorrent) that lives
// apart from the shell, so they go on when the shell reloads; this service
// is the shell's end: what it asks, what the daemon tells every second.
//
// Magnet links and .torrent files reach it through the desktop entry
// "Pshell Torrents" (scripts/torrents/default.py), which is the default for
// both while the plugin is on: a click on a link in the browser opens the
// window with the add sheet, where the destination is picked.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("torrents")
	readonly property string daemon: `${Paths.scripts}/torrents/daemon.py`
	readonly property string socketPath: `${Paths.runtime}/torrents.sock`

	property bool connected: false

	// every torrent as the daemon last told: { hash, name, phase, progress, done, size, down, up, peers, seeds, swarmSeeds, swarmPeers, eta, uploaded, downloaded, ratio, destination, added, finished, error, sequential, queue, pieces, availability }
	// phase: "metadata" | "checking" | "queued" | "downloading" | "stalled" | "seeding" | "done" | "paused" | "error" | "moving"
	property var torrents: []
	readonly property var byHash: {
		const out = {};
		for (const item of root.torrents) out[item.hash] = item;
		return out;
	}
	// the session's rates, now and the last minutes: [[down, up]]
	property real down: 0
	property real up: 0
	property var live: []
	// { destination, recent, ratio, downLimit, upLimit, port, startPaused }
	property var settings: ({ destination: `${Paths.home}/Downloads`, recent: [], ratio: 1, downLimit: 0, upLimit: 0, port: 6881, startPaused: false })

	// links and files waiting for their destination, the first is shown:
	// { pid, name, hasMetadata, files: [{ index, path, size }], total, peers, error, loading, uri }
	property var pending: []
	// the torrent the window shows
	property string selected: ""
	// what the daemon told of it: { summary, files, peers, peerCount, trackers, pieces, magnet, history, live }
	property var details: null
	// browsers that still ask before handing a magnet link over (they were open)
	property int browsersAsk: 0

	readonly property var running: root.torrents.filter(item => ["downloading", "stalled", "metadata", "checking", "moving", "queued"].includes(item.phase))
	readonly property real ratio: {
		const sized = root.running.filter(item => item.size > 0);
		const total = sized.reduce((sum, item) => sum + item.size, 0);
		return total > 0 ? sized.reduce((sum, item) => sum + item.done, 0) / total : -1;
	}

	// the upload beside the download (the accent): across the colour wheel
	// from it, so the two lines never look alike whatever the wallpaper
	readonly property color upColor: {
		const hue = Theme.primary.hsvHue < 0 ? 0.55 : (Theme.primary.hsvHue + 0.5) % 1;
		return Theme.legible(Qt.hsva(hue, Math.max(0.45, Theme.primary.hsvSaturation), 0.85, 1), 3.0);
	}

	signal finishedOne(var torrent)

	// ── where it shows ─────────────────────────────────────────────────────
	// under the bar (torrents-bar, a panel of the bar's icon) or popped out
	// into a window of its own; which one is kept (torrents-ui.json)
	property alias surface: popout
	property alias windowed: popout.windowed
	property alias windowOpen: popout.windowOpen
	readonly property bool panelled: popout.panelled
	readonly property bool shown: popout.shown

	Popout {
		id: popout

		popup: "torrents"
		panel: Plugins.on("torrents-bar")
	}

	function open() {
		if (!root.enabled) return;
		popout.open();
		root.wake();
	}

	function close() {
		popout.close();
	}

	function toggle() {
		if (root.shown) root.close();
		else root.open();
	}

	function popOut() {
		popout.popOut();
		root.saveUi();
	}

	function dock() {
		popout.dock();
		root.saveUi();
		root.open();
	}

	function saveUi() {
		uiFile.setText(JSON.stringify({ windowed: root.windowed }) + "\n");
	}

	FileView {
		id: uiFile

		path: Paths.stateFile("torrents-ui.json")
		printErrors: false
		onLoaded: {
			try {
				root.windowed = JSON.parse(String(text() || "{}")).windowed === true;
			} catch (error) {}
		}
	}

	function select(hash) {
		root.selected = hash;
		root.details = null;
		root.fetchDetails();
	}

	// a magnet link, a .torrent file (path or file://) or a link to one
	function add(uri) {
		const text = String(uri || "").trim();
		if (text === "") return;
		root.open();
		const pid = `wait-${Date.now()}`;
		root.pending = root.pending.concat([{ pid: pid, name: root.guessName(text), hasMetadata: false, files: [], total: -1, peers: 0, loading: true, uri: text, error: "" }]);
		root.request("preview", { uri: text }, (data, error) => {
			if (error) return root.patchPending(pid, { loading: false, error: error });
			if (data.exists) {
				root.pending = root.pending.filter(item => item.pid !== pid);
				root.select(data.exists);
				root.toast(`${data.name || "That torrent"} is already here`);
				return;
			}
			// the same link twice: one sheet
			if (root.pending.some(item => item.pid === data.pid)) {
				root.pending = root.pending.filter(item => item.pid !== pid);
				return;
			}
			root.patchPending(pid, Object.assign({}, data, { loading: false }));
		});
	}

	function guessName(uri) {
		const match = /[?&]dn=([^&]+)/.exec(uri);
		if (match) {
			try {
				return decodeURIComponent(match[1].replace(/\+/g, " "));
			} catch (error) {}
		}
		const name = uri.split("/").pop().replace(/\.torrent$/i, "");
		return uri.startsWith("magnet:") ? "Magnet link" : (decodeURIComponent(name) || "Torrent");
	}

	function patchPending(pid, change) {
		root.pending = root.pending.map(item => item.pid === pid ? Object.assign({}, item, change) : item);
	}

	// skip: indices of files left out; options: { paused, sequential, remember }
	function confirm(pid, destination, skip, options) {
		const item = root.pending.find(entry => entry.pid === pid);
		if (!item) return;
		root.pending = root.pending.filter(entry => entry.pid !== pid);
		root.request("confirm", Object.assign({ pid: pid, destination: destination, skip: skip || [] }, options || {}), (data, error) => {
			if (error) return root.toast(error, true);
			root.select(data.hash);
		});
	}

	function cancel(pid) {
		const item = root.pending.find(entry => entry.pid === pid);
		root.pending = root.pending.filter(entry => entry.pid !== pid);
		if (item && !item.loading && !item.error) root.request("cancel", { pid: pid });
	}

	function pause(hash) {
		root.request("pause", { hash: hash });
	}

	function resume(hash) {
		root.request("resume", { hash: hash });
	}

	function remove(hash, withFiles) {
		root.request("remove", { hash: hash, files: !!withFiles }, () => root.list());
		if (root.selected === hash) {
			root.selected = "";
			root.details = null;
		}
	}

	function recheck(hash) {
		root.request("recheck", { hash: hash });
	}

	function reannounce(hash) {
		root.request("reannounce", { hash: hash });
	}

	function setSequential(hash, on) {
		root.request("sequential", { hash: hash, on: on }, () => root.fetchDetails());
	}

	function move(hash, destination) {
		root.request("move", { hash: hash, destination: destination });
	}

	function setWanted(hash, index, wanted) {
		root.request("files", { hash: hash, wanted: { [index]: wanted } }, () => root.fetchDetails());
	}

	function queue(hash, to) {
		root.request("queue", { hash: hash, to: to });
	}

	function setSetting(name, value) {
		root.settings = Object.assign({}, root.settings, { [name]: value });
		root.request("settings", { settings: { [name]: value } });
	}

	function space(path, done) {
		root.request("space", { path: path }, data => done(data || { free: -1 }));
	}

	function list() {
		root.request("list", {}, data => {
			if (data) root.take(data.torrents || []);
		});
	}

	function fetchDetails() {
		if (root.selected === "") return;
		const hash = root.selected;
		root.request("details", { hash: hash }, (data, error) => {
			if (root.selected !== hash) return;
			if (error) {
				root.selected = "";
				root.details = null;
				return;
			}
			root.details = data;
		});
	}

	// the folder a torrent's files are in, picked in the file manager
	function reveal(hash) {
		const item = root.byHash[hash];
		if (!item) return;
		const path = `${item.destination}/${item.name}`;
		const uri = Format.fileUri(path);
		Quickshell.execDetached(["sh", "-c", 'gdbus call --session --dest org.freedesktop.FileManager1 --object-path /org/freedesktop/FileManager1 --method org.freedesktop.FileManager1.ShowItems "[\'$1\']" "" >/dev/null 2>&1 || xdg-open "$2"',
			"reveal", uri, item.destination]);
	}

	function openFile(hash, relative) {
		const item = root.byHash[hash];
		if (!item) return;
		Quickshell.execDetached(["xdg-open", `${item.destination}/${relative}`]);
	}

	function copy(text) {
		Quickshell.execDetached(["wl-copy", "--", String(text)]);
	}

	// the shell's folder chooser; done(path) with "" when nothing was picked
	function pickFolder(start, done) {
		Files.pick({ title: "Where should it go?", directory: true, folder: start || root.settings.destination }, paths => {
			if (done) done(paths[0] ?? "");
		});
	}


	// a .torrent file picked from disk
	function pickFile() {
		Files.pick({ title: "Open a torrent file", multiple: true, filters: ["*.torrent"] }, paths => {
			paths.filter(path => path.endsWith(".torrent")).forEach(path => root.add(path));
		});
	}


	// ── how things are said ────────────────────────────────────────────────
	// when something that takes `seconds` from now will be over, as a clock
	function finishTime(seconds) {
		if (!(seconds >= 0)) return "";
		const when = new Date(Date.now() + seconds * 1000);
		const today = new Date();
		const clock = Qt.formatTime(when, "HH:mm");
		if (when.toDateString() === today.toDateString()) return clock;
		const tomorrow = new Date(today.getTime() + 86400000);
		if (when.toDateString() === tomorrow.toDateString()) return `tomorrow ${clock}`;
		return `${Qt.formatDate(when, "ddd d MMM")} ${clock}`;
	}

	function when(unix) {
		if (!(unix > 0)) return "";
		const date = new Date(unix * 1000);
		const today = new Date();
		if (date.toDateString() === today.toDateString()) return `today ${Qt.formatTime(date, "HH:mm")}`;
		const yesterday = new Date(today.getTime() - 86400000);
		if (date.toDateString() === yesterday.toDateString()) return `yesterday ${Qt.formatTime(date, "HH:mm")}`;
		return Qt.formatDateTime(date, "d MMM yyyy, HH:mm");
	}

	function phaseLabel(phase) {
		return ({
			metadata: "Finding files",
			checking: "Checking",
			queued: "Queued",
			downloading: "Downloading",
			stalled: "Waiting for peers",
			seeding: "Seeding",
			done: "Complete",
			paused: "Paused",
			error: "Error",
			moving: "Moving"
		})[phase] || phase;
	}

	function toast(text, error) {
		Notifs.post({ app: "Torrents", icon: `${Paths.assets}/icons/pshell-torrents.svg`, summary: error ? "Torrent failed" : "Torrents", body: String(text) });
	}

	// ── what the daemon tells ──────────────────────────────────────────────
	function take(list) {
		const before = root.byHash;
		root.stored = false;
		root.torrents = list;
		// the downloads in the bar and its panel, like the browser's
		if (Plugins.on("downloads")) Downloads.mirror("torrent", list.map(item => ({
			id: item.hash,
			name: item.name,
			path: `${item.destination}/${item.name}`,
			state: item.finished > 0 || item.phase === "seeding" || item.phase === "done" ? "done" : (item.phase === "paused" || item.phase === "error" ? "paused" : "running"),
			received: item.done,
			total: Math.max(0, item.size),
			speed: item.down,
			eta: item.eta,
			started: item.added * 1000
		})));
		if (root.selected !== "" && !root.byHash[root.selected] && before[root.selected]) {
			root.selected = "";
			root.details = null;
		}
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
		case "tick":
			root.take(message.torrents || []);
			root.down = Number(message.down) || 0;
			root.up = Number(message.up) || 0;
			root.live = root.live.concat([[root.down, root.up]]).slice(-180);
			break;
		case "preview":
			if (message.preview) root.patchPending(message.preview.pid, message.preview);
			break;
		case "finished":
			root.finished(message.torrent);
			break;
		case "settings":
			root.settings = Object.assign({}, root.settings, message.settings || {});
			break;
		case "error":
			root.toast(String(message.message || "Something went wrong"), true);
			break;
		}
	}

	function finished(torrent) {
		if (!torrent) return;
		root.finishedOne(torrent);
		// the downloads list plays its sound for what it shows
		if (!Plugins.on("downloads")) Sounds.play("download");
		const hash = torrent.hash;
		Notifs.post({
			app: "Torrents",
			icon: `${Paths.assets}/icons/pshell-torrents.svg`,
			summary: "Download complete",
			body: `${torrent.name} · ${Format.bytes(torrent.size)}`,
			actions: [{ text: "Show folder", invoke: () => root.reveal(hash) }, { text: "Torrents", invoke: () => {
				root.select(hash);
				root.open();
			} }]
		});
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
			root.queued.push(message);
			root.wake();
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
		root.request("hello", { role: "shell" }, (data, error) => {
			if (error || !data) return;
			root.connected = true;
			root.attempts = 0;
			root.settings = Object.assign({}, root.settings, data.settings || {});
			root.take(data.torrents || []);
			root.live = data.live || [];
			const waiting = root.queued;
			root.queued = [];
			for (const message of waiting) root.socket?.write(JSON.stringify(message) + "\n");
			root.socket?.flush();
			// the daemon kept magnet links waiting while the shell was away
			for (const preview of data.pending || []) {
				if (preview && !root.pending.some(item => item.pid === preview.pid)) root.pending = root.pending.concat([Object.assign({ loading: false, error: "" }, preview)]);
			}
			root.fetchDetails();
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
			const queued = root.queued.map(message => String(message.id));
			const waiting = root.callbacks;
			root.callbacks = {};
			for (const id of Object.keys(waiting)) {
				if (queued.includes(id)) root.callbacks[id] = waiting[id];
				else waiting[id](null, "The torrent daemon went away");
			}
		}
		if (root.enabled) root.wake();
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

	// The daemon is only kept while there is something for it: torrents, the
	// window, a link waiting. Without, the shell lets go and it leaves a
	// minute later.
	readonly property bool needed: root.enabled && (root.shown || root.pending.length > 0 || root.torrents.length > 0 || root.stored)
	// torrents of an earlier session, before the daemon told of them
	property bool stored: false

	FileView {
		path: `${Paths.state}/torrents/index.json`
		printErrors: false
		onLoaded: {
			try {
				root.stored = Object.keys(JSON.parse(String(text() || "{}"))).length > 0;
			} catch (error) {}
			if (root.needed) root.wake();
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

		interval: 10000
		onTriggered: {
			if (root.needed) return;
			retry.stop();
			root.hangUp();
			root.connected = false;
		}
	}

	// connected or not, a look now and then: a daemon that was killed comes back
	Timer {
		running: root.needed
		repeat: true
		interval: 5000
		onTriggered: root.wake()
	}

	// what the window shows of one torrent, while it is open
	Timer {
		running: root.enabled && root.connected && root.shown && root.selected !== ""
		repeat: true
		interval: 1000
		onTriggered: root.fetchDetails()
	}

	onEnabledChanged: {
		if (root.enabled) {
			root.attempts = 0;
		} else {
			retry.stop();
			root.hangUp();
			root.connected = false;
			root.windowOpen = false;
			if (Plugins.on("downloads")) Downloads.mirror("torrent", []);
			root.applyDefault();
		}
	}

	Component.onCompleted: if (root.needed) root.wake()

	// ── the desktop's torrent client ───────────────────────────────────────
	property bool entryInstalled: false

	function applyDefault() {
		if (!root.enabled && !root.entryInstalled) return;
		defaultProc.command = ["python3", `${Paths.scripts}/torrents/default.py`, root.enabled ? "on" : "remove"];
		defaultProc.running = true;
		root.entryInstalled = root.enabled;
	}

	Process {
		id: defaultProc

		stdout: StdioCollector {
			onStreamFinished: {
				try {
					root.browsersAsk = Number(JSON.parse(String(text).trim() || "{}").browsersAsk) || 0;
				} catch (error) {}
			}
		}
	}

	Timer {
		running: root.enabled
		interval: 4000
		onTriggered: root.applyDefault()
	}

	// a browser that was open when the plugin came on: asked again later
	Timer {
		running: root.enabled && root.browsersAsk > 0
		interval: 60000
		repeat: true
		onTriggered: root.applyDefault()
	}
}
