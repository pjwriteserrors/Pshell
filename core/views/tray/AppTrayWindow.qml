pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.tray

// One app tray (see AppTray) on the edge of its screen. A transparent layer
// along the whole edge that takes input only where the tray is (or the thin
// strip or the handle it waits behind), so it never covers the windows.
// Everything is laid out along the edge ("along") and away from it
// ("cross"), then turned to the edge it is on.
PanelWindow {
	id: root

	required property var modelData
	readonly property string trayId: String(root.modelData)
	readonly property var tray: AppTray.full(AppTray.trayById(root.trayId))
	readonly property string edge: root.edges.includes(root.tray.edge) ? root.tray.edge : "bottom"
	readonly property var edges: ["left", "right", "top", "bottom"]
	readonly property bool vertical: root.edge === "left" || root.edge === "right"
	readonly property var items: root.tray.items ?? []
	readonly property var itemsById: {
		const out = {};
		for (const item of root.items) out[item.id] = item;
		return out;
	}

	// ── sizes ───────────────────────────────────────────────────────────
	readonly property real size: Math.max(24, Math.min(96, Number(root.tray.iconSize) || 48))
	readonly property real pad: Math.round(root.size * 0.2)
	readonly property real spacing: Math.round(root.size * 0.16)
	readonly property real thick: root.size + root.pad * 2
	readonly property real gap: Math.max(0, Math.min(64, Number(root.tray.gap) || 0))
	readonly property real magnify: Math.max(0, Math.min(1.2, Number(root.tray.magnify) || 0))
	// room inside for the grown icons, their names and the menu
	readonly property real depth: Math.ceil(root.gap + root.thick + Math.max(250, root.size * root.magnify + 70))
	readonly property real len: root.vertical ? root.height : root.width

	// ── showing ─────────────────────────────────────────────────────────
	readonly property bool gaming: root.tray.gameHide && GameMode.active
	readonly property string reveal: root.tray.reveal === "always" && root.gaming ? "hover" : String(root.tray.reveal)
	readonly property bool editingHere: AppTray.previewing && AppTray.editing === root.trayId
	property bool peek: false
	property bool dropping: false
	property bool wasInside: false
	readonly property bool inside: hover.hovered
	readonly property bool menuOpen: root.menuItem !== null
	readonly property bool shown: root.reveal === "always" || root.peek || AppTray.isOpen(root.trayId) || root.menuOpen
		|| root.dropping || AppTray.carrying || root.dragId !== "" || root.editingHere
	property real revealed: root.shown ? 1 : 0

	Behavior on revealed {
		SpatialAnim {
			duration: root.shown ? Motion.long : Motion.medium
		}
	}

	onInsideChanged: {
		if (root.inside) {
			root.wasInside = true;
			leaveTimer.stop();
			if (!root.shown && root.reveal === "hover") peekTimer.restart();
		} else {
			peekTimer.stop();
			leaveTimer.restart();
		}
	}

	Timer {
		id: peekTimer

		interval: Math.max(0, Number(root.tray.delay) || 0)
		onTriggered: if (root.inside) root.peek = true
	}

	// the pointer left: a peeking tray goes, one opened by a click or key too
	Timer {
		id: leaveTimer

		interval: root.menuOpen ? 900 : 420
		onTriggered: {
			if (root.inside || root.dragId !== "") return;
			root.peek = false;
			root.menuItem = null;
			if (root.wasInside && AppTray.isOpen(root.trayId)) AppTray.setOpen(root.trayId, false);
			root.wasInside = false;
		}
	}

	// opened by a key and never reached: it goes again by itself
	Connections {
		target: AppTray

		function onOpenedChanged() {
			if (AppTray.isOpen(root.trayId)) {
				root.wasInside = root.inside;
				forgotTimer.restart();
			}
		}
	}

	Timer {
		id: forgotTimer

		interval: 6000
		onTriggered: if (!root.wasInside && !root.inside && root.dragId === "") AppTray.setOpen(root.trayId, false)
	}

	// ── the layer ───────────────────────────────────────────────────────
	screen: Popups.screenByName(AppTray.outputOf(root.tray)) ?? Popups.primaryScreen
	color: "transparent"
	anchors {
		left: root.edge !== "right"
		right: root.edge !== "left"
		top: root.edge !== "bottom"
		bottom: root.edge !== "top"
	}
	implicitWidth: root.vertical ? root.depth : 0
	implicitHeight: root.vertical ? 0 : root.depth
	exclusionMode: ExclusionMode.Normal
	exclusiveZone: root.tray.reserve && root.reveal === "always" ? Math.round(root.gap + root.thick) : 0
	WlrLayershell.namespace: "shell-app-tray"
	WlrLayershell.layer: WlrLayer.Top
	WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

	mask: Region {
		regions: root.revealed > 0.02 || root.shown ? (root.menuOpen ? [boxRegion, menuRegion] : [boxRegion]) : (root.reveal === "hover" ? [stripRegion] : (root.reveal === "click" ? [handleRegion] : []))
	}

	Region {
		id: boxRegion

		item: hitBox
	}

	Region {
		id: stripRegion

		item: strip
	}

	Region {
		id: handleRegion

		item: handleHit
	}

	Region {
		id: menuRegion

		item: menu
	}

	// a rectangle given along and away from the edge, in the layer's coordinates
	function rect(a, c, la, lc) {
		switch (root.edge) {
		case "left": return Qt.rect(c, a, lc, la);
		case "right": return Qt.rect(root.width - c - lc, a, lc, la);
		case "top": return Qt.rect(a, c, la, lc);
		default: return Qt.rect(a, root.height - c - lc, la, lc);
		}
	}

	// a point of the layer, along and away from the edge
	function local(x, y) {
		switch (root.edge) {
		case "left": return { a: y, c: x };
		case "right": return { a: y, c: root.width - x };
		case "top": return { a: x, c: y };
		default: return { a: x, c: root.height - y };
		}
	}

	// ── where everything goes ───────────────────────────────────────────
	// dragging an item of the tray around
	property string dragId: ""
	property real dragA: 0
	property real dragC: 0
	readonly property bool removing: root.dragId !== "" && root.dragC > root.gap + root.thick + root.size * 0.75
	// where something dragged in from outside would land
	property int dropAt: -1
	// the pointer, for growing the icons under it
	property real pointerA: -1
	property real grow: root.inside && root.dragId === "" && !root.dropping && !root.menuOpen && root.shown && root.pointerA >= 0 ? 1 : 0

	Behavior on grow {
		Anim {
			duration: Motion.medium
		}
	}

	// the items in order; an empty slot where something would go
	readonly property var order: {
		const ids = root.items.map(item => item.id).filter(id => id !== root.dragId);
		let at = -1;
		if (root.dragId !== "" && !root.removing) at = root.insertIndex(root.dragA, ids.length);
		else if (root.dropping && root.dropAt >= 0) at = Math.min(root.dropAt, ids.length);
		if (at >= 0) ids.splice(at, 0, "");
		return ids;
	}
	readonly property real baseLength: Math.max(1, root.order.length) * root.size + Math.max(0, root.order.length - 1) * root.spacing
	readonly property real center: {
		const half = root.baseLength / 2 + root.pad + 8;
		return Math.max(half, Math.min(root.len - half, (Number(root.tray.position) || 0.5) * root.len));
	}
	readonly property real baseStart: root.center - root.baseLength / 2

	// which slot a point along the edge is in (for `count` slots)
	function insertIndex(a, count) {
		const length = (count + 1) * root.size + count * root.spacing;
		const start = root.center - length / 2;
		return Math.max(0, Math.min(count, Math.floor((a - start + root.spacing / 2) / (root.size + root.spacing))));
	}

	// every slot: { id, a (start along the edge), s (scale) }, the point
	// under the pointer staying where it is while the icons grow
	readonly property var layout: {
		const n = root.order.length;
		const slot = root.size + root.spacing;
		const p = root.pointerA;
		const reach = root.size * 2.6;
		const scales = [];
		let before = 0;
		let extra = 0;
		for (let i = 0; i < n; i += 1) {
			const start = root.baseStart + i * slot;
			const middle = start + root.size / 2;
			const d = Math.abs(p - middle) / reach;
			const s = 1 + root.magnify * root.grow * (d < 1 ? (Math.cos(d * Math.PI) + 1) / 2 : 0);
			scales.push(s);
			const more = root.size * (s - 1);
			extra += more;
			before += more * Math.max(0, Math.min(1, (p - start) / slot));
		}
		const out = [];
		let a = root.baseStart - before;
		for (let i = 0; i < n; i += 1) {
			out.push({ id: root.order[i], a: a, s: scales[i] });
			a += root.size * scales[i] + root.spacing;
		}
		return { slots: out, start: root.baseStart - before, end: root.baseStart - before + root.baseLength + extra };
	}
	readonly property var slotById: {
		const out = {};
		for (const slot of root.layout.slots) out[slot.id] = slot;
		return out;
	}
	readonly property real tallest: root.layout.slots.reduce((most, slot) => Math.max(most, slot.s), 1)

	// ── items as a model: delegates live on while the list changes ─────
	ListModel {
		id: itemModel
	}

	function sync() {
		const ids = root.items.map(item => item.id);
		for (let i = itemModel.count - 1; i >= 0; i -= 1)
			if (!ids.includes(itemModel.get(i).itemId)) itemModel.remove(i);
		for (const id of ids) {
			let known = false;
			for (let i = 0; i < itemModel.count; i += 1)
				if (itemModel.get(i).itemId === id) known = true;
			if (!known) itemModel.append({ itemId: id });
		}
	}

	onItemsChanged: root.sync()
	Component.onCompleted: root.sync()

	// ── the menu of an item ─────────────────────────────────────────────
	property var menuItem: null
	property real menuA: 0

	function menuEntries(item) {
		if (!item) return [];
		const out = [];
		switch (item.kind) {
		case "app": {
			const windows = AppTray.windowsOf(item);
			out.push({ id: "open", label: windows.length > 0 ? "New window" : "Open", glyph: "open_in_new" });
			if (windows.length > 0) out.push({ id: "focus", label: windows.length > 1 ? `Go to window (${windows.length})` : "Go to window", glyph: "arrow_right" });
			const entry = AppTray.entryOf(item);
			for (const action of Array.from(entry?.actions ?? []).slice(0, 6))
				out.push({ id: "action", action: action, label: String(action.name ?? ""), glyph: "lightning_bolt" });
			if (windows.length > 0) out.push({ id: "close", label: windows.length > 1 ? "Close all windows" : "Close window", glyph: "close" });
			break;
		}
		case "command":
			out.push({ id: "open", label: "Run", glyph: "play" });
			break;
		case "shell":
			out.push({ id: "open", label: "Run", glyph: "play" });
			out.push({ id: "terminal", label: item.terminal ? "Run without a terminal" : "Run in a terminal", glyph: "console_line" });
			break;
		case "file":
			out.push({ id: "open", label: "Open", glyph: "open_in_new" });
			out.push({ id: "reveal", label: "Show in folder", glyph: "folder_outline" });
			break;
		case "link":
			out.push({ id: "open", label: "Open", glyph: "open_in_new" });
			out.push({ id: "copy", label: "Copy link", glyph: "content_copy" });
			break;
		}
		out.push({ id: "remove", label: "Remove from the tray", glyph: "delete_outline", danger: true });
		out.push({ id: "settings", label: "Tray settings…", glyph: "tune_variant" });
		return out;
	}

	function pick(entry) {
		const item = root.menuItem;
		root.menuItem = null;
		if (!item) return;
		switch (entry.id) {
		case "open":
			AppTray.run(root.trayId, item, true);
			break;
		case "focus": {
			const windows = AppTray.windowsOf(item);
			if (windows.length > 0) Niri.focusWindow(windows[0].id);
			break;
		}
		case "action":
			AppTray.runAction(item, entry.action);
			break;
		case "close":
			AppTray.closeWindows(item);
			break;
		case "terminal":
			AppTray.updateItem(root.trayId, item.id, { terminal: !item.terminal });
			break;
		case "reveal":
			Quickshell.execDetached(["xdg-open", String(item.path).replace(/\/[^/]*$/, "") || "/"]);
			break;
		case "copy":
			Quickshell.execDetached(["wl-copy", String(item.url)]);
			break;
		case "remove":
			AppTray.removeItem(root.trayId, item.id);
			break;
		case "settings":
			AppTray.editing = root.trayId;
			Quickshell.execDetached(["qs", "ipc", "-p", Quickshell.shellDir, "call", "settings", "open", "tray"]);
			break;
		}
	}

	// ── drawing ─────────────────────────────────────────────────────────
	Item {
		id: stage

		anchors.fill: parent

		HoverHandler {
			id: hover

			onPointChanged: {
				if (!hover.hovered) return;
				const at = root.local(hover.point.position.x, hover.point.position.y);
				// only near the tray itself, not over the names and the menu
				root.pointerA = at.c <= root.gap + root.thick + root.size * root.magnify + 6 ? at.a : -1;
			}
			onHoveredChanged: if (!hover.hovered) root.pointerA = -1
		}

		// the strip at the edge a hiding tray waits behind
		Item {
			id: strip

			readonly property rect r: root.rect(root.baseStart - root.pad - 40, 0, root.baseLength + root.pad * 2 + 80, 3)

			x: strip.r.x
			y: strip.r.y
			width: strip.r.width
			height: strip.r.height
		}

		// the handle of a tray that opens on a click
		Item {
			id: handleHit

			readonly property rect r: root.rect(root.center - 50, 0, 100, 14)

			x: handleHit.r.x
			y: handleHit.r.y
			width: handleHit.r.width
			height: handleHit.r.height
			visible: root.reveal === "click"

			MouseArea {
				id: handleMouse

				anchors.fill: parent
				hoverEnabled: true
				cursorShape: Qt.PointingHandCursor
				onClicked: AppTray.toggle(root.trayId)
			}
		}

		// … and what it looks like: a short bar that grows under the pointer
		Rectangle {
			readonly property real l: handleMouse.containsMouse ? 76 : 56
			readonly property real t: handleMouse.containsMouse ? 6 : 4
			readonly property rect r: root.rect(root.center - l / 2, 3, l, t)

			visible: root.reveal === "click"
			x: r.x
			y: r.y
			width: r.width
			height: r.height
			radius: Math.min(width, height) / 2
			color: handleMouse.containsMouse ? Theme.primary : Qt.alpha(Theme.text, 0.45)
			opacity: 1 - root.revealed

			Behavior on color {
				ColorAnim {}
			}
		}

		// what takes the pointer while the tray shows: the tray, the room
		// between it and the edge, and where its icons grow to
		Item {
			id: hitBox

			readonly property real a0: Math.min(root.layout.start, root.baseStart) - root.pad - 6
			readonly property real a1: Math.max(root.layout.end, root.baseStart + root.baseLength) + root.pad + 6
			readonly property real reach: root.gap + root.thick + (root.grow > 0.01 ? root.size * root.magnify * root.grow + 34 : 4)
			readonly property rect r: root.rect(hitBox.a0, 0, hitBox.a1 - hitBox.a0, hitBox.reach)

			x: hitBox.r.x
			y: hitBox.r.y
			width: hitBox.r.width
			height: hitBox.r.height
		}

		// a drop from outside: anywhere the tray takes the pointer
		DropArea {
			anchors.fill: parent
			onEntered: drag => {
				if (!AppTray.accepts(drag)) {
					drag.accepted = false;
					return;
				}
				root.dropping = true;
				const at = root.local(drag.x, drag.y);
				root.dropAt = root.insertIndex(at.a, root.items.length);
			}
			onPositionChanged: drag => {
				const at = root.local(drag.x, drag.y);
				root.dropAt = root.insertIndex(at.a, root.items.length);
			}
			onExited: {
				root.dropping = false;
				root.dropAt = -1;
			}
			onDropped: drop => {
				const items = AppTray.itemsOfDrop(drop);
				const at = root.dropAt;
				root.dropping = false;
				root.dropAt = -1;
				if (items.length === 0) return;
				AppTray.addItems(root.trayId, items, at);
				drop.accept(Qt.CopyAction);
			}
		}

		// everything that slides in and out
		Item {
			id: slider

			anchors.fill: parent
			opacity: Math.min(1, root.revealed * 1.6)
			visible: root.revealed > 0.01

			transform: Translate {
				readonly property real away: (1 - root.revealed) * (root.gap + root.thick + 24)

				x: root.edge === "left" ? -away : (root.edge === "right" ? away : 0)
				y: root.edge === "top" ? -away : (root.edge === "bottom" ? away : 0)
			}

			// the tray's body
			Item {
				id: body

				readonly property real a0: root.layout.start - root.pad
				readonly property real a1: root.layout.end + root.pad
				readonly property rect r: root.rect(body.a0, root.gap, body.a1 - body.a0, root.thick)

				x: body.r.x
				y: body.r.y
				width: body.r.width
				height: body.r.height
				visible: root.tray.look !== "bare" || root.items.length === 0

				Behavior on x {
					enabled: root.grow < 0.01
					SpatialAnim {
						duration: Motion.medium
					}
				}
				Behavior on y {
					enabled: root.grow < 0.01
					SpatialAnim {
						duration: Motion.medium
					}
				}
				Behavior on width {
					enabled: root.grow < 0.01
					SpatialAnim {
						duration: Motion.medium
					}
				}
				Behavior on height {
					enabled: root.grow < 0.01
					SpatialAnim {
						duration: Motion.medium
					}
				}

				RectangularShadow {
					anchors.fill: plate
					radius: plate.radius
					blur: 24
					offset.y: root.edge === "top" ? 2 : (root.edge === "bottom" ? -2 : 0)
					color: Qt.alpha(Theme.shadow, 0.35)
					visible: root.tray.look !== "bare"
				}

				Rectangle {
					id: plate

					anchors.fill: parent
					radius: Math.min(width, height) * 0.36
					color: root.tray.look === "solid" ? Theme.layer1 : (root.tray.look === "bare" ? "transparent" : Theme.glass)
					border.width: 1
					border.color: root.dropping ? Qt.alpha(Theme.primary, 0.7) : (root.tray.look === "bare" ? Qt.alpha(Theme.text, 0.25) : Theme.outline)

					Behavior on border.color {
						ColorAnim {}
					}

					// a faint light on the side away from the edge
					Rectangle {
						anchors.fill: parent
						anchors.margins: 1
						radius: parent.radius - 1
						visible: root.tray.look !== "bare"
						gradient: Gradient {
							orientation: root.vertical ? Gradient.Horizontal : Gradient.Vertical
							GradientStop {
								position: 0
								color: Qt.rgba(1, 1, 1, root.edge === "bottom" || root.edge === "right" ? 0.06 : 0)
							}
							GradientStop {
								position: 1
								color: Qt.rgba(1, 1, 1, root.edge === "top" || root.edge === "left" ? 0.06 : 0)
							}
						}
					}
				}
			}

			// an empty tray says what it is for
			Item {
				readonly property rect r: root.rect(root.baseStart, root.gap + root.pad, root.size, root.size)

				visible: root.items.length === 0 && !root.dropping
				x: r.x
				y: r.y
				width: r.width
				height: r.height

				Rectangle {
					anchors.fill: parent
					anchors.margins: parent.width * 0.08
					radius: width * 0.27
					color: "transparent"
					border.width: 1.5
					border.color: Qt.alpha(Theme.text, 0.3)

					Glyph {
						anchors.centerIn: parent
						icon: "plus"
						size: parent.width * 0.5
						color: Theme.textMuted
						animated: false
					}
				}
			}

			// where a drop would land
			Rectangle {
				readonly property var slot: root.slotById[""]
				readonly property rect r: slot ? root.rect(slot.a + root.size * 0.08, root.gap + root.pad + root.size * 0.08, root.size * 0.84, root.size * 0.84) : Qt.rect(0, 0, 0, 0)

				visible: !!slot && !root.removing
				x: r.x
				y: r.y
				width: r.width
				height: r.height
				radius: width * 0.27
				color: Qt.alpha(Theme.primary, 0.16)
				border.width: 1.5
				border.color: Qt.alpha(Theme.primary, 0.6)
			}

			// the items
			Repeater {
				model: itemModel

				delegate: Item {
					id: cell

					required property string itemId
					readonly property var item: root.itemsById[cell.itemId] ?? null
					readonly property bool dragged: root.dragId === cell.itemId
					readonly property var slot: root.slotById[cell.itemId] ?? { a: root.baseStart, s: 1 }
					readonly property real s: cell.dragged ? 1.08 : cell.slot.s
					readonly property real side: root.size * cell.s
					property real bounce: 0
					property real enter: 0
					readonly property int windows: root.tray.dots ? AppTray.windowsOf(cell.item).length : 0
					readonly property bool hovered: mouse.containsMouse && root.dragId === ""
					readonly property real at: cell.dragged ? root.dragA - cell.side / 2 : cell.slot.a
					readonly property real lift: cell.dragged ? Math.max(0, root.dragC - root.gap - root.pad - root.size / 2) : 0
					readonly property rect r: root.rect(cell.at, root.gap + root.pad + cell.lift + cell.bounce, cell.side, cell.side)

					x: cell.r.x
					y: cell.r.y
					width: cell.r.width
					height: cell.r.height
					z: cell.dragged ? 10 : (cell.hovered ? 2 : 1)
					opacity: cell.enter * (cell.dragged && root.removing ? 0.45 : 1)
					scale: 0.4 + 0.6 * cell.enter

					Behavior on x {
						enabled: root.grow < 0.01 && !cell.dragged
						SpatialAnim {
							duration: Motion.medium
						}
					}
					Behavior on y {
						enabled: root.grow < 0.01 && !cell.dragged
						SpatialAnim {
							duration: Motion.medium
						}
					}

					Component.onCompleted: enterAnim.start()

					NumberAnimation {
						id: enterAnim

						target: cell
						property: "enter"
						from: 0
						to: 1
						duration: Motion.long
						easing.type: Easing.BezierSpline
						easing.bezierCurve: Motion.spatialFast
					}

					// started: it hops away from the edge, twice
					SequentialAnimation {
						id: hopAnim

						loops: 2

						NumberAnimation {
							target: cell
							property: "bounce"
							to: root.size * 0.42
							duration: 220
							easing.type: Easing.OutQuad
						}
						NumberAnimation {
							target: cell
							property: "bounce"
							to: 0
							duration: 260
							easing.type: Easing.OutBounce
						}
					}

					Connections {
						target: AppTray

						function onLaunched(itemId) {
							if (itemId === cell.itemId) hopAnim.restart();
						}
					}

					TrayIcon {
						anchors.fill: parent
						item: cell.item
						lifted: cell.hovered || cell.dragged
						scale: mouse.pressed && !cell.dragged ? 0.9 : 1

						Behavior on scale {
							SpatialAnim {
								duration: Motion.short
							}
						}
					}

					// taken out when let go here
					Rectangle {
						visible: cell.dragged && root.removing
						anchors.centerIn: parent
						width: parent.width * 0.5
						height: width
						radius: width / 2
						color: Theme.danger

						Glyph {
							anchors.centerIn: parent
							icon: "delete_outline"
							size: parent.width * 0.6
							color: Theme.onPrimary
							surface: Theme.danger
							animated: false
						}
					}

					// its windows: a dot each, up to three, between it and the edge
					Row {
						readonly property rect r: root.rect(cell.at + cell.side / 2 - 12, root.gap + 2, 24, 4)

						parent: slider
						visible: cell.windows > 0 && !cell.dragged
						x: r.x + (r.width - width) / 2
						y: r.y + (r.height - height) / 2
						spacing: 3
						rotation: root.vertical ? 90 : 0

						Repeater {
							model: Math.min(3, cell.windows)

							delegate: Rectangle {
								width: cell.windows > 1 ? 4 : 10
								height: 4
								radius: 2
								color: Theme.primary
							}
						}
					}

					MouseArea {
						id: mouse

						property point press
						property bool moved: false

						anchors.fill: parent
						hoverEnabled: true
						acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
						cursorShape: cell.dragged ? Qt.ClosedHandCursor : Qt.PointingHandCursor
						preventStealing: true
						onPressed: event => {
							mouse.press = mapToItem(stage, event.x, event.y);
							mouse.moved = false;
						}
						onPositionChanged: event => {
							if (!mouse.pressed || !(mouse.pressedButtons & Qt.LeftButton)) return;
							const p = mapToItem(stage, event.x, event.y);
							if (!mouse.moved && Math.hypot(p.x - mouse.press.x, p.y - mouse.press.y) < 8) return;
							mouse.moved = true;
							root.menuItem = null;
							const at = root.local(p.x, p.y);
							root.dragA = at.a;
							root.dragC = at.c;
							root.dragId = cell.itemId;
						}
						onReleased: event => {
							if (!cell.dragged) return;
							const removing = root.removing;
							const count = root.items.length - 1;
							const index = root.insertIndex(root.dragA, count);
							root.dragId = "";
							if (removing) AppTray.removeItem(root.trayId, cell.itemId);
							else AppTray.moveItem(root.trayId, cell.itemId, index);
						}
						onCanceled: root.dragId = ""
						onClicked: event => {
							if (mouse.moved) return;
							if (event.button === Qt.RightButton) {
								root.menuA = cell.at + cell.side / 2;
								root.menuItem = root.menuItem?.id === cell.itemId ? null : cell.item;
							} else {
								root.menuItem = null;
								AppTray.run(root.trayId, cell.item, event.button === Qt.MiddleButton);
							}
						}
					}

					// its name, inside of it
					Rectangle {
						readonly property real w: Math.min(260, label.implicitWidth + 20)
						readonly property real h: label.implicitHeight + 10
						readonly property real c: root.gap + root.thick + root.size * (cell.s - 1) + 10
						readonly property rect r: root.vertical
							? root.rect(cell.at + cell.side / 2 - h / 2, c, h, w)
							: root.rect(cell.at + cell.side / 2 - w / 2, c, w, h)
						readonly property bool up: root.tray.labels && cell.hovered && !root.menuOpen

						parent: slider
						x: r.x
						y: r.y
						width: r.width
						height: r.height
						radius: Math.min(width, height) / 2
						color: Theme.layer3
						border.width: 1
						border.color: Theme.outline
						opacity: up ? 1 : 0
						scale: up ? 1 : 0.85
						z: 20

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

						StyledText {
							id: label

							anchors.centerIn: parent
							width: Math.min(implicitWidth, 240)
							text: AppTray.nameOf(cell.item) + (cell.windows > 1 ? `  ·  ${cell.windows}` : "")
							font.pixelSize: Theme.size.small
							font.weight: Font.Medium
						}
					}
				}
			}
		}

		// the menu of an item
		Rectangle {
			id: menu

			readonly property var entries: root.menuEntries(root.menuItem)
			readonly property real w: 230
			readonly property real h: entries.length * 34 + 12
			readonly property real la: root.vertical ? h : w
			readonly property real lc: root.vertical ? w : h
			readonly property real a: Math.max(8, Math.min(root.len - la - 8, root.menuA - la / 2))
			readonly property rect r: root.rect(menu.a, root.gap + root.thick + 10, menu.la, menu.lc)

			x: menu.r.x
			y: menu.r.y
			width: menu.w
			height: menu.h
			radius: Theme.radius.large
			color: Theme.layer2
			border.width: 1
			border.color: Theme.outline
			visible: menu.opacity > 0.01
			opacity: root.menuOpen ? 1 : 0
			scale: root.menuOpen ? 1 : 0.92
			transformOrigin: root.edge === "left" ? Item.Left : (root.edge === "right" ? Item.Right : (root.edge === "top" ? Item.Top : Item.Bottom))

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

			Column {
				anchors.fill: parent
				anchors.margins: 6

				Repeater {
					model: menu.entries

					delegate: Rectangle {
						id: row

						required property var modelData

						width: parent.width
						height: 34
						radius: Theme.radius.small
						color: rowMouse.containsMouse ? (row.modelData.danger ? Theme.dangerContainer : Theme.layer3) : "transparent"

						Glyph {
							id: rowGlyph

							anchors.left: parent.left
							anchors.leftMargin: 10
							anchors.verticalCenter: parent.verticalCenter
							icon: row.modelData.glyph
							size: 16
							color: row.modelData.danger ? Theme.danger : Theme.textMuted
							animated: false
						}

						StyledText {
							anchors.left: rowGlyph.right
							anchors.leftMargin: 10
							anchors.right: parent.right
							anchors.rightMargin: 10
							anchors.verticalCenter: parent.verticalCenter
							text: row.modelData.label
							tone: row.modelData.danger ? Theme.danger : Theme.text
						}

						MouseArea {
							id: rowMouse

							anchors.fill: parent
							hoverEnabled: true
							cursorShape: Qt.PointingHandCursor
							onClicked: root.pick(row.modelData)
						}
					}
				}
			}
		}
	}
}
