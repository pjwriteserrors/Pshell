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
		const next = Tmpo.rawAt - Tmpo.seconds(Tmpo.rawDuration) * 1000;
		// the tracker reports whole seconds: only a real jump moves the anchor
		if (Math.abs(next - topic.startedAt) > 2500) topic.startedAt = next;
	}

	Connections {
		target: Tmpo
		function onRawAtChanged() {
			topic.anchor();
		}
	}

	data: topic.wanted ? ({
		tracking: Tmpo.tracking,
		paused: Tmpo.paused,
		canResume: Tmpo.canResume,
		project: Tmpo.project,
		description: Tmpo.description,
		started: Tmpo.started,
		startedAt: Tmpo.tracking ? topic.startedAt : 0,
		last: Tmpo.tracking ? "" : Tmpo.rawDuration,
		status: Tmpo.statusMessage,
		todayTotal: Tmpo.todayTotal,
		todaySeconds: Tmpo.todaySeconds,
		busy: Tmpo.actionRunning,
		tasks: Tmpo.todayTasks.map(task => ({
			project: String(task.project || ""),
			description: String(task.description || ""),
			duration: String(task.duration_short || task.duration_label || task.total_label || ""),
			current: Tmpo.taskKey(task.project, task.description) === Tmpo.taskKey(Tmpo.project, Tmpo.description) && (Tmpo.tracking || Tmpo.paused)
		})),
		teamwork: Tmpo.teamworkTasks.slice(0, 150).map(task => ({
			id: String(task.task_id || task.id || ""),
			name: String(task.task_name || task.name || task.label || ""),
			project: String(task.project_name || "")
		}))
	}) : null

	onWantedChanged: if (topic.wanted) {
		topic.anchor();
		Tmpo.refresh();
	}

	function call(action, args, done) {
		switch (action) {
		case "pause":
			Tmpo.pause();
			return {};
		case "resume":
			Tmpo.resume();
			return {};
		case "switch": {
			const task = Tmpo.findTodayTask(String(args.project || ""), String(args.description || ""));
			if (!task) throw new Error("No such task today");
			Tmpo.switchTo(task);
			return {};
		}
		case "start": {
			const task = Tmpo.findTeamworkTaskById(String(args.id || ""));
			const description = String(args.description || "").trim();
			if (!task || description === "") throw new Error("A task and a description are needed");
			if (Tmpo.tracking) throw new Error("A timer is running");
			Tmpo.runAction(Tmpo.buildStartArgs(Tmpo.projectLabelFromTeamworkTask(task).trim(), description, task));
			return {};
		}
		case "refreshTeamwork":
			Tmpo.refreshTeamworkTasks();
			return {};
		}
		throw new Error("unknown-action");
	}
}
