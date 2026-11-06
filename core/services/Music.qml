pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.style.theme

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
	// a stretch played again and again (seconds, -1 none)
	property real loopA: -1
	property real loopB: -1
	readonly property bool looping: root.loopA >= 0 && root.loopB > root.loopA

	// path → { title, artist, album, track, year, duration, codec, rate, bits, kbps, chapters }
	property var tags: ({})
	// path → { art, accent }
	property var covers: ({})
	readonly property var song: root.tags[root.path] ?? null
	readonly property string art: root.covers[root.path]?.art ?? ""
	readonly property string accentHex: root.covers[root.path]?.accent ?? ""

	// names given from outside (a voice message's sender): path → { title, artist }
	property var names: ({})

	function titleOf(path) {
		if (root.names[path]?.title) return root.names[path].title;
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
		if (root.names[path]?.artist) return root.names[path].artist;
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
	// visualizer: "bars" | "ring" | "off"; eq: ten gains in dB; fade: seconds between songs;
	// duckGames: quieter while a game plays; breaks: paused during a break;
	// headphones: on again when they come back; shellAccent: the cover's colour for the whole shell
	property var settings: ({ pane: "queue", visualizer: "bars", ambient: true, notify: true, eq: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0], eqPreset: "Flat", pitch: 0, fade: 0, correction: true, voiceSpeed: 1.5, duckGames: true, breaks: true, headphones: true, shellAccent: false, trackOsd: true, lighting: false, acoustidKey: "" })

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
	readonly property string visualizer: {
		const v = root.setting("visualizer", "bars");
		return v === true ? "bars" : (v === false ? "off" : String(v));
	}

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

	// ── the sound ──────────────────────────────────────────────────────────
	readonly property var eqBands: ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
	readonly property var eqPresets: [
		{ name: "Flat", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0] },
		{ name: "Bass", gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0] },
		{ name: "Treble", gains: [0, 0, 0, 0, 0, 1, 2, 4, 5, 6] },
		{ name: "Voice", gains: [-4, -3, -1, 1, 3, 4, 4, 2, 0, -2] },
		{ name: "Rock", gains: [4, 3, 1, -1, -2, -1, 1, 3, 4, 4] },
		{ name: "Electronic", gains: [5, 4, 1, 0, -2, 1, 0, 1, 4, 5] },
		{ name: "Classical", gains: [3, 2, 1, 0, 0, 0, -1, -1, 1, 3] },
		{ name: "Loudness", gains: [6, 4, 0, 0, -1, 0, -1, 0, 4, 2] },
		{ name: "Night", gains: [-2, -1, 0, 1, 2, 2, 1, 0, -2, -4] }
	]
	readonly property var eq: root.setting("eq", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
	readonly property bool eqOn: root.eq.some(g => Math.abs(g) > 0.05)

	function setEq(gains, preset) {
		const list = gains.map(g => Math.round(Math.max(-12, Math.min(12, Number(g) || 0)) * 2) / 2);
		root.settings = Object.assign({}, root.settings, { eq: list, eqPreset: preset ?? (root.eqPresets.find(p => String(p.gains) === String(list))?.name ?? "Custom") });
		settingsFile.setText(JSON.stringify(root.settings, null, 2) + "\n");
		eqSend.restart();
	}

	function setBand(i, gain) {
		const list = root.eq.slice();
		list[i] = gain;
		root.setEq(list);
	}

	// a dragged band is told a little later, all at once
	Timer {
		id: eqSend

		interval: 60
		onTriggered: root.request("eq", { gains: root.eq })
	}

	function setPitch(semitones) {
		root.setSetting("pitch", Math.max(-12, Math.min(12, Math.round(Number(semitones) * 2) / 2)));
		root.request("pitch", { semitones: root.setting("pitch", 0) });
	}

	function setFade(seconds) {
		root.setSetting("fade", Math.max(0, Math.min(12, Number(seconds) || 0)));
		root.request("sound", { fade: root.setting("fade", 0) });
	}

	function setCorrection(on) {
		root.setSetting("correction", !!on);
		root.request("sound", { correction: !!on });
	}

	function sendSound() {
		root.request("sound", { eq: root.eq, pitch: root.setting("pitch", 0), fade: root.setting("fade", 0), correction: root.setting("correction", true) });
	}

	// A, then B, then off: what lies between them plays again and again
	function cycleLoop() {
		const now = root.positionNow();
		if (root.loopA < 0) {
			root.loopA = now;
			root.request("ab", { a: now, b: -1 });
			root.say("Loop from here – press again where it should end", "repeat");
		} else if (root.loopB < 0 && now > root.loopA + 0.3) {
			root.loopB = now;
			root.request("ab", { a: root.loopA, b: now });
		} else root.clearLoop();
	}

	function setLoop(a, b) {
		root.loopA = a;
		root.loopB = b;
		root.request("ab", { a: a, b: b });
	}

	function clearLoop() {
		root.loopA = -1;
		root.loopB = -1;
		root.request("ab", { a: -1, b: -1 });
	}

	// quieter for a while: the lowest level any reason asks for (reason → 0..1)
	property var ducks: ({})
	readonly property real duckLevel: {
		let level = 1;
		for (const reason in root.ducks) level = Math.min(level, root.ducks[reason]);
		return level;
	}

	function duck(reason, level) {
		const next = Object.assign({}, root.ducks);
		if (level === undefined || level === null || level >= 1) delete next[reason];
		else next[reason] = Math.max(0, level);
		root.ducks = next;
	}

	onDuckLevelChanged: if (helper.running) root.request("duck", { level: root.duckLevel, seconds: 1.5 })

	// ── words of a song ────────────────────────────────────────────────────
	// tags: { title, artist, album, albumartist, track, year, genre }; cover: a picture file or ""
	function writeTags(path, tags, cover, done) {
		root.request("writetags", { path: path, tags: tags, cover: cover || "" }, (data, error) => {
			if (error) root.say(`The tags could not be written: ${error}`, "alert_circle_outline");
			else root.say(data?.beside ? "Saved – the cover lies beside the song" : "Saved into the file", "tag_check_outline");
			if (done) done(data, error);
		});
	}

	function lookup(path, done) {
		root.request("lookup", { path: path, key: root.setting("acoustidKey", "") }, (data, error) => done(data?.results ?? [], error));
	}

	function fetchCover(url, done) {
		root.request("fetchcover", { url: url }, (data, error) => done(data?.file ?? "", error));
	}

	// ── a voice message ────────────────────────────────────────────────────
	// played between the songs: what played waits, at its place, and goes on after
	property string voicePath: ""
	property real quietUntil: 0
	// the window came for the voice message alone: it goes again after
	property bool voiceOpened: false

	function playVoice(path, options) {
		if (!root.enabled || !path) return;
		const o = options || {};
		path = root.plainPath(path);
		const named = Object.assign({}, root.names);
		named[path] = { title: o.title || "Voice message", artist: o.artist || "" };
		root.names = named;
		root.voicePath = path;
		root.voiceOpened = !root.windowOpen;
		if (!root.mini && !root.windowOpen) root.wantMini = true;
		root.windowOpen = true;
		root.request("voice", { path: path, speed: root.setting("voiceSpeed", 1.5) });
	}

	// the helper has gone back to the song (or stopped); the window goes if it came for this
	function voiceEnded() {
		root.voicePath = "";
		// the song coming back is no news
		root.quietUntil = Date.now() + 2000;
		if (root.voiceOpened) {
			root.voiceOpened = false;
			root.close();
		}
	}

	// ── sleeping ───────────────────────────────────────────────────────────
	// ms since the epoch when the music fades out, -1 after this song, 0 never
	property real sleepAt: 0
	property string sleepSong: ""
	// and then the computer: "" | "suspend" | "shutdown"
	property string sleepThen: ""

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
			root.sleepThen = "";
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
			root.sleepDone();
		}
	}

	// the music has gone to sleep: the computer follows when asked to
	function sleepDone() {
		const then = root.sleepThen;
		root.sleepThen = "";
		if (then === "shutdown") Session.after("shutdown", { what: "music", name: "Music" });
		else if (then === "suspend") Quickshell.execDetached(["systemctl", "suspend"]);
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

	// the strip at once (the radial menu, a voice message)
	function showSmall() {
		if (!root.mini) root.wantMini = true;
		root.showWindow();
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
	// the window comes up small (a voice message): MusicWindow makes it so
	property bool wantMini: false

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
		if (root.loopA >= 0) {
			root.loopA = -1;
			root.loopB = -1;
		}
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
			root.sleepDone();
		}
		root.announce();
		root.remember(path);
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
			root.loopA = m.loopA ?? -1;
			root.loopB = m.loopB ?? -1;
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
		case "voice-done":
			root.voiceEnded();
			break;
		case "error":
			root.say(m.error || "The music stopped", "alert_circle_outline");
			break;
		}
	}

	// a new song while the window is away: one quiet line
	function announce() {
		if (root.windowOpen && root.watching) return;
		if (root.voicePath || Date.now() < root.quietUntil) return;
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


	// ── with the rest of the shell ─────────────────────────────────────────
	// a game plays: the music steps back (GameMode), and comes again after
	readonly property bool gameOn: Plugins.on("games") && GameMode.playing
	onGameOnChanged: root.duck("game", root.gameOn && root.setting("duckGames", true) ? 0.3 : 1)

	// a break (stretching, resting the eyes): paused, and on again after it
	readonly property bool breakOn: Popups.modal === "stretch" || Popups.modal === "eyerest"
	property bool pausedForBreak: false

	onBreakOnChanged: {
		if (root.breakOn && root.playing && root.setting("breaks", true)) {
			root.pausedForBreak = true;
			root.pause();
		} else if (!root.breakOn && root.pausedForBreak) {
			root.pausedForBreak = false;
			root.play();
		}
	}

	// the headphones went (Media paused everything): when they come back, on again
	property bool pausedForHeadphones: false

	Connections {
		target: Audio

		function onHeadphonesLost() {
			if (root.playing && Media.pauseOnHeadphones) root.pausedForHeadphones = true;
		}

		function onOnHeadphonesChanged() {
			if (Audio.onHeadphones && root.pausedForHeadphones) {
				root.pausedForHeadphones = false;
				if (root.setting("headphones", true) && !root.playing) root.play();
			}
		}
	}

	onPlayingChanged: {
		if (root.playing) {
			root.pausedForHeadphones = false;
			lightsBack.stop();
			root.light();
		} else lightsBack.restart();
	}

	// the cover's colour for the whole shell, while music plays
	readonly property bool tintsShell: root.enabled && root.setting("shellAccent", false) && root.playing && root.accentHex !== ""
	onTintsShellChanged: Theme.accentOverride = root.tintsShell ? root.accentHex : "transparent"
	onAccentHexChanged: if (root.tintsShell) Theme.accentOverride = root.accentHex

	// the lights take the cover; a while after the music stops, the theme again
	property string litWith: ""

	function light() {
		if (!Plugins.on("lighting") || !root.setting("lighting", false) || !root.playing || !root.art || root.litWith === root.art) return;
		root.litWith = root.art;
		Quickshell.execDetached(["python3", `${Paths.scripts}/apply_lighting.py`, root.art]);
	}

	onArtChanged: root.light()

	Timer {
		id: lightsBack

		interval: 30000
		onTriggered: {
			if (root.litWith === "" || root.playing) return;
			root.litWith = "";
			Quickshell.execDetached(["python3", `${Paths.scripts}/apply_lighting.py`]);
		}
	}

	// the recently played, for the launcher (newest first)
	property var recent: []

	FileView {
		id: recentFile

		path: Paths.stateFile("music-recent.json")
		printErrors: false
		onLoaded: {
			try {
				root.recent = JSON.parse(String(recentFile.text() || "[]"));
			} catch (error) {}
		}
	}

	function remember(path) {
		if (!path || path === root.voicePath) return;
		root.recent = [path].concat(root.recent.filter(p => p !== path)).slice(0, 60);
		recentFile.setText(JSON.stringify(root.recent) + "\n");
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
			const first = JSON.stringify({ op: "sound", eq: root.eq, pitch: root.setting("pitch", 0), fade: root.setting("fade", 0), correction: root.setting("correction", true) }) + "\n";
			helper.write(first);
			if (root.duckLevel < 1) helper.write(JSON.stringify({ op: "duck", level: root.duckLevel, seconds: 0 }) + "\n");
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
