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
	visible: shelfModel.count > 0 || Shelf.locating !== ""
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
			if (root.menuOpen || root.previewItem || Shelf.locating !== "") return [everything];
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

	// a shelf that just opened goes next to the pointer: centred below it, so
	// what is being dragged only has to move down a little
	function locate(x, y) {
		const id = Shelf.locating;
		if (id === "") return;
		Shelf.locating = "";
		Shelf.update(id, {
			output: root.name,
			x: Math.round(Math.max(8, Math.min(root.width - 348, x - 170))),
			y: Math.round(Math.max(8, Math.min(root.height - 360, y + 18)))
		});
	}

	// the whole layer takes input for a moment to learn where the pointer is,
	// with or without something being dragged
	MouseArea {
		anchors.fill: parent
		visible: Shelf.locating !== ""
		hoverEnabled: true
		acceptedButtons: Qt.NoButton
		onEntered: root.locate(mouseX, mouseY)
		onPositionChanged: mouse => root.locate(mouse.x, mouse.y)
	}

	DropArea {
		anchors.fill: parent
		visible: Shelf.locating !== ""
		onEntered: drag => root.locate(drag.x, drag.y)
		onPositionChanged: drag => root.locate(drag.x, drag.y)
	}

	Repeater {
		id: cards

		model: shelfModel

		delegate: ShelfCard {
			id: card

			// not shown at the fallback place while the pointer is looked for
			opacity: Shelf.locating === card.shelfId ? 0 : 1

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

		anchors.centerIn: parent
		width: Math.min(root.width * 0.7, previewContent.preferredWidth + 24)
		height: Math.min(root.height * 0.75, previewContent.preferredHeight + 24)
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

		ShelfPreview {
			id: previewContent

			anchors.fill: parent
			anchors.margins: 12
			item: root.previewItem
			mode: "large"
			maxWidth: root.width * 0.7 - 24
			maxHeight: root.height * 0.75 - 24
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
