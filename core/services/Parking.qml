pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Parked windows: a window dragged (niri's interactive move) and let go on
// the very right edge of a screen waits there as a tab (ParkedTabs) until
// it is clicked back onto the screen's workspace.
//
// niri tells no drag: while a window is moved it has no workspace, so that
// is when the screens' edge strips (ParkingEdge) are mapped. During the move
// niri gives the pointer to nobody; once it is let go the strip under it is
// entered, and that drop is a park. Let go anywhere else (another screen
// included) nothing happens.
//
// A tab shows the app's icon, the icon with the window's title, or a live
// picture of the window (scripts/window_shots.py through niri's ScreenCast,
// which renders a window also on a workspace nobody sees); each window can
// have its own, the default and those are kept in parking.json. Resting on
// a tab shows the window live beside it. A tab marks what happened since it
// was last looked at: a new title, a busy agent (Agents), urgency.
//
// The windows wait on a named workspace of their screen ("parked:<output>"),
// so niri keeps them over restarts of the shell; the bar leaves it out, and
// going up and down the workspaces steps over it.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("parked-windows")
	readonly property string prefix: "parked:"

	// the window niri moves right now, -1 none
	property int moving: -1
	// the window just let go and when, the edge entered and when
	property int dropped: -1
	property real droppedAt: 0
	property string hitOutput: ""
	property real hitAt: 0
	// how close drop and entering the edge have to be
	readonly property int together: 150
	readonly property bool armed: root.enabled && (root.moving !== -1 || settle.running)

	// output -> [{ id, appId, title }] in their order on the edge
	readonly property var parked: {
		const spaces = {};
		for (const ws of Niri.workspaces)
			if (root.isParkingSpace(ws)) spaces[ws.id] = String(ws.output ?? "");
		const out = {};
		const windows = Niri.windows.filter(window => spaces[window.workspace_id] !== undefined)
			.sort((a, b) => {
				const [ax, ay] = Niri.layoutPositionValue(a);
				const [bx, by] = Niri.layoutPositionValue(b);
				return ax !== bx ? ax - bx : ay !== by ? ay - by : Number(a.id) - Number(b.id);
			});
		for (const window of windows) {
			const output = spaces[window.workspace_id];
			(out[output] = out[output] ?? []).push({ id: Number(window.id), appId: window.app_id ?? "", title: window.title ?? "",
				urgent: !!window.is_urgent, size: window.layout?.window_size ?? [1600, 900] });
		}
		return out;
	}
	readonly property bool any: Object.keys(root.parked).length > 0
	readonly property var parkedIds: [].concat(...Object.values(root.parked)).map(window => window.id)

	// ── how a tab looks ──────────────────────────────────────────────────
	readonly property var views: [
		{ id: "icon", label: "Icon", icon: "dock_right" },
		{ id: "title", label: "Icon and title", icon: "text_box_outline" },
		{ id: "live", label: "Live", icon: "monitor_shimmer" }
	]
	property string view: "icon"
	// window id → view, where it differs from `view`
	property var viewFor: ({})

	function viewOf(id) {
		return root.viewFor[id] ?? root.view;
	}

	function setView(id, view) {
		const next = Object.assign({}, root.viewFor);
		if (view === root.view) delete next[id];
		else next[id] = view;
		root.viewFor = next;
		saveTimer.restart();
	}

	// every tab like this one
	function setViewForAll(view) {
		root.view = view;
		root.viewFor = ({});
		saveTimer.restart();
	}

	// window id → the title last looked at; another one since is news
	property var seenTitle: ({})

	function hasNews(window) {
		const seen = root.seenTitle[window.id];
		return seen !== undefined && Agents.topic(seen) !== Agents.topic(window.title);
	}

	function markSeen(id) {
		const window = Niri.windowMap[id];
		if (!window || root.seenTitle[id] === window.title) return;
		const next = Object.assign({}, root.seenTitle);
		next[id] = window.title;
		root.seenTitle = next;
	}

	onParkedIdsChanged: {
		const next = {};
		for (const id of root.parkedIds) next[id] = root.seenTitle[id] ?? Niri.windowMap[id]?.title ?? "";
		root.seenTitle = next;
		const views = {};
		for (const id in root.viewFor) if (root.parkedIds.includes(Number(id))) views[id] = root.viewFor[id];
		if (Object.keys(views).length !== Object.keys(root.viewFor).length) {
			root.viewFor = views;
			saveTimer.restart();
		}
		root.sendShots();
	}

	// ── live pictures ────────────────────────────────────────────────────
	// the window the pointer rests on, pictured as long as it rests there
	property int peeking: -1
	readonly property var pictured: root.parkedIds.filter(id => root.viewOf(id) === "live" || id === root.peeking)
	readonly property string shotDir: `${Paths.runtime}/parking`
	property var shotFiles: ({})
	property int shotsRev: 0

	onPicturedChanged: root.sendShots()

	function shot(id, rev) {
		const file = root.shotFiles[id];
		return file ? `file://${file.path}?${file.n}` : "";
	}

	function sendShots() {
		if (!shots.running) return;
		shots.write(root.pictured.map(id => {
			const size = Niri.windowMap[id]?.layout?.window_size ?? [1600, 900];
			return `${id}:${Math.round(Number(size[0]) || 1600)}:${Math.round(Number(size[1]) || 900)}`;
		}).join(" ") + "\n");
	}

	Process {
		id: shots

		running: root.enabled && root.pictured.length > 0
		command: ["python3", `${Paths.scripts}/window_shots.py`, root.shotDir, "640", "4"]
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
				files[data.id] = { path: String(data.file), n: (old?.n ?? 0) + 1, width: Number(data.width), height: Number(data.height) };
				root.shotsRev++;
			}
		}
	}

	// ── settings file ────────────────────────────────────────────────────
	Timer {
		id: saveTimer

		interval: 300
		onTriggered: file.setText(JSON.stringify({ view: root.view, viewFor: root.viewFor }, null, "\t") + "\n")
	}

	FileView {
		id: file

		path: Paths.stateFile("parking.json")
		blockLoading: true
		printErrors: false
		watchChanges: true
		onFileChanged: reload()
		onLoaded: {
			let saved = {};
			try {
				saved = JSON.parse(String(text() || "{}"));
			} catch (error) {
				return;
			}
			if (root.views.some(view => view.id === saved.view)) root.view = saved.view;
			if (saved.viewFor && typeof saved.viewFor === "object") root.viewFor = saved.viewFor;
		}
	}

	function isParkingSpace(ws) {
		return root.enabled && String(ws?.name ?? "").startsWith(root.prefix);
	}

	function isParked(id) {
		const window = Niri.windowMap[id];
		return !!window && root.isParkingSpace(Niri.workspaceMap[window.workspace_id]);
	}

	function spaceOf(output) {
		return Niri.workspaces.find(ws => ws.name === root.prefix + output) ?? null;
	}

	// ── parking ──────────────────────────────────────────────────────────
	// a strip at the right edge of `output` was entered
	function edgeEntered(output) {
		if (!root.armed) return;
		root.hitOutput = output;
		root.hitAt = Date.now();
		settle.restart();
		root.match();
	}

	function match() {
		if (root.dropped === -1 || root.hitOutput === "") return;
		// entered while still moving: the drop was right there; after it only
		// at once, not when the pointer wanders onto the edge later
		if (root.hitAt - root.droppedAt > root.together) return;
		const id = root.dropped;
		const output = root.hitOutput;
		root.dropped = -1;
		root.hitOutput = "";
		// the drop's workspace changes (a new empty one) come right after
		Qt.callLater(() => parkSoon.start(id, output));
	}

	Timer {
		id: parkSoon

		property int window: -1
		property string output: ""

		function start(id, output) {
			parkSoon.window = id;
			parkSoon.output = output;
			parkSoon.restart();
		}

		interval: 80
		onTriggered: root.park(parkSoon.window, parkSoon.output)
	}

	// what is left of a drag a moment after it
	Timer {
		id: settle

		interval: 400
		onTriggered: {
			root.dropped = -1;
			root.hitOutput = "";
		}
	}

	function park(id, output) {
		if (!root.enabled || !Niri.windowMap[id] || root.isParked(id)) return;
		const move = space => ({ MoveWindowToWorkspace: { window_id: id, reference: { Id: space }, focus: false } });
		const space = root.spaceOf(output);
		if (space) {
			Niri.request([move(space.id)]);
			return;
		}
		// the empty workspace at the end of the screen becomes the parking
		const used = {};
		for (const window of Niri.windows) used[window.workspace_id] = true;
		const spare = Niri.workspaces
			.filter(ws => String(ws.output) === output && !used[ws.id] && !ws.name && !ws.is_active)
			.sort((a, b) => Number(b.idx) - Number(a.idx))[0];
		if (!spare) return;
		Niri.request([{ SetWorkspaceName: { name: root.prefix + output, workspace: { Id: spare.id } } }, move(spare.id)]);
	}

	// the focused window onto the edge of its screen (a key)
	function parkFocused() {
		const window = Niri.windowMap[Niri.focusedId];
		const output = Niri.workspaceMap[window?.workspace_id]?.output;
		if (window && output) root.park(Number(window.id), String(output));
	}

	// back onto the workspace its screen shows, focused
	function restore(id) {
		root.markSeen(id);
		const window = Niri.windowMap[id];
		const output = Niri.workspaceMap[window?.workspace_id]?.output;
		const target = Niri.workspaces.find(ws => String(ws.output) === String(output) && ws.is_active && !root.isParkingSpace(ws))
			?? Niri.workspaces.find(ws => ws.is_focused && !root.isParkingSpace(ws));
		if (!target) return;
		Niri.request([{ MoveWindowToWorkspace: { window_id: Number(id), reference: { Id: target.id }, focus: true } },
			{ FocusWindow: { id: Number(id) } }]);
	}

	// the one parked last on the focused screen, or anywhere
	function restoreLast() {
		const focused = Niri.workspaces.find(ws => ws.is_focused);
		const here = root.parked[String(focused?.output ?? "")] ?? [];
		const all = [].concat(...Object.values(root.parked));
		const list = here.length > 0 ? here : all;
		if (list.length > 0) root.restore(list[list.length - 1].id);
	}

	// switched off: every parked window comes back, the workspaces lose their names
	function releaseAll() {
		const named = Niri.workspaces.filter(ws => String(ws.name ?? "").startsWith(root.prefix));
		if (named.length === 0) return;
		const steps = [];
		for (const ws of named) {
			const target = Niri.workspaces.find(other => String(other.output) === String(ws.output) && other.is_active && other.id !== ws.id);
			for (const window of Niri.windows.filter(window => window.workspace_id === ws.id))
				if (target) steps.push({ MoveWindowToWorkspace: { window_id: Number(window.id), reference: { Id: target.id }, focus: false } });
			steps.push({ UnsetWorkspaceName: { reference: { Id: ws.id } } });
		}
		Niri.request(steps);
	}

	onEnabledChanged: if (!root.enabled && Niri.ready) root.releaseAll()

	// an empty parking loses its name, so niri takes the workspace away
	// again; a moment later, the parking just named gets its window first
	Timer {
		id: tidy

		interval: 1500
		onTriggered: {
			if (!root.enabled) return;
			const used = {};
			for (const window of Niri.windows) used[window.workspace_id] = true;
			const steps = Niri.workspaces.filter(ws => root.isParkingSpace(ws) && !used[ws.id])
				.map(ws => ({ UnsetWorkspaceName: { reference: { Id: ws.id } } }));
			if (steps.length > 0) Niri.request(steps);
		}
	}

	// ── following niri ───────────────────────────────────────────────────
	// where each screen was before, to step over the parking in the same direction
	property var lastIdx: ({})

	function stepOver(ws) {
		const output = String(ws.output);
		const before = root.lastIdx[output];
		const down = before === undefined || before < ws.idx;
		const others = Niri.workspaces.filter(other => String(other.output) === output && !root.isParkingSpace(other))
			.sort((a, b) => Number(a.idx) - Number(b.idx));
		const next = down ? others.find(other => other.idx > ws.idx) ?? others[others.length - 1]
			: others.slice().reverse().find(other => other.idx < ws.idx) ?? others[0];
		if (next) Niri.request([{ FocusWorkspace: { reference: { Id: next.id } } }]);
	}

	Connections {
		target: Niri

		function onLine(text, event) {
			if (!root.enabled) return;
			const name = Object.keys(event)[0];
			const data = event[name];
			if (name === "WindowOpenedOrChanged") {
				const window = data.window;
				if (window.workspace_id === null || window.workspace_id === undefined) {
					root.moving = Number(window.id);
				} else if (Number(window.id) === root.moving) {
					root.moving = -1;
					root.dropped = Number(window.id);
					root.droppedAt = Date.now();
					settle.restart();
					root.match();
				}
			} else if (name === "WindowClosed" && Number(data.id) === root.moving) {
				root.moving = -1;
			} else if (name === "WorkspaceActivated") {
				const ws = Niri.workspaceMap[data.id];
				if (!ws) return;
				// gone to by a key or a window there asked for focus
				if (root.isParkingSpace(ws)) {
					const before = root.lastIdx[String(ws.output)];
					const window = Niri.windowMap[ws.active_window_id];
					if (before !== undefined && Math.abs(before - ws.idx) > 1 && window) root.restore(Number(window.id));
					else root.stepOver(ws);
					return;
				}
				const map = Object.assign({}, root.lastIdx);
				map[String(ws.output)] = Number(ws.idx);
				root.lastIdx = map;
			}
		}

		function onWindowsChanged() {
			tidy.restart();
		}
	}
}
