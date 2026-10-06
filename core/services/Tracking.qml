pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The qtrack day board: every day with tracked work, and one of them with
// its entries to edit, queue and send to Teamwork (qtrack-local CLI). The
// running timer itself is Tmpo's.
Singleton {
	id: root

	readonly property int workdayMinutes: 8 * 60

	// [{ day, tracking_minutes, task_count, queued_count, sent_count, unsent_count }], newest first
	property var days: []
	property string today: ""
	property string day: ""
	// the report of `day`: { day, entries, project_groups, total_label, … }
	property var report: null
	property string status: ""
	property bool statusError: false
	// entries (Tmpo.taskKey) and projects an action is still running for
	property var pending: ({})
	property var queue: []

	readonly property bool isToday: root.day !== "" && root.day === root.today
	readonly property bool loading: reportProcess.running || daysProcess.running
	readonly property bool sending: syncProcess.running
	readonly property var entries: Array.isArray(root.report?.entries) ? root.report.entries : []
	readonly property var groups: Array.isArray(root.report?.project_groups) ? root.report.project_groups : []
	readonly property int minutes: root.entries.reduce((sum, entry) => sum + root.entryMinutes(entry), 0)
	readonly property int billableMinutes: root.entries.filter(entry => entry.teamwork_billable !== false).reduce((sum, entry) => sum + root.entryMinutes(entry), 0)
	// the day's rounded stretches in the order they were tracked, neighbours
	// of a kind put together: [{ minutes, billable }]
	readonly property var stretches: {
		const parts = [];
		for (const entry of root.entries) {
			const billable = entry.teamwork_billable !== false;
			const ranges = Array.isArray(entry.rounded_range_timestamps) ? entry.rounded_range_timestamps : [];
			for (const range of ranges)
				parts.push({ start: Number(range.started_ts), minutes: (Number(range.ended_ts) - Number(range.started_ts)) / 60, billable: billable });
			if (ranges.length === 0) parts.push({ start: Number(entry.first_started_ts) || 0, minutes: root.entryMinutes(entry), billable: billable });
		}
		const out = [];
		for (const part of parts.filter(part => part.minutes > 0).sort((a, b) => a.start - b.start)) {
			const last = out[out.length - 1];
			if (last && last.billable === part.billable) last.minutes += part.minutes;
			else out.push({ minutes: part.minutes, billable: part.billable });
		}
		return out;
	}
	readonly property int queued: root.entries.filter(entry => entry.checked && !entry.teamwork_synced).length
	readonly property int sent: root.entries.filter(entry => entry.teamwork_synced).length
	readonly property int dayIndex: root.days.findIndex(entry => entry.day === root.day)

	function entryMinutes(entry) {
		const minutes = Number(entry?.tracking_minutes);
		return Number.isFinite(minutes) ? Math.max(0, minutes) : 0;
	}

	function formatMinutes(total) {
		const minutes = Math.max(0, Math.round(Number(total) || 0));
		const h = Math.floor(minutes / 60);
		const m = minutes % 60;
		return h > 0 ? `${h}h ${m < 10 ? "0" : ""}${m}m` : `${minutes}m`;
	}

	function date(day) {
		return new Date(`${day}T00:00:00`);
	}

	function say(text, isError) {
		root.status = String(text || "").trim().replace(/\s+/g, " ");
		root.statusError = !!isError;
	}

	// what the CLI wrote to stderr; it may arrive before or after the exit code
	function fail(raw) {
		const detail = Tmpo.stripAnsi(raw).trim();
		if (detail !== "") root.say(detail, true);
	}

	function show(day) {
		root.today = Qt.formatDate(new Date(), "yyyy-MM-dd");
		const next = String(day || root.today);
		if (next !== root.day) {
			root.report = null;
			root.say("");
		}
		root.day = next;
		root.reload();
	}

	// the day before (-1) or after (1) in the list, which is newest first
	function step(delta) {
		const target = root.days[root.dayIndex - delta];
		if (root.dayIndex >= 0 && target) root.show(target.day);
	}

	function reload() {
		if (root.day === "") return;
		if (!daysProcess.running) daysProcess.running = true;
		if (reportProcess.running) return;
		reportProcess.forDay = root.day;
		reportProcess.command = ["python3", Tmpo.cliPath, "report", "--json", "--day", root.day];
		reportProcess.running = true;
	}

	function parseDays(raw) {
		let parsed = {};
		try { parsed = JSON.parse(String(raw || "")); } catch (error) { return; }
		root.days = Array.isArray(parsed.days) ? parsed.days : [];
	}

	function parseReport(raw) {
		if (reportProcess.forDay !== root.day) {
			root.reload();
			return;
		}
		try {
			root.report = JSON.parse(String(raw || "")).today ?? null;
		} catch (error) {
			root.say("Could not load qtrack.", true);
		}
	}

	function setPending(key, on) {
		const next = Object.assign({}, root.pending);
		if (on) next[key] = true;
		else delete next[key];
		root.pending = next;
	}

	function isPending(key) {
		return root.pending[key] === true;
	}

	// actions run one after the other, each on the list the one before left
	function run(key, args, success) {
		if (root.isPending(key)) return;
		root.say("");
		root.setPending(key, true);
		root.queue = root.queue.concat([{ key: key, args: args.concat(["--day", root.day, "--json"]), success: success }]);
		root.next();
	}

	function next() {
		if (actionProcess.running || root.queue.length === 0) return;
		const job = root.queue[0];
		root.queue = root.queue.slice(1);
		actionProcess.job = job;
		actionProcess.command = ["python3", Tmpo.cliPath].concat(job.args);
		actionProcess.running = true;
	}

	function finish(exitCode) {
		const job = actionProcess.job;
		actionProcess.job = null;
		if (job) {
			root.setPending(job.key, false);
			if (exitCode === 0) root.say(job.success);
			else if (!root.statusError) root.say("qtrack failed.", true);
		}
		if (root.queue.length > 0) {
			root.next();
			return;
		}
		root.reload();
		Tmpo.refresh();
	}

	function selector(entry) {
		return ["--project", String(entry.project || ""), "--description", String(entry.description || "")];
	}

	function key(entry) {
		return Tmpo.taskKey(entry.project, entry.description);
	}

	function toggle(entry) {
		root.run(root.key(entry), [entry.checked ? "uncheck" : "check"].concat(root.selector(entry)),
			entry.checked ? "removed from queue" : "queued for Teamwork");
	}

	function describe(entry, description) {
		const text = String(description || "").trim();
		if (text === "" || text === String(entry.description || "").trim()) return;
		root.run(root.key(entry), ["edit-description"].concat(root.selector(entry), ["--new-description", text]), "description saved");
	}

	function setBillable(entry, billable) {
		root.run(root.key(entry), ["set-billable"].concat(root.selector(entry), [billable ? "--billable" : "--non-billable"]),
			billable ? "marked billable" : "marked non-billable");
	}

	function shift(entry, edge, minutes) {
		root.run(root.key(entry), ["shift-time"].concat(root.selector(entry), ["--edge", edge, "--minutes", String(minutes)]),
			`${edge} ${minutes > 0 ? "+" : ""}${minutes} min`);
	}

	function assign(entry, task) {
		const taskId = String(task?.task_id || task?.id || "");
		if (taskId === "" || !task.project_id) {
			root.say("The ticket has no project id.", true);
			return;
		}
		root.run(root.key(entry), ["assign-teamwork"].concat(root.selector(entry), [
			"--teamwork-task-id", taskId,
			"--teamwork-project-id", String(task.project_id),
			"--teamwork-task-name", String(task.task_name || ""),
			"--teamwork-project-name", String(task.project_name || ""),
			"--teamwork-task-url", String(task.url || ""),
		]), `ticket set: ${String(task.task_name || task.name || task.label || taskId)}`);
	}

	function remove(entry) {
		root.run(root.key(entry), ["delete"].concat(root.selector(entry)), "entry deleted");
	}

	function removeProject(group) {
		const project = String(group.project || "");
		root.run(project, ["delete-project", "--project", project], "project deleted");
	}

	function send() {
		if (syncProcess.running || root.day === "") return;
		root.say("sending to Teamwork …");
		syncProcess.command = ["python3", Tmpo.cliPath, "sync-teamwork", "--json", "--day", root.day];
		syncProcess.running = true;
	}

	function parseSync(raw) {
		let parsed = {};
		try { parsed = JSON.parse(String(raw || "")); } catch (error) { parsed = {}; }
		if (parsed.message) root.say(parsed.message);
	}

	Process {
		id: daysProcess

		command: ["python3", Tmpo.cliPath, "days", "--json"]
		stdout: StdioCollector { onStreamFinished: root.parseDays(text) }
	}

	Process {
		id: reportProcess

		property string forDay: ""

		stdout: StdioCollector { onStreamFinished: root.parseReport(text) }
	}

	Process {
		id: actionProcess

		property var job: null

		stderr: StdioCollector { onStreamFinished: root.fail(text) }
		onExited: exitCode => root.finish(exitCode)
	}

	Process {
		id: syncProcess

		stdout: StdioCollector { onStreamFinished: root.parseSync(text) }
		stderr: StdioCollector { onStreamFinished: root.fail(text) }
		onExited: exitCode => {
			if (exitCode !== 0 && !root.statusError) root.say("Sending to Teamwork failed.", true);
			else if (root.status === "sending to Teamwork …") root.say("sent to Teamwork");
			root.reload();
			Tmpo.refresh();
		}
	}
}
