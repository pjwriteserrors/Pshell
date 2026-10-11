import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A drive, a phone or a share: how full it is, mounted by a click,
// ejected by its button.
Item {
	id: root

	property var place: ({})

	signal activated

	readonly property real used: root.place.total > 0 ? 1 - root.place.free / root.place.total : 0
	readonly property string glyph: {
		switch (root.place.kind) {
		case "system": return "harddisk";
		case "removable": return "usb_flash_drive_outline";
		case "phone": return "cellphone";
		case "network": return "server_network";
		default: return "harddisk";
		}
	}

	height: 76

	Rectangle {
		anchors.fill: parent
		radius: Theme.radius.huge
		color: mouse.containsMouse ? Theme.layer2 : Theme.layer1

		Behavior on color {
			ColorAnim {}
		}
	}

	Rectangle {
		id: badge

		x: 14
		anchors.verticalCenter: parent.verticalCenter
		width: 44
		height: 44
		radius: 14
		color: Qt.tint(Theme.layer2, Qt.alpha(Theme.primary, 0.18))

		Glyph {
			anchors.centerIn: parent
			icon: root.glyph
			size: 22
			color: Theme.primary
			animated: false
		}
	}

	Column {
		anchors.left: badge.right
		anchors.leftMargin: 12
		anchors.right: eject.visible ? eject.left : parent.right
		anchors.rightMargin: 12
		anchors.verticalCenter: parent.verticalCenter
		spacing: 6

		Text {
			width: parent.width
			text: String(root.place.name || "")
			color: Theme.text
			font.family: Theme.fontFamily
			font.pixelSize: Theme.size.body
			font.weight: Font.DemiBold
			elide: Text.ElideRight
		}

		Rectangle {
			visible: root.place.total > 0
			width: parent.width
			height: 5
			radius: 3
			color: Theme.layer3

			Rectangle {
				width: parent.width * root.used
				height: parent.height
				radius: 3
				color: root.used > 0.9 ? Theme.danger : (root.used > 0.75 ? Theme.warning : Theme.primary)

				Behavior on width {
					SpatialAnim {}
				}
			}
		}

		Text {
			text: root.place.mounted ? (root.place.total > 0 ? `${Files.sizeText(root.place.free)} free of ${Files.sizeText(root.place.total)}` : "Connected") : "Not mounted – click to mount"
			color: Theme.textSubtle
			font.family: Theme.fontFamily
			font.pixelSize: Theme.size.small
		}
	}

	MouseArea {
		id: mouse

		anchors.fill: parent
		hoverEnabled: true
		cursorShape: Qt.PointingHandCursor
		onClicked: root.activated()
	}

	IconButton {
		id: eject

		visible: !!root.place.canEject || !!root.place.canUnmount
		anchors.right: parent.right
		anchors.rightMargin: 12
		anchors.verticalCenter: parent.verticalCenter
		width: 32
		height: 32
		iconSize: 17
		icon: "eject"
		onClicked: Files.unmount(root.place, !!root.place.canEject)
	}
}
