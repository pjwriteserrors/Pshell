pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Now playing. Three bars dance while music plays and freeze when paused;
// a long title scrolls when hovered. Middle click toggles playback, right
// click skips.
BarButton {
	id: root

	readonly property bool hasTrack: Media.barText !== ""
	// width without the title, and what the title would add
	readonly property real fixedWidth: root.padding * 2 + 16
	readonly property real textWant: root.hasTrack ? 9 + Math.min(220, label.implicitWidth) : 0
	// extra width the bar can spare for the title
	property real room: 1e6
	readonly property real textWidth: root.hasTrack && root.room >= 9 + 48 ? Math.min(220, label.implicitWidth, root.room - 9) : 0

	panelId: "media"
	tooltip: Media.hasPlayer ? "Media · middle-click play/pause · right-click next" : "Media"
	padding: 10
	onClicked: toggle()
	onMiddleClicked: Media.player?.togglePlaying()
	onRightClicked: Media.player?.next()

	Row {
		anchors.verticalCenter: parent.verticalCenter
		spacing: 9

		Item {
			anchors.verticalCenter: parent.verticalCenter
			width: 16
			height: 16

			Glyph {
				anchors.centerIn: parent
				visible: !root.hasTrack
				icon: "music_note"
				size: 17
				color: root.active ? Theme.primary : Theme.text
			}

			Row {
				anchors.centerIn: parent
				visible: root.hasTrack
				spacing: 2.5

				Repeater {
					model: [0.55, 1, 0.75]

					delegate: Rectangle {
						id: eq

						required property real modelData
						required property int index
						property real level: Media.playing ? eq.modelData : 0.3

						anchors.bottom: parent.bottom
						width: 3.5
						height: Math.max(3, 14 * eq.level)
						radius: 1.75
						color: Theme.primary

						// a new random height every 700 ms, eased in 300 ms: the
						// bars keep moving without repainting every frame
						Behavior on level {
							Anim {
								duration: 300
							}
						}

						Timer {
							running: Media.playing
							repeat: true
							interval: 700 + eq.index * 90
							onTriggered: eq.level = 0.25 + Math.random() * 0.75
							onRunningChanged: if (!running) eq.level = 0.3
						}
					}
				}
			}
		}

		Item {
			id: viewport

			anchors.verticalCenter: parent.verticalCenter
			visible: root.hasTrack && width > 0.5
			width: root.textWidth
			height: label.implicitHeight
			clip: true

			Behavior on width {
				SpatialAnim {
					duration: Motion.medium
				}
			}

			StyledText {
				id: label

				readonly property real overflow: Math.max(0, implicitWidth - viewport.width)
				// ellipsis at rest, the full title scrolls by on hover
				width: root.hovered ? implicitWidth : viewport.width
				text: Media.barText
				elide: root.hovered ? Text.ElideNone : Text.ElideRight
				font.pixelSize: Theme.size.label
				font.weight: Font.Medium
				tone: Media.playing ? Theme.text : Theme.textMuted

				SequentialAnimation on x {
					running: root.hovered && label.overflow > 0
					loops: Animation.Infinite
					onRunningChanged: if (!running) label.x = 0
					PauseAnimation {
						duration: 500
					}
					NumberAnimation {
						from: 0
						to: -label.overflow
						duration: label.overflow * 28
						easing.type: Easing.InOutSine
					}
					PauseAnimation {
						duration: 900
					}
					NumberAnimation {
						to: 0
						duration: 400
						easing.type: Easing.InOutCubic
					}
				}
			}
		}
	}
}
