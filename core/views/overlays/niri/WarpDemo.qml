pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets

// The keyboard moves the focus to the lower window; the pointer follows –
// straight down only (shortest way), to its middle, or always to its middle.
Item {
	id: root

	property string mode: ""
	property bool playing: true
	property int step: 0

	Timer {
		interval: 1200
		repeat: true
		running: root.playing && root.visible
		onTriggered: root.step = (root.step + 1) % 2
	}

	readonly property bool lower: root.step === 1
	// where the pointer starts inside the upper window, and where it goes
	readonly property point start: Qt.point(win1.x + win1.width * 0.82, win1.y + win1.height * 0.5)
	readonly property point target: {
		if (!root.lower) return root.start;
		if (root.mode === "") return Qt.point(root.start.x, win2.y + 8);
		return Qt.point(win2.x + win2.width / 2, win2.y + win2.height / 2);
	}

	Rectangle {
		id: win1

		x: root.width / 2 - 40
		y: 6
		width: 80
		height: 28
		radius: 5
		color: Theme.layer3
		border.width: 2
		border.color: !root.lower ? Theme.primary : "transparent"
	}

	Rectangle {
		id: win2

		x: root.width / 2 - 30
		y: 40
		width: 60
		height: 30
		radius: 5
		color: Theme.layer3
		border.width: 2
		border.color: root.lower ? Theme.primary : "transparent"
	}

	Glyph {
		x: root.target.x - 2
		y: root.target.y - 2
		icon: "cursor_default"
		size: 15
		color: Theme.text

		Behavior on x {
			SpatialAnim {
				duration: Motion.long
			}
		}
		Behavior on y {
			SpatialAnim {
				duration: Motion.long
			}
		}
	}
}
