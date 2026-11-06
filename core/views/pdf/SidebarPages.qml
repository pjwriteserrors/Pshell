pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views

// The pages as small pictures, in the recipe's order. A click goes there,
// Ctrl adds one to the chosen, Shift a run of them; dragged, the chosen
// move to where the line shows (the others make room); a right click turns,
// doubles, takes out or removes them. Only the pictures in view are drawn.
Item {
	id: root

	property var reader: null
	property var menu: null

	readonly property real thumbW: root.width - 64

	// the list follows the recipe's pages by id, so a page moved slides instead of all being drawn again
	SyncedModel {
		id: model
	}

	property string idsKey: ""

	function follow() {
		const ids = Pdf.pages.map(p => p.id);
		const key = ids.join(",");
		if (key === root.idsKey) return;
		root.idsKey = key;
		model.sync(ids.map(id => ({ key: id })));
	}

	Component.onCompleted: root.follow()

	Connections {
		target: Pdf

		function onRecipeChanged() {
			root.follow();
		}

		function onPageChanged() {
			if (!drag.active) list.positionViewAtIndex(Pdf.page, ListView.Contain);
		}
	}

	function choose(id, mouse) {
		const ctrl = mouse.modifiers & Qt.ControlModifier, shift = mouse.modifiers & Qt.ShiftModifier;
		if (ctrl) {
			const had = Pdf.selectedPages.includes(id);
			Pdf.selectedPages = had ? Pdf.selectedPages.filter(x => x !== id) : Pdf.selectedPages.concat([id]);
		} else if (shift && Pdf.selectedPages.length > 0) {
			const a = Pdf.indexOf(Pdf.selectedPages[Pdf.selectedPages.length - 1]), b = Pdf.indexOf(id);
			const lo = Math.min(a, b), hi = Math.max(a, b);
			Pdf.selectedPages = Pdf.pages.slice(lo, hi + 1).map(p => p.id);
		} else {
			Pdf.selectedPages = [];
			Pdf.goTo(Pdf.indexOf(id));
		}
	}

	function targets(id) {
		return Pdf.selectedPages.includes(id) ? Pdf.selectedPages : [id];
	}

	function pageMenu(id, item, x, y) {
		if (!root.menu) return;
		const ids = root.targets(id);
		const many = ids.length > 1;
		const at = item.mapToItem(root.menu, x, y);
		root.menu.show([
			{ header: many ? `${ids.length} pages` : `Page ${Pdf.indexOf(id) + 1}` },
			{ label: "Turn right", icon: "rotate_right", run: () => Pdf.rotatePages(ids, 90) },
			{ label: "Turn left", icon: "rotate_left", run: () => Pdf.rotatePages(ids, -90) },
			{ label: many ? "Double them" : "Double it", icon: "content_duplicate", run: () => Pdf.duplicatePages(ids) },
			{ label: "An empty page after", icon: "file_plus_outline", run: () => Pdf.insertBlank(Pdf.indexOf(ids[ids.length - 1]) + 1) },
			{ separator: true },
			{ label: many ? "Take them out as a file" : "Take it out as a file", icon: "file_export_outline", run: () => Pdf.extractPages(ids) },
			{ label: "A new file begins after it", icon: "content_cut", enabled: Pdf.indexOf(ids[ids.length - 1]) < Pdf.pageCount - 1, run: () => Pdf.splitAfter(ids) },
			{ label: "Copy as a picture", icon: "content_copy", enabled: !many, run: () => Pdf.copyPage(Pdf.indexOf(id)) },
			{ label: "To the shelf", icon: "tray_arrow_down", children: [
				{ label: many ? "As one PDF" : "As a PDF", icon: "file_pdf_box", run: () => Pdf.toShelf(ids) },
				{ label: many ? "As pictures" : "As a picture", icon: "image_outline", run: () => Pdf.pagesToShelf(ids) }
			] },
			{ separator: true },
			{ label: many ? "Remove them" : "Remove it", icon: "delete_outline", danger: true, run: () => Pdf.deletePages(ids) }
		], at.x, at.y);
	}

	ListView {
		id: list

		anchors.fill: parent
		anchors.bottomMargin: 6
		model: model
		spacing: 6
		clip: true
		cacheBuffer: 600
		boundsBehavior: Flickable.StopAtBounds
		interactive: !drag.active
		reuseItems: false

		ScrollBar.vertical: ThinScrollBar {}

		move: Transition {
			SpatialAnim {
				properties: "x,y"
				duration: Motion.long
			}
		}
		displaced: Transition {
			SpatialAnim {
				properties: "x,y"
				duration: Motion.long
			}
		}
		add: Transition {
			ParallelAnimation {
				Anim {
					property: "opacity"
					from: 0
					to: 1
				}
				SpatialAnim {
					property: "scale"
					from: 0.8
					to: 1
				}
			}
		}
		remove: Transition {
			ParallelAnimation {
				Anim {
					property: "opacity"
					to: 0
				}
				SpatialAnim {
					property: "scale"
					to: 0.7
				}
			}
		}

		delegate: Item {
			id: cell

			required property string key
			required property int index
			readonly property bool current: Pdf.page === cell.index
			readonly property bool chosen: Pdf.selectedPages.includes(cell.key)
			readonly property var size: Pdf.sizeOf(Pdf.pageById(cell.key))
			readonly property real tk: Math.min(root.thumbW / Math.max(1, cell.size.width), (root.thumbW * 1.5) / Math.max(1, cell.size.height))

			width: list.width
			height: thumb.height + 26
			opacity: drag.active && root.targets(drag.page).includes(cell.key) ? 0.35 : 1

			Behavior on opacity {
				Anim {}
			}

			Rectangle {
				anchors.centerIn: thumb
				width: thumb.width + 8
				height: thumb.height + 8
				radius: 6
				color: cell.chosen ? Qt.alpha(Theme.primary, 0.18) : "transparent"
				border.color: cell.current || cell.chosen ? Theme.primary : "transparent"
				border.width: 2

				Behavior on border.color {
					ColorAnimation {
						duration: Motion.short
					}
				}
			}

			PdfPage {
				id: thumb

				anchors.horizontalCenter: parent.horizontalCenter
				y: 4
				pageId: cell.key
				reader: root.reader
				k: cell.tk
				renderK: cell.tk
				interactive: false
				thumbnail: true
			}

			StyledText {
				anchors.horizontalCenter: parent.horizontalCenter
				anchors.top: thumb.bottom
				anchors.topMargin: 5
				text: String(cell.index + 1)
				tone: cell.current ? Theme.primary : Theme.textMuted
				font.pixelSize: Theme.size.small
				font.weight: cell.current ? Font.DemiBold : Font.Normal
				tabular: true
			}

			MouseArea {
				anchors.fill: parent
				acceptedButtons: Qt.LeftButton | Qt.RightButton
				onPressed: mouse => {
					if (mouse.button === Qt.LeftButton) drag.arm(cell.key, cell, mouse.y);
				}
				onPositionChanged: mouse => drag.move(cell, mouse.y)
				onReleased: mouse => {
					if (mouse.button !== Qt.LeftButton) return;
					if (drag.active) drag.drop();
					else {
						drag.cancel();
						root.choose(cell.key, mouse);
					}
				}
				onClicked: mouse => {
					if (mouse.button === Qt.RightButton) root.pageMenu(cell.key, cell, mouse.x, mouse.y);
				}
				onDoubleClicked: Pdf.goTo(cell.index)
			}
		}
	}

	// ── dragging pages into a new order ────────────────────────────────────
	QtObject {
		id: drag

		property string page: ""
		property bool active: false
		property real startY: 0
		property real atY: 0
		property int target: -1

		function arm(id, item, y) {
			drag.page = id;
			drag.startY = item.mapToItem(list, 0, y).y;
			drag.active = false;
		}

		function move(item, y) {
			if (!drag.page) return;
			const p = item.mapToItem(list, 0, y).y;
			if (!drag.active && Math.abs(p - drag.startY) > 8) drag.active = true;
			if (!drag.active) return;
			drag.atY = p;
			// the gap the pointer is nearest
			const contentY = p + list.contentY;
			let best = 0, bestD = 1e9;
			for (let i = 0; i <= list.count; i += 1) {
				const it = list.itemAtIndex(Math.min(i, list.count - 1));
				if (!it) continue;
				const edge = i < list.count ? it.y : it.y + it.height;
				const d = Math.abs(edge - contentY);
				if (d < bestD) {
					bestD = d;
					best = i;
				}
			}
			drag.target = best;
			// near the edges the list scrolls along
			if (p < 30) list.contentY = Math.max(0, list.contentY - 14);
			else if (p > list.height - 30) list.contentY = Math.min(list.contentHeight - list.height, list.contentY + 14);
		}

		function drop() {
			const ids = root.targets(drag.page);
			if (drag.target >= 0) Pdf.movePages(ids, drag.target);
			drag.cancel();
		}

		function cancel() {
			drag.page = "";
			drag.active = false;
			drag.target = -1;
		}
	}

	// where the pages will go
	Rectangle {
		readonly property var it: drag.target >= 0 ? list.itemAtIndex(Math.min(drag.target, list.count - 1)) : null

		visible: drag.active && !!it
		x: 16
		width: root.width - 32
		height: 3
		radius: 1.5
		color: Theme.primary
		y: it ? (drag.target < list.count ? it.y : it.y + it.height) - list.contentY - 3 : 0
	}

	// what is dragged, under the pointer
	Rectangle {
		visible: drag.active
		x: root.width / 2 - 26
		y: drag.atY - 16
		width: 52
		height: 32
		radius: 16
		color: Theme.primary

		StyledText {
			anchors.centerIn: parent
			text: String(root.targets(drag.page).length)
			tone: Theme.onPrimary
			surface: Theme.primary
			font.weight: Font.DemiBold
		}
	}
}
