pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// What plays in the browser, beyond the media card's list (plugin
// `browser-media`, docs/browser.md "What the shell does with it"):
//
// - the sleep timer: in N minutes or after this episode the browser's media
//   fades out and pauses; the screen may go off afterwards;
// - a call on the phone (Phone, `phone.telephony`) pauses every tab that
//   plays and plays the same ones again when it is over;
// - the Amazfit watch's play, next and previous steer the tab that played
//   last: play/pause, +10 s, −10 s (Amazfit hands its keys here first);
// - a music video's song as the page names it (content/attention.js), which
//   Lyrics takes over the browser's media session.
//
// The extension does the media part (background/attention.js): `hold`
// fades and pauses with a tag, `release` plays what that tag paused.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("browser-media") && WebLink.enabled
	readonly property bool linked: root.enabled && WebLink.connected
	// the player in front is the browser
	readonly property bool browserFront: /floorp|firefox|librewolf|zen|waterfox/i.test(`${Media.player?.identity ?? ""} ${Media.player?.dbusName ?? ""}`)

	// settings (browser-playback.json)
	property bool screenOff: false
	property bool calls: true
	property bool remote: true
	readonly property int fadeSeconds: 20

	// ── the tab that played last ──────────────────────────────────────────
	property string lastKey: ""
	readonly property var lastTab: WebLink.table[root.lastKey] ?? WebLink.audibleTabs[0] ?? null

	Connections {
		target: root.enabled ? WebLink : null

		function onTabsUpdated() {
			const playing = WebLink.audibleTabs;
			if (playing.length === 0) return;
			const front = playing.find(tab => tab.active) ?? playing[0];
			if (front.key !== root.lastKey) root.lastKey = front.key;
		}

		function onEventReceived(event) {
			root.received(event);
		}
	}

	function received(event) {
		const key = `${event.source}/${event.tabId}`;
		switch (event.name) {
		case "track":
			root.track = {
				key: key,
				title: String(event.title || ""),
				artist: String(event.artist || ""),
				music: !!event.music,
				duration: Number(event.duration) || 0,
				position: Number(event.position) || 0,
				playing: !!event.playing,
				at: Date.now()
			};
			if (event.playing) root.lastKey = key;
			root.tick();
			return;
		case "played":
			root.lastKey = key;
			return;
		case "sleepDone":
			if (root.sleepMode === "episode" && root.sleepTab === key) root.finishSleep();
			return;
		}
	}

	// ── the song of a music video ─────────────────────────────────────────
	// { key, title, artist, music, duration, position, playing, at }
	property var track: null
	// what Lyrics takes instead of the media session: a music video in front
	readonly property var lyricsTrack: {
		const track = root.track;
		if (!root.enabled || !track || !track.music || !root.browserFront || !WebLink.table[track.key]) return null;
		return track;
	}
	// where the song is, counted on from the page's last word (tick())
	property real position: 0

	function tick() {
		const track = root.track;
		if (!track) return;
		root.position = track.playing ? track.position + (Date.now() - track.at) / 1000 : track.position;
	}

	// ── the sleep timer ───────────────────────────────────────────────────
	// "" | "time" | "episode"
	property string sleepMode: ""
	property real sleepAt: 0
	property string sleepTab: ""
	property bool sleepFading: false
	property real now: Date.now()
	readonly property real sleepLeft: root.sleepMode === "" ? 0 : Math.max(0, (root.sleepAt - root.now) / 1000)

	function sleepIn(minutes) {
		root.cancelSleep();
		root.sleepMode = "time";
		root.sleepAt = Date.now() + Math.max(1, minutes) * 60000;
		root.now = Date.now();
	}

	function sleepAfterThis() {
		const tab = root.lastTab;
		if (!root.linked || !tab) return;
		root.cancelSleep();
		WebLink.command("sleepAfter", { tabId: tab.id, fade: root.fadeSeconds * 1000 }, (ok, data) => {
			if (!ok || !data) {
				Notifs.pushInternal("error", "Sleep timer", "Nothing plays there", { icon: "sleep" });
				return;
			}
			root.sleepMode = "episode";
			root.sleepTab = tab.key;
			root.now = Date.now();
			const left = Number(data.duration) > 0 ? Number(data.duration) - Number(data.position || 0) : 0;
			root.sleepAt = left > 0 ? Date.now() + left * 1000 : 0;
		}, tab.source);
	}

	function cancelSleep() {
		if (root.sleepMode === "episode") {
			const tab = WebLink.table[root.sleepTab];
			if (tab) WebLink.command("sleepAfter", { tabId: tab.id, off: true }, null, tab.source);
		}
		if (root.sleepFading) WebLink.command("release", { tag: "sleep" }, null);
		root.sleepMode = "";
		root.sleepAt = 0;
		root.sleepTab = "";
		root.sleepFading = false;
	}

	function finishSleep() {
		root.sleepMode = "";
		root.sleepAt = 0;
		root.sleepTab = "";
		root.sleepFading = false;
		if (root.screenOff) screenOffSoon.restart();
	}

	Timer {
		running: root.sleepMode !== ""
		interval: 1000
		repeat: true
		onTriggered: {
			root.now = Date.now();
			if (root.sleepMode !== "time") return;
			const left = root.sleepAt - root.now;
			if (!root.sleepFading && left <= root.fadeSeconds * 1000) {
				root.sleepFading = true;
				WebLink.command("hold", { tag: "sleep", fade: Math.max(0, left) }, null);
			}
			if (left <= 0) root.finishSleep();
		}
	}

	// after the fade has settled
	Timer {
		id: screenOffSoon

		interval: 2500
		onTriggered: Quickshell.execDetached(["niri", "msg", "action", "power-off-monitors"])
	}

	// ── a call ────────────────────────────────────────────────────────────
	property bool callHeld: false
	property var callTabs: []

	Connections {
		target: root.enabled && Plugins.on("phone") ? Phone : null

		function onEvent(topic, name, data, device) {
			if (topic === "phone.telephony" && name === "call") root.call(String(data?.state || ""));
		}
	}

	function call(state) {
		if (!root.linked || !root.calls) return;
		if (state === "ringing" || state === "offhook") {
			if (root.callHeld) return;
			root.callHeld = true;
			root.callTabs = [];
			WebLink.command("hold", { tag: "call", fade: 0 }, (ok, data) => {
				const tabs = ok && Array.isArray(data?.tabs) ? data.tabs : [];
				// the call was over before the browser answered
				if (!root.callHeld) {
					if (tabs.length > 0) WebLink.command("release", { tag: "call", tabs: tabs }, null);
					return;
				}
				root.callTabs = tabs;
			});
		} else if (state === "idle" && root.callHeld) {
			const tabs = root.callTabs;
			root.callHeld = false;
			root.callTabs = [];
			if (tabs.length > 0) WebLink.command("release", { tag: "call", tabs: tabs }, null);
		}
	}

	// ── the watch as a remote ─────────────────────────────────────────────
	// Amazfit asks first: true when the key went to the browser
	function steer(id) {
		const tab = root.lastTab;
		if (!root.linked || !root.remote || !tab || !root.browserFront) return false;
		let args = null;
		if (id === "play") args = { op: "toggle" };
		else if (id === "next") args = { op: "seek", by: 10 };
		else if (id === "previous") args = { op: "seek", by: -10 };
		if (!args) return false;
		WebLink.command("mediaKey", Object.assign({ tabId: tab.id }, args), (ok, data) => {
			if (!ok || !data) return;
			// the watch's music app shows where it is now
			if (Plugins.on("amazfit") && Amazfit.musicOpen) Qt.callLater(Amazfit.pushMusic);
		}, tab.source);
		return true;
	}

	// ── settings ──────────────────────────────────────────────────────────
	function set(key, value) {
		if (key === "screenOff") root.screenOff = !!value;
		else if (key === "calls") root.calls = !!value;
		else if (key === "remote") root.remote = !!value;
		else return;
		file.setText(JSON.stringify({ screenOff: root.screenOff, calls: root.calls, remote: root.remote }, null, "\t") + "\n");
	}

	FileView {
		id: file

		path: Paths.stateFile("browser-playback.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(String(text() || "{}"));
				root.screenOff = data.screenOff === true;
				root.calls = data.calls !== false;
				root.remote = data.remote !== false;
			} catch (error) {}
		}
	}
}
