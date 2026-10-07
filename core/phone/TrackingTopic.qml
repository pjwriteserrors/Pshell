import QtQuick
import Quickshell
import qs.core.services

// tracking: the day board of the time tracker: every tracked day, the
// entries of one, which are queued for Teamwork and which were sent. The
// selected day is the shell's, as the desktop's drawer shows it.
Topic {
	id: topic

	name: "tracking"
	throttle: 150

	function entry(args) {
		const project = String(args.project || "");
		const description = String(args.description || "");
		const found = Tracking.entries.find(item => String(item.project || "") === project && String(item.description || "") === description);
		if (!found) throw new Error("No such entry on this day");
		return found;
	}

	data: topic.wanted ? ({
		today: Tracking.today,
		day: Tracking.day,
		isToday: Tracking.isToday,
		loading: Tracking.loading,
		sending: Tracking.sending,
		status: Tracking.status,
		statusError: Tracking.statusError,
		minutes: Tracking.minutes,
		billableMinutes: Tracking.billableMinutes,
		workdayMinutes: Tracking.workdayMinutes,
		queued: Tracking.queued,
		sent: Tracking.sent,
		total: String(Tracking.report?.total_label || ""),
		days: Tracking.days.slice(0, 90).map(day => ({
			day: String(day.day),
			minutes: Math.round((Number(day.total_seconds) || 0) / 60),
			tasks: Number(day.task_count) || 0,
			projects: Number(day.project_count) || 0,
			queued: Number(day.queued_count) || 0,
			sent: Number(day.sent_count) || 0,
			unsent: Number(day.unsent_count) || 0
		})),
		entries: Tracking.entries.map(item => ({
			project: String(item.project || ""),
			description: String(item.description || ""),
			checked: !!item.checked,
			synced: !!item.teamwork_synced,
			billable: item.teamwork_billable !== false,
			minutes: Tracking.entryMinutes(item),
			duration: String(item.duration_label || ""),
			range: String(item.range_label || ""),
			started: String(item.first_started_label || ""),
			ended: String(item.last_ended_label || ""),
			ticket: String(item.teamwork_task_name || ""),
			ticketId: String(item.teamwork_task_id || ""),
			pending: Tracking.isPending(Tracking.key(item))
		})),
		groups: Tracking.groups.map(group => ({
			project: String(group.project || ""),
			tasks: Number(group.task_count) || 0,
			duration: String(group.duration_label || "")
		})),
		tickets: Tmpo.teamworkTasks.slice(0, 150).map(task => ({
			id: String(task.task_id || task.id || ""),
			name: String(task.task_name || task.name || task.label || ""),
			project: String(task.project_name || ""),
			projectId: String(task.project_id || "")
		}))
	}) : null

	onWantedChanged: if (topic.wanted) {
		Tracking.show(Tracking.day);
		if (Tmpo.teamworkTasks.length === 0) Tmpo.refreshTeamworkTasks();
	}

	function call(action, args, done) {
		switch (action) {
		case "show":
			Tracking.show(String(args.day || ""));
			return {};
		case "step":
			Tracking.step(Number(args.delta) || -1);
			return {};
		case "reload":
			Tracking.reload();
			return {};
		case "toggle":
			Tracking.toggle(topic.entry(args));
			return {};
		case "describe":
			Tracking.describe(topic.entry(args), String(args.text || ""));
			return {};
		case "billable":
			Tracking.setBillable(topic.entry(args), args.on !== false);
			return {};
		case "shift":
			Tracking.shift(topic.entry(args), String(args.edge) === "end" ? "end" : "start", Number(args.minutes) || 0);
			return {};
		case "assign": {
			const task = Tmpo.findTeamworkTaskById(String(args.id || ""));
			if (!task) throw new Error("No such ticket");
			Tracking.assign(topic.entry(args), task);
			return {};
		}
		case "remove":
			Tracking.remove(topic.entry(args));
			return {};
		case "removeProject":
			Tracking.removeProject({ project: String(args.project || "") });
			return {};
		case "send":
			Tracking.send();
			return {};
		case "tickets":
			Tmpo.refreshTeamworkTasks();
			return {};
		}
		throw new Error("unknown-action");
	}
}
