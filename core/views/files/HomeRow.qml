import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "FileKinds.js" as Kinds

// A file of the home page's lists: small picture, name, where and when.
Item {
	id: root

	property var entry: ({})

	signal activated
	signal reveal
	signal menu(Item item, real x, real y)

	height: 48

	Rectangle {
		anchors.fill: parent
		radius: Theme.radius.medium
		color: Qt.alpha(Theme.layer1, mouse.containsMouse ? 1 : 0)

		Behavior on color {
			ColorAnim {}
		}
	}

	FileThumb {
		id: picture

		x: 8
		anchors.verticalCenter: parent.verticalCenter
		width: 34
		height: 34
		compact: true
		radius: 8
		path: String(root.entry.path || "")
		name: String(root.entry.name || "")
		mime: String(root.entry.mime || "")
		dir: !!root.entry.dir
		kind: Kinds.kindOf(root.entry)
		thumb: String(root.entry.thumb || "")
		canThumb: !!root.entry.canThumb
	}

	Column {
		anchors.left: picture.right
		anchors.leftMargin: 12
		anchors.right: parent.right
		anchors.rightMargin: 10
		anchors.verticalCenter: parent.verticalCenter
		spacing: 1

		Text {
			width: parent.width
			text: String(root.entry.name || "")
			color: Theme.text
			font.family: Theme.fontFamily
			font.pixelSize: Theme.size.body
			elide: Text.ElideMiddle
		}

		Text {
			width: parent.width
			text: `${Files.pretty(Files.parentOf(String(root.entry.path || "")))} · ${Files.whenText(root.entry.mtime)}`
			color: Theme.textSubtle
			font.family: Theme.fontFamily
			font.pixelSize: Theme.size.small
			elide: Text.ElideLeft
		}
	}

	MouseArea {
		id: mouse

		anchors.fill: parent
		hoverEnabled: true
		acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
		cursorShape: Qt.PointingHandCursor
		onClicked: mouse => {
			if (mouse.button === Qt.RightButton) root.menu(root, mouse.x, mouse.y);
			else if (mouse.button === Qt.MiddleButton) root.reveal();
			else root.activated();
		}
	}
}
