pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Pdf
import qs.style.theme
import qs.style.widgets
import qs.core.services

// All pages at once, over the whole window: dragged into a new order (the
// others spring aside), chosen by click, Ctrl, Shift or a band drawn around
// them, turned, doubled, removed (they fall away), cut into files at the
// gaps, and files dropped in between. Ctrl+wheel or the slider makes them
// larger; Enter goes to the chosen page, Escape back.
Rectangle {
	id: root

	property Item dock: null
	property real cell: Pdf.setting("gridCell", 180)
	readonly property real gap: 18
	readonly property int columns: Math.max(1, Math.floor((flick.width - root.gap) / (root.cell + root.gap)))
	readonly property real cellH: root.cell * 1.3 + 26
	readonly property var order: Pdf.pages.map(p => p.id)
	// while dragging: the order shown (the dragged ones where they would land)
	property var dragIds: []
	property int dropAt: -1
	readonly property var shownOrder: {
		if (root.dragIds.length === 0 || root.dropAt < 0) return root.order;
		const rest = root.order.filter(id => !root.dragIds.includes(id));
		rest.splice(Math.min(root.dropAt, rest.length), 0, ...root.order.filter(id => root.dragIds.includes(id)));
		return rest;
	}
	readonly property var slotOf: {
		const map = {};
		root.shownOrder.forEach((id, i) => map[id] = i);
		return map;
	}
	// cut after these pages
	property var cuts: []
	// falling away right now
	property var falling: []
	property int anchor: -1

	color: Theme.base
	focus: true
	opacity: 0
	scale: 0.98
	Component.onCompleted: {
		root.opacity = 1;
		root.scale = 1;
		root.forceActiveFocus();
		Qt.callLater(() => root.reveal(Pdf.page));
	}

	Behavior on opacity {
		Anim {}
	}

	Behavior on scale {
		SpatialAnim {}
	}

	function close() {
		Pdf.gridOpen = false;
	}

	function cellX(slot) {
		const used = root.columns * (root.cell + root.gap) - root.gap;
		const left = Math.max(root.gap, (flick.width - used) / 2);
		return left + (slot % root.columns) * (root.cell + root.gap);
	}

	function cellY(slot) {
		return root.gap + Math.floor(slot / root.columns) * (root.cellH + root.gap);
	}

	function reveal(index) {
		const y = root.cellY(index);
		if (y < flick.contentY || y + root.cellH > flick.contentY + flick.height) flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, y - flick.height / 3));
	}

	// the gap a point of the grid is nearest to (0 … count)
	function gapAt(x, y) {
		const row = Math.max(0, Math.floor((y - root.gap / 2) / (root.cellH + root.gap)));
		const left = root.cellX(0);
		const col = Math.max(0, Math.min(root.columns, Math.round((x - left) / (root.cell + root.gap))));
		return Math.max(0, Math.min(root.order.length, row * root.columns + col));
	}

	function pick(id, mouse) {
		const index = root.order.indexOf(id);
		if (mouse.modifiers & Qt.ShiftModifier && root.anchor >= 0) {
			const a = Math.min(root.anchor, index), b = Math.max(root.anchor, index);
			Pdf.selectedPages = root.order.slice(a, b + 1);
		} else if (mouse.modifiers & Qt.ControlModifier) {
			Pdf.selectedPages = Pdf.selectedPages.includes(id) ? Pdf.selectedPages.filter(x => x !== id) : Pdf.selectedPages.concat([id]);
			root.anchor = index;
		} else {
			Pdf.selectedPages = [id];
			root.anchor = index;
		}
		Pdf.pageScope = "selected";
	}

	// the chosen ones fall, then go
	function remove(ids) {
		if (ids.length === 0) return;
		if (ids.length >= Pdf.pageCount) return Pdf.say("A PDF keeps at least one page", "alert_circle_outline");
		root.falling = ids;
		Sounds.play("trashed");
		fallTimer.restart();
	}

	Timer {
		id: fallTimer

		interval: Motion.long
		onTriggered: {
			const ids = root.falling;
			root.falling = [];
			Pdf.deletePages(ids);
		}
	}

	readonly property var chosen: Pdf.selectedPages.filter(id => root.order.includes(id))

	Keys.onPressed: event => {
		const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
		if (event.key === Qt.Key_Escape || (event.key === Qt.Key_G && !ctrl)) root.close();
		else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
			const i = root.order.indexOf(root.chosen[0] ?? "");
			if (i >= 0) Pdf.goTo(i);
			root.close();
		} else if (event.key === Qt.Key_Delete) root.remove(root.chosen);
		else if (ctrl && event.key === Qt.Key_A) Pdf.selectedPages = root.order.slice();
		else if (ctrl && event.key === Qt.Key_D) Pdf.duplicatePages(root.chosen);
		else if (ctrl && event.key === Qt.Key_Z) Pdf.undo();
		else if (ctrl && event.key === Qt.Key_Y) Pdf.redo();
		else if (event.key === Qt.Key_R) Pdf.rotatePages(root.chosen, event.modifiers & Qt.ShiftModifier ? -90 : 90);
		else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right || event.key === Qt.Key_Up || event.key === Qt.Key_Down) {
			const now = Math.max(0, root.order.indexOf(root.chosen[root.chosen.length - 1] ?? root.order[Pdf.page]));
			const step = { [Qt.Key_Left]: -1, [Qt.Key_Right]: 1, [Qt.Key_Up]: -root.columns, [Qt.Key_Down]: root.columns }[event.key];
			const next = Math.max(0, Math.min(root.order.length - 1, now + step));
			root.pick(root.order[next], { modifiers: event.modifiers });
			root.reveal(next);
		} else return;
		event.accepted = true;
	}

	// the documents the thumbnails are drawn from (as the reader has them)
	QtObject {
		id: docsHolder

		property var docs: ({})
	}

	Instantiator {
		model: Pdf.sourceKeys

		delegate: PdfDocument {
			id: doc

			required property string modelData

			source: Pdf.sourcePath(doc.modelData) ? Pdf.fileUrl(Pdf.sourcePath(doc.modelData)) : ""
			password: Pdf.recipe.sources?.[doc.modelData]?.password ?? ""
		}

		onObjectAdded: (index, object) => docsHolder.docs = Object.assign({}, docsHolder.docs, { [object.modelData]: object })
		onObjectRemoved: (index, object) => {
			const next = Object.assign({}, docsHolder.docs);
			if (next[object.modelData] === object) delete next[object.modelData];
			docsHolder.docs = next;
		}
	}

	// ── above ──────────────────────────────────────────────────────────────
	Rectangle {
		id: head

		width: parent.width
		height: 60
		z: 3
		color: Theme.layer1

		Rectangle {
			anchors.bottom: parent.bottom
			width: parent.width
			height: 1
			color: Theme.outline
		}

		IconButton {
			id: back

			x: 12
			anchors.verticalCenter: parent.verticalCenter
			icon: "arrow_left"
			onClicked: root.close()
		}

		Column {
			anchors.left: back.right
			anchors.leftMargin: 10
			anchors.verticalCenter: parent.verticalCenter

			StyledText {
				text: "All pages"
				font.pixelSize: Theme.size.title
				font.weight: Font.Bold
			}

			StyledText {
				text: root.chosen.length > 0 ? `${root.chosen.length} of ${Pdf.pageCount} chosen · ${Pdf.rangeText(root.chosen)}` : `${Pdf.pageCount} pages – drag to order, drop files in between`
				font.pixelSize: Theme.size.small
				tone: Theme.textMuted
			}
		}

		Row {
			anchors.right: parent.right
			anchors.rightMargin: 14
			anchors.verticalCenter: parent.verticalCenter
			spacing: 4

			Repeater {
				model: [
					{ icon: "rotate_left", tip: "Turn left (Shift+R)", run: () => Pdf.rotatePages(root.chosen, -90), needs: true },
					{ icon: "rotate_right", tip: "Turn right (R)", run: () => Pdf.rotatePages(root.chosen, 90), needs: true },
					{ icon: "content_duplicate", tip: "Double (Ctrl+D)", run: () => Pdf.duplicatePages(root.chosen), needs: true },
					{ icon: "file_export_outline", tip: "Take out as a file", run: () => Pdf.extractPages(root.chosen), needs: true },
					{ icon: "delete_outline", tip: "Remove (Delete)", run: () => root.remove(root.chosen), needs: true },
					{ icon: "file_plus_outline", tip: "Put files in at the end", run: () => Files.pick({ title: "Put these in", multiple: true, filters: ["*.pdf", "*.png", "*.jpg", "*.jpeg", "*.webp"] }, paths => {
						for (const p of paths || []) Pdf.insertFile(p, -1);
					}), needs: false },
					{ icon: "undo", tip: "Undo (Ctrl+Z)", run: () => Pdf.undo(), needs: false }
				]

				delegate: IconButton {
					required property var modelData

					icon: modelData.icon
					enabled: !modelData.needs || root.chosen.length > 0
					opacity: enabled ? 1 : 0.35
					onClicked: modelData.run()
					ToolTip.visible: hovered
					ToolTip.delay: 500
					ToolTip.text: modelData.tip
				}
			}

			TextButton {
				visible: root.cuts.length > 0
				text: `Cut into ${root.cuts.length + 1} files`
				icon: "content_cut"
				variant: "tonal"
				onActivated: {
					Pdf.splitAfter(root.cuts);
					root.cuts = [];
				}
			}

			PillSlider {
				anchors.verticalCenter: parent.verticalCenter
				width: 140
				height: 30
				icon: "magnify"
				showValue: false
				value: (root.cell - 90) / 330
				onMoved: value => {
					root.cell = 90 + value * 330;
					Pdf.setSetting("gridCell", Math.round(root.cell));
				}
			}

			TextButton {
				text: "Done"
				variant: "filled"
				onActivated: root.close()
			}
		}
	}

	// ── the pages ──────────────────────────────────────────────────────────
	Flickable {
		id: flick

		anchors.fill: parent
		anchors.topMargin: head.height
		contentHeight: root.cellY(Math.max(0, root.order.length - 1)) + root.cellH + root.gap * 2
		clip: true
		boundsBehavior: Flickable.StopAtBounds
		interactive: root.dragIds.length === 0 && !band.active
		ScrollBar.vertical: ThinScrollBar {}

		// Ctrl+wheel: larger and smaller
		WheelHandler {
			acceptedModifiers: Qt.ControlModifier
			onWheel: event => {
				root.cell = Math.max(90, Math.min(420, root.cell * (event.angleDelta.y > 0 ? 1.1 : 0.9)));
				Pdf.setSetting("gridCell", Math.round(root.cell));
			}
		}

		// a band drawn on the empty space chooses what it touches
		MouseArea {
			id: band

			property bool active: false
			property point from

			width: flick.width
			height: Math.max(flick.height, flick.contentHeight)
			onPressed: mouse => {
				band.from = Qt.point(mouse.x, mouse.y);
				band.active = false;
			}
			onPositionChanged: mouse => {
				if (!pressed) return;
				if (!band.active && Math.hypot(mouse.x - band.from.x, mouse.y - band.from.y) > 6) band.active = true;
				if (!band.active) return;
				const x0 = Math.min(band.from.x, mouse.x), y0 = Math.min(band.from.y, mouse.y), x1 = Math.max(band.from.x, mouse.x), y1 = Math.max(band.from.y, mouse.y);
				bandBox.x = x0;
				bandBox.y = y0;
				bandBox.width = x1 - x0;
				bandBox.height = y1 - y0;
				const keep = (mouse.modifiers & Qt.ControlModifier) ? Pdf.selectedPages : [];
				const hit = root.order.filter((id, i) => root.cellX(i) < x1 && root.cellX(i) + root.cell > x0 && root.cellY(i) < y1 && root.cellY(i) + root.cellH > y0);
				Pdf.selectedPages = Array.from(new Set(keep.concat(hit)));
				Pdf.pageScope = "selected";
				// the edge scrolls
				const inView = mouse.y - flick.contentY;
				if (inView > flick.height - 30) flick.contentY = Math.min(flick.contentHeight - flick.height, flick.contentY + 12);
				else if (inView < 30) flick.contentY = Math.max(0, flick.contentY - 12);
			}
			onReleased: {
				if (!band.active) Pdf.selectedPages = [];
				band.active = false;
			}

			Rectangle {
				id: bandBox

				visible: band.active
				color: Theme.primarySoft
				border.color: Theme.primary
				border.width: 1
				radius: 3
			}
		}

		// files dropped in between
		DropArea {
			width: flick.width
			height: Math.max(flick.height, flick.contentHeight)
			keys: ["text/uri-list"]
			onDropped: drop => {
				const at = root.gapAt(drop.x, drop.y);
				let i = at;
				for (const url of drop.urls || []) {
					Pdf.insertFile(Pdf.plainPath(String(url)), i);
					i += 1;
				}
				drop.accept(Qt.CopyAction);
			}

			// where they will go
			Rectangle {
				readonly property int at: root.gapAt(parent.drag.x, parent.drag.y)
				readonly property bool last: at >= root.order.length

				visible: parent.containsDrag
				x: (last ? root.cellX(root.order.length - 1) + root.cell + root.gap / 2 : root.cellX(at) - root.gap / 2) - 2
				y: root.cellY(last ? root.order.length - 1 : at)
				width: 4
				height: root.cellH
				radius: 2
				color: Theme.primary
			}
		}

		Repeater {
			model: root.order

			delegate: Item {
				id: tile

				required property string modelData
				required property int index
				readonly property var page: Pdf.pageById(tile.modelData)
				readonly property int slot: root.slotOf[tile.modelData] ?? tile.index
				readonly property bool chosen: Pdf.selectedPages.includes(tile.modelData)
				readonly property bool dragged: root.dragIds.includes(tile.modelData)
				readonly property bool isFalling: root.falling.includes(tile.modelData)
				readonly property size shownSize: Pdf.sizeOf(tile.page)
				readonly property real tk: Math.min(root.cell / Math.max(1, tile.shownSize.width), root.cell * 1.3 / Math.max(1, tile.shownSize.height))
				readonly property bool cutAfter: root.cuts.includes(tile.modelData)
				// a turn is seen turning
				property real spin: 0
				property int lastRot: tile.page?.rot ?? 0

				x: root.cellX(tile.slot)
				y: root.cellY(tile.slot) + (tile.isFalling ? root.cellH * 0.8 : 0)
				z: tile.dragged ? 5 : 1
				width: root.cell
				height: root.cellH
				opacity: tile.isFalling ? 0 : (tile.dragged && root.dropAt >= 0 ? 0.35 : 1)
				rotation: tile.isFalling ? (tile.index % 2 ? 14 : -14) : 0

				Behavior on x {
					enabled: !tile.dragged || root.dropAt < 0

					SpatialAnim {}
				}

				Behavior on y {
					SpatialAnim {
						duration: tile.isFalling ? Motion.long : Motion.medium
						easing.bezierCurve: tile.isFalling ? Motion.accel : Motion.spatial
					}
				}

				Behavior on opacity {
					Anim {}
				}

				Behavior on rotation {
					Anim {
						duration: Motion.long
					}
				}

				Connections {
					target: tile

					function onPageChanged() {
						const rot = tile.page?.rot ?? 0;
						if (rot !== tile.lastRot) {
							let delta = rot - tile.lastRot;
							if (delta > 180) delta -= 360;
							if (delta < -180) delta += 360;
							tile.lastRot = rot;
							spinIn.stop();
							tile.spin = -delta;
							spinIn.start();
						}
					}
				}

				NumberAnimation {
					id: spinIn

					target: tile
					property: "spin"
					to: 0
					duration: Motion.long
					easing.type: Easing.OutBack
				}

				Rectangle {
					id: card

					anchors.horizontalCenter: parent.horizontalCenter
					y: (root.cell * 1.3 - height) / 2
					width: thumb.width + 8
					height: thumb.height + 8
					radius: 6
					color: tile.chosen ? Theme.primary : (tileMouse.containsMouse ? Theme.layer3 : "transparent")
					rotation: tile.spin
					scale: tileMouse.pressed && root.dragIds.length === 0 ? 0.96 : 1

					Behavior on scale {
						SpatialAnim {}
					}

					Behavior on color {
						ColorAnim {}
					}

					PdfPage {
						id: thumb

						x: 4
						y: 4
						pageId: tile.modelData
						reader: docsHolder
						k: tile.tk
						renderK: tile.tk
						interactive: false
						thumbnail: true
					}
				}

				StyledText {
					anchors.horizontalCenter: parent.horizontalCenter
					anchors.bottom: parent.bottom
					anchors.bottomMargin: 2
					text: `${tile.index + 1}${tile.page?.src && tile.page.src !== "a" ? " · " + Pdf.nameOf(Pdf.recipe.sources[tile.page.src]?.path ?? "") : ""}`
					width: Math.min(implicitWidth, parent.width)
					elide: Text.ElideRight
					font.pixelSize: Theme.size.small
					font.weight: tile.chosen ? Font.Bold : Font.Normal
					tone: tile.chosen ? Theme.primary : Theme.textMuted
				}

				MouseArea {
					id: tileMouse

					property point from
					property bool moving: false

					anchors.fill: card
					hoverEnabled: true
					preventStealing: true
					cursorShape: tileMouse.moving ? Qt.ClosedHandCursor : Qt.PointingHandCursor
					onPressed: mouse => {
						tileMouse.from = Qt.point(mouse.x, mouse.y);
						tileMouse.moving = false;
						if (!tile.chosen || (mouse.modifiers & (Qt.ControlModifier | Qt.ShiftModifier))) root.pick(tile.modelData, mouse);
					}
					onPositionChanged: mouse => {
						if (!pressed) return;
						if (!tileMouse.moving && Math.hypot(mouse.x - tileMouse.from.x, mouse.y - tileMouse.from.y) > 8) {
							tileMouse.moving = true;
							root.dragIds = Pdf.selectedPages.includes(tile.modelData) ? root.order.filter(id => Pdf.selectedPages.includes(id)) : [tile.modelData];
							ghost.count = root.dragIds.length;
							ghost.pageId = tile.modelData;
							ghost.tk = tile.tk;
						}
						if (!tileMouse.moving) return;
						const q = tileMouse.mapToItem(flick.contentItem, mouse.x, mouse.y);
						ghost.x = q.x - ghost.width / 2;
						ghost.y = q.y - ghost.height / 2;
						// the place among the others (without the dragged ones)
						const raw = root.gapAt(q.x, q.y);
						const before = root.order.slice(0, raw).filter(id => !root.dragIds.includes(id)).length;
						root.dropAt = before;
						const inView = q.y - flick.contentY;
						if (inView > flick.height - 40) flick.contentY = Math.min(flick.contentHeight - flick.height, flick.contentY + 14);
						else if (inView < 40) flick.contentY = Math.max(0, flick.contentY - 14);
					}
					onReleased: mouse => {
						if (tileMouse.moving) {
							const rest = root.order.filter(id => !root.dragIds.includes(id));
							const to = root.dropAt >= rest.length ? root.order.length : root.order.indexOf(rest[root.dropAt]);
							const ids = root.dragIds;
							root.dragIds = [];
							root.dropAt = -1;
							if (to >= 0) Pdf.movePages(ids, to);
						} else if (!(mouse.modifiers & (Qt.ControlModifier | Qt.ShiftModifier))) root.pick(tile.modelData, mouse);
						tileMouse.moving = false;
					}
					onDoubleClicked: {
						Pdf.goTo(tile.index);
						root.close();
					}
				}

				// the gap after it: a click cuts the file there
				Item {
					x: parent.width + root.gap / 2 - 12
					y: (root.cell * 1.3) / 2 - 12
					width: 24
					height: 24
					visible: tile.index < root.order.length - 1 && root.dragIds.length === 0

					Rectangle {
						anchors.horizontalCenter: parent.horizontalCenter
						y: -root.cell * 0.5
						width: 2
						height: root.cell * 1.3 * 0.75
						visible: tile.cutAfter
						color: Theme.danger
						radius: 1
					}

					Rectangle {
						anchors.fill: parent
						radius: 12
						color: tile.cutAfter ? Theme.danger : Theme.layer3
						opacity: tile.cutAfter || cutMouse.containsMouse ? 1 : 0
						scale: cutMouse.containsMouse ? 1.1 : 1

						Behavior on opacity {
							Anim {}
						}

						Behavior on scale {
							SpatialAnim {}
						}

						Glyph {
							anchors.centerIn: parent
							icon: "content_cut"
							size: 14
							color: tile.cutAfter ? "white" : Theme.text
							rotation: 90
						}
					}

					MouseArea {
						id: cutMouse

						anchors.fill: parent
						anchors.margins: -4
						hoverEnabled: true
						cursorShape: Qt.PointingHandCursor
						onClicked: root.cuts = tile.cutAfter ? root.cuts.filter(id => id !== tile.modelData) : root.cuts.concat([tile.modelData])
					}
				}
			}
		}

		// what is dragged, under the pointer, a count on it when it is more
		Item {
			id: ghost

			property string pageId: ""
			property int count: 0
			property real tk: 0.2

			visible: root.dragIds.length > 0
			z: 10
			width: ghostPage.width
			height: ghostPage.height
			rotation: -3
			scale: 1.05

			Rectangle {
				visible: ghost.count > 1
				x: 8
				y: 8
				width: ghostPage.width
				height: ghostPage.height
				radius: 4
				color: "white"
				border.color: Theme.outline
				rotation: 5
			}

			PdfPage {
				id: ghostPage

				pageId: ghost.pageId || (Pdf.pages[0]?.id ?? "")
				reader: docsHolder
				k: ghost.tk
				renderK: ghost.tk
				interactive: false
				thumbnail: true
			}

			Rectangle {
				visible: ghost.count > 1
				anchors.right: parent.right
				anchors.top: parent.top
				anchors.margins: -8
				width: 26
				height: 26
				radius: 13
				color: Theme.primary

				Text {
					anchors.centerIn: parent
					text: ghost.count
					color: Theme.onPrimary
					font.bold: true
				}
			}
		}
	}
}
