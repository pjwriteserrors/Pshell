pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// niri workspaces and windows, kept from niri's event stream: it starts
// with the whole state and then tells every change, so nothing is asked
// again. A title that keeps changing (a terminal's spinner) is published at
// most every `titleDelay` ms; everything else at once.
//
// The stream is the shell's only one: daemons that follow niri get its
// lines through `line` (Mouse, Games), starting with `replay()`.
Singleton {
	id: root

	property var workspaces: []
	property var windows: []
	property var workspaceGroups: []
	property var tasks: []
	property var taskGroups: []
	property string groupsKey: ""
	property string tasksKey: ""
	// the focused window covers its whole output (fullscreen video, games …)
	property bool focusedFullscreen: false
	// the focused window's id, -1 none
	property int focusedId: -1
	// screencasts: [{ session_id, target: { Output | Window }, is_active, pw_node_id, … }]
	property var casts: []
	// the stream is up and has told the whole state
	property bool ready: false
	readonly property int titleDelay: 150

	// every line of niri's event stream, parsed: `event` is { Name: data }
	signal line(string text, var event)

	// id → raw window / workspace as niri tells them
	property var windowMap: ({})
	property var workspaceMap: ({})

	function focusTimestampValue(window) {
		const timestamp = window.focus_timestamp;
		if (!timestamp) return -1;
		return Number(timestamp.secs || 0) * 1000000000 + Number(timestamp.nanos || 0);
	}

	function layoutPositionValue(window) {
		const pos = window?.layout?.pos_in_scrolling_layout;
		if (!Array.isArray(pos) || pos.length < 2) return [999999, 999999];
		return [Number(pos[0] || 0), Number(pos[1] || 0)];
	}

	// outputs left to right as they are arranged physically
	function outputOrder(name) {
		for (const screen of Quickshell.screens)
			if (String(screen.name) === String(name)) return Number(screen.x || 0);
		return 1e9;
	}

	function titleOf(id) {
		const window = root.windowMap[id];
		return window ? (window.title || window.app_id || "Window") : "";
	}

	// the state as event lines, for a daemon that starts following now
	function replay() {
		return [
			JSON.stringify({ WorkspacesChanged: { workspaces: Object.values(root.workspaceMap) } }),
			JSON.stringify({ WindowsChanged: { windows: Object.values(root.windowMap) } })
		];
	}

	// ── keeping the state ─────────────────────────────────────────────────
	function apply(event) {
		const name = Object.keys(event)[0];
		const data = event[name];
		switch (name) {
		case "WorkspacesChanged": {
			const map = {};
			for (const ws of data.workspaces ?? []) map[ws.id] = ws;
			root.workspaceMap = map;
			return "all";
		}
		case "WorkspaceActivated": {
			const target = root.workspaceMap[data.id];
			if (!target) return "";
			for (const id in root.workspaceMap) {
				const ws = root.workspaceMap[id];
				if (ws.output === target.output) ws.is_active = ws.id === data.id;
				if (data.focused) ws.is_focused = ws.id === data.id;
			}
			return "all";
		}
		case "WorkspaceActiveWindowChanged": {
			const ws = root.workspaceMap[data.workspace_id];
			if (ws) ws.active_window_id = data.active_window_id;
			return "workspaces";
		}
		case "WorkspaceUrgencyChanged": {
			const ws = root.workspaceMap[data.id];
			if (ws) ws.is_urgent = data.urgent;
			return "workspaces";
		}
		case "WindowsChanged": {
			const map = {};
			for (const window of data.windows ?? []) map[window.id] = window;
			root.windowMap = map;
			return "all";
		}
		case "WindowOpenedOrChanged": {
			const window = data.window;
			const old = root.windowMap[window.id];
			if (window.is_focused)
				for (const id in root.windowMap) root.windowMap[id].is_focused = false;
			root.windowMap[window.id] = window;
			// only the title (or nothing) changed: no task or workspace moved
			if (old && old.app_id === window.app_id && old.workspace_id === window.workspace_id && old.is_focused === window.is_focused
				&& old.is_floating === window.is_floating && old.is_urgent === window.is_urgent
				&& JSON.stringify(old.layout) === JSON.stringify(window.layout))
				return "title";
			return "all";
		}
		case "WindowClosed":
			delete root.windowMap[data.id];
			return "all";
		case "WindowFocusChanged":
			for (const id in root.windowMap) root.windowMap[id].is_focused = Number(id) === data.id;
			return "all";
		case "WindowFocusTimestampChanged": {
			const window = root.windowMap[data.id];
			if (window) window.focus_timestamp = data.focus_timestamp;
			return "title";
		}
		case "WindowUrgencyChanged": {
			const window = root.windowMap[data.id];
			if (window) window.is_urgent = data.urgent;
			return "all";
		}
		case "WindowLayoutsChanged":
			for (const change of data.changes ?? []) {
				const window = root.windowMap[change[0]];
				if (window) window.layout = change[1];
			}
			return "all";
		case "CastsChanged":
			root.casts = data.casts ?? [];
			return "";
		case "CastStartedOrChanged": {
			const cast = data.cast;
			root.casts = root.casts.filter(c => c.session_id !== cast.session_id).concat([cast]);
			return "";
		}
		case "CastStopped":
			root.casts = root.casts.filter(c => c.session_id !== data.session_id);
			return "";
		}
		return "";
	}

	function publish() {
		titleTimer.stop();
		const workspaces = Object.values(root.workspaceMap);
		const windows = Object.values(root.windowMap);
		const wsById = root.workspaceMap;
		const occupied = {};
		for (const window of windows) occupied[window.workspace_id] = true;

		const sortedWs = workspaces.slice().sort((a, b) => {
			const oa = root.outputOrder(a.output);
			const ob = root.outputOrder(b.output);
			if (oa !== ob) return oa - ob;
			return Number(a.idx) - Number(b.idx);
		});
		const groups = [];
		for (const ws of sortedWs) {
			const entry = { id: ws.id, idx: ws.idx, output: String(ws.output || ""), name: ws.name || "", active: !!ws.is_active, focused: !!ws.is_focused, occupied: !!occupied[ws.id] };
			const last = groups[groups.length - 1];
			if (last && last.output === entry.output) last.workspaces.push(entry);
			else groups.push({ output: entry.output, workspaces: [entry] });
		}

		const rank = ws => ws ? root.outputOrder(ws.output) * 1000 + Number(ws.idx || 0) : 1e12;
		const tasks = windows.slice().sort((left, right) => {
			const wl = rank(wsById[left.workspace_id]);
			const wr = rank(wsById[right.workspace_id]);
			if (wl !== wr) return wl - wr;
			const [leftX, leftY] = root.layoutPositionValue(left);
			const [rightX, rightY] = root.layoutPositionValue(right);
			if (leftX !== rightX) return leftX - rightX;
			if (leftY !== rightY) return leftY - rightY;
			return Number(left.id || 0) - Number(right.id || 0);
		}).map(window => ({
			id: Number(window.id),
			appId: window.app_id || "",
			isFocused: !!window.is_focused,
			isUrgent: !!window.is_urgent,
			output: String(wsById[window.workspace_id]?.output || ""),
			onActiveWorkspace: !!wsById[window.workspace_id]?.is_active
		}));
		const taskGroups = [];
		for (const task of tasks) {
			const last = taskGroups[taskGroups.length - 1];
			if (last && last.output === task.output) last.tasks.push(task);
			else taskGroups.push({ output: task.output, tasks: [task] });
		}

		// only publish changes, so a focus change does not rebuild every bar
		const groupsKey = JSON.stringify(groups);
		if (groupsKey !== root.groupsKey) {
			root.groupsKey = groupsKey;
			root.workspaceGroups = groups;
		}
		const tasksKey = JSON.stringify(tasks);
		if (tasksKey !== root.tasksKey) {
			root.tasksKey = tasksKey;
			root.tasks = tasks;
			root.taskGroups = taskGroups;
		}
		root.workspaces = workspaces.map(ws => Object.assign({}, ws));
		root.windows = windows.map(window => Object.assign({}, window));

		const focused = windows.find(w => w.is_focused);
		root.focusedId = focused ? Number(focused.id) : -1;
		const screen = focused ? Quickshell.screens.find(s => String(s.name) === String(wsById[focused.workspace_id]?.output ?? "")) : null;
		const size = focused?.layout?.tile_size;
		root.focusedFullscreen = !!screen && Array.isArray(size) && !focused.is_floating
			&& Math.abs(size[0] - screen.width) < 1 && Math.abs(size[1] - screen.height) < 1;
	}

	// ── actions ───────────────────────────────────────────────────────────
	function focusWorkspace(workspace) {
		if (!workspace) return;
		root.inOrder([["niri", "msg", "action", "focus-monitor", String(workspace.output)],
			["niri", "msg", "action", "focus-workspace", String(Number(workspace.idx))]]);
	}

	function focusWindow(id) {
		if (id === undefined || id === null) return;
		Quickshell.execDetached(["niri", "msg", "action", "focus-window", "--id", String(id)]);
	}

	function closeWindow(id) {
		Quickshell.execDetached(["niri", "msg", "action", "close-window", "--id", String(id)]);
	}

	// move a window to any workspace, also across monitors, without
	// following it with the focus
	function moveWindow(id, workspace) {
		const window = root.windowMap[id];
		if (!window || !workspace || window.workspace_id === workspace.id) return;
		const ref = workspace.name ? String(workspace.name) : String(Number(workspace.idx));
		root.inOrder([["niri", "msg", "action", "move-window-to-monitor", "--id", String(Number(id)), String(workspace.output)],
			["niri", "msg", "action", "move-window-to-workspace", "--window-id", String(Number(id)), "--focus", "false", ref]]);
	}

	// niri actions one after the other, each once the one before is done;
	// a step that fails ends its row
	property var queue: []

	function inOrder(commands) {
		root.queue = root.queue.concat([commands]);
		if (!sequence.running) root.next();
	}

	function next() {
		while (root.queue.length > 0 && root.queue[0].length === 0) root.queue = root.queue.slice(1);
		if (root.queue.length === 0) return;
		const row = root.queue[0];
		sequence.command = row[0];
		root.queue = [row.slice(1)].concat(root.queue.slice(1));
		sequence.running = true;
	}

	function focusWorkspaceRelative(direction) {
		Quickshell.execDetached(["niri", "msg", "action", direction > 0 ? "focus-workspace-down" : "focus-workspace-up"]);
	}

	Process {
		id: sequence

		onExited: code => {
			if (code !== 0 && root.queue.length > 0) root.queue = root.queue.slice(1);
			root.next();
		}
	}

	Timer {
		id: titleTimer

		interval: root.titleDelay
		onTriggered: root.publish()
	}

	Process {
		id: events

		running: true
		command: ["niri", "msg", "-j", "event-stream"]
		stdout: SplitParser {
			onRead: data => {
				let event;
				try {
					event = JSON.parse(data);
				} catch (error) {
					return;
				}
				const change = root.apply(event);
				if (change === "all" || change === "workspaces") {
					root.ready = true;
					root.publish();
				} else if (change === "title" && !titleTimer.running) {
					titleTimer.start();
				}
				root.line(data, event);
			}
		}
		onExited: restartEvents.restart()
	}

	Timer {
		id: restartEvents
		interval: 3000
		onTriggered: events.running = true
	}
}
