import QtQuick
import qs.style.theme
import qs.core.services
import qs.style.widgets

// A spool of the ACE seen from the side: the filament's colour as a ring
// around a hub, the slot's number in it. The spool that feeds turns.
Item {
	id: root

	required property var slot
	property bool chosen: false
	readonly property bool empty: root.slot.type === ""
	readonly property bool feeding: (Printer.ace?.loaded ?? -1) === root.slot.index && Printer.printing

	implicitWidth: 40
	implicitHeight: 40

	// the ring of a chosen spool
	Rectangle {
		anchors.centerIn: parent
		width: parent.width + 8
		height: width
		radius: width / 2
		color: "transparent"
		border.width: 2
		border.color: Theme.primary
		opacity: root.chosen ? 1 : 0
		scale: root.chosen ? 1 : 0.8

		Behavior on opacity {
			Anim {}
		}
		Behavior on scale {
			SpatialAnim {}
		}
	}

	Item {
		id: body

		anchors.fill: parent

		RotationAnimation on rotation {
			running: root.feeding && root.visible
			from: 0
			to: 360
			duration: 4000
			loops: Animation.Infinite
		}

		Rectangle {
			anchors.fill: parent
			radius: width / 2
			color: root.empty ? "transparent" : Printer.rgb(root.slot.color)
			border.width: root.empty ? 1.5 : 1
			border.color: root.empty ? Theme.textFaint : Qt.alpha(Theme.fg, 0.18)
		}

		// the windings
		Repeater {
			model: root.empty ? 0 : 3

			delegate: Rectangle {
				required property int index

				anchors.centerIn: parent
				width: body.width * (0.84 - index * 0.14)
				height: width
				radius: width / 2
				color: "transparent"
				border.width: 1
				border.color: Qt.rgba(0, 0, 0, 0.12)
			}
		}

		// the hub, with a notch to see it turn
		Rectangle {
			anchors.centerIn: parent
			width: body.width * 0.42
			height: width
			radius: width / 2
			color: Theme.bg
			border.width: 1
			border.color: Theme.outline

			Rectangle {
				anchors.horizontalCenter: parent.horizontalCenter
				y: 2
				width: 3
				height: 4
				radius: 1.5
				color: Theme.textFaint
				visible: root.feeding
			}
		}
	}

	StyledText {
		anchors.centerIn: parent
		text: root.slot.slot + 1
		font.pixelSize: Math.max(9, root.width * 0.24)
		font.weight: Font.Bold
		tone: root.empty ? Theme.textFaint : Theme.text
		surface: Theme.bg
	}
}
