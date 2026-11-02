pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications
import qs.style.theme

// What the user follows (plugin "streams"): channels and feeds, who is live,
// series put together by rules and how far they were watched. The looking and
// deciding runs in a daemon of its own (scripts/streams/daemon.py); this is
// the shell's end of it, and the one place its notifications go through.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("streams")
	readonly property string daemon: `${Paths.scripts}/streams/daemon.py`
	readonly property string socketPath: `${Paths.runtime}/streams.sock`

	property bool connected: false

	// as the daemon last told (scripts/streams/daemon.py: state())
	property var sources: []
	property var series: []
	property var liveStreams: []
	property var raids: []
	property var inbox: []
	property var plan: []
	// series a channel seems to run, newest videos first: { key, source, sourceName, avatar, colors, name, kind, rule, playlist, numbered, why, count, seconds, newest, oldest, pictures, latest }
	property var discoveries: []
	// what Explore and the home page show: with "detected", no suggestion that is
	// only a playlist. One that titles, tags or descriptions point at as well stays.
	readonly property var shownDiscoveries: root.settings.exploreKinds === "detected" ? root.discoveries.filter(item => root.isDetected(item)) : root.discoveries
	// how far reading the channels got: { done, total, now, paused }
	property var scan: ({})
	property var playing: null
	property var settings: ({})
	property var keys: ({})
	property bool hasMpv: false
	// grows whenever a video comes or gets watched
	property real feedStamp: 0
	// what the built-in player plays: { video, title, thumb, large, start, duration, live, series, seriesName, channel, avatar, chapters, url }
	property var player: null
	// the character sheets being made: { series, done, total, name, field }
	property var sheetsJob: null
	property var recapJob: null
	// recaps being written for the story of a series: { series, done, total }
	property var storyJob: null
	// what >said looks for once the page is open
	property string saidWanted: ""
	property string bookTabWanted: ""
	// a panel of the player to open from outside (ipc)
	property string playerPanelWanted: "-"
	// small in a corner while the app goes on behind it
	property bool playerMini: false
	// what the player is waiting for: { key, step }
	property var loadingStep: null
	// what listening to a video found: { silences, gains, intro, outro }
	property var playerMarks: ({})
	property var chatLines: []
	property var together: ({})
	// inside the streams window when that is open, else in a window of its own
	readonly property bool playerInside: root.windowOpen && !root.panelled

	readonly property var seriesById: {
		const out = {};
		for (const item of root.series) out[item.id] = item;
		return out;
	}
	readonly property var sourceById: {
		const out = {};
		for (const item of root.sources) out[item.id] = item;
		return out;
	}
	// the channels the user added; a series' playlist is no source of theirs
	readonly property var ownSources: root.sources.filter(item => !item.hidden)
	readonly property var openSeries: root.series.filter(item => item.status === "active" && item.left > 0)
		.sort((a, b) => (b.lastWatched || 0) - (a.lastWatched || 0) || (b.lastEpisode || 0) - (a.lastEpisode || 0))
	readonly property int liveCount: root.liveStreams.length
	readonly property int freshCount: root.series.reduce((sum, item) => sum + (item.status === "active" ? item.fresh : 0), 0)
	readonly property string playingSeries: root.playing?.series ?? ""

	// what comes after this video: { video, title, thumb, seconds, left, via }
	property var upNext: null
	property real upNextAt: 0
	property var signin: null

	signal seriesCompleted(string id, string name, int total)
	signal skipped(real seconds)
	signal notified
	signal togetherState(var state)
	signal sheetChanged(string series)
	signal sheetError(string series, string error)
	// from the session bus: media keys, the bar, the phone, the watch (mpris.py)
	signal playerCommand(string what, real value)

	// ── where it shows ─────────────────────────────────────────────────────
	property alias surface: popout
	property alias windowOpen: popout.windowOpen
	property alias windowed: popout.windowed
	readonly property bool panelled: popout.panelled
	readonly property bool shown: popout.shown
	// what to show once it is open: { page, series, tonight, newSeries: { … } }
	property var wanted: null

	Popout {
		id: popout

		popup: "streams"
		panel: Plugins.on("streams-bar")
		windowed: true
	}

	function open(wanted) {
		if (!root.enabled) return;
		if (wanted) root.wanted = wanted;
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

		path: Paths.stateFile("streams-ui.json")
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(String(text() || "{}"));
				if (data.windowed !== undefined) root.windowed = !!data.windowed;
			} catch (error) {}
		}
	}

	// ── asking ─────────────────────────────────────────────────────────────
	property int lastId: 0
	property var callbacks: ({})
	property var queued: []

	function call(op, args, done) {
		const rid = ++root.lastId;
		const message = Object.assign({}, args || {}, { rid: rid, op: op });
		if (done) root.callbacks[rid] = done;
		if (root.connected && root.socket) root.write(message);
		else {
			root.queued.push(message);
			root.wake();
		}
	}

	function write(message) {
		root.socket.write(JSON.stringify(message) + "\n");
		root.socket.flush();
	}

	function receive(line) {
		let message;
		try {
			message = JSON.parse(line);
		} catch (error) {
			return;
		}
		if (message.event) return root.event(message);
		const done = root.callbacks[message.rid];
		if (done) {
			delete root.callbacks[message.rid];
			done(message.ok ? message.data : null, message.ok ? "" : String(message.error || "That went wrong"));
		}
	}

	function event(message) {
		switch (message.event) {
		case "state": {
			const state = message.state;
			root.sources = state.sources;
			root.series = state.series;
			root.liveStreams = state.live.streams;
			root.raids = state.live.raids;
			root.inbox = state.inbox;
			root.plan = state.plan;
			root.discoveries = state.discoveries;
			root.scan = state.scan;
			root.playing = state.playing;
			root.settings = state.settings;
			root.keys = state.keys;
			root.hasMpv = state.mpv;
			root.feedStamp = state.feedStamp;
			root.together = state.together;
			root.sheetsJob = state.sheetsJob;
			root.recapJob = state.recapJob;
			root.storyJob = state.storyJob;
			break;
		}
		case "notify":
			root.tell(message);
			break;
		case "open":
			Browser.open(message.url);
			break;
		case "player":
			root.playerMini = false;
			root.playerMarks = {};
			root.chatLines = [];
			root.loadingStep = null;
			root.player = message;
			break;
		case "player-stop":
			root.player = null;
			break;
		case "player-command":
			root.playerCommand(message.what, Number(message.value) || 0);
			break;
		case "loading":
			root.loadingStep = message;
			break;
		case "marks":
			if (root.player?.video === message.video) root.playerMarks = message.marks;
			break;
		case "chat":
			root.chatLines = root.chatLines.concat(message.lines).slice(-150);
			break;
		case "sheet-changed":
			root.sheetChanged(message.series);
			break;
		case "sheets-error":
			root.sheetError(message.series, message.error);
			break;
		case "together":
			root.togetherState(message);
			break;
		case "upnext":
			root.upNext = message;
			root.upNextAt = Date.now();
			break;
		case "upnext-done":
			root.upNext = null;
			break;
		case "complete":
			root.seriesCompleted(message.series, message.name, message.total);
			break;
		case "skipped":
			root.skipped(message.seconds);
			break;
		case "signin":
			root.signin = message.state === "done" || message.state === "failed" ? null : message;
			if (message.state === "done") Notifs.pushInternal("done", "Twitch connected", "Follows and raids can be used now", { icon: "check" });
			else if (message.state === "failed") Notifs.pushInternal("error", "Twitch", "The sign-in ran out of time");
			break;
		case "raid":
			root.tell({ kind: "raid", title: `${message.name} raids ${message.to}`, body: message.viewers ? `With ${message.viewers} viewers. Go along?` : "Go along?", url: message.url, video: "", series: "", image: "" });
			break;
		}
	}

	// ── what the user is told ──────────────────────────────────────────────
	// while a game runs it waits and comes as one message afterwards
	property var held: []

	function tell(note) {
		root.notified();
		if (GameMode.active) {
			root.held = root.held.concat([note]);
			return;
		}
		root.post(note);
	}

	function post(note) {
		const actions = [];
		const watch = () => {
			if (note.video) root.play(note.video);
			else if (note.url) Browser.open(note.url);
			else if (note.series) root.open({ page: "series", series: note.series });
			else root.open({ page: "now" });
		};
		actions.push({ identifier: "default", text: "", invoke: watch });
		if (note.url || note.video) actions.push({ text: "Watch", invoke: watch });
		if (note.kind === "live" && note.series) actions.push({ text: "Catch up first", invoke: () => root.open({ page: "series", series: note.series }) });
		else if (note.kind === "video" && note.series) actions.push({ text: "Later", invoke: () => {} });
		Notifs.post({ app: "Streams", icon: "play_circle", image: note.image || "", summary: note.title, body: note.body, actions: actions });
	}

	Connections {
		target: GameMode

		function onActiveChanged() {
			// reading the channels waits while a game runs
			if (root.connected) root.call("quiet", { on: GameMode.active });
			if (GameMode.active || root.held.length === 0) return;
			const notes = root.held;
			root.held = [];
			if (notes.length === 1) return root.post(notes[0]);
			const live = notes.filter(note => note.kind === "live").map(note => note.title.replace(/ is live$/, ""));
			const fresh = notes.filter(note => note.kind === "video" || note.kind === "videos").length;
			const parts = [];
			if (fresh) parts.push(`${fresh} new ${fresh === 1 ? "episode" : "episodes"}`);
			if (live.length) parts.push(`${live.join(", ")} went live`);
			root.post({ kind: "digest", title: "While you played", body: parts.join(" · ") || `${notes.length} things happened`, url: "", video: "", series: "", image: notes[0].image });
		}
	}

	// ── doing ──────────────────────────────────────────────────────────────
	function report(done, doneText) {
		return (data, error) => {
			if (error) Notifs.pushInternal("error", "Streams", error);
			else if (doneText) Notifs.pushInternal("done", doneText, "", { icon: "check" });
			if (done) done(data, error);
		};
	}

	// a click finds it ready: asked ahead for what is likely next
	property var asked: ({})

	function prefetch(videos) {
		const fresh = videos.filter(video => video && !root.asked[video]);
		if (fresh.length === 0) return;
		for (const video of fresh) root.asked[video] = true;
		root.call("prefetch", { videos: fresh });
	}

	onOpenSeriesChanged: root.prefetch(root.openSeries.slice(0, 3).map(item => item.next?.id))

	function play(video, player, queue) {
		const args = { video: video };
		if (player) args.player = player;
		if (queue) args.queue = queue;
		root.call("play", args, root.report());
	}

	function playNext(seriesId, player) {
		const item = root.seriesById[seriesId];
		if (item?.next) root.play(item.next.id, player);
	}

	function playLive(source, options) {
		root.call("playLive", Object.assign({ source: source }, options || {}), root.report());
	}

	function mark(video, watched, upTo) {
		root.call("mark", { video: video, watched: watched, upTo: upTo || "" }, root.report());
	}

	function teach(seriesId, video, answer) {
		root.call("teach", { series: seriesId, video: video, answer: answer }, root.report());
	}

	function updateSeries(id, changes) {
		root.call("updateSeries", Object.assign({}, changes, { id: id }), root.report());
	}

	// the channels merged with this one, itself among them
	function groupOf(id) {
		const group = root.sourceById[id]?.group ?? "";
		return group ? root.ownSources.filter(item => item.group === group) : (root.sourceById[id] ? [root.sourceById[id]] : []);
	}

	function updateSource(id, changes) {
		root.call("updateSource", Object.assign({}, changes, { id: id }), root.report());
	}

	function setSetting(name, value) {
		const args = {};
		args[name] = value;
		root.call("settings", args, root.report());
	}

	// a followed part does not vanish at once: the list says so itself
	function followPart(part, done) {
		root.call("followPart", { name: part.name, source: part.source, rule: part.rule, ids: part.ids }, root.report(done));
	}

	// behind the pages: docked, the panel's own fading background shows through
	readonly property color pageColor: root.panelled ? "transparent" : Theme.base

	function isDetected(item) {
		return item.kind !== "playlist" || item.detected || item.parts.length > 0;
	}

	function followDiscovery(key, done) {
		root.call("followDiscovery", { key: key }, root.report(done));
	}

	// a suggestion in the workshop, to change something before following it
	function adjustDiscovery(item) {
		const open = playlist => root.open({ newSeries: { name: item.name, sources: item.sources ?? [item.source], playlist: playlist, rule: item.rule } });
		if (!item.playlist) return open("");
		root.call("add", { input: `https://www.youtube.com/playlist?list=${item.playlist}`, hidden: true }, root.report(data => {
			if (data) open(data.id);
		}));
	}

	function answerNext(play) {
		root.call("next", { play: play });
		root.upNext = null;
	}

	function toPhone(url, position, title) {
		if (Plugins.on("phone")) Phone.sendUrl(url, position, title);
	}

	// a link from anywhere (shelf, clipboard): the window, ready to follow it
	function follow(link) {
		root.open({ page: "sources", add: String(link) });
	}

	readonly property bool looksLikeLink: false

	function isFollowable(text) {
		return /^(https?:\/\/)?(www\.|m\.)?(youtube\.com|youtu\.be|twitch\.tv)\/\S+$/i.test(String(text).trim());
	}

	// ── how things read ────────────────────────────────────────────────────
	function span(seconds) {
		const minutes = Math.round(Number(seconds || 0) / 60);
		if (minutes < 1) return "under a minute";
		if (minutes < 60) return `${minutes} min`;
		const rest = minutes % 60;
		return rest ? `${Math.floor(minutes / 60)} h ${rest} min` : `${Math.floor(minutes / 60)} h`;
	}

	function clock(seconds) {
		const total = Math.max(0, Math.floor(Number(seconds || 0)));
		const hours = Math.floor(total / 3600);
		const minutes = Math.floor(total / 60) % 60;
		const rest = String(total % 60).padStart(2, "0");
		return hours > 0 ? `${hours}:${String(minutes).padStart(2, "0")}:${rest}` : `${minutes}:${rest}`;
	}

	function ago(stamp) {
		const seconds = Date.now() / 1000 - Number(stamp || 0);
		if (!stamp) return "";
		if (seconds < 90) return "just now";
		if (seconds < 3600) return `${Math.round(seconds / 60)} min ago`;
		if (seconds < 86400) return `${Math.round(seconds / 3600)} h ago`;
		if (seconds < 86400 * 14) return `${Math.round(seconds / 86400)} days ago`;
		if (seconds < 86400 * 60) return `${Math.round(seconds / 86400 / 7)} weeks ago`;
		return Qt.formatDate(new Date(stamp * 1000), "d MMM yyyy");
	}

	function forecast(stamp) {
		if (!stamp) return "";
		const days = Math.round((stamp - Date.now() / 1000) / 86400);
		if (days <= 0) return "Caught up today at this pace";
		if (days === 1) return "Caught up tomorrow at this pace";
		if (days < 7) return `Caught up on ${Qt.formatDate(new Date(stamp * 1000), "dddd")} at this pace`;
		if (days > 180) return "";
		return `Caught up by ${Qt.formatDate(new Date(stamp * 1000), "d MMMM")} at this pace`;
	}

	// the largest picture of a YouTube video; not every video has one (Thumb falls back)
	function large(video) {
		const id = String(video || "");
		return /^[\w-]{11}$/.test(id) ? `https://i.ytimg.com/vi/${id}/maxresdefault.jpg` : "";
	}

	function accent(colors) {
		return colors?.accent ? Theme.legible(colors.accent, 3.0) : Theme.primary;
	}

	function picture(path) {
		const text = String(path || "");
		if (!text) return "";
		return text.startsWith("/") ? `file://${text}` : text;
	}

	// ── the line to the daemon ─────────────────────────────────────────────
	property var socket: null
	property int attempts: 0

	onEnabledChanged: root.enabled ? root.wake() : root.hangUp()
	Component.onCompleted: if (root.enabled) wakeSoon.start()

	Timer {
		id: wakeSoon

		interval: 1500
		onTriggered: root.wake()
	}

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
					root.connected = true;
					root.attempts = 0;
					retry.stop();
					const waiting = root.queued;
					root.queued = [];
					root.write({ rid: 0, op: "hello" });
					for (const message of waiting) root.write(message);
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
		retry.stop();
		root.connected = false;
		if (root.socket) root.socket.destroy();
		root.socket = null;
	}

	function dropped() {
		root.connected = false;
		const waiting = root.callbacks;
		root.callbacks = {};
		for (const id of Object.keys(waiting)) {
			if (!root.queued.some(message => message.rid === Number(id))) waiting[id](null, "The streams daemon went away");
			else root.callbacks[id] = waiting[id];
		}
		if (root.enabled) root.wake();
	}

	function wake() {
		if (!root.enabled || root.connected) return;
		if (!daemonProc.running) daemonProc.running = true;
		if (!retry.running) {
			root.attempts = 0;
			retry.start();
		}
	}

	Process {
		id: daemonProc

		command: ["python3", root.daemon]
		stderr: StdioCollector {
			onStreamFinished: if (String(text).trim() !== "") console.warn("streams daemon:", String(text).trim().slice(-400))
		}
	}

	Timer {
		id: retry

		interval: root.attempts < 12 ? 200 : 2000
		repeat: true
		onTriggered: {
			if (!root.enabled || root.connected) return retry.stop();
			root.attempts += 1;
			root.dial();
		}
	}

	// keeps the daemon alive for as long as the shell is: the socket does that;
	// a picture in picture gets quieter while something else has the focus
	Connections {
		target: Niri
		enabled: root.connected

		function onFocusedIdChanged() {
			const focused = (Niri.windows ?? []).find(window => Number(window.id) === Niri.focusedId);
			root.call("pipVolume", { volume: focused?.app_id === "pshell-streams-pip" ? 100 : 45 });
		}
	}
}
