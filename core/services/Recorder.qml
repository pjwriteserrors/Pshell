pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Screen recording state for the bar. ~/.local/bin/record reports start and
// stop over IPC (`scripts/ipc.sh recording started|stopped <file>`); a
// slow pgrep only runs while a recording is shown, in case wf-recorder died.
Singleton {
	id: root

	property bool active: false
	property real startedAt: 0
	property string file: ""
	property real now: Date.now()
	readonly property int seconds: root.active ? Math.max(0, Math.floor((root.now - root.startedAt) / 1000)) : 0
	readonly property string elapsed: {
		const s = root.seconds;
		const pad = n => String(n).padStart(2, "0");
		return s >= 3600 ? `${Math.floor(s / 3600)}:${pad(Math.floor(s / 60) % 60)}:${pad(s % 60)}` : `${pad(Math.floor(s / 60))}:${pad(s % 60)}`;
	}

	function started(path) {
		root.file = String(path || "");
		root.startedAt = Date.now();
		root.now = root.startedAt;
		root.active = true;
		Haptics.play("recordingStarted");
	}

	function stopped(path) {
		const file = String(path || root.file);
		const wasActive = root.active;
		root.active = false;
		if (!wasActive) return;
		Haptics.play("recordingStopped");
		if (file === "") return;
		const folder = file.slice(0, file.lastIndexOf("/"));
		Notifs.pushInternal("done", "Recording saved", file.split("/").pop(), {
			icon: "record_rec",
			actions: [
				{ label: "Open", icon: "play", run: () => Quickshell.execDetached(["xdg-open", file]) },
				{ label: "Folder", icon: "folder", run: () => Quickshell.execDetached(["xdg-open", folder]) },
				{ label: "Copy path", icon: "content_copy", run: () => Quickshell.execDetached(["wl-copy", file]) }
			]
		});
	}

	function stop() {
		Quickshell.execDetached(["pkill", "-INT", "-x", "wf-recorder"]);
	}

	Timer {
		running: root.active
		repeat: true
		interval: 1000
		onTriggered: root.now = Date.now()
	}

	Timer {
		running: root.active
		repeat: true
		interval: 5000
		onTriggered: if (!alive.running) alive.running = true
	}

	Process {
		id: alive

		command: ["pgrep", "-x", "wf-recorder"]
		onExited: exitCode => {
			if (exitCode !== 0 && root.active) root.stopped(root.file);
		}
	}

	// a recording that was already running when the shell (re)started
	Process {
		running: true
		command: ["pgrep", "-x", "wf-recorder"]
		onExited: exitCode => {
			if (exitCode === 0 && !root.active) {
				root.startedAt = Date.now();
				root.now = root.startedAt;
				root.active = true;
			}
		}
	}
}
