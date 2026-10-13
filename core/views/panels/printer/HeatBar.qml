import QtQuick
import qs.style.theme
import qs.core.services

// The print's progress: a bar running from the accent into the nozzle's
// heat, with a glint travelling along it while the printer works.
Item {
	id: root

	property real value: 0
	property bool running: true

	implicitHeight: 10

	Rectangle {
		anchors.fill: parent
		radius: height / 2
		color: Qt.alpha(Theme.fg, 0.08)
	}

	Rectangle {
		id: fill

		width: Math.max(root.height, root.width * Math.max(0, Math.min(1, root.value)))
		height: root.height
		radius: height / 2
		clip: true
		gradient: Gradient {
			orientation: Gradient.Horizontal
			GradientStop {
				position: 0
				color: Theme.primary
			}
			GradientStop {
				position: 1
				color: Printer.hot
			}
		}

		Behavior on width {
			NumberAnimation {
				duration: 900
				easing.type: Easing.OutCubic
			}
		}

		Rectangle {
			id: glint

			width: 60
			height: parent.height
			visible: root.running
			gradient: Gradient {
				orientation: Gradient.Horizontal
				GradientStop {
					position: 0
					color: "transparent"
				}
				GradientStop {
					position: 0.5
					color: Qt.rgba(1, 1, 1, 0.45)
				}
				GradientStop {
					position: 1
					color: "transparent"
				}
			}

			NumberAnimation on x {
				running: root.running && root.visible
				from: -60
				to: fill.width + 60
				duration: 1800
				loops: Animation.Infinite
				easing.type: Easing.InOutSine
			}
		}
	}

	// the head of the bar glows
	Rectangle {
		x: fill.width - width / 2 - root.height / 2
		anchors.verticalCenter: parent.verticalCenter
		width: root.height * 2.4
		height: width
		radius: width / 2
		color: Qt.alpha(Printer.hot, 0.35)
		visible: root.running && root.value > 0
		scale: 0.6

		SequentialAnimation on scale {
			running: root.running && root.visible
			loops: Animation.Infinite
			NumberAnimation {
				to: 1
				duration: 900
				easing.type: Easing.InOutSine
			}
			NumberAnimation {
				to: 0.6
				duration: 900
				easing.type: Easing.InOutSine
			}
		}
	}
}
