import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A folder as a tile of the home page: drawn as a folder with what is in
// it peeking out; files dropped on it go in.
Item {
	id: root

	property string path: ""
	property string name: ""

	signal activated
	signal menu(Item item, real x, real y)

	readonly property bool hovered: mouse.containsMouse

	height: 148

	Rectangle {
		anchors.fill: parent
		radius: Theme.radius.huge
		color: drop.containsDrag ? Theme.primarySoft : (root.hovered ? Theme.layer2 : Theme.layer1)
		border.width: drop.containsDrag ? 1.5 : 0
		border.color: Theme.primary
		scale: mouse.pressed ? 0.97 : (drop.containsDrag ? 1.03 : 1)

		Behavior on color {
			ColorAnim {}
		}
		Behavior on scale {
			SpatialAnim {
				duration: Motion.medium
			}
		}
	}

	FileThumb {
		x: 10
		y: 8
		width: 104
		height: 84
		path: root.path
		name: root.name
		dir: true
		kind: "folder"
		hovered: root.hovered
		dropTarget: drop.containsDrag
	}

	Text {
		id: title

		x: 16
		anchors.bottom: count.top
		anchors.bottomMargin: 1
		width: root.width - 32
		text: root.name
		color: Theme.text
		font.family: Theme.fontFamily
		font.pixelSize: Theme.size.body
		font.weight: Font.DemiBold
		elide: Text.ElideRight
	}

	Text {
		id: count

		x: 16
		anchors.bottom: parent.bottom
		anchors.bottomMargin: 12
		text: {
			Files.peekTick;
			const n = Files.peekOf(root.path)?.count;
			return n === undefined ? " " : (n < 0 ? "No access" : `${n} item${n === 1 ? "" : "s"}`);
		}
		color: Theme.textSubtle
		font.family: Theme.fontFamily
		font.pixelSize: Theme.size.small
	}

	MouseArea {
		id: mouse

		anchors.fill: parent
		hoverEnabled: true
		acceptedButtons: Qt.LeftButton | Qt.RightButton
		cursorShape: Qt.PointingHandCursor
		onClicked: mouse => {
			if (mouse.button === Qt.RightButton) root.menu(root, mouse.x, mouse.y);
			else {
				Sounds.play("click");
				root.activated();
			}
		}
	}

	DropArea {
		id: drop

		anchors.fill: parent
		onDropped: event => {
			event.acceptProposedAction();
			Files.dropInto(root.path, event, "auto");
		}
	}
}
