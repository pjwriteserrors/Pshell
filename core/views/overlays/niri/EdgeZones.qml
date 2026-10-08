import QtQuick
import qs.style.theme
import qs.style.widgets

// The strips at the screen's edges that scroll while something is dragged
// there. Drag a strip's inner edge to make it wider; a file being dragged
// shows when it kicks in.
Item {
	id: root

	// "sides" (the view scrolls left/right) or "ends" (workspaces up/down)
	property string axis: "sides"
	property real trigger: 30
	property int delay: 100
	property real logical: root.axis === "sides" ? 1920 : 1080
	property bool playing: true

	signal moved(real trigger)

	readonly property bool sides: root.axis === "sides"
	readonly property real length: root.sides ? width : height
	readonly property real band: root.trigger / root.logical * root.length

	implicitWidth: 300
	implicitHeight: 150

	property real phase: 0

	SequentialAnimation on phase {
		running: root.playing && root.visible
		loops: Animation.Infinite

		NumberAnimation {
			from: 0
			to: 1
			duration: 1600
			easing.type: Easing.InOutCubic
		}
		PauseAnimation {
			duration: root.delay + 500
		}
		NumberAnimation {
			to: 0
			duration: 900
			easing.type: Easing.InOutCubic
		}
	}

	Rectangle {
		anchors.fill: parent
		radius: Theme.radius.large
		color: Theme.layer2
		border.width: 1
		border.color: Theme.outline
	}

	Repeater {
		model: [0, 1]

		delegate: Rectangle {
			required property int index

			x: root.sides ? (index === 0 ? 0 : root.width - root.band) : 0
			y: root.sides ? 0 : (index === 0 ? 0 : root.height - root.band)
			width: root.sides ? root.band : root.width
			height: root.sides ? root.height : root.band
			radius: Theme.radius.large
			color: Qt.alpha(Theme.primary, 0.22 + (index === 1 && root.phase > 0.97 ? 0.25 : 0))

			Behavior on color {
				ColorAnim {}
			}

			// the inner edge to drag
			Rectangle {
				x: root.sides ? (index === 0 ? parent.width - 2 : 0) : parent.width / 2 - 20
				y: root.sides ? parent.height / 2 - 20 : (index === 0 ? parent.height - 2 : 0)
				width: root.sides ? 4 : 40
				height: root.sides ? 40 : 4
				radius: 2
				color: Theme.primary

				MouseArea {
					anchors.fill: parent
					anchors.margins: -10
					preventStealing: true
					cursorShape: root.sides ? Qt.SizeHorCursor : Qt.SizeVerCursor
					onPositionChanged: event => {
						if (!pressed) return;
						const p = mapToItem(root, event.x, event.y);
						let px = root.sides ? (index === 0 ? p.x : root.width - p.x) : (index === 0 ? p.y : root.height - p.y);
						root.moved(Math.max(5, Math.min(root.logical / 4, Math.round(px / root.length * root.logical))));
					}
				}
			}
		}
	}

	// a file on its way to the edge
	Rectangle {
		x: root.sides ? root.width * 0.3 + root.phase * (root.width * 0.7 - 30) : root.width / 2 - 14
		y: root.sides ? root.height / 2 - 18 : root.height * 0.3 + root.phase * (root.height * 0.7 - 34)
		width: 28
		height: 34
		radius: 5
		color: Theme.base
		border.width: 1.5
		border.color: Theme.primary

		Glyph {
			anchors.centerIn: parent
			icon: "file_outline"
			size: 14
			color: Theme.primary
		}
	}

	StyledText {
		anchors.centerIn: parent
		text: `${Math.round(root.trigger)} px`
		tabular: true
		tone: Theme.textMuted
		font.weight: Font.DemiBold
	}
}
