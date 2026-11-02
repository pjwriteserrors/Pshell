pragma Singleton

import QtQuick
import Quickshell

// The laser pointer for presentations: while it is on, the pointer is a
// glowing dot with a short trail (LaserPointer draws it). A key or IPC turns
// it on and off; a click, the wheel or Escape ends it.
// As with FindMouse the shell does not know where the pointer is: every
// screen listens for it while the laser is on, and the one it moves on says
// so here.
Singleton {
	id: root

	readonly property bool available: Plugins.on("laser-pointer")
	property bool active: false
	// the screen the pointer is on and where, once it is known
	property string output: ""
	property real x: 0
	property real y: 0

	function toggle() {
		if (root.active) root.hide();
		else root.show();
	}

	function show() {
		if (!root.available || Session.locked) return;
		root.output = "";
		root.active = true;
	}

	function hide() {
		root.active = false;
	}

	function at(output, x, y) {
		root.output = output;
		root.x = x;
		root.y = y;
	}

	// Escape ends it without the screens taking the keyboard: the keys stay
	// with the presentation, to turn its slides
	Connections {
		target: Input
		enabled: root.active

		function onEscaped() {
			root.hide();
		}
	}

	Connections {
		target: Session

		function onLockedChanged() {
			if (Session.locked) root.hide();
		}
	}

	onAvailableChanged: root.hide()
}
