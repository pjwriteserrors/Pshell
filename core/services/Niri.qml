pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// niri workspaces and windows. The event stream triggers an immediate
// refresh on every change; a slow poll is kept as a safety net.
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
	// screencasts: [{ session_id, target: { Output | Window }, is_active, pw_node_id, … }]
	property var casts: []

	function parseJson(raw, fallback) {
		try {
			const parsed = JSON.parse(raw);
			return Array.isArray(parsed) ? parsed : fallback;
		} catch (error) {
			return fallback;
		}
	}

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
		const window = root.windows.find(w => Number(w.id) === Number(id));
		return window ? (window.title || window.app_id || "Window") : "";
	}

	function sync() {
		const workspaces = root.parseJson(workspacesProc.lastText, []);
		const windows = root.parseJson(windowsProc.lastText, []);
		const wsById = {};
		const occupied = {};
		for (const ws of workspaces) wsById[ws.id] = ws;
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

		// only publish changes, so title updates do not rebuild every bar
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
		root.workspaces = workspaces;
		root.windows = windows;

		const focused = windows.find(w => w.is_focused);
		const screen = focused ? Quickshell.screens.find(s => String(s.name) === String(wsById[focused.workspace_id]?.output ?? "")) : null;
		const size = focused?.layout?.tile_size;
		root.focusedFullscreen = !!screen && Array.isArray(size) && !focused.is_floating
			&& Math.abs(size[0] - screen.width) < 1 && Math.abs(size[1] - screen.height) < 1;
	}

	function focusWorkspace(workspace) {
		if (!workspace) return;
		Quickshell.execDetached(["sh", "-c", `niri msg action focus-monitor '${workspace.output}' && niri msg action focus-workspace ${Number(workspace.idx)}`]);
	}

	function refresh() {
		if (!workspacesProc.running) workspacesProc.running = true;
		if (!windowsProc.running) windowsProc.running = true;
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
		const window = root.windows.find(w => Number(w.id) === Number(id));
		if (!window || !workspace || window.workspace_id === workspace.id) return;
		const ref = workspace.name ? `'${workspace.name}'` : Number(workspace.idx);
		Quickshell.execDetached(["sh", "-c", `niri msg action move-window-to-monitor --id ${Number(id)} '${workspace.output}' && niri msg action move-window-to-workspace --window-id ${Number(id)} --focus false ${ref}`]);
	}

	function focusWorkspaceRelative(direction) {
		Quickshell.execDetached(["niri", "msg", "action", direction > 0 ? "focus-workspace-down" : "focus-workspace-up"]);
	}

	Timer {
		running: true
		repeat: true
		interval: 5000
		triggeredOnStart: true
		onTriggered: root.refresh()
	}

	Timer {
		id: debounce
		interval: 40
		onTriggered: root.refresh()
	}

	Process {
		id: workspacesProc

		property string lastText: "[]"
		command: ["niri", "msg", "-j", "workspaces"]
		stdout: StdioCollector {
			onStreamFinished: {
				workspacesProc.lastText = text;
				root.sync();
			}
		}
	}

	Process {
		id: windowsProc

		property string lastText: "[]"
		command: ["niri", "msg", "-j", "windows"]
		stdout: StdioCollector {
			onStreamFinished: {
				windowsProc.lastText = text;
				root.sync();
			}
		}
	}

	Process {
		id: castsProc

		command: ["niri", "msg", "-j", "casts"]
		stdout: StdioCollector {
			onStreamFinished: {
				try {
					const parsed = JSON.parse(text);
					if (Array.isArray(parsed)) root.casts = parsed;
				} catch (error) {}
			}
		}
	}

	Process {
		id: events

		running: true
		command: ["niri", "msg", "-j", "event-stream"]
		stdout: SplitParser {
			onRead: data => {
				if (data.startsWith('{"CastsChanged"')) {
					try {
						root.casts = JSON.parse(data).CastsChanged.casts ?? [];
					} catch (error) {}
					return;
				}
				// single cast events: ask for the whole list
				if (data.startsWith('{"Cast')) {
					if (!castsProc.running) castsProc.running = true;
					return;
				}
				if (data.indexOf("Workspace") >= 0 || data.indexOf("Window") >= 0)
					debounce.restart();
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
