pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Watches over qtrack. Working for a while without a timer brings a toast
// that offers to start the task the work looks like; coming back after
// being away (idle, locked, suspended) while a timer ran offers to take the
// time away out again.
//
// The guess learns by itself: while a timer runs, the words of the focused
// window's title are counted for that task (timer-guard.json). Untracked
// work is compared with those profiles, and with the names of today's and
// the Teamwork tasks when nothing has been learned yet.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("timer-guard")
	readonly property int nudgeSeconds: 10 * 60
	readonly property int snoozeSeconds: 30 * 60
	readonly property int awaySeconds: 15 * 60
	readonly property int sampleSeconds: 30

	readonly property bool trackingNow: Tmpo.tracking && !Tmpo.paused
	property real activeUntracked: 0
	property real snoozeUntil: 0
	property real awaySince: 0
	property real lastTick: Date.now()
	property real idleAt: 0
	// words of the untracked stretch: token → samples
	property var context: ({})
	// taskKey → { project, description, task, tokens: { token: weight }, last }
	property var profiles: ({})

	readonly property var stopwords: ["the", "and", "for", "with", "von", "und", "der", "die", "das", "den", "mit", "für", "auf", "ein", "eine", "original", "profile", "ablaze", "floorp", "firefox", "mozilla", "kitty", "obsidian", "window", "new", "tab", "untitled", "home", "philippjung", "zsh", "bash", "claude", "codex", "code", "visual", "studio"]

	function tokens(text) {
		const out = [];
		for (const raw of String(text || "").toLowerCase().split(/[\s\-–—_/\\|:·.,;()\[\]{}"'`<>!?#@*+=~^$%&◐◑◒◓✳]+/)) {
			if (raw.length < 3 || /^\d+$/.test(raw) || root.stopwords.includes(raw)) continue;
			if (!out.includes(raw)) out.push(raw);
		}
		return out;
	}

	function focusedWords() {
		const window = Niri.windows.find(w => w.is_focused);
		return window ? root.tokens(`${window.title || ""} ${window.app_id || ""}`) : [];
	}

	function taskKey(project, description) {
		return `${project}\u001f${description}`;
	}

	// ── sampling ─────────────────────────────────────────────────────────
	function tick() {
		const now = Date.now();
		const gap = now - root.lastTick;
		root.lastTick = now;
		// the machine slept: that time was away, too
		if (gap > 5 * 60 * 1000 && root.trackingNow && root.awaySince === 0) {
			root.askAway(now - gap);
			return;
		}
		if (Session.locked || shortIdle.isIdle) return;
		const words = root.focusedWords();
		if (root.trackingNow) {
			root.activeUntracked = 0;
			root.context = {};
			root.learn(words);
			return;
		}
		root.activeUntracked += root.sampleSeconds;
		const context = Object.assign({}, root.context);
		for (const word of words) context[word] = (context[word] || 0) + 1;
		root.context = context;
		if (root.activeUntracked >= root.nudgeSeconds && now >= root.snoozeUntil && !Notifs.dnd) root.nudge();
	}

	function learn(words) {
		if (words.length === 0 || Tmpo.project === "") return;
		const key = root.taskKey(Tmpo.project, Tmpo.description);
		const known = Tmpo.findTodayTask(Tmpo.project, Tmpo.description);
		const profiles = Object.assign({}, root.profiles);
		const profile = Object.assign({ project: Tmpo.project, description: Tmpo.description, task: null, tokens: {} }, profiles[key] || {});
		const tokens = Object.assign({}, profile.tokens);
		for (const word of words) tokens[word] = (tokens[word] || 0) + 1;
		// the 150 strongest words are enough to recognise a task
		const kept = {};
		for (const word of Object.keys(tokens).sort((a, b) => tokens[b] - tokens[a]).slice(0, 150))
			kept[word] = tokens[word];
		profile.tokens = kept;
		if (known?.teamwork_task_id) profile.task = {
			teamwork_task_id: known.teamwork_task_id,
			teamwork_project_id: known.teamwork_project_id,
			teamwork_task_name: known.teamwork_task_name || "",
			teamwork_project_name: known.teamwork_project_name || "",
			teamwork_task_url: known.teamwork_task_url || ""
		};
		profile.last = Date.now();
		profiles[key] = profile;
		// forget tasks that were not tracked for two months
		const cutoff = Date.now() - 60 * 24 * 3600 * 1000;
		for (const k of Object.keys(profiles))
			if ((profiles[k].last || 0) < cutoff) delete profiles[k];
		root.profiles = profiles;
		saveDelay.restart();
	}

	// { project, description, task } that fits the untracked work best, or null
	function guess() {
		const context = root.context;
		const total = Object.values(context).reduce((sum, v) => sum + v, 0);
		if (total === 0) return null;
		let best = null;
		let bestScore = 0;
		for (const profile of Object.values(root.profiles)) {
			const weights = profile.tokens || {};
			const mass = Object.values(weights).reduce((sum, v) => sum + v, 0) || 1;
			let score = 0;
			for (const word in context)
				if (weights[word]) score += (context[word] / total) * (weights[word] / mass);
			if (score > bestScore) {
				bestScore = score;
				best = profile;
			}
		}
		if (best && bestScore > 0.02) return best;
		// nothing learned fits: today's tasks by name
		let byName = null;
		let hits = 0;
		for (const task of Tmpo.todayTasks) {
			const words = root.tokens(`${task.project} ${task.description}`);
			const count = words.filter(word => context[word]).length;
			if (count > hits) {
				hits = count;
				byName = { project: task.project, description: task.description, task: task };
			}
		}
		return byName;
	}

	// ── prompts ──────────────────────────────────────────────────────────
	function nudge() {
		root.snoozeUntil = Date.now() + root.snoozeSeconds * 1000;
		const match = root.guess();
		const actions = [];
		if (match) actions.push({ label: `Start “${root.shorten(match.description || match.project)}”`, icon: "play", run: () => root.startTask(match) });
		actions.push({ label: "Timer", icon: "timer_outline", run: () => Popups.withFocusedScreen(screen => Popups.open("timer", screen)) });
		Notifs.pushInternal("running", "No timer running", `Active for ${Math.round(root.activeUntracked / 60)} min`, { icon: "timer_outline", actions: actions, duration: 20000 });
	}

	function startTask(match) {
		root.activeUntracked = 0;
		root.context = {};
		Tmpo.runAction(Tmpo.buildStartArgs(match.project, match.description, match.task));
	}

	function askAway(since) {
		root.awaySince = 0;
		if (!root.trackingNow) return;
		const minutes = Math.round((Date.now() - since) / 60000);
		if (minutes < Math.round(root.awaySeconds / 60)) return;
		const at = Math.round(since / 1000);
		const clock = Qt.formatDateTime(new Date(since), "HH:mm");
		Notifs.pushInternal("running", `Away since ${clock}`, `${minutes} min on “${root.shorten(Tmpo.description || Tmpo.project)}”`, {
			icon: "timer_outline",
			duration: 60000,
			actions: [
				{ label: "Don't count", icon: "close", run: () => root.pauseFrom(at, true) },
				{ label: `Pause from ${clock}`, icon: "pause", run: () => root.pauseFrom(at, false) }
			]
		});
	}

	// pause at a moment in the past, and go on right away if asked
	function pauseFrom(at, resume) {
		const script = resume ? 'python3 "$1" pause --at "$2" && python3 "$1" resume' : 'python3 "$1" pause --at "$2"';
		qtrackProc.command = ["sh", "-c", script, "sh", Tmpo.cliPath, String(at)];
		qtrackProc.running = true;
	}

	function shorten(text) {
		const t = String(text || "");
		return t.length > 32 ? `${t.slice(0, 31)}…` : t;
	}

	Process {
		id: qtrackProc

		onExited: Tmpo.refresh()
	}

	IdleMonitor {
		id: shortIdle

		enabled: root.enabled
		timeout: 120
		respectInhibitors: false
		onIsIdleChanged: {
			if (isIdle) {
				root.idleAt = Date.now();
			} else if (Date.now() - root.idleAt > 10 * 60 * 1000) {
				// a real break: the untracked stretch starts over
				root.activeUntracked = 0;
				root.context = {};
			}
		}
	}

	// a call or a video keeps the machine awake: that is not being away
	IdleMonitor {
		enabled: root.enabled && root.trackingNow
		timeout: root.awaySeconds
		respectInhibitors: true
		onIsIdleChanged: {
			if (isIdle) root.awaySince = Date.now() - root.awaySeconds * 1000;
			else if (root.awaySince > 0) root.askAway(root.awaySince);
		}
	}

	Timer {
		running: root.enabled
		repeat: true
		interval: root.sampleSeconds * 1000
		onTriggered: root.tick()
	}

	Timer {
		id: saveDelay

		interval: 5000
		onTriggered: store.setText(JSON.stringify(root.profiles))
	}

	FileView {
		id: store

		path: root.enabled ? Paths.stateFile("timer-guard.json") : ""
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				root.profiles = JSON.parse(String(text() || "{}")) || {};
			} catch (error) {}
		}
	}
}
