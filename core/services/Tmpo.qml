pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// qtrack time tracking (qtrack-local CLI) incl. Teamwork task picking/sync.
// Status polls every second so the bar timer is always live.
Singleton {
	id: root

	readonly property string cliPath: `${Paths.scripts}/qtrack/qtrack-local`

	property bool tracking: false
	property bool paused: false
	property bool canResume: false
	property var todayTasks: []
	property var teamworkTasks: []
	property string selectedTodayTaskKey: ""
	property string selectedTeamworkTaskId: ""
	property string teamworkStatus: "Loading Teamwork tasks..."
	property string teamworkSyncStatus: ""
	property bool syncingDraft: false
	property string draftProject: ""
	property string draftDescription: ""
	property string project: ""
	property string started: ""
	// qtrack is polled every few seconds; in between the clock ticks locally
	property string rawDuration: ""
	property real rawAt: 0
	property real now: Date.now()
	readonly property string duration: root.tracking ? root.tick(root.rawDuration, (root.now - root.rawAt) / 1000) : root.rawDuration
	property string description: ""
	property string todayTotal: "--"
	property string todayEntries: "0"
	property string statusMessage: "Idle"
	readonly property bool teamworkRefreshing: teamworkTasksProcess.running
	readonly property bool syncing: teamworkSyncProcess.running
	readonly property bool actionRunning: actionProcess.running

	function seconds(clock) {
		const parts = String(clock || "").split(":").map(v => Number(v));
		if (parts.length < 2 || parts.some(v => !Number.isFinite(v))) return -1;
		return parts.reduce((total, v) => total * 60 + v, 0);
	}

	function tick(clock, delta) {
		const base = root.seconds(clock);
		if (base < 0) return clock;
		const total = Math.max(0, Math.floor(base + Math.max(0, delta)));
		const h = Math.floor(total / 3600);
		const m = Math.floor((total % 3600) / 60);
		const sec = total % 60;
		const pad = v => (v < 10 ? "0" : "") + v;
		if (h > 0 || String(clock).split(":").length > 2) return `${h}:${pad(m)}:${pad(sec)}`;
		return `${m}:${pad(sec)}`;
	}

	// seconds of the running session
	readonly property int elapsedSeconds: Math.max(0, root.seconds(root.duration))

	function stripAnsi(value) {
		return String(value || "").replace(/\u001b\[[0-9;]*[A-Za-z]/g, "");
	}

	function refresh() {
		if (!statusProcess.running) statusProcess.running = true;
		if (!snapshotProcess.running) snapshotProcess.running = true;
		if (!teamworkTasksProcess.running) teamworkTasksProcess.running = true;
	}

	function refreshTeamworkTasks() {
		if (teamworkTasksProcess.running) return;
		root.teamworkStatus = "Loading Teamwork tasks...";
		teamworkTasksProcess.running = true;
	}

	function taskKey(project, description) {
		return `${String(project || "")}\u001f${String(description || "")}`;
	}

	function findTeamworkTaskById(taskId) {
		const expected = String(taskId || "");
		if (expected === "") return null;
		for (const task of root.teamworkTasks)
			if (String(task.task_id || task.id || "") === expected) return task;
		return null;
	}

	function projectLabelFromTeamworkTask(task) {
		if (!task) return "";
		const projectName = String(task.project_name || "").trim();
		const taskName = String(task.task_name || task.name || task.label || "").trim();
		if (projectName !== "" && taskName !== "") return `${projectName} / ${taskName}`;
		return taskName || projectName;
	}

	function buildStartArgs(project, description, task) {
		const args = ["start", "--project", String(project || ""), "--description", String(description || "")];
		if (!task) return args;
		const taskId = String(task.teamwork_task_id || task.task_id || task.id || "");
		const projectId = String(task.teamwork_project_id || task.project_id || "");
		if (taskId === "" || projectId === "") return args;
		return args.concat([
			"--teamwork-task-id", taskId,
			"--teamwork-project-id", projectId,
			"--teamwork-task-name", String(task.teamwork_task_name || task.task_name || ""),
			"--teamwork-project-name", String(task.teamwork_project_name || task.project_name || ""),
			"--teamwork-task-url", String(task.teamwork_task_url || task.url || ""),
		]);
	}

	function findTodayTask(project, description) {
		return root.findTodayTaskByKey(root.taskKey(project, description));
	}

	function findTodayTaskByKey(key) {
		const expectedKey = String(key || "");
		if (expectedKey === "") return null;
		for (const task of root.todayTasks)
			if (root.taskKey(task.project, task.description) === expectedKey) return task;
		return null;
	}

	function syncSelectionFromDraft() {
		const task = root.findTodayTask(root.draftProject, root.draftDescription);
		root.selectedTodayTaskKey = task ? root.taskKey(task.project, task.description) : "";
		if (task && task.teamwork_task_id) root.selectedTeamworkTaskId = String(task.teamwork_task_id);
	}

	function seedDraft(force = false) {
		const selectedTask = root.findTodayTaskByKey(root.selectedTodayTaskKey);
		if (selectedTask) {
			root.applyDraftTask(selectedTask.project, selectedTask.description);
			root.selectedTeamworkTaskId = String(selectedTask.teamwork_task_id || "");
			return;
		}
		if (root.tracking || root.paused) {
			const hasDraft = root.draftProject.trim() !== "" || root.draftDescription.trim() !== "";
			if (force || !hasDraft) root.applyDraftTask(root.project, root.description);
			return;
		}
		if (force) root.applyDraftTask("", "");
	}

	function applyDraftTask(project, description) {
		root.syncingDraft = true;
		root.draftProject = String(project || "");
		root.draftDescription = String(description || "");
		root.syncingDraft = false;
		root.syncSelectionFromDraft();
	}

	function selectTodayTask(project, description) {
		root.applyDraftTask(project, description);
	}

	function selectTeamworkTask(taskId) {
		const task = root.findTeamworkTaskById(taskId);
		root.selectedTeamworkTaskId = task ? String(task.task_id || task.id || "") : "";
		root.draftProject = root.projectLabelFromTeamworkTask(task);
		root.syncSelectionFromDraft();
	}

	function editProject(value) {
		root.draftProject = value;
		if (!root.syncingDraft) root.syncSelectionFromDraft();
	}

	function editDescription(value) {
		root.draftDescription = value;
		if (!root.syncingDraft) root.syncSelectionFromDraft();
	}

	function applyStatusPayload(payload) {
		const current = payload && payload.session ? payload.session : null;
		const lastSession = payload && payload.last_session ? payload.last_session : null;
		root.tracking = !!(payload && payload.tracking);
		root.paused = !!(payload && payload.paused);
		root.canResume = !!(payload && payload.can_resume);
		if (current) {
			root.project = String(current.project || "");
			root.description = String(current.description || "");
			root.started = String(current.started_label || "");
			root.rawDuration = String(current.duration_clock || current.duration_label || "--");
			root.rawAt = Date.now();
			root.now = root.rawAt;
		} else if (lastSession) {
			root.project = String(lastSession.project || "");
			root.description = String(lastSession.description || "");
			root.started = "";
			root.rawDuration = String(lastSession.duration_short || lastSession.duration_label || "--");
		} else {
			root.project = "";
			root.description = "";
			root.started = "";
			root.rawDuration = "";
		}
		root.statusMessage = String((payload && payload.status_message) || "Idle");
	}

	function parseStatus(raw) {
		try {
			root.applyStatusPayload(JSON.parse(String(raw || "")));
		} catch (error) {
			root.applyStatusPayload({});
		}
	}

	function parseSnapshot(raw) {
		let parsed = {};
		try { parsed = JSON.parse(String(raw || "")); } catch (error) { parsed = {}; }
		root.applyStatusPayload(parsed);
		const today = parsed.today || {};
		root.todayTotal = String(today.total_label || "--");
		root.todayEntries = String(today.task_count !== undefined ? today.task_count : 0);
		root.todayTasks = Array.isArray(parsed.today_tasks) ? parsed.today_tasks : [];
		root.syncSelectionFromDraft();
		root.seedDraft(false);
	}

	function parseTeamworkTasks(raw) {
		if (String(raw || "").trim() === "") return;
		let parsed = {};
		try { parsed = JSON.parse(String(raw || "")); } catch (error) { parsed = {}; }
		root.teamworkTasks = Array.isArray(parsed.entries) ? parsed.entries : [];
		root.teamworkStatus = root.teamworkTasks.length > 0
			? `${root.teamworkTasks.length} Teamwork tasks`
			: "No Teamwork tasks";
		if (root.selectedTeamworkTaskId === "" && root.teamworkTasks.length > 0)
			root.selectTeamworkTask(root.teamworkTasks[0].task_id || root.teamworkTasks[0].id);
	}

	function parseTeamworkTasksError(raw) {
		const detail = root.stripAnsi(raw).trim();
		if (detail !== "") root.teamworkStatus = detail;
	}

	function finishTeamworkTasks(exitCode) {
		if (exitCode !== 0 && root.teamworkStatus === "Loading Teamwork tasks...")
			root.teamworkStatus = "Teamwork API sync failed.";
	}

	function parseTeamworkSync(raw) {
		let parsed = {};
		try { parsed = JSON.parse(String(raw || "")); } catch (error) { parsed = {}; }
		root.teamworkSyncStatus = String(parsed.message || "Teamwork sync done.");
	}

	function parseTeamworkSyncError(raw) {
		const detail = root.stripAnsi(raw).trim();
		if (detail !== "") root.teamworkSyncStatus = detail;
	}

	function runAction(args) {
		if (actionProcess.running) return;
		actionProcess.command = ["python3", root.cliPath].concat(args);
		actionProcess.running = true;
	}

	readonly property bool canStart: {
		const task = root.findTeamworkTaskById(root.selectedTeamworkTaskId);
		return !root.tracking && !!task && String(task.project_id || "") !== "" && root.draftDescription.trim() !== "";
	}

	function start() {
		const selectedTask = root.findTeamworkTaskById(root.selectedTeamworkTaskId);
		const project = root.projectLabelFromTeamworkTask(selectedTask).trim();
		const description = root.draftDescription.trim();
		if (!selectedTask || project === "" || description === "") return;
		root.runAction(root.buildStartArgs(project, description, selectedTask));
	}

	function pause() {
		root.runAction(["pause"]);
	}

	function resume() {
		const selectedTask = root.findTodayTaskByKey(root.selectedTodayTaskKey);
		if (selectedTask) {
			const selectedKey = root.taskKey(selectedTask.project, selectedTask.description);
			const currentKey = root.taskKey(root.project, root.description);
			if (root.paused && selectedKey === currentKey) root.runAction(["resume"]);
			else root.runAction(root.buildStartArgs(selectedTask.project, selectedTask.description, selectedTask));
			return;
		}
		if (root.canResume) root.runAction(["resume"]);
	}

	function syncTeamwork() {
		if (teamworkSyncProcess.running) return;
		root.teamworkSyncStatus = "Writing checked entries to Teamwork...";
		teamworkSyncProcess.running = true;
	}

	Process {
		id: statusProcess
		command: ["python3", root.cliPath, "status", "--json"]
		stdout: StdioCollector { onStreamFinished: root.parseStatus(text) }
	}

	Process {
		id: snapshotProcess
		command: ["python3", root.cliPath, "snapshot", "--json"]
		stdout: StdioCollector { onStreamFinished: root.parseSnapshot(text) }
	}

	Process {
		id: teamworkTasksProcess
		command: ["python3", root.cliPath, "teamwork-tasks", "--json"]
		stdout: StdioCollector { onStreamFinished: root.parseTeamworkTasks(text) }
		stderr: StdioCollector { onStreamFinished: root.parseTeamworkTasksError(text) }
		onExited: exitCode => root.finishTeamworkTasks(exitCode)
	}

	Process {
		id: teamworkSyncProcess
		command: ["python3", root.cliPath, "sync-teamwork", "--json"]
		stdout: StdioCollector { onStreamFinished: root.parseTeamworkSync(text) }
		stderr: StdioCollector { onStreamFinished: root.parseTeamworkSyncError(text) }
		onExited: root.refresh()
	}

	Process {
		id: actionProcess
		command: ["sh", "-lc", ":"]
		onExited: root.refresh()
	}

	Timer {
		running: true
		repeat: true
		triggeredOnStart: true
		interval: 5000
		onTriggered: if (!statusProcess.running) statusProcess.running = true
	}

	Timer {
		running: root.tracking
		repeat: true
		interval: 1000
		onTriggered: root.now = Date.now()
	}

	Timer {
		running: true
		repeat: true
		triggeredOnStart: true
		interval: 15000
		onTriggered: if (!snapshotProcess.running) snapshotProcess.running = true
	}
}
