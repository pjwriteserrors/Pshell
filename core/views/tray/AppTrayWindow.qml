pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Wayland
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.tray

// One app tray (see AppTray) on the edge of its screen. A transparent layer
// along the whole edge that takes input only where the tray is (or the thin
// strip or the handle it waits behind, a menu, a group or a preview that is
// open), so it never covers the windows. Everything is laid out along the
// edge ("along") and away from it ("cross"), then turned to its edge.
PanelWindow {
	id: root

	required property var modelData
	readonly property string trayId: String(root.modelData)
	readonly property var tray: AppTray.full(AppTray.trayById(root.trayId))
	readonly property string edge: root.edges.includes(root.tray.edge) ? root.tray.edge : "bottom"
	readonly property var edges: ["left", "right", "top", "bottom"]
	readonly property bool vertical: root.edge === "left" || root.edge === "right"
	readonly property bool active: AppTray.active(root.tray)
	readonly property var items: AppTray.shownItems(root.tray)
	readonly property var itemsById: {
		const out = {};
		for (const item of root.items) out[item.id] = item;
		return out;
	}
	readonly property bool lively: root.tray.motion !== "calm"
	readonly property color accent: {
		switch (root.tray.accent) {
		case "secondary": return Theme.secondary;
		case "tertiary": return Theme.tertiary;
		case "custom": return String(root.tray.accentColor || "") !== "" ? root.tray.accentColor : Theme.primary;
		}
		return Theme.primary;
	}

	// ── sizes ───────────────────────────────────────────────────────────
	readonly property real fullSize: Math.max(24, Math.min(96, Number(root.tray.iconSize) || 48))
	// a compact tray is a strip of small icons until it is reached
	readonly property bool engaged: root.inside || root.dropping || root.keyboard || root.menuOpen || root.dragId !== "" || root.groupOpen || root.editingHere
	property real collapse: root.tray.compact && !root.engaged ? 1 : 0
	readonly property real size: root.fullSize * (1 - 0.66 * root.collapse)
	readonly property real pad: Math.round(root.size * 0.2)
	readonly property real spacing: Math.round(root.size * 0.16)
	readonly property real thick: root.size + root.pad * 2
	readonly property real gap: Math.max(0, Math.min(64, Number(root.tray.gap) || 0))
	readonly property real magnify: Math.max(0, Math.min(1.2, Number(root.tray.magnify) || 0))
	// room inside for the grown icons, names, menus, groups and previews
	readonly property real depth: Math.ceil(root.gap + root.fullSize * 1.4 + Math.max(340, root.fullSize * root.magnify + 70))
	readonly property real len: root.vertical ? root.height : root.width

	Behavior on collapse {
		SpatialAnim {
			duration: Motion.medium
		}
	}

	// ── showing ─────────────────────────────────────────────────────────
	readonly property bool gaming: root.tray.gameHide && GameMode.active
	readonly property string reveal: (root.tray.reveal === "always" || root.tray.reveal === "smart") && root.gaming ? "hover" : String(root.tray.reveal)
	readonly property bool editingHere: AppTray.previewing && AppTray.editing === root.trayId
	readonly property bool keyboard: AppTray.keyboardTray === root.trayId
	property bool peek: false
	property bool dropping: false
	property bool wasInside: false
	readonly property bool inside: hover.hovered
	readonly property bool menuOpen: root.menuItem !== null
	readonly property bool groupOpen: root.groupId !== ""
	readonly property bool shown: root.active && (root.reveal === "always" || (root.reveal === "smart" && !root.covered) || root.peek
		|| AppTray.isOpen(root.trayId) || root.menuOpen || root.groupOpen || root.dropping || AppTray.carrying || root.dragId !== ""
		|| root.editingHere || root.keyboard)
	// starts out of sight, so a tray that is made (or comes with a profile) glides in
	property real revealed: 0

	Behavior on revealed {
		SpatialAnim {
			duration: root.shown ? Motion.long : Motion.medium
		}
	}

	onInsideChanged: {
		if (root.inside) {
			root.wasInside = true;
			leaveTimer.stop();
			if (!root.shown && (root.reveal === "hover" || root.reveal === "smart")) peekTimer.restart();
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

		interval: root.menuOpen || root.groupOpen ? 900 : 420
		onTriggered: {
			if (root.inside || root.dragId !== "" || root.dropping) return;
			root.peek = false;
			root.menuItem = null;
			root.groupId = "";
			root.previewId = "";
			if (root.wasInside && AppTray.isOpen(root.trayId)) AppTray.setOpen(root.trayId, false);
			root.wasInside = false;
		}
	}

	Connections {
		target: AppTray

		// opened by a key and never reached: it goes again by itself
		function onOpenedChanged() {
			if (AppTray.isOpen(root.trayId)) {
				root.wasInside = root.inside;
				forgotTimer.restart();
			}
		}
		// something started from here: the tray opened for it closes
		function onLaunched(itemId) {
			if (root.itemsById[itemId] && root.keyboard) AppTray.keyboardTray = "";
		}
	}

	Timer {
		id: forgotTimer

		interval: 6000
		onTriggered: if (!root.wasInside && !root.inside && root.dragId === "") AppTray.setOpen(root.trayId, false)
	}

	// ── windows over it ("smart": it makes way while one covers it) ────
	readonly property bool covered: {
		if (root.tray.reveal !== "smart" || !root.screen) return false;
		const output = String(root.screen.name);
		const space = Niri.workspaces.find(each => each.is_active && String(each.output) === output);
		if (!space) return false;
		const top = Plugins.on("bar") ? Theme.barHeight : 0;
		const box = root.outputRectOf(root.rect(root.baseStart - root.pad, root.gap, root.baseLength + root.pad * 2, root.thick));
		return Niri.windows.some(window => {
			if (window.workspace_id !== space.id) return false;
			const pos = window.layout?.tile_pos_in_workspace_view;
			const size = window.layout?.tile_size;
			if (!pos || !size) return false;
			const x = pos[0];
			const y = pos[1] + top;
			return x < box.x + box.width && x + size[0] > box.x && y < box.y + box.height && y + size[1] > box.y;
		});
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
	exclusiveZone: root.active && root.tray.reserve && root.reveal === "always" ? Math.round(root.gap + root.thick) : 0
	WlrLayershell.namespace: "shell-app-tray"
	WlrLayershell.layer: WlrLayer.Top
	WlrLayershell.keyboardFocus: root.keyboard ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

	// the glass blurs what is behind it
	BackgroundEffect.blurRegion: root.tray.look === "glass" && root.tray.blur && root.revealed > 0.98 && root.active ? blurRegion : null

	// the plate's rectangle as numbers: one given by its item lagged behind
	// while the tray grew and shrank
	Region {
		id: blurRegion

		x: Math.round(body.r.x)
		y: Math.round(body.r.y)
		width: Math.round(body.r.width)
		height: Math.round(body.r.height)
		radius: Math.round(Math.min(body.r.width, body.r.height) * 0.36)
	}

	mask: Region {
		regions: {
			if (!root.active) return [];
			if (root.revealed > 0.02 || root.shown) {
				const out = [boxRegion];
				if (root.menuOpen) out.push(menuRegion);
				if (root.groupOpen) out.push(groupRegion);
				if (root.previewId !== "") out.push(previewRegion);
				return out;
			}
			if (root.reveal === "hover" || root.reveal === "smart") return [stripRegion];
			if (root.reveal === "click") return [handleRegion];
			return [];
		}
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

	Region {
		id: groupRegion

		item: groupPanel
	}

	Region {
		id: previewRegion

		item: previews
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

	// where the layer's corner is on its screen (a side layer starts below the bar)
	readonly property point origin: {
		const sw = root.screen?.width ?? root.width;
		const sh = root.screen?.height ?? root.height;
		return Qt.point(root.edge === "right" ? sw - root.width : 0, root.edge === "bottom" || root.vertical ? sh - root.height : 0);
	}

	function outputRectOf(r) {
		return Qt.rect(r.x + root.origin.x, r.y + root.origin.y, r.width, r.height);
	}

	// ── between trays: where a point of all screens falls in this one ──
	function indexAtGlobal(gx, gy) {
		if (!root.screen || !root.active) return -1;
		const lx = gx - root.screen.x - root.origin.x;
		const ly = gy - root.screen.y - root.origin.y;
		if (lx < 0 || ly < 0 || lx > root.width || ly > root.height) return -1;
		const at = root.local(lx, ly);
		if (at.c > root.gap + root.thick + root.size * 0.6) return -1;
		if (at.a < root.layout.start - root.pad - root.size || at.a > root.layout.end + root.pad + root.size) return -1;
		return root.insertIndex(at.a, root.items.map(item => item.id));
	}

	function globalOf(x, y) {
		return Qt.point((root.screen?.x ?? 0) + root.origin.x + x, (root.screen?.y ?? 0) + root.origin.y + y);
	}

	Component.onCompleted: {
		root.revealed = Qt.binding(() => root.shown ? 1 : 0);
		root.sync();
		const next = Object.assign({}, AppTray.windows);
		next[root.trayId] = root;
		AppTray.windows = next;
	}
	Component.onDestruction: {
		if (AppTray.windows[root.trayId] !== root) return;
		const next = Object.assign({}, AppTray.windows);
		delete next[root.trayId];
		AppTray.windows = next;
	}

	// ── where everything goes ───────────────────────────────────────────
	// dragging an item of the tray around
	property string dragId: ""
	property real dragA: 0
	property real dragC: 0
	readonly property bool removing: root.dragId !== "" && root.dragC > root.gap + root.thick + root.size * 0.75
	// what is under something dragged: a group to go into, an app to open it
	property string targetId: ""
	// where something dragged in from outside would land
	property int dropAt: -1
	// the pointer, for growing the icons under it
	property real pointerA: -1
	property real grow: root.inside && root.dragId === "" && !root.dropping && !root.menuOpen && !root.groupOpen && root.shown && root.pointerA >= 0 && root.collapse < 0.01 ? 1 : 0
	property string hoveredId: ""

	Behavior on grow {
		Anim {
			duration: Motion.medium
		}
	}

	function factorOf(id) {
		if (id === "") return root.dragId !== "" ? AppTray.slotFactor(root.itemsById[root.dragId], root.tray) : 1;
		return AppTray.slotFactor(root.itemsById[id], root.tray);
	}

	function grows(id) {
		const kind = root.itemsById[id]?.kind;
		return kind !== "separator" && kind !== "spacer" && kind !== "widget";
	}

	// the items in order; an empty slot where something would go
	readonly property var order: {
		const ids = root.items.map(item => item.id).filter(id => id !== root.dragId);
		let at = -1;
		if (root.dragId !== "" && !root.removing && root.targetId === "") at = root.insertIndex(root.dragA, ids);
		else if (root.dropping && root.dropAt >= 0 && root.targetId === "") at = Math.min(root.dropAt, ids.length);
		if (at >= 0) ids.splice(at, 0, "");
		return ids;
	}
	readonly property real baseLength: {
		if (root.order.length === 0) return root.size;
		return root.order.reduce((sum, id) => sum + root.factorOf(id) * root.size, 0) + (root.order.length - 1) * root.spacing;
	}
	// where it stands along the edge: its own place, or next to the tray it is snapped to
	readonly property real center: {
		const half = root.baseLength / 2 + root.pad + 8;
		return Math.max(half, Math.min(root.len - half, AppTray.centerOf(root.trayId, root.len, 1)));
	}
	readonly property real baseStart: root.center - root.baseLength / 2

	// the place among `ids` a point along the edge falls in: how many of them it is past
	function insertIndex(a, ids) {
		const length = ids.reduce((sum, id) => sum + root.factorOf(id) * root.size, 0) + Math.max(0, ids.length - 1) * root.spacing;
		let at = root.center - length / 2;
		let index = 0;
		for (const id of ids) {
			const width = root.factorOf(id) * root.size;
			if (a > at + width / 2) index += 1;
			at += width + root.spacing;
		}
		return index;
	}

	// every slot: { id, a (start along the edge), la (length), s (scale) },
	// the point under the pointer staying where it is while the icons grow
	readonly property var layout: {
		const n = root.order.length;
		const p = root.pointerA;
		const reach = root.size * 2.6;
		const scales = [];
		let before = 0;
		let extra = 0;
		let start = root.baseStart;
		for (let i = 0; i < n; i += 1) {
			const id = root.order[i];
			const width = root.factorOf(id) * root.size;
			const middle = start + width / 2;
			const d = Math.abs(p - middle) / reach;
			const s = root.grows(id) ? 1 + root.magnify * root.grow * (d < 1 ? (Math.cos(d * Math.PI) + 1) / 2 : 0) : 1;
			scales.push(s);
			const more = width * (s - 1);
			extra += more;
			before += more * Math.max(0, Math.min(1, (p - start) / (width + root.spacing)));
			start += width + root.spacing;
		}
		const out = [];
		let a = root.baseStart - before;
		for (let i = 0; i < n; i += 1) {
			const width = root.factorOf(root.order[i]) * root.size * scales[i];
			out.push({ id: root.order[i], a: a, la: width, s: scales[i] });
			a += width + root.spacing;
		}
		return { slots: out, start: root.baseStart - before, end: root.baseStart - before + root.baseLength + extra };
	}
	readonly property var slotById: {
		const out = {};
		for (const slot of root.layout.slots) out[slot.id] = slot;
		return out;
	}

	// the item a point along the edge is over, near its middle (or "")
	function itemAt(a, c) {
		if (c > root.gap + root.thick + root.size * 0.4) return "";
		for (const slot of root.layout.slots) {
			if (slot.id === "") continue;
			const margin = slot.la * 0.18;
			if (a >= slot.a + margin && a <= slot.a + slot.la - margin) return slot.id;
		}
		return "";
	}

	// ── items as a model: delegates live on while the list changes ─────
	ListModel {
		id: itemModel
	}

	// an item that goes plays its way out first: it is marked, shrinks
	// where it stood while the others close up, and then leaves the model
	property var leaving: ({})
	// one that went in a puff of smoke needs no way out of its own
	property string poofed: ""

	function sync() {
		const ids = root.items.map(item => item.id);
		const gone = Object.assign({}, root.leaving);
		for (let i = itemModel.count - 1; i >= 0; i -= 1) {
			const id = itemModel.get(i).itemId;
			if (!ids.includes(id) && id === root.poofed) {
				itemModel.remove(i);
				root.poofed = "";
			} else if (!ids.includes(id) && !gone[id]) gone[id] = true;
			// back before it was out
			else if (ids.includes(id) && gone[id]) delete gone[id];
		}
		root.leaving = gone;
		for (const id of ids) {
			let known = false;
			for (let i = 0; i < itemModel.count; i += 1)
				if (itemModel.get(i).itemId === id) known = true;
			if (!known) itemModel.append({ itemId: id });
		}
	}

	function forget(id) {
		for (let i = itemModel.count - 1; i >= 0; i -= 1)
			if (itemModel.get(i).itemId === id) itemModel.remove(i);
		const gone = Object.assign({}, root.leaving);
		delete gone[id];
		root.leaving = gone;
	}

	onItemsChanged: root.sync()

	// ── the keyboard (Mod+Alt+0, `apptray focus`) ──────────────────────
	property int keyIndex: 0
	readonly property var keyItems: root.items.filter(item => item.kind !== "separator" && item.kind !== "spacer")
	onKeyboardChanged: if (root.keyboard) {
		root.keyIndex = 0;
		keys.forceActiveFocus();
	}

	// ── the menu of an item ─────────────────────────────────────────────
	property var menuItem: null
	property real menuA: 0
	readonly property var groups: (root.tray.items ?? []).filter(item => item.kind === "group")

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
			if (AppTray.badgeOf(item).count > 0) out.push({ id: "clear", label: "Clear its notifications", glyph: "bell_off_outline" });
			if (windows.length > 0) out.push({ id: "close", label: windows.length > 1 ? "Close all windows" : "Close window", glyph: "close" });
			break;
		}
		case "command":
		case "game":
			out.push({ id: "open", label: item.kind === "game" ? "Play" : "Run", glyph: "play" });
			break;
		case "shell":
			out.push({ id: "open", label: "Run", glyph: "play" });
			out.push({ id: "terminal", label: item.terminal ? "Run without a terminal" : "Run in a terminal", glyph: "console_line" });
			break;
		case "file":
			out.push({ id: "open", label: "Open", glyph: "open_in_new" });
			if (item.folder) {
				out.push({ id: "stack", label: item.stack ? "Show as a folder" : "Show as a stack", glyph: item.stack ? "folder" : "file_multiple_outline" });
				if (item.stack) out.push({ id: "view", label: item.view === "grid" ? "Open as a fan" : "Open as a grid", glyph: "view_grid_outline" });
			} else {
				out.push({ id: "reveal", label: "Show in folder", glyph: "folder_outline" });
			}
			break;
		case "link":
			out.push({ id: "open", label: "Open", glyph: "open_in_new" });
			out.push({ id: "copy", label: "Copy link", glyph: "content_copy" });
			break;
		case "group":
			out.push({ id: "group", label: "Open", glyph: "apps" });
			out.push({ id: "ungroup", label: "Take the group apart", glyph: "arrow_expand_horizontal" });
			break;
		}
		if (item.transient) {
			out.push({ id: "keep", label: "Keep in the tray", glyph: "pin_outline" });
			return out;
		}
		if (item.kind !== "group" && item.kind !== "separator" && item.kind !== "spacer")
			for (const group of root.groups)
				out.push({ id: "into", group: group.id, label: `Into ${AppTray.nameOf(group)}`, glyph: "apps" });
		out.push({ id: "line", label: "A line after it", glyph: "minus" });
		out.push({ id: "newgroup", label: "A new group after it", glyph: "plus" });
		out.push({ id: "remove", label: "Remove from the tray", glyph: "delete_outline", danger: true });
		out.push({ id: "settings", label: "Tray settings…", glyph: "tune_variant" });
		return out;
	}

	function indexOf(itemId) {
		return (root.tray.items ?? []).findIndex(item => item.id === itemId);
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
		case "clear":
			AppTray.dismissNotifs(item);
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
		case "stack":
			AppTray.updateItem(root.trayId, item.id, { stack: !item.stack });
			break;
		case "view":
			AppTray.updateItem(root.trayId, item.id, { view: item.view === "grid" ? "fan" : "grid" });
			break;
		case "group":
			root.groupId = item.id;
			break;
		case "ungroup": {
			const list = (root.tray.items ?? []).slice();
			const at = list.findIndex(each => each.id === item.id);
			list.splice(at, 1, ...(item.items ?? []));
			AppTray.update(root.trayId, { items: list });
			break;
		}
		case "keep":
			AppTray.addItems(root.trayId, [{ kind: "app", app: item.app }], -1);
			break;
		case "into":
			AppTray.addToGroup(root.trayId, entry.group, [item]);
			break;
		case "line":
			AppTray.addItems(root.trayId, [{ kind: "separator" }], root.indexOf(item.id) + 1);
			break;
		case "newgroup":
			AppTray.addGroup(root.trayId, root.indexOf(item.id) + 1);
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

	// ── a group or a stacked folder, open ───────────────────────────────
	property string groupId: ""
	property real groupA: 0
	readonly property var groupItem: root.itemsById[root.groupId] ?? null

	function openGroup(id) {
		const slot = root.slotById[id];
		root.groupA = slot ? slot.a + slot.la / 2 : root.center;
		root.menuItem = null;
		root.previewId = "";
		root.groupId = root.groupId === id ? "" : id;
	}

	// a drag that rests on a group or a folder opens it
	Timer {
		id: springTimer

		property string target: ""

		interval: 700
		onTriggered: {
			const item = root.itemsById[springTimer.target];
			if (item && (item.kind === "group" || (item.kind === "file" && item.folder))) {
				if (item.kind === "file" && !item.stack) return;
				root.openGroup(springTimer.target);
			}
		}
	}

	// ── the windows of an app, as pictures ──────────────────────────────
	property string previewId: ""
	property real previewA: 0
	readonly property var previewWindows: root.previewId !== "" ? AppTray.windowsOf(root.itemsById[root.previewId]) : []

	Timer {
		id: previewTimer

		interval: 650
		onTriggered: {
			const item = root.itemsById[root.hoveredId];
			if (!root.tray.previews || !item || item.kind !== "app" || root.menuOpen || root.groupOpen || root.dragId !== "") return;
			const windows = AppTray.windowsOf(item);
			if (windows.length === 0) return;
			const slot = root.slotById[root.hoveredId];
			root.previewA = slot ? slot.a + slot.la / 2 : root.center;
			root.previewId = root.hoveredId;
			AppTray.shoot(windows);
		}
	}

	onHoveredIdChanged: {
		if (root.hoveredId !== "") previewTimer.restart();
		else previewTimer.stop();
		if (root.hoveredId !== "" && root.hoveredId !== root.previewId) root.previewId = "";
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

		// the keyboard, while the tray has it
		Item {
			id: keys

			focus: root.keyboard
			Keys.onPressed: event => {
				const count = root.keyItems.length;
				const back = root.edge === "right" || root.edge === "left" ? Qt.Key_Up : Qt.Key_Left;
				const on = root.edge === "right" || root.edge === "left" ? Qt.Key_Down : Qt.Key_Right;
				if (event.key === back || event.key === Qt.Key_Left || event.key === Qt.Key_Up || event.key === Qt.Key_Backtab) root.keyIndex = (root.keyIndex - 1 + count) % Math.max(1, count);
				else if (event.key === on || event.key === Qt.Key_Right || event.key === Qt.Key_Down || event.key === Qt.Key_Tab) root.keyIndex = (root.keyIndex + 1) % Math.max(1, count);
				else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
					const item = root.keyItems[root.keyIndex];
					if (item?.kind === "group" || (item?.kind === "file" && item.stack)) root.openGroup(item.id);
					else if (item) AppTray.run(root.trayId, item, (event.modifiers & Qt.ShiftModifier) !== 0);
				} else if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
					const item = root.keyItems[event.key - Qt.Key_1];
					if (item) AppTray.run(root.trayId, item, false);
				} else if (event.key === Qt.Key_Menu) {
					const item = root.keyItems[root.keyIndex];
					const slot = root.slotById[item?.id ?? ""];
					root.menuA = slot ? slot.a + slot.la / 2 : root.center;
					root.menuItem = item ?? null;
				} else if (event.key === Qt.Key_Escape) {
					if (root.menuOpen) root.menuItem = null;
					else if (root.groupOpen) root.groupId = "";
					else AppTray.keyboardTray = "";
				} else return;
				event.accepted = true;
			}
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

			visible: root.reveal === "click" && root.active
			x: r.x
			y: r.y
			width: r.width
			height: r.height
			radius: Math.min(width, height) / 2
			color: handleMouse.containsMouse ? root.accent : Qt.alpha(Theme.text, 0.45)
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
				root.aim(drag);
			}
			onPositionChanged: drag => root.aim(drag)
			onExited: {
				root.dropping = false;
				root.dropAt = -1;
				root.targetId = "";
				springTimer.stop();
			}
			onDropped: drop => {
				const target = root.itemsById[root.targetId];
				const at = root.dropAt;
				root.dropping = false;
				root.dropAt = -1;
				root.targetId = "";
				springTimer.stop();
				if (target?.kind === "group") {
					AppTray.addToGroup(root.trayId, target.id, AppTray.itemsOfDrop(drop).filter(item => item.kind !== "trayfile"));
				} else if (target) {
					AppTray.openWith(root.trayId, target, AppTray.pathsOfDrop(drop));
				} else {
					const items = AppTray.itemsOfDrop(drop);
					if (items.length === 0) return;
					AppTray.addItems(root.trayId, items, at);
				}
				drop.accept(Qt.CopyAction);
			}
		}

		// slides out of the edge
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

					readonly property color fill: root.tray.look === "solid" ? Theme.layer1 : (root.tray.look === "bare" ? "transparent" : Theme.glass)

					anchors.fill: parent
					radius: Math.min(width, height) * 0.36
					color: root.tray.accent !== "theme" && root.tray.look !== "bare" ? Qt.tint(plate.fill, Qt.alpha(root.accent, 0.16)) : plate.fill
					border.width: root.keyboard ? 1.5 : 1
					border.color: root.dropping || root.keyboard ? Qt.alpha(root.accent, 0.75) : (root.tray.look === "bare" ? Qt.alpha(Theme.text, 0.25) : (root.tray.accent !== "theme" ? Qt.alpha(root.accent, 0.35) : Theme.outline))

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

			// the ring of the keyboard glides from item to item
			Rectangle {
				readonly property var slot: root.slotById[root.keyItems[root.keyIndex]?.id ?? "-"] ?? null
				readonly property rect r: slot ? root.rect(slot.a - 4, root.gap + root.pad - 4, slot.la + 8, root.size * slot.s + 8) : Qt.rect(0, 0, 0, 0)

				z: 5
				x: r.x
				y: r.y
				width: r.width
				height: r.height
				radius: Math.min(width, height) * 0.3
				color: Qt.alpha(root.accent, 0.12)
				border.width: 2
				border.color: root.accent
				opacity: root.keyboard && !!slot ? 1 : 0
				scale: root.keyboard ? 1 : 1.3

				Behavior on x {
					SpatialAnim {
						duration: Motion.medium
					}
				}
				Behavior on y {
					SpatialAnim {
						duration: Motion.medium
					}
				}
				Behavior on width {
					SpatialAnim {
						duration: Motion.medium
					}
				}
				Behavior on opacity {
					Anim {
						duration: Motion.short
					}
				}
				Behavior on scale {
					SpatialAnim {
						duration: Motion.long
					}
				}
			}

			// where a drop would land: it opens and glides along with the pointer
			Rectangle {
				id: gapMark

				readonly property var slot: root.slotById[""]
				property rect last: Qt.rect(0, 0, 0, 0)
				readonly property rect r: slot ? root.rect(slot.a + root.size * 0.08, root.gap + root.pad + root.size * 0.08, slot.la - root.size * 0.16, root.size * 0.84) : gapMark.last

				onRChanged: if (gapMark.slot) gapMark.last = gapMark.r
				visible: opacity > 0.01
				opacity: !!slot && !root.removing ? 1 : 0
				scale: !!slot && !root.removing ? 1 : 0.6
				x: r.x
				y: r.y
				width: Math.max(0, r.width)
				height: Math.max(0, r.height)

				Behavior on x {
					SpatialAnim {
						duration: Motion.short
					}
				}
				Behavior on y {
					SpatialAnim {
						duration: Motion.short
					}
				}
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
				radius: Math.min(width, height) * 0.27
				color: Qt.alpha(root.accent, 0.16)
				border.width: 1.5
				border.color: Qt.alpha(root.accent, 0.6)
			}

			// the items
			Repeater {
				model: itemModel

				delegate: Item {
					id: cell

					required property string itemId
					readonly property bool going: !!root.leaving[cell.itemId]
					// what it was and where it stood, kept for its way out
					property var kept: null
					property var keptSlot: null
					readonly property var item: root.itemsById[cell.itemId] ?? cell.kept
					readonly property string kind: String(cell.item?.kind ?? "")
					readonly property bool dragged: root.dragId === cell.itemId
					readonly property var slot: root.slotById[cell.itemId] ?? cell.keptSlot ?? { a: root.baseStart, la: root.size, s: 1 }
					onItemChanged: if (root.itemsById[cell.itemId]) cell.kept = root.itemsById[cell.itemId]
					onSlotChanged: if (root.slotById[cell.itemId]) cell.keptSlot = root.slotById[cell.itemId]
					onGoingChanged: if (cell.going) leaveAnim.restart()
					readonly property real s: cell.dragged ? 1.08 : cell.slot.s
					readonly property real la: cell.dragged ? root.factorOf(cell.itemId) * root.size * 1.08 : cell.slot.la
					readonly property real lc: cell.kind === "separator" ? root.thick * 0.56 : root.size * cell.s
					readonly property real cOffset: cell.kind === "separator" ? (root.thick - cell.lc) / 2 - root.pad : 0
					property real bounce: 0
					property real enter: 0
					property real wobble: 0
					readonly property int windows: root.tray.dots ? AppTray.windowsOf(cell.item).length : 0
					readonly property bool hovered: mouse.containsMouse && root.dragId === ""
					readonly property bool keyed: root.keyboard && root.keyItems[root.keyIndex]?.id === cell.itemId
					readonly property bool targeted: root.targetId === cell.itemId
					readonly property var badge: root.tray.badges ? AppTray.badgeOf(cell.item) : ({ count: 0, text: "", progress: -1, dot: false, urgent: false })
					readonly property real at: cell.dragged ? root.dragA - cell.la / 2 : cell.slot.a
					readonly property real lift: cell.dragged ? Math.max(0, root.dragC - root.gap - root.pad - root.size / 2) : 0
					readonly property rect r: root.rect(cell.at, root.gap + root.pad + cell.cOffset + cell.lift + cell.bounce, cell.la, cell.lc)

					x: cell.r.x
					y: cell.r.y
					width: cell.r.width
					height: cell.r.height
					z: cell.dragged ? 10 : (cell.hovered ? 2 : 1)
					opacity: cell.enter * (cell.dragged && root.removing ? 0.45 : 1) * (cell.item?.transient ? 0.85 : 1)
					scale: (0.4 + 0.6 * cell.enter) * (cell.targeted ? 1.18 : 1)
					rotation: cell.wobble

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
					Behavior on scale {
						SpatialAnim {
							duration: Motion.medium
						}
					}

					onHoveredChanged: {
						if (cell.hovered) root.hoveredId = cell.itemId;
						else if (root.hoveredId === cell.itemId) root.hoveredId = "";
					}

					Component.onCompleted: {
						cell.kept = cell.item;
						cell.keptSlot = root.slotById[cell.itemId] ?? null;
						enterAnim.start();
					}

					// out: it sinks into the edge and shrinks, then it is gone
					SequentialAnimation {
						id: leaveAnim

						ParallelAnimation {
							NumberAnimation {
								target: cell
								property: "enter"
								to: 0
								duration: Motion.medium
								easing.type: Easing.BezierSpline
								easing.bezierCurve: Motion.accel
							}
							NumberAnimation {
								target: cell
								property: "bounce"
								to: -root.size * 0.3
								duration: Motion.medium
								easing.type: Easing.InCubic
							}
						}
						ScriptAction {
							script: root.forget(cell.itemId)
						}
					}

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
							easing.type: Easing.BezierSpline
							easing.bezierCurve: Motion.spatial
						}
					}

					// something new to say: it shakes its head
					SequentialAnimation {
						id: wobbleAnim

						NumberAnimation { target: cell; property: "wobble"; to: 9; duration: 70 }
						NumberAnimation { target: cell; property: "wobble"; to: -8; duration: 90 }
						NumberAnimation { target: cell; property: "wobble"; to: 6; duration: 90 }
						NumberAnimation { target: cell; property: "wobble"; to: -3; duration: 80 }
						NumberAnimation { target: cell; property: "wobble"; to: 0; duration: 90 }
					}

					property int lastCount: 0
					onBadgeChanged: {
						if (cell.badge.count > cell.lastCount && root.lively && cell.enter > 0.99) wobbleAnim.restart();
						cell.lastCount = cell.badge.count;
					}

					Connections {
						target: AppTray

						function onLaunched(itemId) {
							if (itemId === cell.itemId && root.lively) hopAnim.restart();
						}
					}

					// a line between groups of items
					Rectangle {
						visible: cell.kind === "separator"
						anchors.centerIn: parent
						width: root.vertical ? parent.width : 2
						height: root.vertical ? 2 : parent.height
						radius: 1
						color: Qt.alpha(Theme.text, 0.22)
					}

					// a gap shows itself only while the tray is arranged
					Rectangle {
						visible: cell.kind === "spacer" && (root.editingHere || root.dragId !== "" || cell.hovered)
						anchors.fill: parent
						anchors.margins: 4
						radius: 6
						color: "transparent"
						border.width: 1
						border.color: Qt.alpha(Theme.text, 0.2)
					}

					TrayWidget {
						visible: cell.kind === "widget"
						anchors.fill: parent
						item: cell.kind === "widget" ? cell.item : null
						lifted: cell.hovered || cell.keyed
					}

					TrayIcon {
						visible: cell.kind !== "widget" && cell.kind !== "separator" && cell.kind !== "spacer"
						anchors.fill: parent
						item: visible ? cell.item : null
						lifted: cell.hovered || cell.dragged || cell.keyed || cell.targeted
						scale: mouse.pressed && !cell.dragged ? 0.9 : 1

						Behavior on scale {
							SpatialAnim {
								duration: Motion.short
							}
						}
					}

					TrayBadge {
						anchors.fill: parent
						visible: cell.kind !== "separator" && cell.kind !== "spacer" && !cell.dragged && root.collapse < 0.5
						badge: cell.badge
						accent: root.accent
						lively: root.lively
					}

					// about to take what is dropped
					Rectangle {
						visible: cell.targeted
						anchors.fill: parent
						anchors.margins: -4
						radius: Math.min(width, height) * 0.3
						color: "transparent"
						border.width: 2
						border.color: root.accent
					}

					// taken out when let go here
					Rectangle {
						visible: cell.dragged && root.removing
						anchors.centerIn: parent
						width: Math.min(parent.width, parent.height) * 0.5
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
						readonly property rect r: root.rect(cell.at + cell.la / 2 - 12, root.gap + 2, 24, 4)

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
								color: root.accent
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
							root.previewId = "";
							const at = root.local(p.x, p.y);
							root.dragA = at.a;
							root.dragC = at.c;
							root.dragId = cell.itemId;
							// over a group: it goes in
							const under = root.itemAt(at.a, at.c);
							root.targetId = under !== "" && under !== cell.itemId && root.itemsById[under]?.kind === "group" && cell.kind !== "group" ? under : "";
						}
						onReleased: event => {
							if (!cell.dragged) return;
							const p = mapToItem(stage, event.x, event.y);
							root.finishDrag(cell.item, p);
						}
						onCanceled: {
							root.dragId = "";
							root.targetId = "";
						}
						onClicked: event => {
							if (mouse.moved) return;
							if (event.button === Qt.RightButton) {
								root.menuA = cell.at + cell.la / 2;
								root.groupId = "";
								root.previewId = "";
								root.menuItem = root.menuItem?.id === cell.itemId ? null : cell.item;
							} else if (cell.kind === "group" || (cell.kind === "file" && cell.item.folder && cell.item.stack)) {
								root.openGroup(cell.itemId);
							} else if (cell.kind !== "separator" && cell.kind !== "spacer") {
								root.menuItem = null;
								root.groupId = "";
								root.previewId = "";
								AppTray.run(root.trayId, cell.item, event.button === Qt.MiddleButton);
							}
						}
						onWheel: wheel => {
							AppTray.scrolled(cell.item, wheel.angleDelta.y > 0);
							wheel.accepted = true;
						}
					}

					// its name, inside of it
					Item {
						readonly property real w: Math.min(260, label.implicitWidth + 20)
						readonly property real h: label.implicitHeight + 10
						readonly property bool turned: root.vertical && root.tray.labelStyle === "vertical"
						readonly property real c: root.gap + root.thick + root.size * (cell.s - 1) + 10
						readonly property rect r: root.vertical
							? (turned ? root.rect(cell.at + cell.la / 2 - w / 2, c, w, h) : root.rect(cell.at + cell.la / 2 - h / 2, c, h, w))
							: root.rect(cell.at + cell.la / 2 - w / 2, c, w, h)
						readonly property bool up: root.tray.labels && cell.hovered && !root.menuOpen && !root.groupOpen && root.previewId === "" && cell.kind !== "separator" && cell.kind !== "spacer"

						parent: slider
						x: r.x
						y: r.y
						width: r.width
						height: r.height
						z: 20
						opacity: up ? 1 : 0
						scale: up ? 1 : 0.85

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

						Rectangle {
							anchors.centerIn: parent
							width: parent.turned ? parent.height : parent.width
							height: parent.turned ? parent.width : parent.height
							rotation: parent.turned ? (root.edge === "left" ? -90 : 90) : 0
							radius: Math.min(width, height) / 2
							color: Theme.layer3
							border.width: 1
							border.color: Theme.outline

							StyledText {
								id: label

								anchors.centerIn: parent
								width: Math.min(implicitWidth, 240)
								text: AppTray.nameOf(cell.item) + (cell.windows > 1 ? `  ·  ${cell.windows}` : "") + (cell.item?.transient ? "  ·  open" : "")
								font.pixelSize: Theme.size.small
								font.weight: Font.Medium
							}
						}
					}
				}
			}
		}

		// the menu of an item
		Rectangle {
			id: menu

			readonly property var entries: root.menuEntries(root.menuItem)
			readonly property real w: 240
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
						required property int index
						property real shown: 0

						width: parent.width
						height: 34
						opacity: row.shown
						transform: Translate {
							x: (1 - row.shown) * (root.edge === "right" ? 12 : (root.edge === "left" ? -12 : 0))
							y: (1 - row.shown) * (root.edge === "bottom" ? 10 : (root.edge === "top" ? -10 : 0))
						}

						// one after the other, from the edge outwards
						SequentialAnimation {
							running: root.menuOpen
							PauseAnimation {
								duration: row.index * 22
							}
							NumberAnimation {
								target: row
								property: "shown"
								to: 1
								duration: Motion.medium
								easing.type: Easing.OutCubic
							}
						}
						Connections {
							target: root

							function onMenuOpenChanged() {
								if (!root.menuOpen) row.shown = 0;
							}
						}
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

		// a group or a stacked folder, open: a fan of its newest or a grid
		Rectangle {
			id: groupPanel

			readonly property var item: root.groupItem
			readonly property bool folder: item?.kind === "file"
			readonly property bool fan: folder && item?.view !== "grid" && !root.vertical
			readonly property int max: groupPanel.fan ? 9 : 30
			readonly property int count: Math.min(groupPanel.max, entries.count)
			readonly property int columns: groupPanel.fan ? 1 : Math.max(1, Math.min(5, Math.ceil(Math.sqrt(Math.max(1, groupPanel.count)))))
			readonly property real cellW: groupPanel.fan ? 250 : 86
			readonly property real cellH: groupPanel.fan ? 46 : 88
			readonly property real w: groupPanel.columns * groupPanel.cellW + 20
			readonly property real h: Math.min(root.depth - root.gap - root.thick - 24, Math.ceil(Math.max(1, groupPanel.count) / groupPanel.columns) * groupPanel.cellH + 58)
			readonly property real la: root.vertical ? h : w
			readonly property real lc: root.vertical ? w : h
			readonly property real a: Math.max(8, Math.min(root.len - la - 8, root.groupA - la / 2))
			readonly property rect r: root.rect(groupPanel.a, root.gap + root.thick + 10, groupPanel.la, groupPanel.lc)

			x: groupPanel.r.x
			y: groupPanel.r.y
			width: groupPanel.w
			height: groupPanel.h
			radius: Theme.radius.huge
			color: groupPanel.fan ? "transparent" : Theme.layer2
			border.width: groupPanel.fan ? 0 : 1
			border.color: groupDrop.containsDrag ? root.accent : Theme.outline
			visible: groupPanel.opacity > 0.01
			opacity: root.groupOpen ? 1 : 0
			scale: root.groupOpen ? 1 : 0.85
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

			FolderListModel {
				id: files

				folder: groupPanel.folder ? `file://${groupPanel.item.path}` : ""
				showDirs: true
				showDotAndDotDot: false
				sortField: FolderListModel.Time
			}

			// into the group, or into the folder
			DropArea {
				id: groupDrop

				anchors.fill: parent
				onEntered: drag => drag.accepted = AppTray.accepts(drag)
				onDropped: drop => {
					if (groupPanel.folder) AppTray.openWith(root.trayId, groupPanel.item, AppTray.pathsOfDrop(drop));
					else AppTray.addToGroup(root.trayId, root.groupId, AppTray.itemsOfDrop(drop).filter(item => item.kind !== "trayfile"));
					drop.accept(Qt.CopyAction);
				}
			}

			StyledText {
				id: groupTitle

				anchors.left: parent.left
				anchors.right: openButton.left
				anchors.top: parent.top
				anchors.margins: 12
				text: AppTray.nameOf(groupPanel.item)
				font.weight: Font.DemiBold
				visible: !groupPanel.fan
			}

			TextButton {
				id: openButton

				anchors.right: parent.right
				anchors.top: parent.top
				anchors.margins: 6
				implicitHeight: 28
				visible: groupPanel.folder && !groupPanel.fan
				variant: "ghost"
				icon: "folder_open"
				text: "Open"
				onActivated: {
					Quickshell.execDetached(["xdg-open", String(groupPanel.item.path)]);
					root.groupId = "";
				}
			}

			Flickable {
				anchors.fill: parent
				anchors.topMargin: groupPanel.fan ? 0 : 44
				anchors.margins: 10
				contentHeight: grid.height
				clip: !groupPanel.fan
				interactive: contentHeight > height
				boundsBehavior: Flickable.StopAtBounds

				Grid {
					id: grid

					columns: groupPanel.columns
					spacing: 0
					// a fan grows away from the edge: the newest nearest to it
					layoutDirection: Qt.LeftToRight
					rotation: groupPanel.fan && root.edge === "bottom" ? 180 : 0

					// a folder's files straight from the model (its count does not
					// tell bindings), a group's items from the tray
					Repeater {
						id: entries

						model: !root.groupOpen ? 0 : (groupPanel.folder ? files : (groupPanel.item?.items ?? []))

						delegate: Item {
							id: entry

							required property int index
							readonly property var child: groupPanel.folder ? null : (groupPanel.item?.items ?? [])[entry.index]
							readonly property string path: groupPanel.folder ? String(files.get(entry.index, "filePath") ?? "") : ""
							readonly property bool dir: groupPanel.folder && !!files.get(entry.index, "fileIsDir")
							readonly property var asItem: groupPanel.folder ? { kind: "file", path: entry.path, name: entry.path.split("/").pop(), folder: entry.dir } : entry.child

							property real out: 0

							visible: entry.index < groupPanel.max
							width: groupPanel.cellW
							height: groupPanel.cellH
							rotation: grid.rotation
							opacity: Math.min(1, entry.out * 1.4)
							scale: 0.6 + 0.4 * entry.out
							// from the icon in the tray outwards, one after the other
							transform: Translate {
								x: (1 - entry.out) * (groupPanel.fan ? 0 : (root.groupA - groupPanel.a - entry.x - groupPanel.cellW / 2) * (root.vertical ? 0 : 0.6))
								y: (1 - entry.out) * (groupPanel.fan ? groupPanel.cellH * (entry.index + 1) * 0.6 : groupPanel.cellH * 0.6)
							}
							Component.onCompleted: fanIn.start()

							SequentialAnimation {
								id: fanIn

								PauseAnimation {
									duration: Math.min(entry.index, 12) * (groupPanel.fan ? 35 : 22)
								}
								NumberAnimation {
									target: entry
									property: "out"
									to: 1
									duration: Motion.long
									easing.type: Easing.BezierSpline
									easing.bezierCurve: Motion.spatial
								}
							}

							Rectangle {
								anchors.fill: parent
								anchors.margins: 3
								radius: Theme.radius.medium
								color: entryMouse.containsMouse || entryDrop.containsDrag ? Theme.layer3 : (groupPanel.fan ? Theme.layer2 : "transparent")
								border.width: groupPanel.fan || entryDrop.containsDrag ? 1 : 0
								border.color: entryDrop.containsDrag ? root.accent : Theme.outline
								// a fan leans a little more the further it goes
								transform: Rotation {
									origin.x: 0
									origin.y: groupPanel.cellH / 2
									angle: groupPanel.fan ? (root.edge === "top" ? -1 : 1) * entry.index * 1.6 : 0
								}
							}

							TrayIcon {
								id: entryIcon

								x: groupPanel.fan ? 10 : (parent.width - width) / 2
								y: groupPanel.fan ? (parent.height - height) / 2 : 8
								width: groupPanel.fan ? 30 : 44
								height: width
								item: entry.asItem
								shadow: !groupPanel.fan
								lifted: entryMouse.containsMouse
							}

							StyledText {
								anchors.left: groupPanel.fan ? entryIcon.right : parent.left
								anchors.leftMargin: groupPanel.fan ? 10 : 4
								anchors.right: parent.right
								anchors.rightMargin: 6
								y: groupPanel.fan ? (parent.height - height) / 2 : 58
								horizontalAlignment: groupPanel.fan ? Text.AlignLeft : Text.AlignHCenter
								text: AppTray.nameOf(entry.asItem)
								tone: Theme.textMuted
								font.pixelSize: Theme.size.small
							}

							// a folder in it takes what is dropped
							DropArea {
								id: entryDrop

								anchors.fill: parent
								enabled: entry.dir
								onDropped: drop => {
									AppTray.openWith(root.trayId, entry.asItem, AppTray.pathsOfDrop(drop));
									drop.accept(Qt.CopyAction);
								}
							}

							// files go out to other apps
							Item {
								id: fileGhost

								width: 1
								height: 1
								Drag.dragType: Drag.Automatic
								Drag.active: groupPanel.folder && entryMouse.drag.active
								Drag.supportedActions: Qt.CopyAction | Qt.MoveAction | Qt.LinkAction
								Drag.proposedAction: Qt.CopyAction
								Drag.mimeData: groupPanel.folder ? { "text/uri-list": `file://${encodeURI(entry.path)}\r\n` } : AppTray.mimeFor(entry.child ?? {})
							}

							MouseArea {
								id: entryMouse

								anchors.fill: parent
								hoverEnabled: true
								acceptedButtons: Qt.LeftButton | Qt.RightButton
								cursorShape: Qt.PointingHandCursor
								drag.target: fileGhost
								drag.threshold: 8
								onPressed: event => {
									fileGhost.x = event.x;
									fileGhost.y = event.y;
								}
								onClicked: event => {
									if (event.button === Qt.RightButton && !groupPanel.folder) {
										AppTray.takeOutOfGroup(root.trayId, root.groupId, entry.child.id);
										return;
									}
									if (groupPanel.folder) Quickshell.execDetached(["xdg-open", entry.path]);
									else AppTray.run(root.trayId, entry.child, false);
									root.groupId = "";
								}
							}
						}
					}
				}
			}

			StyledText {
				anchors.centerIn: parent
				visible: groupPanel.count === 0
				text: groupPanel.folder ? "Empty" : "Drop something here"
				tone: Theme.textSubtle
			}
		}

		// pictures of an app's windows
		Rectangle {
			id: previews

			readonly property int count: Math.min(5, root.previewWindows.length)
			readonly property real cardW: 220
			readonly property real cardH: 160
			readonly property real w: root.vertical ? previews.cardW + 20 : previews.count * (previews.cardW + 8) + 12
			readonly property real h: root.vertical ? previews.count * (previews.cardH + 8) + 12 : previews.cardH + 20
			readonly property real la: root.vertical ? h : w
			readonly property real lc: root.vertical ? w : h
			readonly property real a: Math.max(8, Math.min(root.len - la - 8, root.previewA - la / 2))
			readonly property rect r: root.rect(previews.a, root.gap + root.thick + root.size * root.magnify + 12, previews.la, previews.lc)

			x: previews.r.x
			y: previews.r.y
			width: Math.max(1, previews.w)
			height: Math.max(1, previews.h)
			radius: Theme.radius.large
			color: Theme.layer2
			border.width: 1
			border.color: Theme.outline
			visible: previews.opacity > 0.01
			opacity: root.previewId !== "" && previews.count > 0 ? 1 : 0
			scale: root.previewId !== "" && previews.count > 0 ? 1 : 0.9
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

			Grid {
				anchors.centerIn: parent
				columns: root.vertical ? 1 : previews.count
				spacing: 8

				Repeater {
					model: root.previewId !== "" ? root.previewWindows.slice(0, 5) : []

					delegate: Rectangle {
						id: card

						required property var modelData
						required property int index
						property real shown: 0

						opacity: card.shown
						scale: 0.85 + 0.15 * card.shown
						Component.onCompleted: cardIn.start()

						SequentialAnimation {
							id: cardIn

							PauseAnimation {
								duration: card.index * 45
							}
							NumberAnimation {
								target: card
								property: "shown"
								to: 1
								duration: Motion.long
								easing.type: Easing.BezierSpline
								easing.bezierCurve: Motion.spatial
							}
						}
						readonly property string shot: AppTray.shotsRev >= 0 ? (AppTray.shotFiles[card.modelData.id] ?? "") : ""

						width: previews.cardW
						height: previews.cardH
						radius: Theme.radius.medium
						color: cardMouse.containsMouse ? Theme.layer3 : Theme.layer1
						border.width: card.modelData.is_focused ? 1.5 : 0
						border.color: root.accent

						Image {
							anchors.fill: parent
							anchors.margins: 6
							anchors.bottomMargin: 28
							source: card.shot !== "" ? `file://${card.shot}?${AppTray.shotsRev}` : ""
							fillMode: Image.PreserveAspectFit
							cache: false
							asynchronous: true
							opacity: status === Image.Ready ? 1 : 0

							Behavior on opacity {
								Anim {
									duration: Motion.medium
								}
							}
						}

						StyledText {
							anchors.left: parent.left
							anchors.right: closeWindow.left
							anchors.bottom: parent.bottom
							anchors.margins: 8
							text: String(card.modelData.title ?? "")
							font.pixelSize: Theme.size.small
						}

						MouseArea {
							id: cardMouse

							anchors.fill: parent
							hoverEnabled: true
							cursorShape: Qt.PointingHandCursor
							onClicked: {
								Niri.focusWindow(card.modelData.id);
								root.previewId = "";
							}
						}

						IconButton {
							id: closeWindow

							anchors.right: parent.right
							anchors.bottom: parent.bottom
							anchors.margins: 4
							width: 22
							height: 22
							icon: "close"
							variant: "ghost"
							onClicked: Niri.closeWindow(card.modelData.id)
						}
					}
				}
			}
		}
	}

	// the other trays come out while an item of this one is carried
	Binding {
		target: AppTray
		property: "carrying"
		value: true
		when: root.dragId !== ""
	}

	// a little cloud where an item was let go out of the tray
	Item {
		id: puff

		property point at: Qt.point(0, 0)
		property real grow: 0

		parent: stage
		x: puff.at.x - 40
		y: puff.at.y - 40
		width: 80
		height: 80
		z: 50
		visible: puffAnim.running

		Repeater {
			model: 7

			delegate: Rectangle {
				required property int index
				readonly property real angle: index / 7 * Math.PI * 2

				width: 14 + (index % 3) * 4
				height: width
				radius: width / 2
				color: Qt.alpha(Theme.text, 0.5)
				x: 40 - width / 2 + Math.cos(angle) * 30 * puff.grow
				y: 40 - height / 2 + Math.sin(angle) * 30 * puff.grow
				scale: 0.4 + puff.grow * 0.8
				opacity: 1 - puff.grow
			}
		}

		NumberAnimation {
			id: puffAnim

			target: puff
			property: "grow"
			from: 0
			to: 1
			duration: 420
			easing.type: Easing.OutCubic
		}
	}

	// ── how a drag inside the tray ends ─────────────────────────────────
	function finishDrag(item, p) {
		const removing = root.removing;
		const target = root.targetId;
		const ids = root.items.map(each => each.id).filter(id => id !== item.id);
		const index = root.insertIndex(root.dragA, ids);
		root.dragId = "";
		root.targetId = "";
		if (!item) return;
		const fresh = item.transient ? { kind: "app", app: item.app } : null;
		// into a group of this tray
		if (target !== "") {
			AppTray.addToGroup(root.trayId, target, [fresh ?? item]);
			return;
		}
		// onto another tray
		const g = root.globalOf(p.x, p.y);
		const other = AppTray.trayAt(g.x, g.y, root.trayId);
		if (other) {
			if (fresh) AppTray.addItems(other.trayId, [fresh], other.index);
			else AppTray.moveToTray(root.trayId, item.id, other.trayId, other.index);
			return;
		}
		if (fresh) {
			if (!removing) AppTray.addItems(root.trayId, [fresh], Math.min(index, (root.tray.items ?? []).length));
			return;
		}
		if (removing) {
			puff.at = p;
			puffAnim.restart();
			root.poofed = item.id;
			AppTray.removeItem(root.trayId, item.id);
		}
		else AppTray.moveItem(root.trayId, item.id, Math.min(index, (root.tray.items ?? []).length - 1));
	}

	// ── what something dragged in is over ──────────────────────────────
	function aim(drag) {
		const at = root.local(drag.x, drag.y);
		const under = root.itemAt(at.a, at.c);
		const item = root.itemsById[under];
		const files = drag.hasUrls && Array.from(drag.urls ?? []).some(url => String(url).startsWith("file://"));
		const formats = Array.from(drag.formats ?? []).map(String);
		const ours = formats.includes(AppTray.mime);
		// onto an item that does something with files, or into a group
		if (item && ((files && !ours && AppTray.takesFiles(item)) || (item.kind === "group" && (ours || files)))) {
			root.targetId = under;
			root.dropAt = -1;
		} else {
			root.targetId = "";
			root.dropAt = root.insertIndex(at.a, root.items.map(each => each.id));
		}
		// resting on a group or a stack opens it
		if (item && (item.kind === "group" || (item.kind === "file" && item.folder && item.stack))) {
			if (springTimer.target !== under || !springTimer.running) {
				springTimer.target = under;
				springTimer.restart();
			}
		} else {
			springTimer.stop();
		}
	}
}
