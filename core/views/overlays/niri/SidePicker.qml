pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets

// Where the tab indicator sits: click a side of the column. The bar glides
// there; its length and thickness are the settings'.
Item {
	id: root

	property string side: "left"
	property real proportion: 0.5
	property real thickness: 4
	property real gap: 5
	property int tabs: 3

	signal picked(string side)

	implicitWidth: 200
	implicitHeight: 170

	readonly property bool vertical: root.side === "left" || root.side === "right"
	readonly property real length: (root.vertical ? win.height : win.width) * Math.max(0.1, Math.min(1, root.proportion))
	readonly property real t: Math.max(3, root.thickness * 1.6)
	readonly property real g: root.gap * 1.6

	Rectangle {
		id: win

		anchors.centerIn: parent
		width: parent.width - 80
		height: parent.height - 70
		radius: 8
		color: Theme.layer2
		border.width: 1
		border.color: Theme.outline
	}

	// the bar
	Item {
		x: root.side === "left" ? win.x - root.g - root.t : (root.side === "right" ? win.x + win.width + root.g : win.x + (win.width - root.length) / 2)
		y: root.side === "top" ? win.y - root.g - root.t : (root.side === "bottom" ? win.y + win.height + root.g : win.y + (win.height - root.length) / 2)
		width: root.vertical ? root.t : root.length
		height: root.vertical ? root.length : root.t

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
		Behavior on width {
			SpatialAnim {
				duration: Motion.long
			}
		}
		Behavior on height {
			SpatialAnim {
				duration: Motion.long
			}
		}

		Repeater {
			model: root.tabs

			delegate: Rectangle {
				required property int index
				readonly property real each: ((root.vertical ? parent.height : parent.width) - 3 * (root.tabs - 1)) / root.tabs

				x: root.vertical ? 0 : index * (each + 3)
				y: root.vertical ? index * (each + 3) : 0
				width: root.vertical ? parent.width : each
				height: root.vertical ? each : parent.height
				radius: Math.min(width, height) / 2
				color: index === 0 ? Theme.primary : Theme.layer3
			}
		}
	}

	// the four sides to click
	Repeater {
		model: ["left", "right", "top", "bottom"]

		delegate: MouseArea {
			id: zone

			required property string modelData
			readonly property bool vertical: zone.modelData === "left" || zone.modelData === "right"

			x: zone.modelData === "left" ? 0 : (zone.modelData === "right" ? win.x + win.width : win.x)
			y: zone.modelData === "top" ? 0 : (zone.modelData === "bottom" ? win.y + win.height : win.y)
			width: zone.vertical ? win.x : win.width
			height: zone.vertical ? win.height : win.y
			hoverEnabled: true
			cursorShape: Qt.PointingHandCursor
			onClicked: root.picked(zone.modelData)

			Rectangle {
				anchors.centerIn: parent
				width: zone.vertical ? 4 : parent.width * 0.5
				height: zone.vertical ? parent.height * 0.5 : 4
				radius: 2
				color: Theme.primary
				opacity: zone.containsMouse && root.side !== zone.modelData ? 0.35 : 0

				Behavior on opacity {
					Anim {
						duration: Motion.short
					}
				}
			}
		}
	}
}
