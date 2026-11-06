pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// The shell's music player (plugin "music", `music-default` makes it what
// music opens in): a window of its own (core/views/music/). mpv plays,
// headless, steered by a helper (scripts/music/music.py) that holds the
// queue as mpv's playlist (so songs follow without a gap), reads the tags,
// the cover and the waveform, finds the words and puts the player on the
// session bus – the bar, the media panel, media keys, the phone and the
// watch see and steer it through Media like any other. Music goes on when
// the window closes. The position is counted here from what mpv last said,
// not asked for again and again.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("music")
	readonly property string helperScript: `${Paths.scripts}/music/music.py`
	readonly property string windowTitle: root.current ? `${root.titleOf(root.path)} – Music` : "Music"

	// ── what plays ─────────────────────────────────────────────────────────
	property bool windowOpen: false
	property var queue: []
	property int index: -1
	property string path: ""
	readonly property bool current: root.path !== ""
	property bool playing: false
	property bool idle: true
	property real duration: 0
	property real speed: 1
	property real volume: 100
	// "off" | "all" | "one"
	property string repeatMode: "off"
	property bool shuffled: false
	// [{ t, title }] of an audiobook, mpv's own reading
	property var chapters: []
	property int chapter: -1
	// what mpv hears: { samplerate, channels, format }
	property var audio: ({})
	// which way the last change of song went (the next cover slides in from there)
	property int direction: 1

	// path → { title, artist, album, track, year, duration, codec, rate, bits, kbps, chapters }
	property var tags: ({})
	// path → { art, accent }
	property var covers: ({})
	readonly property var song: root.tags[root.path] ?? null
	readonly property string art: root.covers[root.path]?.art ?? ""
	readonly property string accentHex: root.covers[root.path]?.accent ?? ""

	function titleOf(path) {
		const t = root.tags[path];
		if (t?.title) return t.title;
		const name = String(path).slice(String(path).lastIndexOf("/") + 1);
		return name.replace(/\.[^.]+$/, "");
	}

	function formatTime(seconds) {
		const total = Math.max(0, Math.floor(Number(seconds) || 0));
		const h = Math.floor(total / 3600), m = Math.floor(total / 60) % 60, s = total % 60;
		const ss = s < 10 ? `0${s}` : String(s);
		return h > 0 ? `${h}:${m < 10 ? "0" : ""}${m}:${ss}` : `${m}:${ss}`;
	}

	function artistOf(path) {
		return root.tags[path]?.artist ?? "";
	}

	// ── the position, counted on from the last word of mpv ─────────────────
	property real basePosition: 0
	property real baseAt: 0
	property real position: 0
	readonly property real progress: root.duration > 0 ? Math.min(1, root.position / root.duration) : 0
	// the window shows it smoothly, the bus and the bar need it seldom
	property bool watching: false

	function positionNow() {
		if (!root.playing) return root.basePosition;
		return Math.min(root.duration || 1e9, root.basePosition + (Date.now() - root.baseAt) / 1000 * root.speed);
	}

	Timer {
		running: root.playing
		repeat: true
		interval: root.watching ? 50 : 1000
		triggeredOnStart: true
		onTriggered: root.position = root.positionNow()
	}

	// ── side things ────────────────────────────────────────────────────────
	// the loudness of the song along its length, 0..1 each
	property var wave: []
	property string waveOf: ""
	// { state: "" | "loading" | "found" | "none" | "error", synced, lines: [{ t, text }], source }
	property var lyrics: ({ state: "" })
	property string lyricsOf: ""
	readonly property int lyricLine: {
		const lines = root.lyrics.lines ?? [];
		if (!root.lyrics.synced || lines.length === 0) return -1;
		const at = root.position + 0.25;
		let low = 0, high = lines.length - 1, found = -1;
		while (low <= high) {
			const middle = (low + high) >> 1;
			if (lines[middle].t <= at) {
				found = middle;
				low = middle + 1;
			} else high = middle - 1;
		}
		return found;
	}
	readonly property int chapterNow: {
		let found = -1;
		for (let i = 0; i < root.chapters.length; i += 1)
			if (root.chapters[i].t <= root.position + 0.05) found = i;
		return found;
	}

	// ── settings ───────────────────────────────────────────────────────────
	// pane: "queue" | "lyrics" | "" (beside the cover)
	property var settings: ({ pane: "queue", visualizer: true, ambient: true, notify: true })

	function setting(name, fallback) {
		const value = root.settings[name];
		return value === undefined ? fallback : value;
	}

	function setSetting(name, value) {
		root.settings = Object.assign({}, root.settings, { [name]: value });
		settingsFile.setText(JSON.stringify(root.settings, null, 2) + "\n");
	}

	FileView {
		id: settingsFile

		path: Paths.stateFile("music.json")
		printErrors: false
		onLoaded: {
			try {
				root.settings = Object.assign({}, root.settings, JSON.parse(String(text() || "{}")));
			} catch (error) {}
		}
	}

	readonly property string pane: root.setting("pane", "queue")

	function showPane(name) {
		root.setSetting("pane", root.pane === name ? "" : name);
	}

	// ── opening ────────────────────────────────────────────────────────────
	// open(path, { list: [paths], start: seconds, paused, from }) – without a
	// list the songs of its folder follow it
	function open(path, options) {
		if (!root.enabled || !path) return;
		const o = options || {};
		path = root.plainPath(path);
		root.windowOpen = true;
		root.focusWindow();
		if (o.list && o.list.length > 0) {
			const list = o.list.map(p => root.plainPath(p));
			root.request("open", { paths: list, index: Math.max(0, list.indexOf(path)), start: o.start || 0, paused: !!o.paused });
			return;
		}
		// at once with this one, its folder comes around it
		root.request("folder", { path: path }, data => {
			const list = data?.paths?.length > 0 ? data.paths : [path];
			const i = list.indexOf(path);
			// a folder: its first song
			root.request("open", { paths: list, index: Math.max(0, i), start: i >= 0 ? (o.start || 0) : 0, paused: !!o.paused });
		});
	}

	// several songs (from the desktop, Files with many picked): one alone takes its folder
	function openMany(paths) {
		const list = (paths || []).map(p => root.plainPath(p)).filter(p => p);
		if (list.length === 0) return;
		if (list.length === 1) return root.open(list[0]);
		root.open(list[0], { list: list });
	}

	// into the queue: at its end, or next
	function add(paths, next) {
		const list = (paths || []).map(p => root.plainPath(p)).filter(p => p);
		if (list.length === 0 || !root.enabled) return;
		const empty = root.idle || root.queue.length === 0;
		root.request("add", { paths: list, next: !!next });
		if (empty) {
			root.windowOpen = true;
			root.focusWindow();
		} else root.say(list.length === 1 ? `${root.titleOf(list[0])} ${next ? "plays next" : "is in the queue"}` : `${list.length} songs ${next ? "play next" : "are in the queue"}`, next ? "playlist_play" : "playlist_plus");
	}

	function plainPath(path) {
		let p = String(path).replace(/^file:\/\//, "");
		try {
			p = decodeURIComponent(p);
		} catch (error) {}
		return p;
	}

	// the cover of a song further down the queue, read when its row shows
	property var coverAsked: ({})

	function wantCover(path) {
		if (!path || root.covers[path] || root.coverAsked[path]) return;
		root.coverAsked[path] = true;
		root.request("cover", { path: path });
	}

	// ── steering ───────────────────────────────────────────────────────────
	function toggle() {
		if (root.queue.length === 0) return root.showWindow();
		root.request("toggle");
	}

	function play() {
		root.request("play");
	}

	function pause() {
		root.request("pause");
	}

	function next() {
		root.direction = 1;
		root.request("next");
	}

	function previous() {
		root.direction = -1;
		root.request("previous");
	}

	function seek(seconds) {
		const to = Math.max(0, Math.min(root.duration > 0 ? root.duration - 0.2 : 1e9, Number(seconds) || 0));
		root.basePosition = to;
		root.baseAt = Date.now();
		root.position = to;
		root.request("seek", { to: to });
	}

	function seekBy(delta) {
		root.seek(root.positionNow() + delta);
	}

	function jump(i) {
		root.direction = i >= root.index ? 1 : -1;
		root.request("jump", { index: i });
	}

	function move(from, to) {
		if (from === to) return;
		// at once here, the helper says the same a moment later
		const next = root.queue.slice();
		next.splice(to, 0, next.splice(from, 1)[0]);
		root.queue = next;
		root.request("move", { from: from, to: to });
	}

	function remove(i) {
		root.request("remove", { index: i });
	}

	function stop() {
		root.request("stop");
	}

	function setSpeed(value) {
		root.request("speed", { value: Math.round(Number(value) * 100) / 100 });
	}

	function setVolume(value) {
		root.volume = Math.max(0, Math.min(130, Number(value)));
		root.request("volume", { value: root.volume });
	}

	function cycleRepeat() {
		root.request("repeat", { mode: root.repeatMode === "off" ? "all" : (root.repeatMode === "all" ? "one" : "off") });
	}

	function toggleShuffle() {
		root.request("shuffle", { on: !root.shuffled });
	}

	// ── sleeping ───────────────────────────────────────────────────────────
	// ms since the epoch when the music fades out, -1 after this song, 0 never
	property real sleepAt: 0
	property string sleepSong: ""

	function sleep(minutes) {
		const m = Number(minutes);
		if (m < 0) {
			root.sleepAt = -1;
			root.sleepSong = root.path;
			root.say("The music stops after this song", "sleep");
		} else if (m > 0) {
			root.sleepAt = Date.now() + m * 60000;
			root.say(`The music fades out in ${m} minutes`, "sleep");
		} else {
			root.sleepAt = 0;
			fade.stop();
		}
	}

	Timer {
		running: root.sleepAt > 0 && root.playing
		repeat: true
		interval: 1000
		onTriggered: if (Date.now() >= root.sleepAt) root.fadeOut()
	}

	property real fadeFrom: 100
	property real fadeLevel: 1

	function fadeOut() {
		root.sleepAt = 0;
		root.fadeFrom = root.volume;
		fade.start();
	}

	NumberAnimation {
		id: fade

		target: root
		property: "fadeLevel"
		from: 1
		to: 0
		duration: 12000
		onStopped: {
			root.pause();
			root.request("volume", { value: root.fadeFrom });
			root.fadeLevel = 1;
		}
	}

	onFadeLevelChanged: if (fade.running) root.request("volume", { value: Math.round(root.fadeFrom * root.fadeLevel * 10) / 10 })

	// ── the window ─────────────────────────────────────────────────────────
	function showWindow() {
		if (!root.enabled) return;
		root.windowOpen = true;
		root.focusWindow();
		// started as an app with nothing to play: the queue as it was left
		if (root.queue.length === 0) root.request("resume");
	}

	function close() {
		root.windowOpen = false;
	}

	function toggleWindow() {
		if (root.windowOpen) root.close();
		else root.showWindow();
	}

	function focusWindow() {
		focusTimer.restart();
	}

	function niriWindow() {
		return Niri.windows.find(window => /( – Music|^Music)$/.test(String(window.title)) && /quickshell/i.test(String(window.app_id))) ?? null;
	}

	Timer {
		id: focusTimer

		interval: 80
		onTriggered: {
			const window = root.niriWindow();
			if (window && !window.is_focused) Niri.focusWindow(window.id);
		}
	}

	// small (a strip with the cover and the keys) or as it was before
	property bool mini: false
	property size bigSize: Qt.size(1040, 640)

	function toggleMini(width, height) {
		const window = root.niriWindow();
		if (!window) return;
		if (!root.mini) root.bigSize = Qt.size(width, height);
		root.mini = !root.mini;
		const w = root.mini ? 440 : root.bigSize.width;
		const h = root.mini ? 132 : root.bigSize.height;
		Niri.inOrder([
			["niri", "msg", "action", "set-window-width", "--id", String(window.id), String(Math.round(w))],
			["niri", "msg", "action", "set-window-height", "--id", String(window.id), String(Math.round(h))]
		]);
	}

	// ── what the helper says ───────────────────────────────────────────────
	onPathChanged: {
		root.wave = [];
		root.position = 0;
		if (!root.path) return;
		const path = root.path;
		root.request("wave", { path: path }, data => {
			if (data && data.path === root.path) {
				root.wave = data.peaks || [];
				root.waveOf = data.path;
			}
		});
		root.lyrics = { state: "" };
		root.lyricsOf = "";
		if (root.pane === "lyrics") root.findLyrics();
		if (root.sleepAt === -1 && root.sleepSong && path !== root.sleepSong) {
			root.sleepAt = 0;
			root.sleepSong = "";
			root.pause();
			root.seek(0);
		}
		root.announce();
	}

	onPaneChanged: if (root.pane === "lyrics") root.findLyrics()

	function findLyrics() {
		if (!root.path || root.lyricsOf === root.path) return;
		const path = root.path;
		root.lyricsOf = path;
		root.lyrics = { state: "loading" };
		root.request("lyrics", { path: path }, (data, error) => {
			if (root.path !== path) return;
			root.lyrics = error ? { state: "error" } : data;
		});
	}

	function receive(line) {
		let m;
		try {
			m = JSON.parse(line);
		} catch (error) {
			return;
		}
		if (m.id !== undefined && m.id !== null) {
			const done = root.callbacks[m.id];
			delete root.callbacks[m.id];
			if (done) done(m.error ? null : m, m.error ?? "");
			return;
		}
		switch (m.event) {
		case "state":
			// which way it went: further down the queue or back up
			if (m.path !== root.path && root.index >= 0 && m.index >= 0 && m.index !== root.index)
				root.direction = m.index > root.index ? 1 : -1;
			root.playing = !!m.playing;
			root.idle = !!m.idle;
			root.index = m.index ?? -1;
			root.duration = Number(m.duration) || 0;
			root.speed = Number(m.speed) || 1;
			if (!fade.running) root.volume = Number(m.volume);
			root.repeatMode = m.repeat || "off";
			root.shuffled = !!m.shuffle;
			root.chapters = m.chapters || [];
			root.chapter = m.chapter ?? -1;
			root.audio = m.audio || {};
			root.basePosition = Number(m.position) || 0;
			// the helper's clock is this one: its position was right at `at`
			root.baseAt = Math.min(Date.now(), Number(m.at) || Date.now());
			root.position = root.positionNow();
			root.path = m.path || "";
			break;
		case "queue":
			root.queue = m.paths || [];
			break;
		case "tags": {
			const next = Object.assign({}, root.tags);
			for (const p in m.items) next[p] = m.items[p];
			root.tags = next;
			break;
		}
		case "cover": {
			const next = Object.assign({}, root.covers);
			next[m.path] = { art: m.art || "", accent: m.accent || "" };
			root.covers = next;
			break;
		}
		case "command":
			if (m.command === "raise") root.showWindow();
			break;
		case "error":
			root.say(m.error || "The music stopped", "alert_circle_outline");
			break;
		}
	}

	// a new song while the window is away: one quiet line
	function announce() {
		if (root.windowOpen && root.watching) return;
		if (!root.playing || !root.setting("notify", true)) return;
		announceTimer.restart();
	}

	Timer {
		id: announceTimer

		// the tags and the cover are read by then
		interval: 700
		onTriggered: {
			if (!root.playing || (root.windowOpen && root.watching)) return;
			Notifs.pushInternal("done", root.titleOf(root.path), root.artistOf(root.path), {
				app: "Music", icon: "music_note", image: root.art, duration: 3500,
				actions: [{ label: "Skip", icon: "skip_next", run: () => root.next() }, { label: "Open", icon: "open_in_new", run: () => root.showWindow() }]
			});
		}
	}

	// ── talking to the helper ──────────────────────────────────────────────
	property int counter: 0
	property var callbacks: ({})
	property var queued: []

	function request(op, args, done) {
		if (!root.enabled) return 0;
		root.counter += 1;
		const id = root.counter;
		if (done) root.callbacks[id] = done;
		const line = JSON.stringify(Object.assign({ id: id, op: op }, args || {})) + "\n";
		if (!helper.running) {
			root.queued.push(line);
			helper.running = true;
		} else helper.write(line);
		idleTimer.restart();
		return id;
	}

	Process {
		id: helper

		stdinEnabled: true
		command: ["python3", "-u", root.helperScript]
		stdout: SplitParser {
			onRead: line => root.receive(line)
		}
		stderr: SplitParser {
			onRead: line => console.warn(`music: ${line}`)
		}
		onRunningChanged: {
			if (!helper.running) return;
			for (const line of root.queued) helper.write(line);
			root.queued = [];
		}
		onExited: {
			for (const id in root.callbacks) root.callbacks[id](null, "The music helper stopped");
			root.callbacks = {};
			root.playing = false;
			root.idle = true;
			root.queue = [];
			root.path = "";
		}
	}

	// the helper (and mpv) go when nothing is queued and the window has been closed a while
	Timer {
		id: idleTimer

		interval: 300000
		onTriggered: {
			if (root.windowOpen || (root.queue.length > 0 && !root.idle) || Object.keys(root.callbacks).length > 0) idleTimer.restart();
			else if (helper.running) helper.write(JSON.stringify({ op: "quit" }) + "\n");
		}
	}

	onWindowOpenChanged: idleTimer.restart()
	onEnabledChanged: {
		if (!root.enabled && helper.running) helper.write(JSON.stringify({ op: "quit" }) + "\n");
		root.applyDefault();
	}

	// ── as an app of the desktop ───────────────────────────────────────────
	// the entry "Pshell Music" is there while the plugin is on; with
	// music-default songs opened anywhere come here (scripts/music/default.py)
	readonly property bool isDefault: root.enabled && Plugins.on("music-default")
	property bool entryInstalled: false

	function applyDefault() {
		if (!root.enabled && !root.entryInstalled) return;
		defaultProc.command = ["python3", `${Paths.scripts}/music/default.py`, !root.enabled ? "remove" : (root.isDefault ? "on" : "off")];
		defaultProc.running = true;
		root.entryInstalled = root.enabled;
	}

	onIsDefaultChanged: root.applyDefault()
	Component.onCompleted: root.applyDefault()

	Process {
		id: defaultProc
	}

	// ── telling ────────────────────────────────────────────────────────────
	signal said(string text, string icon)

	// in the window while it is looked at, else as a toast
	function say(text, icon) {
		if (root.windowOpen && root.watching) root.said(text, icon || "information_outline");
		else Notifs.pushInternal("done", text, "", { app: "Music", icon: icon || "music_note" });
	}
}
