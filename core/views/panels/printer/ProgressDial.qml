import QtQuick
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The print's progress as a dial: ticks around it light up as it goes, an
// arc of the nozzle's heat with a glowing head that breathes while the
// printer works, the percent counting up in the middle.
Item {
	id: root

	property real value: 0
	property bool running: true
	property color color: Printer.hot
	property string caption: ""
	readonly property real sweep: 300
	readonly property real start: 90 + (360 - root.sweep) / 2
	property real shown: Math.max(0, Math.min(1, root.value))

	Behavior on shown {
		NumberAnimation {
			duration: 900
			easing.type: Easing.OutCubic
		}
	}

	implicitWidth: 180
	implicitHeight: 180

	// the ticks, lit up to where the print is
	Repeater {
		model: 41

		delegate: Item {
			id: tick

			required property int index
			readonly property real at: tick.index / 40
			readonly property bool passed: tick.at <= root.shown

			anchors.fill: parent
			rotation: root.start + root.sweep * tick.at + 90

			Rectangle {
				anchors.horizontalCenter: parent.horizontalCenter
				y: 0
				width: tick.index % 5 === 0 ? 3 : 2
				height: tick.index % 5 === 0 ? 9 : 5
				radius: 1
				color: tick.passed ? root.color : Qt.alpha(Theme.fg, 0.14)
				opacity: tick.passed ? 1 : 0.8

				Behavior on color {
					ColorAnim {
						duration: Motion.long
					}
				}
			}
		}
	}

	// a soft glow under the arc
	Ring {
		anchors.fill: parent
		anchors.margins: 12
		value: root.shown
		animated: false
		sweep: root.sweep
		thickness: 18
		color: Qt.alpha(root.color, 0.16)
		trackColor: "transparent"
	}

	Ring {
		id: arc

		anchors.fill: parent
		anchors.margins: 16
		value: root.shown
		animated: false
		sweep: root.sweep
		thickness: 10
		color: root.color
		trackColor: Qt.alpha(Theme.fg, 0.07)
	}

	// the arc's head
	Item {
		anchors.fill: arc
		rotation: root.start + root.sweep * root.shown + 90
		visible: root.shown > 0.005

		Rectangle {
			id: head

			anchors.horizontalCenter: parent.horizontalCenter
			y: -3
			width: 16
			height: 16
			radius: 8
			color: Qt.lighter(root.color, 1.3)
			border.width: 3
			border.color: Theme.bg

			Rectangle {
				anchors.centerIn: parent
				width: 34
				height: 34
				radius: 17
				z: -1
				color: Qt.alpha(root.color, 0.35)
				scale: 0.6

				SequentialAnimation on scale {
					running: root.running && root.visible
					loops: Animation.Infinite
					NumberAnimation { to: 1.2; duration: 900; easing.type: Easing.OutQuad }
					NumberAnimation { to: 0.6; duration: 900; easing.type: Easing.InQuad }
				}
				SequentialAnimation on opacity {
					running: root.running && root.visible
					loops: Animation.Infinite
					NumberAnimation { to: 0.2; duration: 900 }
					NumberAnimation { to: 1; duration: 900 }
				}
			}
		}
	}

	Column {
		anchors.centerIn: parent
		anchors.verticalCenterOffset: 4
		spacing: -4

		Row {
			anchors.horizontalCenter: parent.horizontalCenter
			spacing: 2

			StyledText {
				text: Math.floor(root.shown * 100)
				font.pixelSize: root.width * 0.24
				font.weight: Font.Bold
				tabular: true
			}

			StyledText {
				y: root.width * 0.05
				text: "%"
				font.pixelSize: root.width * 0.09
				font.weight: Font.DemiBold
				tone: Theme.textMuted
			}
		}

		StyledText {
			anchors.horizontalCenter: parent.horizontalCenter
			text: root.caption
			font.pixelSize: Theme.size.small
			tone: Theme.textMuted
			tabular: true
		}
	}
}
