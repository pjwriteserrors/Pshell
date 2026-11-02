pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import QtMultimedia
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The built-in player. It starts where the video was left and says so, tells the
// daemon how far it got, skips sponsor segments, runs quickly through silence,
// follows the loudness, and goes dark around the picture while nothing is touched.
//   Space/K play, ←/→ 10 s, 0-9 jump, ↑/↓ volume, M mute, F fullscreen, N next,
//   PgUp/PgDn chapters, </> speed, C subtitles, B note, S picture, T link, I mini,
//   P picture in picture, W who is this, Q ask, X keep a clip, H highlights,
//   Esc leave, ? keys
Rectangle {
	id: root

	property bool canMini: false
	readonly property bool mini: root.canMini && Streams.playerMini
	readonly property var item: Streams.player
	readonly property string video: root.item?.video ?? ""
	readonly property bool live: root.item?.live ?? false
	readonly property bool spoiler: root.item?.spoiler ?? false
	readonly property string seriesId: root.item?.series ?? ""
	property string address: ""
	property string error: ""
	property string loadStep: "ask"
	property var qualities: []
	property int height_: 0
	property var segments: []
	property var chapters: []
	property var storyboard: null
	property var captions: []
	property var cues: []
	property string captionLang: ""
	property real seekTo: 0
	property bool started: false
	property bool landed: false
	property real lastSent: 0
	property real knownDuration: 0
	property bool resumed: false
	property string note: ""
	property real speed: 1
	readonly property real duration: player.duration > 0 ? player.duration / 1000 : root.knownDuration
	readonly property real position: player.position / 1000
	readonly property bool playing: player.playbackState === MediaPlayer.PlayingState
	readonly property bool waiting: root.error === "" && (root.address === "" || player.mediaStatus === MediaPlayer.LoadingMedia || player.mediaStatus === MediaPlayer.BufferingMedia || player.mediaStatus === MediaPlayer.StalledMedia)
	// the first picture has not come yet: the line that says what happens
	readonly property bool loadingShown: root.error === "" && !root.landed
	readonly property real ui: root.mini ? 1 : Math.max(1, root.width / 1500)
	property bool awake: true
	property bool menuOpen: false
	// "" | chapters | notes | search | chat | together | who | ask | clips | highlights
	property string panel: ""
	property bool noting: false
	property bool keysOpen: false
	readonly property bool controlsShown: root.awake || !root.playing || root.error !== "" || root.menuOpen || root.noting || root.panel !== ""
	// sleep: minutes left, -1 for the end of this episode, 0 for off
	property real sleepAt: 0
	property bool sleepAtEnd: false
	property string lastLive: ""
	property var liveOffer: null
	property var savedLights: null
	readonly property var marks: Streams.playerMarks
	readonly property var introPart: {
		const found = root.segments.find(segment => segment[2] === "intro");
		if (found) return [found[0], found[1]];
		return root.marks.intro ?? null;
	}
	readonly property var outroPart: {
		const found = root.segments.find(segment => segment[2] === "outro");
		if (found) return [found[0], found[1]];
		return root.marks.outro ?? null;
	}
	readonly property int chapterIndex: {
		let found = -1;
		for (let i = 0; i < root.chapters.length; i += 1) if (root.chapters[i].at <= root.position) found = i;
		return found;
	}
	readonly property string chapterName: !root.spoiler && root.chapterIndex >= 0 ? root.chapters[root.chapterIndex].title : ""
	readonly property string cueText: {
		if (root.cues.length === 0) return "";
		let low = 0, high = root.cues.length - 1, found = -1;
		const at = root.position;
		while (low <= high) {
			const mid = (low + high) >> 1;
			if (root.cues[mid].s <= at) {
				found = mid;
				low = mid + 1;
			} else {
				high = mid - 1;
			}
		}
		return found >= 0 && at < root.cues[found].e + 0.4 ? root.cues[found].t : "";
	}

	function takeFocus() {
		keys.forceActiveFocus();
	}

	function wake() {
		root.awake = true;
		sleep.restart();
	}

	function report() {
		if (root.video && root.landed && root.position > 0 && !root.live) Streams.call("playerPosition", { video: root.video, position: root.position, duration: root.duration });
	}

	// what everybody else sees of this player (mpris.py): the bar, the phone, the watch
	function publish() {
		const item = root.item;
		if (!item || root.leaving) return;
		const introNow = !!root.intro;
		const part = item.seriesName ? item.seriesName : item.channel;
		Streams.call("playerState", {
			video: root.video, title: introNow ? `Previously: ${root.intro.title}` : item.title, artist: part ?? "", album: item.seriesName ?? "", art: item.thumb ?? "", url: root.item?.syncTest ? "" : (item.url ?? ""),
			position: introNow ? (introLoader.item?.position ?? 0) : root.position, length: root.live ? 0 : (introNow ? (introLoader.item?.duration ?? 0) : root.duration), rate: root.speed, volume: root.baseVolume,
			playing: introNow ? (introLoader.item?.playing ?? true) : root.playing, canSeek: !root.live && !introNow
		});
	}

	Timer {
		interval: 5000
		repeat: true
		running: !!root.item
		onTriggered: root.publish()
	}

	Connections {
		target: Streams

		function onPlayerCommand(what, value) {
			if (root.mini && !Streams.playerMini) return;
			if (root.intro) {
				if (what === "toggle" || what === "play" || what === "pause") introLoader.item?.command(what);
				else if (what === "next" || what === "stop") introLoader.item?.end();
				Qt.callLater(root.publish);
				return;
			}
			switch (what) {
			case "toggle":
				root.playing ? player.pause() : player.play();
				break;
			case "play":
				player.play();
				break;
			case "pause":
				player.pause();
				break;
			case "stop":
				root.leave();
				return;
			case "next":
				if (root.video) {
					root.report();
					Streams.call("playerEnded", { video: root.video });
				}
				break;
			case "previous":
				root.goTo(0);
				break;
			case "seek":
				root.goTo(value);
				break;
			case "rate":
				root.setSpeed(value);
				break;
			case "volume":
				root.setVolume(value);
				break;
			case "raise":
				if (root.canMini) Streams.playerMini = false;
				Streams.open();
				break;
			}
			Qt.callLater(root.publish);
		}
	}

	function leave() {
		const args = root.video ? { video: root.video, position: root.landed ? root.position : 0, duration: root.duration } : {};
		// stopping tells everybody it plays no more, and this view may go with the last line
		root.leaving = true;
		player.stop();
		Streams.call("playerClosed", args);
		root.restoreLights();
		Streams.playerMini = false;
		Streams.player = null;
	}

	function resolve(quality, fresh) {
		root.error = "";
		root.loadStep = "ask";
		const args = root.video ? { video: root.video } : { url: root.item?.url ?? "" };
		if (quality) args.quality = quality;
		if (fresh) args.fresh = true;
		const asked = root.loaded;
		Streams.call("resolve", args, (data, error) => {
			if (asked !== root.loaded) return;
			if (error) {
				root.error = error;
				return;
			}
			root.qualities = data.qualities;
			root.height_ = data.height;
			root.segments = data.segments ?? [];
			root.storyboard = data.storyboard ?? null;
			root.captions = data.captions ?? [];
			if (data.chapters?.length > 0) root.chapters = data.chapters;
			if (data.marks && Object.keys(data.marks).length > 0) Streams.playerMarks = data.marks;
			if (data.duration) root.knownDuration = data.duration;
			root.loadStep = "connect";
			root.address = data.url;
			// behind the short video it only gets ready; the end of that starts it
			if (root.intro) player.pause();
			else player.play();
			const lang = root.item?.prefs?.captions ?? Streams.settings.subtitles ?? "";
			if (lang) root.pickCaption(lang);
		});
	}

	property string loaded: ""
	property bool leaving: false

	function load() {
		const key = root.item ? (root.video || root.item.url) : "";
		if (key === root.loaded) return;
		root.loaded = key;
		player.stop();
		root.address = "";
		root.started = false;
		root.landed = false;
		root.resumed = false;
		root.note = "";
		root.cues = [];
		root.captionLang = "";
		root.chapters = root.item?.chapters ?? [];
		root.seekTo = root.item?.start ?? 0;
		root.knownDuration = root.item?.duration ?? 0;
		root.speed = root.item?.rate ?? 1;
		root.lastLive = "";
		root.intro = root.item?.recapVideo ?? null;
		root.retried = false;
		root.leaving = false;
		root.digest = [];
		root.moments = [];
		const prefs = root.item?.prefs ?? {};
		root.baseVolume = prefs.volume ?? Streams.settings.volume ?? 0.8;
		if (root.item) {
			root.resolve(prefs.quality ?? 0);
			root.syncLights();
			root.publish();
			if (root.video && !root.spoiler) Streams.call("highlights", { video: root.video }, data => root.moments = data?.moments ?? []);
		} else {
			Streams.call("playerState", { gone: true });
		}
	}

	function endIntro() {
		if (!root.intro) return;
		root.intro = null;
		if (root.address !== "") player.play();
	}

	// an address that went stale, or the network away for a moment: once more, newly asked
	property bool retried: false

	Timer {
		interval: 15000
		running: root.loadStep === "connect" && root.address !== "" && !root.started && !root.retried && !root.intro && root.error === ""
		onTriggered: {
			root.retried = true;
			player.stop();
			root.address = "";
			root.resolve(0, true);
		}
	}

	// a video that stops moving while it plays (YouTube gave nothing more, an
	// address went stale, the daemon started again): asked anew, on from there
	property real stuckAt: -1
	property int stuckFor: 0
	property real recoveredAt: 0

	Timer {
		interval: 1000
		repeat: true
		running: root.landed && root.playing && !root.intro && !root.live && root.address !== "" && root.error === ""
		onTriggered: {
			if (Math.abs(player.position - root.stuckAt) > 50) {
				root.stuckAt = player.position;
				root.stuckFor = 0;
				return;
			}
			root.stuckFor += 1;
			if (root.stuckFor >= 8) root.recover("The stream stalled, asked again");
		}
	}

	function recover(why) {
		// not again and again: once in half a minute
		if (Date.now() - root.recoveredAt < 30000) return;
		root.recoveredAt = Date.now();
		root.stuckFor = 0;
		root.seekTo = root.position;
		root.started = false;
		root.landed = false;
		player.stop();
		root.address = "";
		root.resolve(root.height_, true);
		root.say(why);
	}

	// only the moments that stand out: jumps from one to the next, nothing is cut
	property var digest: []
	property var moments: []

	function keepClip() {
		if (!root.video || root.live) return;
		Streams.call("clipAdd", { video: root.video, at: root.position });
		root.say("Kept the last 30 seconds");
	}

	function jumpTo(video, at) {
		if (video === root.video) root.goTo(at);
		else Streams.call("play", { video: video, player: "app", at: at });
	}

	function followDigest(now) {
		if (root.digest.length === 0 || !root.playing) return;
		if (root.digest.some(part => now >= part.at && now < part.end)) return;
		const next = root.digest.find(part => part.at > now);
		if (next) {
			player.position = next.at * 1000;
		} else {
			root.digest = [];
			root.say("That was all of it");
			player.pause();
		}
	}

	function setDigest(parts) {
		root.digest = parts;
		root.panel = "";
		if (parts.length > 0) {
			player.position = parts[0].at * 1000;
			root.say(`Only the ${parts.length} moments that stand out`);
		}
	}

	function say(text) {
		root.note = text;
		noteTimer.restart();
	}

	function nudge(seconds) {
		player.position = Math.max(0, Math.min(root.duration, root.position + seconds)) * 1000;
		root.say(seconds > 0 ? `+${seconds} s` : `${seconds} s`);
		root.wake();
		root.shareState();
		Qt.callLater(root.publish);
	}

	function goTo(seconds) {
		player.position = Math.max(0, seconds) * 1000;
		root.resumed = false;
		root.wake();
		root.shareState();
		Qt.callLater(root.publish);
	}

	function setVolume(value) {
		const next = Math.max(0, Math.min(1, value));
		Streams.setSetting("volume", next);
		if (root.seriesId) Streams.call("seriesPrefs", { series: root.seriesId, volume: next });
		output.muted = false;
		root.baseVolume = next;
		root.say(`Volume ${Math.round(next * 100)} %`);
		root.wake();
	}

	property int soundLead: 0
	// { file, title }: the short video of the episode before, playing first
	property var intro: null

	function askSound() {
		Streams.call("soundLead", {}, data => {
			if (data) root.soundLead = data.ms;
		});
	}

	function moveSound(by) {
		root.soundLead += by;
		Streams.call("soundLead", { ms: root.soundLead }, data => {
			if (data) root.soundLead = data.ms;
		});
		soundAgain.restart();
	}

	// what is buffered has the old timing: a seek to here reads it again
	Timer {
		id: soundAgain

		interval: 500
		onTriggered: player.position = root.position * 1000
	}

	function setSpeed(rate) {
		root.speed = Math.max(0.25, Math.min(3, rate));
		root.say(`Speed ${root.speed}×`);
		if (root.seriesId) Streams.call("speed", { series: root.seriesId, rate: root.speed });
		root.shareState();
	}

	function pickCaption(lang) {
		Streams.setSetting("subtitles", lang);
		if (root.seriesId) Streams.call("seriesPrefs", { series: root.seriesId, captions: lang });
		root.captionLang = lang;
		root.cues = [];
		if (!lang) return;
		// the wish may be just "en": the closest there is
		const track = root.captions.find(entry => entry.lang === lang) ?? root.captions.find(entry => entry.lang.startsWith(lang.split("-")[0]));
		if (!track) return;
		Streams.call("subtitles", { url: track.url }, data => {
			if (root.captionLang === lang) root.cues = data?.cues ?? [];
		});
	}

	function toggleCaptions() {
		if (root.captionLang) return root.pickCaption("");
		const first = root.captions.find(entry => !entry.auto) ?? root.captions.find(entry => entry.lang.endsWith("-orig")) ?? root.captions[0];
		if (first) {
			root.pickCaption(first.lang);
			root.say(`Subtitles: ${first.name}`);
		}
	}

	function nextChapter(delta) {
		if (root.chapters.length === 0) return;
		const index = Math.max(0, Math.min(root.chapters.length - 1, root.chapterIndex + delta));
		root.goTo(root.chapters[index].at);
		if (!root.spoiler) root.say(root.chapters[index].title);
	}

	function screenshot() {
		const folder = `${Paths.home}/Pictures/Streams`;
		const stamp = Streams.clock(root.position).replace(/:/g, "-");
		const name = `${(root.item?.title ?? "video").replace(/[^\w -]+/g, "").slice(0, 60)} ${stamp}.png`;
		Quickshell.execDetached(["mkdir", "-p", folder]);
		picture.grabToImage(result => {
			result.saveToFile(`${folder}/${name}`);
			root.say("Picture saved");
		});
	}

	function copyLink() {
		const link = root.video ? `https://youtu.be/${root.video}?t=${Math.floor(root.position)}` : (root.item?.url ?? "");
		Quickshell.execDetached(["wl-copy", "--", link]);
		root.say("Link copied");
	}

	function pictureInPicture() {
		Streams.call("pipFrom", { video: root.video, url: root.item?.url ?? "", position: root.position });
		root.leave();
	}

	function toPhone() {
		root.report();
		Streams.toPhone(root.item?.url ?? "", root.position, root.item?.title ?? "");
		player.pause();
		root.say("Sent to the phone");
	}

	function fullscreen() {
		Quickshell.execDetached(["niri", "msg", "action", "fullscreen-window"]);
	}

	function setSleep(minutes) {
		root.sleepAtEnd = minutes < 0;
		root.sleepAt = minutes > 0 ? Date.now() + minutes * 60000 : 0;
		root.fading = false;
		output.muted = false;
		root.say(minutes === 0 ? "Sleep timer off" : (minutes < 0 ? "Stops after this episode" : `Stops in ${minutes} min`));
	}

	function syncLights() {
		if (!Plugins.on("lighting") && !Lighting.enabled) return;
		if ((Streams.settings.roomLights ?? false) && !root.savedLights) {
			root.savedLights = Object.assign({}, Lighting.modes);
			for (const device of Lighting.devices) Lighting.setMode(device.id, "live");
		} else if (!(Streams.settings.roomLights ?? false)) {
			root.restoreLights();
		}
	}

	function restoreLights() {
		if (!root.savedLights) return;
		const saved = root.savedLights;
		root.savedLights = null;
		for (const device of Lighting.devices) Lighting.setMode(device.id, saved[device.id] ?? "wallpaper");
	}

	// ── together ───────────────────────────────────────────────────────
	property real appliedAt: 0

	function shareState() {
		if (!(Streams.together.role) || !root.video || Date.now() - root.appliedAt < 900) return;
		Streams.call("together", { what: "send", video: root.video, position: root.position, paused: !root.playing, title: root.item?.title ?? "", rate: root.speed });
	}

	Connections {
		target: Streams

		function onTogetherState(state) {
			root.appliedAt = Date.now();
			if (state.video !== root.video) return;
			if (Math.abs(root.position - state.position) > 2) player.position = state.position * 1000;
			root.speed = state.rate;
			if (state.paused && root.playing) player.pause();
			if (!state.paused && !root.playing) player.play();
		}
		function onLiveStreamsChanged() {
			// somebody went live while something else plays
			const known = root.knownLive;
			const fresh = Streams.liveStreams.filter(stream => !known.includes(stream.source) && stream.source !== root.item?.source);
			root.knownLive = Streams.liveStreams.map(stream => stream.source);
			if (fresh.length > 0 && !root.live) {
				root.liveOffer = fresh[0];
				offerTimer.restart();
			}
		}
	}

	property var knownLive: Streams.liveStreams.map(stream => stream.source)

	color: "black"
	radius: root.mini ? Theme.radius.large : 0
	clip: root.mini

	onItemChanged: root.load()
	Connections {
		target: Streams

		function onPlayerPanelWantedChanged() {
			if (Streams.playerPanelWanted !== "-") root.panel = Streams.playerPanelWanted;
			Streams.playerPanelWanted = "-";
		}
	}
	Component.onCompleted: {
		root.load();
		root.askSound();
	}
	onPlayingChanged: {
		root.shareState();
		root.publish();
	}
	onLandedChanged: root.publish()
	onDurationChanged: root.publish()
	onIntroChanged: Qt.callLater(root.publish)
	Component.onDestruction: {
		root.restoreLights();
		if (Streams.player && root.video) Streams.player = Object.assign({}, Streams.player, { start: root.landed ? root.position : Streams.player.start });
	}

	property real baseVolume: Streams.settings.volume ?? 0.8
	property real gainNow: 1
	property bool fading: false
	property real fade: 1

	MediaPlayer {
		id: player

		source: root.address
		videoOutput: picture
		playbackRate: root.inSilence ? Math.max(root.speed * 2.5, 2.5) : root.speed
		audioOutput: AudioOutput {
			id: output

			muted: !!Quickshell.env("STREAMS_TEST_MUTE")
			volume: Math.max(0, Math.min(1, root.baseVolume * root.gainNow * root.fade))
		}
		onErrorOccurred: (code, text) => {
			if (!root.landed) root.error = text || "The video could not be played";
			else if (!root.live) root.recover("The stream broke off, asked again");
		}
		onMediaStatusChanged: {
			// where it was left; the stream may need a moment before it can jump
			if ((mediaStatus === MediaPlayer.BufferedMedia || mediaStatus === MediaPlayer.LoadedMedia || mediaStatus === MediaPlayer.BufferingMedia) && !root.started) {
				root.started = true;
				root.error = "";
				if (root.seekTo > 5 && seekable && !root.live) {
					root.loadStep = "seek";
					player.position = root.seekTo * 1000;
					root.resumed = true;
					resumeTimer.restart();
				} else {
					root.loadStep = "buffer";
				}
			}
			if (mediaStatus === MediaPlayer.BufferingMedia && root.started && !root.landed) root.loadStep = "buffer";
			if (mediaStatus === MediaPlayer.BufferedMedia && root.started) root.landed = true;
			if (mediaStatus === MediaPlayer.EndOfMedia && root.video) {
				root.report();
				if (root.sleepAtEnd) {
					root.leave();
					return;
				}
				Streams.call("playerEnded", { video: root.video });
			}
		}
		onPlaybackStateChanged: if (playbackState === MediaPlayer.PausedState) root.report()
		onPositionChanged: {
			const now = player.position / 1000;
			if (now > 0.2 && root.started && playbackState === MediaPlayer.PlayingState) root.landed = true;
			for (const segment of root.segments) {
				if (segment[2] === "intro" || segment[2] === "outro") continue;
				if (now >= segment[0] && now < segment[1] - 0.3 && playbackState === MediaPlayer.PlayingState) {
					player.position = segment[1] * 1000;
					root.say(`Sponsor skipped (${Math.round(segment[1] - segment[0])} s)`);
					break;
				}
			}
			root.follow(now);
			root.followDigest(now);
			if (Date.now() - root.lastSent > 5000) {
				root.lastSent = Date.now();
				root.report();
			}
		}
	}

	property bool inSilence: false

	// what listening found: silence runs quickly, the volume follows the loudness
	function follow(now) {
		if (Streams.settings.trimSilence && root.marks.silences) {
			root.inSilence = root.marks.silences.some(part => now >= part[0] && now < part[1]);
		} else if (root.inSilence) {
			root.inSilence = false;
		}
		const gains = root.marks.gains;
		if (Streams.settings.evenLoudness && gains) {
			const value = gains[Math.floor(now)];
			root.gainNow = value === undefined ? 1 : Math.pow(10, value / 20);
		} else {
			root.gainNow = 1;
		}
	}

	Behavior on gainNow {
		NumberAnimation {
			duration: 500
		}
	}

	// ── the picture ─────────────────────────────────────────────────────
	// the colours of the video around it, when asked for
	readonly property bool ambient: (Streams.settings.ambient ?? false) && !root.mini && root.landed

	ShaderEffectSource {
		id: ambientSource

		sourceItem: picture
		live: root.ambient
		hideSource: false
		visible: false
		textureSize: Qt.size(64, 36)
		smooth: true
	}

	MultiEffect {
		anchors.fill: picture
		scale: 1.16
		source: ambientSource
		visible: root.ambient
		blurEnabled: true
		blur: 1
		blurMax: 64
		saturation: 0.5
		brightness: 0.05
		autoPaddingEnabled: false
		opacity: 0.9
	}

	readonly property real panelWidth: root.panel !== "" && !root.mini ? 430 * root.ui : 0

	Thumb {
		anchors.fill: picture
		radius: 0
		source: root.item?.thumb ?? ""
		large: Streams.large(root.item?.large ?? "")
		opacity: root.landed ? 0 : 1
		visible: opacity > 0.01

		Behavior on opacity {
			Anim {
				duration: Motion.extraLong
			}
		}
	}

	VideoOutput {
		id: picture

		x: root.ambient ? (root.width - root.panelWidth) * 0.07 : 0
		y: root.ambient ? root.height * 0.07 : 0
		width: (root.width - root.panelWidth) * (root.ambient ? 0.86 : 1)
		height: root.height * (root.ambient ? 0.86 : 1)
		opacity: root.landed ? 1 : 0

		Behavior on width {
			SpatialAnim {
				duration: Motion.long
			}
		}
		Behavior on height {
			SpatialAnim {
				duration: Motion.long
			}
		}
		Behavior on x {
			SpatialAnim {
				duration: Motion.long
			}
		}
		Behavior on y {
			SpatialAnim {
				duration: Motion.long
			}
		}
	}

	// dark while it loads, so the words read
	Rectangle {
		anchors.fill: picture
		color: Qt.rgba(0, 0, 0, 0.5)
		opacity: root.loadingShown ? 1 : 0
		visible: opacity > 0.01

		Behavior on opacity {
			Anim {}
		}
	}

	Item {
		id: keys

		anchors.fill: parent
		focus: true
		Keys.onPressed: event => {
			if (root.mini) return;
			if (root.intro && (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_N)) {
				introLoader.item?.end();
				event.accepted = true;
				return;
			}
			root.wake();
			if (event.key >= Qt.Key_0 && event.key <= Qt.Key_9 && !root.live) {
				root.goTo(root.duration * (event.key - Qt.Key_0) / 10);
				event.accepted = true;
				return;
			}
			switch (event.key) {
			case Qt.Key_Space:
			case Qt.Key_K:
				root.playing ? player.pause() : player.play();
				break;
			case Qt.Key_Left:
			case Qt.Key_J:
				root.nudge(-10);
				break;
			case Qt.Key_Right:
			case Qt.Key_L:
				root.nudge(10);
				break;
			case Qt.Key_Up:
				root.setVolume(root.baseVolume + 0.05);
				break;
			case Qt.Key_Down:
				root.setVolume(root.baseVolume - 0.05);
				break;
			case Qt.Key_M:
				output.muted = !output.muted;
				root.say(output.muted ? "Muted" : "Sound on");
				break;
			case Qt.Key_F:
				root.fullscreen();
				break;
			case Qt.Key_N:
				if (root.video) {
					root.report();
					Streams.call("playerEnded", { video: root.video });
				}
				break;
			case Qt.Key_PageUp:
				root.nextChapter(-1);
				break;
			case Qt.Key_PageDown:
				root.nextChapter(1);
				break;
			case Qt.Key_Less:
			case Qt.Key_Comma:
				root.setSpeed(root.speed - 0.25);
				break;
			case Qt.Key_Greater:
			case Qt.Key_Period:
				root.setSpeed(root.speed + 0.25);
				break;
			case Qt.Key_C:
				root.toggleCaptions();
				break;
			case Qt.Key_B:
				root.noting = true;
				noteField.input.forceActiveFocus();
				break;
			case Qt.Key_S:
				root.screenshot();
				break;
			case Qt.Key_T:
				root.copyLink();
				break;
			case Qt.Key_I:
				if (root.canMini) Streams.playerMini = true;
				break;
			case Qt.Key_P:
				root.pictureInPicture();
				break;
			case Qt.Key_W:
				if (root.seriesId) root.panel = root.panel === "who" ? "" : "who";
				break;
			case Qt.Key_Q:
				if (root.seriesId) root.panel = root.panel === "ask" ? "" : "ask";
				break;
			case Qt.Key_X:
				root.keepClip();
				break;
			case Qt.Key_H:
				if (root.video) root.panel = root.panel === "highlights" ? "" : "highlights";
				break;
			case Qt.Key_G:
				root.menuOpen = !root.menuOpen;
				break;
			case Qt.Key_Question:
				root.keysOpen = !root.keysOpen;
				break;
			case Qt.Key_Escape:
				if (root.keysOpen) root.keysOpen = false;
				else if (root.menuOpen) root.menuOpen = false;
				else if (root.panel !== "") root.panel = "";
				else root.leave();
				break;
			default:
				return;
			}
			event.accepted = true;
		}
	}

	MouseArea {
		anchors.fill: parent
		hoverEnabled: true
		cursorShape: root.controlsShown ? Qt.ArrowCursor : Qt.BlankCursor
		onPositionChanged: root.wake()
		onClicked: {
			if (root.mini) {
				Streams.playerMini = false;
				return;
			}
			if (root.menuOpen) {
				root.menuOpen = false;
				return;
			}
			root.playing ? player.pause() : player.play();
			root.wake();
			root.takeFocus();
		}
		onDoubleClicked: if (!root.mini) root.fullscreen()
	}

	Timer {
		id: sleep

		interval: 2800
		running: true
		onTriggered: root.awake = false
	}
	Timer {
		id: noteTimer

		interval: 1500
		onTriggered: root.note = ""
	}
	Timer {
		id: resumeTimer

		interval: 7000
		onTriggered: root.resumed = false
	}
	Timer {
		id: offerTimer

		interval: 25000
		onTriggered: root.liveOffer = null
	}
	// the sleep timer: the last half minute gets quieter
	Timer {
		interval: 1000
		repeat: true
		running: root.sleepAt > 0
		onTriggered: {
			const left = (root.sleepAt - Date.now()) / 1000;
			root.fade = Math.max(0, Math.min(1, left / 30));
			if (left <= 0) {
				root.sleepAt = 0;
				root.fade = 1;
				root.leave();
			}
		}
	}

	// ── words on the picture ────────────────────────────────────────────
	// subtitles
	Rectangle {
		anchors.horizontalCenter: picture.horizontalCenter
		anchors.bottom: picture.bottom
		anchors.bottomMargin: (root.controlsShown ? 128 : 52) * root.ui
		visible: root.cueText !== "" && !root.mini
		width: Math.min(picture.width - 80, cueWord.implicitWidth + 28 * root.ui)
		height: cueWord.implicitHeight + 14 * root.ui
		radius: 8 * root.ui
		color: (Streams.settings.subtitleBox ?? true) ? Qt.rgba(0, 0, 0, 0.72) : "transparent"

		Behavior on anchors.bottomMargin {
			SpatialAnim {
				duration: Motion.long
			}
		}

		Text {
			id: cueWord

			anchors.centerIn: parent
			width: Math.min(implicitWidth, picture.width - 110)
			horizontalAlignment: Text.AlignHCenter
			text: root.cueText
			color: "white"
			wrapMode: Text.Wrap
			font.family: Theme.fontFamily
			font.pixelSize: 24 * root.ui * (Streams.settings.subtitleSize ?? 1)
			font.weight: Font.Medium
			style: (Streams.settings.subtitleBox ?? true) ? Text.Normal : Text.Outline
			styleColor: "black"
		}
	}

	PlayerLoading {
		anchors.fill: picture
		visible: root.loadingShown && !root.mini
		step: root.loadStep
		seekText: Streams.clock(root.seekTo)
		url: root.item?.url ?? ""
		ui: root.ui
	}
	Connections {
		target: Streams

		function onLoadingStepChanged() {
			const step = Streams.loadingStep;
			if (!step || root.address !== "") return;
			if (step.key === (root.video || root.item?.url)) root.loadStep = step.step;
		}
	}

	Spinner {
		anchors.centerIn: picture
		width: 56 * root.ui
		height: 56 * root.ui
		color: "white"
		visible: root.landed && root.waiting && root.error === ""
	}

	ColumnLayout {
		anchors.centerIn: picture
		width: Math.min(picture.width - 80, 620 * root.ui)
		visible: root.error !== "" && !root.mini
		spacing: 14 * root.ui

		Text {
			Layout.fillWidth: true
			horizontalAlignment: Text.AlignHCenter
			text: root.live ? "This stream won't play" : "This video won't play here"
			color: "white"
			font.family: Theme.fontFamily
			font.pixelSize: 28 * root.ui
			font.weight: Font.Black
		}
		Text {
			Layout.fillWidth: true
			horizontalAlignment: Text.AlignHCenter
			text: root.error
			color: Qt.rgba(1, 1, 1, 0.7)
			font.family: Theme.fontFamily
			font.pixelSize: 14 * root.ui
			wrapMode: Text.Wrap
		}
		BigButton {
			Layout.alignment: Qt.AlignHCenter
			text: "Open in the browser"
			icon: "open_in_new"
			onClicked: {
				Browser.open(root.item.url);
				root.leave();
			}
		}
	}

	Rectangle {
		anchors.centerIn: picture
		width: noteWord.implicitWidth + 36 * root.ui
		height: 50 * root.ui
		radius: 14 * root.ui
		color: Qt.rgba(0, 0, 0, 0.66)
		opacity: root.note !== "" && !root.mini ? 1 : 0
		scale: root.note !== "" ? 1 : 0.86
		visible: opacity > 0.01

		Behavior on opacity {
			Anim {
				duration: Motion.short
			}
		}
		Behavior on scale {
			SpatialAnim {
				duration: Motion.medium
			}
		}

		Text {
			id: noteWord

			anchors.centerIn: parent
			text: root.note
			color: "white"
			font.family: Theme.fontFamily
			font.pixelSize: 18 * root.ui
			font.weight: Font.Bold
		}
	}

	PauseCard {
		anchors.left: picture.left
		anchors.top: picture.top
		anchors.margins: 26 * root.ui
		anchors.topMargin: 90 * root.ui
		wanted: pauseSoon.seen && !root.playing && root.landed && !root.mini && root.panel === "" && !root.menuOpen && !root.intro && !root.live && !root.item?.syncTest
		seriesId: root.seriesId
		video: root.video
		position: root.position
		duration: root.duration
		rate: root.speed
		chapter: root.chapterName
		title: root.spoiler ? (root.item?.seriesName ?? "") : (root.item?.title ?? "")
		ui: root.ui
	}
	Timer {
		id: pauseSoon

		property bool seen: false

		interval: 1500
		repeat: true
		running: !root.playing && root.landed
		onRunningChanged: if (!running) seen = false
		onTriggered: seen = true
	}

	// the timing test: flash and beep, and the two buttons that bring them together
	Rectangle {
		anchors.horizontalCenter: parent.horizontalCenter
		anchors.bottom: parent.bottom
		anchors.bottomMargin: 130 * root.ui
		visible: !!root.item?.syncTest
		z: 40
		width: syncRow.implicitWidth + 40 * root.ui
		height: syncRow.implicitHeight + 28 * root.ui
		radius: 14 * root.ui
		color: Qt.rgba(0, 0, 0, 0.8)

		ColumnLayout {
			id: syncRow

			anchors.centerIn: parent
			spacing: 10 * root.ui

			Text {
				Layout.alignment: Qt.AlignHCenter
				text: root.soundLead === 0 ? "The beep is not moved" : `The beep comes ${Math.abs(root.soundLead)} ms ${root.soundLead > 0 ? "earlier" : "later"}`
				color: "white"
				font.family: Theme.fontFamily
				font.pixelSize: 18 * root.ui
				font.weight: Font.Bold
			}
			RowLayout {
				Layout.alignment: Qt.AlignHCenter

				TextButton {
					text: "Beep is early: later"
					onActivated: root.moveSound(-20)
				}
				TextButton {
					text: "Beep is late: earlier"
					onActivated: root.moveSound(20)
				}
				TextButton {
					text: "They meet"
					onActivated: root.leave()
				}
			}
		}
	}

	// ── small: only what is needed ─────────────────────────────────────
	Row {
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.margins: 8
		spacing: 4
		visible: root.mini

		BigButton {
			implicitWidth: 38
			implicitHeight: 38
			icon: root.playing ? "pause" : "play"
			main: false
			onClicked: root.playing ? player.pause() : player.play()
		}
		BigButton {
			implicitWidth: 38
			implicitHeight: 38
			icon: "arrow_expand"
			main: false
			onClicked: Streams.playerMini = false
		}
		BigButton {
			implicitWidth: 38
			implicitHeight: 38
			icon: "close"
			main: false
			onClicked: root.leave()
		}
	}

	// ── around the picture ──────────────────────────────────────────────
	Item {
		anchors.left: parent.left
		anchors.top: parent.top
		anchors.bottom: parent.bottom
		width: root.width - root.panelWidth
		opacity: root.controlsShown && !root.mini ? 1 : 0
		visible: opacity > 0.01

		Behavior on opacity {
			Anim {
				duration: root.controlsShown ? Motion.short : Motion.long
			}
		}

		Rectangle {
			anchors.left: parent.left
			anchors.right: parent.right
			height: 130 * root.ui
			gradient: Gradient {
				GradientStop {
					position: 0
					color: Qt.rgba(0, 0, 0, 0.8)
				}
				GradientStop {
					position: 1
					color: Qt.rgba(0, 0, 0, 0)
				}
			}
		}
		Rectangle {
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.bottom: parent.bottom
			height: 210 * root.ui
			gradient: Gradient {
				GradientStop {
					position: 0
					color: Qt.rgba(0, 0, 0, 0)
				}
				GradientStop {
					position: 1
					color: Qt.rgba(0, 0, 0, 0.9)
				}
			}
		}

		// ── the top ─────────────────────────────────────────────────────
		RowLayout {
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: parent.top
			anchors.margins: 22 * root.ui
			spacing: 14 * root.ui

			Round {
				icon: "arrow_left"
				size: 26
				onClicked: root.leave()
			}
			ColumnLayout {
				Layout.fillWidth: true
				spacing: 0

				Text {
					Layout.fillWidth: true
					text: root.item?.title ?? ""
					color: "white"
					font.family: Theme.fontFamily
					font.pixelSize: 22 * root.ui
					font.weight: Font.Bold
					elide: Text.ElideRight
				}
				Text {
					Layout.fillWidth: true
					text: [root.item?.seriesName, root.item?.channel, root.chapterName].filter(word => !!word).join(" · ")
					color: Qt.rgba(1, 1, 1, 0.7)
					font.family: Theme.fontFamily
					font.pixelSize: 14 * root.ui
					elide: Text.ElideRight
				}
			}
			Round {
				visible: root.canMini
				icon: "arrow_collapse"
				onClicked: Streams.playerMini = true
			}
			Round {
				icon: "picture_in_picture_top_right"
				visible: Streams.hasMpv
				onClicked: root.pictureInPicture()
			}
			Round {
				icon: "cellphone_arrow_down"
				visible: Plugins.on("phone") && !root.live
				onClicked: root.toPhone()
			}
			Round {
				icon: "camera_outline"
				onClicked: root.screenshot()
			}
			Round {
				icon: "link_variant"
				onClicked: root.copyLink()
			}
			Round {
				icon: "help_circle_outline"
				onClicked: root.keysOpen = !root.keysOpen
			}
		}

		// ── chips over the foot ─────────────────────────────────────────
		ColumnLayout {
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.bottom: parent.bottom
			anchors.leftMargin: 26 * root.ui
			anchors.rightMargin: 26 * root.ui + root.panelWidth
			anchors.bottomMargin: 18 * root.ui
			spacing: 8 * root.ui

			Flow {
				Layout.fillWidth: true
				spacing: 8 * root.ui

				PlayerChip {
					ui: root.ui
					shown: root.resumed
					text: `Continuing at ${Streams.clock(root.seekTo)}`
					action: "Start over"
					onActivated: {
						player.position = 0;
						root.resumed = false;
					}
				}
				PlayerChip {
					ui: root.ui
					shown: !!root.item?.previously && root.position < 60
					text: `Back after ${root.item?.previously?.days ?? 0} days`
					action: "What happened before?"
					onActivated: {
						root.panel = "notes";
						root.recap = { title: root.item.previously.title, text: "", busy: true };
						Streams.call("recap", { video: root.item.previously.video, model: AiActions.model || AiChat.selectedAiModel }, (data, error) => {
							root.recap = { title: root.item.previously.title, text: error || (data?.text ?? ""), busy: false };
						});
					}
				}
				PlayerChip {
					ui: root.ui
					shown: !!root.introPart && root.position >= root.introPart[0] - 1 && root.position < root.introPart[1] - 1
					text: "Intro"
					action: "Skip"
					onActivated: root.goTo(root.introPart[1])
				}
				PlayerChip {
					ui: root.ui
					shown: !!root.outroPart && root.position >= root.outroPart[0] && root.position < root.outroPart[1] - 1
					text: "Outro"
					action: "Skip"
					onActivated: root.goTo(root.outroPart[1])
				}
				PlayerChip {
					ui: root.ui
					shown: !!root.liveOffer
					text: `${root.liveOffer?.name ?? ""} is live`
					action: "Switch over"
					onActivated: {
						const source = root.liveOffer.source;
						root.report();
						root.liveOffer = null;
						Streams.playLive(source);
					}
				}
				PlayerChip {
					ui: root.ui
					shown: root.inSilence
					text: "Running through silence"
					action: ""
				}
			}

			// the line
			Item {
				id: line

				Layout.fillWidth: true
				Layout.preferredHeight: 22 * root.ui
				visible: !root.live || player.seekable
				readonly property real shown: seek.pressed ? seek.mouseX / width : (root.duration > 0 ? root.position / root.duration : 0)
				readonly property real thick: (seek.containsMouse || seek.pressed ? 8 : 5) * root.ui
				readonly property real hoverTime: root.duration * Math.max(0, Math.min(1, seek.mouseX / line.width))

				Rectangle {
					anchors.verticalCenter: parent.verticalCenter
					width: parent.width
					height: line.thick
					radius: height / 2
					color: Qt.rgba(1, 1, 1, 0.26)

					Behavior on height {
						SpatialAnim {
							duration: Motion.medium
						}
					}

					Rectangle {
						height: parent.height
						radius: parent.radius
						color: Theme.primary
						width: parent.width * Math.max(0, Math.min(1, line.shown))
					}

					// a spoiler series gives nothing away about what comes
					Repeater {
						model: root.spoiler ? [] : root.chapters

						Rectangle {
							required property var modelData

							x: root.duration > 0 ? parent.width * modelData.at / root.duration : 0
							width: 2 * root.ui
							height: parent.height
							color: Qt.rgba(0, 0, 0, 0.6)
						}
					}
					// what stands out; a spoiler series keeps that to itself as well
					Repeater {
						model: root.moments

						Rectangle {
							required property var modelData

							x: root.duration > 0 ? parent.width * modelData.at / root.duration : 0
							width: root.duration > 0 ? Math.max(3, parent.width * (modelData.end - modelData.at) / root.duration) : 0
							height: parent.height
							color: "white"
							opacity: root.digest.length > 0 ? 0.9 : 0.35
						}
					}
					Repeater {
						model: root.segments

						Rectangle {
							required property var modelData

							x: root.duration > 0 ? parent.width * modelData[0] / root.duration : 0
							width: root.duration > 0 ? parent.width * (modelData[1] - modelData[0]) / root.duration : 0
							height: parent.height
							color: Theme.warning
							opacity: 0.8
						}
					}
				}

				Rectangle {
					anchors.verticalCenter: parent.verticalCenter
					x: parent.width * Math.max(0, Math.min(1, line.shown)) - width / 2
					width: (seek.containsMouse || seek.pressed ? 20 : 0) * root.ui
					height: width
					radius: width / 2
					color: "white"

					Behavior on width {
						SpatialAnim {
							duration: Motion.medium
						}
					}
				}

				// what lies under the pointer: its frame, chapter and time
				Column {
					id: preview

					readonly property real wide: 256 * root.ui
					readonly property int frame: root.storyboard ? Math.floor(line.hoverTime / root.storyboard.every) : 0
					readonly property int perSheet: root.storyboard ? root.storyboard.columns * root.storyboard.rows : 1
					readonly property int sheet: Math.min(preview.frame / preview.perSheet, (root.storyboard?.sheets.length ?? 1) - 1) | 0
					readonly property int inSheet: preview.frame % preview.perSheet

					visible: seek.containsMouse && !root.spoiler && !root.live
					y: -height - 12 * root.ui
					x: Math.max(0, Math.min(parent.width - preview.wide, seek.mouseX - preview.wide / 2))
					width: preview.wide
					spacing: 4 * root.ui

					Item {
						width: preview.wide
						height: preview.wide * 9 / 16
						visible: !!root.storyboard
						clip: true

						Image {
							readonly property real scaling: preview.wide / (root.storyboard?.width ?? 1)

							source: root.storyboard?.sheets[preview.sheet] ?? ""
							asynchronous: true
							cache: true
							width: (root.storyboard?.width ?? 0) * (root.storyboard?.columns ?? 1) * scaling
							height: (root.storyboard?.height ?? 0) * (root.storyboard?.rows ?? 1) * scaling
							x: -(preview.inSheet % (root.storyboard?.columns ?? 1)) * preview.wide
							y: -Math.floor(preview.inSheet / (root.storyboard?.columns ?? 1)) * (preview.wide * 9 / 16)
						}
					}
					Rectangle {
						anchors.horizontalCenter: parent.horizontalCenter
						width: Math.min(preview.wide, hoverWord.implicitWidth + 16 * root.ui)
						height: 28 * root.ui
						radius: 6 * root.ui
						color: Qt.rgba(0, 0, 0, 0.82)

						Text {
							id: hoverWord

							anchors.centerIn: parent
							width: Math.min(implicitWidth, preview.wide - 12 * root.ui)
							elide: Text.ElideRight
							text: {
								let name = "";
								for (const chapter of root.chapters) if (chapter.at <= line.hoverTime) name = chapter.title;
								return [Streams.clock(line.hoverTime), name].filter(word => !!word).join(" · ");
							}
							color: "white"
							font.family: Theme.fontFamily
							font.pixelSize: 13 * root.ui
						}
					}
				}

				MouseArea {
					id: seek

					anchors.fill: parent
					anchors.topMargin: -8
					anchors.bottomMargin: -8
					hoverEnabled: true
					cursorShape: Qt.PointingHandCursor
					onReleased: mouse => {
						root.goTo(Math.max(0, Math.min(1, mouse.x / line.width)) * root.duration);
						root.takeFocus();
					}
				}
			}

			RowLayout {
				Layout.fillWidth: true
				spacing: 8 * root.ui

				Round {
					icon: root.playing ? "pause" : "play"
					size: 34
					onClicked: root.playing ? player.pause() : player.play()
				}
				Round {
					visible: !root.live || player.seekable
					icon: "chevron_double_left"
					onClicked: root.nudge(root.live ? -30 : -10)
				}
				Round {
					visible: !root.live
					icon: "chevron_double_right"
					onClicked: root.nudge(10)
				}
				Round {
					visible: !!root.seriesId
					icon: "skip_next"
					onClicked: {
						root.report();
						Streams.call("playerEnded", { video: root.video });
					}
				}
				Round {
					icon: output.muted || root.baseVolume === 0 ? "volume_off" : "volume_high"
					onClicked: output.muted = !output.muted
				}
				Item {
					Layout.preferredWidth: 100 * root.ui
					Layout.preferredHeight: 30 * root.ui

					Rectangle {
						anchors.verticalCenter: parent.verticalCenter
						width: parent.width
						height: 5 * root.ui
						radius: height / 2
						color: Qt.rgba(1, 1, 1, 0.26)

						Rectangle {
							height: parent.height
							radius: parent.radius
							color: "white"
							width: parent.width * (output.muted ? 0 : root.baseVolume)
						}
					}
					MouseArea {
						anchors.fill: parent
						cursorShape: Qt.PointingHandCursor
						onPressed: mouse => root.setVolume(mouse.x / width)
						onPositionChanged: mouse => {
							if (pressed) root.setVolume(mouse.x / width);
						}
					}
				}
				Text {
					Layout.leftMargin: 8 * root.ui
					text: root.live ? "LIVE" : (root.spoiler ? Streams.clock(root.position) : `${Streams.clock(root.position)} / ${Streams.clock(root.duration)}`)
					color: root.live ? "#ff5d5d" : "white"
					font.family: Theme.fontFamily
					font.pixelSize: 16 * root.ui
					font.weight: root.live ? Font.Black : Font.Medium
					font.features: { "tnum": 1 }
				}
				// back to now
				Rectangle {
					visible: root.live && player.seekable
					Layout.preferredWidth: nowWord.implicitWidth + 20 * root.ui
					Layout.preferredHeight: 32 * root.ui
					radius: 8 * root.ui
					color: Qt.rgba(1, 1, 1, nowArea.containsMouse ? 0.24 : 0.12)

					Text {
						id: nowWord

						anchors.centerIn: parent
						text: "Back to live"
						color: "white"
						font.family: Theme.fontFamily
						font.pixelSize: 13 * root.ui
						font.weight: Font.Bold
					}
					MouseArea {
						id: nowArea

						anchors.fill: parent
						hoverEnabled: true
						cursorShape: Qt.PointingHandCursor
						onClicked: player.position = player.duration
					}
				}
				Item {
					Layout.fillWidth: true
				}
				// the panels
				Round {
					visible: !!root.seriesId
					icon: "account_group"
					active: root.panel === "who"
					onClicked: root.panel = root.panel === "who" ? "" : "who"
				}
				Round {
					visible: !!root.seriesId
					icon: "help_circle_outline"
					active: root.panel === "ask"
					onClicked: root.panel = root.panel === "ask" ? "" : "ask"
				}
				Round {
					visible: !!root.video
					icon: "star_four_points"
					active: root.panel === "highlights"
					onClicked: root.panel = root.panel === "highlights" ? "" : "highlights"
				}
				Round {
					visible: !!root.video
					icon: "content_cut"
					active: root.panel === "clips"
					onClicked: root.panel = root.panel === "clips" ? "" : "clips"
				}
				Round {
					visible: !!root.video && !root.spoiler && !root.live
					icon: "format_list_bulleted"
					active: root.panel === "chapters"
					onClicked: root.panel = root.panel === "chapters" ? "" : "chapters"
				}
				Round {
					visible: !!root.video
					icon: "note_outline"
					active: root.panel === "notes"
					onClicked: root.panel = root.panel === "notes" ? "" : "notes"
				}
				Round {
					visible: !!root.seriesId
					icon: "magnify"
					active: root.panel === "search"
					onClicked: {
						root.panel = root.panel === "search" ? "" : "search";
						if (root.panel === "search") Streams.call("indexSeries", { id: root.seriesId });
					}
				}
				Round {
					visible: !!root.item?.chatLogin
					icon: "chat"
					active: root.panel === "chat"
					onClicked: root.panel = root.panel === "chat" ? "" : "chat"
				}
				Round {
					visible: !!root.video
					icon: "account_multiple"
					active: root.panel === "together" || !!Streams.together.role
					onClicked: root.panel = root.panel === "together" ? "" : "together"
				}
				// CC
				Rectangle {
					visible: root.captions.length > 0
					Layout.preferredWidth: 46 * root.ui
					Layout.preferredHeight: 38 * root.ui
					radius: 8 * root.ui
					color: root.captionLang ? "white" : Qt.rgba(1, 1, 1, ccArea.containsMouse ? 0.2 : 0.08)

					Text {
						anchors.centerIn: parent
						text: "CC"
						color: root.captionLang ? "black" : "white"
						font.family: Theme.fontFamily
						font.pixelSize: 15 * root.ui
						font.weight: Font.Black
					}
					MouseArea {
						id: ccArea

						anchors.fill: parent
						hoverEnabled: true
						cursorShape: Qt.PointingHandCursor
						onClicked: root.toggleCaptions()
					}
				}
				Round {
					icon: "cog_outline"
					active: root.menuOpen
					onClicked: root.menuOpen = !root.menuOpen
				}
				Round {
					icon: "fullscreen"
					onClicked: root.fullscreen()
				}
			}
		}
	}

	Loader {
		id: introLoader

		anchors.fill: parent
		z: 50
		active: !!root.intro && !root.mini
		sourceComponent: RecapIntro {
			title: root.intro?.title ?? ""
			file: root.intro?.file ?? ""
			lines: root.intro?.lines ?? []
			volume: Math.max(0, Math.min(1, root.baseVolume))
			muted: output.muted
			ui: root.ui
			onFinished: root.endIntro()
		}
	}

	component Round: Rectangle {
		id: round

		property string icon: ""
		property real size: 28
		property bool active: false
		signal clicked

		Layout.preferredWidth: 46 * root.ui
		Layout.preferredHeight: 46 * root.ui
		radius: width / 2
		color: round.active ? Qt.rgba(1, 1, 1, 0.3) : Qt.rgba(1, 1, 1, roundArea.containsMouse ? 0.2 : 0)
		scale: roundArea.pressed ? 0.88 : (roundArea.containsMouse ? 1.1 : 1)

		Behavior on scale {
			SpatialAnim {
				duration: Motion.medium
			}
		}
		Behavior on color {
			ColorAnim {
				duration: Motion.short
			}
		}

		Glyph {
			anchors.centerIn: parent
			icon: round.icon
			size: round.size * root.ui
			color: "white"
			surface: "black"
		}
		MouseArea {
			id: roundArea

			anchors.fill: parent
			hoverEnabled: true
			cursorShape: Qt.PointingHandCursor
			onClicked: {
				round.clicked();
				root.takeFocus();
				root.wake();
			}
		}
	}

	// ── a note, right where it happens ──────────────────────────────────
	property string noteKind: "note"

	Rectangle {
		anchors.horizontalCenter: picture.horizontalCenter
		anchors.bottom: picture.bottom
		anchors.bottomMargin: 150 * root.ui
		width: Math.min(picture.width - 60, 640 * root.ui)
		height: noteColumn.implicitHeight + 24 * root.ui
		radius: 14 * root.ui
		color: Qt.rgba(0.08, 0.08, 0.1, 0.94)
		visible: root.noting
		onVisibleChanged: if (visible) player.pause()

		ColumnLayout {
			id: noteColumn

			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: parent.top
			anchors.margins: 12 * root.ui
			spacing: 8

			Text {
				text: `A note at ${Streams.clock(root.position)}`
				color: "white"
				font.family: Theme.fontFamily
				font.pixelSize: 14 * root.ui
				font.weight: Font.Bold
			}
			Segmented {
				Layout.preferredWidth: 300
				Layout.preferredHeight: 30
				options: [{ value: "note", label: "Note" }, { value: "character", label: "Character" }, { value: "event", label: "Event" }]
				current: root.noteKind
				onSelected: value => root.noteKind = value
			}
			Field {
				id: noteField

				Layout.fillWidth: true
				placeholder: "What should stay?"
				onAccepted: {
					if (noteField.text.trim() !== "") Streams.call("addNote", { video: root.video, at: root.position, kind: root.noteKind, text: noteField.text.trim() }, data => root.panelNotes = data ?? root.panelNotes);
					noteField.text = "";
					root.noting = false;
					player.play();
					root.say("Noted");
					root.takeFocus();
				}
				onEscapePressed: {
					noteField.text = "";
					root.noting = false;
					player.play();
					root.takeFocus();
				}
			}
		}
	}

	// ── settings ────────────────────────────────────────────────────────
	Rectangle {
		anchors.right: picture.right
		anchors.bottom: picture.bottom
		anchors.rightMargin: 24 * root.ui
		anchors.bottomMargin: 96 * root.ui
		width: 360
		height: Math.min(menu.implicitHeight + 28, root.height / root.ui - 170)
		radius: 16
		color: Qt.rgba(0.08, 0.08, 0.1, 0.95)
		visible: opacity > 0.01
		opacity: root.menuOpen ? 1 : 0
		scale: (root.menuOpen ? 1 : 0.92) * root.ui
		transformOrigin: Item.BottomRight
		clip: true

		Behavior on opacity {
			Anim {
				duration: Motion.short
			}
		}

		MouseArea {
			anchors.fill: parent
		}

		Flickable {
			anchors.fill: parent
			anchors.margins: 14
			contentHeight: menu.implicitHeight
			boundsBehavior: Flickable.StopAtBounds

			ColumnLayout {
				id: menu

				width: parent.width
				spacing: 10

				PlayerMenuTitle {
					text: `Speed ${root.speed}×${root.seriesId ? " (kept for this series)" : ""}`
				}
				Flow {
					Layout.fillWidth: true
					spacing: 4

					Repeater {
						model: [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3]

						Chip {
							required property real modelData

							text: `${modelData}`
							selected: root.speed === modelData
							onClicked: root.setSpeed(modelData)
						}
					}
				}

				PlayerMenuTitle {
					text: root.soundLead === 0 ? "Sound in time" : `Sound ${Math.abs(root.soundLead)} ms ${root.soundLead > 0 ? "earlier" : "later"}, on this output`
				}
				Flow {
					Layout.fillWidth: true
					spacing: 4

					Repeater {
						model: [["Later 50", -50], ["Later 10", -10], ["Earlier 10", 10], ["Earlier 50", 50]]

						Chip {
							required property var modelData

							text: modelData[0]
							onClicked: root.moveSound(modelData[1])
						}
					}
					Chip {
						visible: !root.item?.syncTest
						text: "Test with flash and beep"
						onClicked: {
							root.menuOpen = false;
							root.report();
							Streams.call("syncTest", {});
						}
					}
				}

				PlayerMenuTitle {
					visible: root.qualities.length > 1
					text: "Quality"
				}
				Flow {
					Layout.fillWidth: true
					spacing: 4
					visible: root.qualities.length > 1

					Repeater {
						model: root.qualities

						Chip {
							required property int modelData

							text: `${modelData}p`
							selected: root.height_ === modelData
							onClicked: {
								Streams.setSetting("quality", modelData);
								if (root.seriesId) Streams.call("seriesPrefs", { series: root.seriesId, quality: modelData });
								root.seekTo = root.position;
								root.started = false;
								root.landed = false;
								player.stop();
								root.address = "";
								root.resolve(modelData);
								root.takeFocus();
							}
						}
					}
				}

				PlayerMenuTitle {
					visible: root.captions.length > 0
					text: "Subtitles"
				}
				Flow {
					Layout.fillWidth: true
					spacing: 4
					visible: root.captions.length > 0

					Chip {
						text: "Off"
						selected: root.captionLang === ""
						onClicked: root.pickCaption("")
					}
					Repeater {
						// the original, then the languages one is likely to want
						model: root.captions.filter(track => !track.auto || track.lang.endsWith("-orig") || ["en", "de"].includes(track.lang)).slice(0, 8)

						Chip {
							required property var modelData

							text: modelData.name
							selected: root.captionLang === modelData.lang
							onClicked: root.pickCaption(modelData.lang)
						}
					}
				}
				RowLayout {
					visible: root.captionLang !== ""
					Layout.fillWidth: true

					Segmented {
						Layout.preferredWidth: 200
						Layout.preferredHeight: 28
						options: [{ value: "0.8", label: "Small" }, { value: "1", label: "Medium" }, { value: "1.35", label: "Large" }]
						current: String(Streams.settings.subtitleSize ?? 1)
						onSelected: value => Streams.setSetting("subtitleSize", Number(value))
					}
					Item {
						Layout.fillWidth: true
					}
					Text {
						text: "Box"
						color: "white"
						font.family: Theme.fontFamily
						font.pixelSize: 13
					}
					Toggle {
						checked: Streams.settings.subtitleBox ?? true
						onToggled: checked => Streams.setSetting("subtitleBox", checked)
					}
				}

				PlayerMenuTitle {
					text: "Listening"
				}
				PlayerMenuSwitch {
					label: "Run quickly through silence"
					setting: "trimSilence"
					detail: root.marks.silences ? `${root.marks.silences.length} quiet parts found` : "The sound is being listened to first"
				}
				PlayerMenuSwitch {
					label: "Even out the loudness"
					setting: "evenLoudness"
					detail: "Shouts softer, whispers louder"
				}

				PlayerMenuTitle {
					text: "Around the picture"
				}
				PlayerMenuSwitch {
					label: "Colours of the video around it"
					setting: "ambient"
				}
				RowLayout {
					Layout.fillWidth: true
					visible: Lighting.devices.length > 0

					Text {
						Layout.fillWidth: true
						text: "Room lights follow the screen"
						color: "white"
						font.family: Theme.fontFamily
						font.pixelSize: 14
					}
					Toggle {
						checked: Streams.settings.roomLights ?? false
						onToggled: checked => {
							Streams.setSetting("roomLights", checked);
							Qt.callLater(root.syncLights);
						}
					}
				}

				PlayerMenuTitle {
					text: root.sleepAtEnd ? "Sleep: after this episode" : (root.sleepAt > 0 ? "Sleep timer on" : "Sleep")
				}
				Flow {
					Layout.fillWidth: true
					spacing: 4

					Repeater {
						model: [{ label: "Off", value: 0 }, { label: "After this episode", value: -1 }, { label: "30 min", value: 30 }, { label: "60 min", value: 60 }, { label: "90 min", value: 90 }]

						Chip {
							required property var modelData

							text: modelData.label
							selected: modelData.value === 0 ? (root.sleepAt === 0 && !root.sleepAtEnd) : (modelData.value === -1 && root.sleepAtEnd)
							onClicked: root.setSleep(modelData.value)
						}
					}
				}
			}
		}
	}

	// ── the side panel ──────────────────────────────────────────────────
	property var panelNotes: []
	property var hits: []
	property bool makingChapters: false
	property var recap: null
	property string joinAddress: ""
	property string joinCode: ""
	property string togetherError: ""

	onPanelChanged: if (root.panel === "notes" && root.video) Streams.call("notes", root.seriesId ? { series: root.seriesId } : { video: root.video }, data => root.panelNotes = data ?? [])

	Rectangle {
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.bottom: parent.bottom
		width: 430 * root.ui
		color: Qt.rgba(0.07, 0.07, 0.09, 1)
		visible: x < root.width - 1 && !root.mini
		transform: Translate {
			x: root.panel !== "" ? 0 : 430 * root.ui

			Behavior on x {
				SpatialAnim {
					duration: Motion.long
				}
			}
		}

		MouseArea {
			anchors.fill: parent
		}

		ColumnLayout {
			anchors.fill: parent
			anchors.margins: 16 * root.ui
			spacing: 10 * root.ui

			RowLayout {
				Layout.fillWidth: true

				Text {
					Layout.fillWidth: true
					text: ({ chapters: "Chapters", notes: "Notes", search: "What was said", chat: "Chat", together: "Watch together", who: "Who is this?", ask: "Ask the series", clips: "Clips", highlights: "What stands out" })[root.panel] ?? ""
					color: "white"
					font.family: Theme.fontFamily
					font.pixelSize: 20 * root.ui
					font.weight: Font.Black
				}
				Round {
					icon: "close"
					size: 22
					onClicked: root.panel = ""
				}
			}

			PlayerStoryPanel {
				Layout.fillWidth: true
				Layout.fillHeight: true
				visible: mode !== ""
				mode: ["who", "ask", "clips", "highlights"].includes(root.panel) ? root.panel : ""
				seriesId: root.seriesId
				video: root.video
				position: root.position
				ui: root.ui
				digest: root.digest
				onJump: (video, at) => root.jumpTo(video, at)
				onDigestWanted: moments => root.setDigest(moments)
				onDone: root.takeFocus()
			}

			// chapters of its own for a video that has none
			ColumnLayout {
				Layout.fillWidth: true
				visible: root.panel === "chapters" && root.chapters.length === 0
				spacing: 10 * root.ui

				Text {
					Layout.fillWidth: true
					text: root.makingChapters ? "Reading the subtitles and dividing…" : "This video has no chapters. The AI can make some from its subtitles; every one is checked against them."
					color: Qt.rgba(1, 1, 1, 0.66)
					wrapMode: Text.Wrap
					font.family: Theme.fontFamily
					font.pixelSize: 13 * root.ui
				}
				TextButton {
					visible: !root.makingChapters
					text: "Make chapters"
					onActivated: {
						root.makingChapters = true;
						const asked = root.video;
						Streams.call("autoChapters", { video: asked }, Streams.report((data, error) => {
							root.makingChapters = false;
							if (asked === root.video && data?.chapters) root.chapters = data.chapters;
						}));
					}
				}
			}

			// chapters
			ListView {
				id: chapterList

				Layout.fillWidth: true
				Layout.fillHeight: true
				visible: root.panel === "chapters"
				clip: true
				model: root.panel === "chapters" ? root.chapters : []
				spacing: 2

				delegate: Rectangle {
					id: chapterRow

					required property var modelData
					required property int index

					width: chapterList.width
					height: 46 * root.ui
					radius: 8 * root.ui
					color: chapterRow.index === root.chapterIndex ? Qt.rgba(1, 1, 1, 0.16) : (chapterArea.containsMouse ? Qt.rgba(1, 1, 1, 0.08) : "transparent")

					RowLayout {
						anchors.fill: parent
						anchors.margins: 8 * root.ui

						Text {
							text: Streams.clock(chapterRow.modelData.at)
							color: Qt.rgba(1, 1, 1, 0.6)
							font.family: Theme.fontFamily
							font.pixelSize: 13 * root.ui
							font.features: { "tnum": 1 }
						}
						Text {
							Layout.fillWidth: true
							text: chapterRow.modelData.title
							color: "white"
							font.family: Theme.fontFamily
							font.pixelSize: 14 * root.ui
							elide: Text.ElideRight
						}
					}
					MouseArea {
						id: chapterArea

						anchors.fill: parent
						hoverEnabled: true
						cursorShape: Qt.PointingHandCursor
						onClicked: root.goTo(chapterRow.modelData.at)
					}
				}
			}

			// notes, and what happened before
			Rectangle {
				Layout.fillWidth: true
				Layout.preferredHeight: recapColumn.implicitHeight + 20
				visible: root.panel === "notes" && !!root.recap
				radius: 10
				color: Qt.rgba(1, 1, 1, 0.08)

				ColumnLayout {
					id: recapColumn

					anchors.left: parent.left
					anchors.right: parent.right
					anchors.top: parent.top
					anchors.margins: 10
					spacing: 4

					Text {
						Layout.fillWidth: true
						text: `What happened: ${root.recap?.title ?? ""}`
						color: "white"
						font.family: Theme.fontFamily
						font.pixelSize: 13 * root.ui
						font.weight: Font.Bold
						elide: Text.ElideRight
					}
					Text {
						Layout.fillWidth: true
						text: root.recap?.busy ? "Reading the subtitles…" : (root.recap?.text ?? "")
						color: Qt.rgba(1, 1, 1, 0.84)
						font.family: Theme.fontFamily
						font.pixelSize: 13 * root.ui
						wrapMode: Text.Wrap
					}
				}
			}
			BigButton {
				Layout.fillWidth: true
				visible: root.panel === "notes"
				implicitHeight: 40
				text: "New note (B)"
				icon: "plus"
				main: false
				onClicked: {
					root.noting = true;
					noteField.input.forceActiveFocus();
				}
			}
			ListView {
				id: noteList

				Layout.fillWidth: true
				Layout.fillHeight: true
				visible: root.panel === "notes"
				clip: true
				spacing: 6
				model: root.panel === "notes" ? root.panelNotes : []

				delegate: Rectangle {
					id: noteRow

					required property var modelData

					width: noteList.width
					height: noteRowColumn.implicitHeight + 16
					radius: 8
					color: noteArea.containsMouse ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(1, 1, 1, 0.06)

					ColumnLayout {
						id: noteRowColumn

						anchors.left: parent.left
						anchors.right: parent.right
						anchors.top: parent.top
						anchors.margins: 8
						spacing: 2

						Text {
							Layout.fillWidth: true
							text: noteRow.modelData.text
							color: "white"
							wrapMode: Text.Wrap
							font.family: Theme.fontFamily
							font.pixelSize: 14 * root.ui
						}
						Text {
							Layout.fillWidth: true
							text: `${({ character: "Character · ", event: "Event · " })[noteRow.modelData.kind] ?? ""}${Streams.clock(noteRow.modelData.at)} · ${noteRow.modelData.title ?? ""}`
							color: Qt.rgba(1, 1, 1, 0.56)
							elide: Text.ElideRight
							font.family: Theme.fontFamily
							font.pixelSize: 12 * root.ui
						}
					}
					MouseArea {
						id: noteArea

						anchors.fill: parent
						hoverEnabled: true
						cursorShape: Qt.PointingHandCursor
						onClicked: {
							if (noteRow.modelData.video === root.video) root.goTo(noteRow.modelData.at);
							else Streams.call("play", { video: noteRow.modelData.video, player: "app", at: noteRow.modelData.at });
						}
					}
				}
			}

			// search
			Field {
				Layout.fillWidth: true
				visible: root.panel === "search"
				icon: "magnify"
				placeholder: "Anything somebody said"
				onEdited: text => {
					searchWord.text = text;
					searchTimer.restart();
				}
				onEscapePressed: root.takeFocus()
			}
			Item {
				id: searchWord

				property string text: ""
			}
			Timer {
				id: searchTimer

				interval: 240
				onTriggered: Streams.call("searchSeries", { series: root.seriesId, query: searchWord.text }, data => {
					root.hits = data?.hits ?? [];
					root.searchIndex = data?.index ?? null;
				})
			}
			Timer {
				interval: 4000
				repeat: true
				running: root.panel === "search"
				onTriggered: searchTimer.restart()
			}
			Text {
				Layout.fillWidth: true
				visible: root.panel === "search" && !!root.searchIndex && root.searchIndex.done < root.searchIndex.total
				text: `Reading the subtitles: ${root.searchIndex?.done ?? 0} of ${root.searchIndex?.total ?? 0} episodes`
				color: Qt.rgba(1, 1, 1, 0.6)
				font.family: Theme.fontFamily
				font.pixelSize: 12 * root.ui
			}
			ListView {
				id: hitList

				Layout.fillWidth: true
				Layout.fillHeight: true
				visible: root.panel === "search"
				clip: true
				spacing: 6
				model: root.panel === "search" ? root.hits : []

				delegate: Rectangle {
					id: hitRow

					required property var modelData

					width: hitList.width
					height: hitColumn.implicitHeight + 16
					radius: 8
					color: hitArea.containsMouse ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(1, 1, 1, 0.06)

					ColumnLayout {
						id: hitColumn

						anchors.left: parent.left
						anchors.right: parent.right
						anchors.top: parent.top
						anchors.margins: 8
						spacing: 2

						Text {
							Layout.fillWidth: true
							text: hitRow.modelData.text
							textFormat: Text.StyledText
							color: "white"
							wrapMode: Text.Wrap
							font.family: Theme.fontFamily
							font.pixelSize: 13 * root.ui
						}
						Text {
							Layout.fillWidth: true
							text: `${Streams.clock(hitRow.modelData.at)} · ${hitRow.modelData.title}`
							color: Qt.rgba(1, 1, 1, 0.56)
							elide: Text.ElideRight
							font.family: Theme.fontFamily
							font.pixelSize: 12 * root.ui
						}
					}
					MouseArea {
						id: hitArea

						anchors.fill: parent
						hoverEnabled: true
						cursorShape: Qt.PointingHandCursor
						onClicked: {
							if (hitRow.modelData.video === root.video) root.goTo(hitRow.modelData.at);
							else Streams.call("play", { video: hitRow.modelData.video, player: "app", at: hitRow.modelData.at });
						}
					}
				}
			}

			// chat
			ListView {
				id: chatList

				Layout.fillWidth: true
				Layout.fillHeight: true
				visible: root.panel === "chat"
				clip: true
				spacing: 3 * root.ui
				model: root.panel === "chat" ? Streams.chatLines : []
				onCountChanged: Qt.callLater(chatList.positionViewAtEnd)

				delegate: Text {
					required property var modelData

					width: chatList.width
					text: `<b><font color="${modelData.color || "#b6a6ff"}">${String(modelData.name).replace(/</g, "&lt;")}</font></b> ${String(modelData.text).replace(/&/g, "&amp;").replace(/</g, "&lt;")}`
					textFormat: Text.StyledText
					color: "white"
					wrapMode: Text.Wrap
					font.family: Theme.fontFamily
					font.pixelSize: 14 * root.ui
				}
			}
			Text {
				Layout.fillWidth: true
				visible: root.panel === "chat" && chatList.count === 0
				text: "Waiting for messages. The chat is only read here, nothing can be written."
				color: Qt.rgba(1, 1, 1, 0.6)
				font.family: Theme.fontFamily
				font.pixelSize: 13 * root.ui
				wrapMode: Text.Wrap
			}

			// together
			ColumnLayout {
				Layout.fillWidth: true
				visible: root.panel === "together"
				spacing: 10

				Text {
					Layout.fillWidth: true
					text: !Streams.together.role ? "Play and pause together with another PC on this network. Start a room here and enter its code there." : (Streams.together.role === "host" ? `Room is open. Code: ${Streams.together.code}\n${Streams.together.peers} joined` : "Joined. Play, pause and jumps are shared.")
					color: "white"
					font.family: Theme.fontFamily
					font.pixelSize: 15 * root.ui
					wrapMode: Text.Wrap
				}
				BigButton {
					Layout.fillWidth: true
					visible: !Streams.together.role
					text: "Open a room"
					icon: "account_multiple"
					onClicked: Streams.call("together", { what: "host" }, (data, error) => root.togetherError = error)
				}
				BigButton {
					Layout.fillWidth: true
					visible: !!Streams.together.role
					text: "Leave"
					main: false
					onClicked: Streams.call("together", { what: "leave" })
				}
				Field {
					id: joinAddressField

					Layout.fillWidth: true
					visible: !Streams.together.role
					placeholder: "Address of the other PC"
					onEscapePressed: root.takeFocus()
				}
				Field {
					id: joinCodeField

					Layout.fillWidth: true
					visible: !Streams.together.role
					placeholder: "Its code"
					onEscapePressed: root.takeFocus()
				}
				BigButton {
					Layout.fillWidth: true
					visible: !Streams.together.role
					text: "Join"
					main: false
					onClicked: Streams.call("together", { what: "join", address: joinAddressField.text, code: joinCodeField.text }, (data, error) => root.togetherError = error)
				}
				Text {
					Layout.fillWidth: true
					visible: root.togetherError !== ""
					text: root.togetherError
					color: "#ff8a8a"
					font.family: Theme.fontFamily
					font.pixelSize: 13 * root.ui
					wrapMode: Text.Wrap
				}
			}

			Item {
				Layout.fillHeight: root.panel === "together"
			}
		}
	}

	property var searchIndex: null

	// ── the keys ────────────────────────────────────────────────────────
	Rectangle {
		anchors.centerIn: picture
		width: keysGrid.implicitWidth + 44
		height: keysGrid.implicitHeight + 40
		radius: 18
		scale: root.ui
		color: Qt.rgba(0.07, 0.07, 0.09, 0.95)
		visible: root.keysOpen && !root.mini

		GridLayout {
			id: keysGrid

			anchors.centerIn: parent
			columns: 4
			columnSpacing: 14
			rowSpacing: 6

			Repeater {
				model: [["Space", "Play, pause"], ["← →", "10 seconds"], ["0–9", "Jump there"], ["↑ ↓", "Volume"], ["M", "Mute"], ["F", "Fullscreen"], ["N", "Next episode"], ["PgUp PgDn", "Chapters"], ["< >", "Speed"], ["C", "Subtitles"], ["B", "Note"], ["S", "Picture"], ["T", "Copy link"], ["I", "Small"], ["P", "Picture in picture"], ["W", "Who is this?"], ["Q", "Ask the series"], ["X", "Keep 30 seconds"], ["H", "What stands out"], ["G", "Settings"], ["Esc", "Leave"]]

				Item {
					required property var modelData

					Layout.preferredWidth: 220
					Layout.preferredHeight: 24

					Text {
						id: keyName

						text: parent.modelData[0]
						color: "white"
						font.family: Theme.monoFamily
						font.pixelSize: 13
						font.weight: Font.Bold
					}
					Text {
						anchors.left: parent.left
						anchors.leftMargin: 92
						text: parent.modelData[1]
						color: Qt.rgba(1, 1, 1, 0.74)
						font.family: Theme.fontFamily
						font.pixelSize: 13
					}
				}
			}
		}
	}
}
