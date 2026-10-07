pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The words of the song that is playing: scripts/lyrics.py asks LRCLIB, with
// lines timed to the music where it has them. It only asks while the lyrics
// are looked at (the media panel is up and they are folded out, lyrics.json).
Singleton {
	id: root

	// folded out in the media panel
	property bool open: false
	// the media panel is on the screen
	property bool watching: false
	// phones that look at the lyrics (core/phone/LyricsTopic.qml)
	property int remote: 0

	// "" | "loading" | "found" | "none" | "error"
	property string state: ""
	// [{ t: seconds or -1, text }], an empty text is a pause
	property var lines: []
	property bool synced: false

	readonly property string title: Media.player?.trackTitle || ""
	readonly property string key: root.title === "" ? "" : [root.title, Media.artist, Media.player?.trackAlbum || "", Math.round(Media.length)].join("\n")
	// the song the state and the lines belong to
	property string loaded: ""
	readonly property bool active: Plugins.on("lyrics") && ((root.open && root.watching) || root.remote > 0) && root.key !== ""
	readonly property bool following: root.active && root.synced && root.state === "found"

	// the line that is sung, -1 before the first
	readonly property int current: {
		if (!root.following) return -1;
		const at = Media.position + 0.2;
		let low = 0;
		let high = root.lines.length - 1;
		let found = -1;
		while (low <= high) {
			const middle = (low + high) >> 1;
			if (root.lines[middle].t <= at) {
				found = middle;
				low = middle + 1;
			} else {
				high = middle - 1;
			}
		}
		return found;
	}

	onKeyChanged: root.changed()
	onActiveChanged: root.changed()

	function show(on) {
		if (root.open === !!on) return;
		root.open = !!on;
		file.setText(JSON.stringify({ open: root.open }, null, "\t") + "\n");
	}

	function toggle() {
		root.show(!root.open);
	}

	// players name a song piece by piece: wait until it stands
	function changed() {
		if (!root.active) return settle.stop();
		// a failed lookup gets another try when the lyrics come back up
		if (root.key === root.loaded && root.state !== "error") return;
		root.state = "loading";
		root.lines = [];
		root.loaded = "";
		settle.restart();
	}

	function load() {
		// a lookup still under way starts the next one when it ends
		if (!root.active || root.key === root.loaded || fetcher.running) return;
		root.loaded = root.key;
		const command = ["python3", `${Paths.scripts}/lyrics.py`, "--title", root.title, "--duration", String(Media.length)];
		if (Media.artist !== "") command.push("--artist", Media.artist);
		if (Media.player?.trackAlbum) command.push("--album", Media.player.trackAlbum);
		fetcher.command = command;
		fetcher.running = true;
	}

	function handle(text) {
		// the song changed meanwhile
		if (root.loaded !== root.key) return;
		let data = null;
		try {
			data = JSON.parse(text);
		} catch (error) {}
		if (data?.state === "found" && Array.isArray(data.lines)) {
			root.synced = data.synced === true;
			root.lines = data.lines;
			root.state = "found";
			return;
		}
		root.lines = [];
		root.state = data?.state === "none" ? "none" : "error";
	}

	Timer {
		id: settle

		interval: 500
		onTriggered: root.load()
	}

	// the player's position, often enough for a line to come on time
	Timer {
		running: root.following && Media.playing
		repeat: true
		interval: 250
		onTriggered: Media.player?.positionChanged()
	}

	Process {
		id: fetcher

		stdout: StdioCollector {
			onStreamFinished: root.handle(text)
		}
		onExited: Qt.callLater(root.load)
	}

	FileView {
		id: file

		path: Paths.stateFile("lyrics.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				root.open = JSON.parse(String(text() || "{}")).open === true;
			} catch (error) {}
		}
	}
}
