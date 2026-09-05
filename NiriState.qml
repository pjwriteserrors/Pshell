pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

Item {
	id: root
	visible: false

	property int refreshInterval: 1500
	property var focusedWorkspace: null
	property var windows: []
	property var tasks: []
	property var tasksByOutput: ({})
	property string workspacesJson: "[]"
	property string windowsJson: "[]"

	function refresh() {
		workspacesProcess.exec([ "niri", "msg", "-j", "workspaces" ]);
		windowsProcess.exec([ "niri", "msg", "-j", "windows" ]);
	}

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

	function syncState() {
		const workspaces = root.parseJson(root.workspacesJson, []);
		const windows = root.parseJson(root.windowsJson, []);
		const focusedWorkspace = workspaces.find(workspace => workspace.is_focused)
			|| workspaces.find(workspace => workspace.is_active)
			|| null;
		const workspaceOutputById = ({});

		for (const workspace of workspaces) {
			workspaceOutputById[workspace.id] = String(workspace.output || "");
		}

		const tasks = focusedWorkspace
			? root.buildTasks(windows.filter(window => window.workspace_id === focusedWorkspace.id))
			: [];
		const tasksByOutput = ({});

		for (const window of windows) {
			const outputName = workspaceOutputById[window.workspace_id];
			if (!outputName) continue;
			if (!tasksByOutput[outputName]) tasksByOutput[outputName] = [];
			tasksByOutput[outputName].push(window);
		}

		for (const outputName of Object.keys(tasksByOutput)) {
			tasksByOutput[outputName] = root.buildTasks(tasksByOutput[outputName]);
		}

		root.focusedWorkspace = focusedWorkspace;
		root.windows = windows;
		root.tasks = tasks;
		root.tasksByOutput = tasksByOutput;
	}

	function focusWindow(windowId) {
		if (windowId === undefined || windowId === null) return;
		focusProcess.exec([ "niri", "msg", "action", "focus-window", "--id", String(windowId) ]);
		postFocusRefresh.restart();
	}

	Timer {
		running: true
		repeat: true
		interval: root.refreshInterval
		triggeredOnStart: true
		onTriggered: root.refresh()
	}

	Timer {
		id: postFocusRefresh
		interval: 180
		repeat: false
		onTriggered: root.refresh()
	}

	Process {
		id: workspacesProcess
		command: [ "niri", "msg", "-j", "workspaces" ]
		stdout: StdioCollector {
			onStreamFinished: {
				root.workspacesJson = text;
				root.syncState();
			}
		}
	}

	Process {
		id: windowsProcess
		command: [ "niri", "msg", "-j", "windows" ]
		stdout: StdioCollector {
			onStreamFinished: {
				root.windowsJson = text;
				root.syncState();
			}
		}
	}

	Process {
		id: focusProcess
		command: [ "niri", "msg", "action", "focus-window", "--id", "0" ]
		onExited: postFocusRefresh.restart()
	}
}
