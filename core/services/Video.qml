pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import QtMultimedia
import Quickshell
import Quickshell.Io
import qs.style.theme

// The shell's video player and editor (plugin "video", `video-default`
// makes it what videos open in): a window of its own (core/views/video/).
// Qt Multimedia plays, decoding on the graphics card, inside the shell's
// scene – so the picture can glide, glow, be cropped and coloured live by a
// shader without a copy. The player lives here, not in the window: the
// window can be built, closed, made small, and the bus, the keys and the
// phone still steer the same thing. Everything heavy – reading a file,
// pictures along it, its sound, finding the intro, subtitles, exporting –
// is a helper's (scripts/video/video.py), lines of JSON like the music's.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("video")
	readonly property string helperScript: `${Paths.scripts}/video/video.py`
	readonly property string windowTitle: root.current ? `${root.titleOf(root.path)} – Video` : "Video"
	readonly property var extensions: ["mp4", "mkv", "webm", "mov", "avi", "m4v", "wmv", "flv", "ts", "m2ts", "mts", "mpg", "mpeg", "ogv", "3gp", "vob", "divx", "asf"]

	function isVideo(path) {
		const m = String(path || "").match(/\.([^./]+)$/);
		return !!m && root.extensions.includes(m[1].toLowerCase());
	}

	function plainPath(path) {
		let p = String(path).replace(/^file:\/\//, "");
		try {
			p = decodeURIComponent(p);
		} catch (error) {}
		return p;
	}

	function fileUrl(path) {
		return path ? "file://" + String(path).split("/").map(part => encodeURIComponent(part)).join("/") : "";
	}

	// the player has this file (its source as a plain path)
	function holds(path) {
		return !!root.player && root.plainPath(String(root.player.source)) === path;
	}

	function nameOf(path) {
		const name = String(path).slice(String(path).lastIndexOf("/") + 1);
		return name.replace(/\.[^.]+$/, "");
	}

	// a file name made readable: dots and underscores are spaces, the release's tail goes
	function titleOf(path) {
		if (!path) return "";
		const meta = root.metas[path];
		if (meta?.title && meta.title.length > 1 && !/^[\w.-]+\.(mkv|mp4)$/i.test(meta.title)) return meta.title;
		let name = root.nameOf(path);
		if (!/\s/.test(name)) name = name.replace(/[._]+/g, " ");
		name = name.replace(/\s*[\[(](?:\d{3,4}p|x26[45]|h\.?26[45]|web[- ]?dl|bluray|hevc|aac|multi)[^\])]*[\])]\s*/gi, " ");
		name = name.replace(/\s+(?:\d{3,4}p|x26[45]|h\.?26[45]|webrip|web[- ]?dl|bluray|brrip|hdtv|hevc|10bit|aac|ac3|dts|multi|german|dl)\b.*$/i, "");
		return name.trim() || root.nameOf(path);
	}

	// S01E02, 1x02, "Folge 3": the episode's mark when it has one
	function episodeOf(path) {
		const name = root.nameOf(path);
		let m = name.match(/[Ss](\d{1,2})[ ._-]?[Ee](\d{1,3})/);
		if (m) return { season: Number(m[1]), episode: Number(m[2]), label: `S${m[1].padStart(2, "0")}E${m[2].padStart(2, "0")}` };
		m = name.match(/\b(\d{1,2})x(\d{2,3})\b/);
		if (m) return { season: Number(m[1]), episode: Number(m[2]), label: `S${m[1].padStart(2, "0")}E${m[2]}` };
		m = name.match(/\b(?:Folge|Episode|Ep|E)[ ._-]?(\d{1,3})\b/i);
		if (m) return { season: 0, episode: Number(m[1]), label: `Episode ${Number(m[1])}` };
		return null;
	}

	function formatTime(seconds) {
		const total = Math.max(0, Math.floor(Number(seconds) || 0));
		const h = Math.floor(total / 3600), m = Math.floor(total / 60) % 60, s = total % 60;
		const ss = s < 10 ? `0${s}` : String(s);
		return h > 0 ? `${h}:${m < 10 ? "0" : ""}${m}:${ss}` : `${m}:${ss}`;
	}

	// ── what plays ─────────────────────────────────────────────────────────
	property bool windowOpen: false
	property string path: ""
	readonly property bool current: root.path !== ""
	// the folder around it (or what was opened together), in order
	property var list: []
	readonly property int index: root.list.indexOf(root.path)
	readonly property bool hasNext: root.index >= 0 && root.index < root.list.length - 1
	readonly property bool hasPrevious: root.index > 0
	readonly property string title: root.titleOf(root.path)
	readonly property var episode: root.episodeOf(root.path)

	// path → what ffprobe said (video.py probe)
	property var metas: ({})
	readonly property var meta: root.metas[root.path] ?? null
	readonly property real aspect: {
		const m = root.meta;
		if (!m || !m.width || !m.height) return 16 / 9;
		const turned = Math.abs(Number(m.rotation) || 0) % 180 === 90;
		return turned ? m.height / m.width : m.width / m.height;
	}
	readonly property var chapters: root.meta?.chapters ?? []
	readonly property int chapterNow: {
		let found = -1;
		for (let i = 0; i < root.chapters.length; i += 1)
			if (root.chapters[i].t <= root.position + 0.05) found = i;
		return found;
	}

	// the engine: built when the first video opens, not at the shell's start
	property bool engineWanted: false
	readonly property MediaPlayer player: engine.item ? engine.item.player : null
	readonly property AudioOutput output: engine.item ? engine.item.audio : null

	readonly property bool playing: root.player?.playbackState === MediaPlayer.PlayingState
	readonly property bool loading: root.current && !!root.player && (root.player.mediaStatus === MediaPlayer.LoadingMedia || root.player.mediaStatus === MediaPlayer.StalledMedia)
	readonly property bool ended: !!root.player && root.player.mediaStatus === MediaPlayer.EndOfMedia
	property string error: ""
	// seconds; what the player says, the editor's own time is `outPosition`
	readonly property real position: root.player ? root.player.position / 1000 : 0
	readonly property real duration: root.player && root.player.duration > 0 ? root.player.duration / 1000 : (root.meta?.duration ?? 0)
	readonly property real progress: root.duration > 0 ? Math.min(1, root.position / root.duration) : 0
	readonly property bool hasAudio: root.player ? root.player.hasAudio : true
	property real speed: 1
	readonly property real volume: root.setting("volume", 100)
	property bool muted: false
	// the volume follows the film's loudness, quiet words up and loud bangs down (`loudness`)
	property var gains: []
	property real gainNow: 1
	// a stretch played again and again (seconds, -1 none)
	property real loopA: -1
	property real loopB: -1
	readonly property bool looping: root.loopA >= 0 && root.loopB > root.loopA

	// the player as a frame tells it: { sink: QVideoSink } – VideoOutput of the window
	property var videoOutput: null

	LazyLoader {
		id: engine

		active: root.engineWanted

		Scope {
			property alias player: thePlayer
			property alias audio: theAudio

			MediaPlayer {
				id: thePlayer

				videoOutput: root.videoOutput
				audioOutput: AudioOutput {
					id: theAudio

					volume: root.muted ? 0 : Math.max(0, Math.min(1, root.volume / 100 * root.gainNow * root.fadeLevel))
				}
				playbackRate: root.speed * root.clipSpeed * (root.fastSilence ? 2.5 : 1)
				// the subtitles are drawn by the window, in the shell's type
				activeSubtitleTrack: -1
				onErrorOccurred: (code, text) => root.failed(text)
				onMediaStatusChanged: root.statusChanged()
				onPlaybackStateChanged: root.stateChanged()
				onPositionChanged: root.tick()
				onTracksChanged: root.tracksChanged()
				Component.onCompleted: {
					if ("pitchCompensation" in thePlayer) thePlayer.pitchCompensation = Qt.binding(() => root.setting("keepPitch", true));
				}
			}
		}
	}

	Behavior on gainNow {
		NumberAnimation {
			duration: 600
		}
	}

	// ── settings ───────────────────────────────────────────────────────────
	property var settings: ({ volume: 100, resume: true, autoNext: true, skipIntro: "ask", subtitles: true, subSize: 1, subBox: false, subLang: "", audioLang: "", evenLoudness: false, ambient: true, shellAccent: false, lighting: false, pauseMusic: true, breaks: true, games: true, keepPitch: true, hoverPreview: true, whisperModel: "small", opensubtitlesKey: "", pane: "", subPosition: 0.92, losslessFirst: true, preset: "mp4", openRecordings: false })

	function setting(name, fallback) {
		const value = root.settings[name];
		return value === undefined ? fallback : value;
	}

	function setSetting(name, value) {
		root.settings = Object.assign({}, root.settings, { [name]: value });
		settingsSave.restart();
	}

	Timer {
		id: settingsSave

		interval: 300
		onTriggered: settingsFile.setText(JSON.stringify(root.settings, null, 2) + "\n")
	}

	FileView {
		id: settingsFile

		path: Paths.stateFile("video.json")
		printErrors: false
		onLoaded: {
			try {
				root.settings = Object.assign({}, root.settings, JSON.parse(String(text() || "{}")));
			} catch (error) {}
		}
	}

	readonly property string pane: root.setting("pane", "")

	function showPane(name) {
		root.setSetting("pane", root.pane === name ? "" : name);
	}

	// ── opening ────────────────────────────────────────────────────────────
	// open(path, { start: seconds, paused, list: [paths], edit, origin: { screen, x, y, w, h, image } })
	// – without a list the videos of its folder come around it
	property var origin: null
	property real wantStart: -1
	property bool wantPaused: false
	property bool openEditor: false

	function open(path, options) {
		if (!root.enabled || !path) return;
		const o = options || {};
		path = root.plainPath(path);
		root.origin = o.origin ?? null;
		if (o.list && o.list.length > 0) root.list = o.list.map(p => root.plainPath(p));
		else if (!root.list.includes(path)) {
			root.list = [path];
			root.request("folder", { path: path }, data => {
				if (data?.paths?.length > 0 && data.paths.includes(root.path)) root.list = data.paths;
			});
		}
		root.openEditor = !!o.edit;
		root.load(path, o.start ?? -1, !!o.paused);
		root.showWindow();
	}

	function openMany(paths) {
		const list = (paths || []).map(p => root.plainPath(p)).filter(p => p);
		if (list.length === 0) return;
		if (list.length === 1) return root.open(list[0]);
		root.open(list[0], { list: list });
	}

	// into the editor: `trim` [a, b] cuts it to that stretch at once
	function edit(path, options) {
		const o = options || {};
		root.open(path || root.path, { edit: true, paused: true, start: o.trim ? o.trim[0] : -1 });
		if (o.trim && o.trim.length === 2) root.pendingTrim = { path: root.plainPath(path || root.path), a: o.trim[0], b: o.trim[1] };
	}

	property var pendingTrim: null

	// several videos one after the other in the editor (the shelf, Files)
	function join(paths) {
		const list = (paths || []).map(p => root.plainPath(p)).filter(p => root.isVideo(p));
		if (list.length === 0) return;
		if (list.length === 1) return root.edit(list[0]);
		let known = 0;
		const lengths = {};
		for (const p of list) {
			root.probe(p, data => {
				lengths[p] = data?.duration ?? 0;
				known += 1;
				if (known < list.length) return;
				root.pendingJoin = list.filter(q => lengths[q] > 0).map(q => ({ src: q, a: 0, b: lengths[q], speed: 1, reverse: false, hold: 0, volume: 1 }));
				root.open(list[0], { edit: true, paused: true, list: list });
			});
		}
	}

	property var pendingJoin: null

	// what the window does on a word from outside (ipc `video act`, the radial menu):
	// play-pause, fullscreen, pip, edit, info, subtitles, audio, playlist, snapshot, copy-frame,
	// undo, redo, split, export, close-pane …
	signal act(string name)

	function load(path, start, paused) {
		root.saveProgress();
		root.engineWanted = true;
		root.error = "";
		root.clearLoop();
		root.wantPaused = paused;
		// where it was left, unless asked for a place or it was seen to the end
		const kept = root.progress_[path];
		if (start >= 0) root.wantStart = start;
		else if (root.setting("resume", true) && kept && !kept.watched && kept.pos > 15 && kept.pos < (kept.dur || 1e9) - 20) {
			root.wantStart = kept.pos;
			root.resumedFrom = kept.pos;
		} else root.wantStart = -1;
		if (start >= 0) root.resumedFrom = -1;
		const same = root.path === path;
		root.path = path;
		root.remember(path);
		if (!root.metas[path]) root.probe(path);
		if (same && root.player) root.applyStart();
		else if (root.player) root.player.source = root.fileUrl(path);
		root.sidesFor(path);
	}

	// where the video was taken up again (a chip offers the start instead)
	property real resumedFrom: -1

	function probe(path, done) {
		root.request("probe", { path: path }, data => {
			if (!data) return done?.(null);
			const next = Object.assign({}, root.metas);
			next[path] = data;
			root.metas = next;
			if (done) done(data);
		});
	}

	// the engine came: what was asked for before
	property var engineReady: root.player
	onEngineReadyChanged: if (root.player && root.path) root.player.source = root.fileUrl(root.path)

	function statusChanged() {
		const p = root.player;
		if (!p) return;
		if (p.mediaStatus === MediaPlayer.LoadedMedia && root.awaitingStart) root.applyStart();
		if (p.mediaStatus === MediaPlayer.EndOfMedia && !root.startPending) root.reachedEnd();
		if (p.mediaStatus === MediaPlayer.InvalidMedia) root.failed(p.errorString || "This video cannot be played");
	}

	readonly property bool awaitingStart: root.startPending
	property bool startPending: false

	// the new file is there: its start, as soon as the player says it is
	// loaded (the status may not change at all between two files, so it is looked at)
	Timer {
		running: root.startPending && !!root.player && root.current
		repeat: true
		interval: 60
		onTriggered: {
			const p = root.player;
			if (!root.holds(root.path)) p.source = root.fileUrl(root.path);
			else if (p.mediaStatus === MediaPlayer.LoadedMedia || p.mediaStatus === MediaPlayer.BufferedMedia || p.mediaStatus === MediaPlayer.BufferingMedia) root.applyStart();
		}
	}

	function applyStart() {
		const p = root.player;
		if (!p || !root.holds(root.path)) return;
		root.startPending = false;
		root.pickTracks();
		const editedStart = root.editing && root.clips.length > 0 ? root.clips[0].a : -1;
		const at = root.wantStart >= 0 ? root.wantStart : (editedStart > 0 ? editedStart : 0);
		if (at > 0.05) p.position = at * 1000;
		root.wantStart = -1;
		if (root.wantPaused || root.openEditor) {
			p.pause();
			root.wantPaused = false;
		} else p.play();
	}

	function failed(text) {
		root.error = text || "This video cannot be played";
		root.say(root.error, "alert_circle_outline");
	}

	// ── steering ───────────────────────────────────────────────────────────
	function toggle() {
		if (!root.current) return root.showWindow();
		if (root.playing) root.pause();
		else root.play();
	}

	function play() {
		if (!root.player || !root.current) return;
		if (root.ended) root.seek(root.editing ? root.outToSource(0).t : 0);
		root.player.play();
	}

	function pause() {
		if (root.player) root.player.pause();
	}

	function stop() {
		root.saveProgress();
		if (root.player) root.player.stop();
	}

	function seek(seconds) {
		if (!root.player) return;
		const to = Math.max(0, Math.min(root.duration > 0 ? root.duration - 0.05 : 1e9, Number(seconds) || 0));
		root.player.position = to * 1000;
		root.resumedFrom = -1;
		root.seeked(to);
		mprisSend.restart();
	}

	signal seeked(real to)

	function seekBy(delta) {
		root.seek(root.position + delta);
	}

	// one frame on or back (paused): the frame rate the file says
	function step(frames) {
		if (root.playing) root.pause();
		const fps = Number(root.meta?.fps) || 25;
		root.seek(root.position + frames / fps);
	}

	function next() {
		if (root.hasNext) root.load(root.list[root.index + 1], -1, false);
	}

	function previous() {
		if (root.position > 5 && !root.editing) return root.seek(0);
		if (root.hasPrevious) root.load(root.list[root.index - 1], -1, false);
		else root.seek(0);
	}

	function jump(i) {
		if (i >= 0 && i < root.list.length) root.load(root.list[i], -1, false);
	}

	function setVolume(value) {
		root.setSetting("volume", Math.max(0, Math.min(100, Math.round(Number(value)))));
		if (root.muted && value > 0) root.muted = false;
	}

	function setSpeed(value) {
		root.speed = Math.max(0.25, Math.min(4, Math.round(Number(value) * 100) / 100));
		mprisSend.restart();
	}

	// A, then B, then off
	function cycleLoop() {
		const now = root.position;
		if (root.loopA < 0) {
			root.loopA = now;
			root.say("Loop from here – press again where it should end", "repeat");
		} else if (root.loopB < 0 && now > root.loopA + 0.3) root.loopB = now;
		else root.clearLoop();
	}

	function clearLoop() {
		root.loopA = -1;
		root.loopB = -1;
	}

	// the tracks: Qt's lists of metadata; the subtitles are ours (helper `subs`)
	property var audioTracks: []
	property int audioTrack: -1

	function tracksChanged() {
		const p = root.player;
		if (!p) return;
		root.audioTracks = (p.audioTracks || []).map((m, i) => ({
			index: i,
			lang: String(m.stringValue(MediaMetaData.Language) || ""),
			title: String(m.stringValue(MediaMetaData.Title) || ""),
			codec: String(m.stringValue(MediaMetaData.AudioCodec) || "")
		}));
		root.audioTrack = p.activeAudioTrack;
	}

	function setAudioTrack(i) {
		if (!root.player) return;
		root.player.activeAudioTrack = i;
		root.audioTrack = i;
	}

	// the language asked for in the settings, else what the file calls default
	function pickTracks() {
		root.tracksChanged();
		const want = String(root.setting("audioLang", "")).toLowerCase();
		if (want) {
			const found = root.audioTracks.find(t => t.lang.toLowerCase().startsWith(want) || t.title.toLowerCase().includes(want));
			if (found && found.index !== root.audioTrack) root.setAudioTrack(found.index);
		}
	}

	// ── subtitles, drawn by the window ─────────────────────────────────────
	// [{ id, label, lang, source, file }] of the video that plays
	property var subTracks: []
	property string subFile: ""
	property var cues: []
	// seconds the words come later (+) or sooner (-), per video
	property real subDelay: 0
	readonly property string subText: {
		if (!root.setting("subtitles", true) || root.cues.length === 0) return "";
		const at = root.position - root.subDelay;
		let low = 0, high = root.cues.length - 1;
		while (low <= high) {
			const middle = (low + high) >> 1;
			const cue = root.cues[middle];
			if (at < cue.a) high = middle - 1;
			else if (at >= cue.b) low = middle + 1;
			else {
				// overlapping cues: the ones around it that also hold
				const lines = [cue.text];
				for (let i = middle + 1; i < root.cues.length && root.cues[i].a <= at; i += 1)
					if (at < root.cues[i].b) lines.push(root.cues[i].text);
				return lines.join("\n");
			}
		}
		return "";
	}

	function loadSubs(path) {
		root.subTracks = [];
		root.cues = [];
		root.subFile = "";
		root.subDelay = root.progress_[path]?.subDelay ?? 0;
		root.request("subs", { path: path }, data => {
			if (root.path !== path || !data) return;
			root.subTracks = data.tracks || [];
			const want = String(root.setting("subLang", "")).toLowerCase();
			const kept = root.progress_[path]?.sub;
			let pick = kept !== undefined ? root.subTracks.find(t => t.file === kept) : null;
			if (!pick && kept === undefined && want) pick = root.subTracks.find(t => String(t.lang).toLowerCase().startsWith(want));
			if (!pick && kept === undefined && root.subTracks.length > 0 && root.subTracks.some(t => t.source === "beside")) pick = root.subTracks.find(t => t.source === "beside");
			// what the file itself calls its default subtitles
			if (!pick && kept === undefined) pick = root.subTracks.find(t => t.default === true) ?? null;
			if (pick) root.setSubFile(pick.file, true);
		});
	}

	function setSubFile(file, quiet) {
		root.subFile = file || "";
		root.cues = [];
		if (!quiet) root.keepFor(root.path, { sub: root.subFile });
		if (!file) return;
		const path = root.path;
		root.request("cues", { file: file }, data => {
			if (root.path === path && root.subFile === file) root.cues = data?.cues ?? [];
		});
	}

	function setSubDelay(seconds) {
		root.subDelay = Math.round(Number(seconds) * 10) / 10;
		root.keepFor(root.path, { subDelay: root.subDelay });
	}

	// made by Whisper beside the video, then shown
	function transcribe(lang, done) {
		const path = root.path;
		root.startJob("transcribe", { path: path, lang: lang || "", model: root.setting("whisperModel", "small") }, "Writing the subtitles", result => {
			if (result?.file && root.path === path) {
				root.loadSubs(path);
				root.setSubFile(result.file);
			}
			if (done) done(result);
		});
	}

	// ── the rest of a video: pictures along it, its sound, its intro ───────
	// path → { file, cols, rows, count, tile_w, tile_h, times, colors, accent }
	property var sprites: ({})
	property var spritesAsked: ({})
	readonly property var sprite: root.sprites[root.path] ?? null
	property var wave: []
	property var intro: null
	property var outro: null
	property bool introSkipped: false

	function spritesOf(path, done) {
		path = root.plainPath(path);
		if (root.sprites[path]) return done?.(root.sprites[path]);
		const waiting = root.spritesAsked[path];
		if (waiting) {
			if (done) waiting.push(done);
			return;
		}
		root.spritesAsked[path] = done ? [done] : [];
		root.request("sprites", { path: path }, (data, error) => {
			const callbacks = root.spritesAsked[path] || [];
			delete root.spritesAsked[path];
			if (!data) return;
			// a job: the result comes with its end
			if (data.job) {
				root.jobDone[data.job] = result => root.gotSprites(path, result, callbacks);
				return;
			}
			root.gotSprites(path, data, callbacks);
		});
	}

	function gotSprites(path, meta, callbacks) {
		if (!meta?.file) return;
		const next = Object.assign({}, root.sprites);
		next[path] = meta;
		root.sprites = next;
		for (const done of callbacks || []) done(meta);
	}

	// which tile shows the moment t (the tiles are spread evenly)
	function tileAt(meta, t) {
		if (!meta || !meta.times || meta.times.length === 0) return -1;
		const times = meta.times;
		let low = 0, high = times.length - 1;
		while (low < high) {
			const middle = (low + high + 1) >> 1;
			if (times[middle] <= t) low = middle;
			else high = middle - 1;
		}
		return low;
	}

	function frameOf(path, t, done, width) {
		root.request("frame", { path: root.plainPath(path), t: t, width: width || 0 }, data => done(data?.file ?? ""));
	}

	function sidesFor(path) {
		root.wave = [];
		root.gains = [];
		root.intro = null;
		root.outro = null;
		root.introSkipped = false;
		root.outroShown = false;
		root.spritesOf(path);
		root.loadSubs(path);
		root.request("wave", { path: path }, data => {
			if (data && data.path === root.path) root.wave = data.peaks || [];
		});
		if (root.setting("evenLoudness", false)) root.loadGains(path);
		// episodes of a series: the stretch they share at the start and the end
		if (root.list.length > 1 && root.setting("skipIntro", "ask") !== "off") {
			root.request("intro", { path: path }, data => {
				const take = result => {
					if (root.path !== path || !result) return;
					root.intro = result.intro ?? null;
					root.outro = result.outro ?? null;
				};
				if (data?.job) root.jobDone[data.job] = take;
				else take(data);
			});
		}
	}

	function loadGains(path) {
		root.request("loudness", { path: path }, data => {
			const take = result => {
				if (result && root.path === path) root.gains = result.gains || [];
			};
			if (data?.job) root.jobDone[data.job] = take;
			else take(data);
		});
	}

	onSettingsChanged: {
		if (root.setting("evenLoudness", false) && root.gains.length === 0 && root.current) root.loadGains(root.path);
		if (!root.setting("evenLoudness", false)) root.gainNow = 1;
	}

	readonly property bool inIntro: !!root.intro && root.position >= root.intro[0] && root.position < root.intro[1] - 1
	property bool outroShown: false
	// the end is near: the next episode is offered (credits, or the last 20 s)
	readonly property bool nearEnd: root.hasNext && !root.editing && root.duration > 60 && (root.outro ? root.position >= root.outro[0] : root.position >= root.duration - 20)

	function skipIntro() {
		if (!root.intro) return;
		root.introSkipped = true;
		root.seek(root.intro[1]);
	}

	// ── each moment ───────────────────────────────────────────────────────
	property real lastKept: 0
	property bool fastSilence: false

	function tick() {
		const at = root.position;
		if (root.looping && at >= root.loopB) return root.seek(root.loopA);
		if (root.editing) root.followClips(at);
		if (root.inIntro && !root.introSkipped && root.setting("skipIntro", "ask") === "auto" && root.playing) {
			root.introSkipped = true;
			root.seek(root.intro[1]);
			root.say("Intro skipped", "debug_step_over");
		}
		if (root.gains.length > 0 && root.setting("evenLoudness", false)) {
			const g = root.gains[Math.floor(at)];
			root.gainNow = g === undefined ? 1 : Math.min(1 / Math.max(0.01, root.volume / 100), Math.pow(10, g / 20));
		}
		if (root.sprite && (root.tintsShell || root.lightsOn)) root.followColour(at);
		if (Date.now() - root.lastKept > 5000 && root.playing) {
			root.lastKept = Date.now();
			root.saveProgress();
			mprisSend.restart();
		}
	}

	function stateChanged() {
		mprisSend.restart();
		if (!root.playing) root.saveProgress();
		root.followMusic();
	}

	function reachedEnd() {
		if (!root.holds(root.path)) return;
		root.keepFor(root.path, { pos: root.duration, dur: root.duration, watched: true });
		if (root.editing) return;
		// not inside the player's own signal: a new source there is not taken up
		if (root.setting("autoNext", true) && root.hasNext) {
			Qt.callLater(root.next);
			return;
		}
		// the window came only for this: it stays, the picture holds on its last frame
		mprisSend.restart();
	}

	// ── how far each video was seen ────────────────────────────────────────
	// path → { pos, dur, at, watched, sub, subDelay }
	property var progress_: ({})

	function progressOf(path) {
		return root.progress_[root.plainPath(path)] ?? null;
	}

	FileView {
		id: progressFile

		path: Paths.stateFile("video-progress.json")
		printErrors: false
		onLoaded: {
			try {
				root.progress_ = JSON.parse(String(progressFile.text() || "{}"));
			} catch (error) {}
		}
	}

	function keepFor(path, fields) {
		if (!path || !root.keeps(path)) return;
		const next = Object.assign({}, root.progress_);
		next[path] = Object.assign({}, next[path] || {}, fields, { at: Date.now() });
		root.progress_ = next;
		progressSave.restart();
	}

	function saveProgress() {
		if (!root.current || !root.player || root.duration <= 0 || root.startPending || root.editing) return;
		// the player still holds the file before (a new one is on its way)
		if (!root.holds(root.path)) return;
		const pos = root.position;
		const kept = root.progress_[root.path];
		const watched = pos >= root.duration * 0.93 || (root.outro && pos >= root.outro[0]) || !!(kept?.watched && pos < 15);
		if (kept && Math.abs((kept.pos ?? 0) - pos) < 1 && kept.watched === watched) return;
		root.keepFor(root.path, { pos: Math.round(pos * 10) / 10, dur: Math.round(root.duration * 10) / 10, watched: watched });
	}

	function setWatched(path, watched) {
		const kept = root.progress_[path] || {};
		root.keepFor(path, { watched: !!watched, pos: watched ? (kept.dur || 0) : 0, dur: kept.dur || 0 });
	}

	Timer {
		id: progressSave

		interval: 1500
		onTriggered: {
			// the oldest go once there are many
			let entries = Object.entries(root.progress_);
			if (entries.length > 600) {
				entries.sort((a, b) => (b[1].at || 0) - (a[1].at || 0));
				root.progress_ = Object.fromEntries(entries.slice(0, 500));
			}
			progressFile.setText(JSON.stringify(root.progress_) + "\n");
		}
	}

	// the recently opened, newest first (the launcher)
	property var recent: []

	FileView {
		id: recentFile

		path: Paths.stateFile("video-recent.json")
		printErrors: false
		onLoaded: {
			try {
				root.recent = JSON.parse(String(recentFile.text() || "[]"));
			} catch (error) {}
		}
	}

	// a file held in memory ($XDG_RUNTIME_DIR, e.g. from the browser's menu)
	// is gone at the next start: nothing of it is kept
	function keeps(path) {
		return !String(path).startsWith(`${Paths.runtime}/`);
	}

	function remember(path) {
		if (!path || !root.keeps(path)) return;
		root.recent = [path].concat(root.recent.filter(p => p !== path)).slice(0, 60);
		recentFile.setText(JSON.stringify(root.recent) + "\n");
	}

	function forget(path) {
		root.recent = root.recent.filter(p => p !== path);
		recentFile.setText(JSON.stringify(root.recent) + "\n");
	}

	// ── the editor's recipe ────────────────────────────────────────────────
	// what was done to a video, as data (the spec in scripts/video/video.py):
	// kept per file, so leaving and coming back finds it as it was
	property bool editing: false
	property var recipe: root.blankRecipe()
	property var undoStack: []
	property var redoStack: []
	property var recipes: ({})
	readonly property var clips: root.recipe.clips ?? []
	readonly property bool edited: JSON.stringify(root.recipe) !== JSON.stringify(root.blankRecipe())

	function blankRecipe() {
		return { clips: [], geometry: { rot: 0, flip: false, angle: 0, vertical: 0, horizontal: 0, quad: null, crop: { x: 0, y: 0, w: 1, h: 1 }, pad: null }, adjust: {}, curves: {}, tones: {}, look: "", stabilize: 0, fade: { in: 0, out: 0 },
			audio: { gain: 0, fadeIn: 0, fadeOut: 0, denoise: 0, normalize: false, mute: false, replace: "", music: { path: "", gain: -8, start: 0, duck: true }, keys: [] },
			texts: [], blurs: [], faces: false, subtitles: { file: "", burn: false, beside: false, style: { size: 1, box: false } }, chapters: [] };
	}

	FileView {
		id: recipesFile

		path: Paths.stateFile("video-recipes.json")
		printErrors: false
		onLoaded: {
			try {
				root.recipes = JSON.parse(String(recipesFile.text() || "{}"));
			} catch (error) {}
		}
	}

	function startEditing() {
		if (!root.current) return;
		root.editing = true;
		root.undoStack = [];
		root.redoStack = [];
		const kept = root.recipes[root.path];
		root.recipe = kept ? Object.assign(root.blankRecipe(), JSON.parse(JSON.stringify(kept))) : root.blankRecipe();
		if (root.pendingJoin && root.pendingJoin.length > 0 && root.pendingJoin[0].src === root.path) {
			const clips = root.pendingJoin;
			root.pendingJoin = null;
			root.commit(Object.assign({}, root.recipe, { clips: clips }));
		}
		if (root.pendingTrim && root.pendingTrim.path === root.path) {
			const t = root.pendingTrim;
			root.pendingTrim = null;
			root.commit(Object.assign({}, root.recipe, { clips: [{ src: root.path, a: t.a, b: t.b, speed: 1, reverse: false, hold: 0, volume: 1 }] }));
		}
		if (root.playing) root.pause();
	}

	function stopEditing() {
		root.editing = false;
		root.keepRecipe();
		root.clipSpeed = 1;
	}

	// a step done: kept, and can be taken back
	function commit(next) {
		root.undoStack = root.undoStack.concat([JSON.stringify(root.recipe)]).slice(-200);
		root.redoStack = [];
		root.recipe = next;
		recipeSave.restart();
	}

	// a step still moving (a dragged handle): shown, kept only by `commit`
	function preview(next) {
		root.recipe = next;
	}

	function undo() {
		if (root.undoStack.length === 0) return;
		root.redoStack = root.redoStack.concat([JSON.stringify(root.recipe)]);
		root.recipe = JSON.parse(root.undoStack[root.undoStack.length - 1]);
		root.undoStack = root.undoStack.slice(0, -1);
		recipeSave.restart();
	}

	function redo() {
		if (root.redoStack.length === 0) return;
		root.undoStack = root.undoStack.concat([JSON.stringify(root.recipe)]);
		root.recipe = JSON.parse(root.redoStack[root.redoStack.length - 1]);
		root.redoStack = root.redoStack.slice(0, -1);
		recipeSave.restart();
	}

	function resetRecipe() {
		root.commit(root.blankRecipe());
	}

	function keepRecipe() {
		if (!root.path) return;
		const next = Object.assign({}, root.recipes);
		if (root.edited) next[root.path] = root.recipe;
		else delete next[root.path];
		root.recipes = next;
		recipesFile.setText(JSON.stringify(root.recipes) + "\n");
	}

	Timer {
		id: recipeSave

		interval: 800
		onTriggered: root.keepRecipe()
	}

	// a recipe with its clips spelled out (the whole file when none were cut)
	function clipsOf(recipe) {
		const list = recipe?.clips ?? [];
		if (list.length > 0) return list;
		return root.duration > 0 ? [{ src: root.path, a: 0, b: root.duration, speed: 1, reverse: false, hold: 0, volume: 1 }] : [];
	}

	function clipLength(clip) {
		return Math.max(0, clip.b - clip.a) / Math.max(0.01, clip.speed || 1) + (clip.hold || 0);
	}

	readonly property real outDuration: {
		let total = 0;
		for (const clip of root.clipsOf(root.recipe)) total += root.clipLength(clip);
		return total;
	}

	// the output's moment t → { index, src, t (source seconds) }
	function outToSource(t) {
		const list = root.clipsOf(root.recipe);
		let start = 0;
		for (let i = 0; i < list.length; i += 1) {
			const clip = list[i];
			const length = root.clipLength(clip);
			if (t < start + length || i === list.length - 1) {
				const inner = Math.max(0, Math.min(clip.b - clip.a, (t - start) * (clip.speed || 1)));
				return { index: i, src: clip.src || root.path, t: clip.a + inner };
			}
			start += length;
		}
		return { index: 0, src: root.path, t: 0 };
	}

	// a source moment in clip i → the output's moment
	function sourceToOut(i, t) {
		const list = root.clipsOf(root.recipe);
		let start = 0;
		for (let k = 0; k < i && k < list.length; k += 1) start += root.clipLength(list[k]);
		const clip = list[i];
		if (!clip) return 0;
		return start + Math.max(0, Math.min(clip.b, t) - clip.a) / Math.max(0.01, clip.speed || 1);
	}

	// which clip plays now; the editor's playhead
	property int clipIndex: 0
	property real clipSpeed: 1
	readonly property real outPosition: root.editing ? root.sourceToOut(root.clipIndex, root.position) : root.position

	function seekOut(t) {
		const at = root.outToSource(Math.max(0, Math.min(root.outDuration, t)));
		root.clipIndex = at.index;
		const clip = root.clipsOf(root.recipe)[at.index];
		root.clipSpeed = clip?.speed || 1;
		if (at.src !== root.path) {
			// another file's clip (joined videos): its source, then the place
			root.wantStart = at.t;
			root.path = at.src;
			if (root.player) root.player.source = root.fileUrl(at.src);
			if (!root.metas[at.src]) root.probe(at.src);
			return;
		}
		root.seek(at.t);
	}

	// the edited film plays as it will be: past a clip's end it goes on at
	// the next one's start, a held frame waits, a faster clip plays faster
	property bool holding: false

	function followClips(at) {
		const list = root.clipsOf(root.recipe);
		if (list.length === 0 || root.holding || root.startPending) return;
		let i = root.clipIndex;
		let clip = list[i];
		// moved outside the clip (a seek on the player): find the one around it
		if (!clip || (clip.src || root.path) !== root.path || at < clip.a - 0.25 || at > clip.b + 0.25) {
			const found = list.findIndex(c => (c.src || root.path) === root.path && at >= c.a - 0.05 && at <= c.b);
			if (found >= 0) {
				i = found;
				clip = list[i];
				root.clipIndex = i;
			} else if (clip) return;
		}
		root.clipSpeed = clip.speed || 1;
		if (!root.playing || at < clip.b - 0.04) return;
		if ((clip.hold || 0) > 0) {
			root.pause();
			root.holding = true;
			holdTimer.interval = clip.hold * 1000;
			holdTimer.restart();
			return;
		}
		root.toNextClip();
	}

	function toNextClip() {
		const list = root.clipsOf(root.recipe);
		const i = root.clipIndex + 1;
		if (i >= list.length) {
			root.pause();
			return;
		}
		root.seekOut(root.sourceToOut(i, list[i].a));
		root.play();
	}

	Timer {
		id: holdTimer

		onTriggered: {
			root.holding = false;
			root.toNextClip();
		}
	}

	// ── exporting and other long jobs ──────────────────────────────────────
	// id → { kind, label, progress, state, text, result, path }
	property var jobs: ({})
	property var jobDone: ({})

	// a job of the helper with its progress shown; done(result) at its end
	function startJob(op, args, label, done) {
		root.request(op, args, (data, error) => {
			if (error || !data) {
				root.say(error || `${label} did not work`, "alert_circle_outline");
				if (done) done(null);
				return;
			}
			if (!data.job) {
				if (done) done(data);
				return;
			}
			const next = Object.assign({}, root.jobs);
			next[data.job] = { kind: op, label: label, progress: 0, state: "running", text: "", result: null, path: args.path || "" };
			root.jobs = next;
			if (done) root.jobDone[data.job] = done;
		});
	}

	function cancelJob(id) {
		root.request("cancel", { job: id });
	}

	function jobEvent(m) {
		const known = root.jobs[m.job];
		if (known) {
			const next = Object.assign({}, root.jobs);
			next[m.job] = Object.assign({}, known, { progress: m.progress ?? known.progress, state: m.state || known.state, text: m.text ?? known.text, result: m.result ?? known.result });
			root.jobs = next;
		}
		if (m.state === "done" || m.state === "error" || m.state === "cancelled") {
			const done = root.jobDone[m.job];
			delete root.jobDone[m.job];
			if (m.state === "error" && known) root.say(m.text || `${known.label} did not work`, "alert_circle_outline");
			if (done) done(m.state === "done" ? (m.result || {}) : null);
			if (known) forgetJob.restart();
		}
	}

	readonly property var runningJobs: Object.entries(root.jobs).filter(([id, job]) => job.state === "running").map(([id, job]) => Object.assign({ id: id }, job))

	// finished jobs stay a moment to be seen, then go
	Timer {
		id: forgetJob

		interval: 20000
		onTriggered: {
			const next = {};
			for (const id in root.jobs)
				if (root.jobs[id].state === "running") next[id] = root.jobs[id];
			root.jobs = next;
		}
	}

	// the film made: the recipe, as the preset asks; overlays are the window's pictures of the texts
	function exportWith(preset, overlays, done) {
		const recipe = JSON.parse(JSON.stringify(root.recipe));
		recipe.clips = root.clipsOf(recipe);
		// the texts go as the pictures the window made of them, never as words
		recipe.texts = overlays || [];
		const source = root.path;
		root.startJob("export", { path: source, recipe: recipe, preset: preset }, "Exporting", result => {
			if (result?.file) root.tellMade(result.file, result.lossless ? "Cut without re-encoding" : "Exported");
			if (done) done(result);
		});
	}

	// for sharing: under a size, beside the original
	function shrink(path, targetMb, done) {
		root.startJob("shrink", { path: root.plainPath(path), target_mb: targetMb }, `Making it smaller than ${targetMb} MB`, result => {
			if (done) done(result?.file ?? "");
		});
	}

	function gif(path, a, b, done) {
		root.startJob("gif", { path: root.plainPath(path), a: a, b: b }, "Making a GIF", result => {
			if (result?.file) root.tellMade(result.file, "GIF made");
			if (done) done(result?.file ?? "");
		});
	}

	function extractAudio(path, format, done) {
		root.startJob("audio", { path: root.plainPath(path), format: format || "m4a" }, "Taking the sound out", result => {
			if (result?.file) root.tellMade(result.file, "Sound saved");
			if (done) done(result?.file ?? "");
		});
	}

	function cutPart(path, a, b, done) {
		root.startJob("clip", { path: root.plainPath(path), a: a, b: b }, "Cutting the part", result => {
			if (result?.file) root.tellMade(result.file, "Part saved");
			if (done) done(result?.file ?? "");
		});
	}

	// the moment as a picture: beside the video, and on the clipboard
	function snapshot(copy) {
		if (!root.current) return;
		const t = root.position;
		const path = root.path;
		root.request("snapshot", { path: path, t: t }, data => {
			if (!data?.file) return root.say("The picture could not be taken", "alert_circle_outline");
			if (copy) Quickshell.execDetached(["sh", "-c", 'wl-copy --type image/png < "$1"', "sh", data.file]);
			Notifs.pushInternal("done", copy ? "Picture copied" : "Picture saved", root.nameOf(data.file), {
				app: "Video", icon: "camera_outline", image: data.file, duration: 4000,
				actions: [{ label: "Edit", icon: "image_edit_outline", run: () => Viewer.open(data.file) }, { label: "Show", icon: "folder_open_outline", run: () => Files.reveal(data.file) }]
			});
		});
	}

	function tellMade(file, what) {
		Notifs.pushInternal("done", what, root.nameOf(file) + file.slice(file.lastIndexOf(".")), {
			app: "Video", icon: "movie_check_outline", duration: 6000,
			actions: [{ label: "Play", icon: "play", run: () => root.open(file) }, { label: "Show", icon: "folder_open_outline", run: () => Files.reveal(file) }]
		});
	}

	// ── the window ─────────────────────────────────────────────────────────
	function showWindow() {
		if (!root.enabled) return;
		root.engineWanted = true;
		root.windowOpen = true;
		root.focusWindow();
		// started as an app with nothing to play: the one left last
		if (!root.current && root.recent.length > 0) {
			const last = root.recent[0];
			root.open(last, { paused: true });
		}
	}

	function close() {
		if (root.editing) root.stopEditing();
		root.saveProgress();
		if (root.pip) root.pip = false;
		root.windowOpen = false;
		root.pause();
	}

	function toggleWindow() {
		if (root.windowOpen) root.close();
		else root.showWindow();
	}

	function focusWindow() {
		focusTimer.restart();
	}

	function niriWindow() {
		return Niri.windows.find(window => /( – Video|^Video)$/.test(String(window.title)) && /quickshell/i.test(String(window.app_id))) ?? null;
	}

	Timer {
		id: focusTimer

		interval: 80
		onTriggered: {
			const window = root.niriWindow();
			if (window && !window.is_focused) Niri.focusWindow(window.id);
		}
	}

	function niri(args) {
		const window = root.niriWindow();
		if (!window) return;
		Quickshell.execDetached(["niri", "msg", "action"].concat(args.map(a => a === "@id" ? String(window.id) : String(a))));
	}

	property bool fullscreen: false

	function toggleFullscreen() {
		const window = root.niriWindow();
		if (!window) return;
		if (root.pip) root.togglePip();
		root.fullscreen = !root.fullscreen;
		root.niri(["fullscreen-window", "--id", "@id"]);
	}

	// niri knows when it left fullscreen another way (Mod+Shift+F)
	Connections {
		target: Niri

		function onWindowsChanged() {
			const window = root.niriWindow();
			if (!window) return;
			const size = window.layout?.window_size;
			const screen = root.screenOf(window);
			if (size && screen) root.fullscreen = Math.abs(size[0] - screen.width) < 2 && Math.abs(size[1] - screen.height) < 2;
		}

		function onWorkspacesChanged() {
			root.followWorkspace();
		}
	}

	function screenOf(window) {
		const workspace = Niri.workspaceMap[window?.workspace_id];
		return Quickshell.screens.find(s => s.name === workspace?.output) ?? Quickshell.screens[0] ?? null;
	}

	// picture in picture: small in a corner, above what is under it, along
	// to whichever workspace is looked at
	property bool pip: false
	property size bigSize: Qt.size(1280, 760)
	// "br" | "bl" | "tr" | "tl"
	readonly property string pipCorner: root.setting("pipCorner", "br")

	function togglePip() {
		const window = root.niriWindow();
		if (!window) return;
		if (root.editing) root.stopEditing();
		const size = window.layout?.window_size ?? [1280, 760];
		const screen = root.screenOf(window);
		if (!root.pip) {
			if (root.fullscreen) {
				root.fullscreen = false;
				root.niri(["fullscreen-window", "--id", "@id"]);
			}
			root.bigSize = Qt.size(size[0], size[1]);
			root.pip = true;
			const w = Math.round(Math.max(320, Math.min(560, (screen?.width ?? 1920) * 0.24)));
			const h = Math.round(w / Math.max(0.5, Math.min(2.6, root.aspect)));
			root.pipSize = Qt.size(w, h);
			root.placePip(w, h, screen);
		} else {
			root.pip = false;
			Niri.inOrder([
				["niri", "msg", "action", "set-window-width", "--id", String(window.id), String(Math.round(root.bigSize.width))],
				["niri", "msg", "action", "set-window-height", "--id", String(window.id), String(Math.round(root.bigSize.height))],
				["niri", "msg", "action", "center-window", "--id", String(window.id)],
				["niri", "msg", "action", "focus-window", "--id", String(window.id)]
			]);
		}
	}

	property size pipSize: Qt.size(426, 240)

	function placePip(w, h, screen) {
		const window = root.niriWindow();
		if (!window) return;
		const margin = 24;
		const sw = screen?.width ?? 1920, sh = screen?.height ?? 1080;
		const corner = root.pipCorner;
		const x = corner.endsWith("r") ? sw - w - margin : margin;
		const y = corner.startsWith("b") ? sh - h - margin - 40 : margin + 40;
		Niri.inOrder([
			["niri", "msg", "action", "set-window-width", "--id", String(window.id), String(w)],
			["niri", "msg", "action", "set-window-height", "--id", String(window.id), String(h)],
			["niri", "msg", "action", "move-floating-window", "--id", String(window.id), "-x", String(Math.round(x)), "-y", String(Math.round(y))]
		]);
	}

	function pipTo(corner) {
		root.setSetting("pipCorner", corner);
		if (root.pip) root.placePip(root.pipSize.width, root.pipSize.height, root.screenOf(root.niriWindow()));
	}

	function followWorkspace() {
		if (!root.pip) return;
		const window = root.niriWindow();
		const focused = Niri.workspaces.find(w => w.is_focused);
		if (!window || !focused || window.workspace_id === focused.id) return;
		Niri.moveWindow(window.id, focused);
		pipPlace.restart();
	}

	Timer {
		id: pipPlace

		interval: 250
		onTriggered: if (root.pip) root.placePip(root.pipSize.width, root.pipSize.height, root.screenOf(root.niriWindow()))
	}

	// ── on the bus: media keys, the bar, the phone, the watch ──────────────
	property string mprisArt: ""

	Timer {
		id: mprisSend

		interval: 120
		onTriggered: root.publish()
	}

	function publish() {
		if (!helper.running && !root.current) return;
		if (!root.current || !root.player || (!root.windowOpen && !root.playing)) {
			if (helper.running) root.request("state", { state: null });
			return;
		}
		root.request("state", { state: {
			title: root.title, artist: root.episode?.label ?? (root.list.length > 1 ? `${root.index + 1} of ${root.list.length}` : "Video"),
			art: root.mprisArt, url: root.fileUrl(root.path), position: root.position, length: root.duration,
			rate: root.speed, playing: root.playing, canNext: root.hasNext, canPrev: root.hasPrevious || root.position > 5, canSeek: true
		} });
	}

	onPathChanged: {
		root.startPending = root.path !== "";
		root.mprisArt = "";
		if (!root.path) return;
		const path = root.path;
		root.frameOf(path, Math.min(60, (root.metas[path]?.duration ?? 600) * 0.1), file => {
			if (root.path === path) {
				root.mprisArt = file;
				mprisSend.restart();
			}
		}, 480);
	}

	function busCommand(command, value) {
		switch (command) {
		case "play": return root.play();
		case "pause": return root.pause();
		case "toggle": return root.toggle();
		case "stop": return root.pause();
		case "next": return root.hasNext ? root.next() : root.seekBy(30);
		case "previous": return root.previous();
		case "seek": return root.seek(Number(value) || 0);
		case "rate": return root.setSpeed(Number(value) || 1);
		case "raise": return root.showWindow();
		}
	}

	// ── with the rest of the shell ─────────────────────────────────────────
	// a video with sound starts: the music waits, and goes on after it
	property bool pausedMusic: false

	function followMusic() {
		if (root.playing && root.hasAudio && !root.muted) {
			musicBack.stop();
			if (root.setting("pauseMusic", true) && Music.enabled && Music.playing) {
				root.pausedMusic = true;
				Music.pause();
			}
		} else if (root.pausedMusic) musicBack.restart();
	}

	Timer {
		id: musicBack

		interval: 4000
		onTriggered: {
			if (root.playing || !root.pausedMusic) return;
			root.pausedMusic = false;
			if (!root.windowOpen || root.ended) Music.play();
		}
	}

	onWindowOpenChanged: {
		mprisSend.restart();
		if (!root.windowOpen && root.pausedMusic) {
			root.pausedMusic = false;
			Music.play();
		}
	}

	// a break (stretching, resting the eyes), the lock screen, a game: paused, on again after
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

	Connections {
		target: Session

		function onLockedChanged() {
			if (Session.locked && root.playing) root.pause();
		}
	}

	readonly property bool gameOn: Plugins.on("games") && GameMode.playing
	property bool pausedForGame: false

	onGameOnChanged: {
		if (root.gameOn && root.playing && root.setting("games", true) && !root.pip) {
			root.pausedForGame = true;
			root.pause();
		} else if (!root.gameOn) root.pausedForGame = false;
	}

	// the headphones went (Media paused everyone): when they come back, on again
	property bool pausedForHeadphones: false

	Connections {
		target: Audio

		function onHeadphonesLost() {
			if (root.playing) {
				root.pausedForHeadphones = true;
				root.pause();
			}
		}

		function onOnHeadphonesChanged() {
			if (Audio.onHeadphones && root.pausedForHeadphones) {
				root.pausedForHeadphones = false;
				root.play();
			}
		}
	}

	// the picture's colour for the whole shell and the lights, from the
	// tiles along the video (read once by the helper, nothing is grabbed)
	readonly property bool tintsShell: root.enabled && root.setting("shellAccent", false) && root.playing && !!root.sprite
	readonly property bool lightsOn: root.enabled && Plugins.on("lighting") && root.setting("lighting", false) && root.playing && root.windowOpen
	property string colourNow: ""
	property int litTile: -1

	function followColour(at) {
		const i = root.tileAt(root.sprite, at);
		if (i < 0) return;
		const colours = root.sprite.colors?.[i];
		const accent = colours?.avg ?? root.sprite.accent ?? "";
		if (accent && accent !== root.colourNow) {
			root.colourNow = accent;
			if (root.tintsShell) Theme.accentOverride = accent;
		}
		if (root.lightsOn && i !== root.litTile && Date.now() - root.litAt > 3500) {
			root.litTile = i;
			root.litAt = Date.now();
			const path = root.path;
			root.frameOf(path, root.sprite.times[i], file => {
				if (file && root.lightsOn) Quickshell.execDetached(["python3", `${Paths.scripts}/apply_lighting.py`, file]);
			}, 160);
			root.lit = true;
		}
	}

	property real litAt: 0
	property bool lit: false

	onTintsShellChanged: if (!root.tintsShell && root.colourNow !== "") {
		Theme.accentOverride = "transparent";
		root.colourNow = "";
	}
	onLightsOnChanged: if (!root.lightsOn && root.lit) lightsBack.restart()

	Timer {
		id: lightsBack

		interval: 20000
		onTriggered: {
			if (root.lightsOn || !root.lit) return;
			root.lit = false;
			root.litTile = -1;
			Quickshell.execDetached(["python3", `${Paths.scripts}/apply_lighting.py`]);
		}
	}

	// sleeping: the film fades out at a time or at its end
	property real sleepAt: 0
	property real fadeLevel: 1

	function sleep(minutes) {
		const m = Number(minutes);
		if (m < 0) {
			root.sleepAt = -1;
			root.say("Stops at the end of this video", "sleep");
		} else if (m > 0) {
			root.sleepAt = Date.now() + m * 60000;
			root.say(`Fades out in ${m} minutes`, "sleep");
		} else {
			root.sleepAt = 0;
			sleepFade.stop();
			root.fadeLevel = 1;
		}
	}

	Timer {
		running: root.sleepAt !== 0 && root.playing
		repeat: true
		interval: 1000
		onTriggered: {
			const end = root.sleepAt === -1 && root.duration > 0 && root.position >= root.duration - 12;
			if ((root.sleepAt > 0 && Date.now() >= root.sleepAt) || end) {
				root.sleepAt = 0;
				sleepFade.start();
			}
		}
	}

	NumberAnimation {
		id: sleepFade

		target: root
		property: "fadeLevel"
		from: 1
		to: 0
		duration: 12000
		onStopped: {
			root.pause();
			root.fadeLevel = 1;
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
		case "job":
			root.jobEvent(m);
			break;
		case "command":
			root.busCommand(m.command, m.value);
			break;
		case "error":
			console.warn(`video: ${m.error}`);
			break;
		}
	}

	Process {
		id: helper

		stdinEnabled: true
		command: ["python3", "-u", root.helperScript]
		stdout: SplitParser {
			onRead: line => root.receive(line)
		}
		stderr: SplitParser {
			onRead: line => console.warn(`video: ${line}`)
		}
		onRunningChanged: {
			if (!helper.running) return;
			for (const line of root.queued) helper.write(line);
			root.queued = [];
		}
		onExited: {
			for (const id in root.callbacks) root.callbacks[id](null, "The video helper stopped");
			root.callbacks = {};
			for (const id in root.jobDone) root.jobDone[id](null);
			root.jobDone = {};
			root.jobs = {};
			root.spritesAsked = {};
		}
	}

	// the helper goes when nothing is open and nothing runs for a while
	Timer {
		id: idleTimer

		interval: 300000
		onTriggered: {
			if (root.windowOpen || root.playing || root.runningJobs.length > 0 || Object.keys(root.callbacks).length > 0) idleTimer.restart();
			else if (helper.running) helper.write(JSON.stringify({ op: "quit" }) + "\n");
		}
	}

	onEnabledChanged: {
		if (!root.enabled) {
			root.close();
			if (helper.running) helper.write(JSON.stringify({ op: "quit" }) + "\n");
		}
		root.applyDefault();
	}

	// ── as an app of the desktop ───────────────────────────────────────────
	// "Pshell Video" is there while the plugin is on; with video-default
	// videos opened anywhere come here (scripts/video/default.py)
	readonly property bool isDefault: root.enabled && Plugins.on("video-default")
	property bool entryInstalled: false

	function applyDefault() {
		if (!root.enabled && !root.entryInstalled) return;
		defaultProc.command = ["python3", `${Paths.scripts}/video/default.py`, !root.enabled ? "remove" : (root.isDefault ? "on" : "off")];
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
	property bool watching: false

	function say(text, icon) {
		if (root.windowOpen && root.watching) root.said(text, icon || "information_outline");
		else Notifs.pushInternal("done", text, "", { app: "Video", icon: icon || "movie_outline" });
	}
}
