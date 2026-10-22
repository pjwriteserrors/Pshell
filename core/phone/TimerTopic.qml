import QtQuick
import Quickshell
import qs.core.services

// timer: the time tracker (qtrack). The running time is sent as the moment
// it started, so it costs no message per second.
Topic {
	id: topic

	name: "timer"

	// when the running session would have started had it never paused (ms)
	property real startedAt: 0

	function anchor() {
		const next = QtrackTimer.rawAt - QtrackTimer.seconds(QtrackTimer.rawDuration) * 1000;
		// the tracker reports whole seconds: only a real jump moves the anchor
		if (Math.abs(next - topic.startedAt) > 2500) topic.startedAt = next;
	}

	Connections {
		target: QtrackTimer
		function onRawAtChanged() {
			topic.anchor();
		}
	}

	data: topic.wanted ? ({
		tracking: QtrackTimer.tracking,
		paused: QtrackTimer.paused,
		canResume: QtrackTimer.canResume,
		project: QtrackTimer.project,
		description: QtrackTimer.description,
		started: QtrackTimer.started,
		startedAt: QtrackTimer.tracking ? topic.startedAt : 0,
		last: QtrackTimer.tracking ? "" : QtrackTimer.rawDuration,
		status: QtrackTimer.statusMessage,
		todayTotal: QtrackTimer.todayTotal,
		todaySeconds: QtrackTimer.todaySeconds,
		busy: QtrackTimer.actionRunning,
		tasks: QtrackTimer.todayTasks.map(task => ({
			project: String(task.project || ""),
			description: String(task.description || ""),
			duration: String(task.duration_short || task.duration_label || task.total_label || ""),
			current: QtrackTimer.taskKey(task.project, task.description) === QtrackTimer.taskKey(QtrackTimer.project, QtrackTimer.description) && (QtrackTimer.tracking || QtrackTimer.paused)
		})),
		teamwork: QtrackTimer.teamworkTasks.slice(0, 150).map(task => ({
			id: String(task.task_id || task.id || ""),
			name: String(task.task_name || task.name || task.label || ""),
			project: String(task.project_name || "")
		}))
	}) : null

	onWantedChanged: if (topic.wanted) {
		topic.anchor();
		QtrackTimer.refresh();
	}

	function call(action, args, done) {
		switch (action) {
		case "pause":
			QtrackTimer.pause();
			return {};
		case "resume":
			QtrackTimer.resume();
			return {};
		case "switch": {
			const task = QtrackTimer.findTodayTask(String(args.project || ""), String(args.description || ""));
			if (!task) throw new Error("No such task today");
			QtrackTimer.switchTo(task);
			return {};
		}
		case "start": {
			const task = QtrackTimer.findTeamworkTaskById(String(args.id || ""));
			const description = String(args.description || "").trim();
			if (!task || description === "") throw new Error("A task and a description are needed");
			if (QtrackTimer.tracking) throw new Error("A timer is running");
			QtrackTimer.runAction(QtrackTimer.buildStartArgs(QtrackTimer.projectLabelFromTeamworkTask(task).trim(), description, task));
			return {};
		}
		case "refreshTeamwork":
			QtrackTimer.refreshTeamworkTasks();
			return {};
		}
		throw new Error("unknown-action");
	}
}
