pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// Live view of niri's workspaces and windows.
//
// This follows `niri msg -j event-stream` instead of polling. Polling meant two
// processes every 1.5 s and, worse, a brand new task array on every tick, which
// made every Repeater in the bar tear down and rebuild its delegates - visible
// as icons blinking. Events arrive the moment something happens and only touch
// the window they are about.
//
// The stream is authoritative; the periodic refresh below exists purely as a
// safety net for an event this file does not know how to fold in yet.
Item {
	id: root
	visible: false

	// Safety resync. Not a poll: the event stream is what keeps state current.
	property int resyncInterval: 60000

	property var focusedWorkspace: null
	property var windows: []
	property var tasks: []
	property var tasksByOutput: ({})

	// Raw state, keyed by id, mutated in place by the incremental events.
	property var windowById: ({})
	property var workspaceById: ({})

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

	function buildTasks(windows) {
		return windows
			.slice()
			.sort((left, right) => {
				if (left.is_urgent !== right.is_urgent) return left.is_urgent ? -1 : 1;

				const [leftX, leftY] = root.layoutPositionValue(left);
				const [rightX, rightY] = root.layoutPositionValue(right);
				if (leftY !== rightY) return leftY - rightY;
				if (leftX !== rightX) return leftX - rightX;

				const timestampDelta = root.focusTimestampValue(right) - root.focusTimestampValue(left);
				if (timestampDelta !== 0) return timestampDelta;

				return Number(left.id || 0) - Number(right.id || 0);
			})
			.map(window => ({
				id: Number(window.id),
				title: window.title || window.app_id || "Window",
				appId: window.app_id || "",
				isFocused: !!window.is_focused,
				isUrgent: !!window.is_urgent,
				isFloating: !!window.is_floating
			}));
	}

	function tasksForOutput(outputName) {
		if (!outputName) return root.tasks;
		return root.tasksByOutput[outputName] || [];
	}

	function rebuild() {
		const workspaces = Object.values(root.workspaceById);
		const windows = Object.values(root.windowById);
		const focusedWorkspace = workspaces.find(workspace => workspace.is_focused)
			|| workspaces.find(workspace => workspace.is_active)
			|| null;
		const workspaceOutputById = ({});

		for (const workspace of workspaces)
			workspaceOutputById[workspace.id] = String(workspace.output || "");

		const tasksByOutput = ({});
		for (const window of windows) {
			const outputName = workspaceOutputById[window.workspace_id];
			if (!outputName) continue;
			if (!tasksByOutput[outputName]) tasksByOutput[outputName] = [];
			tasksByOutput[outputName].push(window);
		}

		for (const outputName of Object.keys(tasksByOutput))
			tasksByOutput[outputName] = root.buildTasks(tasksByOutput[outputName]);

		root.focusedWorkspace = focusedWorkspace;
		root.windows = windows;
		root.tasks = focusedWorkspace
			? root.buildTasks(windows.filter(window => window.workspace_id === focusedWorkspace.id))
			: [];
		root.tasksByOutput = tasksByOutput;
	}

	function replaceWorkspaces(list) {
		const map = ({});
		for (const workspace of list || []) map[workspace.id] = workspace;
		root.workspaceById = map;
	}

	function replaceWindows(list) {
		const map = ({});
		for (const window of list || []) map[window.id] = window;
		root.windowById = map;
	}

	// Returns true when the event was understood. Anything else falls through
	// to a full resync so an unhandled niri event can never freeze the bar.
	function applyEvent(name, payload) {
		switch (name) {
		case "WorkspacesChanged":
			root.replaceWorkspaces(payload.workspaces);
			return true;
		case "WorkspaceActivated": {
			for (const workspace of Object.values(root.workspaceById)) {
				if (workspace.id === payload.id) {
					workspace.is_active = true;
					if (payload.focused) workspace.is_focused = true;
				} else {
					// Only one workspace per output is active, and only one
					// workspace in the session is focused.
					if (payload.focused) workspace.is_focused = false;
					if (workspace.output === root.workspaceById[payload.id]?.output)
						workspace.is_active = false;
				}
			}
			return true;
		}
		case "WorkspaceActiveWindowChanged": {
			const workspace = root.workspaceById[payload.workspace_id];
			if (workspace) workspace.active_window_id = payload.active_window_id;
			return true;
		}
		case "WorkspaceUrgencyChanged": {
			const workspace = root.workspaceById[payload.id];
			if (workspace) workspace.is_urgent = !!payload.urgent;
			return true;
		}
		case "WindowsChanged":
			root.replaceWindows(payload.windows);
			return true;
		case "WindowOpenedOrChanged": {
			const window = payload.window;
			if (!window) return true;
			root.windowById[window.id] = window;
			if (window.is_focused) {
				for (const other of Object.values(root.windowById))
					if (other.id !== window.id) other.is_focused = false;
			}
			return true;
		}
		case "WindowClosed":
			delete root.windowById[payload.id];
			return true;
		case "WindowFocusChanged": {
			for (const window of Object.values(root.windowById))
				window.is_focused = window.id === payload.id;
			return true;
		}
		case "WindowUrgencyChanged": {
			const window = root.windowById[payload.id];
			if (window) window.is_urgent = !!payload.urgent;
			return true;
		}
		case "WindowLayoutsChanged": {
			for (const change of payload.changes || []) {
				const window = root.windowById[change[0]];
				if (window) window.layout = change[1];
			}
			return true;
		}
		// Events the bar does not derive anything from.
		case "KeyboardLayoutsChanged":
		case "KeyboardLayoutSwitched":
		case "OverviewOpenedOrClosed":
		case "ConfigLoaded":
		case "CastsChanged":
			return false;
		}

		return false;
	}

	function handleEvent(line) {
		const text = String(line || "").trim();
		if (text === "") return;

		let event;
		try {
			event = JSON.parse(text);
		} catch (error) {
			return;
		}

		let touched = false;
		for (const name of Object.keys(event)) {
			if (root.applyEvent(name, event[name] || {})) touched = true;
		}
		if (touched) root.rebuild();
	}

	function focusWindow(windowId) {
		if (windowId === undefined || windowId === null) return;
		Quickshell.execDetached([ "niri", "msg", "action", "focus-window", "--id", String(windowId) ]);
	}

	function closeWindow(windowId) {
		if (windowId === undefined || windowId === null) return;
		Quickshell.execDetached([ "niri", "msg", "action", "close-window", "--id", String(windowId) ]);
	}

	// Full snapshot: used at startup, after the stream reconnects, and by the
	// safety timer.
	function resync() {
		workspacesProcess.running = false;
		workspacesProcess.running = true;
		windowsProcess.running = false;
		windowsProcess.running = true;
	}

	Component.onCompleted: root.resync()

	Process {
		id: eventStream
		command: [ "niri", "msg", "-j", "event-stream" ]
		running: true

		stdout: SplitParser {
			onRead: data => root.handleEvent(data)
		}

		onExited: {
			// niri restarted or is not up yet; reconnect and take a fresh
			// snapshot so nothing that happened in between is missed.
			eventStreamRestart.restart();
		}
	}

	Timer {
		id: eventStreamRestart
		interval: 1000
		repeat: false
		onTriggered: {
			root.resync();
			eventStream.running = true;
		}
	}

	Timer {
		running: true
		repeat: true
		interval: root.resyncInterval
		onTriggered: root.resync()
	}

	Process {
		id: workspacesProcess
		command: [ "niri", "msg", "-j", "workspaces" ]
		stdout: StdioCollector {
			onStreamFinished: {
				try {
					root.replaceWorkspaces(JSON.parse(text));
					root.rebuild();
				} catch (error) {
					// niri not ready yet; the next resync picks it up.
				}
			}
		}
	}

	Process {
		id: windowsProcess
		command: [ "niri", "msg", "-j", "windows" ]
		stdout: StdioCollector {
			onStreamFinished: {
				try {
					root.replaceWindows(JSON.parse(text));
					root.rebuild();
				} catch (error) {
					// niri not ready yet; the next resync picks it up.
				}
			}
		}
	}
}
