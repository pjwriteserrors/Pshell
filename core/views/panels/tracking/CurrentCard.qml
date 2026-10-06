import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The timer that is running or paused, with its live clock. The dot breathes
// while it runs.
Rectangle {
	id: root

	radius: Theme.radius.large
	color: Tmpo.tracking ? Theme.primaryContainer : Theme.layer1
	clip: true

	Behavior on color {
		ColorAnim {
			duration: Motion.medium
		}
	}

	ColumnLayout {
		x: 18
		y: 16
		width: 244
		height: parent.height - 32
		spacing: 4

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			Rectangle {
				id: dot

				implicitWidth: 8
				implicitHeight: 8
				radius: 4
				color: Tmpo.tracking ? Theme.primary : Theme.textSubtle

				SequentialAnimation {
					running: Tmpo.tracking && root.visible
					loops: Animation.Infinite
					onStopped: {
						dot.opacity = 1;
						dot.scale = 1;
					}

					ParallelAnimation {
						Anim { target: dot; property: "opacity"; to: 0.35; duration: 900 }
						Anim { target: dot; property: "scale"; to: 0.7; duration: 900 }
					}
					ParallelAnimation {
						Anim { target: dot; property: "opacity"; to: 1; duration: 900 }
						Anim { target: dot; property: "scale"; to: 1; duration: 900 }
					}
				}
			}

			SectionLabel {
				Layout.fillWidth: true
				text: Tmpo.tracking ? `Running since ${Tmpo.started || "--"}` : "Paused"
			}
		}

		StyledText {
			Layout.fillWidth: true
			Layout.topMargin: 4
			text: Tmpo.description || Tmpo.project
			font.pixelSize: Theme.size.title
			font.weight: Font.Bold
		}

		StyledText {
			Layout.fillWidth: true
			text: Tmpo.project || "No project"
			tone: Theme.textMuted
			font.pixelSize: Theme.size.small
		}

		Item {
			Layout.fillHeight: true
		}

		StyledText {
			text: Tmpo.duration || "--"
			tabular: true
			font.family: Theme.monoFamily
			font.pixelSize: 28
			font.weight: Font.Bold
		}
	}
}
