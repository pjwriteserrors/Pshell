pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets

// Hot corners: a screen whose corners you click on and off. A live corner
// pulses the way the overview would open from it.
Item {
	id: root

	// ["top-left", …]; `off` turns them all off
	property var corners: ["top-left"]
	property bool off: false
	property string label: ""

	signal edited(var corners, bool off)

	implicitWidth: 240
	implicitHeight: 150
	clip: true

	Rectangle {
		id: screen

		anchors.fill: parent
		anchors.margins: 6
		radius: Theme.radius.large
		color: Theme.layer2
		border.width: 1
		border.color: Theme.outline

		StyledText {
			anchors.centerIn: parent
			text: root.off ? "No hot corners" : (root.label || `${root.corners.length} hot corner${root.corners.length === 1 ? "" : "s"}`)
			tone: root.off ? Theme.textSubtle : Theme.textMuted
			font.pixelSize: Theme.size.small
		}
	}

	Repeater {
		model: ["top-left", "top-right", "bottom-left", "bottom-right"]

		delegate: Item {
			id: corner

			required property string modelData
			readonly property bool live: !root.off && root.corners.includes(corner.modelData)
			readonly property bool leftSide: corner.modelData.endsWith("left")
			readonly property bool topSide: corner.modelData.startsWith("top")

			x: corner.leftSide ? 0 : root.width - width
			y: corner.topSide ? 0 : root.height - height
			width: 54
			height: 54

			// the quarter circle in the corner
			Rectangle {
				id: blob

				x: corner.leftSide ? -width / 2 + 6 : corner.width - width / 2 - 6
				y: corner.topSide ? -height / 2 + 6 : corner.height - height / 2 - 6
				width: corner.live ? 64 : (cornerMouse.containsMouse ? 40 : 26)
				height: width
				radius: width / 2
				color: corner.live ? Theme.primary : Qt.alpha(Theme.text, cornerMouse.containsMouse ? 0.18 : 0.08)

				Behavior on width {
					SpatialAnim {
						duration: Motion.medium
					}
				}
				Behavior on color {
					ColorAnim {}
				}
			}

			// the pulse
			Rectangle {
				x: blob.x + blob.width / 2 - width / 2
				y: blob.y + blob.height / 2 - height / 2
				width: blob.width * pulse.grow
				height: width
				radius: width / 2
				color: "transparent"
				border.width: 2
				border.color: Theme.primary
				opacity: corner.live ? 1 - (pulse.grow - 1) : 0

				QtObject {
					id: pulse

					property real grow: 1
				}

				NumberAnimation {
					target: pulse
					property: "grow"
					running: corner.live && root.visible
					from: 1
					to: 1.9
					duration: 1400
					loops: Animation.Infinite
					easing.type: Easing.OutCubic
				}
			}

			MouseArea {
				id: cornerMouse

				anchors.fill: parent
				hoverEnabled: true
				cursorShape: Qt.PointingHandCursor
				onClicked: {
					const now = root.off ? [] : root.corners.slice();
					const next = now.includes(corner.modelData) ? now.filter(c => c !== corner.modelData) : now.concat([corner.modelData]);
					root.edited(next, next.length === 0);
				}
			}
		}
	}
}
