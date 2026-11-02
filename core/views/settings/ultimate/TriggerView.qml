import QtQuick
import qs.style.theme
import qs.style.widgets

// A trigger from the side, live: it fills as far as it is pulled (what the
// pad sends); the two marks are where it starts to count and where it is
// fully down – dragged to set them.
Item {
	id: root

	property string label: ""
	// 0–255, what the pad sends now
	property real value: 0
	// 0–255, as the pad keeps them
	property int start: 0
	property int full: 255
	property color accent: Theme.primary

	signal moved(int start, int full)

	implicitWidth: 92
	implicitHeight: 214

	readonly property real inset: 6
	readonly property real span: root.height - 30 - root.inset

	function yOf(v) {
		return root.inset + root.span * v / 255;
	}

	// the travel
	Rectangle {
		id: track

		x: (root.width - 40) / 2
		y: root.inset
		width: 40
		height: root.span
		radius: 10
		color: Theme.layer2
		border.width: 1
		border.color: Theme.outline
		clip: true

		// before it counts
		Rectangle {
			width: parent.width
			height: root.yOf(root.start) - root.inset
			color: Qt.alpha(Theme.danger, 0.14)
		}

		// pulled
		Rectangle {
			width: parent.width
			height: root.span * Math.min(1, root.value / 255)
			color: root.value >= 250 ? root.accent : Qt.alpha(root.accent, 0.65)
		}
	}

	Repeater {
		model: [
			{ key: "start", tone: Theme.danger },
			{ key: "full", tone: root.accent }
		]

		delegate: Item {
			id: mark

			required property var modelData
			readonly property bool held: drag.which === mark.modelData.key

			x: track.x - 10
			y: root.yOf(mark.modelData.key === "start" ? root.start : root.full) - 6
			width: track.width + 20
			height: 12

			Rectangle {
				anchors.verticalCenter: parent.verticalCenter
				width: parent.width
				height: mark.held ? 4 : 3
				radius: 2
				color: mark.modelData.tone
			}
		}
	}

	StyledText {
		anchors.horizontalCenter: parent.horizontalCenter
		y: root.height - 20
		text: `${root.label} · ${Math.round(root.value / 255 * 100)} %`
		font.pixelSize: Theme.size.small
		tone: Theme.textMuted
	}

	MouseArea {
		id: drag

		property string which: ""

		x: 0
		y: 0
		width: root.width
		height: root.inset + root.span + 8
		cursorShape: drag.which !== "" ? Qt.ClosedHandCursor : Qt.SizeVerCursor

		function valueAt(mouse) {
			return Math.round(Math.max(0, Math.min(1, (mouse.y - root.inset) / root.span)) * 255);
		}

		onPressed: mouse => {
			const v = drag.valueAt(mouse);
			drag.which = Math.abs(v - root.start) <= Math.abs(v - root.full) ? "start" : "full";
		}
		onPositionChanged: mouse => {
			if (drag.which === "") return;
			const v = drag.valueAt(mouse);
			if (drag.which === "start") root.moved(Math.max(0, Math.min(200, Math.min(v, root.full - 10))), root.full);
			else root.moved(root.start, Math.max(60, Math.max(v, root.start + 10)));
		}
		onReleased: drag.which = ""
	}
}
