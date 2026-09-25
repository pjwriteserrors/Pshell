pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Keeps the machine awake: every bar holds a Wayland idle inhibitor while
// this is active, and a systemd inhibitor blocks idle actions and suspend
// requests. Closing the lid still suspends. Not persisted across restarts.
Singleton {
	id: root

	property bool active: false

	function toggle() {
		root.active = !root.active;
	}

	Process {
		running: root.active
		command: ["systemd-inhibit", "--what=idle:sleep", "--who=Quickshell", "--why=Keep awake", "--mode=block", "sleep", "infinity"]
	}
}
