pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Now playing. Three bars follow the sound (cava) while music plays and
// freeze when paused; a long title scrolls when hovered. Middle click toggles playback, right
// click skips, scroll changes the volume.
BarButton {
	id: root

	readonly property bool hasTrack: Media.barText !== ""
	// width without the title, and what the title would add
	readonly property real fixedWidth: root.padding * 2 + 16
	// do not disturb keeps the bars but drops the title, and so does a
	// paused track when the title is only wanted while it plays
	readonly property bool showTitle: root.hasTrack && !Notifs.dnd && (Media.playing || Media.titleWhenPaused)
	readonly property real textWant: root.showTitle ? 9 + Math.min(220, label.implicitWidth) : 0
	// extra width the bar can spare for the title
	property real room: 1e6
	readonly property real textWidth: root.showTitle && root.room >= 9 + 48 ? Math.min(220, label.implicitWidth, root.room - 9) : 0

	panelId: "media"
	tooltip: Media.hasPlayer ? "Media · scroll for volume · middle-click play/pause · right-click next" : "Media"
	padding: 10
	wheelEnabled: true
	onClicked: toggle()
	onScrolled: wheel => Audio.adjust((wheel.angleDelta.y || -wheel.angleDelta.x) > 0 ? 1 : -1)
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

			ExternalCava {
				id: cava

				bars: 3
				framerate: 30
				active: root.visible && root.hasTrack && Media.playing
			}

			Row {
				anchors.centerIn: parent
				visible: root.hasTrack
				// as tall as the title, and fixed: the row would otherwise
				// re-centre around its tallest bar
				height: label.implicitHeight
				spacing: 2.5

				Repeater {
					model: cava.bars

					delegate: Rectangle {
						id: eq

						required property int index
						readonly property real level: Media.playing ? (cava.values[eq.index] || 0) : 0.3

						anchors.bottom: parent.bottom
						width: 3.5
						height: Math.max(3, parent.height * eq.level)
						radius: 1.75
						color: Theme.primary

						Behavior on height {
							Anim {
								duration: 80
							}
						}
					}
				}
			}
		}

		Item {
			id: viewport

			anchors.verticalCenter: parent.verticalCenter
			visible: root.showTitle && width > 0.5
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
