import QtQuick
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Live screen recording: only exists while wf-recorder runs. A red capsule
// with a pulsing dot and the elapsed time grows out of the centre cluster;
// clicking it stops the recording.
BarButton {
	id: root

	tooltip: "Stop recording"
	padding: 4
	visible: Plugins.on("recording") && width > 0.5
	implicitWidth: Recorder.active ? capsule.width + root.padding * 2 : 0
	clip: true
	onClicked: Recorder.stop()

	Behavior on implicitWidth {
		SpatialAnim {
			duration: Motion.medium
		}
	}

	Rectangle {
		id: capsule

		anchors.verticalCenter: parent.verticalCenter
		height: 26
		width: content.implicitWidth + 20
		radius: 13
		color: root.hovered ? Theme.danger : Theme.dangerContainer
		scale: Recorder.active ? 1 : 0.6
		opacity: Recorder.active ? 1 : 0

		Behavior on color {
			ColorAnim {}
		}
		Behavior on scale {
			SpatialAnim {
				duration: Motion.medium
			}
		}
		Behavior on opacity {
			Anim {}
		}

		Row {
			id: content

			anchors.centerIn: parent
			spacing: 7

			Item {
				anchors.verticalCenter: parent.verticalCenter
				width: 12
				height: 12

				Rectangle {
					anchors.centerIn: parent
					width: root.hovered ? 9 : 8
					height: width
					radius: root.hovered ? 2 : width / 2
					color: root.hovered ? Theme.bg : Theme.danger

					Behavior on radius {
						SpatialAnim {
							duration: Motion.short
						}
					}

					SequentialAnimation on opacity {
						running: Recorder.active && !root.hovered
						loops: Animation.Infinite
						onRunningChanged: if (!running) parent.opacity = 1
						NumberAnimation {
							to: 0.25
							duration: 700
							easing.type: Easing.InOutSine
						}
						NumberAnimation {
							to: 1
							duration: 700
							easing.type: Easing.InOutSine
						}
					}
				}
			}

			StyledText {
				anchors.verticalCenter: parent.verticalCenter
				text: Recorder.elapsed
				tabular: true
				font.pixelSize: Theme.size.body
				font.weight: Font.Bold
				tone: root.hovered ? Theme.bg : Theme.text
			}
		}
	}
}
