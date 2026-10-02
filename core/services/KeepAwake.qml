pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Keeps the machine awake: every bar holds a Wayland idle inhibitor while
// this is active, and a systemd inhibitor blocks idle actions and suspend
// requests. Closing the lid still suspends. Not persisted across restarts.
Singleton {
	id: root

	readonly property bool available: Plugins.on("keep-awake")
	property bool active: false

	onAvailableChanged: if (!root.available) root.active = false

	function toggle() {
		root.active = root.available && !root.active;
	}

	Process {
		running: root.active
		command: ["systemd-inhibit", "--what=idle:sleep", "--who=Quickshell", "--why=Keep awake", "--mode=block", "sleep", "infinity"]
	}
}
