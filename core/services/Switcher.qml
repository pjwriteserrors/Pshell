pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.style.theme

// The window switcher (Alt+Tab), drawn by the shell instead of niri's own
// (recent-windows). niri binds the keys to `switcher next|prev <scope>
// <filter>`; the first press opens it on the focused screen with the window
// used before already picked, every further one moves on, and letting go of
// the modifier switches. Windows come in the order they were last used
// (niri's focus timestamps).
//
// The modifier going up is seen twice over: by the switcher's own window
// once it has the keyboard, and by scripts/held_keys.py, which reads the
// keyboards' evdev devices while it is open – it also catches an Alt+Tab
// let go before the window was even there, which then switches at once
// without showing anything.
//
// Pictures of the windows come from scripts/window_shots.py (niri's
// ScreenCast, one cast per window – also for those on hidden workspaces):
// live while it is open, or once per opening, or not at all (icons only).
// They are kept in $XDG_RUNTIME_DIR, so the next opening shows the last
// ones at once. Everything else is in switcher.json.
Singleton {
	id: root

	// ── settings ───────────────────────────────────────────────────────────
	// "shell": this switcher has the keys; "niri": niri's own recent-windows
	property string engine: "niri"
	// strip | grid | carousel | fan | list | workspaces
	property string layout: "strip"
	// all | others (not the workspace you are on) | output | workspace
	property string scope: "all"
	// live | snapshot | icons
	property string previews: "live"
	// selected | all | none
	property string titles: "selected"
	// glow | lift | spotlight | outline
	property string effect: "glow"
	// zoom | rise | cascade | fade
	property string entrance: "zoom"
	// clear | dim | blur
	property string backdrop: "blur"
	property real backdropStrength: 0.6
	property real size: 1
	// -1: as round as the windows
	property int corner: -1
	property int delay: 120
	property bool numbers: true

	readonly property var layouts: [
		{ id: "strip", label: "Strip", icon: "view_column_outline", about: "One row, every window at its own shape" },
		{ id: "grid", label: "Grid", icon: "view_grid_outline", about: "Rows of equal cells, all at a glance" },
		{ id: "carousel", label: "Carousel", icon: "view_carousel_outline", about: "The picked one up front, the others turning away" },
		{ id: "fan", label: "Fan", icon: "cards_outline", about: "Spread like a hand of cards; the picked one rises" },
		{ id: "list", label: "List", icon: "format_list_text", about: "Names on the left, the picked window big beside them" },
		{ id: "workspaces", label: "Workspaces", icon: "monitor_dashboard", about: "Grouped by the workspace they are on" }
	]
	readonly property var settingNames: ["engine", "layout", "scope", "previews", "titles", "effect", "entrance", "backdrop",
		"backdropStrength", "size", "corner", "delay", "numbers"]

	// ── state ──────────────────────────────────────────────────────────────
	property bool open: false
	// drawn (after `delay`; a quick Alt+Tab switches before)
	property bool shown: false
	// held open by a modifier: letting go switches. Opened by a click or by
	// `switcher show` it stays until something is picked.
	property bool held: false
	property var items: []
	property int index: 0
	property var screen: null
	// what this opening shows, for the reopen when windows change
	property string openScope: ""
	property string openFilter: ""
	// the window that was focused when it opened
	property int origin: -1
	// bumps when a picture arrives; the cards read root.shot(id)
	property int shotsRev: 0
	property var shotFiles: ({})
	// set by the window: how the picked card leaves (for the exit motion)
	property int picked: -1

	readonly property var current: root.index >= 0 && root.index < root.items.length ? root.items[root.index] : null
	readonly property real radius: root.corner < 0 ? Math.min(40, Theme.windowRadius) : root.corner
	readonly property string shotDir: `${Paths.runtime}/switcher`

	function shot(id, rev) {
		const file = root.shotFiles[id];
		return file ? `file://${file.path}?${file.n}` : "";
	}

	// ── opening and moving ─────────────────────────────────────────────────
	function step(direction, scope, filter) {
		if (!root.open) {
			root.begin(direction, scope, filter, true);
			return;
		}
		root.move(direction);
	}

	function move(direction) {
		const count = root.items.length;
		if (count === 0) return;
		root.index = ((root.index + direction) % count + count) % count;
	}

	function select(index) {
		if (index >= 0 && index < root.items.length) root.index = index;
	}

	// opened without a held key (a click, `switcher show`): stays until picked
	function show(scope, filter) {
		if (root.open) {
			root.cancel();
			return;
		}
		root.begin(1, scope, filter, false);
		root.shown = true;
	}

	function begin(direction, scope, filter, held) {
		root.openScope = String(scope || "");
		root.openFilter = String(filter || "");
		const items = root.collect(root.openScope, root.openFilter);
		if (items.length === 0) return;
		root.items = items;
		root.origin = items[0].focused ? items[0].id : -1;
		const start = items[0].focused ? 1 : 0;
		root.index = items.length === 1 ? 0 : (direction > 0 ? start % items.length : items.length - 1);
		root.screen = Popups.focusedScreen();
		root.picked = -1;
		root.held = held;
		root.open = true;
		if (held) {
			keys.running = true;
			showTimer.restart();
		}
	}

	function collect(scope, filter) {
		const which = scope || root.scope;
		const workspaces = {};
		for (const ws of Niri.workspaces) workspaces[ws.id] = ws;
		const focusedWs = Niri.workspaces.find(ws => ws.is_focused);
		const focusedWindow = Niri.windows.find(w => w.is_focused);
		let windows = Niri.windows.slice();
		if (filter === "app" && focusedWindow)
			windows = windows.filter(w => w.app_id === focusedWindow.app_id);
		let scoped = windows;
		if (which === "workspace" && focusedWs) scoped = windows.filter(w => w.workspace_id === focusedWs.id);
		else if (which === "output" && focusedWs) scoped = windows.filter(w => workspaces[w.workspace_id]?.output === focusedWs.output);
		else if (which === "others" && focusedWs) {
			scoped = windows.filter(w => w.workspace_id !== focusedWs.id);
			// where you came from stays first, so one tap goes back to it
			if (focusedWindow && scoped.length > 0) scoped = [focusedWindow].concat(scoped);
		}
		if (scoped.length === 0) scoped = windows;
		return scoped.sort((a, b) => {
			if (a.is_focused !== b.is_focused) return a.is_focused ? -1 : 1;
			return Niri.focusTimestampValue(b) - Niri.focusTimestampValue(a);
		}).map(w => root.entry(w, workspaces[w.workspace_id]));
	}

	function entry(window, ws) {
		const size = window.layout?.window_size || window.layout?.tile_size || [1600, 900];
		const screen = Popups.screenByName(ws?.output);
		const scale = Number(screen?.devicePixelRatio || 1);
		return {
			id: Number(window.id),
			appId: String(window.app_id || ""),
			title: String(window.title || window.app_id || "Window"),
			workspaceId: Number(window.workspace_id ?? -1),
			workspaceIdx: Number(ws?.idx ?? 0),
			workspaceName: String(ws?.name || ""),
			workspaceActive: !!ws?.is_active,
			output: String(ws?.output || ""),
			focused: !!window.is_focused,
			urgent: !!window.is_urgent,
			floating: !!window.is_floating,
			width: Number(size[0]) || 1600,
			height: Number(size[1]) || 900,
			pixels: [Math.round((Number(size[0]) || 1600) * scale), Math.round((Number(size[1]) || 900) * scale)]
		};
	}

	// windows opened or closed while it is up: the list follows, the pick stays
	function refresh() {
		if (!root.open) return;
		const keep = root.current ? root.current.id : -1;
		const order = root.items.map(item => item.id);
		const fresh = root.collect(root.openScope, root.openFilter);
		const known = fresh.filter(item => order.includes(item.id)).sort((a, b) => order.indexOf(a.id) - order.indexOf(b.id));
		const items = known.concat(fresh.filter(item => !order.includes(item.id)));
		if (items.length === 0) {
			root.close();
			return;
		}
		root.items = items;
		const at = items.findIndex(item => item.id === keep);
		root.index = at >= 0 ? at : Math.min(root.index, items.length - 1);
		root.sendShots();
	}

	// ── leaving ────────────────────────────────────────────────────────────
	function release() {
		if (!root.open || !root.held) return;
		root.pick();
	}

	function pick() {
		const item = root.current;
		if (!item) {
			root.close();
			return;
		}
		root.picked = item.id;
		root.close();
		if (!item.focused) Niri.focusWindow(item.id);
	}

	function pickAt(index) {
		root.select(index);
		root.pick();
	}

	function cancel() {
		root.picked = -1;
		root.close();
	}

	function close() {
		showTimer.stop();
		keys.running = false;
		root.open = false;
		root.shown = false;
		root.held = false;
	}

	function closeWindow(id) {
		Niri.closeWindow(id);
		const at = root.items.findIndex(item => item.id === id);
		if (at < 0) return;
		const items = root.items.slice();
		items.splice(at, 1);
		if (items.length === 0) {
			root.close();
			return;
		}
		root.items = items;
		if (root.index >= items.length) root.index = items.length - 1;
	}

	function cycleLayout(direction) {
		const ids = root.layouts.map(entry => entry.id);
		const at = Math.max(0, ids.indexOf(root.layout));
		root.set("layout", ids[((at + direction) % ids.length + ids.length) % ids.length]);
	}

	Connections {
		target: Niri
		enabled: root.open

		function onWindowsChanged() {
			refreshTimer.restart();
		}
	}

	Timer {
		id: refreshTimer

		interval: 60
		onTriggered: root.refresh()
	}

	Timer {
		id: showTimer

		interval: Math.max(0, root.delay)
		onTriggered: if (root.open) root.shown = true
	}

	// ── the held modifier ──────────────────────────────────────────────────
	Process {
		id: keys

		command: ["python3", `${Paths.scripts}/held_keys.py`]
		stdinEnabled: true
		stdout: SplitParser {
			onRead: line => {
				if (line.trim() === "up") root.release();
			}
		}
	}

	// ── pictures ───────────────────────────────────────────────────────────
	function sendShots() {
		if (!shots.running) return;
		shots.write(root.items.map(item => `${item.id}:${item.pixels[0]}:${item.pixels[1]}`).join(" ") + "\n");
	}

	Process {
		id: shots

		running: root.open && root.previews !== "icons"
		command: ["python3", `${Paths.scripts}/window_shots.py`, root.shotDir, "900", root.previews === "live" ? "6" : "0"]
		stdinEnabled: true
		onStarted: root.sendShots()
		stdout: SplitParser {
			onRead: line => {
				let data = null;
				try {
					data = JSON.parse(line);
				} catch (error) {
					return;
				}
				const files = root.shotFiles;
				const old = files[data.id];
				files[data.id] = { path: String(data.file), n: (old?.n ?? 0) + 1 };
				root.shotsRev++;
			}
		}
	}

	// the pictures of last time, so an opening shows something at once
	Process {
		id: known

		running: true
		command: ["sh", "-c", `ls "${root.shotDir}" 2>/dev/null`]
		stdout: SplitParser {
			onRead: line => {
				const match = String(line).match(/^(\d+)\.jpg$/);
				if (match) root.shotFiles[Number(match[1])] = { path: `${root.shotDir}/${line}`, n: 0 };
			}
		}
		onExited: root.shotsRev++
	}

	// ── settings file ──────────────────────────────────────────────────────
	function set(name, value) {
		if (!root.settingNames.includes(name) || root[name] === value) return;
		root[name] = value;
		saveTimer.restart();
	}

	Timer {
		id: saveTimer

		interval: 300
		onTriggered: {
			const out = {};
			for (const name of root.settingNames) out[name] = root[name];
			file.setText(JSON.stringify(out, null, "\t") + "\n");
		}
	}

	FileView {
		id: file

		path: Paths.stateFile("switcher.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			let saved = {};
			try {
				saved = JSON.parse(String(text() || "{}"));
			} catch (error) {
				return;
			}
			for (const name of root.settingNames)
				if (saved[name] !== undefined && typeof saved[name] === typeof root[name]) root[name] = saved[name];
		}
	}

	// ── the keys in niri ───────────────────────────────────────────────────
	// `binds`: the switcher's keys as the Overview page lists them, { key,
	// action: next-window|previous-window, props: { scope, filter } }. With
	// the shell's switcher they become spawn binds in keybinds.kdl and niri's
	// own is switched off; with niri's they go away again.
	property var pendingBinds: null
	property string bindNote: ""

	function useEngine(engine, binds) {
		root.set("engine", engine === "shell" ? "shell" : "niri");
		NiriSettings.setFlag(["recent-windows", "off"], root.engine === "shell", root.engine === "shell" ? "The shell's window switcher" : "niri's window switcher");
		root.syncBinds(binds);
	}

	function syncBinds(binds) {
		// read again first: the file may have changed since the editor had it
		root.pendingBinds = binds || [];
		Keybinds.load();
	}

	function isOurs(bind) {
		return Keybinds.isShell(bind) && Keybinds.shellCall(bind).target === "switcher";
	}

	function writeBinds() {
		const wanted = root.pendingBinds;
		root.pendingBinds = null;
		if (!wanted) return;
		const others = Keybinds.binds.filter(bind => !root.isOurs(bind));
		const added = [];
		const skipped = [];
		if (root.engine === "shell") {
			for (const bind of wanted) {
				const taken = others.find(other => !other.disabled && Keybinds.norm(other.key) === Keybinds.norm(bind.key));
				if (taken) {
					skipped.push(bind.key);
					continue;
				}
				added.push({
					key: bind.key,
					props: {},
					action: "spawn",
					args: ["qs", "-c", "shell", "ipc", "call", "switcher", bind.action === "previous-window" ? "prev" : "next",
						String(bind.props?.scope || ""), bind.props?.filter === "app-id" ? "app" : ""],
					aprops: {},
					disabled: false
				});
			}
		}
		const before = Keybinds.binds.filter(root.isOurs).map(bind => `${bind.key}|${bind.args.join(" ")}`).sort().join(",");
		const after = added.map(bind => `${bind.key}|${bind.args.join(" ")}`).sort().join(",");
		root.bindNote = skipped.length > 0 ? `${skipped.join(", ")} already ${skipped.length === 1 ? "does" : "do"} something else` : "";
		if (before === after) return;
		Keybinds.commit(others.concat(added), root.engine === "shell" ? "Alt+Tab opens the shell's switcher" : "Alt+Tab is niri's again");
	}

	Connections {
		target: Keybinds

		// `loading` drops before the list is in; the list and `loaded` follow
		function onBindsChanged() {
			if (root.pendingBinds && Keybinds.loaded && !Keybinds.loading) root.writeBinds();
		}
		function onLoadedChanged() {
			if (root.pendingBinds && Keybinds.loaded && !Keybinds.loading) root.writeBinds();
		}
	}
}
