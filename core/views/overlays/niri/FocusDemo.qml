import QtQuick
import qs.style.theme
import qs.style.widgets

// The pointer wanders between two windows; with focus-follows-mouse the
// focus goes with it, without it stays where the last click was.
Item {
	id: root

	property bool follows: false
	property bool playing: true
	property real phase: 0

	SequentialAnimation on phase {
		running: root.playing && root.visible
		loops: Animation.Infinite

		NumberAnimation {
			from: 0
			to: 1
			duration: 1200
			easing.type: Easing.InOutCubic
		}
		PauseAnimation {
			duration: 500
		}
		NumberAnimation {
			to: 0
			duration: 1200
			easing.type: Easing.InOutCubic
		}
		PauseAnimation {
			duration: 500
		}
	}

	readonly property bool onRight: root.phase > 0.5

	Row {
		anchors.centerIn: parent
		spacing: 4

		Repeater {
			model: 2

			delegate: Rectangle {
				required property int index
				readonly property bool focused: root.follows ? (index === 1) === root.onRight : index === 0

				width: 28
				height: 34
				radius: 5
				color: Theme.layer2
				border.width: 2
				border.color: focused ? Theme.primary : "transparent"

				Behavior on border.color {
					ColorAnim {}
				}
			}
		}
	}

	Glyph {
		x: root.width / 2 - 22 + root.phase * 30
		y: root.height / 2 - 2
		icon: "cursor_default"
		size: 14
		color: Theme.text
	}
}
