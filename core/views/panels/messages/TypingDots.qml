pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme

// Someone is writing: three dots that rise one after the other.
Row {
	id: root

	property color tone: Theme.textMuted
	property bool running: true

	spacing: 4

	Repeater {
		model: 3

		delegate: Rectangle {
			id: dot

			required property int index

			width: 6
			height: 6
			radius: 3
			color: root.tone
			opacity: 0.45

			transform: Translate {
				id: lift
			}

			SequentialAnimation {
				running: root.running && root.visible
				loops: Animation.Infinite
				onRunningChanged: if (!running) {
					lift.y = 0;
					dot.opacity = 0.45;
				}

				PauseAnimation {
					duration: dot.index * 140
				}
				ParallelAnimation {
					NumberAnimation {
						target: lift
						property: "y"
						to: -4
						duration: 220
						easing.type: Easing.OutCubic
					}
					NumberAnimation {
						target: dot
						property: "opacity"
						to: 1
						duration: 220
					}
				}
				ParallelAnimation {
					NumberAnimation {
						target: lift
						property: "y"
						to: 0
						duration: 320
						easing.type: Easing.InOutCubic
					}
					NumberAnimation {
						target: dot
						property: "opacity"
						to: 0.45
						duration: 320
					}
				}
				PauseAnimation {
					duration: 620 - dot.index * 140
				}
			}
		}
	}
}
