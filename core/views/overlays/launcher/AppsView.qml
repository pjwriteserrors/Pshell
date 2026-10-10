pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../../../lib/AppSearch.js" as AppSearch

// Launcher apps. Nothing typed: the favourites on a dock (what is pinned,
// filled up with what is used most; Alt+1…9 starts one) over the apps on
// shelves by kind (All, Internet, Develop, …; Ctrl+←/→ or a click). Typed:
// the spotlight on the left shows what Enter starts and what else it can
// do (the app's own actions, its open window, pin, hide), the results on
// the right, commands that answer first. → or Ctrl+Enter walks the
// actions, Shift+Enter goes to the open window, Ctrl+P pins to the dock,
// Ctrl+H hides an app (the Hidden shelf brings it back). A right click
// shows a tile's actions.
Item {
	id: root

	property bool active: false
	property string query: ""
	// the launches by app (launcher-usage.json)
	property var usage: ({})
	// commands that answer the search, best first: [{ command, score }]
	property var commands: []
	// the commands kept on top of the palette (by token)
	property var commandPins: []
	// whether the cursor of the search field is at its end (→ opens the actions)
	property bool cursorAtEnd: true
	// entry → icon path, command → glyph name
	property var iconFor: entry => ""
	property var glyphFor: command => "console"

	signal launchRequested(var entry)
	signal actionRequested(var entry, var action)
	signal commandRequested(var command)
	signal commandPinRequested(var command)
	signal webSearchRequested(string text)
	signal closeRequested
	// the tiles sweep in: on opening, on another shelf
	signal cascade

	readonly property bool searching: root.query.trim() !== ""
	readonly property int columns: 8
	readonly property int dockSlots: 8
	readonly property real dockHeight: 98
	readonly property real cellHeight: 92
	readonly property real rowHeight: 50
	// the height the body wants: tall while browsing, as tall as the results while searching
	readonly property real preferredHeight: {
		if (!root.searching) return 470;
		const sections = (root.results.some(result => result.kind === "command") ? 1 : 0) + (root.results.some(result => result.kind === "app") ? 1 : 0);
		const list = root.results.length * root.rowHeight + sections * 26 + 8;
		const spot = 248 + spotActions.count * 36;
		return Math.max(300, Math.min(470, Math.max(list, spot)));
	}

	// ── what there is ───────────────────────────────────────────────────
	readonly property var entries: {
		if (!Plugins.on("apps")) return [];
		const list = [];
		for (const entry of DesktopEntries.applications.values) {
			if (!entry || entry.noDisplay || entry.hidden) continue;
			const categories = Array.from(entry.categories || []).map(String);
			list.push({
				key: String(entry.id || entry.name || ""),
				entry: entry,
				name: String(entry.name || entry.id || "App"),
				genericName: String(entry.genericName || ""),
				comment: String(entry.comment || ""),
				keywords: Array.from(entry.keywords || []).map(String),
				id: String(entry.id || ""),
				shelf: AppSearch.shelfOf(categories)
			});
		}
		list.sort((a, b) => a.name.localeCompare(b.name));
		// two apps of one name (Files: Nautilus, Nemo) are told apart by what they run as
		const names = {};
		for (const item of list) names[item.name] = (names[item.name] || 0) + 1;
		for (const item of list) item.also = names[item.name] > 1 ? AppSearch.runName(item.id) : "";
		return list;
	}
	readonly property var byKey: {
		const map = {};
		for (const item of root.entries) map[item.key] = item;
		return map;
	}

	// pinned to the dock and hidden from it all (launcher-apps.json)
	property var pins: []
	property var hidden: []

	readonly property var shown: root.entries.filter(item => !root.hidden.includes(item.key))
	readonly property var dock: {
		const use = item => Number(root.usage[item.key] || 0);
		const pinned = root.pins.map(key => root.byKey[key]).filter(item => item && !root.hidden.includes(item.key));
		const used = root.shown.filter(item => !root.pins.includes(item.key) && use(item) > 0).sort((a, b) => use(b) - use(a) || a.name.localeCompare(b.name));
		return pinned.concat(used).slice(0, root.dockSlots);
	}
	readonly property var shelves: {
		const list = AppSearch.shelves.filter(shelf => shelf.id === "all" || root.shown.some(item => item.shelf === shelf.id));
		if (root.hidden.length > 0) list.push({ id: "hidden", label: "Hidden", glyph: "eye_off_outline" });
		return list;
	}
	property string shelf: "all"
	readonly property int shelfIndex: Math.max(0, root.shelves.findIndex(each => each.id === root.shelf))
	readonly property var shelfApps: {
		if (root.shelf === "hidden") return root.entries.filter(item => root.hidden.includes(item.key));
		if (root.shelf === "all") return root.shown;
		return root.shown.filter(item => item.shelf === root.shelf);
	}
	onShelvesChanged: if (!root.shelves.some(each => each.id === root.shelf)) root.shelf = "all"

	// the windows of every app that has some, the last focused first
	readonly property var running: {
		const map = {};
		if (!root.active) return map;
		for (const window of Niri.windows) {
			const appId = String(window.app_id || "");
			if (appId === "") continue;
			const entry = DesktopEntries.heuristicLookup(appId);
			const key = entry ? String(entry.id || entry.name || "") : "";
			if (key === "") continue;
			(map[key] = map[key] || []).push(window);
		}
		for (const key in map) map[key].sort((a, b) => Niri.focusTimestampValue(b) - Niri.focusTimestampValue(a));
		return map;
	}

	// [{ key, kind: "command" | "app", command | item, indexes }]
	readonly property var results: {
		if (!root.searching) return [];
		const commands = root.commands.slice(0, 3).map(each => ({ key: `command:${each.command.command}`, kind: "command", command: each.command, score: each.score }));
		const apps = AppSearch.rank(root.shown, root.query, root.usage).slice(0, 40)
			.map(found => ({ key: `app:${found.key}`, kind: "app", item: root.byKey[found.key], indexes: found.indexes, field: found.field }));
		return commands.concat(apps);
	}
	readonly property var resultByKey: {
		const map = {};
		for (const result of root.results) map[result.key] = result;
		return map;
	}

	// ── where the keyboard is ───────────────────────────────────────────
	// "dock" | "grid" while browsing, "list" | "actions" while searching
	property string zone: "grid"
	property int dockIndex: 0
	property int gridIndex: 0
	property int listIndex: 0
	property int actionIndex: 0
	property bool altHeld: false
	// tiles made in this short while sweep in
	property bool cascading: false
	property int cascadeDirection: 0
	// the context menu of a tile: its result and where it was asked for
	property var menuTarget: null
	property point menuAt: Qt.point(0, 0)
	property int menuIndex: 0
	readonly property bool menuOpen: root.menuTarget !== null

	function appResult(item) {
		return item ? { key: `app:${item.key}`, kind: "app", item: item, indexes: [] } : null;
	}

	readonly property var current: {
		if (root.searching) return root.results[root.listIndex] || null;
		if (root.zone === "dock") return root.appResult(root.dock[root.dockIndex]);
		return root.appResult(root.shelfApps[root.gridIndex]);
	}
	readonly property var currentWindows: root.current?.kind === "app" ? (root.running[root.current.item.key] || []) : []
	// the rest of the name of the best app when what is typed starts it
	readonly property string completion: {
		const result = root.current;
		if (!root.searching || !root.cursorAtEnd || result?.kind !== "app") return "";
		const name = result.item.name;
		const typed = root.query;
		return name.toLowerCase().startsWith(typed.toLowerCase()) && name.length > typed.length ? name.slice(typed.length) : "";
	}

	// what can be done with a result, first what Enter does
	function actionsFor(result) {
		if (!result) return [];
		if (result.kind === "command") {
			const pinned = root.commandPins.includes(String(result.command.command));
			return [
				{ id: "run", label: result.command.children ? "Open" : "Run", glyph: "keyboard_return", hint: "↵" },
				{ id: "pin-command", label: pinned ? "Unpin from commands" : "Pin to commands", glyph: pinned ? "pin_off_outline" : "pin_outline", hint: "^P" }
			];
		}
		const item = result.item;
		const windows = root.running[item.key] || [];
		const list = [{ id: "open", label: windows.length > 0 ? "Open new" : "Open", glyph: "open_in_new", hint: "↵" }];
		if (windows.length > 0)
			list.push({ id: "focus", label: windows.length > 1 ? `Go to window (${windows.length})` : "Go to window", glyph: "arrow_right", hint: "⇧↵" });
		for (const action of Array.from(item.entry.actions || []))
			list.push({ id: "desktop", action: action, label: String(action.name || ""), glyph: "lightning_bolt", hint: "" });
		const pinned = root.pins.includes(item.key);
		list.push({ id: "pin", label: pinned ? "Take off the dock" : "Pin to the dock", glyph: pinned ? "pin_off_outline" : "pin_outline", hint: "^P" });
		const hidden = root.hidden.includes(item.key);
		list.push({ id: "hide", label: hidden ? "Show again" : "Hide", glyph: hidden ? "eye_outline" : "eye_off_outline", hint: "^H" });
		return list;
	}

	readonly property bool webFallback: root.searching && root.results.length === 0 && Plugins.on("web-search")
	readonly property var currentActions: root.webFallback
		? [{ id: "web", label: "Search the web", glyph: "web", hint: "↵" }]
		: root.actionsFor(root.current)
	readonly property var menuActions: root.actionsFor(root.menuTarget)

	function run(result, action, from) {
		if (action?.id === "web") {
			root.webSearchRequested(root.query.trim());
			return;
		}
		if (!result || !action) return;
		switch (action.id) {
		case "open":
		case "run":
			root.open(result, from);
			break;
		case "focus":
			root.focusWindow(result);
			break;
		case "desktop":
			root.flourish(from);
			root.actionRequested(result.item.entry, action.action);
			break;
		case "pin":
			root.togglePin(result.item.key);
			break;
		case "hide":
			root.toggleHidden(result.item.key);
			break;
		case "pin-command":
			root.commandPinRequested(result.command);
			break;
		}
		root.menuTarget = null;
	}

	function open(result, from) {
		if (!result) return;
		if (result.kind === "command") {
			root.commandRequested(result.command);
			return;
		}
		root.flourish(from);
		root.launchRequested(result.item.entry);
	}

	function focusWindow(result) {
		const windows = result?.kind === "app" ? (root.running[result.item.key] || []) : [];
		if (windows.length === 0) return false;
		Niri.focusWindow(windows[0].id);
		root.closeRequested();
		return true;
	}

	// ── state file ──────────────────────────────────────────────────────
	FileView {
		id: stateFile

		path: Paths.stateFile("launcher-apps.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const state = JSON.parse(String(text() || "{}")) || {};
				root.pins = Array.isArray(state.pins) ? state.pins.map(String) : [];
				root.hidden = Array.isArray(state.hidden) ? state.hidden.map(String) : [];
			} catch (error) {}
		}
	}

	function saveState() {
		stateFile.setText(JSON.stringify({ pins: root.pins, hidden: root.hidden }));
	}

	function togglePin(key) {
		root.pins = root.pins.includes(key) ? root.pins.filter(each => each !== key) : root.pins.concat([key]);
		if (root.pins.includes(key)) root.hidden = root.hidden.filter(each => each !== key);
		root.saveState();
	}

	function toggleHidden(key) {
		const hiding = !root.hidden.includes(key);
		root.hidden = hiding ? root.hidden.concat([key]) : root.hidden.filter(each => each !== key);
		if (hiding) root.pins = root.pins.filter(each => each !== key);
		root.saveState();
		root.clampSelection();
	}

	// ── moving ──────────────────────────────────────────────────────────
	function reset() {
		root.menuTarget = null;
		root.altHeld = false;
		root.shelf = "all";
		root.dockIndex = 0;
		root.selectGrid(0, false);
		root.zone = root.dock.length > 0 ? "dock" : "grid";
		root.listIndex = 0;
		root.actionIndex = 0;
		grid.contentY = grid.originY;
		root.replay(0);
	}

	function replay(direction) {
		root.cascadeDirection = direction;
		root.cascading = true;
		cascadeWindow.restart();
		root.cascade();
	}

	Timer {
		id: cascadeWindow

		interval: 420
		onTriggered: root.cascading = false
	}

	function clampSelection() {
		root.dockIndex = Math.max(0, Math.min(root.dock.length - 1, root.dockIndex));
		if (root.dock.length === 0 && root.zone === "dock") root.zone = "grid";
		root.selectGrid(root.gridIndex, false);
		root.listIndex = Math.max(0, Math.min(root.results.length - 1, root.listIndex));
		root.actionIndex = Math.max(0, Math.min(root.currentActions.length - 1, root.actionIndex));
	}

	function selectGrid(index, glide) {
		root.gridIndex = Math.max(0, Math.min(root.shelfApps.length - 1, index));
		grid.currentIndex = root.gridIndex;
		root.reveal(grid, root.gridIndex, glide);
	}

	function selectResult(index) {
		root.listIndex = Math.max(0, Math.min(root.results.length - 1, index));
		root.picked = true;
		root.pickedKey = root.results[root.listIndex]?.key ?? "";
		resultList.currentIndex = root.listIndex;
		root.actionIndex = 0;
		root.reveal(resultList, root.listIndex, true);
	}

	// brings an item into view, gliding there instead of jumping
	function reveal(view, index, glide) {
		if (index < 0) return;
		const from = view.contentY;
		view.positionViewAtIndex(index, view === grid ? GridView.Contain : ListView.Contain);
		const to = view.contentY;
		if (!glide || Math.abs(to - from) < 1) return;
		view.contentY = from;
		scroller.target = view;
		scroller.to = to;
		scroller.restart();
	}

	NumberAnimation {
		id: scroller

		property: "contentY"
		duration: Motion.medium
		easing.type: Easing.BezierSpline
		easing.bezierCurve: Motion.decel
	}

	function switchShelf(delta) {
		const count = root.shelves.length;
		if (count < 2) return;
		root.showShelf(root.shelves[(root.shelfIndex + delta + count) % count].id);
	}

	function showShelf(id) {
		const to = root.shelves.findIndex(each => each.id === id);
		if (to < 0 || id === root.shelf) return;
		root.replay(to > root.shelfIndex ? 1 : -1);
		root.shelf = id;
		root.zone = "grid";
		grid.contentY = grid.originY;
		root.selectGrid(0, false);
	}

	// the nearest tile of the other row, by where it stands
	function dockToGrid() {
		const tile = dockRepeater.itemAt(root.dockIndex);
		const x = tile ? tile.x + tile.width / 2 + dockRow.x : 0;
		const firstRow = Math.floor(grid.contentY / root.cellHeight) * root.columns;
		root.zone = "grid";
		root.selectGrid(firstRow + Math.max(0, Math.min(root.columns - 1, Math.floor(x / grid.cellWidth))), true);
	}

	function gridToDock() {
		const x = (root.gridIndex % root.columns + 0.5) * grid.cellWidth;
		let best = 0;
		let distance = Infinity;
		for (let i = 0; i < dockRepeater.count; i++) {
			const tile = dockRepeater.itemAt(i);
			const each = tile ? Math.abs(tile.x + dockRow.x + tile.width / 2 - x) : Infinity;
			if (each < distance) {
				distance = each;
				best = i;
			}
		}
		root.dockIndex = best;
		root.zone = "dock";
	}

	// up/down from the launcher
	function move(delta) {
		if (root.menuOpen) {
			root.menuIndex = Math.max(0, Math.min(root.menuActions.length - 1, root.menuIndex + delta));
			return;
		}
		if (root.searching) {
			if (root.zone === "actions") root.actionIndex = Math.max(0, Math.min(root.currentActions.length - 1, root.actionIndex + delta));
			else root.selectResult(root.listIndex + delta);
			return;
		}
		if (root.zone === "dock") {
			if (delta > 0 && root.shelfApps.length > 0) root.dockToGrid();
			return;
		}
		if (delta < 0 && root.gridIndex < root.columns) {
			if (root.dock.length > 0) root.gridToDock();
			return;
		}
		const next = root.gridIndex + delta * root.columns;
		if (next >= root.shelfApps.length && Math.floor(root.gridIndex / root.columns) === Math.floor((root.shelfApps.length - 1) / root.columns)) return;
		root.selectGrid(next, true);
	}

	function handleKey(event) {
		const ctrl = event.modifiers & Qt.ControlModifier;
		const alt = event.modifiers & Qt.AltModifier;
		if (event.key === Qt.Key_Alt) {
			root.altHeld = true;
			return false;
		}
		if (alt && event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
			const index = event.key - Qt.Key_1;
			if (index < root.dock.length) {
				root.dockIndex = index;
				root.open(root.appResult(root.dock[index]), dockRepeater.itemAt(index)?.iconItem ?? null);
			}
			return true;
		}
		if (ctrl && event.key === Qt.Key_P) {
			const result = root.menuTarget || root.current;
			if (result?.kind === "app") root.togglePin(result.item.key);
			else if (result?.kind === "command") root.commandPinRequested(result.command);
			root.menuTarget = null;
			return true;
		}
		if (ctrl && event.key === Qt.Key_H) {
			const result = root.menuTarget || root.current;
			if (result?.kind === "app") root.toggleHidden(result.item.key);
			root.menuTarget = null;
			return true;
		}
		if (event.key === Qt.Key_Left || event.key === Qt.Key_Right) {
			const step = event.key === Qt.Key_Left ? -1 : 1;
			if (root.menuOpen) {
				root.menuTarget = null;
				return true;
			}
			if (root.searching) {
				if (root.zone === "actions" && step < 0) {
					root.zone = "list";
					return true;
				}
				if (root.zone === "list" && step > 0 && root.cursorAtEnd && !ctrl && root.current) {
					root.zone = "actions";
					root.actionIndex = root.currentActions.length > 1 ? 1 : 0;
					return true;
				}
				return root.zone === "actions";
			}
			if (ctrl) {
				root.switchShelf(step);
				return true;
			}
			if (root.zone === "dock") root.dockIndex = Math.max(0, Math.min(root.dock.length - 1, root.dockIndex + step));
			else root.selectGrid(root.gridIndex + step, true);
			return true;
		}
		if (event.key === Qt.Key_PageDown || event.key === Qt.Key_PageUp) {
			if (!root.searching) root.switchShelf(event.key === Qt.Key_PageDown ? 1 : -1);
			return !root.searching;
		}
		return false;
	}

	function handleKeyRelease(event) {
		if (event.key === Qt.Key_Alt) root.altHeld = false;
	}

	function cancel() {
		if (root.menuOpen) {
			root.menuTarget = null;
			return true;
		}
		if (root.zone === "actions") {
			root.zone = "list";
			return true;
		}
		return false;
	}

	function activate(modifiers) {
		if (root.menuOpen) {
			root.run(root.menuTarget, root.menuActions[root.menuIndex], null);
			return;
		}
		const result = root.current;
		if (!result) {
			if (root.searching && Plugins.on("web-search")) root.webSearchRequested(root.query.trim());
			return;
		}
		if (root.searching && root.zone === "actions") {
			root.run(result, root.currentActions[root.actionIndex], spotIcon);
			return;
		}
		// (a result is there from here on)
		if (modifiers & Qt.ControlModifier) {
			root.showActions();
			return;
		}
		if ((modifiers & Qt.ShiftModifier) && root.focusWindow(result)) return;
		root.open(result, root.currentIconItem());
	}

	// Ctrl+Enter: the actions of what is picked
	function showActions() {
		if (root.searching) {
			root.zone = "actions";
			root.actionIndex = root.currentActions.length > 1 ? 1 : 0;
			return;
		}
		const tile = root.zone === "dock" ? dockRepeater.itemAt(root.dockIndex) : grid.currentItem;
		if (tile) root.openMenu(root.current, tile);
	}

	function openMenu(result, tile) {
		const at = tile.mapToItem(root, tile.width / 2, tile.height - 6);
		root.menuAt = Qt.point(at.x, at.y);
		root.menuIndex = 0;
		root.menuTarget = result;
	}

	function currentIconItem() {
		if (root.searching) return spotIcon;
		const tile = root.zone === "dock" ? dockRepeater.itemAt(root.dockIndex) : grid.currentItem;
		return tile?.iconItem ?? null;
	}

	// ── following the search ────────────────────────────────────────────
	property string lastQuery: ""
	// moved to a result by hand: it stays picked while the results change
	property bool picked: false
	property string pickedKey: ""

	onResultsChanged: {
		root.syncResults();
		const typed = root.query.trim().toLowerCase();
		if (typed !== root.lastQuery) {
			root.lastQuery = typed;
			root.picked = false;
			root.zone = root.searching ? "list" : (root.zone === "dock" && root.dock.length > 0 ? "dock" : "grid");
			resultList.contentY = resultList.originY;
		}
		const kept = root.picked ? root.results.findIndex(result => result.key === root.pickedKey) : -1;
		if (kept >= 0) {
			root.listIndex = kept;
			resultList.currentIndex = kept;
			return;
		}
		root.picked = false;
		// a command answers ahead of the apps when a word of it starts
		// with what is typed and no app's name does
		const best = root.commands[0];
		const app = root.results.find(result => result.kind === "app");
		const commandFirst = best && best.score >= 60 && !(app && app.item.name.toLowerCase().startsWith(typed));
		root.listIndex = commandFirst || !app ? 0 : root.results.indexOf(app);
		resultList.currentIndex = root.listIndex;
		root.clampSelection();
	}
	readonly property string currentKey: root.current?.key ?? ""
	onCurrentKeyChanged: if (root.searching) spotChange.restart()
	onActiveChanged: if (!root.active) root.altHeld = false

	// the list keeps rows that stay, so they glide to their new place
	ListModel {
		id: resultModel
	}

	function syncResults() {
		const wanted = {};
		for (const result of root.results) wanted[result.key] = true;
		for (let i = resultModel.count - 1; i >= 0; i--)
			if (!wanted[resultModel.get(i).key]) resultModel.remove(i);
		for (let i = 0; i < root.results.length; i++) {
			const result = root.results[i];
			if (i < resultModel.count && resultModel.get(i).key === result.key) continue;
			let at = -1;
			for (let j = i + 1; j < resultModel.count; j++) {
				if (resultModel.get(j).key === result.key) {
					at = j;
					break;
				}
			}
			if (at >= 0) resultModel.move(at, i, 1);
			else resultModel.insert(i, { key: result.key, kind: result.kind === "command" ? "Commands" : "Apps" });
		}
		resultList.currentIndex = root.listIndex;
	}

	// ── launch flourish ─────────────────────────────────────────────────
	// the icon that was started swells and fades while the launcher leaves
	function flourish(from) {
		if (!from || !from.visible) return;
		const at = from.mapToItem(root, from.width / 2, from.height / 2);
		bloomIcon.source = from.source ?? "";
		bloomIcon.width = from.width;
		bloomIcon.height = from.height;
		bloom.x = at.x;
		bloom.y = at.y;
		bloomAnim.restart();
	}

	// ── pieces ──────────────────────────────────────────────────────────
	component AppIcon: Image {
		property var item: null

		source: root.iconFor(item?.entry)
		sourceSize: Qt.size(width * 2, height * 2)
		fillMode: Image.PreserveAspectFit
		smooth: true
		mipmap: true
		asynchronous: true
	}

	// the app's own colour as a soft light behind it: its icon, blurred
	component Aura: Item {
		id: aura

		property url source
		property real strength: 1

		Image {
			id: auraSource

			anchors.fill: parent
			source: aura.source
			sourceSize: Qt.size(48, 48)
			fillMode: Image.PreserveAspectFit
			visible: false
			asynchronous: true
		}

		MultiEffect {
			anchors.fill: parent
			source: auraSource
			autoPaddingEnabled: true
			blurEnabled: true
			blur: 1
			blurMax: 48
			saturation: 0.35
			brightness: Theme.dark ? 0.05 : 0.15
			opacity: (Theme.dark ? 0.75 : 0.6) * aura.strength
		}
	}

	// a running app: a dot per window, up to three
	component RunDots: Row {
		id: dots

		property int count: 0
		property color tint: Theme.primary

		spacing: 3
		height: 4

		Repeater {
			model: Math.min(3, dots.count)

			delegate: Rectangle {
				width: dots.count > 1 ? 4 : 10
				height: 4
				radius: 2
				color: dots.tint
			}
		}
	}

	component Tile: Item {
		id: tile

		property var item: null
		property bool selected: false
		property bool dimmed: false
		property real iconSize: 38
		property int badge: 0
		property real enter: 1
		property real fromX: 0
		property real fromY: 14
		readonly property alias iconItem: icon
		readonly property int windows: tile.item ? (root.running[tile.item.key] || []).length : 0

		signal pointed
		signal clicked
		signal menuRequested

		function intro(delay) {
			tile.enter = 0;
			pause.duration = delay;
			introAnim.restart();
		}

		opacity: Math.min(1, tile.enter) * (tile.dimmed ? 0.45 : 1)
		scale: 0.8 + 0.2 * tile.enter

		transform: Translate {
			x: (1 - tile.enter) * tile.fromX
			y: (1 - tile.enter) * tile.fromY
		}

		SequentialAnimation {
			id: introAnim

			PauseAnimation {
				id: pause
			}
			NumberAnimation {
				target: tile
				property: "enter"
				to: 1
				duration: Motion.long
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.spatial
			}
		}

		Rectangle {
			anchors.fill: parent
			anchors.margins: 4
			radius: Theme.radius.large
			color: Theme.layer2
			opacity: !tile.selected && mouse.containsMouse ? 0.7 : 0

			Behavior on opacity {
				Anim {
					duration: Motion.short
				}
			}
		}

		Item {
			id: holder

			width: tile.iconSize
			height: tile.iconSize
			anchors.horizontalCenter: parent.horizontalCenter
			y: (tile.height - tile.iconSize - 26) / 2 - (tile.selected ? 3 : 0)
			scale: mouse.pressed ? 0.88 : (tile.selected ? 1.12 : 1)

			Behavior on y {
				SpatialAnim {
					duration: Motion.medium
				}
			}
			Behavior on scale {
				SpatialAnim {
					duration: Motion.medium
				}
			}

			AppIcon {
				id: icon

				anchors.fill: parent
				item: tile.item
			}

			Rectangle {
				visible: tile.badge > 0
				anchors.right: parent.right
				anchors.top: parent.top
				anchors.margins: -6
				width: 18
				height: 18
				radius: 9
				color: Theme.primary
				opacity: root.altHeld ? 1 : 0
				scale: root.altHeld ? 1 : 0.4

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
					anchors.centerIn: parent
					text: String(tile.badge)
					tone: Theme.onPrimary
					font.pixelSize: Theme.size.tiny
					font.weight: Font.Bold
				}
			}
		}

		RunDots {
			anchors.horizontalCenter: parent.horizontalCenter
			y: holder.y + tile.iconSize + 5
			count: tile.windows
			tint: tile.selected ? Theme.primary : Theme.textMuted
		}

		StyledText {
			anchors.horizontalCenter: parent.horizontalCenter
			y: holder.y + tile.iconSize + 12
			width: parent.width - 12
			horizontalAlignment: Text.AlignHCenter
			text: tile.item ? (tile.item.also !== "" ? `${tile.item.name} · ${tile.item.also}` : tile.item.name) : ""
			tone: tile.selected ? Theme.text : Theme.textMuted
			font.pixelSize: Theme.size.label
			font.weight: tile.selected ? Font.DemiBold : Font.Medium
		}

		MouseArea {
			id: mouse

			anchors.fill: parent
			anchors.margins: 4
			hoverEnabled: true
			acceptedButtons: Qt.LeftButton | Qt.RightButton
			cursorShape: Qt.PointingHandCursor
			onEntered: if (Pointer.moved(mouse, mouseX, mouseY)) tile.pointed()
			onPositionChanged: if (Pointer.moved(mouse, mouseX, mouseY)) tile.pointed()
			onClicked: event => {
				tile.pointed();
				if (event.button === Qt.RightButton) tile.menuRequested();
				else tile.clicked();
			}
		}
	}

	// the lens that marks the picked tile and glides from one to the next
	component Lens: Rectangle {
		id: lens

		property Item target: null
		property bool shown: true
		property url glow
		property real iconSize: 38

		x: lens.target ? lens.target.x + 4 : 0
		y: lens.target ? lens.target.y + 4 : 0
		width: lens.target ? lens.target.width - 8 : 0
		height: lens.target ? lens.target.height - 8 : 0
		radius: Theme.radius.large
		color: Theme.primaryContainer
		opacity: lens.shown && lens.target ? 1 : 0

		Behavior on x {
			enabled: lens.opacity > 0.5
			SpatialAnim {
				duration: Motion.medium
			}
		}
		Behavior on y {
			enabled: lens.opacity > 0.5
			SpatialAnim {
				duration: Motion.medium
			}
		}
		Behavior on opacity {
			Anim {
				duration: Motion.short
			}
		}

		Aura {
			x: (lens.width - width) / 2
			y: (lens.height - lens.iconSize - 26) / 2 - 3
			width: lens.iconSize
			height: lens.iconSize
			source: lens.glow
		}
	}

	// where a list goes on beyond its edge, it fades out there
	component EdgeFade: Item {
		id: fade

		required property Flickable view

		visible: false
		layer.enabled: true

		Rectangle {
			anchors.fill: parent
			gradient: Gradient {
				GradientStop {
					position: 0
					color: fade.view.atYBeginning ? "white" : "transparent"
				}
				GradientStop {
					position: Math.min(0.4, 22 / Math.max(1, fade.height))
					color: "white"
				}
				GradientStop {
					position: Math.max(0.6, 1 - 30 / Math.max(1, fade.height))
					color: "white"
				}
				GradientStop {
					position: 1
					color: fade.view.atYEnd ? "white" : "transparent"
				}
			}
		}
	}

	component ActionRow: Clickable {
		id: action

		property var action: null
		property bool selected: false

		implicitHeight: 34
		radius: Theme.radius.medium
		showHover: !action.selected
		pressedScale: 0.97
		color: action.selected ? Theme.primaryContainer : "transparent"

		Behavior on color {
			ColorAnim {}
		}

		Glyph {
			id: actionGlyph

			x: 10
			anchors.verticalCenter: parent.verticalCenter
			icon: action.action?.glyph ?? "console"
			size: 16
			color: action.selected ? Theme.primary : Theme.textMuted
			animated: false
		}

		StyledText {
			anchors.left: actionGlyph.right
			anchors.leftMargin: 10
			anchors.right: actionHint.left
			anchors.rightMargin: 8
			anchors.verticalCenter: parent.verticalCenter
			text: action.action?.label ?? ""
			font.pixelSize: Theme.size.body
			font.weight: action.selected ? Font.DemiBold : Font.Normal
		}

		StyledText {
			id: actionHint

			anchors.right: parent.right
			anchors.rightMargin: 10
			anchors.verticalCenter: parent.verticalCenter
			text: action.action?.hint ?? ""
			tone: Theme.textSubtle
			font.family: Theme.monoFamily
			font.pixelSize: Theme.size.small
		}
	}

	// ══ browsing ════════════════════════════════════════════════════════
	readonly property real searchReveal: root.searching ? 1 : 0
	property real searchShift: root.searchReveal

	Behavior on searchShift {
		SpatialAnim {
			duration: root.searching ? Motion.long : Motion.medium
		}
	}

	Item {
		id: browse

		anchors.fill: parent
		opacity: Math.max(0, 1 - root.searchShift * 1.8)
		visible: opacity > 0.01
		enabled: !root.searching
		scale: 1 - 0.04 * root.searchShift
		transformOrigin: Item.Top

		// ── dock ──
		Rectangle {
			id: dockPlate

			width: parent.width
			height: root.dock.length > 0 ? root.dockHeight : 0
			visible: root.dock.length > 0
			radius: Theme.radius.huge
			color: Theme.layer1

			Lens {
				target: dockRepeater.count > root.dockIndex ? dockRepeater.itemAt(root.dockIndex) : null
				x: target ? target.x + dockRow.x + 4 : 0
				y: target ? target.y + dockRow.y + 4 : 0
				shown: root.zone === "dock"
				iconSize: 44
				glow: root.iconFor(root.dock[root.dockIndex]?.entry)
			}

			Row {
				id: dockRow

				anchors.centerIn: parent

				Repeater {
					id: dockRepeater

					model: root.dock

					delegate: Tile {
						id: dockTile

						required property var modelData
						required property int index

						width: Math.min(104, (dockPlate.width - 16) / root.dockSlots)
						height: root.dockHeight - 8
						item: dockTile.modelData
						iconSize: 44
						badge: dockTile.index + 1
						selected: root.zone === "dock" && root.dockIndex === dockTile.index
						fromY: -12
						onPointed: {
							root.zone = "dock";
							root.dockIndex = dockTile.index;
						}
						onClicked: root.open(root.appResult(dockTile.item), dockTile.iconItem)
						onMenuRequested: root.openMenu(root.appResult(dockTile.item), dockTile)

						Connections {
							target: root
							function onCascade() {
								if (root.cascadeDirection === 0) dockTile.intro(40 + dockTile.index * 28);
							}
						}
					}
				}
			}
		}

		// ── shelves ──
		Item {
			id: shelfBar

			y: dockPlate.height + (dockPlate.visible ? 12 : 0)
			width: parent.width
			height: 34

			// the mark under the shelf that is open; its edges travel at
			// different speeds, so it stretches on the way
			Rectangle {
				id: shelfMark

				readonly property Item target: shelfRepeater.count > root.shelfIndex ? shelfRepeater.itemAt(root.shelfIndex) : null
				property real edgeLeft: shelfMark.target ? shelfMark.target.x : 0
				property real edgeRight: shelfMark.target ? shelfMark.target.x + shelfMark.target.width : 0
				property bool forward: true

				x: shelfMark.edgeLeft
				width: Math.max(0, shelfMark.edgeRight - shelfMark.edgeLeft)
				height: parent.height
				radius: height / 2
				color: Theme.primaryContainer

				onTargetChanged: if (shelfMark.target) shelfMark.forward = shelfMark.target.x >= shelfMark.x

				Behavior on edgeLeft {
					SpatialAnim {
						duration: shelfMark.forward ? Motion.long : Motion.medium
					}
				}
				Behavior on edgeRight {
					SpatialAnim {
						duration: shelfMark.forward ? Motion.medium : Motion.long
					}
				}
			}

			Row {
				id: shelfRow

				height: parent.height
				spacing: 2

				Repeater {
					id: shelfRepeater

					model: root.shelves

					delegate: Item {
						id: chip

						required property var modelData
						required property int index
						readonly property bool open: root.shelf === chip.modelData.id
						readonly property bool wide: chip.open || chipMouse.containsMouse

						width: chipGlyph.width + 24 + (chip.wide ? chipLabel.implicitWidth + 7 : 0)
						height: shelfRow.height
						clip: true

						Behavior on width {
							SpatialAnim {
								duration: Motion.medium
							}
						}

						Glyph {
							id: chipGlyph

							x: 12
							anchors.verticalCenter: parent.verticalCenter
							icon: chip.modelData.glyph
							size: 16
							color: chip.open ? Theme.primary : Theme.textMuted
							animated: false
						}

						StyledText {
							id: chipLabel

							x: chipGlyph.x + chipGlyph.width + 7
							anchors.verticalCenter: parent.verticalCenter
							text: chip.modelData.label
							tone: chip.open ? Theme.primary : Theme.textMuted
							font.pixelSize: Theme.size.label
							font.weight: Font.DemiBold
							elide: Text.ElideNone
							opacity: chip.wide ? 1 : 0

							Behavior on opacity {
								Anim {
									duration: Motion.short
								}
							}
						}

						MouseArea {
							id: chipMouse

							anchors.fill: parent
							hoverEnabled: true
							cursorShape: Qt.PointingHandCursor
							onClicked: root.showShelf(chip.modelData.id)
						}
					}
				}
			}

			StyledText {
				anchors.right: parent.right
				anchors.rightMargin: 6
				anchors.verticalCenter: parent.verticalCenter
				text: `${root.shelfApps.length} ${root.shelfApps.length === 1 ? "app" : "apps"}`
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
				tabular: true
			}

			WheelHandler {
				acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
				onWheel: event => {
					if (wheelPause.running) return;
					root.switchShelf(event.angleDelta.y < 0 || event.angleDelta.x < 0 ? 1 : -1);
					wheelPause.restart();
				}
			}

			Timer {
				id: wheelPause

				interval: 220
			}
		}

		EdgeFade {
			id: gridFade

			anchors.fill: grid
			view: grid
		}

		// ── the apps of the shelf ──
		GridView {
			id: grid

			anchors.top: shelfBar.bottom
			anchors.topMargin: 8
			anchors.bottom: parent.bottom
			width: parent.width
			clip: true
			cellWidth: Math.floor(width / root.columns)
			cellHeight: root.cellHeight
			model: root.shelfApps
			boundsBehavior: Flickable.StopAtBounds
			highlightFollowsCurrentItem: false
			currentIndex: 0
			cacheBuffer: root.cellHeight * 2
			ScrollBar.vertical: ThinScrollBar {}
			layer.enabled: true
			layer.effect: MultiEffect {
				maskEnabled: true
				maskSource: gridFade
				maskThresholdMin: 0
				maskSpreadAtMin: 1
			}

			highlight: Lens {
				target: grid.currentItem
				shown: root.zone === "grid"
				glow: root.iconFor(root.shelfApps[root.gridIndex]?.entry)
			}

			delegate: Tile {
				id: cell

				required property var modelData
				required property int index

				width: grid.cellWidth
				height: grid.cellHeight
				item: cell.modelData
				dimmed: root.shelf === "hidden"
				selected: root.zone === "grid" && root.gridIndex === cell.index
				onPointed: {
					root.zone = "grid";
					root.gridIndex = cell.index;
					grid.currentIndex = cell.index;
				}
				onClicked: root.open(root.appResult(cell.item), cell.iconItem)
				onMenuRequested: root.openMenu(root.appResult(cell.item), cell)

				// a wave from the top on opening, across from the side the
				// shelf was taken from
				function sweep() {
					const row = Math.floor(cell.index / root.columns) - Math.floor(grid.contentY / root.cellHeight);
					if (row < 0 || row > 6) return;
					const column = cell.index % root.columns;
					const direction = root.cascadeDirection;
					cell.fromX = direction * 36;
					cell.fromY = direction === 0 ? 18 : 0;
					const order = direction > 0 ? column : (direction < 0 ? root.columns - 1 - column : column * 0.5);
					cell.intro((direction === 0 ? 90 : 0) + row * 38 + order * 16);
				}

				Component.onCompleted: if (root.cascading) cell.sweep()

				Connections {
					target: root
					function onCascade() {
						cell.sweep();
					}
				}
			}
		}
	}

	// ══ searching ═══════════════════════════════════════════════════════
	Item {
		id: search

		anchors.fill: parent
		opacity: Math.min(1, root.searchShift * 1.4)
		visible: opacity > 0.01
		enabled: root.searching

		// ── spotlight: what Enter starts ──
		Rectangle {
			id: spot

			readonly property var result: root.current
			readonly property bool isApp: spot.result?.kind === "app"

			width: 268
			height: parent.height
			radius: Theme.radius.huge
			color: Theme.layer1
			clip: true

			transform: Translate {
				x: -28 * (1 - root.searchShift)
			}

			// the app's colour fills the card from the top
			Aura {
				x: (spot.width - width) / 2
				y: -40
				width: 190
				height: 190
				visible: spot.isApp
				source: spot.isApp ? root.iconFor(spot.result.item.entry) : ""
				strength: 0.55
			}

			Rectangle {
				anchors.fill: parent
				radius: parent.radius
				gradient: Gradient {
					GradientStop {
						position: 0
						color: "transparent"
					}
					GradientStop {
						position: 0.55
						color: Qt.alpha(Theme.layer1, 0.6)
					}
					GradientStop {
						position: 1
						color: Theme.layer1
					}
				}
			}

			Column {
				id: spotHead

				y: 26
				width: parent.width
				spacing: 4

				Item {
					width: parent.width
					height: 84

					AppIcon {
						id: spotIcon

						anchors.centerIn: parent
						width: 72
						height: 72
						visible: spot.isApp
						item: spot.isApp ? spot.result.item : null
					}

					Rectangle {
						anchors.centerIn: parent
						width: 72
						height: 72
						radius: Theme.radius.huge
						visible: !spot.isApp
						color: spot.result ? Theme.primaryContainer : Theme.layer2

						Glyph {
							anchors.centerIn: parent
							icon: spot.result?.kind === "command" ? root.glyphFor(spot.result.command) : (root.webFallback ? "web" : "magnify")
							size: 34
							color: spot.result || root.webFallback ? Theme.primary : Theme.textSubtle
						}
					}
				}

				Item {
					width: 1
					height: 6
				}

				StyledText {
					id: spotName

					x: 18
					width: parent.width - 36
					horizontalAlignment: Text.AlignHCenter
					wrapMode: Text.Wrap
					maximumLineCount: 2
					text: spot.isApp ? spot.result.item.name : (spot.result ? spot.result.command.name : (root.webFallback ? "Search the web" : "No app answers"))
					font.pixelSize: Theme.size.heading
					font.weight: Font.Bold
				}

				StyledText {
					x: 18
					width: parent.width - 36
					visible: text !== ""
					horizontalAlignment: Text.AlignHCenter
					text: spot.isApp ? [spot.result.item.genericName, spot.result.item.also].filter(part => part !== "").join("  ·  ")
						: (spot.result ? `${spot.result.command.prefix ?? ">"}${spot.result.command.command}` : `“${root.query.trim()}”`)
					tone: spot.isApp || !spot.result ? Theme.textMuted : Theme.primary
					font.family: spot.isApp ? Theme.fontFamily : Theme.monoFamily
					font.pixelSize: Theme.size.body
				}

				Row {
					anchors.horizontalCenter: parent.horizontalCenter
					visible: root.currentWindows.length > 0 || (spot.result?.command?.status ?? "") !== ""
					spacing: 6
					topPadding: 4

					Rectangle {
						anchors.verticalCenter: parent.verticalCenter
						width: 6
						height: 6
						radius: 3
						color: Theme.success
						visible: root.currentWindows.length > 0
					}

					StyledText {
						text: root.currentWindows.length > 0
							? (root.currentWindows.length > 1 ? `${root.currentWindows.length} windows open` : "Open")
							: String(spot.result?.command?.status ?? "")
						tone: root.currentWindows.length > 0 ? Theme.success : Theme.primary
						font.pixelSize: Theme.size.small
						font.weight: Font.DemiBold
					}
				}

				StyledText {
					x: 18
					width: parent.width - 36
					topPadding: 6
					visible: text !== "" && spot.height > 330
					horizontalAlignment: Text.AlignHCenter
					wrapMode: Text.Wrap
					maximumLineCount: 2
					text: spot.isApp ? spot.result.item.comment : String(spot.result?.command?.keywords ?? "")
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
				}
			}

			Column {
				id: spotActionList

				anchors.left: parent.left
				anchors.right: parent.right
				anchors.bottom: parent.bottom
				anchors.margins: 10
				spacing: 2

				Repeater {
					id: spotActions

					model: root.currentActions

					delegate: ActionRow {
						id: spotAction

						required property var modelData
						required property int index

						width: spotActionList.width
						action: spotAction.modelData
						selected: root.zone === "actions" && root.actionIndex === spotAction.index
						onClicked: root.run(root.current, spotAction.modelData, spotIcon)
						onPointed: if (root.zone === "actions") root.actionIndex = spotAction.index
					}
				}
			}

			// a new pick pops in
			ParallelAnimation {
				id: spotChange

				NumberAnimation {
					target: spotIcon
					property: "scale"
					from: 0.82
					to: 1
					duration: Motion.medium
					easing.type: Easing.BezierSpline
					easing.bezierCurve: Motion.spatialFast
				}
				NumberAnimation {
					target: spotHead
					property: "opacity"
					from: 0.35
					to: 1
					duration: Motion.short
				}
			}
		}

		EdgeFade {
			id: resultFade

			anchors.fill: resultList
			view: resultList
		}

		// ── results ──
		ListView {
			id: resultList

			anchors.left: spot.right
			anchors.leftMargin: 12
			anchors.right: parent.right
			anchors.top: parent.top
			anchors.bottom: parent.bottom
			clip: true
			model: resultModel
			boundsBehavior: Flickable.StopAtBounds
			highlightFollowsCurrentItem: false
			section.property: "kind"
			layer.enabled: true
			layer.effect: MultiEffect {
				maskEnabled: true
				maskSource: resultFade
				maskThresholdMin: 0
				maskSpreadAtMin: 1
			}
			section.delegate: SectionLabel {
				required property string section

				width: resultList.width
				height: 26
				leftPadding: 10
				text: section
			}
			ScrollBar.vertical: ThinScrollBar {}

			transform: Translate {
				x: 28 * (1 - root.searchShift)
			}

			highlight: Rectangle {
				x: 0
				y: resultList.currentItem ? resultList.currentItem.y : 0
				width: resultList.width
				height: root.rowHeight
				radius: Theme.radius.large
				color: Theme.primaryContainer
				opacity: root.zone === "actions" ? 0.45 : 1

				Behavior on y {
					SpatialAnim {
						duration: Motion.medium
					}
				}
				Behavior on opacity {
					Anim {
						duration: Motion.short
					}
				}
			}

			add: Transition {
				ParallelAnimation {
					Anim {
						property: "opacity"
						from: 0
						to: 1
						duration: Motion.medium
					}
					SpatialAnim {
						property: "x"
						from: 22
						to: 0
						duration: Motion.long
					}
				}
			}
			remove: Transition {
				Anim {
					property: "opacity"
					to: 0
					duration: Motion.micro
				}
			}
			displaced: Transition {
				SpatialAnim {
					property: "y"
					duration: Motion.medium
				}
				Anim {
					property: "opacity"
					to: 1
					duration: Motion.short
				}
			}
			move: Transition {
				SpatialAnim {
					property: "y"
					duration: Motion.medium
				}
			}

			delegate: Item {
				id: row

				required property string key
				required property int index

				readonly property var result: root.resultByKey[row.key] ?? null
				readonly property bool isApp: row.result?.kind === "app"
				readonly property bool selected: root.listIndex === row.index
				readonly property int windows: row.isApp ? (root.running[row.result.item.key] || []).length : 0
				readonly property alias iconItem: rowIcon

				width: resultList.width
				height: root.rowHeight

				Rectangle {
					anchors.fill: parent
					radius: Theme.radius.large
					color: Theme.layer1
					opacity: !row.selected && rowMouse.containsMouse ? 1 : 0

					Behavior on opacity {
						Anim {
							duration: Motion.short
						}
					}
				}

				AppIcon {
					id: rowIcon

					x: 12
					anchors.verticalCenter: parent.verticalCenter
					width: 30
					height: 30
					visible: row.isApp
					item: row.isApp ? row.result.item : null
					scale: row.selected ? 1.1 : 1

					Behavior on scale {
						SpatialAnim {
							duration: Motion.medium
						}
					}
				}

				Rectangle {
					x: 12
					anchors.verticalCenter: parent.verticalCenter
					width: 30
					height: 30
					radius: row.selected ? Theme.radius.small : 15
					visible: !row.isApp
					color: row.selected ? Theme.primary : Theme.layer2

					Behavior on radius {
						SpatialAnim {
							duration: Motion.medium
						}
					}

					Glyph {
						anchors.centerIn: parent
						icon: row.result?.kind === "command" ? root.glyphFor(row.result.command) : "console"
						size: 16
						color: row.selected ? Theme.onPrimary : Theme.text
						animated: false
					}
				}

				StyledText {
					id: rowName

					x: 56
					anchors.verticalCenter: parent.verticalCenter
					anchors.verticalCenterOffset: rowKind.text !== "" ? -8 : 0
					width: Math.min(implicitWidth, parent.width - x - 40)
					textFormat: Text.StyledText
					text: row.isApp ? AppSearch.highlight(row.result.item.name, row.result.indexes, Theme.primary) : AppSearch.escapeText(row.result?.command?.name ?? "")
					font.pixelSize: Theme.size.body
					font.weight: Font.DemiBold
				}

				StyledText {
					id: rowKind

					x: 56
					anchors.verticalCenter: parent.verticalCenter
					anchors.verticalCenterOffset: 9
					width: parent.width - x - 60
					text: row.isApp ? [row.result.item.genericName || row.result.item.comment, row.result.item.also].filter(part => part !== "").join("  ·  ") : `${row.result?.command?.prefix ?? ">"}${row.result?.command?.command ?? ""}`
					tone: Theme.textSubtle
					font.family: row.isApp ? Theme.fontFamily : Theme.monoFamily
					font.pixelSize: Theme.size.small
				}

				RunDots {
					anchors.left: rowName.right
					anchors.leftMargin: 8
					anchors.verticalCenter: rowName.verticalCenter
					count: row.windows
					tint: Theme.success
				}

				Glyph {
					anchors.right: parent.right
					anchors.rightMargin: 14
					anchors.verticalCenter: parent.verticalCenter
					icon: row.result?.command?.children ? "chevron_right" : "keyboard_return"
					size: 16
					color: Theme.primary
					opacity: row.selected && root.zone !== "actions" ? 1 : 0
					scale: row.selected ? 1 : 0.5

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
				}

				MouseArea {
					id: rowMouse

					anchors.fill: parent
					hoverEnabled: true
					acceptedButtons: Qt.LeftButton | Qt.RightButton
					cursorShape: Qt.PointingHandCursor
					onEntered: if (Pointer.moved(rowMouse, mouseX, mouseY)) root.pointResult(row.index)
					onPositionChanged: if (Pointer.moved(rowMouse, mouseX, mouseY)) root.pointResult(row.index)
					onClicked: event => {
						root.pointResult(row.index);
						if (event.button === Qt.RightButton) {
							root.zone = "actions";
							root.actionIndex = 0;
						} else {
							root.open(row.result, row.isApp ? rowIcon : null);
						}
					}
				}
			}
		}

		EmptyState {
			anchors.centerIn: resultList
			visible: root.searching && root.results.length === 0
			icon: "magnify"
			title: `Nothing called “${root.query.trim()}”`
			subtitle: root.hidden.length > 0 ? "Hidden apps are on the Hidden shelf" : ""
		}
	}

	function pointResult(index) {
		if (root.listIndex === index) return;
		root.listIndex = index;
		root.picked = true;
		root.pickedKey = root.results[index]?.key ?? "";
		resultList.currentIndex = index;
		if (root.zone === "actions") root.zone = "list";
		root.actionIndex = 0;
	}

	// ══ the actions of a tile ═══════════════════════════════════════════
	MouseArea {
		anchors.fill: parent
		visible: root.menuOpen
		acceptedButtons: Qt.AllButtons
		onPressed: root.menuTarget = null
	}

	Rectangle {
		id: menu

		property real reveal: root.menuOpen ? 1 : 0

		x: Math.max(0, Math.min(root.width - width, root.menuAt.x - width / 2))
		y: root.menuAt.y + height > root.height ? Math.max(0, root.menuAt.y - height - 70) : root.menuAt.y
		width: 236
		height: menuColumn.implicitHeight + 12
		z: 20
		radius: Theme.radius.large
		color: Theme.layer2
		border.width: 1
		border.color: Theme.outline
		visible: menu.reveal > 0.01
		opacity: Math.min(1, menu.reveal * 1.5)
		scale: 0.85 + 0.15 * menu.reveal
		transformOrigin: root.menuAt.y + height > root.height ? Item.Bottom : Item.Top

		Behavior on reveal {
			SpatialAnim {
				duration: root.menuOpen ? Motion.medium : Motion.short
			}
		}

		Column {
			id: menuColumn

			x: 6
			y: 6
			width: parent.width - 12
			spacing: 2

			StyledText {
				width: parent.width
				leftPadding: 10
				topPadding: 4
				bottomPadding: 4
				text: root.menuTarget?.item?.name ?? ""
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
				font.weight: Font.DemiBold
			}

			Repeater {
				model: root.menuActions

				delegate: ActionRow {
					id: menuAction

					required property var modelData
					required property int index

					width: menuColumn.width
					action: menuAction.modelData
					selected: root.menuIndex === menuAction.index
					onPointed: root.menuIndex = menuAction.index
					onClicked: root.run(root.menuTarget, menuAction.modelData, null)
				}
			}
		}
	}

	// ══ launch flourish ═════════════════════════════════════════════════
	Item {
		id: bloom

		z: 30
		width: 0
		height: 0

		Rectangle {
			id: bloomRing

			anchors.centerIn: parent
			width: bloomIcon.width * 1.5
			height: width
			radius: width / 2
			color: "transparent"
			border.width: 2
			border.color: Theme.primary
			opacity: 0
		}

		Image {
			id: bloomIcon

			anchors.centerIn: parent
			sourceSize: Qt.size(128, 128)
			fillMode: Image.PreserveAspectFit
			smooth: true
			mipmap: true
			opacity: 0
		}

		ParallelAnimation {
			id: bloomAnim

			NumberAnimation {
				target: bloomIcon
				property: "scale"
				from: 1
				to: 1.9
				duration: Motion.long
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.decel
			}
			SequentialAnimation {
				PropertyAction {
					target: bloomIcon
					property: "opacity"
					value: 0.9
				}
				NumberAnimation {
					target: bloomIcon
					property: "opacity"
					to: 0
					duration: Motion.long
					easing.type: Easing.BezierSpline
					easing.bezierCurve: Motion.decel
				}
			}
			NumberAnimation {
				target: bloomRing
				property: "scale"
				from: 0.6
				to: 2.2
				duration: Motion.long
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.decel
			}
			NumberAnimation {
				target: bloomRing
				property: "opacity"
				from: 0.9
				to: 0
				duration: Motion.long
			}
		}
	}
}
