import QtQuick

// The dots that chase each other round a circle while Windows boots: each
// one speeds up and slows down on its lap, a little after the one before.
Item {
	id: root

	property bool running: false
	property color color: "white"
	property int count: 5
	property real dot: 4.5

	implicitWidth: 34
	implicitHeight: 34
	opacity: root.running ? 1 : 0

	Behavior on opacity {
		NumberAnimation {
			duration: 300
		}
	}

	Repeater {
		model: root.count

		delegate: Item {
			id: orbit

			required property int index

			anchors.fill: parent

			Rectangle {
				x: (orbit.width - width) / 2
				width: root.dot
				height: root.dot
				radius: width / 2
				color: root.color
			}

			SequentialAnimation on rotation {
				running: root.running && root.visible
				loops: Animation.Infinite

				PauseAnimation {
					duration: orbit.index * 110
				}
				NumberAnimation {
					from: 0
					to: 360
					duration: 1500
					easing.type: Easing.InOutCubic
				}
				NumberAnimation {
					from: 360
					to: 720
					duration: 1500
					easing.type: Easing.InOutCubic
				}
				PauseAnimation {
					duration: (root.count - 1 - orbit.index) * 110 + 380
				}
			}

			// each dot is there only while it runs its laps
			SequentialAnimation on opacity {
				running: root.running && root.visible
				loops: Animation.Infinite

				PauseAnimation {
					duration: orbit.index * 110
				}
				NumberAnimation {
					from: 0
					to: 1
					duration: 160
				}
				PauseAnimation {
					duration: 2680
				}
				NumberAnimation {
					from: 1
					to: 0
					duration: 160
				}
				PauseAnimation {
					duration: (root.count - 1 - orbit.index) * 110 + 380
				}
			}
		}
	}
}
