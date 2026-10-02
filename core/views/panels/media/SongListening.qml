pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Song detection while it listens: what plays spreads from the middle as a
// wave, the lows in the centre, and the ring around the ear fills until it
// gives up. Without sound the wave keeps rolling on its own.
Item {
	id: root

	property bool active: false
	readonly property int half: 22
	property real phase: 0
	readonly property real elapsed: {
		root.phase;
		return Math.max(0, Math.min(1, (Date.now() - SongDetect.startedAt) / (SongDetect.listenSeconds * 1000)));
	}

	implicitHeight: 72

	ExternalCava {
		id: cava

		bars: root.half
		active: root.active
	}

	NumberAnimation on phase {
		running: root.active
		from: 0
		to: 2 * Math.PI
		duration: 2400
		loops: Animation.Infinite
	}

	Item {
		id: ear

		readonly property real bass: ((cava.values[0] || 0) + (cava.values[1] || 0) + (cava.values[2] || 0)) / 3

		anchors.left: parent.left
		anchors.verticalCenter: parent.verticalCenter
		width: 56
		height: 56

		Repeater {
			model: 2

			delegate: Rectangle {
				required property int index
				readonly property real travel: (root.phase / (2 * Math.PI) + index * 0.5) % 1

				anchors.centerIn: parent
				width: 40
				height: 40
				radius: 20
				color: "transparent"
				border.color: Theme.primary
				border.width: 1.5
				scale: 1 + travel * 0.6
				opacity: (1 - travel) * 0.55
			}
		}

		Ring {
			anchors.fill: parent
			value: root.elapsed
			thickness: 3
			animated: false
			trackColor: Qt.alpha(Theme.text, 0.1)
		}

		Rectangle {
			anchors.centerIn: parent
			width: 40
			height: 40
			radius: 20
			color: Theme.primary
			scale: 1 + ear.bass * 0.14

			Behavior on scale {
				NumberAnimation {
					duration: 90
					easing.type: Easing.OutQuad
				}
			}

			Glyph {
				anchors.centerIn: parent
				icon: "waveform"
				size: 20
				color: Theme.onPrimary
			}
		}
	}

	Item {
		id: wave

		readonly property int count: root.half * 2
		readonly property real slot: width / wave.count

		anchors.left: ear.right
		anchors.leftMargin: 14
		anchors.right: parent.right
		anchors.rightMargin: 36
		anchors.top: parent.top
		anchors.bottom: parent.bottom

		Repeater {
			model: wave.count

			delegate: Rectangle {
				id: bar

				required property int index
				// 0 in the middle
				readonly property int distance: bar.index < root.half ? root.half - 1 - bar.index : bar.index - root.half
				readonly property real level: Math.max(cava.values[bar.distance] || 0, 0.08 + 0.06 * Math.sin(root.phase * 2 - bar.distance * 0.55))

				x: bar.index * wave.slot + (wave.slot - bar.width) / 2
				anchors.verticalCenter: parent.verticalCenter
				width: Math.max(2, wave.slot * 0.5)
				height: Math.max(bar.width, bar.level * wave.height)
				radius: bar.width / 2
				color: Qt.tint(Theme.primary, Qt.alpha(Theme.secondary, bar.distance / root.half))
				opacity: 1 - 0.75 * bar.distance / root.half

				Behavior on height {
					NumberAnimation {
						duration: 90
						easing.type: Easing.OutQuad
					}
				}
			}
		}
	}

	IconButton {
		anchors.right: parent.right
		anchors.top: parent.top
		implicitWidth: 28
		implicitHeight: 28
		icon: "close"
		onClicked: SongDetect.cancel()
	}
}
