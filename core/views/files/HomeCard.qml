import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "FileKinds.js" as Kinds

// A file on the home page: its picture and name, opened by a click,
// carried away by a drag, offered for more by a right click.
Item {
	id: root

	property var entry: ({})
	// screenshots and videos are wider than they are tall
	property bool wide: false
	// only the picture (the mosaic of pictures)
	property bool bare: false
	property real when: Number(root.entry.mtime) || 0

	signal activated
	signal reveal
	signal menu(Item item, real x, real y)

	readonly property bool hovered: mouse.containsMouse
	readonly property real art: root.bare ? root.width : (root.wide ? root.width * 0.62 : root.width * 0.8)

	width: root.bare ? 120 : (root.wide ? 232 : 164)
	height: root.bare ? root.width * 0.8 : root.art + 54

	Rectangle {
		anchors.fill: parent
		anchors.margins: root.bare ? 0 : -6
		radius: Theme.radius.large
		color: Qt.alpha(Theme.layer1, root.hovered && !root.bare ? 1 : 0)

		Behavior on color {
			ColorAnim {}
		}
	}

	FileThumb {
		id: picture

		width: root.width
		height: root.bare ? root.height : root.art
		radius: Theme.radius.large
		path: String(root.entry.path || "")
		name: String(root.entry.name || "")
		mime: String(root.entry.mime || "")
		dir: !!root.entry.dir
		kind: Kinds.kindOf(root.entry)
		thumb: String(root.entry.thumb || "")
		canThumb: !!root.entry.canThumb
		isText: !!root.entry.text
		hovered: root.hovered
	}

	// "show in folder" on the corner while pointed at
	IconButton {
		anchors.right: picture.right
		anchors.top: picture.top
		anchors.margins: 6
		width: 28
		height: 28
		iconSize: 15
		variant: "tonal"
		icon: "folder_search_outline"
		opacity: root.hovered ? 1 : 0
		scale: root.hovered ? 1 : 0.7
		visible: opacity > 0
		onClicked: root.reveal()

		Behavior on opacity {
			Anim {}
		}
		Behavior on scale {
			SpatialAnim {
				duration: Motion.medium
			}
		}
	}

	Text {
		id: label

		visible: !root.bare
		anchors.top: picture.bottom
		anchors.topMargin: 8
		width: root.width
		text: String(root.entry.name || "")
		color: Theme.text
		font.family: Theme.fontFamily
		font.pixelSize: Theme.size.label
		font.weight: Font.Medium
		elide: Text.ElideMiddle
	}

	Text {
		visible: !root.bare
		anchors.top: label.bottom
		anchors.topMargin: 2
		width: root.width
		text: [Files.whenText(root.when), root.entry.dir ? "" : Format.bytes(root.entry.size)].filter(part => part !== "").join(" · ")
		color: Theme.textSubtle
		font.family: Theme.fontFamily
		font.pixelSize: Theme.size.small
		elide: Text.ElideRight
	}

	MouseArea {
		id: mouse

		anchors.fill: parent
		hoverEnabled: true
		acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
		cursorShape: Qt.PointingHandCursor
		drag.target: ghost
		drag.threshold: 8
		preventStealing: true
		onPressed: mouse => {
			ghost.x = mouse.x;
			ghost.y = mouse.y;
			if (mouse.button === Qt.LeftButton) picture.grabToImage(result => ghost.Drag.imageSource = result.url, Qt.size(72, 72 * picture.height / Math.max(1, picture.width)));
		}
		onClicked: mouse => {
			if (mouse.button === Qt.RightButton) root.menu(root, mouse.x, mouse.y);
			else if (mouse.button === Qt.MiddleButton) root.reveal();
			else root.activated();
		}
	}

	Item {
		id: ghost

		width: 1
		height: 1
		Drag.dragType: Drag.Automatic
		Drag.active: mouse.drag.active
		Drag.supportedActions: Qt.CopyAction | Qt.MoveAction | Qt.LinkAction
		Drag.proposedAction: Qt.CopyAction
		Drag.hotSpot: Qt.point(36, 36)
		Drag.mimeData: ({ "text/uri-list": Files.uri(String(root.entry.path || "")) + "\r\n", "text/plain": String(root.entry.path || "") })
	}
}
