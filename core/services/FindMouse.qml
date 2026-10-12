pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Shaking the pointer with nothing held shows where it is
// (scripts/find_mouse.py tells of the shake, MouseFinder draws the light).
// The shell does not know where the pointer is: while the light is wanted
// every screen listens for it, and the one it moves on says so here.
Singleton {
	id: root

	readonly property bool available: Plugins.on("find-mouse")
	// wanted: the pointer is being shaken, or was a moment ago
	property bool active: false
	// the screen the pointer is on and where, once it is known
	property string output: ""
	property real x: 0
	property real y: 0
	// the daemon cannot work here; said once
	property bool failed: false

	readonly property var failures: ({
		permission: "The mouse is not readable",
		devices: "No mouse"
	})

	function show() {
		if (!root.available || Session.locked) return;
		if (!root.active) root.output = "";
		root.active = true;
		hold.restart();
	}

	function hide() {
		root.active = false;
		hold.stop();
	}

	function at(output, x, y) {
		root.output = output;
		root.x = x;
		root.y = y;
	}

	function handle(line) {
		let data = null;
		try {
			data = JSON.parse(line);
		} catch (error) {
			return;
		}
		if (data.type === "shake") {
			root.show();
		} else if (data.type === "press") {
			root.hide();
		} else if (data.type === "error") {
			root.failed = true;
			Notifs.pushInternal("error", "Find my mouse", root.failures[data.reason] ?? "", { icon: "mouse_variant" });
		}
	}

	onAvailableChanged: {
		root.failed = false;
		root.hide();
	}

	// how long the light stays after the last turn of the shake
	Timer {
		id: hold

		interval: 900
		onTriggered: root.active = false
	}

	Process {
		id: daemon

		running: root.available && !root.failed
		command: ["python3", "-u", `${Paths.scripts}/find_mouse.py`]
		stdout: SplitParser {
			onRead: line => root.handle(line)
		}
		onExited: {
			if (root.available && !root.failed) revive.restart();
		}
	}

	// a daemon that died comes back
	Timer {
		id: revive

		interval: 5000
		onTriggered: if (root.available && !root.failed && !daemon.running) daemon.running = true
	}
}
