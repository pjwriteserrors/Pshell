pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// What the browsers download. Their extension (dotfiles/floorp/downloads)
// reports through scripts/downloads_host.py, which the browser starts and
// which connects to the socket here; pause, resume and cancel go back the
// same way. Nothing listens on the network. Finished downloads stay
// (downloads.json) until they are dismissed.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("downloads")

	// keys in the order they are shown: what runs first, then the newest
	property var order: []
	// { key: { key, source, id, name, path, url, mime, state, received, total, speed, eta, error, canResume, started, finished } }
	// state: "running" | "paused" | "done" | "failed"
	property var table: ({})
	// finished since the panel was last looked at
	property int unseen: 0
	// the hosts that are connected: { source: socket }
	property var links: ({})
	readonly property bool connected: Object.keys(root.links).length > 0

	// the bar
	property bool hideWhenIdle: true
	property bool showSpeed: true
	property bool showPercent: true
	// "auto" asks the desktop's file manager; otherwise one of `managers`
	property string fileManager: "auto"
	// the file managers that are installed
	property var managers: []
	readonly property var known: ["nautilus", "dolphin", "nemo", "thunar", "strata", "caja", "pcmanfm-qt", "pcmanfm"]

	readonly property var active: root.order.map(key => root.table[key]).filter(item => item && (item.state === "running" || item.state === "paused"))
	readonly property var running: root.active.filter(item => item.state === "running")
	readonly property real speed: root.running.reduce((sum, item) => sum + item.speed, 0)
	// of everything under way whose size is known; -1 when none is
	readonly property real ratio: {
		const sized = root.active.filter(item => item.total > 0);
		const total = sized.reduce((sum, item) => sum + item.total, 0);
		return total > 0 ? sized.reduce((sum, item) => sum + item.received, 0) / total : -1;
	}
	// seconds until the last one is through; -1 when that cannot be said
	readonly property real eta: root.running.length > 0 && root.running.every(item => item.eta >= 0) ? Math.max(...root.running.map(item => item.eta)) : -1
	// "running" | "paused" | "done" | "idle"
	readonly property string phase: root.running.length > 0 ? "running" : (root.active.length > 0 ? "paused" : (root.unseen > 0 ? "done" : "idle"))

	// bytes and time of the last report, for the speed: { key: { at, received, speed } }
	property var meters: ({})

	function formatSize(bytes) {
		const value = Math.max(0, Number(bytes) || 0);
		if (value >= 1024 * 1024 * 1024) return `${(value / (1024 * 1024 * 1024)).toFixed(2)} GB`;
		if (value >= 1024 * 1024) return `${(value / (1024 * 1024)).toFixed(1)} MB`;
		if (value >= 1024) return `${Math.round(value / 1024)} KB`;
		return `${Math.round(value)} B`;
	}

	function formatEta(seconds) {
		if (!(seconds >= 0)) return "";
		const total = Math.round(seconds);
		const hours = Math.floor(total / 3600);
		const minutes = Math.floor(total % 3600 / 60);
		const rest = total % 60;
		const two = value => value < 10 ? `0${value}` : String(value);
		return hours > 0 ? `${hours}:${two(minutes)}:${two(rest)}` : `${minutes}:${two(rest)}`;
	}

	// ── what the browser says ───────────────────────────────────────────────
	function receive(link, line) {
		let message = null;
		try {
			message = JSON.parse(line);
		} catch (error) {
			return;
		}
		if (!message) return;
		if (message.type === "hello") {
			link.source = String(message.source || "");
			root.links = Object.assign({}, root.links, { [link.source]: link });
			return;
		}
		if (link.source === "") return;
		if (message.type === "snapshot") {
			// what the browser no longer has under way is gone
			const stays = {};
			(message.items || []).forEach(item => stays[`${link.source}/${item.id}`] = true);
			root.active.filter(item => item.source === link.source && !stays[item.key]).forEach(item => root.drop(item.key));
			(message.items || []).forEach(item => root.report(link.source, item));
		} else if (message.type === "item" && message.item) {
			root.report(link.source, message.item);
		} else if (message.type === "gone") {
			const item = root.table[`${link.source}/${message.id}`];
			if (item && (item.state === "running" || item.state === "paused")) root.drop(item.key);
		}
	}

	function report(source, raw) {
		const key = `${source}/${raw.id}`;
		const before = root.table[key];
		const state = raw.state === "complete" ? "done" : (raw.paused ? "paused" : (raw.state === "in_progress" ? "running" : "failed"));
		// cancelled, here or in the browser: nothing to keep
		if (state === "failed" && (raw.error === "USER_CANCELED" || !before)) return root.drop(key);

		const received = Math.max(0, Number(raw.received) || 0);
		const now = Date.now();
		const meter = root.meters[key] || { at: now, received: received, speed: 0 };
		if (state !== "running") {
			meter.speed = 0;
			meter.at = now;
			meter.received = received;
		} else if (now - meter.at >= 700) {
			const fresh = Math.max(0, received - meter.received) / ((now - meter.at) / 1000);
			meter.speed = meter.speed > 0 ? meter.speed * 0.6 + fresh * 0.4 : fresh;
			meter.at = now;
			meter.received = received;
		}
		root.meters[key] = meter;

		const path = String(raw.file || "");
		const total = Number(raw.total) > 0 ? Number(raw.total) : 0;
		const item = {
			key: key, source: source, id: raw.id,
			name: path.split("/").pop() || String(raw.url || "").split("/").pop() || "Download",
			path: path, url: String(raw.url || ""), mime: String(raw.mime || ""),
			state: state, received: state === "done" && total > 0 ? total : received, total: total,
			speed: meter.speed, eta: state === "running" && total > 0 && meter.speed > 0 ? (total - received) / meter.speed : -1,
			error: String(raw.error || ""), canResume: raw.canResume === true,
			started: Date.parse(raw.started) || before?.started || now,
			finished: state === "done" || state === "failed" ? (before?.finished || now) : 0
		};
		const kept = state === "done" || state === "failed";
		const wasKept = before && (before.state === "done" || before.state === "failed");
		root.table = Object.assign({}, root.table, { [key]: item });
		if (!before || kept !== wasKept) root.sort();
		if (state === "done" && before?.state !== "done") root.unseen += 1;
		if (kept !== wasKept || (kept && before.state !== state)) root.save();
	}

	function sort() {
		const rank = item => item.state === "running" || item.state === "paused" ? 0 : 1;
		root.order = Object.keys(root.table).sort((a, b) => {
			const first = root.table[a];
			const second = root.table[b];
			if (rank(first) !== rank(second)) return rank(first) - rank(second);
			return rank(first) === 0 ? first.started - second.started : second.finished - first.finished;
		});
	}

	function drop(key) {
		if (!root.table[key]) return;
		const kept = root.table[key].state === "done" || root.table[key].state === "failed";
		const next = Object.assign({}, root.table);
		delete next[key];
		delete root.meters[key];
		root.order = root.order.filter(other => other !== key);
		root.table = next;
		if (kept) root.save();
	}

	function dropped(link) {
		if (link.source === "" || root.links[link.source] !== link) return;
		const next = Object.assign({}, root.links);
		delete next[link.source];
		root.links = next;
		// its browser is gone, and with it what it was downloading
		root.active.filter(item => item.source === link.source).forEach(item => root.drop(item.key));
	}

	// ── what the panel does ─────────────────────────────────────────────────
	function send(key, cmd) {
		const item = root.table[key];
		const link = item ? root.links[item.source] : null;
		if (!link) return;
		link.write(JSON.stringify({ type: "cmd", cmd: cmd, id: item.id }) + "\n");
		link.flush();
	}

	function pause(key) {
		root.send(key, "pause");
	}

	function resume(key) {
		root.send(key, "resume");
	}

	function cancel(key) {
		root.send(key, "cancel");
	}

	// only here: the file and the browser's own list stay as they are
	function dismiss(key) {
		root.drop(key);
		root.unseen = Math.min(root.unseen, root.order.filter(other => root.table[other].state === "done").length);
	}

	function seen() {
		root.unseen = 0;
	}

	function open(key) {
		const item = root.table[key];
		if (item && item.state === "done") Quickshell.execDetached(["xdg-open", item.path]);
	}

	// the file manager, with the file picked where it can do that
	function reveal(key) {
		const item = root.table[key];
		if (!item || item.path === "") return;
		const folder = item.path.slice(0, item.path.lastIndexOf("/")) || "/";
		const manager = root.managers.includes(root.fileManager) ? root.fileManager : "auto";
		if (manager === "auto") {
			const uri = "file://" + item.path.split("/").map(part => encodeURIComponent(part).replace(/'/g, "%27")).join("/");
			Quickshell.execDetached(["sh", "-c", 'gdbus call --session --dest org.freedesktop.FileManager1 --object-path /org/freedesktop/FileManager1 --method org.freedesktop.FileManager1.ShowItems "[\'$1\']" "" >/dev/null 2>&1 || xdg-open "$2"',
				"reveal", uri, folder]);
		} else if (manager === "nautilus" || manager === "dolphin") {
			Quickshell.execDetached([manager, "--select", item.path]);
		} else if (manager === "nemo") {
			Quickshell.execDetached([manager, item.path]);
		} else {
			Quickshell.execDetached([manager, folder]);
		}
	}

	function set(name, value) {
		if (name === "hideWhenIdle") root.hideWhenIdle = !!value;
		else if (name === "showSpeed") root.showSpeed = !!value;
		else if (name === "showPercent") root.showPercent = !!value;
		else if (name === "fileManager") root.fileManager = String(value);
		else return;
		root.save();
	}

	function save() {
		const kept = root.order.map(key => root.table[key]).filter(item => item.state === "done" || item.state === "failed");
		file.setText(JSON.stringify({
			hideWhenIdle: root.hideWhenIdle, showSpeed: root.showSpeed, showPercent: root.showPercent, fileManager: root.fileManager,
			kept: kept
		}, null, "\t") + "\n");
	}

	FileView {
		id: file

		path: Paths.stateFile("downloads.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(String(text() || "{}"));
				root.hideWhenIdle = data.hideWhenIdle !== false;
				root.showSpeed = data.showSpeed !== false;
				root.showPercent = data.showPercent !== false;
				root.fileManager = String(data.fileManager || "auto");
				const table = {};
				// a failed one cannot be taken up again once its browser is gone
				(data.kept || []).filter(item => item && item.key && item.state).forEach(item => table[item.key] = Object.assign({}, item, { canResume: false, speed: 0, eta: -1 }));
				root.table = table;
				root.sort();
			} catch (error) {}
		}
	}

	Process {
		running: root.enabled
		command: ["sh", "-c", 'for name in "$@"; do command -v "$name" >/dev/null && echo "$name"; done', "managers"].concat(root.known)
		stdout: StdioCollector {
			onStreamFinished: root.managers = String(text).split("\n").filter(name => name !== "")
		}
	}

	// the socket's folder first
	Process {
		id: folder

		running: root.enabled
		command: ["mkdir", "-p", Paths.runtime]
		onExited: server.active = Qt.binding(() => root.enabled)
	}

	SocketServer {
		id: server

		path: `${Paths.runtime}/downloads.sock`
		handler: Socket {
			id: link

			property string source: ""

			parser: SplitParser {
				onRead: line => root.receive(link, line)
			}
			onConnectedChanged: if (!link.connected) root.dropped(link)
		}
	}
}
