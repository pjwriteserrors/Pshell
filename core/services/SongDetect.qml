pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Names the song that is playing: scripts/song_detect.py listens to the
// default output and asks Shazam. The last song found stays (song.json)
// until it is dismissed.
Singleton {
	id: root

	// "" | "listening" | "found" | "none" | "error"
	property string state: ""
	// { title, artist, album, cover, links: [{ name, icon, url }] }
	property var song: null
	property string message: ""
	readonly property bool listening: root.state === "listening"
	// how long it listens before it gives up, and since when (ms)
	readonly property int listenSeconds: 24
	property real startedAt: 0

	function detect() {
		if (!Plugins.on("song-detection") || root.listening) return;
		root.state = "listening";
		root.message = "";
		root.startedAt = Date.now();
		listener.running = true;
	}

	function cancel() {
		if (!root.listening) return;
		root.state = root.song ? "found" : "";
		listener.running = false;
	}

	function toggle() {
		if (root.listening) root.cancel();
		else root.detect();
	}

	function dismiss() {
		root.cancel();
		root.state = "";
		root.message = "";
		root.song = null;
		file.setText("{}\n");
	}

	function open(url) {
		Quickshell.execDetached(["xdg-open", url]);
	}

	function handle(line) {
		let data = null;
		try {
			data = JSON.parse(line);
		} catch (error) {
			return;
		}
		if (!root.listening || !data || data.state === "listening") return;
		if (data.state === "found") {
			root.song = { title: data.title || "", artist: data.artist || "", album: data.album || "", cover: data.cover || "", links: data.links || [] };
			root.state = "found";
			file.setText(JSON.stringify(root.song, null, "\t") + "\n");
			if (Popups.current !== "media")
				Notifs.pushInternal("done", root.song.title, root.song.artist, {
					icon: "music",
					actions: [{ label: "Open", icon: "open_in_new", run: () => Popups.withFocusedScreen(screen => Popups.open("media", screen)) }]
				});
			return;
		}
		root.state = data.state === "none" ? "none" : "error";
		root.message = data.state === "none" ? (data.silent ? "Nothing is playing" : "No match") : (data.error || "Song detection failed");
		if (Popups.current !== "media") Notifs.pushInternal(root.state === "none" ? "done" : "error", root.message, "", { icon: "waveform" });
	}

	Process {
		id: listener

		command: ["python3", `${Paths.scripts}/song_detect.py`, "--seconds", String(root.listenSeconds)]
		stdout: SplitParser {
			onRead: line => root.handle(line)
		}
		// it ended without an answer
		onExited: if (root.listening) root.handle(JSON.stringify({ state: "error" }))
	}

	FileView {
		id: file

		path: Paths.stateFile("song.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(String(text() || "{}"));
				if (data && data.title) {
					root.song = data;
					root.state = "found";
				}
			} catch (error) {}
		}
	}
}
