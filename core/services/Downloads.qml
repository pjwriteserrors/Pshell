pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// What the browsers download. Their extension (dotfiles/floorp/downloads)
// reports through scripts/downloads_host.py, which the browser starts and
// which connects to the socket here; pause, resume and cancel go back the
// same way. Nothing listens on the network. Finished downloads stay
// (downloads.json) until they are dismissed. The same link tells Screentime
// which page is in front.
//
// With the accelerator on (Boost.qml), every new browser download is offered
// to it first; what it takes over leaves the browser and comes back here as
// one of its own, what it declines goes on in the browser with the reason on
// its card. Every finished download leaves its figures in the statistics
// (downloads-stats.json): how much, how fast, accelerated or not, and how
// much time the extra connections saved.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("downloads")
	// the socket is there for either of the two
	// the file chooser asks which page saves (per site it remembers where)
	readonly property bool listening: root.enabled || Screentime.enabled || (Plugins.on("filemanager") && Plugins.on("files-chooser"))

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

	// browser downloads go to the accelerator first (Boost.qml)
	property bool boost: true
	// the downloads panel opens when a download starts
	property bool popOnStart: false
	// the extension offers downloads (it is new enough for the accelerator)
	property bool offering: false
	// what the accelerator said of a browser download it did not take: { key: reason }
	property var notes: ({})

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

	// a download that was seen running is complete (the file manager may check it)
	signal finished(var item)
	// one that was not there before starts
	signal started(var item)

	// ── the panel ──────────────────────────────────────────────────────────
	readonly property bool shown: Popups.current === "downloads"

	function openPanel(page) {
		if (!root.enabled) return;
		Popups.withFocusedScreen(screen => Popups.open("downloads", screen, page));
	}

	function closePanel() {
		if (root.shown) Popups.close();
	}

	function togglePanel() {
		if (root.shown) root.closePanel();
		else root.openPanel();
	}

	// the glyph of a download's kind of file
	function glyphOf(item) {
		if (!item) return "download";
		const name = String(item.name || "").toLowerCase();
		const mime = String(item.mime || "");
		if (item.source === "torrent") return "magnet";
		if (mime.startsWith("image/") || /\.(png|jpe?g|gif|webp|svg|avif|heic)$/.test(name)) return "image";
		if (mime.startsWith("video/") || /\.(mp4|mkv|webm|mov|avi)$/.test(name)) return "video";
		if (mime.startsWith("audio/") || /\.(mp3|flac|ogg|opus|wav|m4a)$/.test(name)) return "music";
		if (mime === "application/pdf" || name.endsWith(".pdf")) return "file_pdf_box";
		if (/\.(zip|tar|gz|xz|zst|bz2|7z|rar|deb|rpm|iso|img|appimage|flatpak|exe|msi|dmg)$/.test(name)) return "package_variant";
		return "file_document";
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
		if (message.type === "tab") return Screentime.tab(link.source, message);
		if (!root.enabled) return;
		if (message.type === "offer") {
			if (!root.offering) {
				root.offering = true;
				root.save();
			}
			return root.offered(link, message);
		}
		if (message.type === "kept") return Boost.kept(link.source, message.id);
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

	// a new browser download: the accelerator may take it
	function offered(link, message) {
		const id = message.item?.id;
		if (id === undefined || !Boost.enabled || !root.boost) return;
		const key = `${link.source}/${id}`;
		Boost.offer(link.source, message, (taken, reason) => {
			if (taken) {
				link.write(JSON.stringify({ type: "cmd", cmd: "takeover", id: id }) + "\n");
				link.flush();
				return;
			}
			root.notes = Object.assign({}, root.notes, { [key]: reason || "The server allows no more connections" });
			const item = root.table[key];
			if (item) root.table = Object.assign({}, root.table, { [key]: Object.assign({}, item, { note: root.notes[key] }) });
		});
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
			finished: state === "done" || state === "failed" ? (before?.finished || now) : 0,
			mode: "browser", note: root.notes[key] || "", host: root.hostOf(String(raw.url || ""))
		};
		const kept = state === "done" || state === "failed";
		const wasKept = before && (before.state === "done" || before.state === "failed");
		root.table = Object.assign({}, root.table, { [key]: item });
		if (!before || kept !== wasKept) root.sort();
		if (state === "done" && before?.state !== "done") root.unseen += 1;
		if (state === "done" && before && before.state !== "done") {
			root.record(item);
			root.finished(item);
		}
		if (!before && state === "running") root.started(item);
		// one that was seen running ends
		if (before && before.state !== state && (state === "done" || state === "failed")) Sounds.play(state === "done" ? "download" : "error");
		if (kept !== wasKept || (kept && before.state !== state)) root.save();
	}

	// downloads of another kind that show here as well (the torrent client):
	// all of a source's at once, { id, name, path, state, received, total,
	// speed, eta, started }; what is no longer among them while it ran is gone
	function mirror(source, items) {
		if (!root.enabled) return;
		const stays = {};
		for (const raw of items) {
			const key = `${source}/${raw.id}`;
			stays[key] = true;
			const before = root.table[key];
			// one that was complete before the shell came stays dismissed
			if (!before && raw.state === "done") continue;
			const item = Object.assign({
				key: key, source: source, id: raw.id, name: String(raw.name || "Download"), path: String(raw.path || ""), url: "", mime: "",
				state: raw.state, received: raw.received, total: raw.total, speed: raw.speed, eta: raw.state === "running" ? raw.eta : -1,
				error: "", canResume: true, started: raw.started || before?.started || Date.now(),
				finished: raw.state === "done" ? (before?.finished || Date.now()) : 0,
				mode: source, note: "", host: ""
			}, raw.extra || {});
			if (before && JSON.stringify(before) === JSON.stringify(item)) continue;
			const kept = item.state === "done";
			const wasKept = before && before.state === "done";
			root.table = Object.assign({}, root.table, { [key]: item });
			if (!before || kept !== wasKept) root.sort();
			if (kept && before && !wasKept) {
				root.unseen += 1;
				root.record(item);
				root.finished(item);
				Sounds.play("download");
			}
			if (item.state === "failed" && before && before.state === "running") Sounds.play("error");
			if (!before && item.state === "running") root.started(item);
			if (kept !== wasKept) root.save();
		}
		root.active.filter(item => item.source === source && !stays[item.key]).forEach(item => root.drop(item.key));
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
		delete root.curves[key];
		if (root.notes[key] !== undefined) {
			const notes = Object.assign({}, root.notes);
			delete notes[key];
			root.notes = notes;
		}
		root.order = root.order.filter(other => other !== key);
		root.table = next;
		if (kept) root.save();
	}

	function dropped(link) {
		if (link.source === "" || root.links[link.source] !== link) return;
		const next = Object.assign({}, root.links);
		delete next[link.source];
		root.links = next;
		Screentime.tabGone(link.source);
		// its browser is gone, and with it what it was downloading
		root.active.filter(item => item.source === link.source).forEach(item => root.drop(item.key));
	}

	// ── speeds over time ────────────────────────────────────────────────────
	// one speed a second per download while it runs: { key: [bytes/s] }; the
	// cards draw them, the statistics take the peak. `curveTick` moves on
	// with every sample, for bindings.
	property var curves: ({})
	property int curveTick: 0
	// what everything together does, the last two minutes
	property var live: []

	// a copy: the list itself grows in place, which a binding would not notice
	function curve(key) {
		root.curveTick;
		return (root.curves[key] || []).slice();
	}

	// the whole download as the accelerator measured it
	function keepHistory(key, values) {
		if (values && values.length > 1) root.curves[key] = values.slice(-900);
		root.curveTick += 1;
	}

	Timer {
		running: root.enabled && root.active.length > 0
		interval: 1000
		repeat: true
		onTriggered: {
			for (const item of root.active) {
				const list = root.curves[item.key] || [];
				list.push(item.state === "running" ? item.speed : 0);
				// past 900 seconds, every other of the older half
				root.curves[item.key] = list.length > 900 ? list.slice(0, 450).filter((value, index) => index % 2 === 0).concat(list.slice(450)) : list;
			}
			root.live = root.live.concat([root.speed]).slice(-120);
			root.curveTick += 1;
		}
		onRunningChanged: if (!running) root.live = []
	}

	// ── statistics ──────────────────────────────────────────────────────────
	// { since, totals: { boost|normal|torrent: { count, bytes, seconds, saved } },
	//   days: { "yyyy-MM-dd": { boost|normal|torrent: { count, bytes, seconds } } },
	//   hosts: { host: { count, bytes, boost, normal, seconds, ranges } }, recent: [entry] }
	// entry: { at, name, host, bytes, seconds, average, peak, mode, connections, single, saved, note }
	property var stats: root.emptyStats()
	readonly property var kinds: ["boost", "normal", "torrent"]

	function emptyStats() {
		return { since: Date.now(), totals: {}, days: {}, hosts: {}, recent: [] };
	}

	function kindOf(item) {
		if (item.source === "torrent") return "torrent";
		return item.source === "boost" && item.mode === "boost" ? "boost" : "normal";
	}

	function record(item) {
		const kind = root.kindOf(item);
		const curve = root.curves[item.key] || [];
		const bytes = Math.max(item.total, item.received);
		if (!(bytes > 0)) return;
		// running time: the accelerator counts it itself, else start to end
		const seconds = Math.max(0.5, item.activeTime > 0 ? item.activeTime : ((item.finished || Date.now()) - item.started) / 1000);
		const average = bytes / seconds;
		const peak = Math.max(item.peak || 0, ...curve, 0);
		// how long the fastest connection alone would have taken
		const single = kind === "boost" && item.bestSingle > 0 ? item.bestSingle : 0;
		const saved = single > 0 ? Math.max(0, bytes / single - seconds) : 0;
		const entry = {
			at: Date.now(), name: item.name, host: item.host || root.hostOf(item.url || ""), bytes: bytes, seconds: Math.round(seconds * 10) / 10,
			average: Math.round(average), peak: Math.round(peak), mode: kind, connections: item.most || (kind === "boost" ? item.connections : 1),
			single: Math.round(single), saved: Math.round(saved), note: item.note || ""
		};
		const next = JSON.parse(JSON.stringify(root.stats));
		const add = (bucket, extra) => {
			const out = bucket || { count: 0, bytes: 0, seconds: 0, saved: 0 };
			out.count += 1;
			out.bytes += bytes;
			out.seconds += seconds;
			out.saved = (out.saved || 0) + saved;
			return Object.assign(out, extra || {});
		};
		next.totals[kind] = add(next.totals[kind]);
		const day = Qt.formatDate(new Date(), "yyyy-MM-dd");
		next.days[day] = next.days[day] || {};
		next.days[day][kind] = add(next.days[day][kind]);
		// a month of days is enough
		const days = Object.keys(next.days).sort();
		for (const old of days.slice(0, Math.max(0, days.length - 60))) delete next.days[old];
		if (entry.host !== "" && kind !== "torrent") {
			const host = next.hosts[entry.host] || { count: 0, bytes: 0, boost: 0, normal: 0, seconds: 0 };
			host.count += 1;
			host.bytes += bytes;
			host.seconds += seconds;
			host[kind] += 1;
			next.hosts[entry.host] = host;
			const names = Object.keys(next.hosts);
			if (names.length > 80) {
				names.sort((a, b) => next.hosts[a].count - next.hosts[b].count);
				for (const name of names.slice(0, names.length - 80)) delete next.hosts[name];
			}
		}
		next.recent = [entry].concat(next.recent || []).slice(0, 300);
		root.stats = next;
		statsFile.setText(JSON.stringify(next) + "\n");
	}

	function resetStats() {
		root.stats = root.emptyStats();
		statsFile.setText(JSON.stringify(root.stats) + "\n");
	}

	// the figures of one kind, all of them or `days` back from today
	function totals(kind, days) {
		if (!(days > 0)) return root.stats.totals[kind] || { count: 0, bytes: 0, seconds: 0, saved: 0 };
		const out = { count: 0, bytes: 0, seconds: 0, saved: 0 };
		const today = new Date();
		for (let back = 0; back < days; back += 1) {
			const bucket = root.stats.days[Qt.formatDate(new Date(today.getTime() - back * 86400000), "yyyy-MM-dd")]?.[kind];
			if (!bucket) continue;
			out.count += bucket.count;
			out.bytes += bucket.bytes;
			out.seconds += bucket.seconds;
			out.saved += bucket.saved || 0;
		}
		return out;
	}

	// the last `count` days, oldest first: [{ day, label, boost, normal, torrent }] in bytes
	function dayList(count) {
		const out = [];
		const today = new Date();
		for (let back = count - 1; back >= 0; back -= 1) {
			const date = new Date(today.getTime() - back * 86400000);
			const bucket = root.stats.days[Qt.formatDate(date, "yyyy-MM-dd")] || {};
			out.push({
				day: Qt.formatDate(date, "yyyy-MM-dd"), label: back === 0 ? "Today" : Qt.formatDate(date, "ddd"), date: Qt.formatDate(date, "d MMM"),
				boost: bucket.boost?.bytes || 0, normal: bucket.normal?.bytes || 0, torrent: bucket.torrent?.bytes || 0,
				count: (bucket.boost?.count || 0) + (bucket.normal?.count || 0) + (bucket.torrent?.count || 0)
			});
		}
		return out;
	}

	FileView {
		id: statsFile

		path: Paths.stateFile("downloads-stats.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(String(text() || "{}"));
				if (data && data.totals) root.stats = Object.assign(root.emptyStats(), data);
			} catch (error) {}
		}
	}

	onStarted: item => {
		if (root.popOnStart && !root.shown) root.openPanel();
	}

	// ── what the panel does ─────────────────────────────────────────────────
	function send(key, cmd) {
		const item = root.table[key];
		if (item?.source === "torrent") {
			if (cmd === "pause") Torrents.pause(item.id);
			else if (cmd === "resume") Torrents.resume(item.id);
			else if (cmd === "cancel") Torrents.remove(item.id, item.state !== "done");
			return;
		}
		if (item?.source === "boost") {
			if (cmd === "pause") Boost.pause(item.id);
			else if (cmd === "resume") Boost.resume(item.id);
			else if (cmd === "cancel") Boost.cancel(item.id);
			return;
		}
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
		const item = root.table[key];
		// a failed accelerated one is still held by the daemon, with what it got so far
		if (item?.source === "boost" && item.state !== "done") Boost.cancel(item.id);
		root.drop(key);
		root.unseen = Math.min(root.unseen, root.order.filter(other => root.table[other].state === "done").length);
	}

	function seen() {
		root.unseen = 0;
	}

	function open(key) {
		const item = root.table[key];
		if (!item || item.state !== "done") return;
		// a video plays in the shell's own player at once, without the trip through xdg-open
		if (Video.isDefault && Video.isVideo(item.path)) return Video.open(item.path);
		Quickshell.execDetached(["xdg-open", item.path]);
	}

	// a finished video, in the shell's own player even when it is not the default
	function play(key) {
		const item = root.table[key];
		if (item && item.state === "done" && Video.enabled && Video.isVideo(item.path)) Video.open(item.path);
	}

	// the file manager, with the file picked where it can do that
	function reveal(key) {
		const item = root.table[key];
		if (!item || item.path === "") return;
		const folder = item.path.slice(0, item.path.lastIndexOf("/")) || "/";
		const manager = root.managers.includes(root.fileManager) ? root.fileManager : "auto";
		if (manager === "auto") {
			const uri = Format.fileUri(item.path);
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

	// a failed one, from the start once more: the accelerator for its own, the browser for the rest
	function retry(key) {
		const item = root.table[key];
		if (!item) return;
		if (item.source === "boost") return Boost.resume(item.id);
		if (item.url === "") return;
		if (Boost.enabled) Boost.add(item.url);
		else root.fetchInBrowser(item.url);
		root.dismiss(key);
	}

	// the link handed to a connected browser to download as it would
	function fetchInBrowser(url) {
		const link = Object.values(root.links)[0];
		if (!link || !url) return false;
		link.write(JSON.stringify({ type: "cmd", cmd: "fetch", url: url }) + "\n");
		link.flush();
		return true;
	}

	function copyLink(key) {
		const url = root.table[key]?.url ?? "";
		if (url !== "") Quickshell.execDetached(["wl-copy", "--", url]);
	}

	function hostOf(url) {
		const match = /^[a-z]+:\/\/([^/:?#]+)/i.exec(url);
		return match ? match[1].replace(/^www\./, "") : "";
	}

	function set(name, value) {
		if (name === "hideWhenIdle") root.hideWhenIdle = !!value;
		else if (name === "boost") root.boost = !!value;
		else if (name === "popOnStart") root.popOnStart = !!value;
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
			boost: root.boost, popOnStart: root.popOnStart, offering: root.offering,
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
				root.boost = data.boost !== false;
				root.popOnStart = data.popOnStart === true;
				root.offering = data.offering === true;
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

		running: root.listening
		command: ["mkdir", "-p", Paths.runtime]
		onExited: server.active = Qt.binding(() => root.listening)
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
