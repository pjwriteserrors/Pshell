pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// One entry of a shelf, as a row (list) or a tile with a large preview and
// the title below (grid). The whole entry drags out (together with the
// selection it belongs to); the button copies the path.
Item {
	id: root

	required property var item
	property bool grid: false
	property bool selected: false
	property bool renaming: false
	// what a drag from this entry carries
	property var dragItems: [root.item]

	signal select(bool add)
	signal menuRequested(real x, real y)
	signal renamed(string name)

	readonly property bool hovered: pointer.containsMouse || copy.hovered

	Rectangle {
		anchors.fill: parent
		radius: Theme.radius.large
		color: root.selected ? Theme.primarySoft : (root.hovered ? Theme.layer1 : "transparent")

		Behavior on color {
			ColorAnim {}
		}
	}

	// ── preview ───────────────────────────────────────────────────────────
	Rectangle {
		id: preview

		x: root.grid ? 6 : 6
		y: root.grid ? 6 : (root.height - height) / 2
		width: root.grid ? root.width - 12 : 40
		height: root.grid ? Math.min(root.width - 12, 200) : 40
		radius: root.grid ? Theme.radius.medium : Theme.radius.small
		color: Theme.layer2
		clip: true
		scale: pointer.dragging ? 0.92 : 1

		Behavior on scale {
			SpatialAnim {
				duration: Motion.short
			}
		}

		ShelfPreview {
			anchors.fill: parent
			item: root.item
			mode: root.grid ? "tile" : "row"
		}

		// how many go along
		Rectangle {
			anchors.right: parent.right
			anchors.bottom: parent.bottom
			anchors.margins: 3
			visible: root.dragItems.length > 1
			width: Math.max(18, count.implicitWidth + 8)
			height: 18
			radius: 9
			color: Theme.primary

			StyledText {
				id: count

				anchors.centerIn: parent
				text: root.dragItems.length
				tone: Theme.onPrimary
				font.pixelSize: Theme.size.tiny
				font.weight: Font.Bold
			}
		}
	}

	// ── title ─────────────────────────────────────────────────────────────
	ColumnLayout {
		x: root.grid ? 8 : preview.x + preview.width + 10
		y: root.grid ? preview.y + preview.height + 6 : (root.height - height) / 2
		width: root.grid ? root.width - 16 : root.width - x - 44
		spacing: 1

		StyledText {
			Layout.fillWidth: true
			visible: !root.renaming
			text: root.item.name || root.item.path
			elide: root.grid ? Text.ElideRight : Text.ElideMiddle
			horizontalAlignment: root.grid ? Text.AlignHCenter : Text.AlignLeft
			wrapMode: root.grid ? Text.Wrap : Text.NoWrap
			maximumLineCount: root.grid ? 2 : 1
			font.pixelSize: root.grid ? Theme.size.label : Theme.size.body
			font.weight: Font.Medium
		}

		Field {
			id: nameField

			Layout.fillWidth: true
			Layout.preferredHeight: 30
			visible: root.renaming
			clearable: false
			fontSize: Theme.size.label
			onAccepted: root.renamed(nameField.text)
			onEscapePressed: root.renamed("")
		}

		StyledText {
			Layout.fillWidth: true
			visible: !root.grid
			text: Shelf.detailOf(root.item)
			tone: Theme.textSubtle
			elide: Text.ElideRight
			font.pixelSize: Theme.size.small
			maximumLineCount: 1
		}
	}

	ShelfDrag {
		id: pointer

		anchors.fill: parent
		items: root.dragItems
		preview: preview
		onSelected: add => root.select(add)
		onMenuRequested: (x, y) => root.menuRequested(x, y)
		onOpened: Shelf.open(root.item)
	}

	IconButton {
		id: copy

		x: root.grid ? root.width - width - 10 : root.width - width - 6
		y: root.grid ? 10 : (root.height - height) / 2
		width: root.grid ? 28 : 32
		height: width
		visible: !root.renaming
		icon: "content_copy"
		iconSize: 15
		variant: root.grid ? "tonal" : "ghost"
		opacity: root.grid ? (root.hovered ? 1 : 0) : 1
		onClicked: Shelf.copyPath(root.item)

		Behavior on opacity {
			Anim {
				duration: Motion.short
			}
		}
	}

	onRenamingChanged: {
		if (!root.renaming) return;
		nameField.text = root.item.name;
		nameField.input.forceActiveFocus();
		nameField.input.selectAll();
	}
}
