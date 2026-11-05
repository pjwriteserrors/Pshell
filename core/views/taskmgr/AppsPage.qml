pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.shelf

// Apps and processes: the column heads with what all of it takes, the list
// (apps with their processes, the shell, the background, the system – or
// every process, flat or as a tree), the row picked on the right.
Item {
	id: root

	signal focusSearch

	readonly property var columns: TaskManager.settings.columns ?? {}
	readonly property bool picked: TaskManager.selected !== "" && TaskManager.rows[TaskManager.selected] !== undefined

	function syncRows() {
		rows.sync(TaskManager.order);
	}

	Connections {
		target: TaskManager

		function onOrderChanged() {
			root.syncRows();
		}
	}

	Component.onCompleted: root.syncRows()

	KeyedModel {
		id: rows
	}

	// ── keys ───────────────────────────────────────────────────────────────
	function step(delta) {
		const order = TaskManager.order;
		if (order.length === 0) return;
		let index = order.indexOf(TaskManager.selected);
		index = index < 0 ? (delta > 0 ? 0 : order.length - 1) : Math.max(0, Math.min(order.length - 1, index + delta));
		TaskManager.select(order[index]);
		list.positionViewAtIndex(index, ListView.Contain);
	}

	function parentOf(key) {
		const order = TaskManager.order;
		const index = order.indexOf(key);
		const depth = TaskManager.rows[key]?.d ?? 0;
		for (let i = index - 1; i >= 0; i -= 1) {
			if ((TaskManager.rows[order[i]]?.d ?? 0) < depth) return order[i];
		}
		return "";
	}

	function handleKey(event) {
		const key = TaskManager.selected;
		const row = TaskManager.rows[key];
		switch (event.key) {
		case Qt.Key_Down:
			root.step(1);
			return true;
		case Qt.Key_Up:
			root.step(-1);
			return true;
		case Qt.Key_PageDown:
			root.step(10);
			return true;
		case Qt.Key_PageUp:
			root.step(-10);
			return true;
		case Qt.Key_Right:
			if (row?.x === 1) TaskManager.setExpanded(key, true);
			else root.step(1);
			return true;
		case Qt.Key_Left:
			if (row?.x === 2) TaskManager.setExpanded(key, false);
			else {
				const parent = root.parentOf(key);
				if (parent !== "") TaskManager.select(parent);
			}
			return true;
		case Qt.Key_Delete:
			if (!row || row.t === "section") return false;
			if (event.modifiers & Qt.ShiftModifier) TaskManager.kill(key);
			else TaskManager.end(key);
			return true;
		case Qt.Key_Space:
			if (!row || row.t === "section") return false;
			if (TaskManager.isPaused(key)) TaskManager.resume(key);
			else TaskManager.pause(key);
			return true;
		case Qt.Key_Return:
		case Qt.Key_Enter:
			if (row?.t === "section") TaskManager.toggleExpanded(key);
			else if ((row?.w ?? []).length > 0) {
				Niri.focusWindow(row.w[0]);
				TaskManager.close();
			} else if (row?.x) TaskManager.toggleExpanded(key);
			return true;
		}
		return false;
	}

	// ── the menu of a row ──────────────────────────────────────────────────
	property var menuEntries: []
	property real menuX: 0
	property real menuY: 0

	function openMenu(key, point) {
		const row = TaskManager.rows[key];
		if (!row || row.t === "section") return;
		TaskManager.select(key);
		const paused = TaskManager.isPaused(key);
		const windows = row.w ?? [];
		const entries = [];
		if (windows.length > 0) entries.push({ label: "Go to window", icon: "open_in_app", run: () => {
			Niri.focusWindow(windows[0]);
			TaskManager.close();
		} });
		entries.push({ label: paused ? "Resume" : "Pause", icon: paused ? "play" : "pause", run: () => paused ? TaskManager.resume(key) : TaskManager.pause(key) });
		entries.push({ label: TaskManager.watched[key] ? "Stop watching" : "Tell me when it ends", icon: "bell_ring_outline", run: () => TaskManager.setWatched(key, !TaskManager.watched[key]) });
		entries.push({ separator: true });
		for (const level of [["background", "Background", "tortoise"], ["low", "Low priority", "arrow_down"], ["normal", "Normal priority", "minus"], ["high", "High priority", "arrow_up"]])
			entries.push({ label: level[1], icon: level[2], run: () => TaskManager.setPriority(key, level[0]) });
		entries.push({ separator: true });
		if (row.t === "proc" || row.p) {
			entries.push({ label: "Copy command", icon: "content_copy", run: () => Quickshell.execDetached(["wl-copy", "--", row.s ?? ""]) });
			entries.push({ label: "Copy PID", icon: "pound", run: () => Quickshell.execDetached(["wl-copy", "--", String(row.p)]) });
		}
		entries.push({ label: "End", icon: "close", danger: true, run: () => TaskManager.end(key) });
		entries.push({ label: "Kill", icon: "close_octagon_outline", danger: true, run: () => TaskManager.kill(key) });
		root.menuEntries = entries;
		const local = list.mapToItem(root, point.x, point.y);
		root.menuX = local.x;
		root.menuY = local.y;
	}

	RowLayout {
		anchors.fill: parent
		spacing: 0

		ColumnLayout {
			Layout.fillWidth: true
			Layout.fillHeight: true
			spacing: 0

			// ── what all of it takes, and the sorting ───────────────────────
			RowLayout {
				Layout.fillWidth: true
				Layout.preferredHeight: 54
				Layout.leftMargin: 12
				Layout.rightMargin: 16
				Layout.fillHeight: false
				spacing: 0

				Head {
					Layout.fillWidth: true
					column: "name"
					label: TaskManager.mode === "apps" ? "Name" : "Process"
					value: ""
					alignLeft: true
				}

				Item {
					Layout.preferredWidth: 68
				}

				Head {
					visible: root.columns.cpu !== false
					column: "cpu"
					label: "CPU"
					value: TaskManager.percent(TaskManager.cpu, 0)
					heat: TaskManager.cpu
				}

				Head {
					visible: root.columns.mem !== false
					Layout.preferredWidth: 96
					column: "mem"
					label: "Memory"
					value: TaskManager.percent(TaskManager.memoryLevel, 0)
					heat: TaskManager.memoryLevel
				}

				Head {
					visible: root.columns.io !== false
					Layout.preferredWidth: 92
					column: "io"
					label: "Disk"
					value: Format.rate(TaskManager.diskRate)
					heat: Math.min(1, TaskManager.diskRate / 104857600)
				}

				Head {
					visible: root.columns.gpu !== false && TaskManager.hasGpu
					Layout.preferredWidth: 64
					column: "gpu"
					label: "GPU"
					value: TaskManager.percent(TaskManager.gpu, 0)
					heat: TaskManager.gpu
				}
			}

			Rectangle {
				Layout.fillWidth: true
				Layout.preferredHeight: 1
				color: Theme.outline
			}

			// what the update left behind
			Banner {
				Layout.fillWidth: true
				Layout.margins: 10
				Layout.bottomMargin: 0
				shown: TaskManager.oldLibs.length > 0
				icon: "update"
				text: TaskManager.oldLibs.length === 1 ? `${TaskManager.nameOf({ t: "group", kind: TaskManager.oldLibs[0].kind, i: TaskManager.oldLibs[0].icon, n: TaskManager.oldLibs[0].name })} still runs the version from before the update`
					: `${TaskManager.oldLibs.length} apps still run the version from before the update`
				action: "Restart all"
				onActivated: TaskManager.oldLibs.slice().forEach(item => TaskManager.restartApp(item))
			}

			Banner {
				Layout.fillWidth: true
				Layout.margins: 10
				Layout.bottomMargin: 0
				shown: TaskManager.leftovers > 0
				icon: "broom"
				text: TaskManager.leftovers === 1 ? "One helper of an earlier shell still runs" : `${TaskManager.leftovers} helpers of an earlier shell still run`
				action: "End them"
				onActivated: TaskManager.cleanLeftovers()
			}

			ListView {
				id: list

				Layout.fillWidth: true
				Layout.fillHeight: true
				Layout.leftMargin: 6
				Layout.rightMargin: 6
				Layout.topMargin: 4
				clip: true
				model: rows
				spacing: 1
				boundsBehavior: Flickable.StopAtBounds
				cacheBuffer: 400
				reuseItems: false
				ScrollBar.vertical: ThinScrollBar {}

				// the order stays while the pointer is over the list
				HoverHandler {
					id: over

					onHoveredChanged: {
						if (over.hovered) {
							release.stop();
							TaskManager.hold = true;
						} else {
							release.restart();
						}
					}
				}

				Timer {
					id: release

					interval: 700
					onTriggered: TaskManager.hold = false
				}

				add: Transition {
					ParallelAnimation {
						NumberAnimation {
							property: "opacity"
							from: 0
							to: 1
							duration: Motion.medium
						}
						NumberAnimation {
							property: "x"
							from: -14
							to: 0
							duration: Motion.long
							easing.type: Easing.BezierSpline
							easing.bezierCurve: Motion.spatial
						}
					}
				}
				remove: Transition {
					ParallelAnimation {
						NumberAnimation {
							property: "opacity"
							to: 0
							duration: Motion.short
						}
						NumberAnimation {
							property: "x"
							to: 24
							duration: Motion.medium
							easing.type: Easing.BezierSpline
							easing.bezierCurve: Motion.accel
						}
					}
				}
				displaced: Transition {
					NumberAnimation {
						properties: "x,y"
						duration: Motion.long
						easing.type: Easing.BezierSpline
						easing.bezierCurve: Motion.spatial
					}
					NumberAnimation {
						property: "opacity"
						to: 1
						duration: Motion.short
					}
				}
				move: Transition {
					NumberAnimation {
						property: "y"
						duration: Motion.long
						easing.type: Easing.BezierSpline
						easing.bezierCurve: Motion.spatial
					}
				}

				delegate: ProcessRow {
					width: list.width - 8
					picked: TaskManager.selected === key
					onClicked: mouse => {
						if (section) {
							TaskManager.toggleExpanded(key);
							return;
						}
						TaskManager.select(TaskManager.selected === key ? "" : key);
					}
					onMiddleClicked: if (!section) TaskManager.end(key)
					onToggled: TaskManager.toggleExpanded(key)
					onMenuRequested: mouse => root.openMenu(key, mapToItem(list, mouse.x, mouse.y))
				}

				EmptyState {
					anchors.centerIn: parent
					visible: list.count === 0 && TaskManager.connected
					icon: TaskManager.filter !== "" ? "magnify_close" : "timer_sand"
					title: TaskManager.filter !== "" ? `Nothing called “${TaskManager.filter}”` : "Looking…"
				}

				Spinner {
					anchors.centerIn: parent
					width: 28
					height: 28
					visible: !TaskManager.connected
				}
			}
		}

		// ── the row picked ─────────────────────────────────────────────────
		Item {
			id: side

			Layout.fillHeight: true
			Layout.preferredWidth: root.picked ? Math.min(400, Math.max(320, root.width * 0.34)) : 0
			clip: true

			Behavior on Layout.preferredWidth {
				SpatialAnim {
					duration: Motion.long
				}
			}

			Rectangle {
				anchors.left: parent.left
				anchors.top: parent.top
				anchors.bottom: parent.bottom
				width: 1
				color: Theme.outline
			}

			DetailPane {
				x: 1
				width: Math.min(400, Math.max(320, root.width * 0.34)) - 1
				height: parent.height
				opacity: root.picked ? 1 : 0
				key: root.picked ? TaskManager.selected : ""

				Behavior on opacity {
					Anim {
						duration: Motion.medium
					}
				}
			}
		}
	}

	MouseArea {
		anchors.fill: parent
		visible: root.menuEntries.length > 0
		onPressed: root.menuEntries = []
	}

	ShelfMenu {
		id: menu

		x: Math.max(8, Math.min(root.width - menu.implicitWidth - 8, root.menuX))
		y: Math.max(8, Math.min(root.height - menu.implicitHeight - 8, root.menuY))
		visible: root.menuEntries.length > 0
		entries: root.menuEntries
		onDone: root.menuEntries = []
	}

	// a column head: what all of it takes, and whether the list is sorted by it
	component Head: Clickable {
		id: head

		property string column
		property string label
		property string value
		property real heat: 0
		property bool alignLeft: false
		readonly property bool sorted: TaskManager.sort === head.column

		Layout.preferredWidth: 80
		Layout.fillHeight: true
		Layout.topMargin: 6
		Layout.bottomMargin: 6
		radius: Theme.radius.medium
		onClicked: TaskManager.sortBy(head.column)

		Column {
			anchors.verticalCenter: parent.verticalCenter
			anchors.right: head.alignLeft ? undefined : parent.right
			anchors.left: head.alignLeft ? parent.left : undefined
			anchors.rightMargin: 10
			anchors.leftMargin: 32
			spacing: 0

			RollText {
				calm: true
				anchors.right: head.alignLeft ? undefined : parent.right
				visible: head.value !== ""
				text: head.value
				pixelSize: Theme.size.title
				weight: Font.DemiBold
				tone: head.heat > 0.9 ? Theme.danger : (head.heat > 0.75 ? Theme.warning : Theme.text)
				alignment: Qt.AlignRight
			}

			Row {
				anchors.right: head.alignLeft ? undefined : parent.right
				spacing: 3

				Glyph {
					anchors.verticalCenter: parent.verticalCenter
					icon: "menu_down"
					size: 14
					color: Theme.primary
					opacity: head.sorted ? 1 : 0
					rotation: TaskManager.desc ? 0 : 180

					Behavior on rotation {
						SpatialAnim {
							duration: Motion.medium
						}
					}
					Behavior on opacity {
						Anim {}
					}
				}

				StyledText {
					text: head.label
					tone: head.sorted ? Theme.primary : Theme.textMuted
					font.pixelSize: Theme.size.small
					font.weight: head.sorted ? Font.DemiBold : Font.Medium
				}
			}
		}
	}

	// a line over the list that offers one thing
	component Banner: Rectangle {
		id: banner

		property bool shown: false
		property string icon: ""
		property string text: ""
		property string action: ""
		signal activated

		Layout.preferredHeight: banner.shown ? 44 : 0
		Layout.topMargin: banner.shown ? 10 : 0
		visible: Layout.preferredHeight > 0.5
		opacity: banner.shown ? 1 : 0
		radius: Theme.radius.large
		color: Qt.alpha(Theme.warning, 0.12)
		clip: true

		Behavior on Layout.preferredHeight {
			SpatialAnim {}
		}
		Behavior on Layout.topMargin {
			SpatialAnim {}
		}
		Behavior on opacity {
			Anim {}
		}

		RowLayout {
			anchors.fill: parent
			anchors.leftMargin: 14
			anchors.rightMargin: 6
			spacing: 10

			Glyph {
				icon: banner.icon
				size: 18
				color: Theme.warning
			}

			StyledText {
				Layout.fillWidth: true
				text: banner.text
				elide: Text.ElideRight
			}

			TextButton {
				height: 32
				text: banner.action
				onActivated: banner.activated()
			}
		}
	}
}
