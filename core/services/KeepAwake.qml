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
		if (root.available) Sounds.play(root.active ? "toggleOn" : "toggleOff");
	}

	// also while the task manager waits for a watched process to finish
	readonly property bool holding: root.active || (Plugins.on("task-manager") && TaskManager.holdsAwake)

	Process {
		running: root.holding
		command: ["systemd-inhibit", "--what=idle:sleep", "--who=Quickshell", "--why=Keep awake", "--mode=block", "sleep", "infinity"]
	}
}
