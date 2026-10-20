pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.style.theme
import qs.core.services
import qs.style.widgets
import qs.core.views.launcher
import qs.core.views

// Notes and task boards pinned to the desktop (launcher >todo → pin; a note
// made for a task pins itself). One transparent layer on the laptop's own
// screen (eDP; the primary one without it) between wallpaper and windows; only the cards take input, and the
// keyboard only while something is typed in one. Cards are dragged by their
// header, folded to it with its chevron (or a double click) and resized at
// their bottom right corner (the text grows with the width); all of it
// persists in Todos.pins. A link to something pinned lets its card flash,
// with the cards above the windows for a moment. With todo-links on, a line
// joins each pinned note to its tasks on the pinned boards.
PanelWindow {
	id: root

	// cards currently shown; their rectangles form the input mask
	property var cards: []
	// fields that are being typed in (TodoTaskRow, TodoGroup count themselves here)
	property int typing: 0
	// above the windows while a card flashes
	property bool peeking: false
	readonly property bool linking: Plugins.on("todo-links")
	// [{ x1, y1, x2, y2, faded }] from a task (on a board) to its note
	property var links: []

	screen: Quickshell.screens.find(screen => String(screen.name || "").startsWith("eDP")) ?? Popups.primaryScreen
	visible: Todos.pins.length > 0
	anchors.top: true
	anchors.bottom: true
	anchors.left: true
	anchors.right: true
	exclusionMode: ExclusionMode.Ignore
	color: "transparent"
	WlrLayershell.namespace: "shell-todo"
	WlrLayershell.layer: root.peeking ? WlrLayer.Top : WlrLayer.Bottom
	WlrLayershell.keyboardFocus: root.typing > 0 ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
	mask: Region {
		regions: root.cards.map(card => card.region)
	}

	function cardOf(key) {
		return root.cards.find(card => card.key === key) ?? null;
	}

	// ── lines between notes and tasks ─────────────────────────────────────
	// lines follow for a moment after anything moved
	function nudge() {
		if (!root.linking) return;
		settle.restart();
		tick.start();
	}

	function computeLinks() {
		if (!root.linking) {
			if (root.links.length > 0) root.links = [];
			return;
		}
		const out = [];
		const boards = root.cards.filter(card => card.boardCard);
		for (const note of root.cards.filter(card => !card.boardCard)) {
			for (const task of Todos.tasksOf(Todos.displayName(note.key))) {
				for (const board of boards) {
					if (board.group !== "" && board.group !== task.group) continue;
					// the group's own board is enough
					if (board.group === "" && boards.some(other => other.group === task.group)) continue;
					const from = board.pointOf(task.key);
					const right = note.x + note.width / 2 > board.x + board.width / 2;
					out.push({
						x1: right ? board.x + board.width : board.x,
						y1: from.y,
						x2: right ? note.x : note.x + note.width,
						y2: note.y + note.headerMiddle,
						faded: from.faded
					});
				}
			}
		}
		if (JSON.stringify(out) !== JSON.stringify(root.links)) root.links = out;
	}

	onLinkingChanged: {
		root.computeLinks();
		root.nudge();
	}
	onLinksChanged: lines.requestPaint()

	Timer {
		id: tick

		interval: 33
		repeat: true
		onTriggered: root.computeLinks()
	}

	Timer {
		id: settle

		interval: 800
		onTriggered: tick.stop()
	}

	// what is not seen as a move (a row that grows) still settles
	Timer {
		interval: 1200
		repeat: true
		running: root.linking && root.visible
		onTriggered: root.computeLinks()
	}

	Connections {
		target: Todos

		function onTasksTextChanged() {
			root.nudge();
		}
		function onFoldsChanged() {
			root.nudge();
		}
		function onPinsChanged() {
			root.nudge();
		}
		function onHighlightRequested(pinKey, taskKey) {
			const card = root.cardOf(pinKey);
			if (!card) return;
			root.peeking = true;
			unpeek.restart();
			card.flash(taskKey);
		}
	}

	Timer {
		id: unpeek

		interval: 2600
		onTriggered: root.peeking = false
	}

	Canvas {
		id: lines

		property color tint: Theme.primary

		anchors.fill: parent
		opacity: root.linking ? 1 : 0
		onTintChanged: lines.requestPaint()

		Behavior on opacity {
			Anim {}
		}

		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			for (const link of root.links) {
				const bend = Math.max(48, Math.abs(link.x2 - link.x1) / 2);
				const direction = link.x2 >= link.x1 ? 1 : -1;
				const tint = lines.tint;
				const color = `rgba(${Math.round(tint.r * 255)}, ${Math.round(tint.g * 255)}, ${Math.round(tint.b * 255)}, ${link.faded ? 0.28 : 0.6})`;
				ctx.strokeStyle = color;
				ctx.fillStyle = color;
				ctx.lineWidth = 2;
				ctx.setLineDash(link.faded ? [5, 5] : []);
				ctx.beginPath();
				ctx.moveTo(link.x1, link.y1);
				ctx.bezierCurveTo(link.x1 + bend * direction, link.y1, link.x2 - bend * direction, link.y2, link.x2, link.y2);
				ctx.stroke();
				for (const point of [[link.x1, link.y1], [link.x2, link.y2]]) {
					ctx.beginPath();
					ctx.arc(point[0], point[1], 4, 0, Math.PI * 2);
					ctx.fill();
				}
			}
		}
	}

	SyncedModel {
		id: pinModel
	}

	readonly property var pinKeys: Todos.pins.map(pin => ({ key: pin.path }))

	onPinKeysChanged: pinModel.sync(root.pinKeys)
	Component.onCompleted: pinModel.sync(root.pinKeys)

	Repeater {
		model: pinModel

		onItemAdded: (index, item) => root.cards = root.cards.concat([item])
		onItemRemoved: (index, item) => root.cards = root.cards.filter(card => card !== item)

		delegate: Item {
			id: card

			required property string key
			readonly property bool boardCard: card.key === Todos.overviewKey || Todos.isGroupKey(card.key)
			readonly property string group: Todos.isGroupKey(card.key) ? Todos.groupOfKey(card.key) : ""
			readonly property var pin: Todos.pins.find(entry => entry.path === card.key) ?? { x: 80, y: 90, w: 0, h: 0, collapsed: false }
			readonly property bool collapsed: card.pin.collapsed === true
			readonly property real pinX: Math.max(0, Math.min(root.width - card.width, card.pin.x))
			readonly property real pinY: Math.max(0, Math.min(root.height - card.height, card.pin.y))
			readonly property real pinW: card.pin.w > 0 ? card.pin.w : card.baseWidth
			// 0: as tall as the content, up to maxAuto
			readonly property real pinH: card.pin.h > 0 ? card.pin.h : 0
			readonly property real baseWidth: 310
			// the text grows with the width
			readonly property real zoom: card.width / card.baseWidth
			readonly property real maxAuto: 520 * card.zoom
			readonly property real headerHeight: card.px(34)
			readonly property real headerMiddle: card.px(12) + card.headerHeight / 2
			readonly property real contentSize: card.boardCard ? (boardLoader.item?.contentHeight ?? 0) : noteColumn.implicitHeight
			readonly property real fullHeight: card.pinH > 0 ? card.pinH : card.autoHeight()
			readonly property Region region: Region {
				x: card.x
				y: card.y
				width: card.width
				height: card.height
				radius: Theme.radius.huge
			}

			function px(value) {
				return Math.max(1, Math.round(value * card.zoom));
			}

			function autoHeight() {
				return card.headerHeight + card.px(8) + Math.min(card.contentSize, card.maxAuto) + card.px(24);
			}

			// where a line to a task starts: its row (clamped to what shows), else the header
			function pointOf(taskKey) {
				const board = boardLoader.item;
				const top = card.y + card.headerMiddle;
				if (!board || card.collapsed) return { y: top, faded: true };
				const anchor = board.anchorOf(taskKey);
				if (!anchor) return { y: top, faded: true };
				const at = anchor.mapToItem(card, 0, Math.min(anchor.height, card.px(30)) / 2).y;
				const low = body.y + card.px(12);
				const high = body.y + card.px(12) + body.height;
				const inside = at >= low && at <= high;
				return { y: card.y + Math.max(low, Math.min(high, at)), faded: !inside || anchor === board.groupItem(Todos.findTask(taskKey)?.group ?? "")?.headerItem };
			}

			function flash(taskKey) {
				flashAnim.restart();
				if (taskKey === "" || !boardLoader.item) return;
				if (card.collapsed) Todos.setCollapsed(card.key, false);
				boardLoader.item.reveal(taskKey);
			}

			x: card.pinX
			y: card.pinY
			width: card.pinW
			height: card.collapsed ? card.headerHeight + card.px(24) : card.fullHeight
			scale: 0.9
			opacity: 0

			onXChanged: root.nudge()
			onYChanged: root.nudge()
			onWidthChanged: root.nudge()
			onHeightChanged: root.nudge()

			Behavior on height {
				enabled: !resizeArea.pressed
				SpatialAnim {
					duration: Motion.long
				}
			}

			Component.onCompleted: cardIn.start()

			ParallelAnimation {
				id: cardIn

				SpatialAnim {
					target: card
					property: "scale"
					to: 1
				}
				Anim {
					target: card
					property: "opacity"
					to: 1
				}
			}

			Connections {
				target: boardLoader.item?.flickable ?? null

				function onContentYChanged() {
					root.nudge();
				}
			}

			Connections {
				target: boardLoader.item ?? null

				function onSelectedKeyChanged() {
					root.nudge();
				}
			}

			HoverHandler {
				id: cardHover
			}

			RectangularShadow {
				anchors.fill: surface
				radius: surface.radius
				blur: 26
				spread: -4
				offset.y: 8
				color: Qt.alpha(Theme.shadow, 0.35)
			}

			Rectangle {
				id: surface

				anchors.fill: parent
				radius: Theme.radius.huge
				color: Qt.alpha(Theme.base, 0.9)
			}

			// the flash of a link that led here
			Rectangle {
				id: glow

				anchors.fill: parent
				anchors.margins: -3
				radius: Theme.radius.huge + 3
				color: "transparent"
				border.width: 3
				border.color: Theme.primary
				opacity: 0
			}

			SequentialAnimation {
				id: flashAnim

				ParallelAnimation {
					SpatialAnim {
						target: card
						property: "scale"
						to: 1.04
						duration: Motion.medium
					}
					Anim {
						target: glow
						property: "opacity"
						to: 1
						duration: Motion.short
					}
				}
				SpatialAnim {
					target: card
					property: "scale"
					to: 1
					duration: Motion.long
				}
				SequentialAnimation {
					loops: 2
					Anim {
						target: glow
						property: "opacity"
						to: 0.25
						duration: Motion.long
					}
					Anim {
						target: glow
						property: "opacity"
						to: 1
						duration: Motion.long
					}
				}
				Anim {
					target: glow
					property: "opacity"
					to: 0
					duration: Motion.extraLong
				}
			}

			ColumnLayout {
				id: column

				x: card.px(12)
				y: card.px(12)
				width: card.width - card.px(24)
				height: card.height - card.px(24)
				spacing: card.px(8)

				Item {
					Layout.fillWidth: true
					implicitHeight: card.headerHeight

					MouseArea {
						id: dragArea

						anchors.fill: parent
						cursorShape: dragArea.drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
						drag.target: card
						drag.minimumX: 0
						drag.minimumY: 0
						drag.maximumX: root.width - card.width
						drag.maximumY: root.height - card.height
						drag.threshold: 2
						onDoubleClicked: Todos.setCollapsed(card.key, !card.collapsed)
						onReleased: {
							if (card.x === card.pinX && card.y === card.pinY) return;
							Todos.movePin(card.key, card.x, card.y);
							card.x = Qt.binding(() => card.pinX);
							card.y = Qt.binding(() => card.pinY);
						}
					}

					RowLayout {
						anchors.fill: parent
						anchors.leftMargin: card.px(2)
						spacing: card.px(6)

						IconButton {
							Layout.preferredWidth: card.px(26)
							Layout.preferredHeight: card.px(26)
							icon: "chevron_down"
							iconSize: card.px(16)
							iconColor: Theme.textSubtle
							rotation: card.collapsed ? -90 : 0
							onClicked: Todos.setCollapsed(card.key, !card.collapsed)

							Behavior on rotation {
								SpatialAnim {
									duration: Motion.medium
								}
							}
						}

						Glyph {
							icon: card.key === Todos.overviewKey ? "checkbox_marked_circle_outline" : (card.group === Todos.inbox ? "inbox_outline" : (card.group !== "" ? "folder_outline" : "note_text_outline"))
							size: card.px(18)
							color: Theme.primary
						}

						StyledText {
							Layout.fillWidth: true
							text: Todos.displayName(card.key)
							elide: Text.ElideRight
							font.pixelSize: card.px(Theme.size.title)
							font.weight: Font.Bold
						}

						StyledText {
							visible: card.boardCard
							text: card.group === "" ? Todos.openTasks.length : (Todos.findGroup(card.group)?.open ?? 0)
							tone: Theme.textSubtle
							tabular: true
							font.pixelSize: card.px(Theme.size.label)
							font.weight: Font.DemiBold
						}

						IconButton {
							Layout.preferredWidth: card.px(28)
							Layout.preferredHeight: card.px(28)
							visible: !card.collapsed
							icon: card.boardCard ? "plus" : "pencil"
							iconSize: card.px(15)
							opacity: cardHover.hovered ? 1 : 0
							onClicked: {
								if (!card.boardCard) {
									Todos.openEditor(card.key, -1);
									return;
								}
								const group = boardLoader.item?.groupItem(card.group || Todos.inbox);
								if (group) group.startAdding();
							}

							Behavior on opacity {
								Anim {
									duration: Motion.short
								}
							}
						}

						IconButton {
							Layout.preferredWidth: card.px(28)
							Layout.preferredHeight: card.px(28)
							icon: "pin_off"
							iconSize: card.px(15)
							opacity: cardHover.hovered ? 1 : 0.4
							onClicked: Todos.unpin(card.key)

							Behavior on opacity {
								Anim {
									duration: Motion.short
								}
							}
						}
					}
				}

				Item {
					id: body

					Layout.fillWidth: true
					Layout.fillHeight: true
					implicitHeight: Math.min(card.contentSize, card.maxAuto)
					opacity: card.collapsed ? 0 : 1
					visible: opacity > 0.01

					Behavior on opacity {
						Anim {}
					}

					// a board: every group or one
					Loader {
						id: boardLoader

						anchors.fill: parent
						active: card.boardCard
						sourceComponent: TodoBoard {
							filter: card.group
							headless: card.group !== ""
							compact: true
							zoom: card.zoom
						}
					}

					// a note
					Flickable {
						id: noteFlick

						anchors.fill: parent
						visible: !card.boardCard
						contentHeight: noteColumn.implicitHeight
						clip: true
						boundsBehavior: Flickable.StopAtBounds
						interactive: contentHeight > height

						ColumnLayout {
							id: noteColumn

							width: noteFlick.width
							spacing: card.px(8)

							TodoNoteLinks {
								Layout.fillWidth: true
								name: card.boardCard ? "" : Todos.displayName(card.key)
								zoom: card.zoom
								compact: true
							}

							TodoDocument {
								Layout.fillWidth: true
								path: card.boardCard ? "" : card.key
								compact: true
								zoom: card.zoom
							}
						}
					}
				}
			}

			// bottom right corner: drag to resize
			Item {
				id: resizeHandle

				anchors.right: parent.right
				anchors.bottom: parent.bottom
				width: 22
				height: 22
				visible: !card.collapsed
				opacity: cardHover.hovered || resizeArea.pressed ? 1 : 0

				Behavior on opacity {
					Anim {
						duration: Motion.short
					}
				}

				Glyph {
					anchors.centerIn: parent
					icon: "resize_bottom_right"
					size: 14
					color: Theme.textSubtle
				}

				MouseArea {
					id: resizeArea

					property point start
					property size from

					anchors.fill: parent
					cursorShape: Qt.SizeFDiagCursor
					onPressed: mouse => {
						resizeArea.start = resizeArea.mapToItem(null, mouse.x, mouse.y);
						resizeArea.from = Qt.size(card.width, card.height);
					}
					onPositionChanged: mouse => {
						if (!resizeArea.pressed) return;
						const at = resizeArea.mapToItem(null, mouse.x, mouse.y);
						card.width = Math.max(200, Math.min(root.width - card.x, resizeArea.from.width + at.x - resizeArea.start.x));
						card.height = Math.max(120, Math.min(root.height - card.y, resizeArea.from.height + at.y - resizeArea.start.y));
					}
					onReleased: {
						Todos.resizePin(card.key, card.width, card.height);
						card.width = Qt.binding(() => card.pinW);
						card.height = Qt.binding(() => card.collapsed ? card.headerHeight + card.px(24) : card.fullHeight);
					}
				}
			}
		}
	}
}
