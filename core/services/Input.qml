pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// One reader of the mice, touchpads and keyboards for everything that needs
// them (scripts/input_watch.py): a shaken pointer for FindMouse, a shaken
// drag for Shelf, presses counted for the RPG. It runs with just the parts
// that are wanted and starts anew when that changes.
Singleton {
	id: root

	readonly property bool shaking: Plugins.on("find-mouse")
	readonly property bool dragging: Plugins.on("drop-commands") && Shelf.shake
	// set by the RPG while it plays
	property bool counting: false
	readonly property var args: (root.shaking ? ["--shake"] : []).concat(root.dragging ? ["--drag"] : [], root.counting ? ["--count", "2"] : [])
	readonly property bool wanted: root.args.length > 0
	// "" or why the devices cannot be read: "permission" | "devices"
	property string error: ""

	signal shaken
	signal pressed
	signal dragShaken
	// { keys, clicks } of the last two seconds
	signal activity(var counts)

	function handle(line) {
		let data = null;
		try {
			data = JSON.parse(line);
		} catch (error) {
			return;
		}
		switch (data.type) {
		case "shake":
			root.shaken();
			break;
		case "press":
			root.pressed();
			break;
		case "dragshake":
			root.dragShaken();
			break;
		case "activity":
			root.activity({ keys: Number(data.keys) || 0, clicks: Number(data.clicks) || 0 });
			break;
		case "ready":
			root.error = "";
			break;
		case "error":
			root.error = String(data.reason || "devices");
			break;
		}
	}

	// another set of parts: the reader starts anew with them
	onArgsChanged: {
		daemon.running = false;
		root.error = "";
		Qt.callLater(() => daemon.running = root.wanted);
	}

	Process {
		id: daemon

		running: root.wanted
		command: ["python3", "-u", `${Paths.scripts}/input_watch.py`].concat(root.args)
		stdout: SplitParser {
			onRead: line => root.handle(line)
		}
		onExited: if (root.wanted && root.error === "") revive.restart()
	}

	// a reader that died comes back; one that cannot read stays down
	Timer {
		id: revive

		interval: 5000
		onTriggered: if (root.wanted && root.error === "" && !daemon.running) daemon.running = true
	}
}
