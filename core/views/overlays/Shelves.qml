pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import qs.style.theme
import qs.core.services
import qs.style.widgets
import qs.core.views.overlays.shelf

// The shelves of one screen (see Shelf). A transparent layer above the
// windows that only takes input where a shelf or a preview is, so moving a
// shelf works in stable screen coordinates; letting go with its middle over
// another screen moves it there. While a menu is open the whole layer takes
// input, so a click next to it closes it. Shelves of a screen that is gone
// show on the primary one.
PanelWindow {
	id: root

	required property var modelData
	readonly property string name: String(root.modelData.name)
	readonly property bool primary: root.modelData === Popups.primaryScreen
	readonly property var own: Shelf.shelves.filter(shelf => shelf.output === root.name
		|| (root.primary && !Quickshell.screens.some(screen => String(screen.name) === shelf.output)))

	property var menuEntries: []
	property point menuAt
	property var previewItem: null
	readonly property bool menuOpen: root.menuEntries.length > 0

	screen: root.modelData
	visible: shelfModel.count > 0
	color: "transparent"
	anchors {
		top: true
		bottom: true
		left: true
		right: true
	}
	exclusiveZone: 0
	WlrLayershell.namespace: "shell-shelf"
	WlrLayershell.layer: WlrLayer.Top
	WlrLayershell.exclusionMode: ExclusionMode.Ignore
	WlrLayershell.keyboardFocus: root.visible ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

	mask: Region {
		regions: {
			if (root.menuOpen || root.previewItem) return [everything];
			const out = [];
			for (let i = 0; i < cards.count; i += 1) {
				const card = cards.itemAt(i);
				if (!card || card.appear < 0.01) continue;
				out.push(card.boxRegion, card.tabRegion);
			}
			return out;
		}
	}

	Region {
		id: everything

		item: catcher
	}

	// shelves come and go without rebuilding the others (their animations
	// and drags would be cut off), so the ids are mirrored into a model
	ListModel {
		id: shelfModel
	}

	function sync() {
		const ids = root.own.map(shelf => shelf.id);
		for (let i = shelfModel.count - 1; i >= 0; i -= 1)
			if (!ids.includes(shelfModel.get(i).shelfId)) shelfModel.remove(i);
		for (const id of ids) {
			let known = false;
			for (let i = 0; i < shelfModel.count; i += 1)
				if (shelfModel.get(i).shelfId === id) known = true;
			if (!known) shelfModel.append({ shelfId: id });
		}
	}

	onOwnChanged: root.sync()
	Component.onCompleted: root.sync()

	function screenAt(gx, gy) {
		for (const screen of Quickshell.screens)
			if (gx >= screen.x && gx < screen.x + screen.width && gy >= screen.y && gy < screen.y + screen.height)
				return screen;
		return null;
	}

	function place(shelfId, width, height, x, y) {
		const gx = root.modelData.x + x + width / 2;
		const gy = root.modelData.y + y + height / 2;
		const target = root.screenAt(gx, gy);
		if (target && target !== root.modelData) {
			Shelf.update(shelfId, { output: String(target.name), x: Math.round(root.modelData.x + x - target.x), y: Math.round(root.modelData.y + y - target.y) });
			return;
		}
		Shelf.update(shelfId, {
			output: root.name,
			x: Math.round(Math.max(0, Math.min(root.width - width, x))),
			y: Math.round(Math.max(0, Math.min(root.height - 60, y)))
		});
	}

	Repeater {
		id: cards

		model: shelfModel

		delegate: ShelfCard {
			id: card

			readonly property Region boxRegion: Region {
				item: card.boxArea
			}
			readonly property Region tabRegion: Region {
				item: card.tabArea
			}

			onMoved: (x, y) => root.place(card.shelfId, card.cardWidth, card.boxArea.height, x, y)
			onMenuRequested: (entries, x, y) => {
				root.menuEntries = entries;
				root.menuAt = Qt.point(Math.max(8, Math.min(root.width - menu.implicitWidth - 8, x)), Math.max(8, Math.min(root.height - menu.implicitHeight - 8, y)));
				menuKeys.forceActiveFocus();
			}
			onPreviewRequested: item => root.previewItem = item
		}
	}

	// a click anywhere next to an open menu or preview closes it, also one on
	// the shelf (and the ⋯ that opened it), so it lies above the shelves
	MouseArea {
		id: catcher

		anchors.fill: parent
		enabled: root.menuOpen || !!root.previewItem
		acceptedButtons: Qt.AllButtons
		onPressed: {
			root.menuEntries = [];
			root.previewItem = null;
		}
	}

	// ── menu ─────────────────────────────────────────────────────────────
	ShelfMenu {
		id: menu

		x: root.menuAt.x
		y: root.menuAt.y
		visible: root.menuOpen
		entries: root.menuEntries
		onDone: root.menuEntries = []
	}

	Item {
		id: menuKeys

		Keys.onEscapePressed: root.menuEntries = []
	}

	// ── preview (space) ──────────────────────────────────────────────────
	Rectangle {
		id: preview

		readonly property bool image: !!root.previewItem && Shelf.isImage(root.previewItem)

		anchors.centerIn: parent
		width: Math.min(root.width * 0.7, preview.image ? Math.max(200, previewImage.paintedWidth + 24) : 640)
		height: Math.min(root.height * 0.75, preview.image ? Math.max(120, previewImage.paintedHeight + 24) : previewText.implicitHeight + 48)
		visible: !!root.previewItem
		radius: Theme.radius.huge
		color: Theme.base
		border.width: 1
		border.color: Theme.outline

		onVisibleChanged: if (visible) previewKeys.forceActiveFocus()

		layer.enabled: true
		layer.effect: MultiEffect {
			shadowEnabled: true
			shadowColor: Theme.shadow
			shadowBlur: 1
			shadowVerticalOffset: 8
		}

		MouseArea {
			anchors.fill: parent
			onClicked: root.previewItem = null
		}

		Image {
			id: previewImage

			anchors.centerIn: parent
			width: root.width * 0.7 - 24
			height: root.height * 0.75 - 24
			visible: preview.image
			source: preview.image ? Shelf.fileUri(root.previewItem.path) : ""
			fillMode: Image.PreserveAspectFit
			asynchronous: true
			sourceSize: Qt.size(root.width, root.height)
		}

		Flickable {
			anchors.fill: parent
			anchors.margins: 24
			visible: !preview.image
			contentHeight: previewText.implicitHeight
			clip: true

			StyledText {
				id: previewText

				width: parent.width
				text: root.previewItem?.kind === "text" ? root.previewItem.text : ""
				wrapMode: Text.Wrap
				font.pixelSize: Theme.size.body
				font.family: Theme.monoFamily
			}
		}

		Item {
			id: previewKeys

			Keys.onPressed: event => {
				if (event.key === Qt.Key_Space || event.key === Qt.Key_Escape) {
					root.previewItem = null;
					event.accepted = true;
				}
			}
		}
	}
}
