pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// The download accelerator (plugin "download-boost"). Its daemon
// (scripts/downloads/boost.py) asks a server for several parts of a file at
// once, over connections of their own; this service is the shell's end of it.
//
// The browser offers every new download (Downloads.qml, from the extension):
// the daemon looks whether the server sends parts, and takes it over when
// that can make it faster; otherwise the browser goes on downloading as
// always. Links can also be added here (the downloads panel, `ipc downloads
// add`): those go over one connection where the server allows no more.
// Everything the daemon has shows among the downloads (Downloads.mirror).
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("download-boost")
	readonly property string daemon: `${Paths.scripts}/downloads/boost.py`
	readonly property string socketPath: `${Paths.runtime}/boost.sock`

	property bool connected: false
	// as the daemon last told: { id, name, path, url, host, mime, state, mode, error, note, received, total, speed, peak, eta,
	//   connections, limit, wanted, most, speeds, parts, segments, started, finished, activeTime, average, bestSingle, browser }
	// state: "running" | "paused" | "done" | "failed"; mode: "boost" | "single"
	property var jobs: []
	// { connections, minSize }
	property var settings: ({ connections: 8, minSize: 4194304 })
	// offers being looked at, by browser key: the card says "Checking the server…"
	property var checking: ({})
	// links being added: their first request is under way
	property int adding: 0

	readonly property var byId: {
		const out = {};
		for (const job of root.jobs) out[job.id] = job;
		return out;
	}

	signal added(var job)
	signal failedToAdd(string url, string error)

	// ── what the shell asks ────────────────────────────────────────────────
	// a download the browser began; done(taken, reason)
	function offer(source, message, done) {
		const item = message.item || {};
		const key = `${source}/${item.id}`;
		root.checking = Object.assign({}, root.checking, { [key]: true });
		root.request("offer", {
			url: String(item.url || ""), path: String(item.file || ""), total: Number(item.total) || -1, mime: String(item.mime || ""),
			referrer: String(message.referrer || ""), cookies: String(message.cookies || ""), userAgent: String(message.userAgent || ""),
			language: String(message.language || ""), source: source, browserId: item.id
		}, (data, error) => {
			const next = Object.assign({}, root.checking);
			delete next[key];
			root.checking = next;
			if (error || !data) return done(false, error || "The accelerator did not answer");
			if (data.taken && data.job) root.take(root.jobs.filter(job => job.id !== data.job.id).concat([data.job]));
			done(data.taken === true, String(data.reason || ""));
		});
	}

	// a link typed or pasted: into the download folder, as fast as the server lets it
	function add(url) {
		const text = String(url || "").trim();
		if (text === "") return;
		root.adding += 1;
		root.request("add", { url: text }, (data, error) => {
			root.adding = Math.max(0, root.adding - 1);
			if (error || !data?.job) {
				root.failedToAdd(text, error || "failed");
				Notifs.post({ app: "Downloads", icon: "download", summary: "Could not download that", body: `${error || "failed"}\n${text}` });
				return;
			}
			root.take(root.jobs.filter(job => job.id !== data.job.id).concat([data.job]));
			root.added(data.job);
		});
	}

	function pause(id) {
		root.request("pause", { job: id }, () => root.list());
	}

	function resume(id) {
		root.request("resume", { job: id }, () => root.list());
	}

	// stops it and removes what came so far
	function cancel(id) {
		root.request("cancel", { job: id }, () => root.list());
	}

	// one taken from the browser was complete there before it could let go
	function kept(source, browserId) {
		const job = root.jobs.find(entry => entry.browser && String(entry.browser.source) === String(source) && String(entry.browser.id) === String(browserId));
		if (job) root.cancel(job.id);
	}

	function setSetting(name, value) {
		root.settings = Object.assign({}, root.settings, { [name]: value });
		root.request("settings", { settings: { [name]: value } });
	}

	function list() {
		root.request("list", {}, data => {
			if (data) root.take(data.jobs || []);
		});
	}

	// ── what the daemon tells ──────────────────────────────────────────────
	function take(list) {
		root.jobs = list;
		Downloads.mirror("boost", list.map(job => ({
			id: job.id,
			name: job.name,
			path: job.path,
			state: job.state === "failed" ? "failed" : job.state,
			received: job.received,
			total: Math.max(0, job.total),
			speed: job.speed,
			eta: job.eta,
			started: job.started * 1000,
			extra: {
				url: job.url, mime: job.mime, error: job.error, host: job.host, mode: job.mode, note: job.note,
				connections: job.connections, limit: job.limit, wanted: job.wanted, most: job.most, speeds: job.speeds, parts: job.parts, segments: job.segments,
				peak: job.peak, average: job.average, bestSingle: job.bestSingle, activeTime: job.activeTime, canResume: true
			}
		})));
		// what is through is only kept here, among the downloads
		for (const job of list) {
			if (job.state === "done") root.request("forget", { job: job.id });
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
			root.take(message.jobs || []);
			break;
		case "added":
			if (message.job && !root.byId[message.job.id]) root.take(root.jobs.concat([message.job]));
			break;
		case "finished":
		case "failed":
			if (message.job) {
				// the whole download's speeds, for its card and the statistics
				if (message.job.history) Downloads.keepHistory(`boost/${message.job.id}`, message.job.history.map(entry => entry[1]));
				root.take(root.jobs.filter(job => job.id !== message.job.id).concat([message.job]));
			}
			break;
		case "settings":
			root.settings = Object.assign({}, root.settings, message.settings || {});
			break;
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
			root.queued.push(message);
			root.wanting = true;
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
			root.take(data.jobs || []);
			const waiting = root.queued;
			root.queued = [];
			for (const message of waiting) root.socket?.write(JSON.stringify(message) + "\n");
			root.socket?.flush();
			root.wanting = false;
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
				else waiting[id](null, "The accelerator went away");
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
			// a daemon that cannot start: what waits for it is told
			if (root.attempts > 40) {
				retry.stop();
				root.attempts = 0;
				const waiting = root.callbacks;
				root.callbacks = {};
				root.queued = [];
				root.wanting = false;
				for (const id of Object.keys(waiting)) waiting[id](null, "The accelerator could not be started");
				return;
			}
			root.dial();
		}
	}

	// The daemon is only kept while there is something for it: downloads, a
	// request waiting. Without, the shell lets go and it leaves a minute later.
	property bool wanting: false
	property bool stored: false
	readonly property bool needed: root.enabled && (root.wanting || root.stored || root.jobs.some(job => job.state !== "done"))

	FileView {
		path: `${Paths.state}/boost/jobs.json`
		printErrors: false
		onLoaded: {
			try {
				root.stored = JSON.parse(String(text() || "[]")).length > 0;
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

	onConnectedChanged: if (root.connected) root.stored = false

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

	Timer {
		running: root.needed
		repeat: true
		interval: 5000
		onTriggered: root.wake()
	}

	onEnabledChanged: {
		if (root.enabled) {
			root.attempts = 0;
		} else {
			retry.stop();
			root.hangUp();
			root.connected = false;
			Downloads.mirror("boost", []);
		}
	}

	Component.onCompleted: if (root.needed) root.wake()
}
