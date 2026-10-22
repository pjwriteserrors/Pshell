pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import qs.style.theme
import qs.style.widgets
import "NiriColor.js" as NiriColor

// The overview: workspaces shrunk onto the backdrop, each with its shadow.
// Drag the corner of the middle one to zoom.
Item {
	id: root

	property real zoom: 0.5
	property string backdrop: "#262626"
	property bool shadowOn: true
	property real softness: 40
	property real spread: 10
	property real offsetY: 10
	property string shadowColor: "#00000050"

	signal zoomed(real zoom)

	implicitWidth: 480
	implicitHeight: 270

	property real shown: root.zoom

	Behavior on shown {
		enabled: !handle.pressed
		SpatialAnim {
			duration: Motion.medium
		}
	}

	RoundClip {
		anchors.fill: parent
		radius: Theme.radius.large

		Rectangle {
			anchors.fill: parent
			color: NiriColor.qt(root.backdrop, "#262626")

			Behavior on color {
				ColorAnim {}
			}
		}

		// workspaces above and below, the way niri stacks them
		Repeater {
			model: [-1, 0, 1]

			delegate: Item {
				id: ws

				required property int modelData
				readonly property real w: root.width * root.shown
				readonly property real h: root.height * root.shown
				// the shadow is set for a 1080 px tall workspace, then zoomed
				readonly property real unit: ws.h / 1080

				x: (root.width - ws.w) / 2
				y: (root.height - ws.h) / 2 + ws.modelData * (ws.h + root.height * 0.04)
				width: ws.w
				height: ws.h

				RectangularShadow {
					visible: root.shadowOn
					anchors.fill: parent
					offset.y: root.offsetY * ws.unit
					blur: root.softness * ws.unit
					spread: root.spread * ws.unit
					color: NiriColor.qt(root.shadowColor, "#00000050")
					cached: false
				}

				RoundClip {
					anchors.fill: parent
					radius: 4

					Image {
						anchors.fill: parent
						source: Theme.wal?.wallpaper ? `file://${Theme.wal.wallpaper}` : ""
						fillMode: Image.PreserveAspectCrop
						sourceSize.width: 600
						asynchronous: true
					}

					Row {
						x: parent.width * 0.04
						y: parent.height * 0.06
						spacing: parent.width * 0.02

						Repeater {
							model: ws.modelData === 0 ? [0.45, 0.32] : [0.6]

							delegate: Rectangle {
								required property real modelData

								width: ws.w * modelData
								height: ws.h * 0.88
								radius: 3
								color: Qt.alpha(Theme.base, 0.92)
							}
						}
					}
				}
			}
		}
	}

	// the zoom handle on the corner of the middle workspace
	Rectangle {
		readonly property real cx: (root.width + root.width * root.shown) / 2
		readonly property real cy: (root.height + root.height * root.shown) / 2

		x: cx - width / 2
		y: cy - height / 2
		width: handle.pressed ? 22 : 18
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

		MouseArea {
			id: handle

			anchors.fill: parent
			anchors.margins: -10
			preventStealing: true
			cursorShape: Qt.SizeFDiagCursor
			onPositionChanged: event => {
				if (!pressed) return;
				const p = mapToItem(root, event.x, event.y);
				const zx = (2 * p.x - root.width) / root.width;
				const zy = (2 * p.y - root.height) / root.height;
				root.zoomed(Math.max(0.05, Math.min(0.75, Math.round(Math.max(zx, zy) * 100) / 100)));
			}
		}
	}

	Rectangle {
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		anchors.margins: 10
		width: zoomLabel.implicitWidth + 16
		height: 24
		radius: 12
		color: Qt.alpha(Theme.base, 0.8)

		StyledText {
			id: zoomLabel

			anchors.centerIn: parent
			text: `${Math.round(root.zoom * 100)}%`
			tabular: true
			font.weight: Font.DemiBold
			font.pixelSize: Theme.size.small
		}
	}
}
