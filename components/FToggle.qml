import QtQuick

// Two knots on a short wire and a spark that slides between them. The wire
// between the knots is lit when the toggle is on.
Item {
	id: toggle

	property bool checked: false
	property bool enabled: true
	property string text: ""
	readonly property bool hovered: touch.containsMouse

	signal toggled(bool checked)

	implicitWidth: 34 + (text !== "" ? label.implicitWidth + 10 : 0)
	implicitHeight: 20
	opacity: enabled ? 1 : 0.45

	MouseArea {
		id: touch
		anchors.fill: parent
		anchors.margins: -4
		hoverEnabled: true
		enabled: toggle.enabled
		cursorShape: Qt.PointingHandCursor
		onClicked: { toggle.checked = !toggle.checked; toggle.toggled(toggle.checked); }
	}

	Item {
		id: track
		width: 34
		height: 20
		anchors.verticalCenter: parent.verticalCenter

		Wire {
			x: 4; width: 26
			anchors.verticalCenter: parent.verticalCenter
			height: 2
			lit: toggle.checked ? 1 : 0
			cold: Filament.wireDim
		}

		Repeater {
			model: 2
			Rectangle {
				required property int index
				x: index === 0 ? 2 : 28
				anchors.verticalCenter: parent.verticalCenter
				width: 4; height: 4; radius: 2
				color: (index === 1 && toggle.checked) || (index === 0 && !toggle.checked) ? Filament.wireBright : Filament.wire
			}
		}

		Rectangle {
			x: toggle.checked ? 20 : 0
			anchors.verticalCenter: parent.verticalCenter
			width: 10; height: 10; radius: 5
			color: toggle.checked ? Filament.charge : Filament.wireBright
			scale: toggle.hovered ? 1.25 : 1
			Behavior on x { SpringAnimation { spring: 4; damping: 0.32; epsilon: 0.01 } }
			Behavior on scale { NumberAnimation { duration: Filament.quick } }
			Behavior on color { ColorAnimation { duration: Filament.quick } }
			Rectangle {
				anchors.centerIn: parent
				width: 20; height: 20; radius: 10
				color: Qt.alpha(Filament.charge, 0.2)
				visible: toggle.checked
				z: -1
			}
		}
	}

	FText {
		id: label
		visible: toggle.text !== ""
		anchors.left: track.right
		anchors.leftMargin: 10
		anchors.verticalCenter: parent.verticalCenter
		text: toggle.text
		tone: toggle.checked ? "ink" : "soft"
		font.pixelSize: Filament.textSm
	}
}
