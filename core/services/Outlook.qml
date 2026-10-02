pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Microsoft 365 calendar (scripts/ms_calendar.py). Signing in uses the
// device code flow; the refresh token keeps the shell signed in.
//
// Events are loaded per month grid (six weeks) and cached by day. Five
// minutes before an event a toast reminds of it; while one runs, Notifs
// turns do-not-disturb on, and with qtrack the start and the end of a
// meeting offer to switch the timer.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("microsoft-calendar")
	readonly property string script: `${Paths.scripts}/ms_calendar.py`

	property bool signedIn: false
	property string account: ""
	property string name: ""
	property bool checked: false

	// device code sign-in
	readonly property bool signingIn: loginProc.running
	property string loginCode: ""
	property string loginUrl: ""
	property string error: ""

	// "YYYY-MM-DD" → [event], sorted; loaded grid windows by their first day
	property var byDay: ({})
	property var loaded: ({})
	property var queue: []
	readonly property bool loading: eventsProc.running
	property var selected: null

	property real now: Date.now()
	readonly property var current: root.runningAt(root.now)
	readonly property bool inMeeting: root.current !== null
	property var reminded: ({})
	property string meetingId: ""
	// what the timer tracked when the meeting began
	property var trackedBefore: null

	function dayKey(date) {
		return Qt.formatDate(date, "yyyy-MM-dd");
	}

	function eventsOn(date) {
		return root.byDay[root.dayKey(date)] ?? [];
	}

	function active(event) {
		return !event.cancelled && event.response !== "declined";
	}

	function runningAt(now) {
		const today = root.byDay[root.dayKey(new Date(now))] ?? [];
		return today.find(event => !event.allDay && root.active(event) && event.showAs !== "free"
			&& Date.parse(event.start) <= now && now < Date.parse(event.end)) ?? null;
	}

	// ── loading ──────────────────────────────────────────────────────────
	function gridStart(month) {
		const first = new Date(month.getFullYear(), month.getMonth(), 1);
		return new Date(first.getFullYear(), first.getMonth(), 1 - (first.getDay() + 6) % 7);
	}

	function ensure(month) {
		if (!root.enabled || !root.signedIn) return;
		const key = root.dayKey(root.gridStart(month));
		if (root.loaded[key] || root.queue.includes(key)) return;
		root.queue = root.queue.concat([key]);
		root.next();
	}

	function refresh() {
		if (!root.enabled) return;
		if (!root.signedIn) {
			statusProc.running = true;
			return;
		}
		const keys = Object.keys(root.loaded);
		root.loaded = {};
		root.queue = root.queue.concat(keys.filter(key => !root.queue.includes(key)));
		root.ensure(new Date());
		root.next();
	}

	function next() {
		if (eventsProc.running || root.queue.length === 0) return;
		const key = root.queue[0];
		root.queue = root.queue.slice(1);
		const start = new Date(`${key}T00:00:00`);
		const end = new Date(start.getFullYear(), start.getMonth(), start.getDate() + 42);
		eventsProc.window = key;
		eventsProc.command = ["python3", root.script, "events", key, root.dayKey(end)];
		eventsProc.running = true;
	}

	function apply(text) {
		let data;
		try {
			data = JSON.parse(String(text || "{}"));
		} catch (error) {
			return;
		}
		if (data.error) {
			root.error = data.error;
			return;
		}
		if (data.signedIn === false) {
			root.signOutLocally();
			if (data.expired) root.error = "Sign-in expired";
			return;
		}
		root.error = "";
		const days = Object.assign({}, root.byDay);
		const start = new Date(`${data.from}T00:00:00`);
		for (let i = 0; i < 42; i++)
			delete days[root.dayKey(new Date(start.getFullYear(), start.getMonth(), start.getDate() + i))];
		// days of this window, filled fresh; neighbours keep what they had
		const inWindow = key => key >= data.from && key < data.to;
		for (const event of data.events ?? []) {
			for (const key of event.days) {
				if (!inWindow(key)) continue;
				days[key] = (days[key] ?? []).filter(other => other.id !== event.id).concat([event]);
			}
		}
		for (const key of Object.keys(days))
			if (inWindow(key))
				days[key].sort((a, b) => (b.allDay - a.allDay) || (Date.parse(a.start) - Date.parse(b.start)));
		root.byDay = days;
		const loaded = Object.assign({}, root.loaded);
		loaded[data.from] = true;
		root.loaded = loaded;
		if (root.selected) {
			const fresh = (days[root.selected.days[0]] ?? []).find(event => event.id === root.selected.id);
			if (fresh) root.selected = fresh;
		}
		root.check();
	}

	// ── account ──────────────────────────────────────────────────────────
	function signIn() {
		if (loginProc.running) return;
		root.error = "";
		root.loginCode = "";
		loginProc.running = true;
	}

	function cancelSignIn() {
		loginProc.running = false;
		root.loginCode = "";
	}

	// the code goes to the clipboard, the browser to the sign-in page
	function openSignInPage() {
		Quickshell.execDetached(["wl-copy", "--", root.loginCode]);
		Quickshell.execDetached(["xdg-open", root.loginUrl]);
	}

	function signOut() {
		Quickshell.execDetached(["python3", root.script, "logout"]);
		root.signOutLocally();
	}

	function signOutLocally() {
		root.signedIn = false;
		root.account = "";
		root.name = "";
		root.byDay = {};
		root.loaded = {};
		root.queue = [];
		root.selected = null;
	}

	function select(event) {
		root.selected = root.selected?.id === event?.id && root.selected?.start === event?.start ? null : event;
	}

	function open(url) {
		if (url) Quickshell.execDetached(["xdg-open", url]);
	}

	// ── reminders, meetings ──────────────────────────────────────────────
	function check() {
		root.now = Date.now();
		if (!root.signedIn) return;
		const today = root.byDay[root.dayKey(new Date(root.now))] ?? [];
		for (const event of today) {
			if (event.allDay || !root.active(event)) continue;
			const key = `${event.id}@${event.start}`;
			const lead = Date.parse(event.start) - root.now;
			if (lead > 0 && lead <= 5 * 60 * 1000 && !root.reminded[key]) {
				const reminded = Object.assign({}, root.reminded);
				reminded[key] = true;
				root.reminded = reminded;
				root.remind(event, lead);
			}
		}
		const running = root.current;
		const id = running ? `${running.id}@${running.start}` : "";
		if (id === root.meetingId) return;
		const ended = root.meetingId !== "";
		root.meetingId = id;
		if (running) root.meetingStarted(running, ended);
		else root.meetingEnded();
	}

	function remind(event, lead) {
		const minutes = Math.max(1, Math.round(lead / 60000));
		const actions = [];
		if (event.joinUrl) actions.push({ label: "Join", icon: "video", run: () => root.open(event.joinUrl) });
		actions.push({ label: "Details", icon: "calendar_clock", run: () => root.show(event) });
		const place = event.location || (event.online ? "Online" : "");
		Notifs.pushInternal("running", event.subject, `in ${minutes} min · ${Qt.formatTime(new Date(event.start), "HH:mm")}${place ? " · " + place : ""}`, {
			icon: "calendar_clock",
			actions: actions,
			duration: Math.max(20000, lead)
		});
	}

	function show(event) {
		root.selected = event;
		Popups.withFocusedScreen(screen => Popups.open("today", screen));
	}

	function meetingStarted(event, fromAnother) {
		if (!Plugins.on("qtrack")) return;
		if (!fromAnother) root.trackedBefore = Tmpo.tracking && !Tmpo.paused ? { project: Tmpo.project, description: Tmpo.description } : null;
		if (Tmpo.tracking && !Tmpo.paused && Tmpo.description === event.subject) return;
		Notifs.pushInternal("running", event.subject, Tmpo.tracking && !Tmpo.paused ? `Timer: ${Tmpo.description || Tmpo.project}` : "No timer running", {
			icon: "timer_outline",
			duration: 60000,
			actions: [{ label: "Switch timer", icon: "timer_outline", run: () => root.trackMeeting(event) }]
		});
	}

	function trackMeeting(event) {
		Tmpo.selectedTodayTaskKey = "";
		Tmpo.editDescription(event.subject);
		Popups.withFocusedScreen(screen => Popups.open("timer", screen));
	}

	function meetingEnded() {
		const before = root.trackedBefore;
		root.trackedBefore = null;
		if (!Plugins.on("qtrack") || !before) return;
		if (Tmpo.tracking && !Tmpo.paused && Tmpo.project === before.project && Tmpo.description === before.description) return;
		const label = before.description || before.project;
		Notifs.pushInternal("running", "Meeting over", Tmpo.tracking && !Tmpo.paused ? `Timer: ${Tmpo.description || Tmpo.project}` : "No timer running", {
			icon: "timer_outline",
			duration: 60000,
			actions: [{
				label: `Back to “${label.length > 28 ? label.slice(0, 27) + "…" : label}”`,
				icon: "play",
				run: () => Tmpo.runAction(Tmpo.buildStartArgs(before.project, before.description, Tmpo.findTodayTask(before.project, before.description)))
			}]
		});
	}

	Timer {
		running: root.enabled && root.signedIn
		repeat: true
		interval: 20000
		triggeredOnStart: true
		onTriggered: root.check()
	}

	Timer {
		running: root.enabled && root.signedIn
		repeat: true
		interval: 5 * 60 * 1000
		onTriggered: root.refresh()
	}

	Process {
		id: statusProc

		running: root.enabled
		command: ["python3", root.script, "status"]
		stdout: StdioCollector {
			onStreamFinished: {
				try {
					const data = JSON.parse(String(text || "{}"));
					root.signedIn = data.signedIn === true;
					root.account = data.account ?? "";
					root.name = data.name ?? "";
					if (data.expired) root.error = "Sign-in expired";
				} catch (error) {}
				root.checked = true;
				if (root.signedIn) root.ensure(new Date());
			}
		}
	}

	Process {
		id: loginProc

		command: ["python3", root.script, "login"]
		stdout: SplitParser {
			onRead: line => {
				let data;
				try {
					data = JSON.parse(line);
				} catch (error) {
					return;
				}
				if (data.code) {
					root.loginCode = data.code;
					root.loginUrl = data.url;
				} else if (data.signedIn) {
					root.loginCode = "";
					root.signedIn = true;
					root.account = data.account ?? "";
					root.name = data.name ?? "";
					root.ensure(new Date());
				} else if (data.error) {
					root.loginCode = "";
					root.error = data.error;
				}
			}
		}
	}

	Process {
		id: eventsProc

		property string window: ""

		stdout: StdioCollector {
			onStreamFinished: root.apply(text)
		}
		onExited: Qt.callLater(root.next)
	}
}
