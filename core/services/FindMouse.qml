pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Shaking the pointer with nothing held makes it grow, more with every turn
// of the shake, and it shrinks back as soon as the shaking stops
// (Input tells of the shake, MouseFinder draws the grown pointer).
// The shell does not know where the pointer is: while it is grown every
// screen listens for it, and the one it moves on says so here.
// Not while the laser pointer is on: that is a pointer of its own.
Singleton {
	id: root

	// a game (game mode) has the mouse to itself
	readonly property bool available: Plugins.on("find-mouse") && !(GameMode.active && GameMode.pauseFindMouse)
	// wanted: the pointer is being shaken, or was a moment ago
	property bool active: false
	// turns of the shake so far: the pointer grows with them
	property int turns: 0
	// how big the pointer is drawn, 1 its own size
	readonly property real size: root.active ? Math.min(5, 1.8 + 0.35 * (root.turns - 1)) : 1
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

	function grow() {
		if (!root.available || Session.locked || Laser.active) return;
		if (!root.active) {
			root.output = "";
			root.turns = 0;
		}
		root.turns += 1;
		root.active = true;
		hold.interval = 380;
		hold.restart();
	}

	// asked for without a shake (a key, the phone): grown for a moment
	function show() {
		if (!root.available || Session.locked || Laser.active) return;
		if (!root.active) root.output = "";
		root.turns = Math.max(root.turns, 5);
		root.active = true;
		hold.interval = 1200;
		hold.restart();
	}

	function hide() {
		root.active = false;
		root.turns = 0;
		hold.stop();
	}

	function at(output, x, y) {
		root.output = output;
		root.x = x;
		root.y = y;
	}

	Connections {
		target: Input
		enabled: root.available

		function onShaken() {
			root.grow();
		}
		function onPressed() {
			root.hide();
		}
		function onErrorChanged() {
			if (Input.error === "" || !Input.shaking) return;
			root.failed = true;
			Notifs.pushInternal("error", "Find my mouse", root.failures[Input.error] ?? "", { icon: "mouse_variant" });
		}
	}

	Connections {
		target: Laser

		function onActiveChanged() {
			if (Laser.active) root.hide();
		}
	}

	onAvailableChanged: {
		root.failed = false;
		root.hide();
	}

	// how long the pointer stays grown after the last turn of the shake
	Timer {
		id: hold

		interval: 380
		onTriggered: root.hide()
	}
}
