pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "Listing.js" as Listing

// What is in a place, as cards or as a list, optionally in groups. One
// pointer handler serves every card: a click picks, a drag on the empty
// space draws a band, a drag on a card carries the picked files out (to
// other folders, other apps, the shake ring), a drop on a folder card puts
// things in it, and a folder held under a drop for a moment opens.
Item {
	id: root

	required property var pane
	// the pane the keyboard works in (a split has two)
	property bool active: true
	// the keyboard was used last: the current card shows its ring
	property bool keyboard: false

	readonly property bool grouped: root.pane.group !== "none" && root.pane.rows.length > 0
	readonly property bool list: root.pane.mode === "list"
	readonly property real pad: root.list ? 10 : 12
	readonly property real cardSize: Math.max(110, Math.min(340, FileLibrary.view.cardSize || 172))
	readonly property real usable: Math.max(100, root.width - root.pad * 2 - 6)
	readonly property int columns: root.list ? 1 : Math.max(1, Math.floor(root.usable / root.cardSize))
	readonly property real cellW: root.list ? root.usable : Math.floor(root.usable / root.columns)
	// a narrow list (a split) lets the kind go first, then the date: the name keeps its room
	readonly property real kindW: root.cellW < 640 ? 0 : 128
	readonly property real whenW: root.cellW < 470 ? 0 : (root.cellW < 560 ? 112 : 150)
	readonly property real sizeW: root.cellW < 300 ? 0 : 86
	// the columns change with the width: what moves then is not animated
	property bool relayout: false

	onColumnsChanged: {
		root.relayout = true;
		relayoutOff.restart();
	}

	Timer {
		id: relayoutOff

		interval: 400
		onTriggered: {
			root.relayout = false;
			grid.forceLayout();
		}
	}

	// a card: its picture, two lines of name and one about it, measured in the font it is drawn in
	readonly property real nameH: Math.ceil(labelMetrics.height * 1.05) * 2 + 2 + Math.ceil(smallMetrics.height)
	readonly property real cellH: root.list ? (root.pane.location.kind === "search" ? 46 : 38) : Math.round(Math.round(root.cellW * 0.74) * 0.8) + 12 + 8 + root.nameH + 14
	readonly property real headerH: 46
	readonly property bool showFolder: ["search", "recent", "tag", "collection", "shelf", "trash"].includes(root.pane.location.kind)
	readonly property Flickable flick: root.grouped ? groupedView : grid

	FontMetrics {
		id: labelMetrics

		font.family: Theme.fontFamily
		font.pixelSize: Theme.size.label
		font.weight: Font.DemiBold
	}

	FontMetrics {
		id: smallMetrics

		font.family: Theme.fontFamily
		font.pixelSize: Theme.size.small
	}

	property int hoveredIndex: -1
	property int dropIndex: -1
	// something from elsewhere is held over the place itself, not over a folder in it
	property bool dropOnPlace: false
	property bool entering: false

	// open: a double click or Enter; menu: a right click (index -1: the empty space)
	signal opened(int index, bool newTab)
	signal menuRequested(int index, real x, real y)
	signal focusRequested

	// ── the entrance of a new place ────────────────────────────────────────
	Connections {
		target: root.pane

		function onResetsChanged() {
			// cards rise one by one into a folder opened anew; going back (or up)
			// to one seen before only fades the whole view, so nothing blinks
			root.entering = !root.pane.historyStep && root.pane.direction !== "out";
			enteringOff.restart();
			const dir = root.pane.direction;
			stage.scale = dir === "in" ? 0.965 : (dir === "out" ? 1.035 : 0.985);
			stage.opacity = 0;
			stageIn.restart();
			scrollAnim.stop();
			const y = root.pane.restoreY;
			Qt.callLater(() => {
				root.flick.contentY = y >= 0 ? y : root.minY();
				root.pane.restoreY = -1;
				if (root.pane.current >= 0) root.ensureVisible(root.pane.current, true);
			});
		}

		function onLoaded(reset) {
			if (!reset && root.pane.current >= 0 && root.keyboard) root.ensureVisible(root.pane.current, false);
		}
	}

	Timer {
		id: enteringOff

		interval: 60
		onTriggered: root.entering = false
	}

	ParallelAnimation {
		id: stageIn

		NumberAnimation {
			target: stage
			property: "opacity"
			to: 1
			duration: Motion.medium
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.standard
		}
		NumberAnimation {
			target: stage
			property: "scale"
			to: 1
			duration: Motion.long
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.decel
		}
	}

	// ── list header: the columns, sorting by a click ───────────────────────
	Item {
		id: columnsHeader

		visible: root.list
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.leftMargin: root.pad + 3
		anchors.rightMargin: root.pad + 3
		height: root.list ? 30 : 0

		// name on the left; when, size and kind at the same places as in the rows
		Repeater {
			model: [
				{ label: "Name", key: "name", x: 44, span: columnsHeader.width - 44 - root.whenW - root.sizeW - root.kindW - 10, right: false },
				{ label: root.pane.location.kind === "recent" ? "Used" : "Modified", key: "modified", x: columnsHeader.width - 10 - root.kindW - root.sizeW - root.whenW, span: root.whenW, right: false },
				{ label: "Size", key: "size", x: columnsHeader.width - 10 - root.kindW - root.sizeW, span: root.sizeW, right: true },
				{ label: "Kind", key: "kind", x: columnsHeader.width - 10 - root.kindW, span: root.kindW, right: false }
			].filter(column => column.span > 0)

			delegate: Item {
				id: column

				required property var modelData
				readonly property bool on: root.pane.sort === column.modelData.key

				x: column.modelData.x
				width: column.modelData.span
				height: columnsHeader.height

				Row {
					anchors.verticalCenter: parent.verticalCenter
					anchors.right: column.modelData.right ? parent.right : undefined
					anchors.rightMargin: 16
					spacing: 3
					layoutDirection: column.modelData.right ? Qt.RightToLeft : Qt.LeftToRight

					Text {
						text: column.modelData.label
						color: column.on ? Theme.text : Theme.textSubtle
						font.family: Theme.fontFamily
						font.pixelSize: Theme.size.small
						font.weight: column.on ? Font.DemiBold : Font.Medium
					}

					Glyph {
						visible: column.on
						anchors.verticalCenter: parent.verticalCenter
						icon: root.pane.desc ? "chevron_down" : "chevron_up"
						size: 13
						color: Theme.primary
					}
				}

				MouseArea {
					anchors.fill: parent
					cursorShape: Qt.PointingHandCursor
					onClicked: {
						Sounds.play("select");
						const path = root.pane.viewKey;
						if (column.on) FileLibrary.setView(path, { desc: !root.pane.desc });
						else FileLibrary.setView(path, { sort: column.modelData.key, desc: column.modelData.key === "modified" || column.modelData.key === "size" });
					}
				}
			}
		}

		Rectangle {
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.bottom: parent.bottom
			height: 1
			color: Theme.outline
		}
	}

	Item {
		id: stage

		anchors.top: columnsHeader.bottom
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		transformOrigin: Item.Center

		// ── the cards (or rows) without groups ─────────────────────────────
		GridView {
			id: grid

			anchors.fill: parent
			visible: !root.grouped
			interactive: false
			clip: true
			leftMargin: root.pad
			rightMargin: root.pad
			topMargin: root.list ? 4 : 8
			bottomMargin: 96
			cellWidth: root.cellW
			cellHeight: root.cellH
			cacheBuffer: Math.max(0, root.cellH * 2)
			model: root.grouped ? null : root.pane.items
			delegate: root.list ? rowDelegate : cardDelegate
			boundsBehavior: Flickable.StopAtBounds

			add: root.pane.resetting || root.entering || root.relayout ? null : addTransition
			remove: root.pane.resetting || root.relayout ? null : removeTransition
			displaced: root.pane.resetting || root.relayout ? null : displacedTransition
			move: root.pane.resetting || root.relayout ? null : displacedTransition

			ScrollBar.vertical: ThinScrollBar {}
		}

		Transition {
			id: addTransition

			ParallelAnimation {
				NumberAnimation {
					property: "opacity"
					from: 0
					to: 1
					duration: Motion.medium
				}
				NumberAnimation {
					property: "scale"
					from: 0.82
					to: 1
					duration: Motion.long
					easing.type: Easing.BezierSpline
					easing.bezierCurve: Motion.spatial
				}
			}
		}

		Transition {
			id: removeTransition

			ParallelAnimation {
				NumberAnimation {
					property: "opacity"
					to: 0
					duration: Motion.short
				}
				NumberAnimation {
					property: "scale"
					to: 0.8
					duration: Motion.medium
					easing.type: Easing.BezierSpline
					easing.bezierCurve: Motion.accel
				}
			}
		}

		Transition {
			id: displacedTransition

			NumberAnimation {
				properties: "x,y"
				duration: Motion.long
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.spatial
			}
			// a card that was mid-entrance or mid-exit ends whole
			NumberAnimation {
				properties: "opacity,scale"
				to: 1
				duration: Motion.short
			}
		}

		Component {
			id: cardDelegate

			FileCard {
				view: root
				pane: root.pane
				showFolder: root.showFolder
				entering: root.entering
				width: root.cellW
				height: root.cellH
			}
		}

		Component {
			id: rowDelegate

			FileRow {
				view: root
				pane: root.pane
				whenWidth: root.whenW
				sizeWidth: root.sizeW
				kindWidth: root.kindW
				showFolder: root.showFolder
				entering: root.entering
				width: root.cellW
				height: root.cellH
			}
		}

		// ── in groups: a header, then the cards row by row ─────────────────
		ListView {
			id: groupedView

			readonly property var rows: root.grouped ? Listing.rowsOf(root.pane.rows, root.columns) : []
			// where each row starts, for the band and for keeping a card in view
			readonly property var offsets: {
				const out = [];
				let y = 0;
				for (const row of groupedView.rows) {
					out.push(y);
					y += row.header ? root.headerH : root.cellH;
				}
				return out;
			}

			anchors.fill: parent
			visible: root.grouped
			interactive: false
			clip: true
			topMargin: 2
			bottomMargin: 96
			leftMargin: root.pad
			rightMargin: root.pad
			cacheBuffer: Math.max(0, root.cellH * 2)
			model: groupedView.rows
			boundsBehavior: Flickable.StopAtBounds

			ScrollBar.vertical: ThinScrollBar {}

			delegate: Item {
				id: line

				required property var modelData
				required property int index

				width: root.usable
				height: line.modelData.header ? root.headerH : root.cellH

				Row {
					visible: line.modelData.header
					anchors.left: parent.left
					anchors.leftMargin: 6
					anchors.bottom: parent.bottom
					anchors.bottomMargin: 10
					spacing: 8

					Text {
						text: line.modelData.title
						color: Theme.text
						font.family: Theme.fontFamily
						font.pixelSize: Theme.size.title
						font.weight: Font.DemiBold
					}

					Rectangle {
						anchors.verticalCenter: parent.verticalCenter
						width: countLabel.implicitWidth + 12
						height: 18
						radius: 9
						color: Theme.layer2

						Text {
							id: countLabel

							anchors.centerIn: parent
							text: String(line.modelData.count)
							color: Theme.textMuted
							font.family: Theme.fontFamily
							font.pixelSize: Theme.size.tiny
							font.weight: Font.DemiBold
						}
					}
				}

				Repeater {
					model: line.modelData.header ? [] : line.modelData.indexes

					delegate: Loader {
						id: cell

						required property int modelData
						required property int index
						readonly property var row: root.pane.rows[cell.modelData] ?? null

						x: cell.index * root.cellW
						width: root.cellW
						height: root.cellH
						active: !!cell.row
						sourceComponent: root.list ? groupedRow : groupedCard

						Component {
							id: groupedCard

							FileCard {
								index: cell.modelData
								path: cell.row.path
								name: cell.row.name
								dir: cell.row.dir
								link: cell.row.link
								size: cell.row.size
								mtime: cell.row.mtime
								mime: cell.row.mime
								hidden: cell.row.hidden
								thumb: cell.row.thumb
								canThumb: cell.row.canThumb
								text: cell.row.text
								kind: cell.row.kind
								folder: cell.row.folder
								view: root
								pane: root.pane
								showFolder: root.showFolder
								entering: root.entering
							}
						}

						Component {
							id: groupedRow

							FileRow {
								index: cell.modelData
								path: cell.row.path
								name: cell.row.name
								dir: cell.row.dir
								link: cell.row.link
								size: cell.row.size
								mtime: cell.row.mtime
								mime: cell.row.mime
								hidden: cell.row.hidden
								thumb: cell.row.thumb
								canThumb: cell.row.canThumb
								text: cell.row.text
								kind: cell.row.kind
								folder: cell.row.folder
								view: root
								pane: root.pane
								whenWidth: root.whenW
								sizeWidth: root.sizeW
								kindWidth: root.kindW
								showFolder: root.showFolder
								entering: root.entering
							}
						}
					}
				}
			}
		}

		// ── the band drawn over empty space ────────────────────────────────
		Rectangle {
			id: band

			visible: pointer.banding
			x: Math.min(pointer.bandStart.x, pointer.bandEnd.x)
			y: Math.min(pointer.bandStart.y, pointer.bandEnd.y) - root.flick.contentY
			width: Math.abs(pointer.bandEnd.x - pointer.bandStart.x)
			height: Math.abs(pointer.bandEnd.y - pointer.bandStart.y)
			radius: Theme.radius.small
			color: Qt.alpha(Theme.primary, 0.12)
			border.width: 1
			border.color: Qt.alpha(Theme.primary, 0.6)
		}

		// ── the pointer ────────────────────────────────────────────────────
		MouseArea {
			id: pointer

			property int pressIndex: -1
			property point pressAt: Qt.point(0, 0)
			property bool banding: false
			// the band in content coordinates (x in the view, y with the scroll)
			property point bandStart: Qt.point(0, 0)
			property point bandEnd: Qt.point(0, 0)
			property var bandBase: ({})
			property bool dragging: false
			property bool deselectOnRelease: false
			property real lastX: 0
			property real lastY: 0

			anchors.fill: parent
			hoverEnabled: true
			acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton | Qt.BackButton | Qt.ForwardButton
			preventStealing: true
			drag.threshold: 6

			function inRename(mouse) {
				if (root.pane.renaming === "") return false;
				const index = root.pane.rows.findIndex(row => row.path === root.pane.renaming);
				const item = root.itemOf(index);
				if (!item?.nameArea) return false;
				const p = item.nameArea.mapFromItem(pointer, mouse.x, mouse.y);
				return p.x >= -4 && p.y >= -4 && p.x <= item.nameArea.width + 4 && p.y <= item.nameArea.height + 4;
			}

			onPressed: mouse => {
				root.focusRequested();
				root.keyboard = false;
				if (pointer.inRename(mouse)) {
					mouse.accepted = false;
					return;
				}
				if (root.pane.renaming !== "") root.pane.renaming = "";
				if (mouse.button === Qt.BackButton) {
					root.pane.goBack();
					return;
				}
				if (mouse.button === Qt.ForwardButton) {
					root.pane.goForward();
					return;
				}
				const index = root.indexAt(mouse.x, mouse.y);
				pointer.pressIndex = index;
				pointer.pressAt = Qt.point(mouse.x, mouse.y);
				pointer.deselectOnRelease = false;
				const ctrl = (mouse.modifiers & Qt.ControlModifier) !== 0;
				const shift = (mouse.modifiers & Qt.ShiftModifier) !== 0;
				if (mouse.button === Qt.MiddleButton) {
					if (index >= 0 && root.pane.rows[index].dir) root.opened(index, true);
					return;
				}
				if (mouse.button === Qt.RightButton) {
					if (index >= 0 && !root.pane.isSelected(root.pane.rows[index].path)) root.pane.pick(index, "only");
					if (index < 0) root.pane.clearSelection();
					root.menuRequested(index, mouse.x, mouse.y + columnsHeader.height);
					return;
				}
				if (index >= 0) {
					const picked = root.pane.isSelected(root.pane.rows[index].path);
					if (shift) root.pane.pick(index, "range");
					else if (ctrl) root.pane.pick(index, "toggle");
					else if (!picked) root.pane.pick(index, "only");
					else {
						root.pane.current = index;
						pointer.deselectOnRelease = root.pane.selectionCount > 1;
					}
					pointer.drag.target = root.pane.isSelected(root.pane.rows[index].path) ? ghost : null;
					if (pointer.drag.target) root.prepareDrag(mouse.x, mouse.y);
				} else {
					pointer.drag.target = null;
					if (!ctrl && !shift) root.pane.clearSelection();
					pointer.bandBase = (ctrl || shift) ? Object.assign({}, root.pane.selected) : {};
					pointer.bandStart = Qt.point(mouse.x, mouse.y + root.flick.contentY);
					pointer.bandEnd = pointer.bandStart;
				}
			}

			onPositionChanged: mouse => {
				pointer.lastX = mouse.x;
				pointer.lastY = mouse.y;
				if (!pointer.pressed) {
					root.hoveredIndex = root.indexAt(mouse.x, mouse.y);
					return;
				}
				if (pointer.pressIndex < 0 && (mouse.buttons & Qt.LeftButton)) {
					if (!pointer.banding && Math.hypot(mouse.x - pointer.pressAt.x, mouse.y - pointer.pressAt.y) > 4) pointer.banding = true;
					if (pointer.banding) {
						pointer.bandEnd = Qt.point(Math.max(0, Math.min(root.width, mouse.x)), mouse.y + root.flick.contentY);
						root.bandSelect();
						edgeScroll.speed = mouse.y < 36 ? -1 : (mouse.y > pointer.height - 36 ? 1 : 0);
					}
				}
			}

			onReleased: mouse => {
				edgeScroll.speed = 0;
				if (pointer.banding) {
					pointer.banding = false;
					return;
				}
				if (pointer.deselectOnRelease && !pointer.drag.active && pointer.pressIndex >= 0) root.pane.pick(pointer.pressIndex, "only");
				// a single click opens, when the settings say so (not with Ctrl or Shift)
				const plain = (mouse.modifiers & (Qt.ControlModifier | Qt.ShiftModifier)) === 0;
				if (FileLibrary.setting("singleClick") && plain && mouse.button === Qt.LeftButton && !pointer.drag.active && pointer.pressIndex >= 0
					&& Math.hypot(mouse.x - pointer.pressAt.x, mouse.y - pointer.pressAt.y) < 6 && root.indexAt(mouse.x, mouse.y) === pointer.pressIndex)
					root.opened(pointer.pressIndex, false);
				pointer.drag.target = null;
			}

			onCanceled: {
				pointer.banding = false;
				edgeScroll.speed = 0;
			}

			onDoubleClicked: mouse => {
				if (mouse.button !== Qt.LeftButton || FileLibrary.setting("singleClick")) return;
				const index = root.indexAt(mouse.x, mouse.y);
				if (index >= 0) root.opened(index, false);
			}

			onExited: root.hoveredIndex = -1

			onWheel: wheel => {
				if (wheel.modifiers & Qt.ControlModifier) {
					const step = wheel.angleDelta.y > 0 ? 16 : -16;
					FileLibrary.setView("", { cardSize: Math.max(110, Math.min(340, root.cardSize + step)) });
					return;
				}
				if (wheel.pixelDelta.y !== 0) {
					scrollAnim.stop();
					root.flick.contentY = root.clampY(root.flick.contentY - wheel.pixelDelta.y);
				} else {
					root.scrollBy(-wheel.angleDelta.y / 120 * Math.max(90, root.cellH * 0.7));
				}
			}
		}

		// ── things dropped here ────────────────────────────────────────────
		DropArea {
			id: drops

			anchors.fill: parent

			// a collection, a tag or a shelf takes files without moving them
			readonly property bool gathers: ["collection", "tag", "shelf"].includes(root.pane.location.kind)

			function target() {
				if (root.dropIndex >= 0) return root.pane.rows[root.dropIndex]?.path ?? "";
				return root.pane.isFolder && root.pane.writable ? root.pane.location.path : "";
			}

			onEntered: drag => {
				const own = drag.source === ghost;
				drag.accepted = true;
				drops.track(drag.x, drag.y, own);
			}
			onPositionChanged: drag => drops.track(drag.x, drag.y, drag.source === ghost)
			onExited: {
				root.dropIndex = -1;
				root.dropOnPlace = false;
				edgeScroll.speed = 0;
				springTimer.stop();
			}
			onDropped: drop => {
				const into = drops.target();
				const index = root.dropIndex;
				root.dropIndex = -1;
				root.dropOnPlace = false;
				edgeScroll.speed = 0;
				springTimer.stop();
				if (index < 0 && drops.gathers && drop.source !== ghost) {
					drop.acceptProposedAction();
					drops.gather(drop);
					return;
				}
				// dropped where it came from: nothing to do
				if (into === "" || (drop.source === ghost && index < 0)) return;
				if (index >= 0 && drop.source === ghost && root.pane.isSelected(root.pane.rows[index].path)) return;
				drop.acceptProposedAction();
				Files.dropInto(into, drop, "auto");
			}

			function gather(drop) {
				const loc = root.pane.location;
				const paths = (drop.urls ?? []).map(url => String(url)).filter(url => url.startsWith("file://")).map(url => decodeURIComponent(url.slice(7)));
				if (loc.kind === "shelf") {
					Shelf.addDrop(loc.id, drop);
					Sounds.play("pinned");
				} else if (paths.length === 0) {
					return;
				} else if (loc.kind === "collection") {
					FileLibrary.addToCollection(loc.id, paths);
				} else if (loc.kind === "tag" && !paths.every(path => FileLibrary.hasTag(path, loc.id))) {
					FileLibrary.toggleTag(paths.filter(path => !FileLibrary.hasTag(path, loc.id)), loc.id);
				}
			}

			function track(x, y, own) {
				const index = root.indexAt(x, y);
				const row = index >= 0 ? root.pane.rows[index] : null;
				const next = row && row.dir && !(own && root.pane.isSelected(row.path)) ? index : -1;
				if (next !== root.dropIndex) {
					root.dropIndex = next;
					if (next >= 0) springTimer.restart();
					else springTimer.stop();
				}
				root.dropOnPlace = next < 0 && !own && (drops.gathers || (root.pane.isFolder && root.pane.writable));
				edgeScroll.speed = y < 40 ? -1 : (y > drops.height - 40 ? 1 : 0);
			}
		}

		// the place itself takes what is held over it
		Rectangle {
			anchors.fill: parent
			anchors.margins: 4
			radius: Theme.radius.large
			color: Qt.alpha(Theme.primary, root.dropOnPlace ? 0.05 : 0)
			border.width: 2
			border.color: Qt.alpha(Theme.primary, root.dropOnPlace ? 0.5 : 0)

			Behavior on color {
				ColorAnim {}
			}
			Behavior on border.color {
				ColorAnim {}
			}
		}

		// a folder held under a drop for a moment opens, the drag goes on
		Timer {
			id: springTimer

			interval: 850
			onTriggered: {
				const row = root.pane.rows[root.dropIndex];
				if (!row?.dir) return;
				Sounds.play("select");
				root.dropIndex = -1;
				root.pane.openFolder(row.path);
			}
		}

		// near the top or the bottom a band or a drag scrolls along
		Timer {
			id: edgeScroll

			property int speed: 0
			interval: 16
			repeat: true
			running: edgeScroll.speed !== 0
			onTriggered: {
				scrollAnim.stop();
				root.flick.contentY = root.clampY(root.flick.contentY + edgeScroll.speed * 14);
				if (pointer.banding) {
					pointer.bandEnd = Qt.point(pointer.bandEnd.x, pointer.lastY + root.flick.contentY);
					root.bandSelect();
				}
			}
		}
	}

	// the drag carries an invisible ghost; a picture of the stack follows the pointer
	Item {
		id: ghost

		width: 1
		height: 1

		Drag.dragType: Drag.Automatic
		Drag.active: pointer.drag.active
		Drag.supportedActions: Qt.CopyAction | Qt.MoveAction | Qt.LinkAction
		Drag.proposedAction: Qt.MoveAction
		Drag.hotSpot: Qt.point(42, 42)
		Drag.mimeData: root.dragData

		Drag.onDragFinished: dropAction => {
			pointer.drag.target = null;
		}
	}

	property var dragData: ({})

	DragStack {
		id: stack

		x: -400
		y: -400
	}

	function prepareDrag(x, y) {
		ghost.x = x;
		ghost.y = y + columnsHeader.height;
		const rows = root.pane.selectedRows();
		const paths = rows.map(row => row.path);
		root.dragData = {
			"text/uri-list": paths.map(path => Files.uri(path)).join("\r\n") + "\r\n",
			"text/plain": paths.join("\n")
		};
		stack.rows = rows.slice(0, 3);
		stack.count = rows.length;
		Qt.callLater(() => stack.grabToImage(result => ghost.Drag.imageSource = result.url, Qt.size(stack.width, stack.height)));
	}

	// ── geometry ───────────────────────────────────────────────────────────
	// the index of the card under a point of this view (stage coordinates), -1 for none
	function indexAt(x, y) {
		const flick = root.flick;
		const cx = x + flick.contentX;
		const cy = y + flick.contentY;
		if (!root.grouped) {
			const index = grid.indexAt(cx, cy);
			if (index < 0) return -1;
			// the gaps between cards are empty space
			const item = grid.itemAtIndex(index);
			if (item && !root.list) {
				const local = item.mapFromItem(pointer, x, y);
				if (local.x < 4 || local.y < 4 || local.x > item.width - 4 || local.y > item.height - 4) return -1;
			}
			return index;
		}
		const r = groupedView.indexAt(cx, cy);
		const row = groupedView.rows[r];
		if (!row || row.header) return -1;
		const column = Math.floor((cx - 0) / root.cellW);
		return column >= 0 && column < row.indexes.length ? row.indexes[column] : -1;
	}

	function itemOf(index) {
		if (index < 0) return null;
		if (!root.grouped) return grid.itemAtIndex(index);
		const r = groupedView.rows.findIndex(row => !row.header && row.indexes.includes(index));
		const line = groupedView.itemAtIndex(r);
		if (!line) return null;
		for (const child of line.children) {
			if (child.modelData === index && child.item) return child.item;
		}
		return null;
	}

	// the content y of a card's top and its height
	function spanOf(index) {
		if (!root.grouped) {
			const row = Math.floor(index / root.columns);
			return { y: row * root.cellH, h: root.cellH };
		}
		const r = groupedView.rows.findIndex(row => !row.header && row.indexes.includes(index));
		if (r < 0) return { y: 0, h: root.cellH };
		// a group's first row shows its header too
		const headerAbove = r > 0 && groupedView.rows[r - 1].header ? root.headerH : 0;
		return { y: groupedView.offsets[r] - headerAbove, h: root.cellH + headerAbove };
	}

	function minY() {
		return root.flick.originY - root.flick.topMargin;
	}

	function maxY() {
		const flick = root.flick;
		return Math.max(root.minY(), flick.originY + flick.contentHeight + flick.bottomMargin - flick.height);
	}

	function clampY(y) {
		return Math.max(root.minY(), Math.min(root.maxY(), y));
	}

	property real scrollTarget: 0

	function scrollTo(y, instant) {
		const target = root.clampY(y);
		if (instant) {
			scrollAnim.stop();
			root.flick.contentY = target;
			return;
		}
		root.scrollTarget = target;
		scrollAnim.to = target;
		scrollAnim.restart();
	}

	function scrollBy(dy) {
		const from = scrollAnim.running ? root.scrollTarget : root.flick.contentY;
		root.scrollTo(from + dy, false);
	}

	NumberAnimation {
		id: scrollAnim

		target: root.flick
		property: "contentY"
		duration: 280
		easing.type: Easing.OutCubic
	}

	function ensureVisible(index, instant) {
		if (index < 0) return;
		const span = root.spanOf(index);
		const top = span.y + root.flick.originY;
		const view = root.flick.height;
		const y = root.flick.contentY;
		if (top - 8 < y) root.scrollTo(top - 8, instant);
		else if (top + span.h + 8 > y + view) root.scrollTo(top + span.h + 8 - view, instant);
	}

	// keeps the hovered card right while the view scrolls under a still pointer
	Connections {
		target: root.flick

		function onContentYChanged() {
			if (pointer.containsMouse && !pointer.pressed) root.hoveredIndex = root.indexAt(pointer.lastX, pointer.lastY);
		}
	}

	function bandSelect() {
		const x1 = Math.min(pointer.bandStart.x, pointer.bandEnd.x);
		const x2 = Math.max(pointer.bandStart.x, pointer.bandEnd.x);
		const y1 = Math.min(pointer.bandStart.y, pointer.bandEnd.y);
		const y2 = Math.max(pointer.bandStart.y, pointer.bandEnd.y);
		const picked = [];
		const left = root.pad;
		const intersects = (cx, cy, w, h) => cx + w - 6 > x1 && cx + 6 < x2 && cy + h - 6 > y1 && cy + 6 < y2;
		if (!root.grouped) {
			const originY = grid.originY;
			const firstRow = Math.max(0, Math.floor((y1 - originY) / root.cellH));
			const lastRow = Math.floor((y2 - originY) / root.cellH);
			for (let r = firstRow; r <= lastRow; r += 1) {
				for (let c = 0; c < root.columns; c += 1) {
					const index = r * root.columns + c;
					if (index >= root.pane.rows.length) break;
					if (intersects(left + c * root.cellW, originY + r * root.cellH, root.cellW, root.cellH)) picked.push(index);
				}
			}
		} else {
			const originY = groupedView.originY;
			for (let r = 0; r < groupedView.rows.length; r += 1) {
				const row = groupedView.rows[r];
				if (row.header) continue;
				const top = originY + groupedView.offsets[r];
				if (top > y2) break;
				if (top + root.cellH < y1) continue;
				row.indexes.forEach((index, c) => {
					if (intersects(left + c * root.cellW, top, root.cellW, root.cellH)) picked.push(index);
				});
			}
		}
		const next = Object.assign({}, pointer.bandBase);
		for (const index of picked) next[root.pane.rows[index].path] = true;
		root.pane.commit(next);
	}

	// ── the keyboard (FilesView hands the keys here) ───────────────────────
	// key: left, right, up, down, home, end, pageup, pagedown
	function step(key, shift, ctrl) {
		root.keyboard = true;
		const count = root.pane.rows.length;
		if (count === 0) return;
		let index = root.pane.current;
		const columns = root.columns;
		const page = Math.max(1, Math.floor(root.flick.height / root.cellH)) * columns;
		if (index < 0) index = key === "end" ? count - 1 : 0;
		else if (!root.grouped) {
			switch (key) {
			case "left": index -= 1; break;
			case "right": index += 1; break;
			case "up": index -= columns; break;
			case "down": index = index + columns < count ? index + columns : (Math.floor(index / columns) < Math.floor((count - 1) / columns) ? count - 1 : index); break;
			case "home": index = 0; break;
			case "end": index = count - 1; break;
			case "pageup": index -= page; break;
			case "pagedown": index += page; break;
			}
		} else {
			const rows = groupedView.rows.filter(row => !row.header);
			const r = rows.findIndex(row => row.indexes.includes(index));
			const c = r >= 0 ? rows[r].indexes.indexOf(index) : 0;
			const at = (rr, cc) => rows[rr].indexes[Math.min(cc, rows[rr].indexes.length - 1)];
			switch (key) {
			case "left": index -= 1; break;
			case "right": index += 1; break;
			case "up": if (r > 0) index = at(r - 1, c); break;
			case "down": if (r < rows.length - 1) index = at(r + 1, c); break;
			case "home": index = 0; break;
			case "end": index = count - 1; break;
			case "pageup": index = at(Math.max(0, r - Math.floor(root.flick.height / root.cellH)), c); break;
			case "pagedown": index = at(Math.min(rows.length - 1, r + Math.floor(root.flick.height / root.cellH)), c); break;
			}
		}
		index = Math.max(0, Math.min(count - 1, index));
		if (shift) root.pane.pick(index, "range");
		else if (ctrl) root.pane.current = index;
		else root.pane.pick(index, "only");
		root.ensureVisible(index, false);
	}

	// ── what shows instead of cards ────────────────────────────────────────
	// a slow folder: placeholder cards breathing
	Grid {
		anchors.top: columnsHeader.bottom
		anchors.left: parent.left
		anchors.leftMargin: root.pad + 4
		anchors.topMargin: 12
		columns: root.columns
		visible: opacity > 0
		opacity: root.pane.loading && root.pane.rows.length === 0 ? 1 : 0
		columnSpacing: 0
		rowSpacing: 0

		Behavior on opacity {
			Anim {}
		}

		Repeater {
			model: root.pane.loading ? Math.min(root.list ? 10 : root.columns * 2, 18) : 0

			delegate: Item {
				id: skeleton

				required property int index

				width: root.cellW
				height: root.cellH

				Rectangle {
					anchors.fill: parent
					anchors.margins: root.list ? 2 : 10
					radius: Theme.radius.large
					color: Theme.layer1

					SequentialAnimation on opacity {
						loops: Animation.Infinite
						running: skeleton.visible

						PauseAnimation {
							duration: skeleton.index * 60
						}
						NumberAnimation {
							from: 1
							to: 0.4
							duration: 700
							easing.type: Easing.InOutSine
						}
						NumberAnimation {
							from: 0.4
							to: 1
							duration: 700
							easing.type: Easing.InOutSine
						}
					}
				}
			}
		}
	}

	EmptyPlace {
		id: empty

		anchors.centerIn: parent
		anchors.verticalCenterOffset: -30
		visible: opacity > 0
		opacity: root.pane.rows.length === 0 && root.pane.settled && !root.pane.loading && root.pane.location.kind !== "home" ? 1 : 0
		pane: root.pane

		Behavior on opacity {
			Anim {
				duration: Motion.medium
			}
		}
	}
}
