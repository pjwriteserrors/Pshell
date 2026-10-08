pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import "NiriColor.js" as NiriColor

// The Alt-Tab switcher: window previews in a row, the picked one on its
// highlight. The selection walks along while it plays.
Item {
	id: root

	property string active: "#999999ff"
	property string urgent: "#ff9999ff"
	property real padding: 30
	property real corner: 0
	property real maxScale: 0.5
	property bool playing: true
	property int at: 1

	implicitWidth: 520
	implicitHeight: 170
	clip: true

	Timer {
		interval: 900
		repeat: true
		running: root.playing && root.visible
		onTriggered: root.at = (root.at + 1) % 4
	}

	RoundClip {
		anchors.fill: parent
		radius: Theme.radius.large

		Image {
			anchors.fill: parent
			source: Theme.wal?.wallpaper ? `file://${Theme.wal.wallpaper}` : ""
			fillMode: Image.PreserveAspectCrop
			sourceSize.width: 600
			asynchronous: true
		}

		Rectangle {
			anchors.fill: parent
			color: Qt.rgba(0, 0, 0, 0.45)
		}
	}

	Row {
		id: previews

		readonly property real scaleShown: Math.max(0.2, Math.min(0.75, root.maxScale))
		readonly property real h: (root.height - 40) * scaleShown / 0.75 * 0.9

		anchors.centerIn: parent
		spacing: root.padding * 0.3 + 14

		Repeater {
			model: [1.5, 1.0, 1.3, 0.8]

			delegate: Item {
				id: thumb

				required property real modelData
				required property int index
				readonly property bool picked: root.at === thumb.index
				readonly property real pad: root.padding * 0.3

				width: previews.h * thumb.modelData
				height: previews.h

				Behavior on width {
					SpatialAnim {}
				}

				Rectangle {
					x: -thumb.pad
					y: -thumb.pad
					width: parent.width + thumb.pad * 2
					height: parent.height + thumb.pad * 2
					radius: root.corner * 0.3
					color: NiriColor.qt(thumb.index === 2 ? root.urgent : root.active)
					opacity: thumb.picked ? 1 : (thumb.index === 2 ? 0.35 : 0)

					Behavior on opacity {
						Anim {
							duration: Motion.short
						}
					}
				}

				Rectangle {
					anchors.fill: parent
					radius: 4
					color: Theme.base
					border.width: 1
					border.color: Theme.outline

					Rectangle {
						x: 6
						y: 6
						width: parent.width * 0.5
						height: 5
						radius: 2.5
						color: Theme.layer3
					}
				}
			}
		}
	}
}
