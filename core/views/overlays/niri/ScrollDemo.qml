pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets

// Two fingers push up; the page goes up with them (natural) or the other way.
Item {
	id: root

	property bool natural: false
	property bool playing: true

	implicitWidth: 64
	implicitHeight: 44
	clip: true

	property real phase: 0

	SequentialAnimation on phase {
		running: root.playing && root.visible
		loops: Animation.Infinite

		NumberAnimation {
			from: 0
			to: 1
			duration: 1100
			easing.type: Easing.InOutCubic
		}
		PauseAnimation {
			duration: 350
		}
		NumberAnimation {
			to: 0
			duration: 400
			easing.type: Easing.InOutCubic
		}
	}

	Rectangle {
		anchors.fill: parent
		radius: 6
		color: Theme.layer2
	}

	// the page
	Column {
		x: 8
		y: 6 + (root.natural ? -1 : 1) * root.phase * 12
		spacing: 4

		Repeater {
			model: 6

			delegate: Rectangle {
				required property int index

				width: [30, 22, 34, 18, 28, 24][index]
				height: 3
				radius: 1.5
				color: index === 2 ? Theme.primary : Theme.layer3
			}
		}
	}

	// the fingers
	Row {
		x: root.width - 22
		y: 28 - root.phase * 16
		spacing: 2
		opacity: 0.85

		Repeater {
			model: 2

			delegate: Rectangle {
				width: 6
				height: 9
				radius: 3
				color: Theme.text
			}
		}
	}
}
