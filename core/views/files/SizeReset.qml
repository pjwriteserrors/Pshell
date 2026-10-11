import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Back to the cards' first size: there only while they are another size,
// it pops up beside the slider and goes again once it was used.
Clickable {
	id: root

	readonly property bool away: Math.abs((FileLibrary.view.cardSize || 172) - 172) > 2

	implicitWidth: row.implicitWidth + 16
	implicitHeight: 22
	radius: 11
	color: Qt.alpha(Theme.layer2, root.hovered ? 1 : 0.7)
	enabled: root.away
	scale: root.away ? (root.pressed ? 0.94 : 1) : 0.6
	opacity: root.away ? 1 : 0
	visible: opacity > 0.01
	sound: "select"
	onClicked: FileLibrary.setView("", { cardSize: 172 })

	Behavior on scale {
		SpatialAnim {
			duration: Motion.medium
		}
	}
	Behavior on opacity {
		Anim {}
	}

	Row {
		id: row

		anchors.centerIn: parent
		spacing: 4

		Glyph {
			anchors.verticalCenter: parent.verticalCenter
			icon: "restore"
			size: 12
			color: Theme.textMuted
			animated: false
		}

		Text {
			anchors.verticalCenter: parent.verticalCenter
			text: "Default"
			color: Theme.textMuted
			font.family: Theme.fontFamily
			font.pixelSize: Theme.size.tiny
			font.weight: Font.DemiBold
		}
	}
}
