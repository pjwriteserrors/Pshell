import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// A step of the install: waiting (a faint dot), at work (turning, with how
// far it is) or done (a tick that pops in). The steps come in one by one.
Item {
	id: root

	property string label: ""
	// "waiting" | "working" | "done"
	property string phase: "waiting"
	property real progress: 0
	property int order: 0

	implicitHeight: 30
	opacity: 0
	transform: Translate {
		id: slide

		y: 8
	}

	Component.onCompleted: arrive.start()

	SequentialAnimation {
		id: arrive

		PauseAnimation {
			duration: 55 * root.order
		}
		ParallelAnimation {
			Anim {
				target: root
				property: "opacity"
				to: 1
				duration: Motion.long
			}
			SpatialAnim {
				target: slide
				property: "y"
				to: 0
			}
		}
	}

	RowLayout {
		anchors.fill: parent
		spacing: 12

		Item {
			Layout.preferredWidth: 20
			Layout.preferredHeight: 20

			Rectangle {
				anchors.centerIn: parent
				width: 8
				height: 8
				radius: 4
				color: Theme.textFaint
				scale: root.phase === "waiting" ? 1 : 0

				Behavior on scale {
					SpatialAnim {}
				}
			}

			Spinner {
				anchors.fill: parent
				visible: root.phase === "working"
			}

			Rectangle {
				anchors.fill: parent
				radius: 10
				color: Theme.success
				scale: root.phase === "done" ? 1 : 0
				visible: scale > 0

				Behavior on scale {
					NumberAnimation {
						duration: Motion.long
						easing.type: Easing.OutBack
						easing.overshoot: 2.4
					}
				}

				Glyph {
					anchors.centerIn: parent
					icon: "check"
					size: 13
					color: Theme.bg
				}
			}
		}

		StyledText {
			Layout.fillWidth: true
			text: root.label
			tone: root.phase === "waiting" ? Theme.textSubtle : Theme.text
			font.weight: root.phase === "working" ? Font.DemiBold : Font.Normal

			Behavior on tone {
				ColorAnim {}
			}
		}

		// how far a long step is
		Rectangle {
			Layout.preferredWidth: 120
			Layout.preferredHeight: 4
			radius: 2
			color: Theme.layer3
			opacity: root.phase === "working" && root.progress > 0 && root.progress < 1 ? 1 : 0

			Behavior on opacity {
				Anim {}
			}

			Rectangle {
				height: parent.height
				radius: 2
				width: parent.width * Math.min(1, root.progress)
				color: Theme.primary

				Behavior on width {
					SpatialAnim {}
				}
			}
		}
	}
}
