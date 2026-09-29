pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets

// One shelf, laid over the whole screen layer; `box` is the card and `tab`
// the docked form, both offered to the layer's input mask. The header moves
// the card (and onto another screen), the stack at its left drags
// everything out at once. While something is dragged over it, instant
// actions appear below: dropping there acts on the dragged things without
// keeping them. It pops in when it opens, slides into a tab at the screen
// edge when docked and back out when undocked. The tab moves up and down the
// edge; pulled away from it, the shelf opens where it is let go.
Item {
	id: root

	required property string shelfId
	readonly property var shelf: Shelf.shelfById(root.shelfId) ?? ({ id: root.shelfId, name: "", x: 0, y: 0, docked: false, grid: true, items: [] })
	readonly property var items: root.shelf.items ?? []
	property var selection: []
	property string renamingItem: ""
	property bool renamingShelf: false

	// while the header is dragged the card moves locally, the shelf takes the place on release
	property bool moving: false
	property real dragX: 0
	property real dragY: 0

	// the tab while it is dragged: along the edge, and how far it is pulled out
	property bool tabMoving: false
	property real tabDragY: 0
	property real tabPull: 0
	readonly property real pullToOpen: 70

	// 0 → 1 when it opens, back to 0 before it closes
	property real appear: 0
	property bool closing: false
	// 0 card … 1 tab
	property real dock: root.shelf.docked ? 1 : 0

	readonly property var selectedItems: root.items.filter(item => root.selection.includes(item.id))
	property int actionHover: 0
	readonly property bool dragOver: drop.containsDrag || tabDrop.containsDrag || root.actionHover > 0
	readonly property bool actionsShown: root.dock < 0.5 && (root.dragOver || linger.running)
	// cards unless the list was picked for this shelf
	readonly property bool grid: root.shelf.grid !== false
	readonly property real cardWidth: root.grid ? 340 : 310
	// the tiles always fill the width: one item is one large preview
	readonly property int columns: Math.max(1, Math.min(3, root.items.length))
	readonly property real cellWidth: (root.cardWidth - 16) / root.columns
	readonly property real cellHeight: Math.min(root.cellWidth - 8, 200) + 52

	readonly property Item boxArea: box
	readonly property Item tabArea: tab

	signal moved(real x, real y)
	signal menuRequested(var entries, real x, real y)
	signal previewRequested(var item)

	anchors.fill: parent

	Behavior on dock {
		NumberAnimation {
			duration: Motion.long
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.emphasized
		}
	}

	NumberAnimation {
		id: appearAnim

		target: root
		property: "appear"
		duration: root.closing ? Motion.medium : Motion.long
		easing.type: Easing.BezierSpline
		easing.bezierCurve: root.closing ? Motion.accel : Motion.spatial
		onFinished: if (root.closing) Shelf.close(root.shelfId)
	}

	Component.onCompleted: {
		root.syncItems();
		root.animateAppear(Shelf.hidden ? 0 : 1);
	}

	function animateAppear(to) {
		appearAnim.stop();
		appearAnim.to = to;
		appearAnim.start();
	}

	// Mod+A hides every shelf and brings them back
	Connections {
		target: Shelf
		function onHiddenChanged() {
			if (!root.closing) root.animateAppear(Shelf.hidden ? 0 : 1);
		}
	}

	function close() {
		if (root.closing) return;
		root.closing = true;
		root.animateAppear(0);
	}

	// how many of the action targets (and the gap above them) hold the drag
	function recountActions() {
		let count = gapDrop.containsDrag ? 1 : 0;
		for (let i = 0; i < actionTargets.count; i += 1)
			if (actionTargets.itemAt(i)?.containsDrag) count += 1;
		root.actionHover = count;
	}

	Timer {
		running: root.actionHover > 0
		repeat: true
		interval: 400
		onTriggered: root.recountActions()
	}

	// the drag left the card on the way to the actions: keep them a moment
	Timer {
		id: linger

		interval: 350
	}

	onDragOverChanged: if (!root.dragOver) linger.restart()

	// ── items as a model, so rows survive changes of the shelf ────────────
	ListModel {
		id: itemModel
	}

	function syncItems() {
		const ids = root.items.map(item => item.id);
		for (let i = itemModel.count - 1; i >= 0; i -= 1)
			if (!ids.includes(itemModel.get(i).itemId)) itemModel.remove(i);
		ids.forEach((id, index) => {
			let at = -1;
			for (let i = 0; i < itemModel.count; i += 1)
				if (itemModel.get(i).itemId === id) at = i;
			if (at < 0) itemModel.insert(Math.min(index, itemModel.count), { itemId: id });
			else if (at !== index) itemModel.move(at, index, 1);
		});
	}

	onItemsChanged: root.syncItems()

	function itemOf(id) {
		return root.items.find(item => item.id === id) ?? ({ id: id, kind: "text", text: "", name: "", path: "" });
	}

	// ── menus ─────────────────────────────────────────────────────────────
	function itemMenu(item) {
		const many = root.selection.includes(item.id) && root.selectedItems.length > 1;
		const targets = many ? root.selectedItems : [item];
		const entries = [];
		if (!many) {
			entries.push({ label: "Open", icon: "open_in_new", run: () => Shelf.open(item) });
			if (item.kind === "file") entries.push({ label: "Show in folder", icon: "folder_open", run: () => Shelf.showInFolder(item) });
			if (Shelf.isImage(item) || item.kind === "text") entries.push({ label: "Preview", icon: "eye", run: () => root.previewRequested(item) });
			entries.push({ separator: true });
		}
		entries.push({ label: many ? `Copy ${targets.length} files` : "Copy", icon: "content_copy", run: () => Shelf.copyItems(targets) });
		entries.push({ label: many ? "Copy paths" : "Copy path", icon: "clipboard_text", run: () => Shelf.copyPaths(targets) });
		if (!many && item.kind === "file") entries.push({ label: "Rename", icon: "pencil", run: () => root.renamingItem = item.id });
		if (KdeConnect.available) entries.push({ label: `Send to ${KdeConnect.name}`, icon: "cellphone_arrow_down", run: () => Shelf.sendToPhone(targets) });
		if (targets.some(t => t.kind === "file")) entries.push({ label: "Compress to ZIP", icon: "package_variant", run: () => Shelf.zip(root.shelfId, targets) });
		if (!many && Shelf.isImage(item)) {
			entries.push({ separator: true });
			entries.push({ label: "Extract text", icon: "text_recognition", run: () => Shelf.extractText(item) });
			entries.push({ label: "Half size", icon: "aspect_ratio", run: () => Shelf.convertImage(root.shelfId, item, "resize") });
			if (item.mime !== "image/png") entries.push({ label: "Convert to PNG", icon: "image", run: () => Shelf.convertImage(root.shelfId, item, "png") });
			if (item.mime !== "image/jpeg") entries.push({ label: "Convert to JPG", icon: "image", run: () => Shelf.convertImage(root.shelfId, item, "jpg") });
		}
		entries.push({ separator: true });
		entries.push({ label: "Remove from shelf", icon: "close", run: () => root.removeItems(targets) });
		if (targets.some(t => t.kind === "file")) entries.push({ label: "Move to trash", icon: "trash_can_outline", danger: true, run: () => Shelf.trash(root.shelfId, targets) });
		return entries;
	}

	function shelfMenu() {
		const entries = [];
		if (root.items.length > 0) {
			entries.push({ label: "Copy all", icon: "content_copy", run: () => Shelf.copyItems(root.items) });
			entries.push({ label: "Copy all paths", icon: "clipboard_text", run: () => Shelf.copyPaths(root.items) });
			if (root.items.some(t => t.kind === "file")) entries.push({ label: "Compress to ZIP", icon: "package_variant", run: () => Shelf.zip(root.shelfId, root.items) });
			if (KdeConnect.available) entries.push({ label: `Send all to ${KdeConnect.name}`, icon: "cellphone_arrow_down", run: () => Shelf.sendToPhone(root.items) });
			entries.push({ separator: true });
		}
		entries.push({ label: "Paste", icon: "content_paste", run: () => Shelf.pasteInto(root.shelfId) });
		entries.push({ label: "Rename", icon: "pencil", run: () => root.renamingShelf = true });
		if (root.items.length > 0) entries.push({ label: "Clear", icon: "broom", run: () => Shelf.clear(root.shelfId) });
		const recent = Shelf.recent.slice(0, 5);
		if (recent.length > 0) entries.push({ separator: true });
		for (const closed of recent)
			entries.push({ label: Shelf.titleOf(closed), icon: "history", run: () => Shelf.reopen(closed.id) });
		entries.push({ separator: true });
		entries.push({ label: "Shake to open", icon: "gesture_tap", checked: () => Shelf.shake, run: () => Shelf.setOption("shake", !Shelf.shake) });
		entries.push({ label: "Open for new downloads", icon: "tray_arrow_down", checked: () => Shelf.openOnNew, run: () => Shelf.setOption("openOnNew", !Shelf.openOnNew) });
		entries.push({ label: "Collect screenshot series", icon: "image_multiple", checked: () => Shelf.collectShots, run: () => Shelf.setOption("collectShots", !Shelf.collectShots) });
		return entries;
	}

	function removeItems(targets) {
		const ids = targets.map(t => t.id);
		Shelf.update(root.shelfId, { items: root.items.filter(item => !ids.includes(item.id)) });
		root.selection = root.selection.filter(id => !ids.includes(id));
	}

	function select(item, add) {
		if (add) root.selection = root.selection.includes(item.id) ? root.selection.filter(id => id !== item.id) : root.selection.concat([item.id]);
		else root.selection = [item.id];
		keys.forceActiveFocus();
	}

	function dragItemsFor(item) {
		return root.selection.includes(item.id) && root.selectedItems.length > 1 ? root.selectedItems : [item];
	}

	function openItemMenu(entry, item, mx, my) {
		if (!root.selection.includes(item.id)) root.selection = [item.id];
		const p = entry.mapToItem(root, mx, my);
		root.menuRequested(root.itemMenu(item), p.x, p.y);
	}

	function finishRename(item, name) {
		root.renamingItem = "";
		if (name !== "") Shelf.rename(root.shelfId, item, name);
	}

	onRenamingShelfChanged: {
		if (!root.renamingShelf) return;
		titleField.text = root.shelf.name;
		titleField.input.forceActiveFocus();
		titleField.input.selectAll();
	}

	// ── keyboard ──────────────────────────────────────────────────────────
	Item {
		id: keys

		focus: true
		Keys.onPressed: event => {
			const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
			const targets = root.selectedItems.length > 0 ? root.selectedItems : root.items;
			if (event.key === Qt.Key_Escape) {
				if (root.selection.length > 0) root.selection = [];
				else Shelf.update(root.shelfId, { docked: true });
			} else if (event.key === Qt.Key_Delete || event.key === Qt.Key_Backspace) {
				root.removeItems(root.selectedItems);
			} else if (ctrl && event.key === Qt.Key_A) {
				root.selection = root.items.map(item => item.id);
			} else if (ctrl && event.key === Qt.Key_C) {
				Shelf.copyItems(targets);
			} else if (ctrl && event.key === Qt.Key_V) {
				Shelf.pasteInto(root.shelfId);
			} else if (ctrl && event.key === Qt.Key_W) {
				root.close();
			} else if (event.key === Qt.Key_Space && root.selectedItems.length === 1) {
				root.previewRequested(root.selectedItems[0]);
			} else if (event.key === Qt.Key_Return && root.selectedItems.length === 1) {
				Shelf.open(root.selectedItems[0]);
			} else {
				return;
			}
			event.accepted = true;
		}
	}

	// ── the card ──────────────────────────────────────────────────────────
	Item {
		id: box

		readonly property real homeX: root.moving ? root.dragX : root.shelf.x

		// docking slides it past the screen edge, where the tab comes from
		x: box.homeX + root.dock * (root.width - box.homeX + 24)
		y: root.moving ? root.dragY : root.shelf.y
		width: root.cardWidth
		height: card.height + (root.actionsShown ? actions.height + 10 : 0)
		visible: root.dock < 1
		opacity: root.appear * (1 - root.dock)
		scale: (0.86 + 0.14 * root.appear) * (1 - 0.12 * root.dock)

		RectangularShadow {
			anchors.fill: card
			radius: card.radius
			blur: 28
			offset.y: 8
			color: Theme.shadow
		}

		Rectangle {
			id: card

			width: root.cardWidth
			height: header.height + body.height + 18
			radius: Theme.radius.huge
			color: Theme.base
			border.width: root.dragOver ? 2 : 1
			border.color: root.dragOver ? Theme.primary : Theme.outline

			Behavior on width {
				SpatialAnim {
					duration: Motion.medium
				}
			}

			Behavior on border.color {
				ColorAnim {}
			}

			DropArea {
				id: drop

				anchors.fill: parent
				onDropped: event => {
					Shelf.addDrop(root.shelfId, event);
					event.accept(Qt.CopyAction);
				}
			}

			// header: moves the shelf
			Item {
				id: header

				anchors.left: parent.left
				anchors.right: parent.right
				anchors.top: parent.top
				anchors.margins: 8
				height: 44

				MouseArea {
					id: mover

					property point grab

					anchors.fill: parent
					cursorShape: pressed ? Qt.ClosedHandCursor : Qt.ArrowCursor
					onPressed: event => {
						mover.grab = Qt.point(event.x, event.y);
						root.dragX = root.shelf.x;
						root.dragY = root.shelf.y;
						root.moving = true;
						keys.forceActiveFocus();
					}
					onPositionChanged: event => {
						if (!pressed) return;
						root.dragX += event.x - mover.grab.x;
						root.dragY += event.y - mover.grab.y;
					}
					onReleased: {
						root.moving = false;
						root.moved(root.dragX, root.dragY);
					}
					onDoubleClicked: root.renamingShelf = true
				}

				RowLayout {
					anchors.fill: parent
					spacing: 6

					// the stack: drags everything
					Item {
						Layout.preferredWidth: 40
						Layout.preferredHeight: 40
						visible: root.items.length > 0

						Repeater {
							model: root.items.slice(-3)

							delegate: Rectangle {
								id: sheet

								required property var modelData
								required property int index
								readonly property int count: Math.min(3, root.items.length)

								anchors.centerIn: parent
								width: 30
								height: 30
								radius: Theme.radius.small
								color: Theme.layer3
								border.width: 1
								border.color: Theme.base
								rotation: (sheet.index - (sheet.count - 1)) * 8 * (stackDrag.containsMouse ? 1.6 : 1)
								clip: true

								Behavior on rotation {
									SpatialAnim {
										duration: Motion.medium
									}
								}

								Image {
									anchors.fill: parent
									visible: Shelf.isImage(sheet.modelData)
									source: visible ? Shelf.fileUri(sheet.modelData.path) : ""
									sourceSize: Qt.size(60, 60)
									fillMode: Image.PreserveAspectCrop
									asynchronous: true
								}

								Glyph {
									anchors.centerIn: parent
									visible: !Shelf.isImage(sheet.modelData)
									icon: Shelf.iconFor(sheet.modelData)
									size: 15
									color: Theme.primary
								}
							}
						}

						ShelfDrag {
							id: stackDrag

							anchors.fill: parent
							items: root.items
							preview: parent
						}
					}

					ColumnLayout {
						Layout.fillWidth: true
						Layout.leftMargin: root.items.length > 0 ? 2 : 8
						spacing: 0

						StyledText {
							Layout.fillWidth: true
							visible: !root.renamingShelf
							text: Shelf.titleOf(root.shelf)
							elide: Text.ElideRight
							font.pixelSize: Theme.size.title
							font.weight: Font.DemiBold
						}

						Field {
							id: titleField

							Layout.fillWidth: true
							Layout.preferredHeight: 30
							visible: root.renamingShelf
							clearable: false
							placeholder: "Shelf"
							fontSize: Theme.size.body
							onAccepted: {
								Shelf.update(root.shelfId, { name: titleField.text.trim() });
								root.renamingShelf = false;
							}
							onEscapePressed: root.renamingShelf = false
						}

						StyledText {
							visible: root.shelf.name !== "" && root.items.length > 0 && !root.renamingShelf
							text: root.items.length === 1 ? "1 item" : `${root.items.length} items`
							tone: Theme.textSubtle
							font.pixelSize: Theme.size.small
						}
					}

					IconButton {
						Layout.preferredWidth: 30
						Layout.preferredHeight: 30
						icon: root.grid ? "format_list_bulleted" : "view_grid_outline"
						iconSize: 16
						visible: root.items.length > 0
						onClicked: Shelf.update(root.shelfId, { grid: !root.grid })
					}

					IconButton {
						id: menuButton

						Layout.preferredWidth: 30
						Layout.preferredHeight: 30
						icon: "dots_horizontal"
						iconSize: 16
						onClicked: {
							const p = menuButton.mapToItem(root, menuButton.width, menuButton.height + 4);
							root.menuRequested(root.shelfMenu(), p.x - 230, p.y);
						}
					}

					IconButton {
						Layout.preferredWidth: 30
						Layout.preferredHeight: 30
						icon: "chevron_right"
						iconSize: 16
						onClicked: Shelf.update(root.shelfId, { docked: true })
					}

					IconButton {
						Layout.preferredWidth: 30
						Layout.preferredHeight: 30
						icon: "close"
						iconSize: 16
						onClicked: root.close()
					}
				}
			}

			Item {
				id: body

				anchors.left: parent.left
				anchors.right: parent.right
				anchors.top: header.bottom
				anchors.margins: 8
				anchors.topMargin: 4
				height: root.items.length === 0 ? 120 : Math.min(root.grid ? grid.contentHeight : list.contentHeight, root.grid ? Math.max(2.4 * root.cellHeight, 320) : 6 * 56)

				Behavior on height {
					SpatialAnim {
						duration: Motion.medium
					}
				}

				// empty: a place to drop
				Rectangle {
					anchors.fill: parent
					visible: root.items.length === 0
					radius: Theme.radius.large
					color: root.dragOver ? Theme.primarySoft : Theme.layer1
					border.width: 1
					border.color: root.dragOver ? Theme.primary : Theme.outline

					ColumnLayout {
						anchors.centerIn: parent
						spacing: 6

						Glyph {
							Layout.alignment: Qt.AlignHCenter
							icon: "tray_arrow_down"
							size: 26
							color: root.dragOver ? Theme.primary : Theme.textSubtle
						}

						StyledText {
							Layout.alignment: Qt.AlignHCenter
							text: "Drop here"
							tone: Theme.textSubtle
							font.pixelSize: Theme.size.label
						}
					}
				}

				ListView {
					id: list

					anchors.fill: parent
					visible: !root.grid && root.items.length > 0
					interactive: contentHeight > height
					clip: true
					spacing: 2
					model: itemModel
					boundsBehavior: Flickable.StopAtBounds
					ScrollBar.vertical: ThinScrollBar {}

					add: Transition {
						NumberAnimation {
							properties: "opacity,scale"
							from: 0.6
							to: 1
							duration: Motion.medium
						}
					}
					displaced: Transition {
						NumberAnimation {
							property: "y"
							duration: Motion.medium
							easing.type: Easing.OutCubic
						}
					}

					delegate: ShelfEntry {
						id: row

						required property string itemId

						width: list.width
						height: 54
						item: root.itemOf(row.itemId)
						selected: root.selection.includes(row.itemId)
						renaming: root.renamingItem === row.itemId
						dragItems: root.dragItemsFor(row.item)
						onSelect: add => root.select(row.item, add)
						onMenuRequested: (mx, my) => root.openItemMenu(row, row.item, mx, my)
						onRenamed: name => root.finishRename(row.item, name)
					}
				}

				GridView {
					id: grid

					anchors.fill: parent
					visible: root.grid && root.items.length > 0
					interactive: contentHeight > height
					clip: true
					cellWidth: root.cellWidth
					cellHeight: root.cellHeight
					model: itemModel
					boundsBehavior: Flickable.StopAtBounds
					ScrollBar.vertical: ThinScrollBar {}

					add: Transition {
						NumberAnimation {
							properties: "opacity,scale"
							from: 0.6
							to: 1
							duration: Motion.medium
						}
					}
					displaced: Transition {
						NumberAnimation {
							properties: "x,y"
							duration: Motion.medium
							easing.type: Easing.OutCubic
						}
					}

					delegate: ShelfEntry {
						id: tile

						required property string itemId

						width: grid.cellWidth - 4
						height: grid.cellHeight - 4
						grid: true
						item: root.itemOf(tile.itemId)
						selected: root.selection.includes(tile.itemId)
						renaming: root.renamingItem === tile.itemId
						dragItems: root.dragItemsFor(tile.item)
						onSelect: add => root.select(tile.item, add)
						onMenuRequested: (mx, my) => root.openItemMenu(tile, tile.item, mx, my)
						onRenamed: name => root.finishRename(tile.item, name)
					}
				}
			}
		}

		// the gap between card and actions still counts as over the shelf
		DropArea {
			id: gapDrop

			x: 0
			y: card.height
			width: card.width
			height: 10
			visible: root.actionsShown
			onEntered: Qt.callLater(root.recountActions)
			onExited: Qt.callLater(root.recountActions)
		}

		// ── instant actions: drop on one to act without keeping ──────────
		Rectangle {
			id: actions

			readonly property var entries: [
				{ label: "Copy path", icon: "clipboard_text", run: items => Shelf.copyPaths(items) },
				{ label: "ZIP", icon: "package_variant", run: items => Shelf.zip(root.shelfId, items) },
				{ label: "Text", icon: "text_recognition", run: items => items.filter(i => Shelf.isImage(i)).forEach(i => Shelf.extractText(i)) }
			].concat(KdeConnect.available ? [{ label: "Phone", icon: "cellphone_arrow_down", run: items => Shelf.sendToPhone(items) }] : [])

			anchors.top: card.bottom
			anchors.topMargin: 10
			anchors.horizontalCenter: card.horizontalCenter
			width: actionRow.implicitWidth + 12
			height: 64
			radius: Theme.radius.huge
			color: Theme.base
			border.width: 1
			border.color: Theme.outline
			opacity: root.actionsShown ? 1 : 0
			visible: opacity > 0.01
			scale: root.actionsShown ? 1 : 0.9
			transformOrigin: Item.Top

			Behavior on opacity {
				Anim {
					duration: Motion.short
				}
			}

			Behavior on scale {
				SpatialAnim {
					duration: Motion.medium
				}
			}

			Row {
				id: actionRow

				anchors.centerIn: parent
				spacing: 4

				Repeater {
					id: actionTargets

					model: actions.entries

					delegate: DropArea {
						id: target

						required property var modelData

						width: 62
						height: 52

						onEntered: Qt.callLater(root.recountActions)
						onExited: Qt.callLater(root.recountActions)
						onDropped: event => {
							target.modelData.run(Shelf.itemsOfDrop(event));
							event.accept(Qt.CopyAction);
							Qt.callLater(root.recountActions);
						}

						Rectangle {
							anchors.fill: parent
							radius: Theme.radius.large
							color: target.containsDrag ? Theme.primary : Theme.layer1
							scale: target.containsDrag ? 1.06 : 1

							Behavior on color {
								ColorAnim {}
							}

							Behavior on scale {
								SpatialAnim {
									duration: Motion.short
								}
							}

							ColumnLayout {
								anchors.centerIn: parent
								spacing: 2

								Glyph {
									Layout.alignment: Qt.AlignHCenter
									icon: target.modelData.icon
									size: 18
									color: target.containsDrag ? Theme.onPrimary : Theme.text
								}

								StyledText {
									Layout.alignment: Qt.AlignHCenter
									text: target.modelData.label
									tone: target.containsDrag ? Theme.onPrimary : Theme.textMuted
									font.pixelSize: Theme.size.tiny
								}
							}
						}
					}
				}
			}
		}
	}

	// ── docked: a tab at the screen edge ──────────────────────────────────
	Rectangle {
		id: tab

		readonly property real shown: Math.max(0, (root.dock - 0.35) / 0.65) * root.appear
		// a drop over it, or pulled far enough to open
		readonly property bool hot: tabDrop.containsDrag || (root.tabMoving && root.tabPull >= root.pullToOpen)

		x: root.width - tab.width * tab.shown - (root.tabMoving ? root.tabPull : 0)
		y: root.tabMoving ? root.tabDragY : root.shelf.y + 40
		width: 40
		height: Math.max(64, tabColumn.implicitHeight + 20)
		visible: tab.shown > 0
		topLeftRadius: Theme.radius.large
		bottomLeftRadius: Theme.radius.large
		color: tab.hot ? Theme.primary : Theme.base
		border.width: 1
		border.color: tab.hot ? Theme.primary : Theme.outline

		Behavior on color {
			ColorAnim {}
		}

		DropArea {
			id: tabDrop

			anchors.fill: parent
			onDropped: event => {
				Shelf.addDrop(root.shelfId, event);
				event.accept(Qt.CopyAction);
			}
		}

		// click: open where it was; drag: move along the edge or pull it out
		MouseArea {
			id: tabMouse

			property point grab
			property bool dragged: false

			anchors.fill: parent
			cursorShape: pressed && tabMouse.dragged ? Qt.ClosedHandCursor : Qt.PointingHandCursor
			onPressed: event => {
				tabMouse.grab = Qt.point(event.x, event.y);
				tabMouse.dragged = false;
				root.tabDragY = root.shelf.y + 40;
				root.tabPull = 0;
				root.tabMoving = true;
			}
			onPositionChanged: event => {
				if (!pressed) return;
				const dx = tabMouse.grab.x - event.x;
				const dy = event.y - tabMouse.grab.y;
				if (Math.abs(dx) + Math.abs(dy) > 4) tabMouse.dragged = true;
				root.tabDragY = Math.max(0, Math.min(root.height - tab.height, root.tabDragY + dy));
				root.tabPull = Math.max(0, root.tabPull + dx);
			}
			onReleased: {
				const y = Math.round(root.tabDragY - 40);
				if (!tabMouse.dragged) {
					Shelf.update(root.shelfId, { docked: false, x: Math.min(root.shelf.x, root.width - root.cardWidth - 24) });
				} else if (root.tabPull >= root.pullToOpen) {
					// the card lands with its right edge where the tab was let go
					const x = Math.round(Math.max(0, root.width - root.tabPull - root.cardWidth + 20));
					Shelf.update(root.shelfId, { docked: false, x: x, y: Math.max(0, y) });
				} else {
					Shelf.update(root.shelfId, { y: y });
				}
				root.tabMoving = false;
			}
		}

		ColumnLayout {
			id: tabColumn

			anchors.centerIn: parent
			spacing: 4

			Glyph {
				Layout.alignment: Qt.AlignHCenter
				icon: "tray_full"
				size: 18
				color: tab.hot ? Theme.onPrimary : Theme.primary
			}

			StyledText {
				Layout.alignment: Qt.AlignHCenter
				visible: root.items.length > 0
				text: root.items.length
				tone: tab.hot ? Theme.onPrimary : Theme.textMuted
				font.pixelSize: Theme.size.small
				font.weight: Font.DemiBold
			}
		}
	}
}
