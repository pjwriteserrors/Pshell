import QtQuick
import qs.style.theme
import qs.style.widgets

// A stick from above, live: the dot is where it is now (what the pad sends,
// after its own dead zone), the inner ring the dead zone, the outer one
// where it counts as fully out. Both rings are dragged to set them.
Item {
	id: root

	property string label: ""
	// -1…1 each
	property real ax: 0
	property real ay: 0
	property bool pressed: false
	// 0–128, as the pad keeps them
	property int dead: 0
	property int full: 128
	property color accent: Theme.primary

	// a ring was dragged to (dead, full)
	signal moved(int dead, int full)

	implicitWidth: 190
	implicitHeight: 214

	readonly property real radius: Math.min(width, height - 24) / 2 - 8
	readonly property real cx: width / 2
	readonly property real cy: (height - 24) / 2
	readonly property real deadR: root.radius * root.dead / 128
	readonly property real fullR: root.radius * root.full / 128
	readonly property real reach: Math.min(1, Math.hypot(root.ax, root.ay))

	// the stick's whole way
	Rectangle {
		x: root.cx - root.radius
		y: root.cy - root.radius
		width: root.radius * 2
		height: width
		radius: width / 2
		color: Theme.layer2
		border.width: 1
		border.color: Theme.outline
	}

	// fully out from here on
	Rectangle {
		x: root.cx - root.fullR
		y: root.cy - root.fullR
		width: root.fullR * 2
		height: width
		radius: width / 2
		color: "transparent"
		border.width: drag.which === "full" ? 3 : 2
		border.color: Qt.alpha(root.accent, 0.7)
	}

	// nothing in here
	Rectangle {
		x: root.cx - root.deadR
		y: root.cy - root.deadR
		width: Math.max(2, root.deadR * 2)
		height: width
		radius: width / 2
		color: Qt.alpha(Theme.danger, 0.16)
		border.width: drag.which === "dead" ? 3 : 1.5
		border.color: Qt.alpha(Theme.danger, 0.75)
	}

	// cross
	Rectangle {
		x: root.cx - root.radius
		y: root.cy
		width: root.radius * 2
		height: 1
		color: Theme.outline
	}

	Rectangle {
		x: root.cx
		y: root.cy - root.radius
		width: 1
		height: root.radius * 2
		color: Theme.outline
	}

	// where it is
	Rectangle {
		width: 16
		height: 16
		radius: 8
		x: root.cx + root.ax * root.radius - 8
		y: root.cy + root.ay * root.radius - 8
		color: root.pressed ? Theme.text : root.accent
		border.width: 2
		border.color: Theme.base
	}

	StyledText {
		anchors.horizontalCenter: parent.horizontalCenter
		y: root.height - 20
		text: `${root.label} · ${Math.round(root.reach * 100)} %`
		font.pixelSize: Theme.size.small
		tone: Theme.textMuted
	}

	MouseArea {
		id: drag

		property string which: ""

		x: root.cx - root.radius
		y: root.cy - root.radius
		width: root.radius * 2
		height: width
		cursorShape: drag.which !== "" ? Qt.ClosedHandCursor : Qt.PointingHandCursor
		hoverEnabled: true

		function at(mouse) {
			return Math.hypot(mouse.x - root.radius, mouse.y - root.radius);
		}

		onPressed: mouse => {
			const r = drag.at(mouse);
			drag.which = Math.abs(r - root.deadR) <= Math.abs(r - root.fullR) ? "dead" : "full";
		}
		onPositionChanged: mouse => {
			if (drag.which === "") return;
			const v = Math.round(Math.min(1, drag.at(mouse) / root.radius) * 128);
			if (drag.which === "dead") root.moved(Math.max(0, Math.min(60, Math.min(v, root.full - 8))), root.full);
			else root.moved(root.dead, Math.max(64, Math.max(v, root.dead + 8)));
		}
		onReleased: drag.which = ""
	}
}
