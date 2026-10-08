import QtQuick
import qs.style.theme
import qs.style.widgets

// A window whose corner you pull: dragging the handle along the diagonal
// rounds it (geometry-corner-radius). The number follows the pointer.
Item {
	id: root

	property real radius: 0
	property real maxRadius: 40
	// preview pixels per logical pixel
	property real zoom: 2
	property bool clipped: true

	signal moved(real radius)

	implicitWidth: 230
	implicitHeight: 170

	property real shown: root.radius

	Behavior on shown {
		enabled: !mouse.pressed
		SpatialAnim {
			duration: Motion.medium
		}
	}

	Rectangle {
		id: win

		x: 24
		y: 24
		width: parent.width - 48
		height: parent.height - 48
		radius: root.shown * root.zoom
		color: Theme.layer2
		border.width: 1.5
		border.color: Qt.alpha(Theme.primary, 0.5)

		// what an app draws: cut at the corners only when clipped – else
		// its square corners poke out of the rounded border
		RoundClip {
			anchors.fill: parent
			radius: root.clipped ? win.radius : 0

			Rectangle {
				width: parent.width
				height: 26
				color: Theme.layer3
			}

			Column {
				x: 14
				y: 40
				spacing: 7

				Repeater {
					model: [0.7, 0.55, 0.8, 0.45]

					delegate: Rectangle {
						required property real modelData

						width: (win.width - 28) * modelData
						height: 6
						radius: 3
						color: Qt.alpha(Theme.text, 0.12)
					}
				}
			}
		}
	}

	// the arc guide and the handle on the top-right corner
	Rectangle {
		id: handle

		readonly property real inset: root.shown * root.zoom * (1 - Math.SQRT1_2)

		x: win.x + win.width - handle.inset - width / 2
		y: win.y + handle.inset - height / 2
		width: mouse.pressed ? 24 : 18
		height: width
		radius: width / 2
		color: Theme.primary
		border.width: 3
		border.color: Theme.base

		Behavior on width {
			SpatialAnim {
				duration: Motion.short
			}
		}
	}

	Rectangle {
		anchors.horizontalCenter: handle.horizontalCenter
		anchors.bottom: handle.top
		anchors.bottomMargin: 6
		width: radiusLabel.implicitWidth + 14
		height: 22
		radius: 11
		color: Theme.layer3
		opacity: mouse.pressed || mouse.containsMouse ? 1 : 0.85

		StyledText {
			id: radiusLabel

			anchors.centerIn: parent
			text: `${Math.round(root.radius)} px`
			tabular: true
			font.pixelSize: Theme.size.small
			font.weight: Font.DemiBold
		}
	}

	MouseArea {
		id: mouse

		x: win.x + win.width - 70
		y: win.y - 20
		width: 90
		height: 90
		hoverEnabled: true
		preventStealing: true
		cursorShape: Qt.SizeBDiagCursor
		onPositionChanged: event => {
			if (!pressed) return;
			const p = mapToItem(root, event.x, event.y);
			// distance in from the corner, along the diagonal
			const dx = win.x + win.width - p.x;
			const dy = p.y - win.y;
			const inward = Math.max(0, (dx + dy) / 2);
			root.moved(Math.max(0, Math.min(root.maxRadius, Math.round(inward / (1 - Math.SQRT1_2) / root.zoom))));
		}
	}
}
